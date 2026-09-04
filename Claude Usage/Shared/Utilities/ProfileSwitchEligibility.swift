//
//  ProfileSwitchEligibility.swift
//  Claude Usage
//
//  Which profile the app is allowed to move to on its own — the Next Profile
//  hotkey, and the auto-switch that fires when the active account is spent.
//

import Foundation
import UsageCore

/// The one rule both automatic profile switches obey.
///
/// The two surfaces used to disagree, and both picked destinations they could
/// not defend. The hotkey took the next entry in the list whatever it was: a
/// Codex profile, a profile already being deleted, or an account whose
/// sign-in had died. Auto-switch looked only at the 5-hour window, so an
/// account sitting at 4% session and 100% weekly read as free, and an account
/// with no reading at all read as empty. Landing on one of those is not a
/// cosmetic miss — activating a profile rewrites `CLAUDE_CONFIG_DIR` or
/// `CODEX_HOME` and the tmux environment, so the terminal follows the app onto
/// an account that cannot serve a request.
///
/// What is actually checked, stated as the code checks it:
///
/// 1. **Not a profile that is being deleted, and not the profile being left.**
///    A tombstone stays in `ProfileManager.profiles` until deletion finalizes
///    and `activateProfile` then refuses it silently, so returning one is a
///    dead switch. Every other candidate-selection site in the app already
///    filters it; this is the last one that did not.
/// 2. **The same provider as the profile being left.** Derived from that
///    profile rather than passed in, so no caller can ask for a
///    cross-provider hop by mistake. Auto-switch used to hard-code `.claude`;
///    it only ever runs from the active Claude profile, which
///    `MenuBarManager.checkAutoSwitchIfNeeded` proves before calling here, so
///    deriving the provider leaves that surface exactly as strict.
/// 3. Then one branch per provider, mirroring
///    `MenuBarManager.canAttemptUsageRefresh` — the app's existing answer to
///    "can we even talk to this account", which is per-provider for the same
///    reason this is.
///
/// **Claude.** Two things, and deliberately not a third:
///
/// - `hasImmediatelyUsableCredentials`. This is a *presence* test, not a
///   liveness test: `hasClaudeAI` and `hasAPIConsole` check only that fields
///   are non-nil, and only `hasValidCLIOAuth` validates anything. It is the
///   property the ticket names, and it is the stricter of the two available
///   (`hasUsageCredentials` also admits an account whose terminal login must
///   be repaired first) — this is a destination we are about to move someone
///   onto, and this rule may only ever get stricter than the one it replaces.
/// - Room in the worse of the two windows. The 5-hour and the 7-day figure
///   must both be present and both below 100%. A missing figure is a reading
///   that was never received, not a zero — `ClaudeUsage.empty` and a
///   half-answered response both land here, and
///   `ClaudeUsageProviderAdapter.accountHealth` already grades a half-answer
///   as degraded health rather than as a partial number worth acting on.
///
/// Not checked: either extra-usage verdict. `personalExtraUsageIssue` is the
/// member row's, `browserSignInIssue` the organization row's, and neither
/// speaks to whether the account can serve a request. `browserSignInIssue` is
/// the tempting one — its `.expired` case really does mean claude.ai rejected
/// a session key — but it is written in exactly one place,
/// `ClaudeAPIService.applyOrganizationExtraUsage`, whose own log line says the
/// percentages on screen come from the Claude Code sign-in and are unaffected.
/// Refusing on it would strand someone on an exhausted account while a working
/// one at 5% sat one slot away, which is the opposite of this feature's job.
/// `personalExtraUsageIssue` fails the same way: `accountHealth` reaches its
/// sign-in cases only after both capacity windows have already arrived, and
/// one of its cases is `.notLinked`, an ordinary well-configured profile.
///
/// **Codex.** A linked `CODEX_HOME`, and nothing else — because nothing else
/// exists to read. `hasImmediatelyUsableCredentials` and `claudeUsage` are not
/// "false" and "nil" for a Codex profile in the sense of a failed test; they
/// read fields `Profile.validateProviderIsolation` *throws* on, so they answer
/// "this question does not apply". Enforcing them would silently turn the
/// hotkey into a permanent no-op for every Codex-only user, with no message
/// allowed to explain it. `linkedHome` is the Codex-shaped form of the same
/// question the Claude branch asks, and it matters on its own: activating an
/// unlinked Codex profile *clears* `CODEX_HOME`, repointing every terminal at
/// Codex's own `~/.codex` default.
///
/// Nothing here ranks candidates by headroom. The nearest eligible profile
/// after the current one wins, wrapping around, exactly as the list has always
/// been walked. If nobody qualifies, the caller stays put.
enum ProfileSwitchEligibility {

    /// The profile an automatic switch away from `activeProfileID` should land
    /// on, or nil when nothing qualifies and the caller must stay put.
    ///
    /// Walks forward from the active profile's position and wraps, returning
    /// the first eligible entry. The active profile is never its own answer.
    static func nextEligibleProfile(
        after activeProfileID: UUID,
        in profiles: [Profile]
    ) -> Profile? {
        // Counted over the whole array, tombstones included, because `count`
        // is also the modulus for the wrap below — filtering here would
        // renumber the walk. It costs nothing: `isEligible` rejects every
        // tombstone, so a list of one live profile plus any number of
        // tombstones still returns nil, just one loop later.
        let count = profiles.count
        guard count > 1,
              let activeIndex = profiles.firstIndex(
                  where: { $0.id == activeProfileID }
              ) else {
            return nil
        }
        let active = profiles[activeIndex]

        for offset in 1..<count {
            let candidate = profiles[(activeIndex + offset) % count]
            if isEligible(candidate, switchingFrom: active) {
                return candidate
            }
        }
        return nil
    }

    /// Whether `candidate` is somewhere the app may send someone, given the
    /// profile it would be leaving. Split out from the walk above so each rule
    /// can be tested without standing up an ordered list.
    static func isEligible(
        _ candidate: Profile,
        switchingFrom active: Profile
    ) -> Bool {
        guard !candidate.deletionInProgress,
              candidate.id != active.id,
              candidate.providerID == active.providerID else {
            return false
        }

        // Exhaustive on purpose, mirroring
        // `MenuBarManager.canAttemptUsageRefresh`: a third provider must fail
        // to compile here rather than inherit whichever branch happened to be
        // the fallthrough.
        switch candidate.providerConfiguration {
        case .claude:
            guard candidate.hasImmediatelyUsableCredentials,
                  let usage = candidate.claudeUsage,
                  let session = usage.readableSessionPercentage,
                  let weekly = usage.readableWeeklyPercentage else {
                return false
            }
            return max(session, weekly) < 100.0

        case .codex(let configuration):
            // Activating an unlinked Codex profile clears `CODEX_HOME` for
            // every terminal, so it is a reset rather than a destination.
            return configuration.linkedHome != nil
        }
    }
}
