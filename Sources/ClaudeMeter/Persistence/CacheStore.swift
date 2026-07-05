import Foundation

/// Persists scanned usage metadata and per-file scan offsets so restarts and
/// refreshes are incremental. Lives in Application Support; deleting it just
/// triggers a full rescan.
struct CacheStore {
    struct CacheData: Codable {
        var fileStates: [String: FileScanState]
        var events: [UsageEvent]
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
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CacheData.self, from: data)
    }

    func save(_ cache: CacheData) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
