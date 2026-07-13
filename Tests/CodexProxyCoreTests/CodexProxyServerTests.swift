import XCTest
@testable import CodexProxyCore

final class CodexProxyServerTests: XCTestCase {
    func testRequiredModelAcceptsNonEmptyModel() throws {
        XCTAssertEqual(
            try CodexProxyServer.requiredModel(in: ["model": " gpt-5.6-terra "]),
            "gpt-5.6-terra"
        )
    }

    func testRequiredModelRejectsMissingOrBlankModel() {
        for payload: JSONObject in [[:], ["model": "   "]] {
            XCTAssertThrowsError(try CodexProxyServer.requiredModel(in: payload)) { error in
                XCTAssertEqual((error as? ProxyError)?.description, "model is required")
            }
        }
    }
}
