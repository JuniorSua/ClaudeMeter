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
        let monthInterval = DateWindowCalculator.monthWindow(now: now)

        let usageEvents = events.filter { $0.totalTokens > 0 || $0.estimatedCostUSD != nil }
        let monthEvents = usageEvents.filter { monthInterval.start <= $0.timestamp && $0.timestamp <= now }

        let currentWindow = windowSnapshot(events: usageEvents, interval: DateInterval(start: shortInterval.start, end: now), settings: settings)
        let today = windowSnapshot(events: usageEvents, interval: todayInterval, settings: settings)
        let week = windowSnapshot(events: usageEvents, interval: weekInterval, settings: settings)
        let month = windowSnapshot(events: usageEvents, interval: monthInterval, settings: settings)

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
            dailyTrend: dailyTotals(events: usageEvents, now: now),
            month: month,
            projectBreakdown: projectBreakdown(events: monthEvents, settings: settings),
            efficiency: efficiencySnapshot(events: monthEvents, settings: settings)
        )
    }

    /// Month efficiency plus the per-session ("per task") distribution.
    static func efficiencySnapshot(events: [UsageEvent], settings: AppSettings) -> EfficiencySnapshot? {
        guard let score = EfficiencyScore.evaluate(events: events, settings: settings) else { return nil }

        // Per-task view: a Claude Code session is the closest thing to a task.
        var bySession: [String: [UsageEvent]] = [:]
        for event in events {
            guard let session = event.sessionID, !session.isEmpty else { continue }
            bySession[session, default: []].append(event)
        }
        // Only score sessions long enough for the measurement to mean
        // something. Cache reuse can't happen until a later turn, so a one- or
        // two-turn session scores near zero no matter how well it was run —
        // that measures session length, not efficiency. Require some volume
        // *and* enough turns for reuse to have been possible.
        let sessionScores = bySession.values
            .filter { $0.count >= 3 && $0.reduce(0) { $0 + $1.totalTokens } >= 10_000 }
            .compactMap { EfficiencyScore.overallScore(events: $0, settings: settings) }
            .sorted()

        return EfficiencySnapshot(
            overall: score.overall,
            grade: score.grade,
            brief: score.brief,
            cacheLeverage: score.cacheLeverage,
            cacheDiscipline: score.cacheDiscipline,
            outputShare: score.outputShare,
            medianSessionScore: median(sessionScores),
            worstSessionScore: sessionScores.first,
            scoredSessionCount: sessionScores.count
        )
    }

    /// Median of a pre-sorted array; nil when empty.
    static func median(_ sorted: [Double]) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[mid - 1] + sorted[mid]) / 2
            : sorted[mid]
    }

    /// Token/cost totals per project, largest first, with the tail folded into
    /// "Other" so the card stays readable.
    static func projectBreakdown(
        events: [UsageEvent],
        settings: AppSettings,
        limit: Int = 4
    ) -> [ProjectUsage] {
        var tokens: [String: Int] = [:]
        var costs: [String: Decimal] = [:]
        var hasCost: Set<String> = []
        var eventsByProject: [String: [UsageEvent]] = [:]
        for event in events {
            guard let project = event.project, !project.isEmpty else { continue }
            tokens[project, default: 0] += event.totalTokens
            if let cost = eventCost(event, settings: settings) {
                costs[project, default: 0] += cost
                hasCost.insert(project)
            }
            eventsByProject[project, default: []].append(event)
        }
        let ranked = tokens
            .map { ProjectUsage(project: $0.key, totalTokens: $0.value,
                                estimatedCostUSD: hasCost.contains($0.key) ? costs[$0.key] : nil,
                                efficiency: EfficiencyScore.overallScore(
                                    events: eventsByProject[$0.key] ?? [], settings: settings)) }
            .sorted { ($0.totalTokens, $1.project) > ($1.totalTokens, $0.project) }
        guard ranked.count > limit else { return ranked }
        let head = Array(ranked.prefix(limit))
        let tail = ranked.dropFirst(limit)
        let tailCosts = tail.compactMap(\.estimatedCostUSD)
        // "Other" is a synthetic bucket, so score it over the same folded
        // events rather than trying to average the individual scores.
        let tailEvents = tail.flatMap { eventsByProject[$0.project] ?? [] }
        return head + [ProjectUsage(
            project: "Other",
            totalTokens: tail.reduce(0) { $0 + $1.totalTokens },
            estimatedCostUSD: tailCosts.isEmpty ? nil : tailCosts.reduce(0, +),
            efficiency: EfficiencyScore.overallScore(events: tailEvents, settings: settings)
        )]
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
        var eventsByModel: [String: [UsageEvent]] = [:]
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
            eventsByModel[name, default: []].append(event)
        }
        return grouped
            .map { name, bucket in
                ModelUsage(
                    id: name,
                    model: name,
                    inputTokens: bucket.input,
                    outputTokens: bucket.output,
                    totalTokens: bucket.total,
                    estimatedCostUSD: bucket.hasCost ? bucket.cost : nil,
                    // Scored over this model's own events, and output share is
                    // normalized by its own prices — so the score reflects how
                    // the model was used, not how expensive it is.
                    efficiency: EfficiencyScore.overallScore(
                        events: eventsByModel[name] ?? [], settings: settings
                    )
                )
            }
            .sorted { $0.totalTokens > $1.totalTokens }
    }
}
