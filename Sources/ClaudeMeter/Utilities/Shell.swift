import Foundation

/// Runs short, non-interactive commands with a hard timeout. Used only for
/// safe Claude CLI discovery — never sends prompts or content anywhere.
enum Shell {
    struct Output {
        let stdout: String
        let exitCode: Int32
    }

    static func run(_ executable: String, arguments: [String] = [], timeout: TimeInterval = 3) -> Output? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return Output(
            stdout: String(data: data, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus
        )
    }

    /// Resolves a command via /usr/bin/env which (covers nvm/npm-global installs
    /// only if on the login PATH; falls back to common install locations).
    static func which(_ command: String) -> String? {
        if let out = run("/usr/bin/which", arguments: [command]), out.exitCode == 0 {
            let path = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty { return path }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.npm-global/bin/\(command)",
            "/usr/local/bin/\(command)",
            "/opt/homebrew/bin/\(command)",
            "\(home)/.local/bin/\(command)"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
