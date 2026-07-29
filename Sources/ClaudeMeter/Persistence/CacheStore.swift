import Foundation

/// Persists scanned usage metadata and per-file scan offsets so restarts and
/// refreshes are incremental. Lives in Application Support; deleting it just
/// triggers a full rescan.
struct CacheStore {
    /// Bump when a new event field needs backfilling from the logs; `load()`
    /// then reports the cache as stale so the app does one full rescan.
    static let schemaVersion = 2

    struct CacheData: Codable {
        var fileStates: [String: FileScanState]
        var events: [UsageEvent]
        // Absent in caches written before versioning (treated as version 1).
        var schemaVersion: Int?
        // Last successful official usage, so the app shows the real
        // percentages immediately on launch and keeps showing them through
        // transient rate limits instead of blanking to a fallback.
        var officialQuota: OfficialQuota?
    }

    private let url: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("ClaudeMeter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("cache.json")
    }

    func load() -> CacheData? {
        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(CacheData.self, from: data) else { return nil }
        guard (cache.schemaVersion ?? 1) == Self.schemaVersion else {
            // Keep the cached official quota (still valid) but drop the scan
            // offsets so the next scan re-reads the logs from the start.
            return CacheData(fileStates: [:], events: [], schemaVersion: Self.schemaVersion,
                             officialQuota: cache.officialQuota)
        }
        return cache
    }

    func save(_ cache: CacheData) {
        var stamped = cache
        stamped.schemaVersion = Self.schemaVersion
        guard let data = try? JSONEncoder().encode(stamped) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
