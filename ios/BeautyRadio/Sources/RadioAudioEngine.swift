@preconcurrency import AVFoundation
import Foundation

/// Capture and playback for the radio.
///
/// The measured problem this class exists to solve: the previous build took a
/// median of 871 ms (worst case 2719 ms) between the talk button being pressed
/// and the first audio byte reaching the server, because the audio session and
/// engine were started on the press. Android on the same server measured 117 ms.
/// Everything the server does — receive, mix, fan out — costs 25-44 ms, so the
/// startup was more than twenty times the rest of the path combined.
///
/// Two things remove it:
///
/// 1. The engine runs for the whole time the channel is joined. Pressing talk
///    only flips a flag; no session activation, no engine start, no format
///    negotiation happens on the press.
/// 2. A pre-roll ring buffer always holds the most recent `preRollDuration` of
///    captured audio. On press that audio is sent first, so syllables spoken
///    slightly before — or during — the press are transmitted instead of lost.
///    A walkie-talkie that clips the first word is the thing users notice most.
///
/// Releasing is symmetric. `endTransmitting` keeps capturing for `tailDuration`
/// and flushes the partial frame before its completion runs, because the server
/// stops accepting a transmission's audio once `ptt-stop` lands. Signalling the
/// stop at the same moment as the release is what cut the final word off a
/// short "let me just say this quickly".
///
/// Haptics are never awaited here. The caller fires them on its own queue so a
/// vibration can never sit between the press and the microphone.
// Capture state (`transmitting`, `preRoll`, `pendingCapture`) is confined to
// `audioQueue`; the running flags are guarded by `stateLock`. Callbacks are set
// once before `prepare()`. That confinement is what the unchecked conformance
// relies on.
public final class RadioAudioEngine: @unchecked Sendable {

    public struct Configuration {
        public var sampleRate: Double = 16_000
        public var frameDurationMs: Int = 20
        /// How much audio from before the press is transmitted.
        public var preRollDuration: TimeInterval = 0.3
        /// Playback is held this long before starting, to absorb network jitter
        /// without adding latency a listener can perceive.
        public var playoutBufferDuration: TimeInterval = 0.06
        /// How long capture keeps running after the button is released, so the
        /// audio still inside the hardware buffer, the converter and this queue
        /// is transmitted before the stop is signalled. Matches the server's
        /// `RADIO_TAIL_GRACE_MS`.
        public var tailDuration: TimeInterval = 0.25
        public init() {}
    }

    /// 20 ms at 16 kHz mono PCM16 = 320 samples = 640 bytes, matching the
    /// server's mixer frame exactly so no repacketisation is needed.
    public var frameSampleCount: Int { Int(configuration.sampleRate) * configuration.frameDurationMs / 1000 }
    public var frameByteCount: Int { frameSampleCount * 2 }

    public private(set) var configuration: Configuration
    /// Whether captured frames are being sent. Only ever read and written on
    /// `audioQueue`: the capture tap runs there, and touching this from the
    /// button's thread raced the tap and could drop or duplicate frames.
    private var transmitting = false
    /// Called on the audio queue with one ready-to-send 640-byte PCM16LE frame.
    public var onCapturedFrame: (@Sendable (Data) -> Void)?
    public var onRouteChanged: (@Sendable (String) -> Void)?

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let audioQueue = DispatchQueue(label: "com.rootbeauty.radio.audio", qos: .userInteractive)
    private var converter: AVAudioConverter?
    private var captureFormat: AVAudioFormat?
    var pendingCapture = Data()
    var preRoll: [Data] = []
    private var preRollFrameCapacity: Int {
        max(1, Int(configuration.preRollDuration * 1000) / configuration.frameDurationMs)
    }
    private let stateLock = NSLock()
    private var _isRunning = false
    private var _isPrepared = false
    private var isRunning: Bool {
        get { stateLock.withLock { _isRunning } }
        set { stateLock.withLock { _isRunning = newValue } }
    }
    private var isPrepared: Bool {
        get { stateLock.withLock { _isPrepared } }
        set { stateLock.withLock { _isPrepared = newValue } }
    }
    /// Block-based observers are removed by their token, not by `self`; without
    /// keeping it, every prepare after a logout added one more route handler.
    private var routeObserver: NSObjectProtocol?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    // MARK: - Transmit window

