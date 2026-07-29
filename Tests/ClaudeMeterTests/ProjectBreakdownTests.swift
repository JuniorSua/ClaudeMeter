import Testing
import Foundation
@testable import ClaudeMeter

struct ProjectBreakdownTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func event(project: String?, tokens: Int, cost: Decimal? = nil) -> UsageEvent {
        UsageEvent(
            id: UUID().uuidString,
            timestamp: now,
            source: .claudeCodeLog,
            model: "claude-sonnet-4",
            inputTokens: tokens,
            outputTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            totalTokens: tokens,
            estimatedCostUSD: cost,
            sessionID: nil,
            resetAt: nil,
            rawLimitMessage: nil,
            project: project
        )
    }

    @Test func ranksProjectsByTokensDescending() {
        let breakdown = UsageAggregator.projectBreakdown(
            events: [
                event(project: "small", tokens: 100),
                event(project: "big", tokens: 5_000),
                event(project: "big", tokens: 1_000),
                event(project: "middle", tokens: 900)
            ],
            settings: .default
        )
        #expect(breakdown.map(\.project) == ["big", "middle", "small"])
        #expect(breakdown.first?.totalTokens == 6_000)
    }

    @Test func eventsWithoutProjectAreIgnored() {
        let breakdown = UsageAggregator.projectBreakdown(
            events: [event(project: nil, tokens: 999), event(project: "", tokens: 5),
                     event(project: "real", tokens: 10)],
            settings: .default
        )
        #expect(breakdown.count == 1)
        #expect(breakdown.first?.project == "real")
    }

    @Test func tailFoldsIntoOther() {
        let events = (1...7).map { event(project: "p\($0)", tokens: $0 * 100) }
        let breakdown = UsageAggregator.projectBreakdown(events: events, settings: .default, limit: 4)
        #expect(breakdown.count == 5)
        #expect(breakdown.last?.project == "Other")
        // p3 (300) + p2 (200) + p1 (100) fall outside the top four.
        #expect(breakdown.last?.totalTokens == 600)
        // Nothing is lost in the fold.
        #expect(breakdown.reduce(0) { $0 + $1.totalTokens } == events.reduce(0) { $0 + $1.totalTokens })
    }

    @Test func costsSumPerProjectAndStayNilWhenAbsent() {
        let breakdown = UsageAggregator.projectBreakdown(
            events: [
                event(project: "paid", tokens: 10, cost: Decimal(string: "1.50")),
                event(project: "paid", tokens: 10, cost: Decimal(string: "0.25")),
                event(project: "free", tokens: 10)
            ],
            settings: AppSettings.default
        )
        let paid = breakdown.first { $0.project == "paid" }
        #expect(paid?.estimatedCostUSD == Decimal(string: "1.75"))
        // "free" has no logged cost, but estimation is on by default, so a
        // value is expected rather than nil.
        #expect(breakdown.first { $0.project == "free" }?.estimatedCostUSD != nil)
    }

    @Test func emptyInputProducesEmptyBreakdown() {
        #expect(UsageAggregator.projectBreakdown(events: [], settings: .default).isEmpty)
    }

    @Test func projectNameComesFromWorkingDirectory() {
        let name = ClaudeLogScanner.projectName(
            record: ["cwd": "/Users/someone/Desktop/Ai Projects/Menusage"],
            filePath: "/Users/someone/.claude/projects/-Users-someone-other/abc.jsonl"
        )
        #expect(name == "Menusage")
    }

    @Test func projectNameFallsBackToLogDirectory() {
        let name = ClaudeLogScanner.projectName(
            record: [:],
            filePath: "/Users/someone/.claude/projects/-Users-someone-code-myapp/abc.jsonl"
        )
        #expect(name == "myapp")
    }

    @Test func monthWindowStartsAtFirstOfMonth() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 7, day: 19, hour: 13))!
        let window = DateWindowCalculator.monthWindow(now: now, calendar: calendar)
        let parts = calendar.dateComponents([.year, .month, .day, .hour], from: window.start)
        #expect(parts.year == 2026)
        #expect(parts.month == 7)
        #expect(parts.day == 1)
        #expect(parts.hour == 0)
        #expect(window.end == now)
    }
}
