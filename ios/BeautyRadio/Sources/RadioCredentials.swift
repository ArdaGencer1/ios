import Foundation
import Security

/// Persistent identity for the radio.
///
/// A restart of the backend does not invalidate anything stored here. The staff
/// JWT is stateless HS256, so it stays valid until it expires on its own, and
/// the device-bound radio token is a row in PostgreSQL that survives restarts.
/// Keeping both in the Keychain is what lets the app come back up and rejoin
/// the channel without showing a login screen.
///
/// `installationId` identifies this install for the lifetime of the app. The
/// server uses it to decide whose microphone a mixed frame must exclude, so it
/// has to be stable across launches and distinct per device — two devices that
/// reported the same id would each be cut out of the other's audio.
// No stored state: every accessor reads or writes the Keychain.
public struct RadioCredentials: Sendable {

    private enum Key: String {
        case staffToken = "com.rootbeauty.radio.staffToken"
        case refreshToken = "com.rootbeauty.radio.refreshToken"
        case deviceToken = "com.rootbeauty.radio.deviceToken"
        case installationId = "com.rootbeauty.radio.installationId"
        case channel = "com.rootbeauty.radio.channel"
    }

    public static let shared = RadioCredentials()
    private init() {}

    /// Issued by `POST /api/staff/login` as `data.token`.
    public var staffToken: String? {
        get { read(.staffToken) }
        nonmutating set { write(.staffToken, newValue) }
    }

    /// Issued by `POST /api/staff/login` (with `client: "ios"`) as
    /// `data.refreshToken`. Long-lived and revocable: it is exchanged at
    /// `POST /api/staff/refresh` for a new 4-hour staff JWT, which is what keeps
    /// the app signed in across reboots and backend restarts. It is not rotated
    /// on use, so the app and its embedded web panel can safely share it.
    public var refreshToken: String? {
        get { read(.refreshToken) }
        nonmutating set { write(.refreshToken, newValue) }
    }

    /// Issued by `PUT /api/radio/push-registration` as `radioAccessToken`, sent
    /// back as the `X-Radio-Device-Token` header. This is what keeps the radio
    /// reachable after the staff JWT expires.
    public var deviceToken: String? {
        get { read(.deviceToken) }
        nonmutating set { write(.deviceToken, newValue) }
    }

    public var channel: String {
        get { read(.channel) ?? "genel" }
        nonmutating set { write(.channel, newValue) }
    }

    public var installationId: String {
        if let existing = read(.installationId) { return existing }
        let created = UUID().uuidString.lowercased()
        write(.installationId, created)
        return created
    }

    public var isLoggedIn: Bool { staffToken != nil || refreshToken != nil || deviceToken != nil }

    /// True when the stored JWT is missing or within `margin` of its expiry.
    public func staffTokenNeedsRefresh(margin: TimeInterval = 15 * 60) -> Bool {
        Self.tokenNeedsRefresh(staffToken, margin: margin)
    }

    /// Reads the `exp` claim without verifying it — the server still verifies.
    /// Anything unreadable counts as needing a refresh: this decision only
    /// chooses whether to renew early, and renewing needlessly is harmless
    /// while skipping a renewal costs the first press after a reboot.
    static func tokenNeedsRefresh(_ token: String?, margin: TimeInterval = 15 * 60) -> Bool {
        guard let token else { return true }
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return true }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = claims["exp"] as? TimeInterval else { return true }
        return exp - Date().timeIntervalSince1970 < margin
    }

    public func clearLogin() {
        // The installation id deliberately survives a logout: it identifies the
        // device, not the session.
        write(.staffToken, nil)
        write(.refreshToken, nil)
        write(.deviceToken, nil)
    }

    // MARK: - Keychain

    private func query(_ key: Key) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue,
            // The radio must be able to reconnect after an APNs wake-up while
            // the phone is still locked, so this cannot be a "WhenUnlocked" item.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
    }

    private func read(_ key: Key) -> String? {
        var lookup = query(key)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    private func write(_ key: Key, _ value: String?) {
        let base = query(key)
        SecItemDelete(base as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var insert = base
        insert[kSecValueData as String] = data
        SecItemAdd(insert as CFDictionary, nil)
    }
}
