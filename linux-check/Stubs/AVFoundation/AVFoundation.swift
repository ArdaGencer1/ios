import Foundation
// Darwin: AutoreleasingUnsafeMutablePointer<NSError?>?; the call site `&err` fits both.
public typealias NSErrorPointer = UnsafeMutablePointer<NSError?>?
public typealias AVAudioFrameCount = UInt32
public typealias AVAudioPacketCount = UInt32
public typealias AVAudioChannelCount = UInt32
public typealias AVAudioNodeBus = Int

open class AVAudioSession: NSObject {
    public static func sharedInstance() -> AVAudioSession { AVAudioSession() }
    public struct Category: RawRepresentable, Hashable, Sendable {
        public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue }
        public static let playAndRecord = Category(rawValue: "PlayAndRecord")
    }
    public struct Mode: RawRepresentable, Hashable, Sendable {
        public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue }
        public static let voiceChat = Mode(rawValue: "VoiceChat")
    }
    public struct CategoryOptions: OptionSet, Sendable {
        public let rawValue: UInt; public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let duckOthers = CategoryOptions(rawValue: 2)
        public static let allowBluetooth = CategoryOptions(rawValue: 4)
        public static let defaultToSpeaker = CategoryOptions(rawValue: 8)
        public static let allowBluetoothA2DP = CategoryOptions(rawValue: 32)
    }
    public struct SetActiveOptions: OptionSet, Sendable {
        public let rawValue: UInt; public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let notifyOthersOnDeactivation = SetActiveOptions(rawValue: 1)
    }
    public struct Port: RawRepresentable, Hashable, Sendable {
        public let rawValue: String; public init(rawValue: String) { self.rawValue = rawValue }
        public static let bluetoothHFP = Port(rawValue: "BluetoothHFP")
        public static let bluetoothLE = Port(rawValue: "BluetoothLE")
        public static let headsetMic = Port(rawValue: "MicrophoneWired")
    }
    public static let routeChangeNotification = Notification.Name("AVAudioSessionRouteChangeNotification")
    open func setCategory(_ category: Category, mode: Mode, options: CategoryOptions = []) throws {}
    open func setPreferredSampleRate(_ sampleRate: Double) throws {}
    open func setPreferredIOBufferDuration(_ duration: TimeInterval) throws {}
    open func setActive(_ active: Bool, options: SetActiveOptions = []) throws {}
    open var availableInputs: [AVAudioSessionPortDescription]? { nil }
    open func setPreferredInput(_ inPort: AVAudioSessionPortDescription?) throws {}
    open var currentRoute: AVAudioSessionRouteDescription { AVAudioSessionRouteDescription() }
}
open class AVAudioSessionPortDescription: NSObject {
    open var portType: AVAudioSession.Port { .headsetMic }
    open var portName: String { "" }
}
open class AVAudioSessionRouteDescription: NSObject {
    open var outputs: [AVAudioSessionPortDescription] { [] }
}
public enum AVAudioCommonFormat: UInt, Sendable { case otherFormat, pcmFormatFloat32, pcmFormatFloat64, pcmFormatInt16, pcmFormatInt32 }
open class AVAudioFormat: NSObject {
    public init?(commonFormat format: AVAudioCommonFormat, sampleRate: Double, channels: AVAudioChannelCount, interleaved: Bool) {}
    open var sampleRate: Double { 16000 }
}
open class AVAudioBuffer: NSObject {}
open class AVAudioPCMBuffer: AVAudioBuffer {
    public init?(pcmFormat format: AVAudioFormat, frameCapacity: AVAudioFrameCount) { self.format = format }
    open var frameLength: AVAudioFrameCount = 0
    open var format: AVAudioFormat
    open var int16ChannelData: UnsafePointer<UnsafeMutablePointer<Int16>>? { nil }
}
public enum AVAudioConverterInputStatus: Int { case haveData, noDataNow, endOfStream }
public enum AVAudioConverterOutputStatus: Int { case haveData, inputRanDry, endOfStream, error }
public typealias AVAudioConverterInputBlock = (AVAudioPacketCount, UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer?
open class AVAudioConverter: NSObject {
    public init?(from fromFormat: AVAudioFormat, to toFormat: AVAudioFormat) {}
    open func convert(to outputBuffer: AVAudioBuffer, error outError: NSErrorPointer, withInputFrom inputBlock: AVAudioConverterInputBlock) -> AVAudioConverterOutputStatus { .haveData }
}
open class AVAudioTime: NSObject {}
// Strict on purpose: newer SDKs deliver the tap on a realtime thread and mark it @Sendable.
public typealias AVAudioNodeTapBlock = @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
public typealias AVAudioNodeCompletionHandler = @Sendable () -> Void
open class AVAudioNode: NSObject {
    open func outputFormat(forBus bus: AVAudioNodeBus) -> AVAudioFormat { AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 1, interleaved: true)! }
    open func installTap(onBus bus: AVAudioNodeBus, bufferSize: AVAudioFrameCount, format: AVAudioFormat?, block tapBlock: @escaping AVAudioNodeTapBlock) {}
    open func removeTap(onBus bus: AVAudioNodeBus) {}
}
open class AVAudioIONode: AVAudioNode {}
open class AVAudioInputNode: AVAudioIONode {}
open class AVAudioMixerNode: AVAudioNode {}
open class AVAudioPlayerNode: AVAudioNode {
    public override init() {}
    open func play() {}
    open func stop() {}
    open func pause() {}
    open func scheduleBuffer(_ buffer: AVAudioPCMBuffer, completionHandler: AVAudioNodeCompletionHandler? = nil) {}
}
open class AVAudioEngine: NSObject {
    public override init() {}
    open var inputNode: AVAudioInputNode { AVAudioInputNode() }
    open var mainMixerNode: AVAudioMixerNode { AVAudioMixerNode() }
    open func attach(_ node: AVAudioNode) {}
    open func connect(_ node1: AVAudioNode, to node2: AVAudioNode, format: AVAudioFormat?) {}
    open func prepare() {}
    open func start() throws {}
    open func stop() {}
    open func pause() {}
    open var isRunning: Bool { false }
}
