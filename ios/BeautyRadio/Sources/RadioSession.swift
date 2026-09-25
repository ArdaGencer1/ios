import Foundation
import Combine

/// Everything the UI talks to.
///
/// The whole design goal is that pressing the talk button does nothing but set
/// a flag. Login, push registration, the socket and the audio engine are all
/// brought up when the channel is opened, so the press itself has no work left
/// to do.
@MainActor
public final class RadioSession: ObservableObject {

    @Published public private(set) var isJoined = false
    @Published public private(set) var isTransmitting = false
    @Published public private(set) var speakers: [String] = []
    @Published public private(set) var outputRoute = ""
    @Published public private(set) var lastError: String?

    public let baseURL: URL
    private let credentials = RadioCredentials.shared
    // Both synchronise internally, so the client's delegate callbacks can reach
    // them straight from the network queue without hopping to the main actor.
    private nonisolated let audio = RadioAudioEngine()
    private nonisolated let client: RadioClient

    public init(baseURL: URL) {
        self.baseURL = baseURL
        self.client = RadioClient(baseURL: baseURL)
        self.client.delegate = self
        self.audio.onCapturedFrame = { [weak self] frame in
            self?.client.send(pcm: frame)
        }
        self.audio.onRouteChanged = { [weak self] route in
            Task { @MainActor in self?.outputRoute = route }
        }
        self.client.credentialRefresher = { [weak self] in
            guard let self else { return false }
            return await self.refreshStaffToken()
        }
    }

    public var isLoggedIn: Bool { credentials.isLoggedIn }

    // MARK: - Login

    /// `POST /api/staff/login` returns `{ success, data: { token, user } }`.
    /// The token is a stateless JWT, so it keeps working across backend
    /// restarts and is stored in the Keychain for the next launch.
    public func logIn(identifier: String, password: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/staff/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "identifier": identifier,
            "password": password,
            // Asks the server for the refresh token in the body; browsers only
            // ever get it as an HttpOnly cookie.
            "client": "ios"
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw RadioSessionError.loginFailed(String(data: data, encoding: .utf8) ?? "")
        }
        guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = body["data"] as? [String: Any],
              let token = payload["token"] as? String else {
            throw RadioSessionError.loginFailed("token yok")
        }
        credentials.staffToken = token
        credentials.refreshToken = payload["refreshToken"] as? String
    }

    /// Exchanges the stored refresh token for a new 4-hour staff JWT. Returns
    /// false only when the server rejected the refresh token itself (logged out
    /// elsewhere, password changed, account disabled); a network failure keeps
    /// the session and is retried later.
    @discardableResult
    public func refreshStaffToken() async -> Bool {
        guard let refreshToken = credentials.refreshToken else { return false }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/staff/refresh"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["refreshToken": refreshToken])

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        if http.statusCode == 401 {
            credentials.clearLogin()
            sessionEnded = true
            return false
        }
        guard http.statusCode == 200,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = body["data"] as? [String: Any],
              let token = payload["token"] as? String else { return false }
        credentials.staffToken = token
        return true
    }

    /// Set when the server has ended the session for good, so the UI can go
    /// back to the login screen.
    @Published public private(set) var sessionEnded = false
    private var refreshTask: Task<Void, Never>?

    /// Keeps the 4-hour JWT fresh for as long as the app is alive.
    private func startPeriodicRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 60 * 1_000_000_000)
                guard let self else { return }
                if self.credentials.staffTokenNeedsRefresh(margin: 60 * 60) {
                    await self.refreshStaffToken()
                }
            }
        }
    }

    public func logOut() async {
        await leave()
        await deregisterPushToTalk()
        // Revoke the refresh token server-side so the device is really signed
        // out, then drop everything local.
        var request = URLRequest(url: baseURL.appendingPathComponent("api/staff/logout"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let refreshToken = credentials.refreshToken {
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["refreshToken": refreshToken])
        }
        _ = try? await URLSession.shared.data(for: request)
        refreshTask?.cancel()
        credentials.clearLogin()
    }

    // MARK: - Channel

    /// Called as soon as the app has a session, not when the user reaches the
    /// radio screen, so the first press is already on a live socket.
    public func join() async {
        guard credentials.isLoggedIn else { return }
        // After a reboot or a long idle period the JWT has lapsed; renew it
        // before the socket needs it rather than taking a 401 first.
        if credentials.staffTokenNeedsRefresh() {
            await refreshStaffToken()
        }
        startPeriodicRefresh()
        do {
            // Build the graph up front so a press has nothing left to set up.
            try audio.prepare()
            // Claim the session for the in-app path. When PushToTalk takes over
            // it hands the session back through the delegate below.
            try audio.activate()
            outputRoute = "hazır"
        } catch {
            lastError = "Ses motoru başlatılamadı: \(error.localizedDescription)"
        }
        client.connect()
    }

    public func leave() async {
        client.disconnect()
        audio.stop()
        isJoined = false
    }

    // MARK: - Talk

    /// Button down. No awaits, no network round trip, no audio session work:
    /// the engine has been running since `join()` and its pre-roll already
    /// holds the audio from just before this call.
    public func startTalking() {
        guard !isTransmitting else { return }
        isTransmitting = true
        // Identity first, then audio: the client establishes the stream
        // synchronously, so the pre-roll cannot arrive before it exists.
        client.beginTransmitting()
        audio.beginTransmitting()
    }

    /// The stop is deliberately not sent here. The engine keeps capturing for
    /// its tail window first, because the server stops accepting a
    /// transmission's audio once `ptt-stop` lands — sending both at once is
    /// what cut the last word off a quick phrase.
    public func stopTalking() {
        guard isTransmitting else { return }
        isTransmitting = false
        audio.endTransmitting { [weak self] in
            self?.client.endTransmitting()
        }
    }

    // MARK: - Push registration

    /// `PUT /api/radio/push-registration` exchanges the ephemeral APNs token for
    /// a device-bound `radioAccessToken`, which is what lets the radio rejoin
    /// after the staff JWT has expired.
    public func registerPushToTalk(apnsToken: Data, channelUUID: UUID) async {
        guard let staffToken = credentials.staffToken else { return }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/radio/push-registration"))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(staffToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "installationId": credentials.installationId,
            "channel": credentials.channel,
            "channelUUID": channelUUID.uuidString.lowercased(),
            "token": apnsToken.map { String(format: "%02x", $0) }.joined(),
            "environment": ApnsEnvironment.current,
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            "buildNumber": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        ])

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let payload = (body["data"] as? [String: Any]) ?? body
        if let deviceToken = payload["radioAccessToken"] as? String {
            credentials.deviceToken = deviceToken
        }
    }

    public func deregisterPushToTalk() async {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/radio/push-registration"))
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let staffToken = credentials.staffToken {
            request.setValue("Bearer \(staffToken)", forHTTPHeaderField: "Authorization")
        }
        if let deviceToken = credentials.deviceToken {
            request.setValue(deviceToken, forHTTPHeaderField: "X-Radio-Device-Token")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "installationId": credentials.installationId
        ])
        _ = try? await URLSession.shared.data(for: request)
    }

    /// Called from the PushToTalk delegate once the system has handed over the
    /// audio session. Never re-activates it — the system owns it here.
    public func handleSystemAudioSessionActivated() {
        do {
            try audio.resumeAfterSystemActivation()
        } catch {
            lastError = "Ses oturumu devralınamadı: \(error.localizedDescription)"
        }
    }

    /// The system reclaimed the session (a phone call, another PTT app). The
    /// graph stays built so the next activation costs nothing.
    public func handleSystemAudioSessionDeactivated() {
        audio.suspendAfterSystemDeactivation()
    }
}

