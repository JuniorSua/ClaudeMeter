import SwiftUI

struct PopoverView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settingsStore: SettingsStore
    let openSettings: () -> Void
    let quit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 10) {
                    header
                    if let snapshot = store.snapshot {
                        if let official = snapshot.officialQuota {
                            accountUsageCard(official, generatedAt: snapshot.generatedAt)
                        } else {
                            currentWindowCard(snapshot)
                        }
                        windowCard(title: "Today", window: snapshot.today)
                        windowCard(title: "This Week", window: snapshot.week)
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
            footer
        }
        .frame(width: 320, height: 600)
    }

    private var header: some View {
        HStack {
            Text("\(MenuBarFormatter.symbol) Claude Usage")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if store.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }
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
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color(nsColor: .tertiaryLabelColor).opacity(0.3))
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color(nsColor: MeterColor.nsColor(for: limit.percent)))
                                .frame(width: max(4, geo.size.width * min(limit.percent, 100) / 100))
                        }
                    }
                    .frame(height: 5)
                    if let resetsAt = limit.resetsAt, resetsAt > generatedAt {
                        Text("Resets in \(HumanFormatters.duration(resetsAt.timeIntervalSince(generatedAt)))")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .padding(.bottom, 2)
            }
            Text("Official Anthropic usage for the active Claude account")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
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

    private func windowCard(title: String, window: UsageWindowSnapshot) -> some View {
        CardView(title: title) {
            UsageRow(label: "Input", value: HumanFormatters.tokensExact(window.inputTokens))
            UsageRow(label: "Output", value: HumanFormatters.tokensExact(window.outputTokens))
            if window.cacheCreationTokens > 0 || window.cacheReadTokens > 0 {
                UsageRow(label: "Cache Create", value: HumanFormatters.tokensExact(window.cacheCreationTokens))
                UsageRow(label: "Cache Read", value: HumanFormatters.tokensExact(window.cacheReadTokens))
            }
            Divider()
            UsageRow(label: "Total", value: HumanFormatters.tokensExact(window.totalTokens))
            if let cost = window.estimatedCostUSD {
                UsageRow(label: "Estimated Cost", value: HumanFormatters.cost(cost, estimated: true))
            }
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
