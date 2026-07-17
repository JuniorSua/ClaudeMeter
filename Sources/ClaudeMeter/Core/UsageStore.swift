import Foundation
import Combine

/// Owns the scan → aggregate → publish pipeline. Scanning happens off the
/// main thread; published state changes happen on the main thread.
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    @Published private(set) var profileError: String?
    @Published private(set) var cliVersion: String?
    @Published private(set) var profiles: [String] = []
    @Published private(set) var profilePlans: [String: String] = [:]
    @Published private(set) var activeProfile: String?
    @Published private(set) var isSwitchingProfile = false

    private let settingsStore: SettingsStore
    private let cacheStore = CacheStore()
    private let scanner = ClaudeLogScanner()
    private let scanQueue = DispatchQueue(label: "com.local.ClaudeMeter.scan", qos: .utility)

    // Official usage is rate limited server-side; fetch at most this often
    // regardless of how frequently logs change, and treat a cached value as
    // usable well past that so brief 429s don't blank the display.
    private static let officialMinInterval: TimeInterval = 120
    private static let officialMaxBackoff: TimeInterval = 300   // 5 min ceiling on 429 backoff
    private static let officialStaleAfter: TimeInterval = 6 * 3600  // show cached percentages this long

    private var eventsByID: [String: UsageEvent] = [:]
    private var fileStates: [String: FileScanState] = [:]
    private var scanWarnings: [String] = []
    private var lastOfficialQuota: OfficialQuota?
    private var lastOfficialWarning: String?
    private var lastOfficialFetchAt: Date?
    private var officialFailureCount = 0

    private var watcher: FileWatcher?
    private var scheduler: RefreshScheduler?
    private var cancellables: Set<AnyCancellable> = []
    private var refreshQueuedWhileBusy = false

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    func start() {
        if let cached = cacheStore.load() {
            eventsByID = Dictionary(uniqueKeysWithValues: cached.events.map { ($0.id, $0) })
            fileStates = cached.fileStates
            // Restore last good official usage so the stacked percentages and
            // green bars appear instantly, before the first network fetch.
            lastOfficialQuota = cached.officialQuota
            recomputeSnapshot()
        }

        scheduler = RefreshScheduler { [weak self] in self?.refreshNow() }
        scheduler?.start(intervalSeconds: settingsStore.settings.refreshIntervalSeconds)
        startWatcher()

        // React to settings changes: retime the timer, rewatch on directory
        // change, and recompute quota/cost outputs immediately.
        settingsStore.$settings
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] settings in
                guard let self else { return }
                self.scheduler?.start(intervalSeconds: settings.refreshIntervalSeconds)
                self.startWatcher()
                self.recomputeSnapshot()
            }
            .store(in: &cancellables)

        refreshNow()
        detectCLI()
        loadProfiles()
    }

    func stop() {
        scheduler?.stop()
        watcher?.stop()
    }

    // MARK: - Refresh

    func refreshNow() {
        refresh(fullRescan: false)
    }

    func rescanAll() {
        refresh(fullRescan: true)
    }

    func clearCache() {
        cacheStore.clear()
        eventsByID = [:]
        fileStates = [:]
        refresh(fullRescan: true)
    }

    private func refresh(fullRescan: Bool) {
        guard !isRefreshing else {
            refreshQueuedWhileBusy = true
            return
        }
        isRefreshing = true

        let directory = settingsStore.settings.claudeDirectoryPath
        let settings = settingsStore.settings
        let previousStates = fullRescan ? [:] : fileStates
        let existingEvents = fullRescan ? [:] : eventsByID
        let scanner = self.scanner

        let previousOfficial = lastOfficialQuota
        let previousOfficialWarning = lastOfficialWarning
        let previousFetchAt = lastOfficialFetchAt
        let previousFailures = officialFailureCount
        let now = Date()

        scanQueue.async { [weak self] in
            // Scan the main directory plus any isolated claude-switch profile
            // dirs (each holds its own logs); events dedup by id.
            var result = scanner.scan(directory: directory, previousStates: previousStates)
            for extra in Self.extraScanRoots(mainDirectory: directory) {
                let more = scanner.scan(directory: extra, previousStates: previousStates)
                result.events.append(contentsOf: more.events)
                result.fileStates.merge(more.fileStates) { _, new in new }
                result.warnings.append(contentsOf: more.warnings)
            }
            let activeName = ClaudeQuotaFetcher.activeProfileName()

            // Official account usage (same numbers as Claude Code's /usage).
            // Throttled hard: log scans fire on every file-watch event during
            // active Claude Code use, but the usage endpoint is rate limited
            // (429). Fetch at most every `officialMinInterval`, and on failure
            // back off exponentially so the app stops adding to any rate limit.
            var official = previousOfficial
            var officialWarning = previousOfficialWarning
            var didFetch = false
            var newFailures = previousFailures
            if settings.officialUsageEnabled {
                // A profile switch (in-app or in Terminal) makes the cached
                // quota another account's numbers: never show them under the
                // new profile's name, and fetch right away despite throttling.
                let profileChanged = previousOfficial != nil && previousOfficial?.profileName != activeName
                if profileChanged {
                    ClaudeQuotaFetcher.invalidateTokenCache()
                    official = nil
                }
                let backoff = min(Self.officialMinInterval * pow(2, Double(previousFailures)), Self.officialMaxBackoff)
                let due = profileChanged || previousFetchAt == nil || now.timeIntervalSince(previousFetchAt!) >= backoff
                if due {
                    didFetch = true
                    switch ClaudeQuotaFetcher.fetch() {
                    case .success(let quota):
                        official = quota
                        officialWarning = nil
                        newFailures = 0
                    case .failure(let error):
                        newFailures = previousFailures + 1
                        officialWarning = error.warning
                        // Keep showing the last good value for a long time
                        // (reset countdowns stay accurate — they're absolute),
                        // but only if it belongs to the current profile.
                        if !profileChanged, let last = previousOfficial, now.timeIntervalSince(last.fetchedAt) < Self.officialStaleAfter {
                            official = last
                        } else {
                            official = nil
                        }
                    }
                }
            } else {
                official = nil
                officialWarning = nil
            }

            var merged = existingEvents
            for event in result.events {
                merged[event.id] = event
            }
            let allEvents = Array(merged.values)
            let warnings = result.warnings
            let snapshot = UsageAggregator.makeSnapshot(
                events: allEvents,
                settings: settings,
                now: Date(),
                officialQuota: official,
                officialWarning: officialWarning,
                extraWarnings: warnings
            )

            DispatchQueue.main.async {
                guard let self else { return }
                self.eventsByID = merged
                self.fileStates = result.fileStates
                self.scanWarnings = warnings
                self.activeProfile = activeName
                self.lastOfficialQuota = official
                self.lastOfficialWarning = officialWarning
                if didFetch {
                    self.lastOfficialFetchAt = now
                    self.officialFailureCount = newFailures
                }
                self.snapshot = snapshot
                if self.profileError == nil {
                    self.lastError = nil
                }
                self.isRefreshing = false
                self.cacheStore.save(CacheStore.CacheData(
                    fileStates: result.fileStates,
                    events: allEvents,
                    officialQuota: official
                ))
                if self.refreshQueuedWhileBusy {
                    self.refreshQueuedWhileBusy = false
                    self.refreshNow()
                }
            }
        }
    }

    /// Re-aggregates cached events without touching disk (used when settings
    /// like budgets/pricing change).
    private func recomputeSnapshot() {
        let events = Array(eventsByID.values)
        let settings = settingsStore.settings
        let warnings = scanWarnings
        let official = settings.officialUsageEnabled ? lastOfficialQuota : nil
        let officialWarning = settings.officialUsageEnabled ? lastOfficialWarning : nil
        scanQueue.async { [weak self] in
            let snapshot = UsageAggregator.makeSnapshot(
                events: events, settings: settings, now: Date(),
                officialQuota: official, officialWarning: officialWarning,
                extraWarnings: warnings
            )
            DispatchQueue.main.async {
                self?.snapshot = snapshot
            }
        }
    }

    /// Isolated claude-switch profile dirs that hold their own Claude logs.
    /// Dirs that resolve to the main directory (e.g. a `personal` symlink to
    /// ~/.claude) are skipped so files are not scanned twice.
    static func extraScanRoots(mainDirectory: String) -> [String] {
        let fm = FileManager.default
        let mainResolved = URL(fileURLWithPath: (mainDirectory as NSString).expandingTildeInPath)
            .resolvingSymlinksInPath().path
        guard let names = try? fm.contentsOfDirectory(atPath: ProfileSwitcher.profilesRoot) else { return [] }
        return names.sorted().compactMap { name in
            let dir = ProfileSwitcher.profileDirectory(name)
            let resolved = URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
            var isDir: ObjCBool = false
            guard resolved != mainResolved,
                  fm.fileExists(atPath: resolved, isDirectory: &isDir), isDir.boolValue else { return nil }
            return dir
        }
    }

    // MARK: - Profiles (claude-switch)

    /// Refreshes the profile list, active profile, and per-profile plan
    /// badges (pro/max) shown in the popover.
    func loadProfiles() {
        scanQueue.async { [weak self] in
            let names = ProfileSwitcher.listProfiles()
            let active = ClaudeQuotaFetcher.activeProfileName()
            var plans: [String: String] = [:]
            for name in names {
                plans[name] = ProfileSwitcher.subscription(for: name, isActive: name == active)
            }
            DispatchQueue.main.async {
                self?.profiles = names
                self?.activeProfile = active
                self?.profilePlans = plans
            }
        }
    }

    /// Switches the active Claude Code login via claude-switch, then drops
    /// the old account's quota and fetches the new one immediately.
    /// Switching to the profile that is already marked active is allowed —
    /// it forces a Keychain re-sync when credentials drift from `.active-profile`.
    func switchProfile(to name: String) {
        guard !isSwitchingProfile else { return }
        guard profiles.contains(name) else {
            profileError = "Unknown profile “\(name)”"
            return
        }
        isSwitchingProfile = true
        profileError = nil
        let known = profiles
        scanQueue.async { [weak self] in
            let result = ProfileSwitcher.switchTo(name, knownProfiles: known)
            let confirmedActive = ClaudeQuotaFetcher.activeProfileName()
            DispatchQueue.main.async {
                guard let self else { return }
                self.isSwitchingProfile = false
                switch result {
                case .success:
                    // Only keychain mode shares one login slot that a running
                    // session can clobber; isolated profiles are safe to run
                    // concurrently.
                    self.profileError = ProfileSwitcher.storageMode() == "keychain" && ProfileSwitcher.claudeCLIIsRunning()
                        ? "Claude Code is still running — it stays logged into the previous account and can mix up profile credentials. Quit it (or restart it) after switching."
                        : nil
                    self.activeProfile = confirmedActive ?? name
                    ClaudeQuotaFetcher.invalidateTokenCache()
                    // Old account's numbers are meaningless now; clear them
                    // and lift the fetch throttle so the new ones load fast.
                    self.lastOfficialQuota = nil
                    self.lastOfficialWarning = nil
                    self.lastOfficialFetchAt = nil
                    self.officialFailureCount = 0
                    self.refreshNow()
                    self.loadProfiles()
                case .failure(let reason):
                    self.profileError = reason
                }
            }
        }
    }

    // MARK: - Watching / CLI

    private func startWatcher() {
        watcher?.stop()
        let root = (settingsStore.settings.claudeDirectoryPath as NSString).expandingTildeInPath
        let paths = [root] + Self.extraScanRoots(mainDirectory: root)
        watcher = FileWatcher(paths: paths) { [weak self] in
            self?.refreshNow()
        }
    }

    private func detectCLI() {
        scanQueue.async { [weak self] in
            let info = ClaudeStatusDetector.detect()
            DispatchQueue.main.async {
                self?.cliVersion = info?.version
            }
        }
    }
}
