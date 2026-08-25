//
//  BrokenSignInVisibilityTests.swift
//  Claude UsageTests
//
//  Created by Claude Code on 2026-08-25.
//

import AppKit
import UsageCore
import XCTest
@testable import Claude_Usage

/// A profile whose Claude Code account was signed out said so in one place:
/// a grey line at the bottom of the popover reading "Your extra usage can't
/// be read". The header said "Partial data", and the menu bar said nothing at
/// all. These cover the three surfaces that now name the account fact.
///
/// The other half of the job is not crying wolf. Every non-raising case has
/// its own assertion here, because a banner and a red dot on a correctly
/// configured profile would be a louder version of the mistake the v4.0.9
/// stream was spent removing.
@MainActor
final class BrokenSignInVisibilityTests: HostedAppTestCase {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    /// The Claude Code states that are genuinely broken.
    private static let raising: [ClaudeUsage.PersonalExtraUsageIssue] = [
        .signInExpired, .signInHasNoToken, .signInUnusable
    ]

    /// Settled facts and transient misses. Nothing here is a broken sign-in:
    /// one was never connected, one is a statement about a different account,
    /// one is a reading the app retries unaided, and one is a claude.ai-side
    /// problem the extra-usage notice already routes to that screen.
    private static let quiet: [ClaudeUsage.PersonalExtraUsageIssue?] = [
        .notLinked, .differentOrganization, .temporarilyUnavailable,
        .claudeAccountUnresolved, nil
    ]

    private func banner(
        for issue: ClaudeUsage.PersonalExtraUsageIssue?,
        hasCredentialError: Bool = false,
        sessionOnlyCredentialCount: Int = 0
    ) -> LegacyPopoverBanner? {
        LegacyPopoverBanner.resolve(
            sessionOnlyCredentialCount: sessionOnlyCredentialCount,
            hasCredentialError: hasCredentialError,
            cliSignInIssue: issue,
            consecutiveRefreshFailures: 0,
            lastSuccessfulRefreshTime: now,
            now: now
        )
    }

    // MARK: - The banner is raised, and only for the broken states

    func testEachBrokenSignInRaisesItsOwnBanner() {
        XCTAssertEqual(
            banner(for: .signInExpired),
            .cliSignInBroken(.expired)
        )
        XCTAssertEqual(
            banner(for: .signInHasNoToken),
            .cliSignInBroken(.signedOut)
        )
        XCTAssertEqual(
            banner(for: .signInUnusable),
            .cliSignInBroken(.unusable)
        )
    }

    func testSettledAndTransientStatesRaiseNoBanner() {
        for issue in Self.quiet {
            XCTAssertNil(
                banner(for: issue),
                "\(String(describing: issue)) is not a broken sign-in and "
                    + "must not put a banner on a working profile"
            )
        }
    }

    /// REGRESSION SHAPE: the claude.ai banner used to send people to Settings
    /// at large, where they re-synced the CLI account, watched it succeed,
    /// and found the banner unchanged. This banner is the mirror image and
    /// must not repeat it in the other direction — Settings at large would
    /// let someone update their claude.ai session key while the Claude Code
    /// complaint they are reading survives untouched.
    func testBrokenSignInBannerRoutesToCLIAccountNotSettingsAtLarge() {
        for problem: LegacyPopoverBanner.CLISignInProblem in [
            .expired, .signedOut, .unusable
        ] {
            XCTAssertEqual(
                LegacyPopoverBanner.cliSignInBroken(problem).action,
                .cliAccount
            )
            XCTAssertNotEqual(
                LegacyPopoverBanner.cliSignInBroken(problem).action,
                .preferences
            )
            XCTAssertNotEqual(
                LegacyPopoverBanner.cliSignInBroken(problem).action,
                .claudeAIAccount
            )
        }
    }

    /// Each of the three says something different, and each resolves to a
    /// real translation rather than falling through to its key.
    func testEachBrokenSignInBannerCarriesItsOwnMessage() {
        let messages = [
            LegacyPopoverBanner.cliSignInBroken(.expired).message,
            LegacyPopoverBanner.cliSignInBroken(.signedOut).message,
            LegacyPopoverBanner.cliSignInBroken(.unusable).message
        ]
        XCTAssertEqual(Set(messages).count, 3)
        for message in messages {
            XCTAssertFalse(message.isEmpty)
            XCTAssertFalse(
                message.hasPrefix("popover.banner."),
                "\(message) fell through to its localization key"
            )
        }
    }

