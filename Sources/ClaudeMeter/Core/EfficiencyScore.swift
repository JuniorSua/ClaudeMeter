import Foundation

/// How cost-efficiently the account is being used, scored 0–10.
///
/// This measures the *cost efficiency of token usage* — it deliberately does
/// not claim to measure whether the work was any good, because nothing in the
/// local logs reveals whether a task succeeded.
///
/// Three components, each computed from real per-model prices (never a proxy
/// unit — the pricing table already has the exact multipliers):
///
/// 1. **Cache leverage** — share of input-side tokens served from cache rather
///    than re-billed at full price. Industry alerts below an 85% hit rate,
///    which anchors this band.
/// 2. **Cache discipline** — cache reads per write. A write costs 1.25× input
///    and only pays off after ~2 reads, so this catches paying the write
///    premium for context that is never reused — invisible to hit rate alone.
/// 3. **Output share** — fraction of spend that bought produced output rather
///    than re-sent context. The industry's output-to-input ratio expressed in
///    dollars. Its band is *our* calibration (see `outputShareScore`), because
///    published guidance says healthy ratios vary by task type.
struct EfficiencyScore: Equatable {
    /// One scored dimension, carrying both the score and the raw measurement
    /// behind it so the UI can always show the reader where a number came from.
    struct Component: Codable, Equatable {
        let score: Double       // 0–10
        let measured: Double    // the underlying ratio (0–1 for shares)
        let weight: Double
    }

    enum Grade: String, Codable, Equatable {
        case excellent, good, fair, needsAttention

        var label: String {
            switch self {
            case .excellent: return "Excellent"
            case .good: return "Good"
            case .fair: return "Fair"
            case .needsAttention: return "Needs attention"
            }
        }

        /// Paired with the label everywhere it appears, so the grade never
        /// depends on color alone.
        var symbolName: String {
            switch self {
            case .excellent: return "checkmark.seal.fill"
            case .good: return "checkmark.circle"
            case .fair: return "gauge.medium"
            case .needsAttention: return "exclamationmark.triangle.fill"
            }
        }

        static func forScore(_ score: Double) -> Grade {
            switch score {
            case 8.5...: return .excellent
            case 6.5..<8.5: return .good
            case 4.5..<6.5: return .fair
            default: return .needsAttention
            }
        }
    }

    let overall: Double
    let cacheLeverage: Component?
    let cacheDiscipline: Component?
    let outputShare: Component?
    let grade: Grade
    /// One plain-language sentence over the same numbers.
    let brief: String

    // MARK: - Weights

    private static let cacheLeverageWeight = 0.40
    private static let cacheDisciplineWeight = 0.20
    private static let outputShareWeight = 0.40

    // MARK: - Component curves

    /// Cache hit rate → 0–10, anchored on the published 85% alert threshold.
    /// 0% → 0, 50% → 3, 85% → 7, 97%+ → 10.
    static func cacheLeverageScore(hitRate: Double) -> Double {
        interpolate(hitRate, points: [(0, 0), (0.50, 3), (0.85, 7), (0.97, 10)])
    }

    /// Cache reads per write → 0–10. Break-even is ~2 reads (a write costs
    /// 1.25× input, a read 0.1×), which anchors the midpoint.
    /// 0 → 0, 2 → 5 (break-even), 12+ → 10.
    static func cacheDisciplineScore(readsPerWrite: Double) -> Double {
        interpolate(readsPerWrite, points: [(0, 0), (2, 5), (6, 8), (12, 10)])
    }

    /// Share of spend that bought output → 0–10.
    ///
    /// **This band is our calibration, not an industry figure.** Published
    /// guidance explicitly says healthy output-to-input ratios vary by task
    /// type; agentic coding is inherently context-heavy, and a real Claude Code
    /// session measures ~10%. The band reflects that reality:
    /// 0% → 0, 3% → 2, 10% → 6.5, 20%+ → 10.
    static func outputShareScore(share: Double) -> Double {
        interpolate(share, points: [(0, 0), (0.03, 2), (0.10, 6.5), (0.20, 10)])
    }

