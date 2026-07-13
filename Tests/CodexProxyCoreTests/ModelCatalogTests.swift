import XCTest
@testable import CodexProxyCore

final class ModelCatalogTests: XCTestCase {
    func testDefaultModelsUseCurrentCodexCatalog() {
        let settings = ProxySettings()

        XCTAssertEqual(settings.defaultModelID, "gpt-5.6-terra")
        XCTAssertTrue(settings.effectiveModelIDs.contains("gpt-5.6-sol"))
        XCTAssertTrue(settings.effectiveModelIDs.contains("gpt-5.6-terra"))
        XCTAssertTrue(settings.effectiveModelIDs.contains("gpt-5.6-luna"))
        XCTAssertTrue(settings.effectiveModelIDs.contains("gpt-5.3-codex"))
        XCTAssertTrue(settings.effectiveModelIDs.contains("gpt-5.4"))
        XCTAssertTrue(settings.effectiveModelIDs.contains("gpt-5.5"))
        XCTAssertFalse(settings.effectiveModelIDs.contains("gpt-5-codex"))
        XCTAssertFalse(settings.effectiveModelIDs.contains("gpt-5.1-codex"))
    }

    func testLegacyDefaultModelsAreTreatedAsAutomatic() {
        let settings = ProxySettings(modelIDs: CodexModelCatalog.legacyDefaultModelIDs)

        XCTAssertTrue(settings.usesAutomaticModelCatalog)
        XCTAssertEqual(settings.effectiveModelIDs, CodexModelCatalog.defaultModelIDs)
    }

    func testPlanTypeControlsAutomaticCatalog() throws {
        let token = try idToken(planType: "free")
        let settings = ProxySettings(idToken: token, modelIDs: CodexModelCatalog.legacyDefaultModelIDs)

        XCTAssertEqual(settings.codexPlanType, "free")
        XCTAssertTrue(settings.effectiveModelIDs.contains("gpt-5.3-codex"))
        XCTAssertFalse(settings.effectiveModelIDs.contains("gpt-5.3-codex-spark"))
        XCTAssertFalse(settings.effectiveModelIDs.contains("gpt-5.5"))
    }

    func testCustomModelsArePreserved() {
        let settings = ProxySettings(modelIDs: ["custom-model"])

        XCTAssertFalse(settings.usesAutomaticModelCatalog)
        XCTAssertEqual(settings.effectiveModelIDs, ["custom-model"])
    }

    func testUpstreamModelsOnlyExposeAvailableAPIModels() throws {
        let payload: JSONObject = [
            "models": [
                [
                    "slug": "gpt-5.6-terra",
                    "display_name": "GPT-5.6-Terra",
                    "description": "Balanced agentic coding model for everyday work.",
                    "context_window": 272_000,
                    "supported_in_api": true,
                    "visibility": "list"
                ],
                [
                    "slug": "internal-model",
                    "supported_in_api": true,
                    "visibility": "hide"
                ],
                [
                    "slug": "unsupported-model",
                    "supported_in_api": false,
                    "visibility": "list"
                ]
            ]
        ]

        let models = try CodexModelCatalog.models(fromUpstream: payload)

        XCTAssertEqual(models.map(\.id), ["gpt-5.6-terra"])
        XCTAssertEqual(models.first?.displayName, "GPT-5.6-Terra")
        XCTAssertEqual(models.first?.contextLength, 272_000)
    }

    func testLegacyCodexFingerprintIsMigrated() throws {
        let payload = Data(#"{"defaultUserAgent":"codex_cli_rs/0.118.0 (Mac OS 26.3.1; arm64) iTerm.app/3.6.9","originator":"codex_cli_rs"}"#.utf8)

        let settings = try JSONDecoder().decode(ProxySettings.self, from: payload)

        XCTAssertEqual(settings.upstreamUserAgent, ProxySettings.codexUserAgent)
        XCTAssertEqual(settings.upstreamOriginator, ProxySettings.codexOriginator)
    }

    func testMissingConfiguredClientVersionUsesTheCurrentDefault() throws {
        let payload = Data(#"{"defaultUserAgent":"codex-tui/0.144.1 (Mac OS 26.5.0; arm64) iTerm.app/3.6.10 (codex-tui; 0.144.1)"}"#.utf8)

        let settings = try JSONDecoder().decode(ProxySettings.self, from: payload)

        XCTAssertEqual(settings.upstreamClientVersion, ProxySettings.defaultCodexClientVersion)
        XCTAssertEqual(settings.upstreamUserAgent, ProxySettings.codexUserAgent)
    }

    func testAnthropicModelObjectUsesAnthropicShape() {
        let model = CodexModelDescriptor(
            id: "gpt-5.5",
            created: 1_776_902_400,
            displayName: "GPT 5.5",
            version: "gpt-5.5"
        )

        let object = model.anthropicModelObject

        XCTAssertEqual(object["id"] as? String, "gpt-5.5")
        XCTAssertEqual(object["type"] as? String, "model")
        XCTAssertEqual(object["display_name"] as? String, "GPT 5.5")
        XCTAssertEqual(object["created_at"] as? String, "2026-04-23T00:00:00Z")
        XCTAssertNil(object["object"])
        XCTAssertNil(object["created"])
    }

    private func idToken(planType: String) throws -> String {
        let payload: JSONObject = [
            "email": "user@example.com",
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "acc_123",
                "chatgpt_plan_type": planType
            ]
        ]
        return [
            base64URL(Data(#"{"alg":"none"}"#.utf8)),
            base64URL(try JSONHelper.data(payload)),
            "sig"
        ].joined(separator: ".")
    }

    private func base64URL(_ data: Data) -> String {
        data
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
