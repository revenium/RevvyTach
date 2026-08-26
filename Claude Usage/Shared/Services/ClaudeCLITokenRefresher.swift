import Foundation

/// Renews the OAuth access token inside a stored Claude Code credential blob.
///
/// The app keeps a *snapshot* of the CLI login. Claude Code keeps its own copy
/// fresh, but this copy is only re-synced when a profile is switched, so on a
/// menu bar app left running it ages out (these tokens last roughly eight
/// hours) and every request made with it starts failing within a day.
///
/// The endpoint and client id are Claude Code's own public OAuth values, taken
/// verbatim from its configuration; the client id matches the
/// `application.uuid` that `/api/oauth/profile` reports back.
///
/// Failure is always silent and non-destructive: the caller keeps the stored
/// credential exactly as it was and simply goes without the figure that needed
/// it. Losing a credential that still works is a far worse outcome than
/// missing one number.
enum ClaudeCLITokenRefresher {
    static let tokenEndpoint = "https://platform.claude.com/v1/oauth/token"
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    /// The top-level key the CLI stores its OAuth material under. The whole
    /// blob is rewritten around it so unrelated keys survive a refresh.
    private static let oauthKey = "claudeAiOauth"

    /// Reads the refresh token out of a stored credential blob.
    static func refreshToken(in credentialsJSON: String) -> String? {
        guard
            let data = credentialsJSON.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            let oauth = json[oauthKey] as? [String: Any],
            let token = oauth["refreshToken"] as? String,
            !token.isEmpty
        else { return nil }
        return token
    }

    /// Why a renewal did not produce a usable credential.
    ///
    /// An expired login and a failed attempt need opposite advice: the first
    /// is fixed by signing in to that Claude Code account again, the second
    /// by nothing the person can do. Telling someone to re-sync an expired
    /// login sends them round a loop where the button appears to work and
    /// changes nothing, because re-syncing copies a login, it does not renew
    /// one.
    enum RefreshFailure: Equatable, Sendable {
        /// The account's login is too old to renew. Signing in again fixes it.
        case expired
        /// The request was cancelled or timed out after dispatch, so the
        /// server may already have spent the refresh token. Replaying this
        /// credential could turn an uncertain result into `invalid_grant`.
        case indeterminate
        /// Anything else: offline, a server error, a malformed credential.
        case unavailable
    }

    enum RefreshOutcome: Equatable, Sendable {
        case renewed(String)
        case failed(RefreshFailure)
    }

    /// Exchanges the stored refresh token for a fresh credential blob.
    static func refreshedCredentials(
        from credentialsJSON: String,
        forAccountNamed accountName: String? = nil,
        session: URLSession = .shared,
        now: Date = Date()
    ) async -> String? {
        switch await refreshOutcome(
            from: credentialsJSON,
            forAccountNamed: accountName,
            session: session,
            now: now
        ) {
        case .renewed(let blob):
            return blob
        case .failed:
            return nil
        }
    }

    /// `accountName` names the linked Claude Code account in the log lines
    /// below. Every failure here used to be reported anonymously, so a machine
    /// with several linked accounts produced warnings no one could attribute
    /// to the account that actually needed signing in again.
    static func refreshOutcome(
        from credentialsJSON: String,
        forAccountNamed accountName: String? = nil,
        session: URLSession = .shared,
        now: Date = Date()
    ) async -> RefreshOutcome {
        let account = ClaudeCodeSyncService.describeAccount(accountName)
        guard let refreshToken = refreshToken(in: credentialsJSON) else {
            // A credential with no renewal token at all is one the app copied
            // before the account had a full login stored. Signing in again is
            // what produces one.
            LoggingService.shared.logWarning(
                "CLI credential for \(account) has no refresh token; "
                + "leaving it untouched."
            )
            return .failed(.expired)
        }
        guard let url = URL(string: tokenEndpoint) else {
            return .failed(.unavailable)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID
        ]
        guard let httpBody = try? JSONSerialization.data(
            withJSONObject: body
        ) else { return .failed(.unavailable) }
        request.httpBody = httpBody

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            LoggingService.shared.logWarning(
                "CLI token refresh for \(account) failed: "
                + "\(error.localizedDescription). The stored credential is "
                + "unchanged."
            )
            let urlError = error as? URLError
            if Task.isCancelled
                || urlError?.code == .cancelled
                || urlError?.code == .timedOut
            {
                return .failed(.indeterminate)
            }
            return .failed(.unavailable)
        }

        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            // The OAuth error code separates "this login is simply too old,
            // sign in again" from "our request is malformed", which look
            // identical as a bare 400 and lead to completely different
            // remedies. Only the code is logged; the body also carries
            // tokens.
            let object = try? JSONSerialization.jsonObject(with: data)
            let code = (object as? [String: Any])?["error"] as? String
            LoggingService.shared.logWarning(
                "CLI token refresh for \(account) returned HTTP \(status)"
                + (code.map { " (\($0))" } ?? "")
                + ". The stored credential is unchanged."
                + (code == "invalid_grant"
                   ? " This login has expired; signing in to that Claude Code"
                     + " account again will renew it."
                   : "")
            )
            return .failed(code == "invalid_grant" ? .expired : .unavailable)
        }

        guard let merged = merging(
            tokenResponse: data,
            into: credentialsJSON,
            now: now
        ) else {
            LoggingService.shared.logWarning(
                "CLI token refresh response for \(account) could not be "
                + "applied. The stored credential is unchanged."
            )
            return .failed(.unavailable)
        }
        return .renewed(merged)
    }

    /// Rewrites a stored credential blob around a token-endpoint response.
    ///
    /// Every key the caller did not send back is preserved, because the server
    /// answers with the OAuth fields only while the CLI blob also carries
    /// subscription and account material the app still needs. The refresh
    /// token is deliberately overwritten when the server returns one: it may
    /// be rotated, and keeping the old one would break the *next* refresh.
    static func merging(
        tokenResponse data: Data,
        into credentialsJSON: String,
        now: Date = Date()
    ) -> String? {
        guard
            let response = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            let accessToken = response["access_token"] as? String,
            !accessToken.isEmpty,
            let existingData = credentialsJSON.data(using: .utf8),
            var json = try? JSONSerialization.jsonObject(with: existingData)
                as? [String: Any]
        else { return nil }

        var oauth = json[oauthKey] as? [String: Any] ?? [:]
        oauth["accessToken"] = accessToken
        if let refreshed = response["refresh_token"] as? String,
           !refreshed.isEmpty {
            oauth["refreshToken"] = refreshed
        }
        if let expiresIn = response["expires_in"] as? Double {
            // The CLI stores expiry as milliseconds since epoch.
            oauth["expiresAt"] = (now.timeIntervalSince1970 + expiresIn) * 1000
        }
        if let scope = response["scope"] as? String, !scope.isEmpty {
            oauth["scopes"] = scope.split(separator: " ").map(String.init)
        }
        json[oauthKey] = oauth

        guard let encoded = try? JSONSerialization.data(
            withJSONObject: json
        ) else { return nil }
        return String(data: encoded, encoding: .utf8)
    }
}
