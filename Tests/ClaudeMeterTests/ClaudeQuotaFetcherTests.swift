import Testing
import Foundation
@testable import ClaudeMeter

struct ClaudeQuotaFetcherTests {

    // Synthetic fixture matching the shape of Anthropic's usage endpoint
    // response. Values are made up; they exercise session, weekly-all, and a
    // model-scoped weekly limit (with the active-limit flag).
    static let apiFixture = #"""
    {
        "five_hour": {"utilization": 42.0, "resets_at": "2030-01-02T02:40:00.443745+00:00",
                      "limit_dollars": null, "used_dollars": null, "remaining_dollars": null},
        "seven_day": {"utilization": 63.0, "resets_at": "2030-01-05T15:00:00.443772+00:00",
                      "limit_dollars": null, "used_dollars": null, "remaining_dollars": null},
        "seven_day_oauth_apps": null,
        "seven_day_opus": null,
        "seven_day_sonnet": null,
        "extra_usage": {"is_enabled": false, "monthly_limit": null},
        "limits": [
            {"kind": "session", "group": "session", "percent": 42, "severity": "normal",
             "resets_at": "2030-01-02T02:40:00.344313+00:00", "scope": null, "is_active": false},
            {"kind": "weekly_all", "group": "weekly", "percent": 63, "severity": "normal",
             "resets_at": "2030-01-05T15:00:00.344334+00:00", "scope": null, "is_active": false},
            {"kind": "weekly_scoped", "group": "weekly", "percent": 71, "severity": "normal",
             "resets_at": "2030-01-05T15:00:00.344640+00:00",
             "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null},
             "is_active": true}
        ]
    }
    """#

    @Test func parsesLimitsArray() throws {
        let quota = try #require(ClaudeQuotaFetcher.parse(data: Data(Self.apiFixture.utf8)))
        #expect(quota.limits.count == 3)

        let session = try #require(quota.session)
        #expect(session.percent == 42)
        #expect(session.resetsAt != nil)
        #expect(!session.isActive)

        let weekly = try #require(quota.limits.first { $0.kind == "weekly_all" })
        #expect(weekly.percent == 63)

        let scoped = try #require(quota.limits.first { $0.kind == "weekly_scoped" })
        #expect(scoped.percent == 71)
        #expect(scoped.scopeName == "Fable")
        #expect(scoped.isActive)
        #expect(scoped.label == "Weekly · Fable")
    }

    @Test func fallsBackToTopLevelBucketsWithoutLimitsArray() throws {
        let json = #"{"five_hour":{"utilization":42.5,"resets_at":"2026-07-06T02:40:00+00:00"},"seven_day":{"utilization":7.0,"resets_at":"2026-07-09T15:00:00+00:00"}}"#
        let quota = try #require(ClaudeQuotaFetcher.parse(data: Data(json.utf8)))
        #expect(quota.limits.count == 2)
        #expect(quota.session?.percent == 42.5)
    }

    @Test func unparseableDataReturnsNil() {
        #expect(ClaudeQuotaFetcher.parse(data: Data("not json".utf8)) == nil)
        #expect(ClaudeQuotaFetcher.parse(data: Data("{}".utf8)) == nil)
    }

    @Test func officialQuotaDrivesQuotaSnapshot() throws {
        let quota = try #require(ClaudeQuotaFetcher.parse(data: Data(Self.apiFixture.utf8)))
        let snapshot = UsageAggregator.makeSnapshot(events: [], settings: .default, now: Date(), officialQuota: quota)
        #expect(snapshot.quota.percentageUsed == 42)
        #expect(snapshot.quota.quotaSource == .official)
        #expect(snapshot.quota.confidence == .high)
        #expect(snapshot.quota.resetAt != nil)
        #expect(snapshot.officialQuota?.limits.count == 3)
    }

    @Test func withoutOfficialQuotaBehaviorUnchanged() {
        let snapshot = UsageAggregator.makeSnapshot(events: [], settings: .default, now: Date(), officialQuota: nil)
        #expect(snapshot.quota.percentageUsed == nil)
        #expect(snapshot.quota.quotaSource == .unavailable)
    }

    @Test func stackedMenuBarDisplayFromOfficialQuota() throws {
        let quota = try #require(ClaudeQuotaFetcher.parse(data: Data(Self.apiFixture.utf8)))
        let snapshot = UsageAggregator.makeSnapshot(events: [], settings: .default, now: Date(), officialQuota: quota)
        let stacked = try #require(MenuBarFormatter.stackedDisplay(snapshot: snapshot))
        #expect(stacked.topText == "42%")     // session
        #expect(stacked.bottomText == "63%")  // weekly all models
    }

    @Test func noStackedDisplayWithoutOfficialQuota() {
        let snapshot = UsageAggregator.makeSnapshot(events: [], settings: .default, now: Date(), officialQuota: nil)
        #expect(MenuBarFormatter.stackedDisplay(snapshot: snapshot) == nil)
    }

    @Test func settingsWithoutOfficialKeyDefaultsOn() throws {
        var legacy = AppSettings.default
        legacy.useOfficialUsage = nil
        // Encoding nil omits the key — decoding it back must default to enabled.
        let data = try JSONEncoder().encode(legacy)
        #expect(!String(data: data, encoding: .utf8)!.contains("useOfficialUsage"))
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.officialUsageEnabled)
    }
}