    // MARK: - Precedence

    /// The claude.ai credential produces every number on screen; the Claude
    /// Code one produces a single row. When both are broken, name the bigger
    /// loss.
    func testClaudeAICredentialErrorOutranksABrokenSignIn() {
        for issue in Self.raising {
            XCTAssertEqual(
                banner(for: issue, hasCredentialError: true),
                .credentialError
            )
        }
    }

    /// Still the top of the pile: the others describe something already
    /// broken, this one describes a credential the user can still keep.
    func testHeldCredentialsOutrankEverythingIncludingABrokenSignIn() {
        for issue in Self.raising {
            XCTAssertEqual(
                banner(
                    for: issue,
                    hasCredentialError: true,
                    sessionOnlyCredentialCount: 2
                ),
                .credentialsNotSaved(count: 2)
            )
        }
    }

    /// And it outranks what used to sit directly below the claude.ai banner,
    /// so a stale figure cannot bury a signed-out account.
    func testBrokenSignInOutranksRefreshFailuresAndStaleness() {
        XCTAssertEqual(
            LegacyPopoverBanner.resolve(
                hasCredentialError: false,
                cliSignInIssue: .signInExpired,
                consecutiveRefreshFailures: 8,
                lastSuccessfulRefreshTime: now.addingTimeInterval(-3_000),
                now: now
            ),
            .cliSignInBroken(.expired)
        )
    }

    /// Nothing above changed for a profile with no sign-in problem.
    func testQuietStatesLeaveTheExistingBannersUntouched() {
        for issue in Self.quiet {
            XCTAssertEqual(
                LegacyPopoverBanner.resolve(
                    hasCredentialError: false,
                    cliSignInIssue: issue,
                    consecutiveRefreshFailures: 3,
                    lastSuccessfulRefreshTime: now,
                    now: now
                ),
                .refreshFailed(count: 3)
            )
        }
    }

    // MARK: - The account-health verdict

    func testAuthenticationIssueGetsItsOwnVerdict() {
        let authentication = ProviderPopoverHeader.accountHealthText(
            status: .degraded,
            issue: .authenticationRequired
        )
        let partial = ProviderPopoverHeader.accountHealthText(
            status: .degraded,
            issue: .optionalUsageUnavailable
        )
        XCTAssertNotEqual(
            authentication,
            partial,
            "a signed-out account read as \"Partial data\", which sounds "
                + "like a data hiccup rather than a credential that stopped "
                + "working"
        )
        XCTAssertEqual(
            authentication,
            NormalizedUsageStrings.localized(
                "popover.normalized.health.sign_in_problem",
                default: "Sign-in needs attention"
            )
        )
    }

    /// Every other degraded cause is a figure that did not arrive, not a
    /// credential. Saying "sign-in" about one would put a complaint on a
    /// profile whose credentials are fine.
    func testOtherDegradedCausesStillSayPartialData() {
        let partial = NormalizedUsageStrings.localized(
            "popover.normalized.health.degraded",
            default: "Partial data"
        )
        for issue: ProviderHealthIssue? in [
            .dependencyMissing, .configurationInvalid, .accountUnsupported,
            .transportUnavailable, .protocolMismatch, .responseInvalid,
            .optionalUsageUnavailable, .unknown, nil
        ] {
            XCTAssertEqual(
                ProviderPopoverHeader.accountHealthText(
                    status: .degraded,
                    issue: issue
                ),
                partial,
                "\(String(describing: issue)) is not an authentication "
                    + "problem"
            )
        }
    }

    /// The authentication issue only changes the degraded wording. A healthy
    /// account is still "Available" whatever issue happens to be attached.
    func testNonDegradedVerdictsAreUnchangedByTheIssue() {
        XCTAssertEqual(
            ProviderPopoverHeader.accountHealthText(
                status: .healthy,
                issue: .authenticationRequired
            ),
            NormalizedUsageStrings.localized(
                "popover.normalized.health.healthy",
                default: "Available"
            )
        )
        XCTAssertEqual(
            ProviderPopoverHeader.accountHealthText(
                status: .unauthenticated,
                issue: .authenticationRequired
            ),
            NormalizedUsageStrings.localized(
                "popover.normalized.health.sign_in",
                default: "Sign-in required"
            )
        )
    }

    // MARK: - The menu bar marker

