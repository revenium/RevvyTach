//
//  BrowserSignInSettingsVisibilityTests.swift
//  Claude UsageTests
//
//  Created by Claude Code on 2026-08-29.
//

import AppKit
import Combine
import UsageCore
import XCTest
@testable import Claude_Usage

/// The menu bar learned to say that a claude.ai session key had stopped
/// working, and Settings kept saying the opposite: a green "Fully set up"
/// banner and a "Working" badge on the very sign-in the icon was marking, on
/// the one page a person opens to repair it.
///
/// The fix is a relay, not a second rule: `MenuBarManager` records the
/// verdict `MenuBarAttentionSignal` produced, and Settings renders that. So
/// these tests assert two things together — that Settings reaches the same
/// conclusion the icon does for every input, and that it stays quiet for the
/// cases the icon stays quiet for. A page that cried wolf about a working
/// account would be the same defect wearing the other shoe.
@MainActor
final class BrowserSignInSettingsVisibilityTests: HostedAppTestCase {
    // MARK: - Settings agrees with the icon

    func testBrowserRowNeedsAttentionExactlyWhenTheIconMarksClaudeAI() {
        // Every input pair the menu bar turns into `.claudeAI`: a rejection
        // streak at the debounce threshold, a longer streak, and a settled
        // unauthenticated verdict carried with no failure projected.
        let marking: [(streak: Int, health: ProviderHealthStatus?)] = [
            (2, nil),
            (5, .healthy),
            (0, .unauthenticated)
        ]

        for input in marking {
            let credential = MenuBarAttentionSignal.attention(
                cliSignInIssue: nil,
                credentialFailureStreak: input.streak,
                healthStatus: input.health,
                setupState: .complete
            )
            XCTAssertEqual(
                credential,
                .claudeAI,
                "streak \(input.streak) with health "
                    + "\(String(describing: input.health)) no longer marks "
                    + "the icon; this test's premise is stale"
            )
            XCTAssertEqual(
                ClaudeAccountView.browserSummaryHealth(
                    attention: credential
                ),
                .needsAttention,
                "Settings still calls the browser sign-in healthy while the "
                    + "icon marks it"
            )
        }
    }

    func testASingleRejectionAccusesNeitherSurface() {
        // One refusal is the blip the icon's threshold absorbs. Settings must
        // absorb it too, or opening the page after a transient failure would
        // accuse a working account.
        let credential = MenuBarAttentionSignal.attention(
            cliSignInIssue: nil,
            credentialFailureStreak: 1,
            healthStatus: .unauthenticated,
            setupState: .complete
        )

        XCTAssertNil(credential)
        XCTAssertEqual(
            ClaudeAccountView.browserSummaryHealth(attention: credential),
            .working
        )
    }

    func testTheOtherCredentialsLeaveTheBrowserRowAlone() {
        // `.claudeCode` is the terminal sign-in, which has its own row and
        // its own health input; `.setupIncomplete` is already carried by the
        // setup-state verdict. Either one marking the browser row would send
        // the reader to the wrong repair.
        for credential: MenuBarAttentionSignal.Credential? in [
            nil, .claudeCode, .setupIncomplete
        ] {
            XCTAssertEqual(
                ClaudeAccountView.browserSummaryHealth(
                    attention: credential
                ),
                .working,
                "\(String(describing: credential)) should not badge the "
                    + "browser sign-in"
            )
        }
    }

    // MARK: - What the summary renders

    func testBrokenBrowserSignInIsBadgedAndExplained() {
        for state: ClaudeSetupState in [.complete, .browserOnly] {
            XCTAssertEqual(
                ClaudeSignInSummaryView.browserStatus(
                    state: state,
                    browserHealth: .needsAttention
                ),
                .needsAttention
            )
            XCTAssertEqual(
                ClaudeSignInSummaryView.verdict(
                    state: state,
                    browserHealth: .needsAttention
                ).localizationKey,
                "claude_account.summary.verdict.browser_needs_attention",
                "the banner still reads as though nothing is wrong"
            )
        }
    }

    func testHealthyBrowserSignInKeepsItsSettledWording() {
        XCTAssertEqual(
            ClaudeSignInSummaryView.browserStatus(
                state: .complete,
                browserHealth: .working
            ),
            .working
        )
        XCTAssertEqual(
            ClaudeSignInSummaryView.verdict(
                state: .complete,
                browserHealth: .working
            ).localizationKey,
            "claude_account.summary.verdict.complete"
        )
        XCTAssertEqual(
            ClaudeSignInSummaryView.verdict(
                state: .browserOnly,
                browserHealth: .working
            ).localizationKey,
            "claude_account.summary.verdict.browser_only"
        )
    }

