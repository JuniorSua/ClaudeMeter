import Testing
import Foundation
@testable import ClaudeMeter

struct DateWindowCalculatorTests {
    let calendar = Calendar.current

    @Test func todayWindowStartsAtLocalMidnight() {
        let now = Date()
        let window = DateWindowCalculator.todayWindow(now: now, calendar: calendar)
        #expect(window.start == calendar.startOfDay(for: now))
        #expect(window.end == now)
    }

    @Test func weekWindowMondayStart() {
        let now = Date()
        let window = DateWindowCalculator.weekWindow(now: now, calendar: calendar, weekStartsOn: .monday)
        #expect(calendar.component(.weekday, from: window.start) == 2) // Monday
        #expect(window.start <= now)
        #expect(window.end == now)
    }

    @Test func weekWindowSundayStart() {
        let now = Date()
        let window = DateWindowCalculator.weekWindow(now: now, calendar: calendar, weekStartsOn: .sunday)
        #expect(calendar.component(.weekday, from: window.start) == 1) // Sunday
    }

    @Test func shortWindowRollingDefault() {
        var settings = AppSettings.default
        settings.shortWindowMode = .autoDetect
        let now = Date()
        let (interval, resetAt, source) = DateWindowCalculator.shortWindow(now: now, settings: settings, detectedResetAt: nil)
        #expect(abs(interval.duration - 5 * 3600) < 1)
        #expect(resetAt == nil)
        #expect(source == .unknown)
    }

    @Test func shortWindowCustomLength() {
        var settings = AppSettings.default
        settings.shortWindowMode = .custom(minutes: 90)
        let now = Date()
        let (interval, resetAt, source) = DateWindowCalculator.shortWindow(now: now, settings: settings, detectedResetAt: nil)
        #expect(abs(interval.duration - 90 * 60) < 1)
        #expect(resetAt != nil)
        #expect(source == .manual)
    }

    @Test func shortWindowAnchorsToDetectedReset() {
        let settings = AppSettings.default
        let now = Date()
        let resetAt = now.addingTimeInterval(2 * 3600)
        let (interval, outReset, source) = DateWindowCalculator.shortWindow(now: now, settings: settings, detectedResetAt: resetAt)
        #expect(outReset == resetAt)
        #expect(source == .detectedFromClaudeCode)
        #expect(interval.end == resetAt)
        #expect(abs(interval.duration - TimeInterval(settings.shortWindowMinutes * 60)) < 1)
    }

    @Test func shortWindowIgnoresPastReset() {
        let settings = AppSettings.default
        let now = Date()
        let stale = now.addingTimeInterval(-3600)
        let (_, resetAt, source) = DateWindowCalculator.shortWindow(now: now, settings: settings, detectedResetAt: stale)
        #expect(resetAt == nil)
        #expect(source == .unknown)
    }
}
