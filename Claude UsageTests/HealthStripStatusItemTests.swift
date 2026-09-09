//
//  HealthStripStatusItemTests.swift
//  Claude UsageTests
//
//  Created by Claude Code on 2026-09-08.
//

import AppKit
import UsageCore
import XCTest
@testable import Claude_Usage

/// Status item lifecycle for the health strip. Every manager here is
/// process-retained and torn down with `defer { manager.cleanup() }`, the
/// convention `StatusBarOverflowTests` established: letting a manager that
/// owns real `NSStatusItem`s deallocate mid-test aborts the test process.
@MainActor
final class HealthStripStatusItemTests: HostedAppTestCase {
    private final class MenuTarget: NSObject {
        @objc func toggle() {}
    }

    /// Counts whether the Accessibility-backed space probe was consulted at
    /// all. Strip layout must never reach it: the strip cannot overflow, so
    /// measuring the menu bar is work whose answer is thrown away, and those
    /// reads contend with a running menu bar manager.
    private final class FakeSpaceProbe: MenuBarSpaceProbing {
        private(set) var makeLayoutInputCallCount = 0

        func makeLayoutInput(
            ourItemWidths: [CGFloat],
            overflowItemWidth: CGFloat,
            currentlyOnScreenWidth: CGFloat
        ) -> MenuBarLayoutInput? {
            makeLayoutInputCallCount += 1
            return nil
        }
    }

    private func claudeProfiles(_ count: Int) -> [Profile] {
        (0..<count).map { Profile(name: "Claude \($0)") }
    }

    private func codexProfile(name: String = "Codex") -> Profile {
        Profile(
            name: name,
            providerConfiguration: .codex(CodexProfileConfiguration())
        )
    }

    private func makeStripManager(
        profiles: [Profile],
        target: MenuTarget
    ) -> StatusBarUIManager {
        let manager = retain(StatusBarUIManager())
        manager.multiLayout = .healthStrip
        manager.setupMultiProfile(
            profiles: profiles,
            target: target,
            action: #selector(MenuTarget.toggle)
        )
        return manager
    }

    // MARK: - hasValidStatusBar

    func testTheStripAloneCountsAsAValidStatusBar() {
        XCTAssertTrue(
            StatusBarUIManager.hasValidStatusBar(
                hasSingleProfileItem: false,
                hasMultiProfileItem: false,
                hasOverflowItem: false,
                hasHealthStripItem: true
            ),
            "Reading false here reruns setup(), which reaches cleanup() and "
                + "discards every saved menu bar position"
        )
        XCTAssertFalse(
            StatusBarUIManager.hasValidStatusBar(
                hasSingleProfileItem: false,
                hasMultiProfileItem: false,
                hasOverflowItem: false,
                hasHealthStripItem: false
            )
        )
    }

    func testALiveStripLayoutReportsAValidStatusBar() {
        let target = MenuTarget()
        let manager = makeStripManager(
            profiles: claudeProfiles(3),
            target: target
        )
        defer { manager.cleanup() }

        XCTAssertTrue(manager.hasValidStatusBar)
    }

    // MARK: - Cold launch

    func testColdLaunchInStripLayoutCreatesHiddenClaudeItems() {
        let target = MenuTarget()
        let profiles = claudeProfiles(3)
        let manager = makeStripManager(profiles: profiles, target: target)
        defer { manager.cleanup() }

        for profile in profiles {
            XCTAssertNotNil(
                manager.multiProfileItemIdentityForTesting(profile.id),
                "The item must exist so switching layouts back restores its "
                    + "saved position instead of minting a fresh item"
            )
            XCTAssertNil(
                manager.button(for: profile.id),
                "but it must not be on screen while the strip is drawing it"
            )
        }
        XCTAssertNotNil(manager.healthStripButton)
    }

