import Testing
import Foundation
@testable import ClaudeMeter

struct ClaudeLogScannerTests {

    // Fixture 1: simple flat usage schema.
    @Test func simpleUsageSchema() throws {
        let line = #"{"timestamp":"2026-07-05T20:00:00Z","model":"claude-sonnet-4","usage":{"input_tokens":1000,"output_tokens":250}}"#
        let parsed = ClaudeLogScanner.parseLine(line, filePath: "/tmp/a.jsonl", lineOffset: 0)
        let event = try #require(parsed.event)
        #expect(event.inputTokens == 1000)
        #expect(event.outputTokens == 250)
        #expect(event.totalTokens == 1250)
        #expect(event.model == "claude-sonnet-4")
        #expect(!parsed.malformed)
    }

    // Fixture 2: nested message.usage + cost_usd.
    @Test func nestedUsageWithCost() throws {
        let line = #"{"created_at":"2026-07-05T20:05:00Z","message":{"usage":{"input_tokens":2000,"output_tokens":500}},"cost_usd":0.012}"#
        let event = try #require(ClaudeLogScanner.parseLine(line, filePath: "/tmp/a.jsonl", lineOffset: 0).event)
        #expect(event.inputTokens == 2000)
        #expect(event.outputTokens == 500)
        #expect(event.totalTokens == 2500)
        #expect(event.estimatedCostUSD == Decimal(string: "0.012"))
    }

    // Fixture 3: limit message with parseable reset clock time, no tokens.
    @Test func limitMessageDetection() throws {
        let line = #"{"timestamp":"2026-07-05T20:10:00Z","error":{"message":"Usage limit reached. Try again at 11:00 PM."}}"#
        let event = try #require(ClaudeLogScanner.parseLine(line, filePath: "/tmp/a.jsonl", lineOffset: 0).event)
        #expect(event.totalTokens == 0)
        let message = try #require(event.rawLimitMessage)
        // Sanitized — the full original text must not be retained.
        #expect(!message.contains("Try again"))
        let resetAt = try #require(event.resetAt)
        #expect(Calendar.current.component(.hour, from: resetAt) == 23)
    }

    // Fixture 4: bad date + numeric strings must not crash.
    @Test func badDateAndNumericStrings() throws {
        let line = #"{"timestamp":"bad-date","usage":{"input_tokens":"100","output_tokens":"50"}}"#
        let event = try #require(ClaudeLogScanner.parseLine(line, filePath: "/tmp/a.jsonl", lineOffset: 0).event)
        #expect(event.inputTokens == 100)
        #expect(event.outputTokens == 50)
    }

    // Fixture 5: the real Claude Code schema observed on this machine.
    @Test func realClaudeCodeSchema() throws {
        let line = #"{"parentUuid":"x","isSidechain":false,"type":"assistant","uuid":"54796a3e-c1d6-4287-9143-4a7dedd3f1ac","timestamp":"2026-07-04T22:37:24.482Z","sessionId":"e88b287e","message":{"model":"claude-opus-4-8","role":"assistant","usage":{"input_tokens":2973,"output_tokens":111,"cache_creation_input_tokens":3551,"cache_read_input_tokens":15198}}}"#
        let event = try #require(ClaudeLogScanner.parseLine(line, filePath: "/tmp/a.jsonl", lineOffset: 0).event)
        #expect(event.id == "54796a3e-c1d6-4287-9143-4a7dedd3f1ac")
        #expect(event.model == "claude-opus-4-8")
        #expect(event.inputTokens == 2973)
        #expect(event.outputTokens == 111)
        #expect(event.cacheCreationTokens == 3551)
        #expect(event.cacheReadTokens == 15198)
        #expect(event.totalTokens == 2973 + 111 + 3551 + 15198)
        #expect(event.sessionID == "e88b287e")
    }