    func testMarkerIsRaisedForEveryBrokenSignIn() {
        for issue in Self.raising {
            XCTAssertTrue(
                MenuBarAttentionSignal.needsAttention(
                    cliSignInIssue: issue,
                    hasCredentialError: false,
                    healthStatus: .degraded
                ),
                "\(issue) left the menu bar saying nothing at all"
            )
        }
    }

    func testMarkerIsAbsentForAHealthyProfile() {
        XCTAssertFalse(
            MenuBarAttentionSignal.needsAttention(
                cliSignInIssue: nil,
                hasCredentialError: false,
                healthStatus: .healthy
            )
        )
    }

    func testMarkerIsAbsentForSettledAndTransientStates() {
        for issue in Self.quiet {
            XCTAssertFalse(
                MenuBarAttentionSignal.needsAttention(
                    cliSignInIssue: issue,
                    hasCredentialError: false,
                    healthStatus: .degraded
                ),
                "\(String(describing: issue)) put a permanent red dot on a "
                    + "correctly configured profile"
            )
        }
    }

    /// Degradation on its own is not a credential problem — a missing
    /// optional figure degrades the account too, and a dot that never goes
    /// away is a dot nobody reads.
    func testDegradedAloneDoesNotRaiseTheMarker() {
        XCTAssertFalse(
            MenuBarAttentionSignal.needsAttention(
                cliSignInIssue: nil,
                hasCredentialError: false,
                healthStatus: .degraded
            )
        )
    }

    /// The claude.ai half, from both signals that carry it.
    func testMarkerIsRaisedForARejectedClaudeAICredential() {
        XCTAssertTrue(
            MenuBarAttentionSignal.needsAttention(
                cliSignInIssue: nil,
                hasCredentialError: true,
                healthStatus: .healthy
            )
        )
        XCTAssertTrue(
            MenuBarAttentionSignal.needsAttention(
                cliSignInIssue: nil,
                hasCredentialError: false,
                healthStatus: .unauthenticated
            )
        )
    }

    /// The marker and the banner must never disagree about which states are
    /// broken, which is why both ask `CLISignInProblem`. If a future case is
    /// added to one path only, this fails.
    func testMarkerAndBannerAgreeOnEveryState() {
        for issue in Self.raising.map(Optional.some) + Self.quiet {
            XCTAssertEqual(
                MenuBarAttentionSignal.needsAttention(
                    cliSignInIssue: issue,
                    hasCredentialError: false,
                    healthStatus: .degraded
                ),
                banner(for: issue) != nil,
                "\(String(describing: issue)) is treated differently by the "
                    + "menu bar and the popover"
            )
        }
    }

    // MARK: - The marker as drawn

    private func makeProfile(
        issue: ClaudeUsage.PersonalExtraUsageIssue?
    ) -> Profile {
        var usage = ClaudeUsage.empty
        usage.sessionPercentage = 42
        usage.sessionPercentageAvailable = true
        usage.weeklyPercentageAvailable = true
        usage.sessionResetTime = Date().addingTimeInterval(3_600)
        usage.personalExtraUsageIssue = issue
        var profile = Profile(name: "Test")
        profile.claudeUsage = usage
        return profile
    }

    /// `intendedItemWidth(for:config:isActive:)` plans the overflow split by
    /// measuring this same render before the status item exists, and it
    /// cannot know whether an account is broken. A marker that changed the
    /// width would make that plan wrong for exactly the profiles that most
    /// need to stay on screen.
    func testMarkerDoesNotChangeTheRenderedWidth() {
        let manager = retain(StatusBarUIManager())
        defer { manager.cleanup() }
        let profile = makeProfile(issue: .signInExpired)
        let config = MultiProfileDisplayConfig()

        let plain = manager.renderProfileMenuBar(
            for: profile,
            config: config,
            isDarkMode: false,
            isActive: false
        )
        let marked = manager.renderProfileMenuBar(
            for: profile,
            config: config,
            isDarkMode: false,
            isActive: false,
            needsAttention: true
        )

        XCTAssertEqual(
            marked.image.size.width,
            plain.image.size.width,
            accuracy: 0.01
        )
        XCTAssertEqual(
            marked.image.size.height,
            plain.image.size.height,
            accuracy: 0.01
        )
    }

