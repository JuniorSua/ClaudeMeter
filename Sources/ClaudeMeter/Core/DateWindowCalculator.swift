import Foundation

enum DateWindowCalculator {
    static func todayWindow(now: Date, calendar: Calendar = .current) -> DateInterval {
        DateInterval(start: calendar.startOfDay(for: now), end: now)
    }

    static func weekWindow(now: Date, calendar: Calendar = .current, weekStartsOn: WeekStartDay) -> DateInterval {
        var cal = calendar
        cal.firstWeekday = weekStartsOn == .sunday ? 1 : 2
        let interval = cal.dateInterval(of: .weekOfYear, for: now)
            ?? DateInterval(start: cal.startOfDay(for: now), end: now)
        return DateInterval(start: interval.start, end: now)
    }

    /// The current short usage window, plus how its boundary was determined.
    /// A detected reset timestamp anchors the window end; otherwise it is a
    /// rolling window ending now.
    static func shortWindow(
        now: Date,
        settings: AppSettings,
        detectedResetAt: Date?
    ) -> (interval: DateInterval, resetAt: Date?, source: ResetSource) {
        let length = TimeInterval(settings.shortWindowMinutes * 60)
        if let resetAt = detectedResetAt, resetAt > now, resetAt.timeIntervalSince(now) <= length {
            let start = resetAt.addingTimeInterval(-length)
            return (DateInterval(start: start, end: resetAt), resetAt, .detectedFromClaudeCode)
        }
        let start = now.addingTimeInterval(-length)
        let inferredReset = now.addingTimeInterval(length)
        switch settings.shortWindowMode {
        case .autoDetect:
            return (DateInterval(start: start, end: now), nil, .unknown)
        case .fourHours, .fiveHours, .custom:
            return (DateInterval(start: start, end: now), inferredReset, .manual)
        }
    }
}
