//

import UsageCore
//  ClaudeSetupState.swift
//  Claude Usage
//

enum ClaudeSetupState: Equatable, Sendable {
    case complete
    case browserOnly
    case terminalOnly
    case none

    static func of(_ profile: Profile) -> ClaudeSetupState {
        let hasBrowserSignIn = profile.hasClaudeAI
        let hasTerminalSignIn = profile.cliCredentialsJSON != nil || profile.hasCliAccount

        switch (hasBrowserSignIn, hasTerminalSignIn) {
        case (true, true):
            return .complete
        case (true, false):
            return .browserOnly
        case (false, true):
            return .terminalOnly
        case (false, false):
            return .none
        }
    }
}

enum ClaudeAccountAttention {
    /// What the Claude Account row in the Settings sidebar should say about
    /// this profile, or `nil` for no badge.
    ///
    /// Two different problems, deliberately not collapsed into one word.
    /// "Incomplete" is a sign-in that was never added; "Needs attention" is
    /// one that was added and has stopped working. They are repaired by
    /// different steps on the page the badge leads to.
    enum Badge: Equatable {
        /// Only the terminal sign-in is linked, so the profile will go
        /// silent when that sign-in lapses.
        case setupIncomplete
        /// claude.ai has started rejecting the stored session key, so every
        /// number for this profile is frozen.
        case browserSignInBroken

        var localizationKey: String {
            switch self {
            case .setupIncomplete:
                return "claude_account.incomplete_badge"
            case .browserSignInBroken:
                return "claude_account.summary.status.needs_attention"
            }
        }
    }

    static func isSetupIncomplete(
        _ profile: Profile,
        snapshot: ClaudeSetupState? = nil
    ) -> Bool {
        profile.providerID == .claude
            && (snapshot ?? ClaudeSetupState.of(profile)) == .terminalOnly
    }

    /// - Parameter browserSignInNeedsAttention: the menu bar's own verdict
    ///   for this profile, relayed through `ClaudeSignInAttentionStore`. The
    ///   sidebar cannot derive it: a rejected session key is still a stored
    ///   session key, which is why the sidebar showed nothing at all while
    ///   the menu bar carried the red disc.
    static func badge(
        _ profile: Profile,
        snapshot: ClaudeSetupState? = nil,
        browserSignInNeedsAttention: Bool = false
    ) -> Badge? {
        guard profile.providerID == .claude else { return nil }
        // Missing outranks broken: a terminal-only profile has no browser
        // sign-in to be broken, and its verdict names the step that fixes it.
        if isSetupIncomplete(profile, snapshot: snapshot) {
            return .setupIncomplete
        }
        return browserSignInNeedsAttention ? .browserSignInBroken : nil
    }
}
