import XCTest
@testable import CodexProxyCore

final class ModelCatalogTests: XCTestCase {
    func testDefaultModelsUseCurrentCodexCatalog() {
        let settings = ProxySettings()

        XCTAssertEqual(settings.defaultModelID, "gpt-5.3-codex")
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
