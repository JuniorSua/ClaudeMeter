import Foundation

/// Thin wrapper around the claude-switch CLI (keychain mode): lists profiles
/// and swaps the active Claude Code login. All reads/writes happen through
/// /usr/bin/security inside claude-switch itself, so switching is silent —
/// no keychain prompts.
enum ProfileSwitcher {
    enum SwitchResult: Equatable {
        case success
        case failure(String)
    }

    static var executablePath: String? {
        Shell.which("claude-switch")
    }

    /// claude-switch storage mode, read straight from its config file so it
    /// costs a file read, not a subprocess. "keychain" (shared login slot,
    /// the default) or "isolated" (one CLAUDE_CONFIG_DIR per profile).
    static func storageMode() -> String {
        let config = NSHomeDirectory() + "/.config/claude-switch/config"
        guard let text = try? String(contentsOfFile: config, encoding: .utf8) else { return "keychain" }
        for line in text.split(separator: "\n") where line.hasPrefix("mode=") {
            let mode = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if !mode.isEmpty { return mode }
        }
        return "keychain"
    }

    static var profilesRoot: String {
        NSHomeDirectory() + "/.config/claude-switch/profiles"
    }

    static func profileDirectory(_ name: String) -> String {
        profilesRoot + "/" + name
    }

    /// Credentials JSON for an isolated profile (written by Claude Code when
    /// CLAUDE_CONFIG_DIR points at the profile's dir). Nil when absent.
    static func isolatedCredentials(profile: String) -> Data? {
        FileManager.default.contents(atPath: profileDirectory(profile) + "/.credentials.json")
    }

    /// Profile names, in claude-switch's own order. Empty when claude-switch
    /// is not installed or has no saved profiles.
    static func listProfiles() -> [String] {
        guard let path = executablePath,
              let out = Shell.run(path, arguments: ["list"], timeout: 5),
              out.exitCode == 0 else { return [] }
        return out.stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Switches the active profile. Only names returned by `listProfiles()`
    /// are accepted, so arbitrary strings never reach the shell.
    /// Re-switching to the already-active profile is allowed — it re-syncs
    /// the Keychain when `.active-profile` and credentials have drifted apart.
    static func switchTo(_ name: String, knownProfiles: [String]) -> SwitchResult {
        guard knownProfiles.contains(name) else {
            return .failure("Unknown profile “\(name)”")
        }
        guard let path = executablePath else {
            return .failure("claude-switch not found — install it and restart ClaudeMeter")
        }
        guard let out = Shell.run(path, arguments: [name], timeout: 30) else {
            return .failure("Profile switch timed out — try `claude-switch \(name)` in Terminal")
        }
        guard out.exitCode == 0 else {
            let detail = stripANSI(out.stderr + out.stdout)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return .failure("Profile switch failed (exit \(out.exitCode)) — try `claude-switch \(name)` in Terminal")
            }
            return .failure(detail)
        }
        return .success
    }

    /// Subscription plan ("pro", "max", …) saved in a profile's login.
    /// Isolated mode reads the profile dir's credentials file; keychain mode
    /// reads the shared/per-profile items silently via /usr/bin/security.
    static func subscription(for name: String, isActive: Bool) -> String? {
        if storageMode() == "isolated" {
            guard let data = isolatedCredentials(profile: name) else { return nil }
            return subscriptionType(fromCredentials: data)
        }
        let service = isActive ? "Claude Code-credentials" : "Claude Code-credentials-\(name)"
        guard let out = Shell.run(
            "/usr/bin/security",
            arguments: ["find-generic-password", "-s", service, "-w"],
            timeout: 5
        ), out.exitCode == 0,
              let data = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) else { return nil }
        return subscriptionType(fromCredentials: data)
    }

    private static func subscriptionType(fromCredentials data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any] else { return nil }
        return oauth["subscriptionType"] as? String
    }

    /// True while a Claude Code CLI process is running. Switching then is the
    /// classic way profiles get cross-contaminated: the running session keeps
    /// refreshing the *old* account's token into the shared Keychain slot,
    /// and the next switch saves it into the wrong profile.
    static func claudeCLIIsRunning() -> Bool {
        guard let out = Shell.run("/usr/bin/pgrep", arguments: ["-x", "claude"], timeout: 3) else {
            return false
        }
        return out.exitCode == 0
    }

    private static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\u{001B}\\[[0-9;]*m",
            with: "",
            options: .regularExpression
        )
    }
}
