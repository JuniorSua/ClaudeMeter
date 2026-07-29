import Testing
import Foundation
@testable import ClaudeMeter

struct EfficiencyScoreTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func event(
        model: String = "claude-opus-4-6",
        input: Int = 0,
        output: Int = 0,
        cacheWrite: Int = 0,
        cacheRead: Int = 0,
        session: String? = nil,
        project: String? = nil
    ) -> UsageEvent {
        UsageEvent(
            id: UUID().uuidString,
            timestamp: now,
            source: .claudeCodeLog,
            model: model,
            inputTokens: input,
            outputTokens: output,
            cacheCreationTokens: cacheWrite,
            cacheReadTokens: cacheRead,
            totalTokens: input + output + cacheWrite + cacheRead,
            estimatedCostUSD: nil,
            sessionID: session,
            resetAt: nil,
            rawLimitMessage: nil,
            project: project
        )
    }

    /// Estimation on, no logged costs — so scores come from the price table.
    private var settings: AppSettings { .default }

    // MARK: - Component curves

    @Test func cacheLeverageAnchors() {
        // Published industry threshold: 85% hit rate is the alert line.
        #expect(EfficiencyScore.cacheLeverageScore(hitRate: 0.85) == 7.0)
        #expect(EfficiencyScore.cacheLeverageScore(hitRate: 0) == 0)
        #expect(EfficiencyScore.cacheLeverageScore(hitRate: 0.50) == 3.0)
        #expect(EfficiencyScore.cacheLeverageScore(hitRate: 0.97) == 10)
        // Clamped above the top anchor.
        #expect(EfficiencyScore.cacheLeverageScore(hitRate: 1.0) == 10)
        // Monotonic between anchors.
        #expect(EfficiencyScore.cacheLeverageScore(hitRate: 0.90)
                > EfficiencyScore.cacheLeverageScore(hitRate: 0.86))
    }

    @Test func cacheDisciplineBreaksEvenAtTwoReads() {
        // A write costs 1.25x input and pays off after ~2 reads.
        #expect(EfficiencyScore.cacheDisciplineScore(readsPerWrite: 2) == 5.0)
        #expect(EfficiencyScore.cacheDisciplineScore(readsPerWrite: 0) == 0)
        #expect(EfficiencyScore.cacheDisciplineScore(readsPerWrite: 12) == 10)
        #expect(EfficiencyScore.cacheDisciplineScore(readsPerWrite: 40) == 10)
        #expect(EfficiencyScore.cacheDisciplineScore(readsPerWrite: 1) < 5.0)
    }

    @Test func outputShareBand() {
        #expect(EfficiencyScore.outputShareScore(share: 0) == 0)
        #expect(EfficiencyScore.outputShareScore(share: 0.03) == 2.0)
        #expect(EfficiencyScore.outputShareScore(share: 0.10) == 6.5)
        #expect(EfficiencyScore.outputShareScore(share: 0.20) == 10)
        #expect(EfficiencyScore.outputShareScore(share: 0.90) == 10)
    }

    // MARK: - Evaluation

    @Test func emptyInputScoresNothing() {
        #expect(EfficiencyScore.evaluate(events: [], settings: settings) == nil)
        // Events with no tokens at all carry no signal either.
        #expect(EfficiencyScore.evaluate(events: [event()], settings: settings) == nil)
    }

    @Test func heavilyCachedUsageScoresWell() {
        // Shape of a real Claude Code session: cache reads dominate.
        let score = EfficiencyScore.evaluate(
            events: [event(input: 300, output: 150_000, cacheWrite: 1_800_000, cacheRead: 45_000_000)],
            settings: settings
        )
        #expect(score != nil)
        // ~96% hit rate and 25 reads/write both score at or near the top.
        #expect((score?.cacheLeverage?.score ?? 0) > 9.5)
        #expect(score?.cacheDiscipline?.score == 10)
        #expect((score?.overall ?? 0) > 6.0)
    }

    @Test func uncachedUsageScoresPoorly() {
        // Everything billed fresh: no cache reads at all.
        let score = EfficiencyScore.evaluate(
            events: [event(input: 1_000_000, output: 10_000)],
            settings: settings
        )
        #expect(score?.cacheLeverage?.score == 0)
        // No writes means the discipline dimension is dropped, not zeroed.
        #expect(score?.cacheDiscipline == nil)
        #expect((score?.overall ?? 10) < 4.0)
        #expect(score?.grade == .needsAttention)
    }

    @Test func weightsRenormalizeWhenAComponentIsMissing() {
        // No cache writes → discipline drops out; the score must still be a
        // clean weighted mean of the two survivors, not diluted by a zero.
        let events = [event(input: 100_000, output: 50_000, cacheRead: 900_000)]
        let score = EfficiencyScore.evaluate(events: events, settings: settings)
        #expect(score?.cacheDiscipline == nil)
        guard let score, let leverage = score.cacheLeverage, let share = score.outputShare else {
            Issue.record("expected two measurable components")
            return
        }
        let expected = (leverage.score * leverage.weight + share.score * share.weight)
            / (leverage.weight + share.weight)
        #expect(abs(score.overall - expected) < 0.0001)
    }

    /// The point of normalizing output share by each model's own prices: a
    /// cheap and an expensive model used the *same way* must score the same.
    @Test func scoreMeasuresBehaviorNotModelPrice() {
        let shape = { (model: String) in
            [self.event(model: model, input: 1_000, output: 40_000,
                        cacheWrite: 200_000, cacheRead: 2_000_000)]
        }
        let haiku = EfficiencyScore.overallScore(events: shape("claude-haiku-4-5"), settings: settings)
        let opus = EfficiencyScore.overallScore(events: shape("claude-opus-4-6"), settings: settings)
        #expect(haiku != nil)
        #expect(abs((haiku ?? 0) - (opus ?? 0)) < 0.0001)
    }

    @Test func gradeBoundaries() {
        #expect(EfficiencyScore.Grade.forScore(9.0) == .excellent)
        #expect(EfficiencyScore.Grade.forScore(8.5) == .excellent)
        #expect(EfficiencyScore.Grade.forScore(7.0) == .good)
        #expect(EfficiencyScore.Grade.forScore(5.0) == .fair)
        #expect(EfficiencyScore.Grade.forScore(2.0) == .needsAttention)
        #expect(EfficiencyScore.Grade.forScore(0) == .needsAttention)
    }

    @Test func componentsCarryTheirRawMeasurement() {
        // The UI shows the measurement next to the score, so it must be the
        // real ratio rather than a rescaled value.
        let score = EfficiencyScore.evaluate(
            events: [event(input: 100_000, output: 1_000, cacheWrite: 100_000, cacheRead: 800_000)],
            settings: settings
        )
        #expect(abs((score?.cacheLeverage?.measured ?? 0) - 0.8) < 0.0001)
        #expect(abs((score?.cacheDiscipline?.measured ?? 0) - 8.0) < 0.0001)
    }

    // MARK: - Brief

    @Test func briefDescribesTheShapeOfSpend() {
        let high = EfficiencyScore.makeBrief(hitRate: 0.96, outputShare: 0.10, readsPerWrite: 25)
        #expect(high.contains("96%"))
        #expect(high.contains("mostly cached"))

        let low = EfficiencyScore.makeBrief(hitRate: 0.10, outputShare: 0.01, readsPerWrite: 0.5)
        #expect(low.contains("full price"))

        // Never returns an empty or dangling sentence.
        #expect(EfficiencyScore.makeBrief(hitRate: nil, outputShare: nil, readsPerWrite: nil).isEmpty == false)
        #expect(EfficiencyScore.makeBrief(hitRate: nil, outputShare: nil, readsPerWrite: 3.0).contains("3.0"))
    }

    // MARK: - Aggregator integration

    @Test func perSessionScoringIgnoresTinySessions() {
        // Below the 10k-token floor a session's ratios are noise.
        let events = [
            event(output: 100, cacheRead: 500, session: "tiny"),
        ] + (0..<3).map { _ in
            event(input: 1_000, output: 20_000, cacheWrite: 100_000, cacheRead: 1_000_000, session: "real")
        }
        let snapshot = UsageAggregator.efficiencySnapshot(events: events, settings: settings)
        #expect(snapshot?.scoredSessionCount == 1)
        #expect(snapshot?.medianSessionScore != nil)
    }

    /// A one- or two-turn session cannot have reused cache yet, so scoring it
    /// would report session length as if it were inefficiency.
    @Test func perSessionScoringSkipsSessionsTooShortForCacheReuse() {
        let shortButLarge = (0..<2).map { _ in
            event(input: 500, output: 2_000, cacheWrite: 20_000, session: "brief")
        }
        let snapshot = UsageAggregator.efficiencySnapshot(events: shortButLarge, settings: settings)
        // The month still scores (pooled), but no session qualifies.
        #expect(snapshot != nil)
        #expect(snapshot?.scoredSessionCount == 0)
        #expect(snapshot?.medianSessionScore == nil)
        #expect(snapshot?.worstSessionScore == nil)
    }

    @Test func medianPicksMiddleValue() {
        #expect(UsageAggregator.median([]) == nil)
        #expect(UsageAggregator.median([5.0]) == 5.0)
        #expect(UsageAggregator.median([1.0, 3.0, 8.0]) == 3.0)
        // Even count averages the two middles.
        #expect(UsageAggregator.median([1.0, 3.0, 5.0, 9.0]) == 4.0)
    }

    @Test func modelAndProjectBreakdownsCarryScores() {
        let events = [
            event(model: "claude-opus-4-6", input: 500, output: 30_000,
                  cacheWrite: 150_000, cacheRead: 3_000_000, project: "alpha"),
            event(model: "claude-haiku-4-5", input: 500, output: 5_000,
                  cacheWrite: 50_000, cacheRead: 100_000, project: "beta"),
        ]
        let models = UsageAggregator.modelBreakdown(events: events, settings: settings)
        #expect(models.allSatisfy { $0.efficiency != nil })
        let projects = UsageAggregator.projectBreakdown(events: events, settings: settings)
        #expect(projects.allSatisfy { $0.efficiency != nil })
        // The better-cached project should outscore the other.
        let alpha = projects.first { $0.project == "alpha" }?.efficiency ?? 0
        let beta = projects.first { $0.project == "beta" }?.efficiency ?? 0
        #expect(alpha > beta)
    }
}
