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

    /// Splitting the non-Claude half of `updateProviderMultiProfileButtons`
    /// out is where a Codex item could silently go blank in strip layout
    /// only, so it is not enough that its item is still visible.
    func testACodexItemStillGetsAnImageInStripLayout() throws {
        let target = MenuTarget()
        let codex = codexProfile()
        let profiles = claudeProfiles(1) + [codex]
        let manager = makeStripManager(profiles: profiles, target: target)
        defer { manager.cleanup() }

        let presentations = ProviderMenuPresentationBuilder.presentations(
            profiles: profiles,
            snapshots: [:],
            now: Date(),
            isActive: { _ in false }
        )
        manager.updateNonClaudeMultiProfileButtons(
            presentations: presentations,
            profiles: profiles,
            config: MultiProfileDisplayConfig(),
            isActive: { _ in false }
        )

        let button = try XCTUnwrap(manager.button(for: codex.id))
        XCTAssertNotNil(
            button.image,
            "A Codex account must still be drawn while the strip is on"
        )
        XCTAssertGreaterThan(
            button.image?.size.width ?? 0,
            0
        )
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
    }

    // MARK: - Cell hit test

    /// The cells are laid out in the strip image's coordinates, but a click
    /// arrives in the button's, and the button is wider than the image and
    /// centres it. Measured on a real item the gap is about one 7pt cell
    /// pitch, so without the conversion cell n resolves as cell n-1 and
    /// Refresh on the fifth account refreshes the fourth.
    func testTheInsetConversionMovesAClickIntoImageSpace() {
        XCTAssertEqual(
            StatusBarUIManager.healthStripCanvasX(
                buttonX: 20,
                buttonWidth: 72,
                imageWidth: 58
            ),
            13,
            "A 72pt button around a 58pt image insets it by 7pt per side"
        )
        XCTAssertEqual(
            StatusBarUIManager.healthStripCanvasX(
                buttonX: 20,
                buttonWidth: 58,
                imageWidth: 58
            ),
            20,
            "With no inset the two spaces are the same"
        )
    }

    func testEveryCellResolvesThroughTheRealButtonGeometry() throws {
        let target = MenuTarget()
        let profiles = claudeProfiles(5)
        let manager = makeStripManager(profiles: profiles, target: target)
        defer { manager.cleanup() }
        manager.updateHealthStrip(
            profiles: profiles,
            config: MultiProfileDisplayConfig(),
            threshold: .percent(90),
            activeClaudeProfileID: profiles[0].id
        )

        let button = try XCTUnwrap(manager.healthStripButton)
        let image = try XCTUnwrap(button.image)
        let inset = (button.bounds.width - image.size.width) / 2

        for (index, profile) in profiles.enumerated() {
            // The centre of this account's own 4pt bar, in image space,
            // pushed back out into the button's coordinates the way a real
            // click arrives.
            let canvasX = HealthStripLayout.edgePadding
                + CGFloat(index) * 7
                + HealthStripLayout.barWidth / 2
            XCTAssertEqual(
                manager.healthStripProfileID(atButtonX: canvasX + inset),
                profile.id,
                "Cell \(index) must resolve to its own account"
            )
        }
        XCTAssertEqual(
            manager.healthStripProfileID(atButtonX: inset),
            nil,
            "The leading 1pt margin belongs to no account"
        )
        XCTAssertNil(
            manager.healthStripProfileID(atButtonX: 0),
            "and neither does the button's own padding"
        )
    }

    /// A real right-click event on cell 0 and on the last cell.
    ///
    /// This is the whole resolution chain a context menu goes through:
    /// `NSEvent.locationInWindow` → the button's coordinates → the image's →
    /// the cell. `showContextMenu` itself is not called, because it ends in
    /// `NSMenu.popUp`, which blocks a test run in its own tracking loop.
    func testARightClickResolvesTheFirstAndLastCell() throws {
        let target = MenuTarget()
        let profiles = claudeProfiles(5)
        let manager = makeStripManager(profiles: profiles, target: target)
        defer { manager.cleanup() }
        manager.updateHealthStrip(
            profiles: profiles,
            config: MultiProfileDisplayConfig(),
            threshold: .percent(90),
            activeClaudeProfileID: profiles[0].id
        )

        let button = try XCTUnwrap(manager.healthStripButton)
        let window = try XCTUnwrap(button.window)
        let image = try XCTUnwrap(button.image)
        let buttonOriginX = button.convert(button.bounds, to: nil).minX
        let inset = (button.bounds.width - image.size.width) / 2

        func rightClick(atCanvasX canvasX: CGFloat) throws -> NSEvent {
            try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: .rightMouseUp,
                    location: NSPoint(
                        x: buttonOriginX + inset + canvasX,
                        y: button.convert(button.bounds, to: nil).midY
                    ),
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: 1
                )
            )
        }

        for index in [0, profiles.count - 1] {
            let canvasX = HealthStripLayout.edgePadding
                + CGFloat(index) * 7
                + HealthStripLayout.barWidth / 2
            let event = try rightClick(atCanvasX: canvasX)

            XCTAssertTrue(
                MenuBarManager.isContextMenuEvent(event.type),
                "The event must classify as a context menu, or the strip "
                    + "branch opens the accounts list instead"
            )
            XCTAssertEqual(
                manager.healthStripProfileID(for: event),
                profiles[index].id,
                "A right click on cell \(index) must name that account, not "
                    + "the active one and not its neighbour"
            )
        }
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

    func testTheStripItemSurvivesAFullLayoutRoundTrip() {
        let target = MenuTarget()
        let profiles = claudeProfiles(2)
        let manager = makeStripManager(profiles: profiles, target: target)
        defer { manager.cleanup() }

        let identity = manager.healthStripItemIdentityForTesting
        XCTAssertNotNil(identity)

        for layout in [
            MenuBarMultiLayout.perProfileItems,
            .healthStrip,
            .perProfileItems,
            .healthStrip
        ] {
            manager.multiLayout = layout
            manager.updateMultiProfileConfiguration(
                profiles: profiles,
                target: target,
                action: #selector(MenuTarget.toggle)
            )
            XCTAssertEqual(
                manager.healthStripItemIdentityForTesting,
                identity,
                "Removing the item on the way out would delete its saved "
                    + "menu bar position, so a Thaw or Ice user would lose "
                    + "their arrangement on every toggle of this setting"
            )
        }
        XCTAssertNotNil(manager.healthStripButton)
    }

    // MARK: - Nothing to draw

    func testDeselectingEveryClaudeAccountHidesTheStripButKeepsTheItem() {
        let target = MenuTarget()
        let claude = claudeProfiles(2)
        let codexAccount = codexProfile()
        let manager = makeStripManager(
            profiles: claude + [codexAccount],
            target: target
        )
        defer { manager.cleanup() }
        let identity = manager.healthStripItemIdentityForTesting
        XCTAssertNotNil(manager.healthStripButton)

        let deselected = claude.map { profile -> Profile in
            var hidden = profile
            hidden.isSelectedForDisplay = false
            return hidden
        }
        manager.updateMultiProfileConfiguration(
            profiles: deselected + [codexAccount],
            target: target,
            action: #selector(MenuTarget.toggle)
        )

        XCTAssertNil(
            manager.healthStripButton,
            "An empty strip would be a 2pt sliver in the menu bar opening a "
                + "popover with no accounts in it"
        )
        XCTAssertEqual(
            manager.healthStripItemIdentityForTesting,
            identity,
            "Hidden, not removed"
        )
        XCTAssertNotNil(
            manager.button(for: codexAccount.id),
            "The Codex account still has its own item"
        )
    }

    func testAFullyEmptySelectionFallsBackToTheDefaultLogoItem() {
        let target = MenuTarget()
        let claude = claudeProfiles(1)
        let manager = makeStripManager(profiles: claude, target: target)
        defer { manager.cleanup() }

        var deselected = claude[0]
        deselected.isSelectedForDisplay = false
        manager.updateMultiProfileConfiguration(
            profiles: [deselected],
            target: target,
            action: #selector(MenuTarget.toggle)
        )

        XCTAssertNil(manager.healthStripButton)
        XCTAssertTrue(
            manager.hasValidStatusBar,
            "The existing default-logo placeholder still covers a fully "
                + "empty selection, so the app never goes itemless"
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

    // MARK: - The tighter window drives the bar

    /// The strip's own words state the figure its bar was drawn from, so
    /// they are how these tests read the bar without counting pixels.
    private func stripTooltip(
        _ manager: StatusBarUIManager
    ) throws -> String {
        let button = try XCTUnwrap(manager.healthStripButton)
        return try XCTUnwrap(button.toolTip)
    }

    func testAnIdleSessionWithABusyWeekStillDrawsABusyBar() throws {
        let target = MenuTarget()
        var profile = Profile(name: "Work")
        var reading = usage(sessionPercentage: 10)
        reading.weeklyPercentage = 85
        profile.claudeUsage = reading
        let manager = makeStripManager(profiles: [profile], target: target)
        defer { manager.cleanup() }

        // A threshold the week clears and the session does not: if the
        // strip still keyed on the session alone, 10% would be under it.
        manager.updateHealthStrip(
            profiles: [profile],
            config: MultiProfileDisplayConfig(),
            threshold: .percent(80),
            activeClaudeProfileID: nil
        )

        XCTAssertEqual(
            manager.healthStripNumbersShownForTesting[profile.id],
            true,
            "Headroom is bounded by the tighter window; a 10% session bar "
                + "would call an account near its weekly wall comfortable"
        )
        let tooltip = try stripTooltip(manager)
        let week = StatusBarUIManager.legacyMetricName(for: .week)
        let session = StatusBarUIManager.legacyMetricName(for: .session)
        XCTAssertTrue(
            tooltip.contains("\(week), 85%"),
            "and the words must name the window the bar was drawn from. "
                + "Tooltip was: \(tooltip)"
        )
        XCTAssertTrue(
            tooltip.contains("\(session), 10%"),
            "without dropping the other window"
        )
    }

    func testAnUnreadSessionWithAReadWeekIsNotADash() throws {
        let target = MenuTarget()
        var profile = Profile(name: "Work")
        var reading = ClaudeUsage.empty
        reading.weeklyPercentage = 95
        reading.weeklyPercentageAvailable = true
        profile.claudeUsage = reading
        let manager = makeStripManager(profiles: [profile], target: target)
        defer { manager.cleanup() }

        manager.updateHealthStrip(
            profiles: [profile],
            config: MultiProfileDisplayConfig(),
            threshold: .percent(90),
            activeClaudeProfileID: nil
        )

        XCTAssertEqual(
            manager.healthStripNumbersShownForTesting[profile.id],
            true,
            "A working account at 95% of its week must not be treated as no "
                + "reading just because its session window is missing"
        )
        let tooltip = try stripTooltip(manager)
        let week = StatusBarUIManager.legacyMetricName(for: .week)
        let session = StatusBarUIManager.legacyMetricName(for: .session)
        let noData = ProviderUILocalization.text(
            "menubar.accessibility.state.no_data",
            fallback: "no usage data"
        )
        XCTAssertTrue(tooltip.contains("\(week), 95%"))
        XCTAssertTrue(
            tooltip.contains("\(session), \(noData)"),
            "and the missing window is named rather than passed over"
        )
    }

    func testAnAccountWithNeitherWindowReadIsADash() throws {
        let target = MenuTarget()
        var profile = Profile(name: "Work")
        profile.claudeUsage = ClaudeUsage.empty
        let manager = makeStripManager(profiles: [profile], target: target)
        defer { manager.cleanup() }

        manager.updateHealthStrip(
            profiles: [profile],
            config: MultiProfileDisplayConfig(),
            threshold: .percent(90),
            activeClaudeProfileID: nil
        )

        XCTAssertTrue(
            try stripTooltip(manager).contains(
                ProviderUILocalization.text(
                    "menubar.accessibility.state.no_data",
                    fallback: "no usage data"
                )
            )
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

    /// A snapshot whose provider revision has moved on describes the
    /// account as it was before a re-link or a credential rotation.
    /// Rendering it would put the old identity's numbers on the strip while
    /// every other surface correctly showed none.
    func testASnapshotForAStaleIdentityIsIgnored() throws {
        let target = MenuTarget()
        var profile = Profile(name: "Work", providerRevision: 4)
        profile.claudeUsage = usage(sessionPercentage: 12)
        let manager = makeStripManager(profiles: [profile], target: target)
        defer { manager.cleanup() }

        var stale = presentationSnapshot(
            for: profile,
            usage: usage(sessionPercentage: 96)
        )
        stale = PresentationSnapshot(
            profileID: stale.profileID,
            profileName: stale.profileName,
            providerID: stale.providerID,
            providerRevision: profile.providerRevision + 1,
            presentationEpoch: stale.presentationEpoch,
            capabilities: stale.capabilities,
            configurationState: stale.configurationState,
            report: stale.report,
            claudeUsage: stale.claudeUsage,
            claudeAPIUsage: stale.claudeAPIUsage,
            activity: stale.activity,
            lastSuccessfulAt: stale.lastSuccessfulAt,
            currentFailure: stale.currentFailure
        )

        manager.updateHealthStrip(
            profiles: [profile],
            config: MultiProfileDisplayConfig(),
            threshold: .percent(90),
            activeClaudeProfileID: nil,
            snapshots: [profile.id: stale]
        )

        let button = try XCTUnwrap(manager.healthStripButton)
        XCTAssertTrue(
            button.toolTip?.contains("12%") == true,
            "The profile record must win over a snapshot for a revision "
                + "that no longer exists. Tooltip was: "
                + "\(button.toolTip ?? "nil")"
        )
        XCTAssertEqual(
            manager.healthStripNumbersShownForTesting[profile.id],
            false,
            "and the stale 96% must not trip the numbers threshold"
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
