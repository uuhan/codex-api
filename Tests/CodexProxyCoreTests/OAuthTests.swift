import XCTest
@testable import CodexProxyCore

final class OAuthTests: XCTestCase {
    func testBeginLoginBuildsCodexOAuthURL() throws {
        let service = CodexOAuthService()
        let url = try service.beginLogin(redirectURI: "http://localhost:1455/auth/callback")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "auth.openai.com")
        XCTAssertEqual(components.path, "/oauth/authorize")
        XCTAssertEqual(items["client_id"], CodexOAuthService.clientID)
        XCTAssertEqual(items["response_type"], "code")
        XCTAssertEqual(items["redirect_uri"], "http://localhost:1455/auth/callback")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["codex_cli_simplified_flow"], "true")
        XCTAssertFalse((items["state"] ?? "").isEmpty)
        XCTAssertFalse((items["code_challenge"] ?? "").isEmpty)
    }

    func testParseIDTokenExtractsAccountAndEmail() throws {
        let service = CodexOAuthService()
        let payload: JSONObject = [
            "email": "user@example.com",
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "acc_123",
                "chatgpt_plan_type": "plus"
            ]
        ]
        let token = [
            base64URL(Data(#"{"alg":"none"}"#.utf8)),
            base64URL(try JSONHelper.data(payload)),
            "sig"
        ].joined(separator: ".")

        let parsed = service.parseIDToken(token)
        XCTAssertEqual(parsed.accountID, "acc_123")
        XCTAssertEqual(parsed.email, "user@example.com")
        XCTAssertEqual(parsed.planType, "plus")
    }

    private func base64URL(_ data: Data) -> String {
        data
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
