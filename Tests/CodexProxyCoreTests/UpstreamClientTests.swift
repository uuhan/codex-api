import Foundation
@testable import CodexProxyCore
import XCTest

final class UpstreamClientTests: XCTestCase {
    func testUpstreamRequestUsesCurrentCodexFingerprint() throws {
        let request = HTTPRequest(
            method: "POST",
            target: "/v1/responses",
            path: "/v1/responses",
            query: nil,
            version: "HTTP/1.1",
            headers: [
                "authorization": "Bearer incoming-token",
                "user-agent": "claude-cli/2.1.0",
                "originator": "claude-cli"
            ],
            body: Data()
        )

        let upstream = try UpstreamClient().makeRequest(
            settings: ProxySettings(authToken: "upstream-token"),
            request: request,
            path: "/responses",
            body: [:],
            stream: false
        )

        XCTAssertEqual(upstream.value(forHTTPHeaderField: "User-Agent"), ProxySettings.codexUserAgent)
        XCTAssertEqual(upstream.value(forHTTPHeaderField: "Originator"), ProxySettings.codexOriginator)
    }

    func testModelsRequestFetchesWithCurrentCodexVersion() throws {
        let request = HTTPRequest(
            method: "GET",
            target: "/v1/models",
            path: "/v1/models",
            query: nil,
            version: "HTTP/1.1",
            headers: ["authorization": "Bearer incoming-token"],
            body: Data()
        )

        let upstream = try UpstreamClient().makeModelsRequest(
            settings: ProxySettings(authToken: "upstream-token"),
            request: request
        )

        XCTAssertEqual(
            upstream.url?.absoluteString,
            "https://chatgpt.com/backend-api/codex/models?client_version=0.144.1"
        )
        XCTAssertEqual(upstream.value(forHTTPHeaderField: "User-Agent"), ProxySettings.codexUserAgent)
        XCTAssertEqual(upstream.value(forHTTPHeaderField: "Originator"), ProxySettings.codexOriginator)
    }

    func testModelsRequestUsesConfiguredCodexVersion() throws {
        let request = HTTPRequest(
            method: "GET",
            target: "/v1/models",
            path: "/v1/models",
            query: nil,
            version: "HTTP/1.1",
            headers: ["authorization": "Bearer incoming-token"],
            body: Data()
        )
        let settings = ProxySettings(authToken: "upstream-token", codexClientVersion: "0.150.0")

        let upstream = try UpstreamClient().makeModelsRequest(settings: settings, request: request)

        XCTAssertEqual(
            upstream.url?.absoluteString,
            "https://chatgpt.com/backend-api/codex/models?client_version=0.150.0"
        )
        XCTAssertEqual(
            upstream.value(forHTTPHeaderField: "User-Agent"),
            "codex-tui/0.150.0 (Mac OS 26.5.0; arm64) iTerm.app/3.6.10 (codex-tui; 0.150.0)"
        )
    }

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
