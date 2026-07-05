import Foundation

/// Incremental line reader: reads new complete lines from a byte offset.
enum ByteReader {
    struct Result {
        let lines: [String]
        let newOffset: UInt64
    }

    /// Reads from `offset` to EOF and returns complete lines. A trailing
    /// partial line (no newline yet) is consumed only if it parses as JSON;
    /// otherwise the offset stops at the last newline so the next scan
    /// picks it up once complete.
    // Bounded per-pass read so a very large .jsonl can't spike memory; scans
    // are incremental (offset advances each pass) so a big append is consumed
    // over successive refreshes.
    static func readNewLines(path: String, from offset: UInt64, maxBytes: Int = 16 * 1024 * 1024) -> Result? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
        } catch {
            return nil
        }
        guard let data = try? handle.read(upToCount: maxBytes), !data.isEmpty else {
            return Result(lines: [], newOffset: offset)
        }

        var consumed = data.count
        var body = data
        if data.last != UInt8(ascii: "\n") {
            if let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) {
                // Keep the trailing partial line for the next pass unless it
                // already parses as standalone JSON.
                let tail = data[data.index(after: lastNewline)...]
                if (try? JSONSerialization.jsonObject(with: tail)) == nil {
                    body = data[..<data.index(after: lastNewline)]
                    consumed = body.count
                }
            } else {
                // Single partial line with no newline at all.
                if (try? JSONSerialization.jsonObject(with: data)) == nil {
                    return Result(lines: [], newOffset: offset)
                }
            }
        }

        guard let text = String(data: body, encoding: .utf8) else {
            // Binary or non-UTF8 content: skip the whole chunk.
            return Result(lines: [], newOffset: offset + UInt64(data.count))
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return Result(lines: lines, newOffset: offset + UInt64(consumed))
    }
}