    /// Button down. Serialised with the capture tap, and the retained pre-roll
    /// is emitted first so the syllables from just before the press are sent.
    public func beginTransmitting() {
        audioQueue.async {
            guard !self.transmitting else { return }
            self.transmitting = true
            let buffered = self.preRoll
            self.preRoll.removeAll(keepingCapacity: true)
            for frame in buffered { self.onCapturedFrame?(frame) }
        }
    }

    /// Button up. Capture keeps running for `tailDuration` before `completion`
    /// fires, so the caller can delay `ptt-stop` until the tail has been sent.
    /// Releasing and signalling the stop in the same breath is what cut the
    /// last word off a short transmission.
    public func endTransmitting(completion: @escaping @Sendable () -> Void) {
        audioQueue.async {
            guard self.transmitting else {
                completion()
                return
            }
            self.audioQueue.asyncAfter(deadline: .now() + self.configuration.tailDuration) {
                guard self.transmitting else { return }
                self.flushPartialFrame()
                self.transmitting = false
                self.preRoll.removeAll(keepingCapacity: true)
                completion()
            }
        }
    }

    /// The final packet of a phrase is usually shorter than one wire frame.
    /// Zero-padding and sending it keeps the last few milliseconds of speech
    /// instead of discarding them with the remainder.
    private func flushPartialFrame() {
        guard !pendingCapture.isEmpty else { return }
        var frame = pendingCapture
        pendingCapture.removeAll(keepingCapacity: true)
        if frame.count < frameByteCount {
            frame.append(Data(repeating: 0, count: frameByteCount - frame.count))
        }
        onCapturedFrame?(frame.prefix(frameByteCount))
    }

    // MARK: - Lifecycle

    /// Configure the session and build the graph without claiming the session.
    /// Under PushToTalk the system owns activation and hands it over through
    /// `PTChannelManagerDelegate`; forcing `setActive(true)` here fights it and
    /// can fail outright while the app is in the background. Everything
    /// expensive — category negotiation, format conversion setup, the tap — is
    /// done here so activation later is only `engine.start()`.
    public func prepare() throws {
        guard !isPrepared else { return }
        try configureSession()
        try buildGraph()
        engine.prepare()
        isPrepared = true
        observeRouteChanges()
    }

    /// Claim the session ourselves. Used for the in-app path, where no system
    /// PushToTalk activation is coming.
    public func activate() throws {
        try prepare()
        try AVAudioSession.sharedInstance().setActive(true, options: [])
        try startGraph()
    }

    /// The PushToTalk framework has activated the session for us. Do not call
    /// `setActive` here — only bring the graph back up.
    public func resumeAfterSystemActivation() throws {
        try prepare()
        try startGraph()
    }

    /// The system took the session away (a call, another PTT app). Keep the
    /// graph built so the next activation is immediate.
    public func suspendAfterSystemDeactivation() {
        playerNode.pause()
        engine.pause()
        isRunning = false
    }

    private func startGraph() throws {
        if !engine.isRunning { try engine.start() }
        playerNode.play()
        isRunning = true
        try? preferBluetoothInput(AVAudioSession.sharedInstance())
    }

