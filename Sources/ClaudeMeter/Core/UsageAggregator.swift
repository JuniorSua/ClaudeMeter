import Foundation

enum UsageAggregator {
    static func makeSnapshot(
        events: [UsageEvent],
        settings: AppSettings,
        now: Date = Date(),
        officialQuota: OfficialQuota? = nil,
        officialWarning: String? = nil,
        extraWarnings: [String] = []
    ) -> UsageSnapshot {
        var warnings = extraWarnings

        // Latest detected reset that is still in the future.
        let detectedResetAt = events.compactMap(\.resetAt).filter { $0 > now }.max()

        let (shortInterval, resetAt, resetSource) = DateWindowCalculator.shortWindow(
            now: now, settings: settings, detectedResetAt: detectedResetAt
        )
        let todayInterval = DateWindowCalculator.todayWindow(now: now)
        let weekInterval = DateWindowCalculator.weekWindow(now: now, weekStartsOn: settings.weekStartsOn)

        let usageEvents = events.filter { $0.totalTokens > 0 || $0.estimatedCostUSD != nil }

        let currentWindow = windowSnapshot(events: usageEvents, interval: DateInterval(start: shortInterval.start, end: now), settings: settings)
        let today = windowSnapshot(events: usageEvents, interval: todayInterval, settings: settings)
        let week = windowSnapshot(events: usageEvents, interval: weekInterval, settings: settings)

        let breakdown = modelBreakdown(events: usageEvents.filter { weekInterval.start <= $0.timestamp && $0.timestamp <= now }, settings: settings)

        let quota: QuotaSnapshot
        if let official = officialQuota, let session = official.session {
            // Level 1: exact account data from Anthropic's usage endpoint.
            quota = QuotaSnapshot(
                percentageUsed: session.percent,
                resetAt: session.resetsAt,
                resetSource: .detectedFromClaudeCode,
                quotaSource: .official,
                confidence: .high
            )
        } else {
            quota = QuotaEstimator.quota(
                currentWindowTokens: currentWindow.totalTokens,
                todayTokens: today.totalTokens,
                weekTokens: week.totalTokens,
                settings: settings,
                resetAt: resetAt,
                resetSource: resetSource
            )
        }

        if usageEvents.isEmpty {
            warnings.append("No Claude Code usage found")
        }

        return UsageSnapshot(
            generatedAt: now,
            currentWindow: currentWindow,
            today: today,
            week: week,
            modelBreakdown: breakdown,
            quota: quota,
            officialQuota: officialQuota,
            officialWarning: officialWarning,
            warnings: warnings,
            dailyTrend: dailyTotals(events: usageEvents, now: now)
        )
    }

    /// Token totals per calendar day for the trailing `days` days, oldest
    /// first, including zero days so the trend chart has a fixed domain.
    static func dailyTotals(events: [UsageEvent], now: Date, days: Int = 7) -> [DailyUsage] {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        var totals: [Date: Int] = [:]
        for event in events {
            let day = calendar.startOfDay(for: event.timestamp)
            totals[day, default: 0] += event.totalTokens
        }
        return (0..<days).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: todayStart) else { return nil }
            return DailyUsage(date: day, totalTokens: totals[day] ?? 0)
        }
    }

    static func windowSnapshot(events: [UsageEvent], interval: DateInterval, settings: AppSettings) -> UsageWindowSnapshot {
        var input = 0, output = 0, cacheCreate = 0, cacheRead = 0, total = 0, count = 0
        var cost: Decimal = 0
        var hasCost = false

        for event in events where interval.start <= event.timestamp && event.timestamp <= interval.end {
            input += event.inputTokens
            output += event.outputTokens
            cacheCreate += event.cacheCreationTokens
            cacheRead += event.cacheReadTokens
            total += event.totalTokens
            count += 1
            if let c = eventCost(event, settings: settings) {
                cost += c
                hasCost = true
            }
        }
        return UsageWindowSnapshot(
            start: interval.start,
            end: interval.end,
            inputTokens: input,
            outputTokens: output,
            cacheCreationTokens: cacheCreate,
            cacheReadTokens: cacheRead,
            totalTokens: total,
            estimatedCostUSD: hasCost ? cost : nil,
            eventCount: count
        )
    }

    static func eventCost(_ event: UsageEvent, settings: AppSettings) -> Decimal? {
        if settings.useLoggedCosts, let logged = event.estimatedCostUSD {
            return logged
        }
        guard settings.estimateCostsWhenMissing else { return nil }
        return settings.pricing.estimateCost(
            model: event.model,
            inputTokens: event.inputTokens,
            outputTokens: event.outputTokens,
            cacheCreationTokens: event.cacheCreationTokens,
            cacheReadTokens: event.cacheReadTokens,
            allowFallback: settings.enableFallbackPricingForUnknownModels
        )
    }

    static func modelBreakdown(events: [UsageEvent], settings: AppSettings) -> [ModelUsage] {
        var grouped: [String: (input: Int, output: Int, total: Int, cost: Decimal, hasCost: Bool)] = [:]
        for event in events {
            let family = PricingTable.family(for: event.model)
            let name = family == .unknown ? (event.model ?? "Unknown") : family.rawValue.capitalized
            var bucket = grouped[name] ?? (0, 0, 0, 0, false)
            bucket.input += event.inputTokens
            bucket.output += event.outputTokens
            bucket.total += event.totalTokens
            if let c = eventCost(event, settings: settings) {
                bucket.cost += c
                bucket.hasCost = true
            }
            grouped[name] = bucket
        }
        return grouped
            .map { name, bucket in
                ModelUsage(
                    id: name,
                    model: name,
                    inputTokens: bucket.input,
                    outputTokens: bucket.output,
                    totalTokens: bucket.total,
                    estimatedCostUSD: bucket.hasCost ? bucket.cost : nil
                )
            }
            .sorted { $0.totalTokens > $1.totalTokens }
    }
}
