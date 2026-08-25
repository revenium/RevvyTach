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

    /// The verdict names the credential for the same reason the icon does:
    /// the two are repaired on different Settings screens, so "Sign-in needs
    /// attention" sends half the people who read it to the wrong one.
    func testDegradedVerdictNamesWhichCredentialFailed() {
        let claudeAI = ProviderPopoverHeader.accountHealthText(
            status: .degraded,
            issue: .authenticationRequired,
            credential: .claudeAI
        )
        let claudeCode = ProviderPopoverHeader.accountHealthText(
            status: .degraded,
            issue: .authenticationRequired,
            credential: .claudeCode
        )
        let generic = ProviderPopoverHeader.accountHealthText(
            status: .degraded,
            issue: .authenticationRequired
        )
        XCTAssertNotEqual(
            claudeAI,
            claudeCode,
            "both credentials got the same verdict, which is the defect "
                + "this names its way out of"
        )
        XCTAssertNotEqual(claudeAI, generic)
        XCTAssertNotEqual(claudeCode, generic)
        for verdict in [claudeAI, claudeCode, generic] {
            XCTAssertFalse(
                verdict.hasPrefix("popover.normalized."),
                "\(verdict) fell through to its localization key"
            )
        }
    }

    /// The more severe claude.ai verdict is named too. Leaving the worse
    /// failure — the session key rejected outright, so every figure below is
    /// gone rather than one row of it — as the vaguer sentence would be
    /// exactly backwards.
    func testSignInRequiredNamesClaudeAIWhenItIsKnownToBeClaudeAI() {
        let named = ProviderPopoverHeader.accountHealthText(
            status: .unauthenticated,
            issue: nil,
            credential: .claudeAI
        )
        let generic = ProviderPopoverHeader.accountHealthText(
            status: .unauthenticated,
            issue: nil
        )
        XCTAssertNotEqual(named, generic)
        XCTAssertEqual(
            generic,
            NormalizedUsageStrings.localized(
                "popover.normalized.health.sign_in",
                default: "Sign-in required"
            ),
            "a provider with one credential has nothing to name, and must "
                + "keep the wording it always had"
        )
        XCTAssertEqual(
            named,
            NormalizedUsageStrings.localized(
                "popover.normalized.health.claude_ai_sign_in",
                default: "Claude.ai sign-in required"
            )
        )
    }

    /// Naming a credential must not leak into verdicts that are not about
    /// one. A degraded account with a missing optional figure is still
    /// "Partial data" whoever is passed alongside it.
    func testCredentialDoesNotChangeVerdictsThatAreNotAboutSignIn() {
        for credential: MenuBarAttentionSignal.Credential? in [
            .claudeAI, .claudeCode, nil
        ] {
            XCTAssertEqual(
                ProviderPopoverHeader.accountHealthText(
                    status: .degraded,
                    issue: .optionalUsageUnavailable,
                    credential: credential
                ),
                NormalizedUsageStrings.localized(
                    "popover.normalized.health.degraded",
                    default: "Partial data"
                )
            )
            XCTAssertEqual(
                ProviderPopoverHeader.accountHealthText(
                    status: .healthy,
                    issue: nil,
                    credential: credential
                ),
                NormalizedUsageStrings.localized(
                    "popover.normalized.health.healthy",
                    default: "Available"
                )
            )
        }
    }

    /// The wiring between the popover's own data and the verdict, which is
    /// the part no string comparison above can catch: the header reads the
    /// Claude Code verdict off the profile's usage record, and it must not
    /// name a Claude credential on a profile that has none.
    func testHeaderReadsTheCredentialFromTheProfilesOwnRecord() {
        var usage = ClaudeUsage.empty
        usage.personalExtraUsageIssue = .signInHasNoToken

        XCTAssertEqual(
            ProviderPopoverHeader.attentionCredential(
                providerID: .claude,
                claudeUsage: usage,
                healthStatus: .degraded
            ),
            .claudeCode
        )
        XCTAssertEqual(
            ProviderPopoverHeader.attentionCredential(
                providerID: .claude,
                claudeUsage: nil,
                healthStatus: .unauthenticated
            ),
            .claudeAI
        )
        XCTAssertNil(
            ProviderPopoverHeader.attentionCredential(
                providerID: .claude,
                claudeUsage: nil,
                healthStatus: .healthy
            )
        )

        // A Codex profile has one credential, so there is nothing to name and
        // "Claude.ai" would simply be false.
        XCTAssertNil(
            ProviderPopoverHeader.attentionCredential(
                providerID: .codex,
                claudeUsage: usage,
                healthStatus: .unauthenticated
            ),
            "a non-Claude profile was told which of Claude's two "
                + "credentials had failed"
        )
    }

    /// `claudeAccountUnresolved` degrades the account to
    /// `.authenticationRequired` but is deliberately not a marker, so the
    /// header has nothing to attribute and keeps the generic wording rather
    /// than guessing. Pinned because the two rules live in different files
    /// and a future edit could quietly make this profile blame Claude Code.
    func testUnresolvedClaudeAccountKeepsTheGenericVerdict() {
        var usage = ClaudeUsage.empty
        usage.personalExtraUsageIssue = .claudeAccountUnresolved
        let credential = ProviderPopoverHeader.attentionCredential(
            providerID: .claude,
            claudeUsage: usage,
            healthStatus: .degraded
        )
        XCTAssertNil(credential)
        XCTAssertEqual(
            ProviderPopoverHeader.accountHealthText(
                status: .degraded,
                issue: .authenticationRequired,
                credential: credential
            ),
            NormalizedUsageStrings.localized(
                "popover.normalized.health.sign_in_problem",
                default: "Sign-in needs attention"
            )
        )
    }

    // MARK: - The menu bar marker

    /// A profile has two credentials that fail independently, and the first
    /// pass at this surface gave both of them the same red dot and the same
    /// "sign-in needs attention" tooltip. The verdict has to say WHICH, or
    /// the menu bar is telling someone that something they cannot identify
    /// is broken. The kind is what both the mark and the wording are built
    /// from.
    func testEveryBrokenSignInRaisesTheClaudeCodeKind() {
        for issue in Self.raising {
            XCTAssertEqual(
                MenuBarAttentionSignal.attention(
                    cliSignInIssue: issue,
                    hasCredentialError: false,
                    healthStatus: .degraded
                ),
                .claudeCode,
                "\(issue) is a Claude Code sign-in failure and the icon "
                    + "must say so rather than blaming claude.ai"
            )
        }
    }

    func testMarkerIsAbsentForAHealthyProfile() {
        XCTAssertNil(
            MenuBarAttentionSignal.attention(
                cliSignInIssue: nil,
                hasCredentialError: false,
                healthStatus: .healthy
            )
        )
    }

    func testMarkerIsAbsentForSettledAndTransientStates() {
        for issue in Self.quiet {
            XCTAssertNil(
                MenuBarAttentionSignal.attention(
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
        XCTAssertNil(
            MenuBarAttentionSignal.attention(
                cliSignInIssue: nil,
                hasCredentialError: false,
                healthStatus: .degraded
            )
        )
    }

    /// The claude.ai half, from both signals that carry it.
    func testRejectedClaudeAICredentialRaisesTheClaudeAIKind() {
        XCTAssertEqual(
            MenuBarAttentionSignal.attention(
                cliSignInIssue: nil,
                hasCredentialError: true,
                healthStatus: .healthy
            ),
            .claudeAI
        )
        XCTAssertEqual(
            MenuBarAttentionSignal.attention(
                cliSignInIssue: nil,
                hasCredentialError: false,
                healthStatus: .unauthenticated
            ),
            .claudeAI
        )
    }

    /// The same precedence the banner already applies, for the same reason:
    /// the claude.ai credential produces every number on screen, the Claude
    /// Code one produces a single row. Two surfaces disagreeing about which
    /// failure matters more would be worse than either ordering.
    func testClaudeAIOutranksClaudeCodeWhenBothAreBroken() {
        for issue in Self.raising {
            XCTAssertEqual(
                MenuBarAttentionSignal.attention(
                    cliSignInIssue: issue,
                    hasCredentialError: true,
                    healthStatus: .degraded
                ),
                .claudeAI,
                "\(issue) with a rejected session key must name the bigger "
                    + "loss, as the popover banner does"
            )
            XCTAssertEqual(
                MenuBarAttentionSignal.attention(
                    cliSignInIssue: issue,
                    hasCredentialError: false,
                    healthStatus: .unauthenticated
                ),
                .claudeAI
            )
        }
    }

    /// The mark drawn, the wording spoken and the banner all agree about
    /// which credential comes first, not just about whether something is
    /// wrong — they read the one verdict this asserts. Checked against the
    /// banner itself so the two orderings cannot drift.
    func testMarkAndWordingAndBannerNameTheSameCredentialFirst() {
        for issue in Self.raising {
            XCTAssertEqual(
                banner(for: issue, hasCredentialError: true),
                .credentialError
            )
            XCTAssertEqual(
                MenuBarAttentionSignal.attention(
                    cliSignInIssue: issue,
                    hasCredentialError: true,
                    healthStatus: .degraded
                ),
                .claudeAI
            )
        }
    }

    /// The marker and the banner must never disagree about which states are
    /// broken, which is why both ask `CLISignInProblem`. If a future case is
    /// added to one path only, this fails.
    func testMarkerAndBannerAgreeOnEveryState() {
        for issue in Self.raising.map(Optional.some) + Self.quiet {
            XCTAssertEqual(
                MenuBarAttentionSignal.attention(
                    cliSignInIssue: issue,
                    hasCredentialError: false,
                    healthStatus: .degraded
                ) != nil,
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

    private func render(
        attention: MenuBarAttentionSignal.Credential?,
        isActive: Bool = false,
        config: MultiProfileDisplayConfig = MultiProfileDisplayConfig(),
        manager: StatusBarUIManager
    ) -> StatusBarUIManager.ProfileMenuBarRender {
        manager.renderProfileMenuBar(
            for: makeProfile(issue: .signInExpired),
            config: config,
            isDarkMode: false,
            isActive: isActive,
            attention: attention
        )
    }

    /// `intendedItemWidth(for:config:isActive:)` plans the overflow split by
    /// measuring this same render before the status item exists, and it
    /// cannot know whether an account is broken. A marker that changed the
    /// width would make that plan wrong for exactly the profiles that most
    /// need to stay on screen. Both markers, since either can be the one
    /// drawn.
    func testNeitherMarkerChangesTheRenderedSize() {
        let manager = retain(StatusBarUIManager())
        defer { manager.cleanup() }
        let plain = render(attention: nil, manager: manager)

        for credential: MenuBarAttentionSignal.Credential in [
            .claudeAI, .claudeCode
        ] {
            let marked = render(attention: credential, manager: manager)
            XCTAssertEqual(
                marked.image.size.width,
                plain.image.size.width,
                accuracy: 0.01,
                "\(credential) changed the icon's width, which would make "
                    + "the overflow plan wrong for a broken profile"
            )
            XCTAssertEqual(
                marked.image.size.height,
                plain.image.size.height,
                accuracy: 0.01
            )
        }
    }

    /// And they are actually drawn, and drawn DIFFERENTLY. The whole
    /// complaint was that the menu bar said nothing; two identical marks for
    /// two unrelated failures would be the same complaint one level in.
    func testTheTwoMarkersDifferFromEachOtherAndFromNoMarker() {
        let manager = retain(StatusBarUIManager())
        defer { manager.cleanup() }
        let plain = render(attention: nil, manager: manager)
        let claudeAI = render(attention: .claudeAI, manager: manager)
        let claudeCode = render(attention: .claudeCode, manager: manager)

        XCTAssertNotEqual(
            claudeAI.image.tiffRepresentation,
            plain.image.tiffRepresentation,
            "the claude.ai marker left the icon unchanged"
        )
        XCTAssertNotEqual(
            claudeCode.image.tiffRepresentation,
            plain.image.tiffRepresentation,
            "the Claude Code marker left the icon unchanged"
        )
        XCTAssertNotEqual(
            claudeAI.image.tiffRepresentation,
            claudeCode.image.tiffRepresentation,
            "both credentials drew the same mark, so the menu bar still "
                + "cannot say which one is broken"
        )
    }

    /// Colour alone would carry nothing for a red/green-colourblind viewer,
    /// and red-against-amber is one of the pairs that goes first. The shape
    /// is the part that survives: claude.ai is a filled disc, Claude Code is
    /// a ring with the middle punched out.
    ///
    /// Asserted in pixels rather than trusted to the drawing code, because a
    /// ring whose hole closed up would still be a different image from the
    /// disc and would still pass every test above it — while looking, at
    /// menu-bar size, exactly like the disc.
    func testClaudeCodeMarkerIsHollowAndClaudeAIMarkerIsFilled() throws {
        let manager = retain(StatusBarUIManager())
        defer { manager.cleanup() }

        let disc = try marker(
            of: render(attention: .claudeAI, manager: manager)
        )
        let ring = try marker(
            of: render(attention: .claudeCode, manager: manager)
        )

        XCTAssertGreaterThan(
            disc.centreAlpha,
            0.9,
            "the claude.ai marker is a filled disc; an empty middle would "
                + "make it the same shape as the Claude Code ring\n"
                + disc.map
        )
        // Compared against the disc's own centre, not a constant: a fixed
        // threshold measures the rasterizer's antialiasing bleed at
        // whatever scale the host happens to draw at (a hollow ~2-device-
        // pixel hole reads a real alpha at 1x, near-zero at 2x), not the
        // product claim. The claim is that these two marks differ in the
        // middle — comparing both markers from the same render pass, at
        // the same host scale, states exactly that at any scale.
        XCTAssertLessThan(
            ring.centreAlpha,
            disc.centreAlpha - 0.5,
            "the Claude Code marker read as a filled blob, not a ring — "
                + "the one encoding that survives both menu-bar size and "
                + "colourblindness\n"
                + ring.map
        )
        // Relative rather than absolute: on a 1x/headless raster the stroke
        // itself only reaches partial alpha (a 1.0pt stroke landing on a
        // single device pixel), so what distinguishes a real ring from a
        // filled blob isn't "the stroke is near-opaque" but "the stroke is
        // substantially more opaque than the ring's own punched-out
        // centre" — a filled shape collapses that gap toward zero at any
        // scale.
        XCTAssertGreaterThan(
            ring.strokeAlpha - ring.centreAlpha,
            0.4,
            "the ring's stroke is not meaningfully more opaque than its "
                + "own hollow centre\n"
                + ring.map
        )

        // Shape is the encoding that survives colourblindness, but the two
        // colours still have to be two colours: if the ring came back red
        // the marker would have lost half its redundancy silently. Green is
        // what separates systemOrange from systemRed. Compared as intrinsic
        // (alpha-normalized) colour rather than the raw composited channel,
        // since a partially-transparent amber stroke composites toward
        // whatever's underneath and dilutes the raw green reading.
        let ringIntrinsicGreen = ring.strokeAlpha > 0
            ? ring.strokeGreen / ring.strokeAlpha : 0
        let discIntrinsicGreen = disc.centreAlpha > 0
            ? disc.centreGreen / disc.centreAlpha : 0
        XCTAssertGreaterThan(
            ringIntrinsicGreen - discIntrinsicGreen,
            0.25,
            "the ring was not drawn in amber (intrinsic green "
                + "\(ringIntrinsicGreen)) against the disc's red "
                + "(intrinsic green \(discIntrinsicGreen))"
        )
    }

    /// Reads the corner the marker is drawn into, so a failure above can
    /// show what was actually painted instead of only a number.
    private struct Marker {
        let centreAlpha: CGFloat
        let centreGreen: CGFloat
        /// The most opaque pixel on the marker's centre row between 1pt and
        /// 2.5pt out from the middle — where the ring's stroke lives. Taken
        /// as a maximum over several offsets rather than one sample because
        /// a single fixed offset can still straddle a pixel boundary within
        /// the sampling bitmap's own grid; sampling several offsets and
        /// taking the max is cheap insurance against that. This value is
        /// compared against `centreAlpha` (not against an absolute
        /// threshold) because the raster's actual detail is fixed at
        /// `applyAttentionMarker` draw time by the host's current scale —
        /// resampling at a fixed grid here cannot recover detail that was
        /// never drawn, so a relative/normalized comparison is what stays
        /// robust across 1x and 2x hosts.
        let strokeAlpha: CGFloat
        let strokeGreen: CGFloat
        let map: String
    }

    private func marker(
        of render: StatusBarUIManager.ProfileMenuBarRender
    ) throws -> Marker {
        // Rasterize at a fixed 2x scale rather than relying on
        // `tiffRepresentation`, whose backing scale tracks the host's
        // display. This no longer recovers any lost detail — the source
        // image's actual sharpness was fixed by `applyAttentionMarker` at
        // draw time (1x on headless CI, 2x on a Retina dev Mac), and
        // resampling it here can't add detail that was never drawn. It's
        // kept purely for a stable, deterministic sampling grid so pixel
        // offsets below are host-independent; the assertions themselves are
        // now relative/normalized so they hold regardless of the source
        // raster's actual scale.
        let pointSize = render.image.size
        let fixedScale: CGFloat = 2.0
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(pointSize.width * fixedScale),
            pixelsHigh: Int(pointSize.height * fixedScale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        bitmap.size = pointSize
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        render.image.draw(
            in: NSRect(origin: .zero, size: pointSize),
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0
        )
        NSGraphicsContext.restoreGraphicsState()
        let scale = fixedScale

        // The marker occupies a 4pt square whose top-right corner sits 0.5pt
        // in from the image's own top-right, drawn by `applyAttentionMarker`.
        // Bitmap coordinates run from the top-left, so the marker's centre is
        // 2.5pt in from the right edge and 2.5pt down from the top.
        func pixel(rightOffset: CGFloat, topOffset: CGFloat) -> NSColor? {
            let x = Int((render.image.size.width - rightOffset) * scale)
            let y = Int(topOffset * scale)
            guard x >= 0, y >= 0,
                  x < bitmap.pixelsWide, y < bitmap.pixelsHigh else {
                return nil
            }
            return bitmap.colorAt(x: x, y: y)?
                .usingColorSpace(.sRGB)
        }

        func alpha(rightOffset: CGFloat, topOffset: CGFloat) -> CGFloat {
            pixel(rightOffset: rightOffset, topOffset: topOffset)?
                .alphaComponent ?? 0
        }

        var map = ""
        let side = Int((8 * scale).rounded())
        for row in 0..<side {
            for column in stride(from: side - 1, through: 0, by: -1) {
                let value = alpha(
                    rightOffset: (CGFloat(column) + 0.5) / scale,
                    topOffset: (CGFloat(row) + 0.5) / scale
                )
                map += value > 0.75 ? "#" : (value > 0.15 ? "+" : ".")
            }
            map += "\n"
        }

        let strokeOffsets: [CGFloat] = [3.5, 4.0, 4.5, 5.0]
        let strokeOffset = strokeOffsets.max {
            alpha(rightOffset: $0, topOffset: 2.5)
                < alpha(rightOffset: $1, topOffset: 2.5)
        } ?? 4.0
        return Marker(
            centreAlpha: alpha(rightOffset: 2.5, topOffset: 2.5),
            centreGreen: pixel(rightOffset: 2.5, topOffset: 2.5)?
                .greenComponent ?? 0,
            strokeAlpha: alpha(rightOffset: strokeOffset, topOffset: 2.5),
            strokeGreen: pixel(rightOffset: strokeOffset, topOffset: 2.5)?
                .greenComponent ?? 0,
            map: map
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
    /// `isTemplate` back off, is what keeps the dot red — and, for the
    /// hollow ring, keeps the punched-out middle that tells the two
    /// credentials apart when neither colour survives.
    func testMarkedIconIsNeverTemplateRendered() {
        let manager = retain(StatusBarUIManager())
        defer { manager.cleanup() }
        var monochrome = MultiProfileDisplayConfig()
        monochrome.useSystemColor = true
        monochrome.showPaceMarker = false

        for credential: MenuBarAttentionSignal.Credential in [
            .claudeAI, .claudeCode
        ] {
            for isActive in [false, true] {
                let marked = render(
                    attention: credential,
                    isActive: isActive,
                    config: monochrome,
                    manager: manager
                )
                XCTAssertFalse(
                    marked.image.isTemplate,
                    "template rendering would repaint the \(credential) "
                        + "marker in the menu bar's foreground colour, "
                        + "hiding it from exactly the monochrome users who "
                        + "have no other colour to notice"
                )
            }
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

    // MARK: - The marker in the accessibility label and tooltip

    /// The dot is invisible to VoiceOver and to anyone who only hovers the
    /// icon. `updateMultiProfileButtons` is the one path that both marks
    /// the icon and rebuilds the label every render, so it is the one place
    /// this fact must reach both surfaces.
    ///
    /// It has to name the credential here more than anywhere else: the
    /// icon's two shapes are worth nothing to someone reading a tooltip or
    /// listening to VoiceOver, so for them "sign-in needs attention" is the
    /// whole message — and it sends half of them to the wrong Settings
    /// screen.
    func testAttentionLabelNamesWhichCredentialIsBroken() {
        for credential: MenuBarAttentionSignal.Credential in [
            .claudeAI, .claudeCode
        ] {
            let manager = retain(StatusBarUIManager())
            defer { manager.cleanup() }
            let profile = makeProfile(issue: .signInExpired)
            manager.setupMultiProfile(
                profiles: [profile],
                target: manager,
                action: #selector(NSObject.description)
            )

            manager.updateMultiProfileButtons(
                profiles: [profile],
                config: MultiProfileDisplayConfig(),
                attention: [profile.id: credential]
            )

            guard let button = manager.button(for: profile.id) else {
                return XCTFail("expected a status item for the marked profile")
            }
            let expected = StatusBarUIManager.attentionStateText(credential)
            let other = StatusBarUIManager.attentionStateText(
                credential == .claudeAI ? .claudeCode : .claudeAI
            )
            XCTAssertTrue(
                button.accessibilityLabel()?.contains(expected) ?? false,
                "the accessibility label did not name \(credential): "
                    + "\(button.accessibilityLabel() ?? "nil")"
            )
            XCTAssertTrue(
                button.toolTip?.contains(expected) ?? false,
                "the tooltip did not name \(credential): "
                    + "\(button.toolTip ?? "nil")"
            )
            XCTAssertFalse(
                button.toolTip?.contains(other) ?? true,
                "the tooltip blamed the credential that is working: "
                    + "\(button.toolTip ?? "nil")"
            )
        }
    }

    /// The two wordings really are different sentences in every shipped
    /// locale. Two keys that happened to translate to the same string would
    /// leave the tooltip exactly as uninformative as the one key it replaced.
    func testTheTwoAttentionWordingsAreDistinctAndTranslated() {
        let claudeAI = StatusBarUIManager.attentionStateText(.claudeAI)
        let claudeCode = StatusBarUIManager.attentionStateText(.claudeCode)
        XCTAssertNotEqual(claudeAI, claudeCode)
        for text in [claudeAI, claudeCode] {
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(
                text.hasPrefix("menubar.accessibility."),
                "\(text) fell through to its localization key"
            )
        }
    }

    /// The mirror of the test above: a profile with no sign-in problem must
    /// not gain the wording just because the render pass ran again — a
    /// permanent complaint on a working profile is the same crying-wolf
    /// failure the marker itself avoids. Neither credential's wording, since
    /// there are now two ways to get it wrong.
    func testUnmarkedProfileAccessibilityLabelNamesNeitherCredential() {
        let manager = retain(StatusBarUIManager())
        defer { manager.cleanup() }
        let profile = makeProfile(issue: nil)
        manager.setupMultiProfile(
            profiles: [profile],
            target: manager,
            action: #selector(NSObject.description)
        )

        manager.updateMultiProfileButtons(
            profiles: [profile],
            config: MultiProfileDisplayConfig()
        )

        guard let button = manager.button(for: profile.id) else {
            return XCTFail("expected a status item for the profile")
        }
        for credential: MenuBarAttentionSignal.Credential in [
            .claudeAI, .claudeCode
        ] {
            let fragment = StatusBarUIManager.attentionStateText(credential)
            XCTAssertFalse(
                button.accessibilityLabel()?.contains(fragment) ?? true,
                "a working profile was told \(credential) needs attention"
            )
            XCTAssertFalse(button.toolTip?.contains(fragment) ?? true)
        }
    }

    /// `profileAccessibilityLabel` is the one function both call sites share,
    /// so its own contract is worth pinning directly: the attention wording
    /// is appended, not substituted, and comes after the active/inactive
    /// fact rather than replacing it.
    func testProfileAccessibilityLabelHelperAppendsAttentionWording() {
        let plain = StatusBarUIManager.profileAccessibilityLabel(
            "Claude, r3, 2% used",
            isActive: false
        )
        for credential: MenuBarAttentionSignal.Credential in [
            .claudeAI, .claudeCode
        ] {
            let marked = StatusBarUIManager.profileAccessibilityLabel(
                "Claude, r3, 2% used",
                isActive: false,
                attention: credential
            )
            XCTAssertEqual(
                marked,
                plain + ", "
                    + StatusBarUIManager.attentionStateText(credential)
            )
        }
    }

    /// The active-profile underline is drawn onto a taller canvas; the marker
    /// runs after it and must not undo that.
    func testMarkerPreservesTheActiveProfileUnderlineGeometry() {
        let manager = retain(StatusBarUIManager())
        defer { manager.cleanup() }
        let active = render(attention: nil, isActive: true, manager: manager)

        for credential: MenuBarAttentionSignal.Credential in [
            .claudeAI, .claudeCode
        ] {
            let activeMarked = render(
                attention: credential,
                isActive: true,
                manager: manager
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

    // MARK: - The single-profile label and tooltip

    /// These tests exercise `legacyMetricAccessibilityLabel` directly rather
    /// than through `updateAllButtons`, which is not safe to drive from a
    /// unit test for two reasons. It reads `ProfileManager.shared`, the
    /// process-wide singleton holding the tester's real profiles; and the
    /// status items it needs carry the SHIPPING autosave names
    /// (`claude-usage-tracker.session` and friends, not the per-UUID names
    /// the multi-profile tests create), so creating and tearing them down in
    /// a test would discard AppKit's saved menu-bar position for the real
    /// app's own items. The label builder is the whole of what changed, and
    /// the two production call sites pass it straight through.
    private func singleProfileUsage(
        sessionAvailable: Bool = true,
        weekAvailable: Bool = true
    ) -> ClaudeUsage {
        var usage = ClaudeUsage.empty
        usage.sessionPercentage = 42
        usage.sessionPercentageAvailable = sessionAvailable
        usage.sessionResetTime = Date().addingTimeInterval(3_600)
        usage.weeklyPercentage = 13
        usage.weeklyPercentageAvailable = weekAvailable
        return usage
    }

    private func singleProfileAPIUsage() -> APIUsage {
        APIUsage(
            currentSpendCents: 25,
            resetsAt: now.addingTimeInterval(86_400),
            prepaidCreditsCents: 75,
            currency: "USD",
            apiTokenCostCents: nil,
            apiCostByModel: nil,
            costBySource: nil,
            dailyCostCents: nil
        )
    }

    private func singleProfileLabel(
        for metricType: MenuBarMetricType,
        attention: MenuBarAttentionSignal.Credential? = nil,
        usage: ClaudeUsage? = nil
    ) -> String {
        StatusBarUIManager.legacyMetricAccessibilityLabel(
            for: metricType,
            profileName: "Work",
            usage: usage ?? singleProfileUsage(),
            apiUsage: singleProfileAPIUsage(),
            showRemaining: false,
            attention: attention
        )
    }

    /// Single-profile mode puts one status item on screen per enabled
    /// metric — up to three at once. A label that named only the provider
    /// and the profile would be the same sentence three times over, which
    /// identifies none of them and is worse than the silence it replaces.
    func testSingleProfileLabelNamesItsMetricAndItsProfile() {
        let labels = MenuBarMetricType.allCases.map {
            singleProfileLabel(for: $0)
        }
        for (metricType, label) in zip(MenuBarMetricType.allCases, labels) {
            XCTAssertTrue(
                label.contains(
                    StatusBarUIManager.legacyMetricName(for: metricType)
                ),
                "the \(metricType) label did not name its metric: \(label)"
            )
            XCTAssertTrue(
                label.contains("Work"),
                "the \(metricType) label did not name the profile: \(label)"
            )
        }
        XCTAssertEqual(
            Set(labels).count,
            MenuBarMetricType.allCases.count,
            "two menu bar items would announce themselves identically"
        )
    }

    /// The point of the whole change on this surface: the mark's shape says
    /// which credential failed to anyone who can see it, and says nothing at
    /// all to someone hovering for a tooltip or listening to VoiceOver. If
    /// the words do not name which one, for them nothing does — and half of
    /// them go to the wrong Settings screen.
    func testSingleProfileLabelNamesWhichCredentialIsBroken() {
        for credential: MenuBarAttentionSignal.Credential in [
            .claudeAI, .claudeCode
        ] {
            let other: MenuBarAttentionSignal.Credential =
                credential == .claudeAI ? .claudeCode : .claudeAI
            for metricType in MenuBarMetricType.allCases {
                let label = singleProfileLabel(
                    for: metricType,
                    attention: credential
                )
                XCTAssertTrue(
                    label.contains(
                        StatusBarUIManager.attentionStateText(credential)
                    ),
                    "the \(metricType) label did not name \(credential): "
                        + label
                )
                XCTAssertFalse(
                    label.contains(
                        StatusBarUIManager.attentionStateText(other)
                    ),
                    "the \(metricType) label blamed the credential that is "
                        + "working: " + label
                )
            }
        }
    }

    /// The two credentials really do produce two different labels here, not
    /// just two code paths that end up saying the same thing.
    func testTheTwoCredentialsProduceDifferentSingleProfileLabels() {
        for metricType in MenuBarMetricType.allCases {
            XCTAssertNotEqual(
                singleProfileLabel(for: metricType, attention: .claudeAI),
                singleProfileLabel(for: metricType, attention: .claudeCode)
            )
        }
    }

    /// The mirror: a profile with nothing wrong must not gain the wording
    /// just because the render pass ran again. A permanent complaint on a
    /// working profile is the same crying-wolf failure the marker avoids,
    /// and there are now two ways to commit it.
    func testUnmarkedSingleProfileLabelNamesNeitherCredential() {
        for metricType in MenuBarMetricType.allCases {
            let label = singleProfileLabel(for: metricType)
            for credential: MenuBarAttentionSignal.Credential in [
                .claudeAI, .claudeCode
            ] {
                XCTAssertFalse(
                    label.contains(
                        StatusBarUIManager.attentionStateText(credential)
                    ),
                    "a working profile was told \(credential) needs "
                        + "attention: " + label
                )
            }
        }
    }

    /// Every label resolves to real text rather than falling through to a
    /// localization key, which is how a missing translation would reach a
    /// tooltip.
    func testSingleProfileLabelIsTranslatedNotAKey() {
        for metricType in MenuBarMetricType.allCases {
            let label = singleProfileLabel(
                for: metricType,
                attention: .claudeCode
            )
            XCTAssertFalse(label.isEmpty)
            for fragment in ["appearance.metric.", "menubar.accessibility."] {
                XCTAssertFalse(
                    label.contains(fragment),
                    "\(label) fell through to a localization key"
                )
            }
        }
    }

    /// A window nobody read is said in words. The legacy single-profile ICON
    /// still draws `0%` in that case, which is a separate defect in
    /// `MenuBarIconRenderer.getMetricData`; the label is not the place to
    /// repeat it, and doing so would have hidden it.
    func testSingleProfileValueSaysNoReadingRatherThanZeroPercent() {
        let unread = StatusBarUIManager.legacyMetricAccessibilityValue(
            for: .session,
            usage: singleProfileUsage(sessionAvailable: false),
            apiUsage: singleProfileAPIUsage(),
            showRemaining: false
        )
        let measured = StatusBarUIManager.legacyMetricAccessibilityValue(
            for: .session,
            usage: singleProfileUsage(),
            apiUsage: singleProfileAPIUsage(),
            showRemaining: false
        )
        XCTAssertFalse(
            unread.contains("0%"),
            "VoiceOver must not read a fabricated 0% for a window nobody "
                + "measured. Got: " + unread
        )
        XCTAssertTrue(measured.contains("42%"))
        XCTAssertNotEqual(unread, measured)
    }

    /// An unlinked API console is the one unknown the icon also refuses —
    /// it draws "N/A" — so the label says so rather than the 0% that
    /// `getMetricData` substitutes to keep the drawing code total.
    func testSingleProfileCreditsValueSaysNoReadingWithNoAPIUsage() {
        let value = StatusBarUIManager.legacyMetricAccessibilityValue(
            for: .api,
            usage: singleProfileUsage(),
            apiUsage: nil,
            showRemaining: false
        )
        XCTAssertFalse(value.contains("0%"), value)
        XCTAssertFalse(value.isEmpty)
    }

    /// The default-logo item — no usage credentials, or every metric
    /// switched off — is named too, because an unlabelled status item is
    /// announced as nothing at all and this is the item a person meets
    /// before the app has any data.
    ///
    /// It never carries the attention wording, and takes no credential to
    /// carry: that branch returns before the marker is stamped, so a spoken
    /// complaint there would be a claim the icon does not make.
    func testDefaultLogoItemIsNamedAndBlamesNoCredential() {
        let label = StatusBarUIManager.legacyDefaultLogoAccessibilityLabel(
            profileName: "Work"
        )
        XCTAssertTrue(label.contains("Work"), label)
        XCTAssertFalse(label.isEmpty)
        XCTAssertFalse(
            label.contains("menubar.accessibility."),
            "\(label) fell through to a localization key"
        )
        for credential: MenuBarAttentionSignal.Credential in [
            .claudeAI, .claudeCode
        ] {
            XCTAssertFalse(
                label.contains(
                    StatusBarUIManager.attentionStateText(credential)
                ),
                "the unmarked default logo blamed \(credential): " + label
            )
        }
    }

    /// A profile that has not loaded yet degrades to "Claude, …" rather than
    /// announcing an empty clause between two commas.
    func testSingleProfileLabelSurvivesAMissingProfileName() {
        for name in [nil, ""] as [String?] {
            let label = StatusBarUIManager.legacyMetricAccessibilityLabel(
                for: .session,
                profileName: name,
                usage: singleProfileUsage(),
                apiUsage: singleProfileAPIUsage(),
                showRemaining: false,
                attention: nil
            )
            XCTAssertFalse(label.contains(", , "), label)
            XCTAssertTrue(
                label.contains(
                    StatusBarUIManager.legacyMetricName(for: .session)
                ),
                label
            )
        }
    }
}
