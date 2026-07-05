import Foundation
import Security

/// Official account usage: the same numbers Claude Code's /usage screen shows.
struct OfficialQuota: Codable, Equatable {
    struct Limit: Codable, Equatable, Identifiable {
        let kind: String          // session | weekly_all | weekly_scoped
        let percent: Double
        let resetsAt: Date?
        let scopeName: String?    // model display name for weekly_scoped
        let isActive: Bool
        let severity: String?

        var id: String { "\(kind)|\(scopeName ?? "")" }

        var label: String {
            switch kind {
            case "session": return "Session"
            case "weekly_all": return "Weekly · All Models"
            case "weekly_scoped": return "Weekly · \(scopeName ?? "Scoped")"
            default: return kind
            }
        }
    }

    let limits: [Limit]
    let fetchedAt: Date
    let profileName: String?

    var session: Limit? { limits.first { $0.kind == "session" } }
}

/// Fetches official usage from Anthropic's OAuth usage endpoint, authenticated
/// with the user's existing Claude Code login token (read from the Keychain).
/// Read-only: never writes to the Keychain, never touches the refresh token,
/// never sends any local data beyond the authenticated GET itself.
struct ClaudeQuotaFetcher {
    enum FetchError: Error {
        case noCredentials
        case tokenExpired
        case network(String)
        case badResponse(Int)

        var warning: String {
            switch self {
            case .noCredentials: return "Claude Code login not found in Keychain — official usage unavailable"
            case .tokenExpired: return "Claude login token expired — open Claude Code to refresh it"
            case .network: return "Could not reach Anthropic to fetch official usage"
            case .badResponse(let code):
                switch code {
                case 401: return "Claude login token rejected — open Claude Code to refresh it"
                case 429: return "Anthropic usage endpoint is rate limited right now — retrying shortly"
                default: return "Official usage request failed (HTTP \(code))"
                }
            }
        }
    }

    static let keychainService = "Claude Code-credentials"
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    // MARK: - Keychain

    /// Reads the active Claude Code OAuth access token. claude-switch swaps
    /// this Keychain item between profiles, so this always reflects the
    /// currently active account.
    static func readAccessToken() -> Result<String, FetchError> {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: NSUserName(),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        var status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            // Retry without the account attribute in case it differs.
            query.removeValue(forKey: kSecAttrAccount as String)
            status = SecItemCopyMatching(query as CFDictionary, &item)
        }
        guard status == errSecSuccess,
              let data = item as? Data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            return .failure(.noCredentials)
        }
        if let expiresAt = oauth["expiresAt"] as? Double,
           Date(timeIntervalSince1970: expiresAt / 1000) < Date() {
            return .failure(.tokenExpired)
        }
        return .success(token)
    }

    static func activeProfileName() -> String? {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/.active-profile")
        guard let name = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Fetch

    /// Synchronous fetch — call from a background queue only.
    static func fetch(timeout: TimeInterval = 10) -> Result<OfficialQuota, FetchError> {
        let token: String
        switch readAccessToken() {
        case .success(let t): token = t
        case .failure(let error): return .failure(error)
        }

        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data?
        var resultCode = 0
        var resultError: String?
        URLSession.shared.dataTask(with: request) { data, response, error in
            resultData = data
            resultCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            resultError = error?.localizedDescription
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + timeout + 2)

        if let resultError { return .failure(.network(resultError)) }
        guard resultCode == 200, let data = resultData else {
            return .failure(.badResponse(resultCode))
        }
        guard let quota = parse(data: data) else {
            return .failure(.network("Unparseable usage response"))
        }
        return .success(quota)
    }

    // MARK: - Parsing (tolerant, like the log scanner)

    static func parse(data: Data, now: Date = Date()) -> OfficialQuota? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var limits: [OfficialQuota.Limit] = []

        if let rawLimits = object["limits"] as? [[String: Any]] {
            for raw in rawLimits {
                guard let kind = raw["kind"] as? String,
                      let percent = doubleValue(raw["percent"]) else { continue }
                let scope = raw["scope"] as? [String: Any]
                let model = scope?["model"] as? [String: Any]
                limits.append(OfficialQuota.Limit(
                    kind: kind,
                    percent: percent,
                    resetsAt: ClaudeLogScanner.parseTimestamp(raw["resets_at"]),
                    scopeName: model?["display_name"] as? String,
                    isActive: (raw["is_active"] as? Bool) ?? false,
                    severity: raw["severity"] as? String
                ))
            }
        }

        // Fallback for older response shapes without a limits array.
        if limits.isEmpty {
            if let five = object["five_hour"] as? [String: Any],
               let pct = doubleValue(five["utilization"]) {
                limits.append(OfficialQuota.Limit(
                    kind: "session", percent: pct,
                    resetsAt: ClaudeLogScanner.parseTimestamp(five["resets_at"]),
                    scopeName: nil, isActive: false, severity: nil
                ))
            }
            if let seven = object["seven_day"] as? [String: Any],
               let pct = doubleValue(seven["utilization"]) {
                limits.append(OfficialQuota.Limit(
                    kind: "weekly_all", percent: pct,
                    resetsAt: ClaudeLogScanner.parseTimestamp(seven["resets_at"]),
                    scopeName: nil, isActive: false, severity: nil
                ))
            }
        }

        guard !limits.isEmpty else { return nil }
        return OfficialQuota(limits: limits, fetchedAt: now, profileName: activeProfileName())
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        switch any {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }
}
