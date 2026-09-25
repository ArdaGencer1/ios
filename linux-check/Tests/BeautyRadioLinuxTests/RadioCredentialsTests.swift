import XCTest
@testable import BeautyRadio

/// Decides whether the app renews its 4-hour token before using it. Getting
/// this wrong costs the first press after a reboot.
final class RadioCredentialsTests: XCTestCase {

    private func token(expiringIn seconds: TimeInterval) -> String {
        let claims = ["exp": Int(Date().addingTimeInterval(seconds).timeIntervalSince1970)]
        let payload = try! JSONSerialization.data(withJSONObject: claims)
        let base64url = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(base64url).signature"
    }

    func testMissingOrUnreadableTokensAreRefreshed() {
        XCTAssertTrue(RadioCredentials.tokenNeedsRefresh(nil))
        XCTAssertTrue(RadioCredentials.tokenNeedsRefresh(""))
        XCTAssertTrue(RadioCredentials.tokenNeedsRefresh("not-a-jwt"))
        XCTAssertTrue(RadioCredentials.tokenNeedsRefresh("header.!!!not-base64!!!.sig"))
        XCTAssertTrue(RadioCredentials.tokenNeedsRefresh("header.\(Data("{}".utf8).base64EncodedString()).sig"),
                      "a payload with no exp claim")
    }

    func testFreshTokenIsKeptAndLapsingOneIsRenewedEarly() {
        XCTAssertFalse(RadioCredentials.tokenNeedsRefresh(token(expiringIn: 3 * 3600)))
        XCTAssertTrue(RadioCredentials.tokenNeedsRefresh(token(expiringIn: 5 * 60)))
        XCTAssertTrue(RadioCredentials.tokenNeedsRefresh(token(expiringIn: -60)), "already expired")
        // The margin is what makes it renew early rather than on failure.
        XCTAssertFalse(RadioCredentials.tokenNeedsRefresh(token(expiringIn: 20 * 60), margin: 15 * 60))
        XCTAssertTrue(RadioCredentials.tokenNeedsRefresh(token(expiringIn: 20 * 60), margin: 30 * 60))
    }
}
