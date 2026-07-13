import SwiftUI
import AppKit

// MARK: - Palette

/// Categorical slots from the validated reference palette (light and dark
/// steps validated as ordered sets — worst adjacent CVD ΔE 24.2 light /
/// 10.3 dark). Keep the slot order fixed; identity is reinforced by the
/// legend labels and 2px segment gaps, never color alone.
enum Viz {
    static let series: [Color] = [
        dynamic(light: 0x2A78D6, dark: 0x3987E5),   // blue
        dynamic(light: 0x1BAF7A, dark: 0x199E70),   // aqua
        dynamic(light: 0xEDA100, dark: 0xC98500),   // yellow
        dynamic(light: 0x008300, dark: 0x008300)    // green
    ]

    /// Sequential hue (blue step 450/400) for single-series magnitude marks.
    static let sequential = dynamic(light: 0x2A78D6, dark: 0x3987E5)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

// MARK: - Composition bar (part-to-whole)

struct TokenSegment: Identifiable {
    let label: String
    let value: Int
    let color: Color
    var id: String { label }
}

/// A window's token mix as segments in fixed categorical order. Zero-value
/// segments are kept for the legend but drawn with no width.
func tokenSegments(_ window: UsageWindowSnapshot) -> [TokenSegment] {
    [
        TokenSegment(label: "Input", value: window.inputTokens, color: Viz.series[0]),
        TokenSegment(label: "Output", value: window.outputTokens, color: Viz.series[1]),
        TokenSegment(label: "Cache Write", value: window.cacheCreationTokens, color: Viz.series[2]),
        TokenSegment(label: "Cache Read", value: window.cacheReadTokens, color: Viz.series[3])
    ]
}

/// Thin horizontal stacked bar: 2px surface gaps between segments, 4px
/// rounded outer ends, quiet track when empty.
struct CompositionBar: View {
    let segments: [TokenSegment]

    var body: some View {
        GeometryReader { geo in
            let visible = segments.filter { $0.value > 0 }
            let total = visible.reduce(0) { $0 + $1.value }
            if total > 0 {
                HStack(spacing: 2) {
                    ForEach(visible) { segment in
                        Rectangle()
                            .fill(segment.color)
                            .frame(width: max(3, (geo.size.width - CGFloat(visible.count - 1) * 2) * CGFloat(segment.value) / CGFloat(total)))
                            .help("\(segment.label): \(HumanFormatters.tokensExact(segment.value)) tokens")
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: .tertiaryLabelColor).opacity(0.25))
            }
        }
        .frame(height: 8)
    }
}

/// Two-column legend with exact values — the required relief for the two
/// low-contrast slots, and the detail layer behind the bar.
struct CompositionLegend: View {
    let segments: [TokenSegment]

    private let columns = [
        GridItem(.flexible(), alignment: .leading),
        GridItem(.flexible(), alignment: .leading)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
            ForEach(segments) { segment in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(segment.value > 0 ? segment.color : Color(nsColor: .tertiaryLabelColor).opacity(0.4))
                        .frame(width: 8, height: 8)
                    Text(segment.label)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 2)
                    Text(HumanFormatters.tokens(segment.value))
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(segment.value > 0 ? .primary : .tertiary)
                }
                .help("\(segment.label): \(HumanFormatters.tokensExact(segment.value)) tokens")
            }
        }
    }
}

// MARK: - Daily trend (change over time, single series)

/// Seven thin columns, one hue; today is emphasized and carries the only
/// direct label. Weekday initials under the baseline, hairline baseline,
/// no gridlines — the popover is too small for chart chrome.
struct DailyTrendChart: View {
    let days: [DailyUsage]

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEEE")
        return f
    }()

    var body: some View {
        let peak = max(1, days.map(\.totalTokens).max() ?? 1)
        VStack(spacing: 3) {
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(days) { day in
                    let isToday = Calendar.current.isDateInToday(day.date)
                    VStack(spacing: 2) {
                        if isToday {
                            Text(HumanFormatters.tokens(day.totalTokens))
                                .font(.system(size: 9, weight: .semibold))
                                .monospacedDigit()
                                .fixedSize()
                        }
                        UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3)
                            .fill(Viz.sequential.opacity(isToday ? 1 : 0.45))
                            .frame(height: max(2, 44 * CGFloat(day.totalTokens) / CGFloat(peak)))
                    }
                    .frame(maxWidth: .infinity, alignment: .bottom)
                    .help("\(day.date.formatted(date: .abbreviated, time: .omitted)): \(HumanFormatters.tokensExact(day.totalTokens)) tokens")
                }
            }
            .frame(height: 60, alignment: .bottom)
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
            HStack(spacing: 6) {
                ForEach(days) { day in
                    Text(Self.weekdayFormatter.string(from: day.date))
                        .font(.system(size: 9))
                        .foregroundStyle(Calendar.current.isDateInToday(day.date) ? .secondary : .tertiary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}