    func testAnAbsentBrowserSignInIsNeverReportedAsBroken() {
        // There is no browser sign-in to have stopped working, so the health
        // input must not reach either surface.
        for state: ClaudeSetupState in [.terminalOnly, .none] {
            XCTAssertNotEqual(
                ClaudeSignInSummaryView.browserStatus(
                    state: state,
                    browserHealth: .needsAttention
                ),
                .needsAttention
            )
            XCTAssertNotEqual(
                ClaudeSignInSummaryView.verdict(
                    state: state,
                    browserHealth: .needsAttention
                ).localizationKey,
                "claude_account.summary.verdict.browser_needs_attention"
            )
        }

        // The two states say different things about that absence now. A
        // terminal-only profile is complete — its Claude Code sign-in
        // produces every number — so its browser row reads "Optional" and
        // its verdict is the green one. Only a profile with neither sign-in
        // is missing anything.
        XCTAssertEqual(
            ClaudeSignInSummaryView.browserStatus(
                state: .terminalOnly,
                browserHealth: .needsAttention
            ),
            .optional
        )
        XCTAssertEqual(
            ClaudeSignInSummaryView.verdict(
                state: .terminalOnly,
                browserHealth: .working
            ).localizationKey,
            "claude_account.summary.verdict.terminal_only"
        )
        XCTAssertEqual(
            ClaudeSignInSummaryView.browserStatus(
                state: ClaudeSetupState.none,
                browserHealth: .needsAttention
            ),
            .missing
        )
    }

    /// The Claude Code row's own two states, which moved with the same
    /// change: it is what produces every number now, so a browser-only
    /// profile is nudged to add it rather than told nothing.
    func testTheTerminalRowIsRecommendedOnABrowserOnlyProfile() {
        XCTAssertEqual(
            ClaudeSignInSummaryView.verdict(
                state: .browserOnly,
                browserHealth: .working
            ).localizationKey,
            "claude_account.summary.verdict.browser_only"
        )
        XCTAssertEqual(
            ClaudeSignInSummaryView.Status.recommended.localizationKey,
            "claude_account.summary.status.recommended"
        )
        XCTAssertEqual(
            ClaudeSignInSummaryView.Status.optional.localizationKey,
            "claude_account.summary.status.optional"
        )
    }

    func testTheBrokenBrowserVerdictNamesTheRepairInEveryLocale() throws {
        // The banner wraps, so its width is not the risk; being absent or
        // untranslated is. Each locale must have its own wording, and it must
        // not run taller than the longest banner already shipping in that
        // locale's own layout.
        let bannerWidth: CGFloat = 516 - 2 * 16 - 15 - 12
        for locale in [
            "de", "en", "es", "fr", "it", "ja", "ko", "pt", "zh-Hans"
        ] {
            let bundle = try XCTUnwrap(
                Bundle(for: MenuBarManager.self)
                    .path(forResource: locale, ofType: "lproj")
                    .flatMap(Bundle.init(path:))
            )
            let key = "claude_account.summary.verdict.browser_needs_attention"
            let text = bundle.localizedString(
                forKey: key,
                value: nil,
                table: nil
            )
            XCTAssertNotEqual(
                text,
                key,
                "\(locale) has no translation for \(key)"
            )

            let shipped = bundle.localizedString(
                forKey: "claude_account.summary.verdict.terminal_only",
                value: nil,
                table: nil
            )
            XCTAssertLessThanOrEqual(
                height(text, width: bannerWidth),
                height(shipped, width: bannerWidth),
                "\(locale)'s broken-browser banner is taller than the "
                    + "longest banner already shipping"
            )
        }
    }

