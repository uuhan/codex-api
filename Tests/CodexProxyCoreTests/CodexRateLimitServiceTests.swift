import XCTest
@testable import CodexProxyCore

final class CodexRateLimitServiceTests: XCTestCase {
    func testRateLimitURLUsesChatGPTUsageEndpointForBackendAPIBase() {
        XCTAssertEqual(
            CodexRateLimitService.rateLimitsURL(for: "https://chatgpt.com/backend-api/codex"),
            "https://chatgpt.com/backend-api/wham/usage"
        )
        XCTAssertEqual(
            CodexRateLimitService.rateLimitsURL(for: "https://chatgpt.com/backend-api/"),
            "https://chatgpt.com/backend-api/wham/usage"
        )
    }

    func testRateLimitURLUsesCodexUsageEndpointForCodexAPIBase() {
        XCTAssertEqual(
            CodexRateLimitService.rateLimitsURL(for: "https://example.com"),
            "https://example.com/api/codex/usage"
        )
        XCTAssertEqual(
            CodexRateLimitService.rateLimitsURL(for: "https://example.com/api/codex"),
            "https://example.com/api/codex/usage"
        )
    }

    func testSnapshotsParsePrimarySecondaryAndAdditionalLimits() throws {
        let payload = try JSONHelper.object(from: Data(#"""
        {
          "plan_type": "pro",
          "rate_limit_reached_type": { "type": "workspace_member_usage_limit_reached" },
          "rate_limit": {
            "primary_window": {
              "used_percent": 42,
              "limit_window_seconds": 18000,
              "reset_after_seconds": 600,
              "reset_at": 1800000000
            },
            "secondary_window": {
              "used_percent": 73.5,
              "limit_window_seconds": 604800,
              "reset_after_seconds": 86400,
              "reset_at": 1800600000
            }
          },
          "additional_rate_limits": [
            {
              "limit_name": "Review",
              "metered_feature": "codex_review",
              "rate_limit": {
                "primary_window": {
                  "used_percent": "10",
                  "limit_window_seconds": "3600",
                  "reset_after_seconds": "120",
                  "reset_at": "1800000120"
                }
              }
            }
          ]
        }
        """#.utf8))

        let limits = CodexRateLimitService.snapshots(from: payload)

        XCTAssertEqual(limits.count, 2)
        XCTAssertEqual(limits[0].limitID, "codex")
        XCTAssertEqual(limits[0].planType, "pro")
        XCTAssertEqual(limits[0].rateLimitReachedType, "workspace_member_usage_limit_reached")
        XCTAssertEqual(limits[0].primary?.usedPercent, 42.0)
        XCTAssertEqual(limits[0].primary?.remainingPercent, 58.0)
        XCTAssertEqual(limits[0].primary?.windowDurationMinutes, 300)
        XCTAssertEqual(limits[0].primary?.resetAfterSeconds, 600)
        XCTAssertEqual(limits[0].primary?.resetsAt?.timeIntervalSince1970, 1_800_000_000.0)
        XCTAssertEqual(limits[0].secondary?.usedPercent, 73.5)
        XCTAssertEqual(limits[0].secondary?.remainingPercent, 26.5)
        XCTAssertEqual(limits[0].secondary?.windowDurationMinutes, 10_080)

        XCTAssertEqual(limits[1].limitID, "codex_review")
        XCTAssertEqual(limits[1].limitName, "Review")
        XCTAssertEqual(limits[1].primary?.usedPercent, 10.0)
        XCTAssertEqual(limits[1].primary?.windowDurationMinutes, 60)
    }
}
