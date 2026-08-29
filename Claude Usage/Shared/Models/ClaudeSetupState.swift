//

import UsageCore
//  ClaudeSetupState.swift
//  Claude Usage
//

enum ClaudeSetupState: Equatable, Hashable, Sendable {
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

    /// True only for the exact `.none` case of an *optional*
    /// `ClaudeSetupState?` — never for a nil one.
    ///
    /// `setupState == .none` on an optional is a Swift ambiguity trap: the
    /// bare `.none` resolves to `Optional<ClaudeSetupState>.none` (a literal
    /// nil check), silently shadowing the enum's own `.none` case, so an
    /// unset `setupState` always matched regardless of the real state (bugs
    /// on PR #98 in both `MenuBarAttentionSignal.attention` and
    /// `LegacyPopoverBanner.resolve`, independently). One predicate here is
    /// what keeps a future call site from rediscovering the same trap.
    static func isExactlyNone(_ state: ClaudeSetupState?) -> Bool {
        guard let state else { return false }
        return state == ClaudeSetupState.none
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
        /// Neither sign-in is linked, so no number can be produced at all.
        case setupIncomplete
        /// claude.ai has started rejecting the stored session key, so the
        /// organization-wide extra usage for this profile is unreachable.
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

    /// Whether this profile can produce no usage numbers at all.
    ///
    /// Only `.none` qualifies now. It used to be `.terminalOnly`, from when
    /// the claude.ai sign-in produced every figure and a profile without one
    /// was genuinely half-configured. The Claude Code sign-in produces them
    /// now, so a terminal-only profile is complete: full percentages, every
    /// per-model row, its own extra-usage row, and a login the app renews
    /// unaided. Warning about it was telling people to fix something that
    /// worked.
    ///
    /// Every surface that renders an incomplete state reads through here or
    /// through the same `.none` test — the popover banner, the menu-bar
    /// marker, the Settings sidebar badge, the section pill, the account
    /// page verdict. Miss one and the app contradicts itself.
    static func isSetupIncomplete(
        _ profile: Profile,
        snapshot: ClaudeSetupState? = nil
    ) -> Bool {
        guard profile.providerID == .claude else { return false }
        // A Console API profile has credentials and shows figures; it simply
        // shows billing rather than usage, and neither sign-in applies to it.
        // `ClaudeSetupState.of` reports it as `.none` because it holds
        // neither, so without this guard narrowing the predicate to `.none`
        // would have started accusing it. It never raised the warning before
        // and must not start now.
        guard !profile.hasAPIConsole else { return false }
        return (snapshot ?? ClaudeSetupState.of(profile)) == .none
    }

    /// Numbers work, but from the browser sign-in only: no automatic
    /// renewal, no account switching, and no member extra-usage row.
    ///
    /// Informational, never a warning. Nothing is broken and nothing is
    /// missing that stops the app working — this is the state that earns a
    /// "Recommended" nudge on the account page, not a red badge anywhere.
    static func isMissingTerminalSignIn(
        _ profile: Profile,
        snapshot: ClaudeSetupState? = nil
    ) -> Bool {
        profile.providerID == .claude
            && (snapshot ?? ClaudeSetupState.of(profile)) == .browserOnly
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
        // Missing outranks broken, and now means something narrower: a
        // profile with neither sign-in, which can produce no number at all.
        // A terminal-only profile is no longer badged — it is complete.
        if isSetupIncomplete(profile, snapshot: snapshot) {
            return .setupIncomplete
        }
        // And it must hold a browser sign-in for one to be broken. A
        // terminal-only profile has none, so an `.unauthenticated` verdict
        // there is about its Claude Code sign-in and belongs to that row.
        guard (snapshot ?? ClaudeSetupState.of(profile)) != .terminalOnly
        else { return nil }
        return browserSignInNeedsAttention ? .browserSignInBroken : nil
    }
}
