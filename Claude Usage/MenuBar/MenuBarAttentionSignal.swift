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
    }

    /// - Parameters:
    ///   - cliSignInIssue: the profile's own Claude Code verdict from its
    ///     last reading. Only the three genuinely broken sign-in states
    ///     raise the marker; `notLinked`, `differentOrganization`,
    ///     `temporarilyUnavailable` and `claudeAccountUnresolved` are settled
    ///     or transient and deliberately raise nothing.
    ///   - hasCredentialError: the claude.ai session key was rejected. Set
    ///     only from the `.unauthenticated` refresh failures, which are
    ///     reachable from the claude.ai error codes alone.
    ///   - healthStatus: the provider's own verdict on the account, so an
    ///     unauthenticated account is marked even on a tick where no refresh
    ///     failure is currently being projected.
    /// - Returns: the credential to name on the icon, or `nil` for no marker.
    static func attention(
        cliSignInIssue: ClaudeUsage.PersonalExtraUsageIssue?,
        hasCredentialError: Bool,
        healthStatus: ProviderHealthStatus?
    ) -> Credential? {
        // claude.ai first, so that when both credentials are broken at once
        // the mark drawn and the words spoken both name the bigger loss.
        // This is the same precedence `LegacyPopoverBanner.resolve` already
        // applies, for the same reason: the claude.ai credential produces
        // every number on screen, the Claude Code one produces a single row.
        // Two surfaces disagreeing about which failure matters more would be
        // worse than either ordering.
        if hasCredentialError { return .claudeAI }

        // Exhaustive on purpose, with no `default:`, matching the discipline
        // in `ClaudeUsageProviderAdapter.accountHealth`: a newly added status
        // must not inherit "no marker" without anyone deciding.
        switch healthStatus {
        case .unauthenticated:
            // Only ever the claude.ai session key. A broken Claude Code
            // sign-in never lowers the account below `.degraded` — see
            // `ClaudeUsageProviderAdapter.accountHealth`, which maps every
            // CLI sign-in failure to `degraded(.authenticationRequired)`.
            return .claudeAI
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
