import SwiftUI

/// The efficiency headline: one score out of 10, the grade that score earns,
/// the three components it's made of, and a plain-language brief.
///
/// The components are always shown — the score is a weighted mean of things the
/// reader can see and check, not an opaque rating.
struct EfficiencyCard: View {
    let efficiency: EfficiencySnapshot

    var body: some View {
        CardView(title: "Efficiency This Month") {
            scoreHeader
            EfficiencyMeter(score: efficiency.overall)
                .padding(.vertical, 1)
            componentRows
            Text(efficiency.brief)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            perTaskRow
            Text("Cost efficiency of token usage — not a measure of whether the work was correct.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var scoreHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(String(format: "%.1f", efficiency.overall))
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text("/ 10")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            // Icon + label, so the grade never rides on color alone.
            HStack(spacing: 3) {
                Image(systemName: efficiency.grade.symbolName)
                    .font(.system(size: 9, weight: .semibold))
                Text(efficiency.grade.label)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(EfficiencyPalette.color(for: efficiency.overall))
        }
    }

    @ViewBuilder
    private var componentRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let c = efficiency.cacheLeverage {
                ComponentRow(
                    label: "Cache leverage",
                    component: c,
                    detail: HumanFormatters.percent(c.measured * 100) + " of input from cache",
                    help: "Share of input-side tokens served from cache instead of full price. Industry practice flags anything under 85%."
                )
            }
            if let c = efficiency.outputShare {
                ComponentRow(
                    label: "Output share",
                    component: c,
                    detail: HumanFormatters.percent(c.measured * 100) + " of spend bought output",
                    help: "Fraction of spend that produced new output rather than re-reading context. Agentic coding runs context-heavy, so this band is calibrated for that."
                )
            }
            if let c = efficiency.cacheDiscipline {
                ComponentRow(
                    label: "Cache discipline",
                    component: c,
                    detail: String(format: "%.1f", c.measured) + "× reads per write",
                    help: "A cache write costs 1.25× and breaks even after about 2 reads. Low values mean paying to cache context that never gets reused."
                )
            }
        }
    }

    @ViewBuilder
    private var perTaskRow: some View {
        if let median = efficiency.medianSessionScore, efficiency.scoredSessionCount > 0 {
            Divider()
            HStack(spacing: 6) {
                Text("Per task")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("typical \(String(format: "%.1f", median))")
                    .font(.system(size: 10))
                    .monospacedDigit()
                if let worst = efficiency.worstSessionScore, efficiency.scoredSessionCount > 1 {
                    Text("· weakest \(String(format: "%.1f", worst))")
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .help("Median and lowest score across \(efficiency.scoredSessionCount) Claude Code session\(efficiency.scoredSessionCount == 1 ? "" : "s") this month")
        }
    }
}

/// One component: label, its own 0–10 bar, and the real measurement behind it.
private struct ComponentRow: View {
    let label: String
    let component: EfficiencyScore.Component
    let detail: String
    let help: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 11))
                Spacer(minLength: 4)
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Text(String(format: "%.1f", component.score))
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .frame(width: 24, alignment: .trailing)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(nsColor: .tertiaryLabelColor).opacity(0.25))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(EfficiencyPalette.color(for: component.score))
                        .frame(width: max(2, geo.size.width * component.score / 10))
                }
            }
            .frame(height: 4)
        }
        .help(help)
    }
}

/// The headline 0–10 meter: ten segments with a 2px gap, so the score reads as
/// a count of filled steps rather than a bar to be measured by eye.
private struct EfficiencyMeter: View {
    let score: Double

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<10, id: \.self) { index in
                // Partial fill on the segment the score lands in.
                let fill = min(max(score - Double(index), 0), 1)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(nsColor: .tertiaryLabelColor).opacity(0.25))
                    .overlay(alignment: .leading) {
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(EfficiencyPalette.color(for: score))
                                .frame(width: geo.size.width * fill)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 2))
            }
        }
        .frame(height: 7)
        .help("Weighted score across the components below")
    }
}

/// Score → color. Reuses the validated viz palette; every use is paired with a
/// number and a label, so color is never the only channel.
enum EfficiencyPalette {
    static func color(for score: Double) -> Color {
        switch score {
        case 8.5...: return Viz.series[3]      // green
        case 6.5..<8.5: return Viz.sequential  // blue
        case 4.5..<6.5: return Viz.series[2]   // yellow
        default: return Viz.statusWarning
        }
    }
}

/// Compact score badge for the model and project breakdown rows.
struct EfficiencyBadge: View {
    let score: Double

    var body: some View {
        Text(String(format: "%.1f", score))
            .font(.system(size: 9, weight: .semibold))
            .monospacedDigit()
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                Capsule().fill(EfficiencyPalette.color(for: score).opacity(0.18))
            )
            .overlay(
                Capsule().stroke(EfficiencyPalette.color(for: score).opacity(0.45), lineWidth: 0.5)
            )
            .help("Efficiency score \(String(format: "%.1f", score)) out of 10")
    }
}
