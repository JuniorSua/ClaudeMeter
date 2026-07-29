import Testing
import Foundation
@testable import ClaudeMeter

struct QuotaPaceTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// Session windows are 5h, so 1h in (4h to reset) is 20% elapsed.
    private func sessionPace(percent: Double, hoursToReset: Double) -> QuotaPace? {
        QuotaPace.evaluate(
            percent: percent,
            kind: "session",
            resetsAt: now.addingTimeInterval(hoursToReset * 3600),
            now: now
        )
    }

    @Test func steadyBurnProjectsToFullWindow() {
        // 20% used with 20% of the window elapsed → ~100% by reset.
        let pace = sessionPace(percent: 20, hoursToReset: 4)
        #expect(pace != nil)
        #expect(abs((pace?.projectedPercentAtReset ?? 0) - 100) < 0.001)
    }

    @Test func fastBurnWarnsBeforeReset() {
        // Half the quota in a fifth of the window: cap arrives early.
        let pace = sessionPace(percent: 50, hoursToReset: 4)
        #expect(pace?.verdict == .aheadOfPace)
        #expect(pace?.timeToCap != nil)
        // 50% remaining at 50%/hour → one more hour.
        #expect(abs((pace?.timeToCap ?? 0) - 3600) < 1)
    }

    @Test func slowBurnIsComfortable() {
        // 5% used with 80% of the window gone → nowhere near the cap.
        let pace = sessionPace(percent: 5, hoursToReset: 1)
        #expect(pace?.verdict == .comfortable)
        #expect((pace?.projectedPercentAtReset ?? 100) < 10)
        #expect(pace?.timeToCap == nil)
    }

    @Test func nearCapButSlowingIsOnTrack() {
        // 85% used with 90% of the window gone: projected ~94%, no cap hit.
        let pace = sessionPace(percent: 85, hoursToReset: 0.5)
        #expect(pace?.verdict == .onTrack)
        #expect(pace?.timeToCap == nil)
    }

    @Test func exhaustedReportsReset() {
        let pace = sessionPace(percent: 100, hoursToReset: 2)
        #expect(pace?.verdict == .exhausted)
        #expect(pace?.timeToCap == 0)
    }

    @Test func tooEarlyInWindowStaysSilent() {
        // Only a minute elapsed — any rate would look absurd.
        #expect(sessionPace(percent: 3, hoursToReset: 4.99) == nil)
    }

    @Test func requiresResetTimeAndKnownWindow() {
        #expect(QuotaPace.evaluate(percent: 40, kind: "session", resetsAt: nil, now: now) == nil)
        #expect(QuotaPace.evaluate(
            percent: 40, kind: "mystery_kind",
            resetsAt: now.addingTimeInterval(3600), now: now
        ) == nil)
    }

    @Test func pastResetTimeStaysSilent() {
        #expect(sessionPace(percent: 40, hoursToReset: -1) == nil)
    }

    @Test func zeroUsageIsComfortable() {
        let pace = sessionPace(percent: 0, hoursToReset: 3)
        #expect(pace?.verdict == .comfortable)
        #expect(pace?.projectedPercentAtReset == 0)
    }

    @Test func weeklyWindowUsesSevenDays() {
        #expect(QuotaPace.windowLength(forKind: "weekly_all") == TimeInterval(604_800))
        #expect(QuotaPace.windowLength(forKind: "weekly_scoped") == TimeInterval(604_800))
        #expect(QuotaPace.windowLength(forKind: "session") == TimeInterval(18_000))
        // Half the week gone, 10% used → ~20% by reset: comfortable.
        let pace = QuotaPace.evaluate(
            percent: 10, kind: "weekly_all",
            resetsAt: now.addingTimeInterval(3.5 * 24 * 3600), now: now
        )
        #expect(pace?.verdict == .comfortable)
        #expect(abs((pace?.projectedPercentAtReset ?? 0) - 20) < 0.001)
    }
}
