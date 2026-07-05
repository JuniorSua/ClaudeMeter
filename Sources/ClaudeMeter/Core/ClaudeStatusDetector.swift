import Foundation

/// Best-effort, safe discovery of the local claude CLI. Runs only clearly
/// non-interactive commands (which / --version). Purely informational —
/// the app works fully without the CLI.
struct ClaudeStatusDetector {
    struct CLIInfo {
        let path: String
        let version: String?
    }

    static func detect() -> CLIInfo? {
        guard let path = Shell.which("claude") else { return nil }
        let version = Shell.run(path, arguments: ["--version"], timeout: 5)?
            .stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return CLIInfo(path: path, version: version?.isEmpty == false ? version : nil)
    }
}
