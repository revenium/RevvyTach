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
/// **Codex.** A linked `CODEX_HOME` that still resolves, and nothing else —
/// because nothing else exists to read. `hasImmediatelyUsableCredentials` and
/// `claudeUsage` are not "false" and "nil" for a Codex profile in the sense
/// of a failed test; they read fields `Profile.validateProviderIsolation`
/// *throws* on, so they answer "this question does not apply". Enforcing
/// them would silently turn the hotkey into a permanent no-op for every
/// Codex-only user, with no message allowed to explain it. `linkedHome` is
/// the Codex-shaped form of the same question the Claude branch asks, and it
/// matters on its own: activating an unlinked Codex profile *clears*
/// `CODEX_HOME`, repointing every terminal at Codex's own `~/.codex` default.
/// A *linked* home still has to be revalidated, though: `nextEligibleProfile`
/// returns the first match it finds, so a stale link (directory removed,
/// replaced, or on an unavailable volume) sitting earlier in the wrap order
/// would otherwise be chosen over a genuinely usable one later in the list,
/// and only discovered stale after activation had already committed to it.
/// `defaultCodexHomeAvailable` mirrors `CodexSwitchService.switchToHome` —
/// the code `ProfileActivationCodexEffects.live` actually runs to point the
/// terminal at a profile's `CODEX_HOME` — not `CodexProviderFactory`, which
/// answers a different question (can a usage-fetching client be built) and
/// intentionally distrusts a legacy, identity-less link until the user
/// relinks it. Activation itself never demanded that: it re-canonicalizes
/// the path and only compares filesystem identity when one was actually
/// recorded, so a legacy path-only link switches fine as long as the
/// directory is still there. Rejecting it here, even though activation would
/// have accepted it, is a regression this helper must not introduce.
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
        in profiles: [Profile],
        codexHomeAvailable: (CanonicalCodexHome) -> Bool = defaultCodexHomeAvailable
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
            if isEligible(
                candidate,
                switchingFrom: active,
                codexHomeAvailable: codexHomeAvailable
            ) {
                return candidate
            }
        }
        return nil
    }

    /// Whether `candidate` is somewhere the app may send someone, given the
    /// profile it would be leaving. Split out from the walk above so each rule
    /// can be tested without standing up an ordered list.
    ///
    /// `codexHomeAvailable` defaults to `defaultCodexHomeAvailable`, which
    /// mirrors the re-canonicalize-and-compare-identity-if-known check
    /// `CodexSwitchService.switchToHome` performs at activation. Injectable
    /// so tests can stand up a stale-vs-live pair without touching the real
    /// filesystem.
    static func isEligible(
        _ candidate: Profile,
        switchingFrom active: Profile,
        codexHomeAvailable: (CanonicalCodexHome) -> Bool = defaultCodexHomeAvailable
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
            // `readableWeeklyPercentage` is not reset-aware the way
            // `readableSessionPercentage` (via `effectiveSessionPercentage`)
            // is: it returns the stored figure even after
            // `weeklyResetTime` has passed. A weekly window that already
            // rolled over is genuinely free, not still exhausted, so treat
            // an elapsed reset the same way the session branch does.
            let effectiveWeekly = usage.weeklyResetTime < Date()
                ? 0.0
                : weekly
            return max(session, effectiveWeekly) < 100.0

        case .codex(let configuration):
            // Activating an unlinked Codex profile clears `CODEX_HOME` for
            // every terminal, so it is a reset rather than a destination. A
            // *linked* home is not automatically a usable one: the directory
            // can have been removed, replaced, or moved to an unavailable
            // volume since it was linked. Presence alone used to be enough
            // here, but `nextEligibleProfile` stops at the first match — a
            // stale-but-linked profile earlier in the wrap order would be
            // returned and a genuinely usable one later in the list would
            // never be reached. Re-verify the same way activation does.
            guard let linkedHome = configuration.linkedHome else {
                return false
            }
            return codexHomeAvailable(linkedHome)
        }
    }

    /// Revalidates a linked Codex home exactly as `CodexSwitchService
    /// .switchToHome` does — the code that actually runs when a profile
    /// carrying this link is activated — rather than
    /// `CodexProviderFactory.isHomeAvailable`, which additionally requires a
    /// stored filesystem identity and so rejects a legacy path-only link
    /// activation has always accepted.
    ///
    /// Re-canonicalizing is the "does this path still exist and is it still
    /// a directory" check; identity is compared only when the link actually
    /// recorded one, matching `switchToHome`'s own reasoning for why a
    /// missing identity must not be treated as a mismatch.
    private static func defaultCodexHomeAvailable(
        _ linkedHome: CanonicalCodexHome
    ) -> Bool {
        guard let recanonicalized = try? CodexHomeCanonicalizer()
            .canonicalize(linkedHome.path) else {
            return false
        }
        guard let verifiedIdentity = linkedHome.filesystemIdentity else {
            return true
        }
        return verifiedIdentity == recanonicalized.filesystemIdentity
    }
}