    func testCodexAccountsKeepTheirOwnVisibleItems() {
        let target = MenuTarget()
        let codex = codexProfile()
        let claude = claudeProfiles(2)
        let manager = makeStripManager(
            profiles: claude + [codex],
            target: target
        )
        defer { manager.cleanup() }

        XCTAssertNotNil(
            manager.button(for: codex.id),
            "The strip draws Claude accounts only; Codex keeps its own item"
        )
        for profile in claude {
            XCTAssertNil(manager.button(for: profile.id))
        }
    }

    func testAStripIsNotCreatedWhenNoClaudeAccountIsSelected() {
        let target = MenuTarget()
        let manager = makeStripManager(
            profiles: [codexProfile()],
            target: target
        )
        defer { manager.cleanup() }

        XCTAssertNil(manager.healthStripButton)
    }

    // MARK: - The strip item itself

    func testTheStripItemIsCreatedOnceWithTheExactAutosaveName() throws {
        let target = MenuTarget()
        let profiles = claudeProfiles(3)
        let manager = makeStripManager(profiles: profiles, target: target)
        defer { manager.cleanup() }

        let identity = manager.healthStripItemIdentityForTesting
        XCTAssertNotNil(identity)
        let button = try XCTUnwrap(manager.healthStripButton)
        XCTAssertEqual(
            manager.autosaveName(for: button),
            "claude-usage-tracker.healthstrip",
            "A changed autosaveName is a brand new item to every menu bar "
                + "manager, so this string is frozen"
        )
        XCTAssertEqual(
            StatusBarUIManager.healthStripAutosaveName,
            "claude-usage-tracker.healthstrip"
        )

        manager.updateMultiProfileConfiguration(
            profiles: profiles,
            target: target,
            action: #selector(MenuTarget.toggle)
        )
        XCTAssertEqual(
            manager.healthStripItemIdentityForTesting,
            identity,
            "A second layout pass must reuse the same item"
        )
    }

    func testTheStripButtonIsRecognisedByEveryButtonLookup() throws {
        let target = MenuTarget()
        let profiles = claudeProfiles(3)
        let manager = makeStripManager(profiles: profiles, target: target)
        defer { manager.cleanup() }

        let button = try XCTUnwrap(manager.healthStripButton)
        XCTAssertTrue(manager.isHealthStripButton(button))
        XCTAssertFalse(manager.isOverflowButton(button))
        XCTAssertNotNil(manager.autosaveName(for: button))

        manager.updateHealthStrip(
            profiles: profiles,
            config: MultiProfileDisplayConfig(),
            threshold: .percent(90),
            activeClaudeProfileID: profiles[1].id
        )
        XCTAssertEqual(
            manager.profileId(for: button),
            profiles[1].id,
            "With no click coordinate, the strip resolves to the active "
                + "account"
        )
        XCTAssertEqual(
            manager.healthStripProfileID(at: HealthStripLayout.edgePadding),
            profiles[0].id
        )
        XCTAssertNil(
            manager.healthStripProfileID(at: 0),
            "A click in the leading padding belongs to no account"
        )
    }

    // MARK: - Entering and leaving the layout

    func testEnteringAndLeavingStripLayoutPreservesEveryItemIdentity() {
        let target = MenuTarget()
        let profiles = claudeProfiles(3) + [codexProfile()]
        let manager = retain(StatusBarUIManager())
        defer { manager.cleanup() }
        manager.overflowMode = .never
        manager.setupMultiProfile(
            profiles: profiles,
            target: target,
            action: #selector(MenuTarget.toggle)
        )

        let before = profiles.map {
            manager.multiProfileItemIdentityForTesting($0.id)
        }
        for profile in profiles {
            XCTAssertNotNil(manager.button(for: profile.id))
        }

        manager.multiLayout = .healthStrip
        manager.updateMultiProfileConfiguration(
            profiles: profiles,
            target: target,
            action: #selector(MenuTarget.toggle)
        )
        XCTAssertEqual(
            profiles.map { manager.multiProfileItemIdentityForTesting($0.id) },
            before,
            "Entering strip layout hides items, it never removes them"
        )
        let stripIdentity = manager.healthStripItemIdentityForTesting
        XCTAssertNotNil(stripIdentity)

        manager.multiLayout = .perProfileItems
        manager.updateMultiProfileConfiguration(
            profiles: profiles,
            target: target,
            action: #selector(MenuTarget.toggle)
        )
        XCTAssertEqual(
            profiles.map { manager.multiProfileItemIdentityForTesting($0.id) },
            before,
            "and leaving it shows the same items again"
        )
        for profile in profiles {
            XCTAssertNotNil(manager.button(for: profile.id))
        }
        XCTAssertNil(
            manager.healthStripButton,
            "The strip is hidden on the way out"
        )
        XCTAssertEqual(
            manager.healthStripItemIdentityForTesting,
            stripIdentity,
            "but the item itself is kept, so its saved position survives"
        )
    }

