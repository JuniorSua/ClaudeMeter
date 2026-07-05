import Testing
import Foundation
@testable import ClaudeMeter

struct UsageAggregatorTests {

    private func event(
        id: String = UUID().uuidString,
        minutesAgo: Double,
        model: String = "claude-sonnet-4",
        input: Int,
        output: Int,
        now: Date
    ) -> UsageEvent {
        UsageEvent(
            id: id,
            timestamp: now.addingTimeInterval(-minutesAgo * 60),
            source: .claudeCodeLog,
            model: model,
            inputTokens: input,
            outputTokens: output,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            totalTokens: input + output,
            estimatedCostUSD: nil,
            sessionID: nil,
            resetAt: nil,
            rawLimitMessage: nil
        )
    }

    // Use noon so "minutes ago" stays within the same calendar day.
    private var noon: Date {
        Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
    }

    @Test func windowSums() {
        let now = noon
        let events = [
            event(minutesAgo: 10, input: 1000, output: 200, now: now),
            event(minutesAgo: 30, input: 500, output: 100, now: now)
        ]
        let snapshot = UsageAggregator.makeSnapshot(events: events, settings: .default, now: now)
        #expect(snapshot.today.inputTokens == 1500)
        #expect(snapshot.today.outputTokens == 300)
        #expect(snapshot.today.totalTokens == 1800)
        #expect(snapshot.today.eventCount == 2)
        #expect(snapshot.week.totalTokens >= snapshot.today.totalTokens)
        #expect(snapshot.currentWindow.totalTokens == 1800) // both within 5h window
    }

    @Test func quotaUnavailableWithoutBudget() {
        let now = noon
        let events = [event(minutesAgo: 5, input: 100, output: 10, now: now)]
        let snapshot = UsageAggregator.makeSnapshot(events: events, settings: .default, now: now)
        #expect(snapshot.quota.percentageUsed == nil)
        #expect(snapshot.quota.quotaSource == .unavailable)
        #expect(snapshot.quota.confidence == .unavailable)
    }

    @Test func quotaPercentageWithManualBudget() throws {
        let now = noon
        var settings = AppSettings.default
        settings.shortWindowTokenBudget = 2000
        let events = [event(minutesAgo: 5, input: 800, output: 200, now: now)]
        let snapshot = UsageAggregator.makeSnapshot(events: events, settings: settings, now: now)
        let pct = try #require(snapshot.quota.percentageUsed)
        #expect(abs(pct - 50.0) < 0.01)
        #expect(snapshot.quota.quotaSource == .manualCalibration)
        #expect(snapshot.quota.confidence == .medium)
    }

    @Test func dailyBudgetFallback() throws {
        let now = noon
        var settings = AppSettings.default
        settings.dailyTokenBudget = 10_000
        let events = [event(minutesAgo: 5, input: 2000, output: 500, now: now)]
        let snapshot = UsageAggregator.makeSnapshot(events: events, settings: settings, now: now)
        let pct = try #require(snapshot.quota.percentageUsed)
        #expect(abs(pct - 25.0) < 0.01)
    }

    @Test func modelBreakdownGroupsByFamily() {
        let now = noon
        let events = [
            event(minutesAgo: 5, model: "claude-sonnet-5", input: 800, output: 40, now: now),
            event(minutesAgo: 6, model: "claude-sonnet-4", input: 100, output: 20, now: now),
            event(minutesAgo: 7, model: "claude-opus-4-8", input: 50, output: 10, now: now)
        ]
        let snapshot = UsageAggregator.makeSnapshot(events: events, settings: .default, now: now)
        #expect(snapshot.modelBreakdown.count == 2)
        #expect(snapshot.modelBreakdown.first?.model == "Sonnet")
        #expect(snapshot.modelBreakdown.first?.totalTokens == 960)
        #expect(snapshot.modelBreakdown.last?.model == "Opus")
    }

    @Test func fableFamilyMatching() {
        #expect(PricingTable.family(for: "claude-fable-5") == .fable)
        #expect(PricingTable.family(for: "claude-mythos-5") == .fable)
        #expect(PricingTable.family(for: "claude-opus-4-8") == .opus)
    }

