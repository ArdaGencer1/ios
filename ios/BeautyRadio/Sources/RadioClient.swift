import Foundation

public protocol RadioClientDelegate: AnyObject {
    func radioClient(_ client: RadioClient, didChangeState state: RadioClient.State)
    func radioClient(_ client: RadioClient, didReceiveMixedAudio pcm: Data)
    func radioClient(_ client: RadioClient, didChangeSpeakers speakers: [String])
    func radioClient(_ client: RadioClient, didFail error: Error)
}

/// Transport and control protocol for `/ws/radio`.
///
/// Two rules from the server contract shape this class:
///
/// * Every grant carries `allowConcurrentTalk: true` and `busy: false`. The
///   server mixes any number of simultaneous speakers and never reports a busy
///   channel, so the talk button must never be disabled because somebody else
///   is speaking. There is deliberately no busy state in this file.
/// * A protocol-v2 sender creates its own `streamId` and `txGeneration` before
///   signalling and starts sending audio immediately. WebSocket preserves the
///   order of the preceding control frame, so waiting for `ptt-granted` would
///   add a round trip to every press for no benefit.
// All mutable state is confined to `queue` except the transmission identity,
// which `stateLock` guards; `delegate` and `credentialRefresher` are set once
// before `connect()`. That is what makes the unchecked conformance honest.
public final class RadioClient: NSObject, @unchecked Sendable {

    public enum State: Equatable, Sendable {
        case disconnected
        case connecting
        case joined(channel: String)
    }

    public weak var delegate: RadioClientDelegate?
    /// Called when the server refuses the socket upgrade with 401 — the staff
    /// JWT lapsed. Returns true once fresh credentials are stored, and the
    /// socket reconnects straight away instead of waiting out the backoff.
    public var credentialRefresher: (@Sendable () async -> Bool)?
    public private(set) var state: State = .disconnected {
        didSet {
            guard state != oldValue else { return }
            DispatchQueue.main.async { self.delegate?.radioClient(self, didChangeState: self.state) }
        }
    }

    private let baseURL: URL
    private let credentials = RadioCredentials.shared
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private let queue = DispatchQueue(label: "com.rootbeauty.radio.client")

    /// Transmission identity is read by the audio queue and written by the
    /// button, so it is guarded rather than confined to `queue`. Setting it
    /// asynchronously meant the pre-roll could reach `send(pcm:)` before the
    /// stream existed, and those frames — the first word — were dropped.
    private let stateLock = NSLock()
    private var currentStreamId: String?
    private var currentGeneration: UInt32 = 0
    private var outboundSequence: UInt32 = 0
    /// Frames captured while the socket is down. Held rather than discarded so
    /// a reconnect in the middle of a sentence does not lose it.
    private var pendingOutbound: [Data] = []
    private let maxPendingOutboundFrames = 150
    private var reconnectAttempt = 0
    private var intentionallyClosed = false
    private var activeSpeakers: [String] = []

