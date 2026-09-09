//
//  HealthStripAccountRowTests.swift
//  Claude UsageTests
//
//  Created by Claude Code on 2026-09-08.
//

import AppKit
import UsageCore
import XCTest
@testable import Claude_Usage

/// The rows behind a left click on the health strip: which accounts are
/// listed, in what order, and what each row says about one of them.
@MainActor
final class HealthStripAccountRowTests: XCTestCase {

    private func usage(
        session: Double?,
        week: Double? = 20
    ) -> ClaudeUsage {
        var reading = ClaudeUsage.empty
        reading.sessionResetTime = Date().addingTimeInterval(3_600)
        if let session {
            reading.sessionPercentage = session
            reading.sessionPercentageAvailable = true
        }
        if let week {
            reading.weeklyPercentage = week
            reading.weeklyPercentageAvailable = true
        }
        return reading
    }

    private func claude(
        _ name: String,
        session: Double? = 40,
        selected: Bool = true,
        deleting: Bool = false
    ) -> Profile {
        var profile = Profile(name: name, isSelectedForDisplay: selected)
        profile.claudeUsage = usage(session: session)
        profile.deletionInProgress = deleting
        return profile
    }

    private func codex(_ name: String) -> Profile {
        Profile(
            name: name,
            providerConfiguration: .codex(CodexProfileConfiguration())
        )
    }

    private func rows(
        _ profiles: [Profile],
        activeClaudeProfileID: UUID? = nil,
        attention: [UUID: MenuBarAttentionSignal.Credential] = [:],
        showRemaining: Bool = false,
        showPaceMarker: Bool = false
    ) -> [HealthStripAccountRow] {
        HealthStripAccountRow.rows(
            profiles: profiles,
            snapshots: [:],
            activeClaudeProfileID: activeClaudeProfileID,
            attention: attention,
            showRemaining: showRemaining,
            showPaceMarker: showPaceMarker,
            isActive: { $0.id == activeClaudeProfileID }
        )
    }

    // MARK: - Row set

    func testOnlyClaudeAccountsSelectedAndNotBeingDeletedAreListed() {
        let shown = claude("Work")
        let deselected = claude("Hidden", selected: false)
        let deleting = claude("Going", deleting: true)
        let codexAccount = codex("Codex")

        let listed = rows([shown, deselected, deleting, codexAccount])

        XCTAssertEqual(
            listed.map(\.name),
            ["Work"],
            "The list must match what the strip draws, not the looser "
                + "'selected for display' alone"
        )
    }

    func testRowsKeepTheProfileListsOwnOrder() {
        let profiles = ["A", "B", "C", "D"].map { claude($0) }

        XCTAssertEqual(
            rows(profiles).map(\.name),
            ["A", "B", "C", "D"],
            "Rows and bars must read left to right the same way"
        )
    }

    func testAnEmptySelectionProducesNoRows() {
        XCTAssertTrue(rows([claude("Hidden", selected: false)]).isEmpty)
    }

    // MARK: - What a row says

    func testARowNamesBothWindowsAndTheirFigures() throws {
        let profile = claude("Work", session: 83)
        let row = try XCTUnwrap(rows([profile]).first)

        XCTAssertEqual(row.name, "Work")
        XCTAssertFalse(row.windows.isEmpty)
        XCTAssertTrue(row.valueText.contains("83"))
        XCTAssertNotEqual(row.valueText, OverflowProfileRow.noReadingText)
    }

    func testAnAccountWithNoReadingCollapsesToASingleDash() throws {
        var profile = claude("Work")
        profile.claudeUsage = nil
        let row = try XCTUnwrap(rows([profile]).first)

        XCTAssertEqual(
            row.valueText,
            OverflowProfileRow.noReadingText,
            "Nothing read is one dash, never a reassuring zero"
        )
        XCTAssertTrue(
            row.accessibilityValueText.contains(
                ProviderUILocalization.text(
                    "menubar.accessibility.state.no_data",
                    fallback: "no usage data"
                )
            )
        )
    }

    func testOneMissingWindowStillNamesBoth() throws {
        var profile = claude("Work")
        profile.claudeUsage = usage(session: nil, week: 55)
        let row = try XCTUnwrap(rows([profile]).first)

        XCTAssertNotEqual(row.valueText, OverflowProfileRow.noReadingText)
        XCTAssertTrue(
            row.valueText.contains(OverflowProfileRow.noReadingText),
            "The dash says which window is missing"
        )
    }

    // MARK: - Flags

    func testOnlyTheActiveAccountIsFlaggedActive() {
        let first = claude("One")
        let second = claude("Two")
        let listed = rows([first, second], activeClaudeProfileID: second.id)

        XCTAssertEqual(listed.map(\.isActive), [false, true])
    }

    func testTheAttentionFlagFollowsTheAccountItBelongsTo() {
        let first = claude("One")
        let second = claude("Two")
        let listed = rows(
            [first, second],
            attention: [second.id: .claudeAI]
        )

        XCTAssertNil(listed[0].attention)
        XCTAssertEqual(listed[1].attention, .claudeAI)
    }

