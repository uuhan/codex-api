import Foundation
@testable import CodexProxyCore
import XCTest

final class UpstreamClientTests: XCTestCase {
    func testTransportErrorMessageClassifiesTLSErrors() {
        let message = UpstreamClient.transportErrorMessage(
            URLError(.secureConnectionFailed),
            url: URL(string: "https://chatgpt.com/backend-api/codex/responses")
        )

        XCTAssertTrue(message.hasPrefix("upstream TLS error connecting to chatgpt.com:"))
    }

    func testTransportErrorMessageClassifiesOtherNetworkErrors() {
        let message = UpstreamClient.transportErrorMessage(
            URLError(.cannotFindHost),
            url: URL(string: "https://example.invalid/responses")
        )

        XCTAssertTrue(message.hasPrefix("upstream network error connecting to example.invalid:"))
    }
}
