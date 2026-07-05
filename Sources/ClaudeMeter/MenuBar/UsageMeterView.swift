import AppKit

/// Shared meter color logic for the menu bar meter and popover meter.
enum MeterColor {
    static func nsColor(for percentage: Double) -> NSColor {
        switch percentage {
        case ..<60: return .systemGreen
        case ..<80: return .systemYellow
        case ..<95: return .systemOrange
        default: return .systemRed
        }
    }
}