    @Test func fableCostEstimation() {
        let now = noon
        let events = [event(minutesAgo: 5, model: "claude-fable-5", input: 1_000_000, output: 0, now: now)]
        let snapshot = UsageAggregator.makeSnapshot(events: events, settings: .default, now: now)
        #expect(snapshot.currentWindow.estimatedCostUSD == Decimal(10))
    }

    @Test func pricingTableDecodesLegacyJSONWithoutFableKey() throws {
        // Settings persisted before the fable row existed lack the key.
        let row = #"{"inputPerMTok":2,"outputPerMTok":8,"cacheWritePerMTok":2.5,"cacheReadPerMTok":0.2}"#
        let legacyJSON = #"{"opus":\#(row),"sonnet":\#(row),"haiku":\#(row),"fallback":\#(row)}"#
        let decoded = try JSONDecoder().decode(PricingTable.self, from: Data(legacyJSON.utf8))
        #expect(decoded.fable == PricingTable.default.fable)
        #expect(decoded.sonnet.inputPerMTok == 2)
        #expect(decoded.sonnet.outputPerMTok == 8)
    }

    @Test func costEstimationFromPricingTable() {
        let now = noon
        let events = [event(minutesAgo: 5, model: "claude-sonnet-4", input: 1_000_000, output: 0, now: now)]
        let snapshot = UsageAggregator.makeSnapshot(events: events, settings: .default, now: now)
        #expect(snapshot.currentWindow.estimatedCostUSD == Decimal(3))
    }

    @Test func unknownModelNoCostWithoutFallback() {
        let now = noon
        let events = [event(minutesAgo: 5, model: "mystery-model", input: 1_000_000, output: 0, now: now)]
        let snapshot = UsageAggregator.makeSnapshot(events: events, settings: .default, now: now)
        #expect(snapshot.currentWindow.estimatedCostUSD == nil)

        var settings = AppSettings.default
        settings.enableFallbackPricingForUnknownModels = true
        let withFallback = UsageAggregator.makeSnapshot(events: events, settings: settings, now: now)
        #expect(withFallback.currentWindow.estimatedCostUSD == Decimal(3))
    }

    @Test func loggedCostPreferred() {
        let now = noon
        let logged = UsageEvent(
            id: "c1", timestamp: now.addingTimeInterval(-60), source: .claudeCodeLog,
            model: "claude-sonnet-4", inputTokens: 1_000_000, outputTokens: 0,
            cacheCreationTokens: 0, cacheReadTokens: 0, totalTokens: 1_000_000,
            estimatedCostUSD: Decimal(string: "9.99"), sessionID: nil, resetAt: nil, rawLimitMessage: nil
        )
        let snapshot = UsageAggregator.makeSnapshot(events: [logged], settings: .default, now: now)
        #expect(snapshot.currentWindow.estimatedCostUSD == Decimal(string: "9.99"))
    }

    @Test func emptyEventsWarns() {
        let snapshot = UsageAggregator.makeSnapshot(events: [], settings: .default, now: noon)
        #expect(snapshot.warnings.contains("No Claude Code usage found"))
    }

    @Test func detectedResetSurfacesInQuota() {
        let now = noon
        let resetAt = now.addingTimeInterval(90 * 60)
        let limitEvent = UsageEvent(
            id: "l1", timestamp: now.addingTimeInterval(-60), source: .claudeCodeLog,
            model: nil, inputTokens: 0, outputTokens: 0,
            cacheCreationTokens: 0, cacheReadTokens: 0, totalTokens: 0,
            estimatedCostUSD: nil, sessionID: nil, resetAt: resetAt, rawLimitMessage: "Usage limit reached"
        )
        let snapshot = UsageAggregator.makeSnapshot(events: [limitEvent], settings: .default, now: now)
        #expect(snapshot.quota.resetAt == resetAt)
        #expect(snapshot.quota.resetSource == .detectedFromClaudeCode)
        // Still no fake percentage.
        #expect(snapshot.quota.percentageUsed == nil)
    }
}