    public init(baseURL: URL) {
        self.baseURL = baseURL
        super.init()
        let configuration = URLSessionConfiguration.default
        #if canImport(FoundationNetworking)
        // Linux only (the offline check harness): read-only there.
        #else
        // Keeps a connect attempt pending until the phone has a network again
        // instead of failing immediately — a radio on hotel Wi-Fi reconnects on
        // its own.
        configuration.waitsForConnectivity = true
        #endif
        // A radio that reconnects slowly is a radio that misses the call.
        configuration.timeoutIntervalForRequest = 15
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    // MARK: - Connection

    public func connect() {
        queue.async { self.openSocket() }
    }

    public func disconnect() {
        queue.async {
            self.intentionallyClosed = true
            self.task?.cancel(with: .goingAway, reason: nil)
            self.task = nil
            self.state = .disconnected
        }
    }

    private func openSocket() {
        guard task == nil else { return }
        intentionallyClosed = false
        state = .connecting

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.scheme = baseURL.scheme == "http" ? "ws" : "wss"
        components?.path = "/ws/radio"
        components?.queryItems = [
            URLQueryItem(name: "channel", value: credentials.channel),
            URLQueryItem(name: "installationId", value: credentials.installationId),
            URLQueryItem(name: "mediaProtocol", value: "2")
        ]
        guard let url = components?.url else { return }

        var request = URLRequest(url: url)
        // The staff JWT is preferred; the device token keeps the radio alive
        // once that JWT has expired, which is what makes an APNs wake-up able
        // to rejoin without a login screen.
        if let staffToken = credentials.staffToken {
            request.setValue("Bearer \(staffToken)", forHTTPHeaderField: "Authorization")
        }
        if let deviceToken = credentials.deviceToken {
            request.setValue(deviceToken, forHTTPHeaderField: "X-Radio-Device-Token")
        }
        request.setValue("SeldaBeautyIosWebView", forHTTPHeaderField: "User-Agent")

        let socket = session.webSocketTask(with: request)
        task = socket
        socket.resume()
        receiveNext()
    }

    private func scheduleReconnect() {
        guard !intentionallyClosed else { return }
        reconnectAttempt += 1
        // Quick first retries so a dropped socket is back before the next press,
        // then back off so a server outage is not hammered.
        let delay = min(pow(1.6, Double(min(reconnectAttempt, 8))) * 0.25, 20)
        queue.asyncAfter(deadline: .now() + delay) {
            self.task = nil
            self.openSocket()
        }
    }

    // MARK: - Receiving

    private func receiveNext() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                let status = (self.task?.response as? HTTPURLResponse)?.statusCode
                self.queue.async {
                    self.state = .disconnected
                    if status == 401, let refresher = self.credentialRefresher {
                        Task {
                            let refreshed = await refresher()
                            self.queue.async {
                                self.task = nil
                                if refreshed { self.openSocket() } else { self.scheduleReconnect() }
                            }
                        }
                        return
                    }
                    DispatchQueue.main.async { self.delegate?.radioClient(self, didFail: error) }
                    self.scheduleReconnect()
                }
            case .success(let message):
                self.queue.async { self.handle(message) }
                self.receiveNext()
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .data(let data):
            handleBinary(data)
        case .string(let text):
            handleControl(Data(text.utf8))
        @unknown default:
            break
        }
    }

    private func handleBinary(_ data: Data) {
        do {
            if let frame = try RadioEnvelope.decode(data) {
                // Header length is read from the frame, never assumed: the
                // downlink mix uses the speaker id "server-mix" and therefore a
                // shorter header than anything this device sends.
                delegate?.radioClient(self, didReceiveMixedAudio: frame.pcm)
            } else {
                // A server still on protocol 1 sends bare PCM.
                delegate?.radioClient(self, didReceiveMixedAudio: data)
            }
        } catch {
            DispatchQueue.main.async { self.delegate?.radioClient(self, didFail: error) }
        }
    }

    private func handleControl(_ data: Data) {
        guard let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = payload["type"] as? String else { return }

        switch type {
        case "joined":
            reconnectAttempt = 0
            state = .joined(channel: payload["channel"] as? String ?? credentials.channel)
            flushPendingOutbound()
        case "speaker-start":
            if let name = payload["speakerName"] as? String, !name.isEmpty, !activeSpeakers.contains(name) {
                activeSpeakers.append(name)
                notifySpeakers()
            }
        case "speaker-stop":
            if let name = payload["speakerName"] as? String {
                activeSpeakers.removeAll { $0 == name }
                notifySpeakers()
            }
        case "presence":
            if let names = payload["speakerNames"] as? [String] {
                activeSpeakers = names.filter { !$0.isEmpty }
                notifySpeakers()
            }
        default:
            break
        }
    }

    private func notifySpeakers() {
        let speakers = activeSpeakers
        DispatchQueue.main.async { self.delegate?.radioClient(self, didChangeSpeakers: speakers) }
    }

    // MARK: - Transmitting

    /// Called the instant the button goes down. The stream identity is
    /// established synchronously so a frame can never arrive before it, and the
    /// control frame is queued behind it — WebSocket preserves that order, so
    /// the server sees `ptt-start` before the audio either way.
    public func beginTransmitting() {
        let streamId = UUID().uuidString.lowercased()
        stateLock.lock()
        currentStreamId = streamId
        currentGeneration &+= 1
        outboundSequence = 0
        let generation = currentGeneration
        stateLock.unlock()

        queue.async {
            if self.task == nil { self.openSocket() }
            self.send(control: [
                "type": "ptt-start",
                "transmissionId": streamId,
                "streamId": streamId,
                "txGeneration": Int(generation),
                "clientStartedAtEpochUs": Int(Date().timeIntervalSince1970 * 1_000_000)
            ])
        }
    }

    /// Must only be called once the audio engine has finished draining its
    /// tail: the server stops accepting this transmission's audio shortly after
    /// this frame lands.
    public func endTransmitting() {
        stateLock.lock()
        let streamId = currentStreamId
        let generation = currentGeneration
        currentStreamId = nil
        stateLock.unlock()
        guard let streamId else { return }

        queue.async {
            self.flushPendingOutbound()
            self.send(control: [
                "type": "ptt-stop",
                "transmissionId": streamId,
                "streamId": streamId,
                "txGeneration": Int(generation)
            ])
        }
    }

    /// One 640-byte PCM16LE frame from the capture tap.
    public func send(pcm: Data) {
        stateLock.lock()
        guard let streamId = currentStreamId else {
            stateLock.unlock()
            return
        }
        let sequence = outboundSequence
        outboundSequence &+= 1
        let generation = currentGeneration
        stateLock.unlock()

        let encoded: Data
        do {
            encoded = try RadioEnvelope.encode(
                sequence: sequence,
                mediaTimestampMicroseconds: UInt64(Date().timeIntervalSince1970 * 1_000_000),
                transmissionGeneration: generation,
                channel: credentials.channel,
                // The server accepts the connection id, the installation id or
                // the staff id here; the installation id is the one this client
                // always knows.
                speakerId: credentials.installationId,
                streamId: streamId,
                pcm: pcm
            )
        } catch {
            DispatchQueue.main.async { self.delegate?.radioClient(self, didFail: error) }
            return
        }

        queue.async {
            guard let task = self.task, case .joined = self.state else {
                // Mid-sentence reconnect: hold the frame instead of dropping it.
                self.pendingOutbound.append(encoded)
                if self.pendingOutbound.count > self.maxPendingOutboundFrames {
                    self.pendingOutbound.removeFirst(self.pendingOutbound.count - self.maxPendingOutboundFrames)
                }
                return
            }
            task.send(.data(encoded)) { error in
                guard error != nil else { return }
                // A failed send means this socket is gone; let the receive loop
                // reconnect rather than silently losing the rest of the phrase.
                self.queue.async { self.task?.cancel(with: .abnormalClosure, reason: nil) }
            }
        }
    }

    private func flushPendingOutbound() {
        guard let task, !pendingOutbound.isEmpty else { return }
        let frames = pendingOutbound
        pendingOutbound.removeAll(keepingCapacity: true)
        for frame in frames { task.send(.data(frame)) { _ in } }
    }

    private func send(control payload: [String: Any]) {
        guard let task, let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }
}

extension RadioClient: URLSessionWebSocketDelegate {
    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        // The upgrade succeeded; a later drop should retry quickly again.
        queue.async { self.reconnectAttempt = 0 }
    }

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        queue.async {
            self.state = .disconnected
            self.scheduleReconnect()
        }
    }
}
