//
//  ClaudeBrowserSignInRecovery.swift
//  Claude Usage
//
//  One refresh, plus the one thing worth trying when claude.ai says the
//  browser sign-in is no longer accepted: reading the cookie again from the
//  Chrome profile it came from.
//

import Foundation

/// Wraps a Claude usage fetch so a revoked browser sign-in gets exactly one
/// chance to repair itself before the profile is reported as expired.
///
/// A refusal reaches this code in two shapes, and both mean the same thing:
///
/// * the fetch throws `sessionKeyExpired`, which is how a claude.ai HTTP 403
///   whose body says `account_session_invalid` arrives — see
///   `ClaudeAISessionRefusal`; or
/// * the fetch succeeds on the Claude Code sign-in and reports
///   `browserSignInIssue == .expired`, because only the claude.ai supplement
///   was refused.
///
/// The repair is attempted once. Whether it happens at all, and how often it
/// may be retried, is `ChromeSessionKeyAutoReReader`'s decision, not this
/// one's.
nonisolated enum ClaudeBrowserSignInRecovery {
    /// Whether a returned reading says the browser sign-in was refused.
    static func isRefusal(_ usage: ClaudeUsage) -> Bool {
        usage.browserSignInIssue == .expired
    }

    /// Whether a thrown error says the browser sign-in was refused.
    static func isRefusal(_ error: Error) -> Bool {
        (error as? AppError)?.code == .sessionKeyExpired
    }

    /// The decision, with every boundary supplied by the caller.
    ///
    /// - Parameters:
    ///   - initialFetch: the refresh as it would have run without any of this.
    ///   - reRead: one attempt to re-read the key from Chrome.
    ///   - retryFetch: the same refresh again, with the renewed key.
    static func fetch(
        initialFetch: () async throws -> ClaudeUsage,
        reRead: () async -> ChromeSessionKeyReReadOutcome,
        retryFetch: (String) async throws -> ClaudeUsage
    ) async throws -> ClaudeUsage {
        do {
            let usage = try await initialFetch()
            guard isRefusal(usage) else { return usage }
            guard case .renewed(let sessionKey) = await reRead() else {
                // Nothing was renewed, so nothing changed. The reading keeps
                // the expired verdict it arrived with, which is the state
                // this profile had before any of this ran.
                return usage
            }
            // A retry that fails must not lose the reading already in hand:
            // the Claude Code sign-in produced real numbers on the first
            // fetch, and they are still true.
            return (try? await retryFetch(sessionKey)) ?? usage
        } catch {
            guard isRefusal(error) else { throw error }
            guard case .renewed(let sessionKey) = await reRead() else {
                throw error
            }
            return try await retryFetch(sessionKey)
        }
    }

    /// The production wiring.
    static func fetch(
        using request: ClaudeAPIService.CapturedUsageRequest,
        profile: Profile,
        apiService: ClaudeAPIService,
        reReader: ChromeSessionKeyAutoReReader
    ) async throws -> ClaudeUsage {
        try await fetch(
            initialFetch: {
                try await apiService.fetchUsageData(using: request)
            },
            reRead: {
                await reReader.reReadAfterRefusal(
                    profileID: profile.id,
                    profileName: profile.name,
                    source: profile.chromeSessionKeySource,
                    currentSessionKey: profile.claudeSessionKey
                )
            },
            retryFetch: { sessionKey in
                try await apiService.fetchUsageData(
                    using: request.replacingBrowserSessionKey(sessionKey)
                )
            }
        )
    }
}