    func testThePaceDotAppearsOnlyWhenThePaceMarkerIsOn() throws {
        let profile = claude("Work", session: 60)

        let without = try XCTUnwrap(
            rows([profile], showPaceMarker: false).first
        )
        XCTAssertNil(without.paceStatus)

        let with = try XCTUnwrap(
            rows([profile], showPaceMarker: true).first
        )
        XCTAssertNotNil(
            with.paceStatus,
            "An account with a reading and an elapsed window has a pace"
        )
    }

    // MARK: - canActivate

    func testCanActivateFollowsThePresentationsOwnActions() throws {
        let profile = claude("Work")

        for isActive in [false, true] {
            let listed = HealthStripAccountRow.rows(
                profiles: [profile],
                snapshots: [:],
                activeClaudeProfileID: isActive ? profile.id : nil,
                attention: [:],
                showRemaining: false,
                showPaceMarker: false,
                isActive: { _ in isActive }
            )
            let row = try XCTUnwrap(listed.first)
            let presentation = ProviderMenuPresentationBuilder.presentation(
                profile: profile,
                snapshot: nil,
                now: Date(),
                isActive: isActive
            )
            XCTAssertEqual(
                row.canActivate,
                presentation.actions.contains { $0.kind == .activate },
                "Make Active must be offered on exactly the same terms the "
                    + "context menu offers it, with isActive \(isActive)"
            )
        }
    }

    // MARK: - Row action labels

    func testEveryRowActionHasALocalizedLabel() {
        let openLabel = String(
            format: ProviderUILocalization.text(
                "menu.provider.open_profile",
                fallback: "Open %@"
            ),
            "Work"
        )
        let labels = [
            openLabel,
            ProviderUILocalization.text(
                "menu.provider.make_active",
                fallback: "Make Active"
            ),
            ProviderUILocalization.text(
                "common.refresh",
                fallback: "Refresh"
            ),
            ProviderUILocalization.text(
                "menubar.healthstrip.footer.refresh_all",
                fallback: "Refresh All"
            ),
            ProviderUILocalization.text(
                "menu.provider.manage_profiles",
                fallback: "Manage Profiles…"
            ),
            ProviderUILocalization.text("common.quit", fallback: "Quit"),
            ProviderUILocalization.text(
                "menubar.healthstrip.header",
                fallback: "Claude Accounts"
            ),
            ProviderUILocalization.text(
                "menubar.healthstrip.row.active_badge",
                fallback: "Active"
            )
        ]
        for label in labels {
            XCTAssertFalse(label.isEmpty)
            XCTAssertFalse(
                label.contains("menubar.") || label.contains("menu.provider"),
                "A raw key reached the UI: \(label)"
            )
        }
        XCTAssertTrue(openLabel.contains("Work"))
    }

    // MARK: - Popover sizing

    /// Every account gets a row however many there are; nothing is dropped
    /// from the list to make it fit. The popover's own height is measured in
    /// `HealthStripAccountsViewLayoutTests`.
    func testEveryAccountGetsARowHoweverManyThereAre() {
        let many = (0..<20).map { claude("Account \($0)") }

        XCTAssertEqual(rows(many).count, 20)
    }

    /// The bounce guard that makes a second click on a status item close the
    /// popover must not eat a press inside one. Opening the strip's list and
    /// then pressing a row's Open is the same button within 250 ms.
    func testTheBounceGuardIsSkippedForAPressInsideThePopover() {
        let button = NSStatusBarButton()

        XCTAssertTrue(
            MenuBarManager.shouldSuppressPopoverOpen(
                button: button,
                lastButton: button,
                lastCloseDate: Date()
            ),
            "A second click on the status item still closes the popover"
        )
        XCTAssertFalse(
            MenuBarManager.shouldSuppressPopoverOpen(
                button: button,
                lastButton: button,
                lastCloseDate: Date(),
                checksBounce: false
            ),
            "but Open from inside the list must always show the account"
        )
    }

    // MARK: - Captured identity

    /// A row carries the account exactly as it stood when the list was
    /// built, so an action pressed after a credential rotation
    /// re-provisioned that account is refused instead of landing on the
    /// replacement. Deriving the identity from the live profile at press
    /// time made the router's revision check compare a value with itself,
    /// which can never fail.
    func testARowsCapturedRevisionRejectsAnActionAfterReprovisioning()
        throws
    {
        let profile = claude("Work")
        let row = try XCTUnwrap(rows([profile]).first)
        var live = [profile]
        var refreshed: [UUID] = []
        let router = ProviderCapturedTargetActionRouter(
            profiles: { live },
            sinks: .init(
                openPopover: { _, _ in },
                detachPopover: { _, _ in },
                refresh: { target, _ in
                    refreshed.append(target.profileID)
                },
                activate: { _, _ in },
                settings: { _, _, _ in },
                quit: { _, _ in }
            )
        )

        XCTAssertTrue(
            router.route(.refresh, target: row.identity),
            "The unchanged account still takes the row's action"
        )
        XCTAssertEqual(refreshed, [profile.id])

        var reprovisioned = profile
        reprovisioned.providerRevision += 1
        live = [reprovisioned]

        XCTAssertFalse(
            router.route(.refresh, target: row.identity),
            "A row built before the rotation must not act on the account "
                + "that replaced it"
        )
        XCTAssertEqual(
            refreshed,
            [profile.id],
            "The stale action fired nothing"
        )
    }
}
