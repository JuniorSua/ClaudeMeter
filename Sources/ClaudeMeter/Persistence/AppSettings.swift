import Foundation

struct AppSettings: Codable, Equatable {
    var claudeDirectoryPath: String
    var refreshIntervalSeconds: Int
    var displayMode: DisplayMode
    var weekStartsOn: WeekStartDay

    var launchAtLogin: Bool

    var shortWindowMode: ShortWindowMode
    var customShortWindowMinutes: Int?

    var shortWindowTokenBudget: Int?
    var dailyTokenBudget: Int?
    var weeklyTokenBudget: Int?

    var hidePercentageWhenConfidenceLow: Bool

    var useLoggedCosts: Bool
    var estimateCostsWhenMissing: Bool
    var enableFallbackPricingForUnknownModels: Bool

    var pricing: PricingTable

    // Optional so settings persisted before this key existed decode as nil
    // (synthesized Codable uses decodeIfPresent for optionals) → default on.
    var useOfficialUsage: Bool?

    var officialUsageEnabled: Bool {
        get { useOfficialUsage ?? true }
        set { useOfficialUsage = newValue }
    }

    static let `default` = AppSettings(
        claudeDirectoryPath: "~/.claude",
        refreshIntervalSeconds: 60,
        displayMode: .auto,
        weekStartsOn: .monday,
        launchAtLogin: false,
        shortWindowMode: .autoDetect,
        customShortWindowMinutes: nil,
        shortWindowTokenBudget: nil,
        dailyTokenBudget: nil,
        weeklyTokenBudget: nil,
        hidePercentageWhenConfidenceLow: true,
        useLoggedCosts: true,
        estimateCostsWhenMissing: true,
        enableFallbackPricingForUnknownModels: false,
        pricing: .default,
        useOfficialUsage: true
    )

    /// Length of the short usage window in minutes, per the configured mode.
    var shortWindowMinutes: Int {
        switch shortWindowMode {
        case .autoDetect: return 300
        case .fourHours: return 240
        case .fiveHours: return 300
        case .custom(let minutes): return max(1, minutes)
        }
    }
}

enum DisplayMode: String, Codable, CaseIterable {
    case auto
    case full
    case compact
    case ultraCompact

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .full: return "Full"
        case .compact: return "Compact"
        case .ultraCompact: return "Ultra Compact"
        }
    }
}

enum WeekStartDay: String, Codable, CaseIterable {
    case sunday
    case monday

    var label: String { rawValue.capitalized }
}

enum ShortWindowMode: Codable, Equatable, Hashable {
    case autoDetect
    case fourHours
    case fiveHours
    case custom(minutes: Int)

    var label: String {
        switch self {
        case .autoDetect: return "Auto-detect"
        case .fourHours: return "4 hours"
        case .fiveHours: return "5 hours"
        case .custom: return "Custom"
        }
    }
}
