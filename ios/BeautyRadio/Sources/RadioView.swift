import SwiftUI
import UIKit

/// The talk screen.
///
/// Two rules here are requirements, not styling:
///
/// * The button is never disabled. The server mixes simultaneous speakers and
///   always reports `busy: false`, so "someone else is talking" is not a reason
///   to refuse a press. There is no busy state anywhere in this view.
/// * Nothing is animated on the press path and the haptic is dispatched after
///   transmitting has already started. A vibration that runs before the
///   microphone is what made the old build feel like it had to be waited out.
public struct RadioView: View {

    @ObservedObject private var session: RadioSession
    private let pushToTalk: RadioPushToTalkManager
    @State private var isPressed = false

    public init(session: RadioSession, pushToTalk: RadioPushToTalkManager) {
        self.session = session
        self.pushToTalk = pushToTalk
    }

    public var body: some View {
        VStack(spacing: 24) {
            header
            Spacer(minLength: 0)
            talkButton
            Text(isPressed ? "Konuşuyorsunuz" : "Konuşmak için basılı tutun")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            footer
        }
        .padding(24)
    }

    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(session.isJoined ? Color.green : Color.orange)
                    .frame(width: 10, height: 10)
                Text(session.isJoined ? "Telsiz bağlı" : "Bağlanıyor…")
                    .font(.headline)
            }
            if session.speakers.isEmpty {
                Text("Kanal sessiz").font(.subheadline).foregroundStyle(.secondary)
            } else {
                // Plural on purpose: everyone can talk at once.
                Text("Konuşan: \(session.speakers.joined(separator: ", "))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var talkButton: some View {
        ZStack {
            Circle()
                .fill(isPressed ? Color.red : Color.accentColor)
                .frame(width: 220, height: 220)
            VStack(spacing: 8) {
                Image(systemName: "mic.fill").font(.system(size: 64, weight: .bold))
                Text("KONUŞ").font(.title2.bold())
            }
            .foregroundStyle(.white)
        }
        // No implicit animation: the fill changes on the same frame as the press.
        .animation(nil, value: isPressed)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !isPressed else { return }
                    isPressed = true
                    // Transmit first.
                    pushToTalk.beginTransmitting()
                    // Then confirm, on another queue, where it cannot delay audio.
                    DispatchQueue.global(qos: .userInitiated).async {
                        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                    }
                }
                .onEnded { _ in
                    guard isPressed else { return }
                    isPressed = false
                    pushToTalk.stopTransmitting()
                }
        )
        .accessibilityLabel("Konuş")
        .accessibilityHint("Basılı tutarak konuşun")
    }

    private var footer: some View {
        VStack(spacing: 4) {
            if !session.outputRoute.isEmpty {
                Label(session.outputRoute, systemImage: "headphones")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let error = session.lastError {
                Text(error).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
            }
        }
    }
}