extension RadioSession: RadioClientDelegate {
    nonisolated public func radioClient(_ client: RadioClient, didChangeState state: RadioClient.State) {
        Task { @MainActor in
            if case .joined = state { self.isJoined = true } else { self.isJoined = false }
        }
    }

    nonisolated public func radioClient(_ client: RadioClient, didReceiveMixedAudio pcm: Data) {
        audio.play(pcm: pcm)
    }

    nonisolated public func radioClient(_ client: RadioClient, didChangeSpeakers speakers: [String]) {
        Task { @MainActor in self.speakers = speakers }
    }

    nonisolated public func radioClient(_ client: RadioClient, didFail error: Error) {
        Task { @MainActor in self.lastError = error.localizedDescription }
    }
}

public enum RadioSessionError: LocalizedError {
    case loginFailed(String)

    public var errorDescription: String? {
        switch self {
        case .loginFailed(let detail): return "Giriş başarısız. \(detail)"
        }
    }
}

/// Which APNs gateway this build's push tokens belong to.
///
/// Deriving it from the `DEBUG` flag is wrong: a Release build signed with a
/// development profile carries sandbox tokens but would report production, and
/// every wake-up to it would fail. The signing profile is the source of truth.
/// App Store and TestFlight builds ship without `embedded.mobileprovision` and
/// always use production.
enum ApnsEnvironment {
    static let current: String = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let raw = try? Data(contentsOf: url),
              let text = String(data: raw, encoding: .isoLatin1),
              let start = text.range(of: "<?xml"),
              let end = text.range(of: "</plist>"),
              let plistData = String(text[start.lowerBound..<end.upperBound]).data(using: .isoLatin1),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let aps = entitlements["aps-environment"] as? String else {
            return "production"
        }
        return aps == "development" ? "sandbox" : "production"
    }()
}