    /// And it is actually drawn: the whole complaint was that the menu bar
    /// said nothing, so an identical image would be the same defect with more
    /// code behind it.
    func testMarkerChangesWhatIsDrawn() {
        let manager = retain(StatusBarUIManager())
        defer { manager.cleanup() }
        let profile = makeProfile(issue: .signInExpired)
        let config = MultiProfileDisplayConfig()

        let plain = manager.renderProfileMenuBar(
            for: profile,
            config: config,
            isDarkMode: false,
            isActive: false
        )
        let marked = manager.renderProfileMenuBar(
            for: profile,
            config: config,
            isDarkMode: false,
            isActive: false,
            needsAttention: true
        )

        XCTAssertNotEqual(
            marked.image.tiffRepresentation,
            plain.image.tiffRepresentation,
            "the attention marker left the icon unchanged"
        )
    }

    /// Why the marker is its own pass rather than an extra argument to
    /// `applyProviderBadge`, which is the other overlay this icon already
    /// has.
    ///
    /// The badge is applied BEFORE the line that decides template rendering:
    ///
    ///     badgedImage.isTemplate = useMonochrome
    ///         && !config.showPaceMarker
    ///         && !badgeStyle.showsTint
    ///
    /// A marker drawn inside the badge pass would be inside `badgedImage`
    /// when that runs, and for a monochrome user with no pace marker and an
    /// untinted badge it evaluates to `true` — AppKit then redraws the whole
    /// image from its alpha channel in the menu bar's foreground colour and
    /// the red dot becomes the same grey as the icon it sits on. The one
    /// person who most needs a coloured alarm is the one who switched every
    /// other colour off. Marking after that assignment, and forcing
    /// `isTemplate` back off, is what keeps the dot red.
    func testMarkedIconIsNeverTemplateRendered() {
        let manager = retain(StatusBarUIManager())
        defer { manager.cleanup() }
        let profile = makeProfile(issue: .signInExpired)
        var monochrome = MultiProfileDisplayConfig()
        monochrome.useSystemColor = true
        monochrome.showPaceMarker = false

        for isActive in [false, true] {
            let marked = manager.renderProfileMenuBar(
                for: profile,
                config: monochrome,
                isDarkMode: false,
                isActive: isActive,
                needsAttention: true
            )
            XCTAssertFalse(
                marked.image.isTemplate,
                "template rendering would repaint the marker in the menu "
                    + "bar's foreground colour, hiding it from exactly the "
                    + "monochrome users who have no other colour to notice"
            )
        }
    }

    /// The premise of the test above, asserted rather than assumed: the
    /// healthy monochrome icon really is template-rendered, so "the marker
    /// would have been flattened" is a live hazard and not a hypothetical.
    /// It also pins that nothing changed for unmarked icons.
    func testUnmarkedMonochromeIconIsStillTemplateRendered() throws {
        try XCTSkipIf(
            ProfileManager.shared.providerBadgeStyle.showsTint,
            "a tinted badge already forces isTemplate off, so this run "
                + "cannot demonstrate the flattening hazard"
        )
        let manager = retain(StatusBarUIManager())
        defer { manager.cleanup() }
        let profile = makeProfile(issue: nil)
        var monochrome = MultiProfileDisplayConfig()
        monochrome.useSystemColor = true
        monochrome.showPaceMarker = false

        let plain = manager.renderProfileMenuBar(
            for: profile,
            config: monochrome,
            isDarkMode: false,
            isActive: false
        )
        XCTAssertTrue(
            plain.image.isTemplate,
            "an untinted monochrome icon is template-rendered, as it always "
                + "has been — which is exactly why a marker drawn before "
                + "that assignment would lose its colour"
        )
    }

    /// The active-profile underline is drawn onto a taller canvas; the marker
    /// runs after it and must not undo that.
    func testMarkerPreservesTheActiveProfileUnderlineGeometry() {
        let manager = retain(StatusBarUIManager())
        defer { manager.cleanup() }
        let profile = makeProfile(issue: .signInHasNoToken)
        let config = MultiProfileDisplayConfig()

        let active = manager.renderProfileMenuBar(
            for: profile,
            config: config,
            isDarkMode: false,
            isActive: true
        )
        let activeMarked = manager.renderProfileMenuBar(
            for: profile,
            config: config,
            isDarkMode: false,
            isActive: true,
            needsAttention: true
        )

        XCTAssertEqual(
            activeMarked.image.size.height,
            active.image.size.height,
            accuracy: 0.01
        )
        XCTAssertNotEqual(
            activeMarked.image.tiffRepresentation,
            active.image.tiffRepresentation
        )
    }
}
