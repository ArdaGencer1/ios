import Foundation
import PushToTalk
import AVFoundation

/// Bridges Apple's PushToTalk framework to `RadioSession`.
///
/// This is the piece whose absence made the radio unreliable: the server was
/// delivering its `pushtotalk` wake-up (the APNs fanout logged `sent: 2,
/// delivered`), but nothing rejoined `/ws/radio` afterwards, so the woken phone
/// sat on the channel list without a socket and heard nothing. Every path that
/// can wake this app therefore calls `session.join()`.
@MainActor
public final class RadioPushToTalkManager: NSObject {

    public static let channelUUID = UUID(uuidString: "7B3A1F6E-2C55-4B7A-9E11-8F4D6C2A9051")!

    private let session: RadioSession
    private var channelManager: PTChannelManager?
    private let channelName: String

    public init(session: RadioSession, channelName: String = "Telsiz") {
        self.session = session
        self.channelName = channelName
        super.init()
    }

    private var isStarting = false

    /// Idempotent, including under concurrent calls: a second manager would
    /// split the system's callbacks between two objects.
    public func start() async {
        guard channelManager == nil, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        do {
            channelManager = try await PTChannelManager.channelManager(delegate: self, restorationDelegate: self)
            await requestJoin()
        } catch {
            // A failure here costs the lock screen button, not the radio: the
            // in-app path still works over the same socket.
            print("PushToTalk baslatilamadi: \(error.localizedDescription)")
            await session.join()
        }
    }

    private func requestJoin() async {
        guard let channelManager else { return }
        // After a background relaunch the system has already restored the
        // channel; asking to join it again is redundant at best.
        if channelManager.activeChannelUUID != Self.channelUUID {
            let descriptor = PTChannelDescriptor(name: channelName, image: nil)
            channelManager.requestJoinChannel(channelUUID: Self.channelUUID, descriptor: descriptor)
        }
        // Bring the socket and the audio engine up with the channel, so the
        // first press has nothing left to start.
        await session.join()
    }

    /// Button down from the app's own UI.
    public func beginTransmitting() {
        session.startTalking()
        channelManager?.requestBeginTransmitting(channelUUID: Self.channelUUID)
    }

    public func stopTransmitting() {
        session.stopTalking()
        channelManager?.stopTransmitting(channelUUID: Self.channelUUID)
    }
}

// MARK: - PTChannelManagerDelegate

extension RadioPushToTalkManager: PTChannelManagerDelegate {

    nonisolated public func channelManager(
        _ channelManager: PTChannelManager,
        didJoinChannel channelUUID: UUID,
        reason: PTChannelJoinReason
    ) {
        Task { @MainActor in await session.join() }
    }

    nonisolated public func channelManager(
        _ channelManager: PTChannelManager,
        didLeaveChannel channelUUID: UUID,
        reason: PTChannelLeaveReason
    ) {
        Task { @MainActor in await session.leave() }
    }

    /// The system owns the audio session under PushToTalk. Resume the graph
    /// here rather than rebuilding it, so no format negotiation lands between
    /// the press and the microphone.
    nonisolated public func channelManager(
        _ channelManager: PTChannelManager,
        didActivate audioSession: AVAudioSession
    ) {
        Task { @MainActor in session.handleSystemAudioSessionActivated() }
    }

    nonisolated public func channelManager(
        _ channelManager: PTChannelManager,
        didDeactivate audioSession: AVAudioSession
    ) {
        Task { @MainActor in session.handleSystemAudioSessionDeactivated() }
    }

    /// The system's own talk button — lock screen and the blue banner — routes
    /// through here. It must do exactly what the in-app button does and nothing
    /// more.
    nonisolated public func channelManager(
        _ channelManager: PTChannelManager,
        channelUUID: UUID,
        didBeginTransmittingFrom source: PTChannelTransmitRequestSource
    ) {
        Task { @MainActor in session.startTalking() }
    }

    nonisolated public func channelManager(
        _ channelManager: PTChannelManager,
        channelUUID: UUID,
        didEndTransmittingFrom source: PTChannelTransmitRequestSource
    ) {
        Task { @MainActor in session.stopTalking() }
    }

    nonisolated public func channelManager(
        _ channelManager: PTChannelManager,
        receivedEphemeralPushToken pushToken: Data
    ) {
        Task { @MainActor in
            await session.registerPushToTalk(apnsToken: pushToken, channelUUID: Self.channelUUID)
        }
    }

    /// A remote speaker started. The server's payload carries the speaker and
    /// the transmission, and the socket has to come back before any of that
    /// audio can arrive — so rejoin here, every time.
    nonisolated public func incomingPushResult(
        channelManager: PTChannelManager,
        channelUUID: UUID,
        pushPayload: [String: Any]
    ) -> PTPushResult {
        Task { @MainActor in await session.join() }
        let speakerName = (pushPayload["speakerName"] as? String)
            ?? (pushPayload["activeSpeaker"] as? String)
            ?? "Telsiz"
        return .activeRemoteParticipant(PTParticipant(name: speakerName, image: nil))
    }
}

// MARK: - PTChannelRestorationDelegate

extension RadioPushToTalkManager: PTChannelRestorationDelegate {
    nonisolated public func channelDescriptor(restoredChannelUUID channelUUID: UUID) -> PTChannelDescriptor {
        PTChannelDescriptor(name: "Telsiz", image: nil)
    }
}
