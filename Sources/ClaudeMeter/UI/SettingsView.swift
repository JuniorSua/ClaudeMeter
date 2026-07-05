import SwiftUI
import ServiceManagement
import AppKit

struct SettingsView: View {
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var store: UsageStore
    @State private var loginItemError: String?

    private var settings: Binding<AppSettings> {
        Binding(get: { settingsStore.settings }, set: { settingsStore.settings = $0 })
    }

    var body: some View {
        Form {
            generalSection
            claudeDataSection
            quotaSection
            pricingSection
            privacySection
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 620)
    }

    // MARK: - General

    private var generalSection: some View {
        Section("General") {
            Toggle("Use official account usage (recommended)", isOn: Binding(
                get: { settingsStore.settings.officialUsageEnabled },
                set: { settingsStore.settings.officialUsageEnabled = $0 }
            ))
            Text("Shows the same session/weekly percentages as Claude Code's /usage, for the active claude-switch profile. Requires Keychain access to your Claude Code login (approve \"Always Allow\" when asked).")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Launch at login", isOn: Binding(
                get: { settingsStore.settings.launchAtLogin },
                set: { setLaunchAtLogin($0) }
            ))
            if let loginItemError {
                Text(loginItemError)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Picker("Refresh interval", selection: settings.refreshIntervalSeconds) {
                Text("15 seconds").tag(15)
                Text("30 seconds").tag(30)
                Text("60 seconds").tag(60)
                Text("5 minutes").tag(300)
            }
            Picker("Display mode", selection: settings.displayMode) {
                ForEach(DisplayMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            Picker("Week starts on", selection: settings.weekStartsOn) {
                ForEach(WeekStartDay.allCases, id: \.self) { day in
                    Text(day.label).tag(day)
                }
            }
        }
    }

    // MARK: - Claude Data

    private var claudeDataSection: some View {
        Section("Claude Data") {
            TextField("Claude directory", text: settings.claudeDirectoryPath)
                .font(.system(size: 12, design: .monospaced))
            HStack {
                Button("Refresh Now") { store.refreshNow() }
                Button("Rescan All Logs") { store.rescanAll() }
                Button("Clear Cache") { store.clearCache() }
                Button("Open in Finder") {
                    let path = (settingsStore.settings.claudeDirectoryPath as NSString).expandingTildeInPath
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
            }
            .controlSize(.small)
        }
    }

    // MARK: - Quota Calibration

    private var quotaSection: some View {
        Section("Quota Calibration") {
            Picker("Short window", selection: shortWindowSelection) {
                Text("Auto-detect").tag(0)
                Text("4 hours").tag(1)
                Text("5 hours").tag(2)
                Text("Custom").tag(3)
            }
            if case .custom = settingsStore.settings.shortWindowMode {
                optionalIntField("Custom window (minutes)", value: Binding(
                    get: { settingsStore.settings.customShortWindowMinutes },
                    set: { newValue in
                        settingsStore.settings.customShortWindowMinutes = newValue
                        settingsStore.settings.shortWindowMode = .custom(minutes: newValue ?? 300)
                    }
                ))
            }
            optionalIntField("Short window token budget", value: settings.shortWindowTokenBudget)
            optionalIntField("Daily token budget", value: settings.dailyTokenBudget)
            optionalIntField("Weekly token budget", value: settings.weeklyTokenBudget)
            Toggle("Hide percentage when confidence is low", isOn: settings.hidePercentageWhenConfidenceLow)
            Text("Budgets are manual calibration: percentages show how much of your own budget is used, not an official Anthropic quota. Leave blank to show usage only.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var shortWindowSelection: Binding<Int> {
        Binding(
            get: {
                switch settingsStore.settings.shortWindowMode {
                case .autoDetect: return 0
                case .fourHours: return 1
                case .fiveHours: return 2
                case .custom: return 3
                }
            },
            set: { tag in
                switch tag {
                case 1: settingsStore.settings.shortWindowMode = .fourHours
                case 2: settingsStore.settings.shortWindowMode = .fiveHours
                case 3: settingsStore.settings.shortWindowMode = .custom(minutes: settingsStore.settings.customShortWindowMinutes ?? 300)
                default: settingsStore.settings.shortWindowMode = .autoDetect
                }
            }
        )
    }

    // MARK: - Pricing

    private var pricingSection: some View {
        Section("Pricing (USD per million tokens)") {
            Toggle("Use logged costs when available", isOn: settings.useLoggedCosts)
            Toggle("Estimate costs when missing", isOn: settings.estimateCostsWhenMissing)
            Toggle("Fallback pricing for unknown models", isOn: settings.enableFallbackPricingForUnknownModels)
            pricingRow("Fable", pricing: settings.pricing.fable)
            pricingRow("Opus", pricing: settings.pricing.opus)
            pricingRow("Sonnet", pricing: settings.pricing.sonnet)
            pricingRow("Haiku", pricing: settings.pricing.haiku)
        }
    }

    private func pricingRow(_ label: String, pricing: Binding<ModelPricing>) -> some View {
        HStack {
            Text(label)
                .frame(width: 60, alignment: .leading)
            decimalField("In", value: pricing.inputPerMTok)
            decimalField("Out", value: pricing.outputPerMTok)
            decimalField("Cache W", value: pricing.cacheWritePerMTok)
            decimalField("Cache R", value: pricing.cacheReadPerMTok)
        }
        .font(.system(size: 12))
    }

    // MARK: - Privacy

    private var privacySection: some View {
        Section("Privacy") {
            Text("ClaudeMeter reads local Claude Code metadata only.\n\nIt does not upload logs. It does not store prompt or completion text. It stores only local usage metadata.\n\nWhen \"official account usage\" is on, it reads your existing Claude Code login token from the macOS Keychain and makes a read-only usage request to Anthropic — the same call Claude Code's /usage makes. No log content is ever sent.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let version = store.cliVersion {
                Text("Claude CLI detected: \(version)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Field helpers

    private func optionalIntField(_ label: String, value: Binding<Int?>) -> some View {
        TextField(label, text: Binding(
            get: { value.wrappedValue.map(String.init) ?? "" },
            set: { text in
                let digits = text.filter(\.isNumber)
                value.wrappedValue = digits.isEmpty ? nil : Int(digits)
            }
        ))
        .textFieldStyle(.roundedBorder)
    }

    private func decimalField(_ label: String, value: Binding<Decimal>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            TextField(label, text: Binding(
                get: { "\(value.wrappedValue)" },
                set: { text in
                    if let d = Decimal(string: text) { value.wrappedValue = d }
                }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(width: 70)
        }
    }

    // MARK: - Launch at login

    private func setLaunchAtLogin(_ enabled: Bool) {
        loginItemError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            settingsStore.settings.launchAtLogin = enabled
        } catch {
            loginItemError = "Could not update login item: \(error.localizedDescription). (Run from a bundled ClaudeMeter.app for this to work.)"
            settingsStore.settings.launchAtLogin = false
        }
    }
}