    // Synthetic zero-token placeholder records must be skipped.
    @Test func syntheticRecordSkipped() {
        let line = #"{"uuid":"abc","timestamp":"2026-07-05T21:19:19.537Z","message":{"model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0}},"type":"assistant"}"#
        #expect(ClaudeLogScanner.parseLine(line, filePath: "/tmp/a.jsonl", lineOffset: 0).event == nil)
    }

    // Records with no usage and no limit info are ignored (e.g. user messages).
    @Test func contentOnlyRecordIgnored() {
        let line = #"{"uuid":"u1","type":"user","timestamp":"2026-07-05T20:00:00Z","message":{"role":"user","content":"secret prompt text"}}"#
        #expect(ClaudeLogScanner.parseLine(line, filePath: "/tmp/a.jsonl", lineOffset: 0).event == nil)
    }

    @Test func malformedLineDoesNotCrash() {
        let parsed = ClaudeLogScanner.parseLine("{not json at all", filePath: "/tmp/a.jsonl", lineOffset: 0)
        #expect(parsed.event == nil)
        #expect(parsed.malformed)
    }

    @Test func deduplicationByUUID() throws {
        let line = #"{"uuid":"same-id","timestamp":"2026-07-05T20:00:00Z","model":"claude-sonnet-4","usage":{"input_tokens":10,"output_tokens":5}}"#
        let a = try #require(ClaudeLogScanner.parseLine(line, filePath: "/tmp/a.jsonl", lineOffset: 0).event)
        let b = try #require(ClaudeLogScanner.parseLine(line, filePath: "/tmp/a.jsonl", lineOffset: 999).event)
        #expect(a.id == b.id)
        var merged: [String: UsageEvent] = [:]
        merged[a.id] = a
        merged[b.id] = b
        #expect(merged.count == 1)
    }

    @Test func hashFallbackIsStable() throws {
        let line = #"{"timestamp":"2026-07-05T20:00:00Z","model":"m","usage":{"input_tokens":10,"output_tokens":5}}"#
        let a = try #require(ClaudeLogScanner.parseLine(line, filePath: "/tmp/a.jsonl", lineOffset: 42).event)
        let b = try #require(ClaudeLogScanner.parseLine(line, filePath: "/tmp/a.jsonl", lineOffset: 42).event)
        #expect(a.id == b.id)
        let c = try #require(ClaudeLogScanner.parseLine(line, filePath: "/tmp/a.jsonl", lineOffset: 43).event)
        #expect(a.id != c.id)
    }

    // Full-directory scan with a temp fixture tree, incremental behavior.
    @Test func directoryScanAndIncrementalOffsets() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cm-test-\(UUID().uuidString)/projects/p1")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let root = dir.deletingLastPathComponent().deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }

        let file = dir.appendingPathComponent("session.jsonl")
        let line1 = #"{"uuid":"e1","timestamp":"2026-07-05T20:00:00Z","model":"claude-sonnet-4","usage":{"input_tokens":100,"output_tokens":50}}"#
        try (line1 + "\n").write(to: file, atomically: true, encoding: .utf8)

        let scanner = ClaudeLogScanner()
        let first = scanner.scan(directory: root.path, previousStates: [:])
        #expect(first.events.count == 1)

        // Append a second line; incremental scan should return only the new event.
        let line2 = #"{"uuid":"e2","timestamp":"2026-07-05T20:01:00Z","model":"claude-sonnet-4","usage":{"input_tokens":7,"output_tokens":3}}"#
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: (line2 + "\n").data(using: .utf8)!)
        try handle.close()

        let second = scanner.scan(directory: root.path, previousStates: first.fileStates)
        #expect(second.events.count == 1)
        #expect(second.events.first?.id == "e2")
    }

    @Test func missingDirectoryWarnsWithoutCrashing() {
        let result = ClaudeLogScanner().scan(directory: "/nonexistent/nope", previousStates: [:])
        #expect(result.events.isEmpty)
        #expect(result.warnings.contains { $0.contains("not found") })
    }
}
