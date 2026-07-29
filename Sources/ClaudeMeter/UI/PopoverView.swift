import SwiftUI

struct PopoverView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settingsStore: SettingsStore
    let openSettings: () -> Void
    let quit: () -> Void

    /// Which range the token card shows. One card with a segmented control
    /// beats three stacked cards: same data, a third of the scrolling, and
    /// the comparison is a click rather than a scroll.
    enum Range: String, CaseIterable, Identifiable {
        case today, week, month
        var id: String { rawValue }
        var label: String {
            switch self {
            case .today: return "Today"
            case .week: return "Week"
            case .month: return "Month"
            }
        }
    }

    @State private var range: Range = .today

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 10) {
                    header
                    if let snapshot = store.snapshot {
                        if let official = snapshot.officialQuota {
                            accountUsageCard(official, generatedAt: snapshot.generatedAt)
                        } else {
                            if settingsStore.settings.officialUsageEnabled {
                                accountUsageUnavailableCard(snapshot)
                            }
                            currentWindowCard(snapshot)
                        }
                        if let efficiency = snapshot.efficiency {
                            EfficiencyCard(efficiency: efficiency)
                        }
                        rangeCard(snapshot)
                        if snapshot.dailyTrend.contains(where: { $0.totalTokens > 0 }) {
                            CardView(title: "Last 7 Days") {
                                DailyTrendChart(days: snapshot.dailyTrend)
                            }
                        }
                        if !snapshot.projectBreakdown.isEmpty {
                            CardView(title: "Top Projects This Month") {
                                ProjectBreakdownView(breakdown: snapshot.projectBreakdown)
                            }
                        }
                        if !snapshot.modelBreakdown.isEmpty {
                            CardView(title: "Model Breakdown") {
                                ModelBreakdownView(breakdown: snapshot.modelBreakdown)
                            }
                        }
                        warningsView(snapshot)
                    } else {
                        Text(store.isRefreshing ? "Scanning Claude Code logs…" : "No data yet")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 24)
                    }
                }
                .padding(12)
            }
            Divider()
            keychainControl
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            footer
        }
        .frame(width: 320, height: 600)
    }

    /// One-tap control over Keychain access. Turning it off permanently stops
    /// the "Claude Code-credentials" reads that trigger the macOS Keychain
    /// permission pop-up, without touching local usage tracking.
    @ViewBuilder
    private var keychainControl: some View {
        if settingsStore.settings.officialUsageEnabled {
            VStack(alignment: .leading, spacing: 6) {
                Text("Account usage reads your Claude Code login from the macOS Keychain silently — it never asks for your password. Prefer it not to read the Keychain at all? Stop it here.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    settingsStore.settings.officialUsageEnabled = false
                } label: {
                    Label("Stop Giving Keychain Permission", systemImage: "key.slash")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Keychain access is off — account usage is paused and you won't be asked for permission. Local usage tracking still works.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    settingsStore.settings.officialUsageEnabled = true
                } label: {
                    Label("Turn Account Usage Back On", systemImage: "key")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(MenuBarFormatter.symbol) Claude Usage")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if store.isRefreshing || store.isSwitchingProfile {
                    ProgressView()
                        .controlSize(.small)
                }
                profileMenu
            }
            if let profileError = store.profileError {
                Text(profileError)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// One-click claude-switch profile picker. Hidden unless there are at
    /// least two profiles — with one there is nothing to switch to.
    @ViewBuilder
    private var profileMenu: some View {
        if store.profiles.count > 1 {
            Menu {
                ForEach(store.profiles, id: \.self) { name in
                    Button {
                        store.switchProfile(to: name)
                    } label: {
                        // Plan badge (pro/max) identifies which login each
                        // profile actually holds — a lifesaver when profiles
                        // get out of sync.
                        let title = store.profilePlans[name].map { "\(name) — \($0)" } ?? name
                        if name == store.activeProfile {
                            Label(title, systemImage: "checkmark")
                        } else {
                            Text(title)
                        }
                    }
                }
            } label: {
                Label(store.activeProfile ?? "profile", systemImage: "person.crop.circle")
                    .font(.system(size: 11, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(store.isSwitchingProfile)
            .help("Switch Claude Code profile (claude-switch)")
        }
    }

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMM")
        return f
    }()

    /// Pace is shown for the one limit that actually binds — the active one,
    /// else the highest percentage — so the card stays a single clear signal
    /// instead of three competing forecasts.
    private func paceForBindingLimit(
        _ official: OfficialQuota,
        limit: OfficialQuota.Limit,
        now: Date
    ) -> QuotaPace? {
        let binding = official.limits.first(where: \.isActive)
            ?? official.limits.max(by: { $0.percent < $1.percent })
        guard binding?.id == limit.id else { return nil }
        return QuotaPace.evaluate(limit: limit, now: now)
    }

    private func paceIcon(_ verdict: QuotaPace.Verdict) -> String {
        switch verdict {
        case .exhausted: return "exclamationmark.octagon.fill"
        case .aheadOfPace: return "exclamationmark.triangle.fill"
        case .onTrack: return "gauge.medium"
        case .comfortable: return "checkmark.circle"
        }
    }

    private func paceColor(_ verdict: QuotaPace.Verdict) -> Color {
        switch verdict {
        case .exhausted, .aheadOfPace: return Viz.statusWarning
        case .onTrack: return .secondary
        case .comfortable: return .secondary
        }
    }

    private func accountUsageCard(_ official: OfficialQuota, generatedAt: Date) -> some View {
        CardView(title: official.profileName.map { "Account Usage — \($0)" } ?? "Account Usage") {
            ForEach(official.limits) { limit in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(limit.label)
                            .font(.system(size: 12, weight: limit.isActive ? .semibold : .regular))
                        if limit.isActive {
                            Text("active limit")
                                .font(.system(size: 9, weight: .medium))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.orange.opacity(0.25)))
                        }
                        Spacer()
                        Text(HumanFormatters.percent(limit.percent))
                            .font(.system(size: 12, weight: .semibold))
                            .monospacedDigit()
                    }
                    let pace = paceForBindingLimit(official, limit: limit, now: generatedAt)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color(nsColor: .tertiaryLabelColor).opacity(0.3))
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color(nsColor: MeterColor.nsColor(for: limit.percent)))
                                .frame(width: max(4, geo.size.width * min(limit.percent, 100) / 100))
                            // Where this window lands by reset at the current
                            // rate. Only drawn when the projection falls
                            // inside the track — past 100% the warning text
                            // below says it better than a pinned tick.
                            if let pace,
                               pace.projectedPercentAtReset > limit.percent + 2,
                               pace.projectedPercentAtReset < 99 {
                                let x = geo.size.width * pace.projectedPercentAtReset / 100
                                Capsule()
                                    .fill(Color(nsColor: .labelColor).opacity(0.7))
                                    .frame(width: 2, height: 7)
                                    .offset(x: min(max(x - 1, 0), geo.size.width - 2))
                                    .help("Projected \(HumanFormatters.percent(pace.projectedPercentAtReset)) by reset")
                            }
                        }
                    }
                    .frame(height: 5)
                    if let resetsAt = limit.resetsAt, resetsAt > generatedAt {
                        Text("Resets in \(HumanFormatters.duration(resetsAt.timeIntervalSince(generatedAt)))")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    if let pace {
                        HStack(spacing: 4) {
                            Image(systemName: paceIcon(pace.verdict))
                                .font(.system(size: 9, weight: .semibold))
                            Text(pace.message)
                                .font(.system(size: 10))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundStyle(paceColor(pace.verdict))
                    }
                }
                .padding(.bottom, 2)
            }
            Text("Official Anthropic usage for the active Claude account")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            if generatedAt.timeIntervalSince(official.fetchedAt) > 15 * 60 {
                Text("Last updated \(HumanFormatters.duration(generatedAt.timeIntervalSince(official.fetchedAt))) ago — retrying automatically")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            }
        }
    }

    /// Shown when official usage is on but no quota is available, so the
    /// reason (e.g. an expired login token) is front and center instead of
    /// buried in the fine print at the bottom.
    private func accountUsageUnavailableCard(_ snapshot: UsageSnapshot) -> some View {
        CardView(title: "Account Usage") {
            Text(snapshot.officialWarning ?? "Waiting for the first fetch from Anthropic…")
                .font(.system(size: 11, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Text("Retries automatically — nothing to approve or type. If it mentions your login, just open Claude Code once.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func currentWindowCard(_ snapshot: UsageSnapshot) -> some View {
        CardView(title: "Current Window") {
            if let pct = snapshot.quota.percentageUsed {
                HStack(spacing: 8) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color(nsColor: .tertiaryLabelColor).opacity(0.3))
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color(nsColor: MeterColor.nsColor(for: pct)))
                                .frame(width: max(4, geo.size.width * min(pct, 100) / 100))
                        }
                    }
                    .frame(height: 6)
                    Text(HumanFormatters.percent(pct))
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                }
                UsageRow(label: "Used", value: "\(HumanFormatters.tokensExact(snapshot.currentWindow.totalTokens)) tokens")
                UsageRow(label: "Source", value: quotaSourceLabel(snapshot.quota))
            } else {
                Text("Quota fullness unavailable")
                    .font(.system(size: 12, weight: .medium))
                Text("Local usage is tracked, but exact account allowance is not exposed. Open Settings to calibrate a budget.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                UsageRow(label: "Used", value: "\(HumanFormatters.tokensExact(snapshot.currentWindow.totalTokens)) tokens")
            }
            if let resetAt = snapshot.quota.resetAt, resetAt > snapshot.generatedAt {
                UsageRow(
                    label: "Reset",
                    value: "\(HumanFormatters.duration(resetAt.timeIntervalSince(snapshot.generatedAt)))\(snapshot.quota.resetSource == .detectedFromClaudeCode ? "" : " (estimated)")"
                )
            }
            UsageRow(label: "Window", value: windowLabel(snapshot.quota.resetSource))
        }
    }

    /// Token usage for the selected range: segmented control, hero total,
    /// composition bar, legend. Replaces the old Today/Week/Month card stack.
    private func rangeCard(_ snapshot: UsageSnapshot) -> some View {
        let window: UsageWindowSnapshot = {
            switch range {
            case .today: return snapshot.today
            case .week: return snapshot.week
            case .month: return snapshot.month
            }
        }()
        return CardView(title: rangeTitle(snapshot.generatedAt)) {
            Picker("", selection: $range) {
                ForEach(Range.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            windowBody(window)
        }
    }

    private func rangeTitle(_ now: Date) -> String {
        switch range {
        case .today: return "Tokens Today"
        case .week: return "Tokens This Week"
        case .month: return "Tokens in \(Self.monthFormatter.string(from: now))"
        }
    }

    /// Stat tile + part-to-whole composition: hero total, thin stacked bar of
    /// the token mix, legend with exact values. Hover any segment for the
    /// precise count.
    @ViewBuilder
    private func windowBody(_ window: UsageWindowSnapshot) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(HumanFormatters.tokens(window.totalTokens))
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .help("\(HumanFormatters.tokensExact(window.totalTokens)) tokens")
            Text("tokens")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            if let cost = window.estimatedCostUSD {
                Text(HumanFormatters.cost(cost, estimated: true))
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .help("Estimated cost")
            }
        }
        if window.totalTokens > 0 {
            let segments = tokenSegments(window)
            CompositionBar(segments: segments)
            CompositionLegend(segments: segments)
        } else {
            Text("No activity in this range")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func warningsView(_ snapshot: UsageSnapshot) -> some View {
        let localNote = snapshot.officialQuota != nil
            ? "Token counts above are from local logs on this Mac (all claude-switch profiles combined)."
            : "This reflects local Claude Code activity on this Mac. Claude web, desktop, or other-device usage may not be included."
        let notes = snapshot.warnings + [localNote]
        VStack(alignment: .leading, spacing: 4) {
            ForEach(notes, id: \.self) { warning in
                Text(warning)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack {
            Button("Refresh Now") { store.refreshNow() }
                .controlSize(.small)
            Button("Settings…") { openSettings() }
                .controlSize(.small)
            Spacer()
            if let snapshot = store.snapshot {
                Text("Updated \(HumanFormatters.time(snapshot.generatedAt))")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Button("Quit") { quit() }
                .controlSize(.small)
        }
        .padding(10)
    }

    private func quotaSourceLabel(_ quota: QuotaSnapshot) -> String {
        switch quota.quotaSource {
        case .official: return "Official"
        case .detected: return "Detected"
        case .manualCalibration: return "Calibrated"
        case .unavailable: return "Unavailable"
        }
    }

    private func windowLabel(_ source: ResetSource) -> String {
        switch source {
        case .detectedFromClaudeCode: return "detected"
        case .manual: return "manual"
        case .inferredFromWindow, .unknown: return "estimated (rolling \(settingsStore.settings.shortWindowMinutes / 60)h)"
        }
    }
}
