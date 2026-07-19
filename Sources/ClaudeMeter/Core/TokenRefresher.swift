import Foundation

/// Mints a fresh access token from a profile's refresh token — the same
/// OAuth grant Claude Code itself performs — so the menu bar stays live even
/// when Claude Code hasn't run for hours (access tokens expire after ~8h).
/// The updated credentials are written back to the same slot they came from;
/// the refresh token is used for nothing else and is only ever sent to
/// Anthropic's own token endpoint.
enum TokenRefresher {
    private static let endpoint = URL(string: "https://platform.claude.com/v1/oauth/token")!
    // Claude Code's public OAuth client id (present in its binary).
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    // The endpoint rate-limits aggressively; never hammer it.
    private static let minAttemptInterval: TimeInterval = 300

    private static let lock = NSLock()
    nonisolated(unsafe) private static var lastAttemptAt: Date?

    /// Returns updated credentials JSON on success; nil on failure or when
    /// throttled. Synchronous — call from a background queue only.
    static func refresh(credentials: Data, timeout: TimeInterval = 15) -> Data? {
        lock.lock()
        if let last = lastAttemptAt, Date().timeIntervalSince(last) < minAttemptInterval {
            lock.unlock()
            return nil
        }
        lastAttemptAt = Date()
        lock.unlock()

        guard var object = (try? JSONSerialization.jsonObject(with: credentials)) as? [String: Any],
              var oauth = object["claudeAiOauth"] as? [String: Any],
              let refreshToken = oauth["refreshToken"] as? String, !refreshToken.isEmpty else {
            return nil
        }

        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID
        ])

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var status = 0
        URLSession.shared.dataTask(with: request) { data, response, _ in
            responseData = data
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + timeout + 2)

        guard status == 200, let data = responseData,
              let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let accessToken = reply["access_token"] as? String, !accessToken.isEmpty else {
            AppLog.general.log("Token refresh failed (HTTP \(status))")
            return nil
        }

        oauth["accessToken"] = accessToken
        let expiresIn = (reply["expires_in"] as? Double) ?? 28800
        oauth["expiresAt"] = (Date().timeIntervalSince1970 + expiresIn) * 1000
        if let newRefresh = reply["refresh_token"] as? String, !newRefresh.isEmpty {
            oauth["refreshToken"] = newRefresh
        }
        object["claudeAiOauth"] = oauth
        AppLog.general.log("Access token refreshed successfully")
        return try? JSONSerialization.data(withJSONObject: object)
    }
}
