import Foundation
import Combine

/// Owns the scan → aggregate → publish pipeline. Scanning happens off the
/// main thread; published state changes happen on the main thread.
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    @Published private(set) var cliVersion: String?

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
        let previousFetchAt = lastOfficialFetchAt
        let previousFailures = officialFailureCount
        let now = Date()

        scanQueue.async { [weak self] in
            let result = scanner.scan(directory: directory, previousStates: previousStates)

            // Official account usage (same numbers as Claude Code's /usage).
            // Throttled hard: log scans fire on every file-watch event during
            // active Claude Code use, but the usage endpoint is rate limited
            // (429). Fetch at most every `officialMinInterval`, and on failure
            // back off exponentially so the app stops adding to any rate limit.
            var official = previousOfficial
            var officialWarning: String?
            var didFetch = false
            var newFailures = previousFailures
            if settings.officialUsageEnabled {
                let backoff = min(Self.officialMinInterval * pow(2, Double(previousFailures)), Self.officialMaxBackoff)
                let due = previousFetchAt == nil || now.timeIntervalSince(previousFetchAt!) >= backoff
                if due {
                    didFetch = true
                    switch ClaudeQuotaFetcher.fetch() {
                    case .success(let quota):
                        official = quota
                        newFailures = 0
                    case .failure(let error):
                        newFailures = previousFailures + 1
                        // Keep showing the last good value for a long time
                        // (reset countdowns stay accurate — they're absolute);
                        // only warn when there is nothing usable to show.
                        if let last = previousOfficial, now.timeIntervalSince(last.fetchedAt) < Self.officialStaleAfter {
                            official = last
                        } else {
                            official = nil
                            officialWarning = error.warning
                        }
                    }
                } else {
                    official = previousOfficial
                }
            } else {
                official = nil
            }

            var merged = existingEvents
            for event in result.events {
                merged[event.id] = event
            }
            let allEvents = Array(merged.values)
            var warnings = result.warnings
            if let officialWarning { warnings.append(officialWarning) }
            let snapshot = UsageAggregator.makeSnapshot(
                events: allEvents,
                settings: settings,
                now: Date(),
                officialQuota: official,
                extraWarnings: warnings
            )

            DispatchQueue.main.async {
                guard let self else { return }
                self.eventsByID = merged
                self.fileStates = result.fileStates
                self.scanWarnings = warnings
                self.lastOfficialQuota = official
                if didFetch {
                    self.lastOfficialFetchAt = now
                    self.officialFailureCount = newFailures
                }
                self.snapshot = snapshot
                self.lastError = nil
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
        scanQueue.async { [weak self] in
            let snapshot = UsageAggregator.makeSnapshot(
                events: events, settings: settings, now: Date(),
                officialQuota: official, extraWarnings: warnings
            )
            DispatchQueue.main.async {
                self?.snapshot = snapshot
            }
        }
    }

    // MARK: - Watching / CLI

    private func startWatcher() {
        watcher?.stop()
        let root = (settingsStore.settings.claudeDirectoryPath as NSString).expandingTildeInPath
        watcher = FileWatcher(paths: [root]) { [weak self] in
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