    // MARK: - Overflow is bypassed

    func testStripLayoutHidesTheOverflowItemAndNeverConsultsTheSpaceProbe() {
        let target = MenuTarget()
        let manager = retain(StatusBarUIManager())
        defer { manager.cleanup() }
        let probe = FakeSpaceProbe()
        manager.spaceProbe = probe
        manager.overflowMode = .automatic
        manager.multiLayout = .healthStrip
        manager.setupMultiProfile(
            profiles: claudeProfiles(8),
            target: target,
            action: #selector(MenuTarget.toggle)
        )

        XCTAssertNil(
            manager.overflowButton,
            "Eight accounts on the strip are one item, so nothing overflows"
        )
        XCTAssertTrue(manager.overflowProfileIDs.isEmpty)
        XCTAssertEqual(
            probe.makeLayoutInputCallCount,
            0,
            "Strip layout must skip the Accessibility reads entirely, not "
                + "make them and discard the answer"
        )
    }

    func testAnExistingOverflowItemIsHiddenWhenTheStripTakesOver() {
        let target = MenuTarget()
        let profiles = claudeProfiles(8)
        let manager = retain(StatusBarUIManager())
        defer { manager.cleanup() }
        manager.overflowMode = .afterCount(4)
        manager.setupMultiProfile(
            profiles: profiles,
            target: target,
            action: #selector(MenuTarget.toggle)
        )
        XCTAssertNotNil(manager.overflowButton)

        manager.multiLayout = .healthStrip
        manager.updateMultiProfileConfiguration(
            profiles: profiles,
            target: target,
            action: #selector(MenuTarget.toggle)
        )

        XCTAssertNil(manager.overflowButton)
        XCTAssertTrue(manager.overflowProfileIDs.isEmpty)
    }

    // MARK: - Visibility rule

    func testTheVisibilityRuleKeepsClaudeHiddenAndCodexVisible() {
        XCTAssertFalse(
            StatusBarUIManager.multiProfileItemIsVisible(
                providerID: .claude,
                isIndividual: true,
                layout: .healthStrip
            )
        )
        XCTAssertTrue(
            StatusBarUIManager.multiProfileItemIsVisible(
                providerID: .codex,
                isIndividual: true,
                layout: .healthStrip
            )
        )
        XCTAssertTrue(
            StatusBarUIManager.multiProfileItemIsVisible(
                providerID: .claude,
                isIndividual: true,
                layout: .perProfileItems
            )
        )
        XCTAssertFalse(
            StatusBarUIManager.multiProfileItemIsVisible(
                providerID: .claude,
                isIndividual: false,
                layout: .perProfileItems
            ),
            "Outside strip layout the overflow split still decides"
        )
    }

    // MARK: - Hysteresis state