    /// Piecewise-linear interpolation over an ascending set of anchor points,
    /// clamped at both ends.
    private static func interpolate(_ x: Double, points: [(x: Double, y: Double)]) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if x <= first.x { return first.y }
        if x >= last.x { return last.y }
        for (lower, upper) in zip(points, points.dropFirst()) where x <= upper.x {
            let span = upper.x - lower.x
            guard span > 0 else { return upper.y }
            return lower.y + (upper.y - lower.y) * (x - lower.x) / span
        }
        return last.y
    }

    // MARK: - Evaluation

    /// Scores a set of events. Nil when there is nothing meaningful to score,
    /// so the UI can hide the card rather than display a fabricated number.
    ///
    /// Any component whose denominator is missing (no cache writes, no priced
    /// events) is dropped and the remaining weights renormalize — a score is
    /// never invented from absent data.
    static func evaluate(events: [UsageEvent], settings: AppSettings) -> EfficiencyScore? {
        var input = 0, output = 0, cacheWrite = 0, cacheRead = 0
        var totalCost: Decimal = 0
        var outputCost: Decimal = 0
        var pricedEvents = 0

        for event in events {
            input += event.inputTokens
            output += event.outputTokens
            cacheWrite += event.cacheCreationTokens
            cacheRead += event.cacheReadTokens

            // Output-share needs the output portion isolated, which logged
            // costs don't break out — so it always uses the price table,
            // while total spend honors the user's cost settings.
            if let pricing = settings.pricing.pricing(
                for: event.model,
                allowFallback: settings.enableFallbackPricingForUnknownModels
            ) {
                outputCost += Decimal(event.outputTokens) * pricing.outputPerMTok / 1_000_000
                pricedEvents += 1
            }
            if let cost = UsageAggregator.eventCost(event, settings: settings) {
                totalCost += cost
            }
        }

        let inputSide = input + cacheWrite + cacheRead
        guard inputSide > 0 || output > 0 else { return nil }

        let leverage: Component? = inputSide > 0
            ? Component(
                score: cacheLeverageScore(hitRate: Double(cacheRead) / Double(inputSide)),
                measured: Double(cacheRead) / Double(inputSide),
                weight: cacheLeverageWeight)
            : nil

        // No writes at all means nothing to amortize — not a failure, so the
        // dimension is dropped rather than scored zero.
        let discipline: Component? = cacheWrite > 0
            ? Component(
                score: cacheDisciplineScore(readsPerWrite: Double(cacheRead) / Double(cacheWrite)),
                measured: Double(cacheRead) / Double(cacheWrite),
                weight: cacheDisciplineWeight)
            : nil

        let share: Component? = {
            guard pricedEvents > 0, totalCost > 0 else { return nil }
            let value = (outputCost / totalCost).doubleValue
            return Component(
                score: outputShareScore(share: value),
                measured: value,
                weight: outputShareWeight)
        }()

        let components = [leverage, discipline, share].compactMap { $0 }
        guard !components.isEmpty else { return nil }

        // Renormalize over whichever dimensions were measurable.
        let weightSum = components.reduce(0) { $0 + $1.weight }
        let overall = components.reduce(0.0) { $0 + $1.score * $1.weight } / weightSum

        return EfficiencyScore(
            overall: overall,
            cacheLeverage: leverage,
            cacheDiscipline: discipline,
            outputShare: share,
            grade: Grade.forScore(overall),
            brief: makeBrief(
                hitRate: leverage?.measured,
                outputShare: share?.measured,
                readsPerWrite: discipline?.measured
            )
        )
    }

    /// Convenience for the breakdown rows, which only need the number.
    static func overallScore(events: [UsageEvent], settings: AppSettings) -> Double? {
        evaluate(events: events, settings: settings)?.overall
    }

    // MARK: - Token brief

    /// A plain-language read on the input/output balance — the shape of the
    /// spend, not another exact count (those already live in the range card).
    static func makeBrief(hitRate: Double?, outputShare: Double?, readsPerWrite: Double?) -> String {
        var parts: [String] = []

        if let hitRate {
            let pct = Int((hitRate * 100).rounded())
            switch hitRate {
            case 0.85...:
                parts.append("Context is mostly cached — \(pct)% of input came from cache instead of full price")
            case 0.5..<0.85:
                parts.append("\(pct)% of input came from cache; the rest was billed fresh")
            default:
                parts.append("Only \(pct)% of input came from cache — most context is being re-billed at full price")
            }
        }

        if let outputShare {
            let pct = outputShare * 100
            let phrasing: String
            switch pct {
            case 15...: phrasing = "a healthy \(Int(pct.rounded()))% of spend bought new output"
            case 7..<15: phrasing = "about \(Int(pct.rounded()))% of spend bought new output, typical for agentic coding"
            default: phrasing = "only \(String(format: "%.1f", pct))% of spend bought new output — the rest went to reading context"
            }
            parts.append(phrasing)
        }

        if parts.isEmpty, let readsPerWrite {
            parts.append("Each cached block was read \(String(format: "%.1f", readsPerWrite)) times on average")
        }
        return parts.isEmpty ? "Not enough usage yet to judge efficiency." : parts.joined(separator: ", and ") + "."
    }
}

private extension Decimal {
    var doubleValue: Double { NSDecimalNumber(decimal: self).doubleValue }
}
