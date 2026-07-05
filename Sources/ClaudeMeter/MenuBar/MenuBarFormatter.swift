import Foundation

/// Builds the compact menu bar text for a snapshot + display mode.
enum MenuBarFormatter {
    static let symbol = "◆"

    struct Display {
        let text: String
        let percentage: Double?
    }

    /// Two tiny stacked percentages: session on top, weekly below.
    struct StackedDisplay: Equatable {
        let topText: String
        let topPercent: Double
        let bottomText: String
        let bottomPercent: Double
    }

    /// Compact stacked layout used when official account data is available.
    static func stackedDisplay(snapshot: UsageSnapshot?) -> StackedDisplay? {
        guard let official = snapshot?.officialQuota,
              let session = official.session,
              let weekly = official.limits.first(where: { $0.kind == "weekly_all" }) else {
            return nil
        }
        return StackedDisplay(
            topText: HumanFormatters.percent(session.percent),
            topPercent: session.percent,
            bottomText: HumanFormatters.percent(weekly.percent),
            bottomPercent: weekly.percent
        )
    }

    static func display(snapshot: UsageSnapshot?, settings: AppSettings, mode overrideMode: DisplayMode? = nil) -> Display {
        guard let snapshot else {
            return Display(text: "\(symbol) …", percentage: nil)
        }

        var percentage = snapshot.quota.percentageUsed
        if settings.hidePercentageWhenConfidenceLow,
           snapshot.quota.confidence == .low {
            percentage = nil
        }

        let pct = percentage.map { HumanFormatters.percent($0) }
        let day = "D\(HumanFormatters.tokens(snapshot.today.totalTokens))"
        let week = "W\(HumanFormatters.tokens(snapshot.week.totalTokens))"

        let requested = overrideMode ?? settings.displayMode
        let mode = requested == .auto ? DisplayMode.full : requested
        let text: String
        switch mode {
        case .full, .auto:
            text = pct.map { "\(symbol) \($0) \(day) \(week)" } ?? "\(symbol) \(day) \(week)"
        case .compact:
            text = pct.map { "\(symbol) \($0) \(week)" } ?? "\(symbol) \(week)"
        case .ultraCompact:
            text = pct.map { "\(symbol)\($0)" } ?? symbol
        }
        return Display(text: text, percentage: percentage)
    }
}
