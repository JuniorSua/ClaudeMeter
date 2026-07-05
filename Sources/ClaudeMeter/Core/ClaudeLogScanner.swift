import Foundation
import CryptoKit

/// Scans the Claude directory for usage metadata. Tolerant of schema changes:
/// it looks up token/model/timestamp fields across several known shapes and
/// never throws on malformed content. Only metadata is retained — prompt and
/// completion text is discarded at parse time.
struct ClaudeLogScanner {

    // MARK: - Directory scan

    /// Incremental scan: reads only bytes appended since the previous states.
    /// Pass empty `previousStates` for a full rescan.
    func scan(directory: String, previousStates: [String: FileScanState]) -> ScanResult {
        let root = (directory as NSString).expandingTildeInPath
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else {
            return ScanResult(events: [], warnings: ["Claude directory not found at \(directory)"], fileStates: [:])
        }

        var events: [UsageEvent] = []
        var warnings: [String] = []
        var states: [String: FileScanState] = [:]
        var parseErrorCount = 0

        let rootResolved = URL(fileURLWithPath: root).resolvingSymlinksInPath().path

        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants]
        ) else {
            return ScanResult(events: [], warnings: ["Permission denied reading Claude directory"], fileStates: [:])
        }

        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            guard ext == "jsonl" || ext == "json" else { continue }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else { continue }
            // Confine to the Claude directory: never follow a symlink that
            // resolves to a file outside the scanned root.
            guard url.resolvingSymlinksInPath().path.hasPrefix(rootResolved) else { continue }

            let path = url.path
            let size = UInt64(values.fileSize ?? 0)
            let modified = values.contentModificationDate ?? .distantPast
            let inode = (try? fm.attributesOfItem(atPath: path))?[.systemFileNumber] as? UInt64

            let previous = previousStates[path]
            var startOffset: UInt64 = 0
            if let previous,
               previous.inode == inode,
               size >= previous.lastReadOffset,
               previous.size <= size {
                if size == previous.lastReadOffset && modified == previous.lastModified {
                    // Unchanged file — keep state, skip reading.
                    states[path] = previous
                    continue
                }
                startOffset = previous.lastReadOffset
            }

            if ext == "jsonl" {
                guard let result = ByteReader.readNewLines(path: path, from: startOffset) else {
                    warnings.append("Permission denied reading \(url.lastPathComponent)")
                    continue
                }
                for line in result.lines {
                    let parsed = Self.parseLine(line, filePath: path, lineOffset: startOffset)
                    if let event = parsed.event { events.append(event) }
                    if parsed.malformed { parseErrorCount += 1 }
                }
                states[path] = FileScanState(path: path, inode: inode, lastModified: modified, size: size, lastReadOffset: result.newOffset)
            } else {
                // Plain .json — parse whole file when small; most yield nothing.
                if size > 0, size < 2 * 1024 * 1024,
                   startOffset == 0,
                   let data = fm.contents(atPath: path),
                   let object = try? JSONSerialization.jsonObject(with: data) {
                    let records: [[String: Any]]
                    if let dict = object as? [String: Any] { records = [dict] }
                    else if let array = object as? [[String: Any]] { records = array }
                    else { records = [] }
                    for (index, record) in records.enumerated() {
                        if let event = Self.extractEvent(from: record, filePath: path, lineOffset: UInt64(index)) {
                            events.append(event)
                        }
                    }
                }
                states[path] = FileScanState(path: path, inode: inode, lastModified: modified, size: size, lastReadOffset: size)
            }
        }

        if parseErrorCount > 0 {
            warnings.append("Some Claude log entries could not be parsed")
        }
        return ScanResult(events: events, warnings: warnings, fileStates: states)
    }

    // MARK: - Line parsing

    struct ParsedLine {
        let event: UsageEvent?
        let malformed: Bool
    }

    static func parseLine(_ line: String, filePath: String, lineOffset: UInt64) -> ParsedLine {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return ParsedLine(event: nil, malformed: false) }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let record = object as? [String: Any] else {
            return ParsedLine(event: nil, malformed: true)
        }
        return ParsedLine(event: extractEvent(from: record, filePath: filePath, lineOffset: lineOffset), malformed: false)
    }

    // MARK: - Tolerant record extraction

    static func extractEvent(from record: [String: Any], filePath: String, lineOffset: UInt64) -> UsageEvent? {
        let message = record["message"] as? [String: Any]
        let usage = (record["usage"] as? [String: Any]) ?? (message?["usage"] as? [String: Any])

        let model = (record["model"] as? String) ?? (message?["model"] as? String)

        let input = intValue(usage?["input_tokens"]) ?? 0
        let output = intValue(usage?["output_tokens"]) ?? 0
        let cacheCreate = intValue(usage?["cache_creation_input_tokens"]) ?? 0
        let cacheRead = intValue(usage?["cache_read_input_tokens"]) ?? 0
        let total = intValue(usage?["total_tokens"]) ?? (input + output + cacheCreate + cacheRead)

        let cost = decimalValue(record["cost_usd"] ?? record["costUSD"] ?? record["cost"] ?? record["total_cost"])

        let (resetAt, limitMessage) = extractLimitInfo(record: record, message: message)

        // Only records that actually carry usage or limit metadata become events.
        let hasUsage = total > 0 || cost != nil
        let hasLimit = resetAt != nil || limitMessage != nil
        guard hasUsage || hasLimit else { return nil }

        // Skip synthetic/local placeholder records unless they carry limit info.
        if model == "<synthetic>" && !hasLimit && total == 0 { return nil }

        let timestamp = parseTimestamp(record["timestamp"] ?? record["created_at"] ?? record["createdAt"]) ?? Date()

        let sessionID = (record["sessionId"] as? String)
            ?? (record["session_id"] as? String)
            ?? (record["conversation_id"] as? String)

        let id: String
        if let uuid = record["uuid"] as? String, !uuid.isEmpty {
            id = uuid
        } else if let requestID = record["requestId"] as? String, !requestID.isEmpty {
            id = requestID
        } else {
            let material = "\(filePath)|\(lineOffset)|\(timestamp.timeIntervalSince1970)|\(model ?? "")|\(input)|\(output)|\(cacheCreate)|\(cacheRead)"
            id = sha256(material)
        }

        return UsageEvent(
            id: id,
            timestamp: timestamp,
            source: .claudeCodeLog,
            model: model,
            inputTokens: input,
            outputTokens: output,
            cacheCreationTokens: cacheCreate,
            cacheReadTokens: cacheRead,
            totalTokens: total,
            estimatedCostUSD: cost,
            sessionID: sessionID,
            resetAt: resetAt,
            rawLimitMessage: limitMessage
        )
    }

    // MARK: - Limit / reset detection

    private static let limitPhrases = ["usage limit", "limit reached", "rate limit", "try again at", "resets at", "reset at"]

    static func extractLimitInfo(record: [String: Any], message: [String: Any]?) -> (resetAt: Date?, limitMessage: String?) {
        // Structured reset keys first.
        let resetKeys = ["reset_at", "resets_at", "resetAt", "resetsAt", "limit_reset", "usage_limit_reset"]
        for key in resetKeys {
            let candidate = record[key] ?? message?[key] ?? (record["error"] as? [String: Any])?[key]
            if let date = parseTimestamp(candidate) {
                return (date, "Usage limit metadata detected")
            }
        }

        // Text-based detection: only in error messages / short status strings.
        var texts: [String] = []
        if let error = record["error"] as? [String: Any], let msg = error["message"] as? String { texts.append(msg) }
        if let error = record["error"] as? String { texts.append(error) }
        if let msg = record["message"] as? String { texts.append(msg) }

        let reference = parseTimestamp(record["timestamp"] ?? record["created_at"]) ?? Date()
        for text in texts {
            let lower = text.lowercased()
            guard limitPhrases.contains(where: { lower.contains($0) }) else { continue }
            let reset = parseClockTime(in: text, reference: reference)
            // Sanitized: never store the full message text.
            return (reset, "Usage limit reached")
        }
        return (nil, nil)
    }

    /// Parses "… at 11:00 PM" / "… at 3 PM" into the next occurrence of that
    /// clock time relative to `reference` (local time).
    static func parseClockTime(in text: String, reference: Date) -> Date? {
        let pattern = #"at\s+(\d{1,2})(?::(\d{2}))?\s*(AM|PM|am|pm)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return nil
        }
        func group(_ i: Int) -> String? {
            guard let range = Range(match.range(at: i), in: text) else { return nil }
            return String(text[range])
        }
        guard var hour = group(1).flatMap({ Int($0) }) else { return nil }
        let minute = group(2).flatMap { Int($0) } ?? 0
        let meridiem = group(3)?.uppercased() ?? "AM"
        if meridiem == "PM" && hour < 12 { hour += 12 }
        if meridiem == "AM" && hour == 12 { hour = 0 }
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }

        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: reference)
        components.hour = hour
        components.minute = minute
        guard var date = calendar.date(from: components) else { return nil }
        if date < reference {
            date = calendar.date(byAdding: .day, value: 1, to: date) ?? date
        }
        return date
    }

    // MARK: - Value coercion

    static func intValue(_ any: Any?) -> Int? {
        switch any {
        case let n as Int: return n
        case let n as Double: return Int(n)
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s) ?? Double(s).map(Int.init)
        default: return nil
        }
    }

    static func decimalValue(_ any: Any?) -> Decimal? {
        switch any {
        case let n as NSNumber: return n.decimalValue
        case let s as String: return Decimal(string: s)
        default: return nil
        }
    }

    private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseTimestamp(_ any: Any?) -> Date? {
        switch any {
        case let s as String:
            return isoWithFraction.date(from: s) ?? isoPlain.date(from: s)
        case let n as NSNumber:
            let v = n.doubleValue
            // Heuristic: epoch millis vs seconds.
            if v > 1_000_000_000_000 { return Date(timeIntervalSince1970: v / 1000) }
            if v > 1_000_000_000 { return Date(timeIntervalSince1970: v) }
            return nil
        default:
            return nil
        }
    }

    static func sha256(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
