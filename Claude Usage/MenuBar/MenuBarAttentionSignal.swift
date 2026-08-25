import Foundation
import UsageCore

/// Whether a profile's menu-bar icon should carry the attention marker.
///
/// The menu bar said nothing at all about a broken account. Health was
/// computed correctly and reached the popover, but the Claude render path
/// (`StatusBarUIManager.updateMultiProfileButtons` /
/// `renderProfileMenuBar`) takes only a `Profile` and a display config, so
/// nothing about a credential ever reached the thing on screen. Someone whose
/// Claude Code account was signed out had to open the popover and read a grey
/// footnote to find out.
///
/// This is the one decision behind the marker, kept apart from the drawing so
/// it can be tested without AppKit — and so it cannot drift from the popover
/// banner: both ask `LegacyPopoverBanner.CLISignInProblem` the same question,
/// and a case added there changes both surfaces at once or neither.
enum MenuBarAttentionSignal {
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
    static func needsAttention(
        cliSignInIssue: ClaudeUsage.PersonalExtraUsageIssue?,
        hasCredentialError: Bool,
        healthStatus: ProviderHealthStatus?
    ) -> Bool {
        if hasCredentialError { return true }

        // Exhaustive on purpose, with no `default:`, matching the discipline
        // in `ClaudeUsageProviderAdapter.accountHealth`: a newly added status
        // must not inherit "no marker" without anyone deciding.
        switch healthStatus {
        case .unauthenticated:
            return true
        case .healthy, .degraded, .unavailable, .unsupported, nil:
            // `.degraded` is deliberately not a marker on its own. It is
            // raised for a figure that did not arrive as much as for a
            // credential that stopped working, and a permanent dot on a
            // profile with a missing optional figure is the crying-wolf
            // failure this whole surface exists to avoid. The sign-in check
            // below is what distinguishes the two.
            break
        }

        return LegacyPopoverBanner.CLISignInProblem(cliSignInIssue) != nil
    }
}
