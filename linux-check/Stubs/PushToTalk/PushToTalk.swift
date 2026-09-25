import Foundation
@_exported import AVFoundation
open class PTChannelDescriptor: NSObject { public init(name: String, image: AnyObject?) {} }
open class PTParticipant: NSObject { public init(name: String, image: AnyObject?) {} }
open class PTPushResult: NSObject {
    public static var leaveChannel: PTPushResult { PTPushResult() }
    public static func activeRemoteParticipant(_ participant: PTParticipant) -> PTPushResult { PTPushResult() }
}
public enum PTChannelJoinReason: Int { case developerRequest, channelRestoration }
public enum PTChannelLeaveReason: Int { case unknown, userRequest, developerRequest, systemPolicy }
public enum PTChannelTransmitRequestSource: Int { case unknown, userRequest, developerRequest, handsfreeButton }
public protocol PTChannelManagerDelegate: NSObjectProtocol {
    func channelManager(_ channelManager: PTChannelManager, didJoinChannel channelUUID: UUID, reason: PTChannelJoinReason)
    func channelManager(_ channelManager: PTChannelManager, didLeaveChannel channelUUID: UUID, reason: PTChannelLeaveReason)
    func channelManager(_ channelManager: PTChannelManager, channelUUID: UUID, didBeginTransmittingFrom source: PTChannelTransmitRequestSource)
    func channelManager(_ channelManager: PTChannelManager, channelUUID: UUID, didEndTransmittingFrom source: PTChannelTransmitRequestSource)
    func channelManager(_ channelManager: PTChannelManager, receivedEphemeralPushToken pushToken: Data)
    func incomingPushResult(channelManager: PTChannelManager, channelUUID: UUID, pushPayload: [String: Any]) -> PTPushResult
    func channelManager(_ channelManager: PTChannelManager, didActivate audioSession: AVAudioSession)
    func channelManager(_ channelManager: PTChannelManager, didDeactivate audioSession: AVAudioSession)
}
public protocol PTChannelRestorationDelegate: NSObjectProtocol {
    func channelDescriptor(restoredChannelUUID channelUUID: UUID) -> PTChannelDescriptor
}
open class PTChannelManager: NSObject {
    public static func channelManager(delegate: any PTChannelManagerDelegate, restorationDelegate: any PTChannelRestorationDelegate) async throws -> PTChannelManager { PTChannelManager() }
    open var activeChannelUUID: UUID? { nil }
    open func requestJoinChannel(channelUUID: UUID, descriptor: PTChannelDescriptor) {}
    open func requestBeginTransmitting(channelUUID: UUID) {}
    open func stopTransmitting(channelUUID: UUID) {}
}
