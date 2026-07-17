import Foundation

struct UsageEvent: Identifiable, Hashable, Codable {
    let id: String
    let timestamp: Date
    let source: UsageSource
    let model: String?
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int
    let totalTokens: Int
    let estimatedCostUSD: Decimal?
    let sessionID: String?
    let resetAt: Date?
    let rawLimitMessage: String?
}

enum UsageSource: String, Codable {
    case claudeCodeLog
    case claudeCLI
    case manual
}

struct UsageSnapshot: Codable {
    let generatedAt: Date
    let currentWindow: UsageWindowSnapshot
    let today: UsageWindowSnapshot
    let week: UsageWindowSnapshot
    let modelBreakdown: [ModelUsage]
    let quota: QuotaSnapshot
    let officialQuota: OfficialQuota?
    // Why officialQuota is nil while official usage is enabled (e.g. token
    // expired) — shown prominently instead of being buried in `warnings`.
    let officialWarning: String?
    let warnings: [String]
    // Daily token totals for the trailing week, oldest first (last = today).
    let dailyTrend: [DailyUsage]
}

struct DailyUsage: Codable, Identifiable, Equatable {
    let date: Date
    let totalTokens: Int
    var id: Date { date }
}

struct UsageWindowSnapshot: Codable {
    let start: Date
    let end: Date
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int
    let totalTokens: Int
    let estimatedCostUSD: Decimal?
    let eventCount: Int
}

struct QuotaSnapshot: Codable {
    let percentageUsed: Double?
    let resetAt: Date?
    let resetSource: ResetSource
    let quotaSource: QuotaSource
    let confidence: Confidence
}

enum ResetSource: String, Codable {
    case detectedFromClaudeCode
    case inferredFromWindow
    case manual
    case unknown
}

enum QuotaSource: String, Codable {
    case official
    case detected
    case manualCalibration
    case unavailable
}

enum Confidence: String, Codable {
    case high
    case medium
    case low
    case unavailable
}

struct ModelUsage: Codable, Identifiable {
    let id: String
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let totalTokens: Int
    let estimatedCostUSD: Decimal?
}

struct FileScanState: Codable {
    let path: String
    let inode: UInt64?
    let lastModified: Date
    let size: UInt64
    let lastReadOffset: UInt64
}

struct ScanResult {
    var events: [UsageEvent]
    var warnings: [String]
    var fileStates: [String: FileScanState]
}
