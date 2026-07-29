import Foundation

/// Answers the question a usage meter exists to answer: *at this rate, am I
/// going to run out before the window resets?*
///
/// Percent-used alone can't tell you that — 50% is fine four hours into a
/// five-hour window and alarming ten minutes in. Comparing burn rate against
/// the reset clock turns the raw number into something actionable.
struct QuotaPace: Equatable {
    enum Verdict: Equatable {
        case exhausted          // already at the cap
        case aheadOfPace        // projected to hit the cap before reset
        case onTrack            // projected to finish the window near the cap
        case comfortable        // plenty of headroom at this rate
    }

    let verdict: Verdict
    /// Usage projected for the moment the window resets, if the current rate
    /// holds (can exceed 100 — that is the warning case).
    let projectedPercentAtReset: Double
    /// Time from now until the cap is reached at this rate, when that lands
    /// before the reset.
    let timeToCap: TimeInterval?
    /// Short human-readable summary for the popover.
    let message: String

    /// Length of the window a limit covers. Session windows are the rolling
    /// 5 hours Claude uses; weekly limits span 7 days.
    static func windowLength(forKind kind: String) -> TimeInterval? {
        switch kind {
        case "session": return 5 * 3600
        case "weekly_all", "weekly_scoped": return 7 * 24 * 3600
        default: return nil
        }
    }

    /// Nil when there isn't enough of the window elapsed to say anything
    /// honest (the first few minutes make every rate look extreme), or when
    /// the limit carries no reset time.
    static func evaluate(
        percent: Double,
        kind: String,
        resetsAt: Date?,
        now: Date = Date(),
        minimumElapsed: TimeInterval = 300
    ) -> QuotaPace? {
        guard let windowLength = windowLength(forKind: kind),
              let resetsAt, resetsAt > now else { return nil }

        let remaining = min(resetsAt.timeIntervalSince(now), windowLength)
        let elapsed = windowLength - remaining
        guard elapsed >= minimumElapsed else { return nil }

        if percent >= 100 {
            return QuotaPace(
                verdict: .exhausted,
                projectedPercentAtReset: percent,
                timeToCap: 0,
                message: "Limit reached — frees up in \(HumanFormatters.duration(remaining))"
            )
        }
        guard percent > 0 else {
            return QuotaPace(
                verdict: .comfortable,
                projectedPercentAtReset: 0,
                timeToCap: nil,
                message: "No usage this window yet"
            )
        }

        let ratePerSecond = percent / elapsed
        let projected = min(ratePerSecond * windowLength, 9_999)
        let secondsToCap = (100 - percent) / ratePerSecond
        let hitsCapBeforeReset = secondsToCap < remaining

        let verdict: Verdict
        let message: String
        if hitsCapBeforeReset {
            verdict = .aheadOfPace
            // The reset countdown sits directly above this line, so naming the
            // time-to-cap is enough — no need to restate the reset.
            message = "On pace to cap out in \(HumanFormatters.duration(secondsToCap))"
        } else if projected >= 80 {
            verdict = .onTrack
            message = "On pace for about \(HumanFormatters.percent(projected)) by reset"
        } else {
            verdict = .comfortable
            message = "Comfortable — about \(HumanFormatters.percent(projected)) by reset at this rate"
        }
        return QuotaPace(
            verdict: verdict,
            projectedPercentAtReset: projected,
            timeToCap: hitsCapBeforeReset ? secondsToCap : nil,
            message: message
        )
    }

    /// Convenience for the popover: pace for the limit that is actually
    /// binding (the active one, else the highest percentage).
    static func evaluate(limit: OfficialQuota.Limit, now: Date = Date()) -> QuotaPace? {
        evaluate(percent: limit.percent, kind: limit.kind, resetsAt: limit.resetsAt, now: now)
    }
}