    private func height(_ text: String, width: CGFloat) -> CGFloat {
        (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 13)]
        ).height
    }

    // MARK: - The sidebar badge

    func testSidebarBadgeNamesABrokenBrowserSignIn() {
        let profile = Profile(
            name: "Complete",
            claudeSessionKey: "session-key",
            organizationId: "org",
            cliCredentialsJSON: #"{"claudeAiOauth":{"accessToken":"ok"}}"#,
            hasCliAccount: true
        )

        XCTAssertEqual(
            ClaudeAccountAttention.badge(
                profile,
                browserSignInNeedsAttention: true
            ),
            .browserSignInBroken
        )
        XCTAssertEqual(
            ClaudeAccountAttention.badge(
                profile,
                browserSignInNeedsAttention: true
            )?.localizationKey,
            "claude_account.summary.status.needs_attention"
        )
        XCTAssertNil(
            ClaudeAccountAttention.badge(
                profile,
                browserSignInNeedsAttention: false
            )
        )
    }

    func testMissingOutranksBrokenInTheSidebarBadge() {
        // "Incomplete" now means neither sign-in, and it still outranks
        // broken: a profile with nothing linked has no browser sign-in to be
        // broken, and its badge names the step that repairs it.
        let neither = Profile(name: "Neither")

        XCTAssertEqual(
            ClaudeAccountAttention.badge(
                neither,
                browserSignInNeedsAttention: true
            ),
            .setupIncomplete
        )
        XCTAssertEqual(
            ClaudeAccountAttention.Badge.setupIncomplete.localizationKey,
            "claude_account.incomplete_badge"
        )

        // A terminal-only profile is no longer badged at all. It is
        // complete, and it holds no browser sign-in that could be the thing
        // the relay is complaining about — so neither badge applies.
        let terminalOnly = Profile(name: "Terminal only", hasCliAccount: true)
        XCTAssertNil(
            ClaudeAccountAttention.badge(
                terminalOnly,
                browserSignInNeedsAttention: true
            )
        )
    }

    // MARK: - The relay itself

    func testTheStoreCarriesTheVerdictAndClearsItOnRepair() {
        let store = ClaudeSignInAttentionStore()
        let profileID = UUID()

        XCTAssertNil(store.credential(for: profileID))

        store.record(.claudeAI, for: profileID)
        XCTAssertEqual(store.credential(for: profileID), .claudeAI)
        XCTAssertEqual(
            ClaudeAccountView.browserSummaryHealth(
                attention: store.credential(for: profileID)
            ),
            .needsAttention
        )

        // A repaired sign-in must stop being reported the moment the icon
        // stops marking it; a stale accusation is the same lie inverted.
        store.record(nil, for: profileID)
        XCTAssertNil(store.credential(for: profileID))
        XCTAssertEqual(
            ClaudeAccountView.browserSummaryHealth(
                attention: store.credential(for: profileID)
            ),
            .working
        )
    }

    /// The defect this PR was reopened for: with the app running and the
    /// Claude Account page already on screen, the icon marked jc@ and the
    /// page still said "Working". A stored value that never announces itself
    /// leaves an open page frozen on the answer it read when it appeared.
    func testARecordedVerdictAnnouncesItselfToAnAlreadyOpenPage() {
        let store = ClaudeSignInAttentionStore()
        let profileID = UUID()
        let announced = expectation(
            description: "the store tells its readers to re-render"
        )
        var cancellables: Set<AnyCancellable> = []
        store.objectWillChange
            .sink { _ in announced.fulfill() }
            .store(in: &cancellables)

        store.record(.claudeAI, for: profileID)

        wait(for: [announced], timeout: 1)
        XCTAssertEqual(
            ClaudeAccountView.browserSummaryHealth(
                attention: store.credential(for: profileID)
            ),
            .needsAttention
        )
    }

    /// A profile that is not selected for the menu bar is still listed in
    /// Settings, so it still needs a verdict. Publishing the whole map is
    /// what covers it; publishing only what the icon drew is what left it
    /// badged "Working" while its session key was being rejected.
    func testAHiddenProfileGetsAVerdictAndADeletedOneLosesIts() {
        let store = ClaudeSignInAttentionStore()
        let displayed = UUID()
        let hidden = UUID()

        store.replace(with: [displayed: .claudeCode, hidden: .claudeAI])
        XCTAssertEqual(store.credential(for: hidden), .claudeAI)
        XCTAssertEqual(
            ClaudeAccountView.browserSummaryHealth(
                attention: store.credential(for: hidden)
            ),
            .needsAttention
        )

        // The hidden profile is removed; its accusation must go with it.
        store.replace(with: [displayed: .claudeCode])
        XCTAssertNil(store.credential(for: hidden))
        XCTAssertEqual(
            ClaudeAccountView.browserSummaryHealth(
                attention: store.credential(for: hidden)
            ),
            .working
        )
    }

    // MARK: - Terminal-first redesign

    /// An absent browser sign-in must never draw the red "Missing"/"Needs
    /// attention" treatment — only `.optional` (terminal-only, complete
    /// picture) or `.missing` paired with the neutral `.none` verdict, which
    /// itself points at the terminal sign-in, not the browser one. Swept
    /// across every setup state so a future state added to the enum cannot
    /// silently regress this.
    func testAbsentBrowserSignInIsNeverTheRedBadgeOnAnySetupState() {
        for state: ClaudeSetupState in [
            .complete, .browserOnly, .terminalOnly, .none
        ] {
            // "Absent" means the health input itself reports nothing is
            // broken — there is either a working key, or none to break.
            let status = ClaudeSignInSummaryView.browserStatus(
                state: state,
                browserHealth: .working
            )
            XCTAssertNotEqual(
                status,
                .needsAttention,
                "\(state) must not badge an absent browser sign-in as broken"
            )
        }
    }

    /// The terminal (Claude Code) sign-in's own button is the page's primary
    /// call to action while it is unlinked; the browser button never is.
    func testTerminalLinkActionIsPrimaryStyleAndBrowserIsNot() {
        let primaryAction = ClaudeSignInSummaryAction(
            "claude_account.terminal.link".localized,
            style: .primary
        ) {}
        let standardAction = ClaudeSignInSummaryAction(
            "claude_account.browser.sign_in".localized,
            style: .standard
        ) {}

        XCTAssertEqual(primaryAction.style, .primary)
        XCTAssertEqual(standardAction.style, .standard)
        XCTAssertNotEqual(primaryAction.style, standardAction.style)
    }

    func testAnUnrenderedProfileIsNotAccused() {
        // Absent means "the menu bar has not decided yet", never "broken".
        let store = ClaudeSignInAttentionStore()

        XCTAssertEqual(
            ClaudeAccountView.browserSummaryHealth(
                attention: store.credential(for: UUID())
            ),
            .working
        )
    }
}
