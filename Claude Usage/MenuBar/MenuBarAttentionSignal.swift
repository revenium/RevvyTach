import Foundation
import UsageCore

/// Whether a profile's menu-bar icon should carry the attention marker, and
/// — since a Claude profile has two credentials that fail independently —
/// which of the two is broken.
///
/// The menu bar said nothing at all about a broken account. Health was
/// computed correctly and reached the popover, but the Claude render path
/// (`StatusBarUIManager.updateMultiProfileButtons` /
/// `renderProfileMenuBar`) takes only a `Profile` and a display config, so
/// nothing about a credential ever reached the thing on screen. Someone whose
/// Claude Code account was signed out had to open the popover and read a grey
/// footnote to find out.
///
/// The first pass at that fix returned a `Bool`, which produced an identical
/// red dot and an identical "sign-in needs attention" tooltip for two
/// unrelated failures with two unrelated remedies — a signal that says
/// something is wrong without saying what, on the one surface a person
/// actually looks at. The verdict is a `Credential?` so every surface can
/// name which one.
///
/// The kind selects BOTH the mark and the wording. claude.ai is a filled red
/// disc, Claude Code a hollow amber ring, and the difference is deliberately
/// carried in the SHAPE and not only the colour: red against amber is one of
/// the first pairs to fail for a colourblind viewer, while solid against
/// hollow survives that and survives being read at 4pt. Which mark goes to
/// which credential follows the loss — the solid one, the mark that reads as
/// heavier, belongs to the credential that takes every number on screen with
/// it. The wording carries the same fact for anyone reaching the icon through
/// a tooltip or VoiceOver, where no shape reaches at all.
///
/// This is the one decision behind the marker, kept apart from the drawing so
/// it can be tested without AppKit — and so it cannot drift from the popover
/// banner: both ask `LegacyPopoverBanner.CLISignInProblem` the same question,
/// and a case added there changes both surfaces at once or neither.
enum MenuBarAttentionSignal {
    /// Which of a profile's two independent credentials stopped working.
    ///
    /// They are genuinely independent: one can be broken for months while the
    /// other is fine, they are stored separately, they are repaired on
    /// different Settings screens, and they cost the user different things
    /// when they fail. Collapsing them into "sign-in" leaves the person
    /// holding a complaint they cannot act on.
    enum Credential: Equatable {
        /// The claude.ai session key. Every number in the popover and every
        /// percentage in the menu bar comes from it, so when it is rejected
        /// there is nothing left on screen to trust.
        case claudeAI
        /// The Claude Code CLI sign-in. It produces exactly one thing: the
        /// member's own extra-usage figure. Everything else keeps working.
        case claudeCode
        /// A legacy terminal-only profile will go silent when that sign-in
        /// lapses because no browser sign-in exists to renew it.
        case setupIncomplete
    }

    /// - Parameters:
    ///   - cliSignInIssue: the profile's own Claude Code verdict from its
    ///     last reading. Only the three genuinely broken sign-in states
    ///     raise the marker; `notLinked`, `differentOrganization`,
    ///     `temporarilyUnavailable` and `claudeAccountUnresolved` are settled
    ///     or transient and deliberately raise nothing.
    ///   - credentialFailureStreak: how many times in a row the claude.ai
    ///     session key has been rejected — `ProviderRefreshFailure`'s
    ///     `sameKindConsecutiveCount`, or `0` when the last attempt
    ///     succeeded or failed for some other reason. Kind-scoped
    ///     deliberately: a transport failure immediately before the
    ///     rejection must not count toward this streak.
    ///
    ///     A single rejection does not raise the marker. The count was
    ///     already tracked and simply never consulted, so one transient
    ///     refusal lit the menu bar immediately, and because the flag is
    ///     wiped by the next success, opening the popover — which forces a
    ///     refresh — cleared it. That is the exact shape of crying wolf: a
    ///     red dot that is always gone by the time anyone looks at it, on an
    ///     account whose credential works. Two in a row is the smallest
    ///     threshold that distinguishes a credential that stopped working
    ///     from one request that did.
    ///   - healthStatus: the provider's own verdict on the account, so an
    ///     unauthenticated account is marked even on a tick where no refresh
    ///     failure is currently being projected.
    /// - Returns: the credential to name on the icon, or `nil` for no marker.
    static func attention(
        cliSignInIssue: ClaudeUsage.PersonalExtraUsageIssue?,
        credentialFailureStreak: Int,
        healthStatus: ProviderHealthStatus?,
        setupState: ClaudeSetupState? = nil
    ) -> Credential? {
        /// The number of consecutive rejections before the icon says
        /// anything. See `credentialFailureStreak`.
        let credentialFailureThreshold = 2
        // A terminal-only profile is incomplete regardless of which generic
        // refresh error happens to be visible at the same time. Match the
        // popover banner so the icon and its repair destination keep naming
        // the missing browser sign-in until that setup step is completed.
        if setupState == .terminalOnly {
            return .setupIncomplete
        }

        if credentialFailureStreak >= credentialFailureThreshold {
            return .claudeAI
        }

        // Exhaustive on purpose, with no `default:`, matching the discipline
        // in `ClaudeUsageProviderAdapter.accountHealth`: a newly added status
        // must not inherit "no marker" without anyone deciding.
        switch healthStatus {
        case .unauthenticated:
            // Only ever the claude.ai session key. A broken Claude Code
            // sign-in never lowers the account below `.degraded` — see
            // `ClaudeUsageProviderAdapter.accountHealth`, which maps every
            // CLI sign-in failure to `degraded(.authenticationRequired)`.
            //
            // A streak of exactly one is the blip the threshold above exists
            // to absorb, and this branch must not smuggle it back in: the
            // health verdict is derived from that same single failure, so
            // returning here unconditionally would leave the threshold with
            // nothing to do. Zero is different — no failure is being
            // projected at all, so this is a settled verdict carried on the
            // account rather than one bad request, and it is exactly the
            // case this branch was added for.
            return credentialFailureStreak == 0 ? .claudeAI : nil
        case .healthy, .degraded, .unavailable, .unsupported, nil:
            // `.degraded` is deliberately not a marker on its own. It is
            // raised for a figure that did not arrive as much as for a
            // credential that stopped working, and a permanent dot on a
            // profile with a missing optional figure is the crying-wolf
            // failure this whole surface exists to avoid. The sign-in check
            // below is what distinguishes the two.
            break
        }

        guard LegacyPopoverBanner.CLISignInProblem(cliSignInIssue) != nil else {
            return nil
        }
        return .claudeCode
    }
}