    func testDeselectingAnAccountPrunesItsNumbersState() {
        let target = MenuTarget()
        let profiles = claudeProfiles(2).map { profile -> Profile in
            var hot = profile
            hot.claudeUsage = usage(sessionPercentage: 97)
            return hot
        }
        let manager = makeStripManager(profiles: profiles, target: target)
        defer { manager.cleanup() }

        manager.updateHealthStrip(
            profiles: profiles,
            config: MultiProfileDisplayConfig(),
            threshold: .percent(90),
            activeClaudeProfileID: profiles[0].id
        )
        XCTAssertEqual(
            manager.healthStripNumbersShownForTesting[profiles[0].id],
            true,
            "97% used is over a 90 threshold, so this account shows numbers"
        )

        var deselected = profiles[0]
        deselected.isSelectedForDisplay = false
        manager.updateMultiProfileConfiguration(
            profiles: [deselected, profiles[1]],
            target: target,
            action: #selector(MenuTarget.toggle)
        )

        XCTAssertNil(
            manager.healthStripNumbersShownForTesting[profiles[0].id],
            "An account that lost its item must not leave hysteresis behind"
        )
    }

    func testChangingTheThresholdClearsTheNumbersStateWholesale() {
        let target = MenuTarget()
        let profiles = claudeProfiles(1).map { profile -> Profile in
            var hot = profile
            hot.claudeUsage = usage(sessionPercentage: 91)
            return hot
        }
        let manager = makeStripManager(profiles: profiles, target: target)
        defer { manager.cleanup() }

        manager.updateHealthStrip(
            profiles: profiles,
            config: MultiProfileDisplayConfig(),
            threshold: .percent(90),
            activeClaudeProfileID: nil
        )
        XCTAssertEqual(
            manager.healthStripNumbersShownForTesting[profiles[0].id],
            true
        )

        manager.updateHealthStrip(
            profiles: profiles,
            config: MultiProfileDisplayConfig(),
            threshold: .percent(95),
            activeClaudeProfileID: nil
        )
        XCTAssertEqual(
            manager.healthStripNumbersShownForTesting[profiles[0].id],
            false,
            "91% is under the new 95 threshold, and the old level's "
                + "hysteresis band must not carry it over"
        )
    }

    // MARK: - One reading for the bar and the numbers

    func testTheSnapshotWinsOverTheProfileRecordForBothBarAndNumbers() throws {
        let target = MenuTarget()
        var profile = Profile(name: "Work")
        profile.claudeUsage = usage(sessionPercentage: 10)
        let manager = makeStripManager(profiles: [profile], target: target)
        defer { manager.cleanup() }

        let snapshot = presentationSnapshot(
            for: profile,
            usage: usage(sessionPercentage: 96)
        )
        manager.updateHealthStrip(
            profiles: [profile],
            config: MultiProfileDisplayConfig(),
            threshold: .percent(90),
            activeClaudeProfileID: nil,
            snapshots: [profile.id: snapshot]
        )

        XCTAssertEqual(
            manager.healthStripNumbersShownForTesting[profile.id],
            true,
            "The threshold read the snapshot's 96%, not the record's 10%"
        )
        let button = try XCTUnwrap(manager.healthStripButton)
        XCTAssertTrue(
            button.toolTip?.contains("96%") == true,
            "and the words say the same figure the bar was drawn from"
        )
    }

    // MARK: - Fixtures

    private func usage(sessionPercentage: Double) -> ClaudeUsage {
        var reading = ClaudeUsage.empty
        reading.sessionPercentage = sessionPercentage
        reading.sessionPercentageAvailable = true
        reading.sessionResetTime = Date().addingTimeInterval(3_600)
        reading.weeklyPercentage = 5
        reading.weeklyPercentageAvailable = true
        return reading
    }

    private func presentationSnapshot(
        for profile: Profile,
        usage: ClaudeUsage
    ) -> PresentationSnapshot {
        PresentationSnapshot(
            profileID: profile.id,
            profileName: profile.name,
            providerID: profile.providerID,
            providerRevision: profile.providerRevision,
            presentationEpoch: 1,
            capabilities: ProviderCapabilities(),
            configurationState: .ready,
            report: nil,
            claudeUsage: usage,
            claudeAPIUsage: nil,
            activity: .idle,
            lastSuccessfulAt: nil,
            currentFailure: nil
        )
    }
}