    public func stop() {
        guard isPrepared else { return }
        isPrepared = false
        isRunning = false
        audioQueue.async { self.transmitting = false }
        playerNode.stop()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioQueue.async {
            self.preRoll.removeAll(keepingCapacity: false)
            self.pendingCapture.removeAll(keepingCapacity: false)
        }
        if let routeObserver {
            NotificationCenter.default.removeObserver(routeObserver)
            self.routeObserver = nil
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Session

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        // .voiceChat gives the echo canceller and the low-latency I/O path.
        // Bluetooth HFP is listed first so a paired headset wins over the
        // speaker; .defaultToSpeaker only applies when no headset is present.
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker, .duckOthers]
        )
        try session.setPreferredSampleRate(configuration.sampleRate)
        // Small I/O buffer: the hardware callback interval is part of the
        // press-to-air budget.
        try session.setPreferredIOBufferDuration(0.005)
        try preferBluetoothInput(session)
    }

    private func preferBluetoothInput(_ session: AVAudioSession) throws {
        let bluetoothPorts: Set<AVAudioSession.Port> = [.bluetoothHFP, .bluetoothLE, .headsetMic]
        guard let headset = session.availableInputs?.first(where: { bluetoothPorts.contains($0.portType) }) else {
            return
        }
        try session.setPreferredInput(headset)
    }

    private func observeRouteChanges() {
        guard routeObserver == nil else { return }
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let session = AVAudioSession.sharedInstance()
            try? self.preferBluetoothInput(session)
            let name = session.currentRoute.outputs.first?.portName ?? "bilinmiyor"
            self.onRouteChanged?(name)
        }
    }

    // MARK: - Graph

    private func buildGraph() throws {
        let input = engine.inputNode
        let hardwareFormat = input.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0 else { throw RadioAudioError.noInputAvailable }

        guard let wireFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: configuration.sampleRate,
            channels: 1,
            interleaved: true
        ) else { throw RadioAudioError.unsupportedFormat }

        captureFormat = wireFormat
        converter = AVAudioConverter(from: hardwareFormat, to: wireFormat)

        engine.attach(playerNode)
        // Play out at the wire format so no extra conversion sits in the path.
        engine.connect(playerNode, to: engine.mainMixerNode, format: playbackFormat())

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: hardwareFormat) { [weak self] buffer, _ in
            // Bind once: re-reading the weak var inside the hop is a race.
            guard let self else { return }
            self.audioQueue.async { self.handleCaptured(buffer) }
        }
    }

    private func playbackFormat() -> AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: configuration.sampleRate,
            channels: 1,
            interleaved: true
        ) ?? engine.mainMixerNode.outputFormat(forBus: 0)
    }

    // MARK: - Capture

    private func handleCaptured(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let captureFormat else { return }
        let ratio = configuration.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let converted = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: capacity) else { return }

        var suppliedOnce = false
        var conversionError: NSError?
        let conversionStatus = converter.convert(to: converted, error: &conversionError) { _, status in
            if suppliedOnce {
                status.pointee = .noDataNow
                return nil
            }
            suppliedOnce = true
            status.pointee = .haveData
            return buffer
        }
        // A failed conversion must not reach the wire as a garbage frame.
        guard conversionStatus != .error,
              conversionError == nil,
              converted.frameLength > 0,
              let channel = converted.int16ChannelData else { return }

        pendingCapture.append(Data(bytes: channel[0], count: Int(converted.frameLength) * 2))

        // Emit exactly one wire frame at a time so the server's 20 ms mixer tick
        // never has to split or pad a packet.
        while pendingCapture.count >= frameByteCount {
            let frame = pendingCapture.prefix(frameByteCount)
            pendingCapture.removeFirst(frameByteCount)
            deliver(Data(frame))
        }
    }

    // internal, not private: the pre-roll and tail behaviour is covered by tests.
    func deliver(_ frame: Data) {
        if transmitting {
            onCapturedFrame?(frame)
        } else {
            preRoll.append(frame)
            if preRoll.count > preRollFrameCapacity { preRoll.removeFirst(preRoll.count - preRollFrameCapacity) }
        }
    }

    /// Test hook: waits for everything already queued on the audio queue.
    func syncForTesting() {
        audioQueue.sync {}
    }

    // MARK: - Playback

    /// Schedules one mixed frame from the server. The player node is already
    /// running, so a frame is audible as soon as the node reaches it.
    public func play(pcm: Data) {
        audioQueue.async { [weak self] in
            guard let self, self.isRunning else { return }
            let format = self.playbackFormat()
            let frameCount = AVAudioFrameCount(pcm.count / 2)
            guard frameCount > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
                  let channel = buffer.int16ChannelData else { return }
            buffer.frameLength = frameCount
            pcm.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: Int16.self).baseAddress else { return }
                channel[0].update(from: base, count: Int(frameCount))
            }
            self.playerNode.scheduleBuffer(buffer, completionHandler: nil)
        }
    }
}

public enum RadioAudioError: Error {
    case noInputAvailable
    case unsupportedFormat
}
