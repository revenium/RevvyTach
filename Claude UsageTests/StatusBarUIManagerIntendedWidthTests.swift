//
//  StatusBarUIManagerIntendedWidthTests.swift
//  Claude UsageTests
//
//  Created by Claude Code on 2026-08-08.
//

import AppKit
import UsageCore
import XCTest
@testable import Claude_Usage

/// Covers the intended-width machinery `currentOverflowPlan(for:)` relies on
/// to plan the overflow split from what a profile's item WILL render as,
/// rather than a render-behind measurement or the old hardcoded 40pt
/// estimate. See `StatusBarOverflowTests` for the overflow-plan tests this
/// complements.
@MainActor
final class StatusBarUIManagerIntendedWidthTests: HostedAppTestCase {
    private final class MenuTarget: NSObject {
        @objc func toggle() {}
    }

    /// A `MenuBarSpaceProbing` fake that returns a fixed app-menu/status-
    /// region boundary measurement while capturing the `ourItemWidths` the
    /// manager fed it, so tests can assert on the per-profile width the
    /// overflow planner actually used without depending on `automatic`
    /// mode's collapse decision.
    private final class FakeSpaceProbe: MenuBarSpaceProbing {
        var fixedMeasurement: (
            appMenuMaxX: CGFloat, statusRegionMinX: CGFloat
        )?
        private(set) var lastOurItemWidths: [CGFloat] = []

        func makeLayoutInput(
            ourItemWidths: [CGFloat],
            overflowItemWidth: CGFloat,
            currentlyOnScreenWidth: CGFloat
        ) -> MenuBarLayoutInput? {
            lastOurItemWidths = ourItemWidths
            guard let fixedMeasurement else { return nil }
            return MenuBarLayoutInput(
                appMenuMaxX: fixedMeasurement.appMenuMaxX,
                statusRegionMinX: fixedMeasurement.statusRegionMinX,
                ourItemWidths: ourItemWidths,
                overflowItemWidth: overflowItemWidth,
                currentlyOnScreenWidth: currentlyOnScreenWidth
            )
        }
    }

    /// A `RunningApplicationBundleIdentifiersProviding` fake reporting no
    /// menu bar manager, so tests exercising `.automatic` mode's space-probe
    /// path aren't at the mercy of whatever is actually running on the
    /// machine executing them. Mirrors `StatusBarOverflowTests`'s private
    /// fake of the same name — this machine genuinely runs Thaw, and without
    /// this injection `currentOverflowPlan` would detect it as a manager and
    /// skip the probe entirely, which is exactly the regression this file's
    /// `testAutomaticModeUsesIntendedWidthOnlyForClaudeProfiles` would
    /// otherwise silently fall victim to.
    private final class FakeRunningApplications:
        RunningApplicationBundleIdentifiersProviding
    {
        var bundleIdentifiers: [String] = []
        var runningBundleIdentifiers: [String] { bundleIdentifiers }
    }

    private func makeProfile(sessionPercentage: Double) -> Profile {
        var usage = ClaudeUsage.empty
        usage.sessionPercentage = sessionPercentage
        // `ClaudeUsage.empty` means "nothing has been read yet" and renders
        // as a dash, so these profiles have to say the figure below is a real
        // reading — otherwise every width here would be the dash's width.
        usage.sessionPercentageAvailable = true
        usage.weeklyPercentageAvailable = true
        usage.sessionResetTime = Date().addingTimeInterval(3_600)
        var profile = Profile(name: "Test")
        profile.claudeUsage = usage
        return profile
    }

    // MARK: - renderProfileMenuBar

    func testRenderProfileMenuBarWidthIsIndependentOfDarkMode() {
        let manager = retain(StatusBarUIManager())
        defer { manager.cleanup() }
        let profile = makeProfile(sessionPercentage: 42)
        let config = MultiProfileDisplayConfig()

        let light = manager.renderProfileMenuBar(
            for: profile,
            config: config,
            isDarkMode: false,
            isActive: false
        )
        let dark = manager.renderProfileMenuBar(
            for: profile,
            config: config,
            isDarkMode: true,
            isActive: false
        )

        XCTAssertEqual(
            light.image.size.width,
            dark.image.size.width,
            accuracy: 0.01,
            "appearance changes colour only; geometry must not depend on it "
                + "— intendedItemWidth always renders isDarkMode: false"
        )
    }

    // MARK: - intendedItemWidth

    func testIntendedItemWidthVariesWithPercentageDigitCount() {
        let manager = retain(StatusBarUIManager())
        defer { manager.cleanup() }
        // Profile label off: it's clamped to a fixed 3-character floor
        // (`String(profileName.prefix(3)).count * 6 + 4`) that would
        // otherwise mask small differences in the percentage text's own
        // width for a short profile name.
        let config = MultiProfileDisplayConfig(
            iconStyle: .percentage,
            showWeek: false,
            showProfileLabel: false
        )

        let oneDigit = manager.intendedItemWidth(
            for: makeProfile(sessionPercentage: 5),
            config: config,
            isActive: false
        )
        let twoDigits = manager.intendedItemWidth(
            for: makeProfile(sessionPercentage: 42),
            config: config,
            isActive: false
        )
        let threeDigits = manager.intendedItemWidth(
            for: makeProfile(sessionPercentage: 100),
            config: config,
            isActive: false
        )

        XCTAssertNotEqual(
            oneDigit,
            twoDigits,
            "a 1-digit and a 2-digit percentage must not render the same width"
        )
        XCTAssertNotEqual(
            twoDigits,
            threeDigits,
            "a 2-digit and a 3-digit percentage must not render the same width"
        )
        XCTAssertNotEqual(
            twoDigits,
            StatusBarUIManager.estimatedProfileItemWidth,
            "must not silently collapse back to the old hardcoded 40pt estimate"
        )
    }

    func testIntendedItemWidthVariesWithShowWeek() {
        let manager = retain(StatusBarUIManager())
        defer { manager.cleanup() }
        let profile = makeProfile(sessionPercentage: 42)
        let withoutWeek = MultiProfileDisplayConfig(
            iconStyle: .percentage,
            showWeek: false,
            showProfileLabel: false
        )
        let withWeek = MultiProfileDisplayConfig(
            iconStyle: .percentage,
            showWeek: true,
            showProfileLabel: false
        )

        let widthWithoutWeek = manager.intendedItemWidth(
            for: profile,
            config: withoutWeek,
            isActive: false
        )
        let widthWithWeek = manager.intendedItemWidth(
            for: profile,
            config: withWeek,
            isActive: false
        )

        XCTAssertNotEqual(
            widthWithoutWeek,
            widthWithWeek,
            "showing the weekly window must change the rendered width — "
                + "it is not a constant, which is what the 40pt estimate got wrong"
        )
    }

    // MARK: - currentOverflowPlan / provider-specific width estimation

    func testAutomaticModeUsesIntendedWidthOnlyForClaudeProfiles() {
        let manager = retain(StatusBarUIManager())
        defer { manager.cleanup() }
        manager.overflowMode = .automatic
        let fakeProbe = FakeSpaceProbe()
        fakeProbe.fixedMeasurement = (appMenuMaxX: 0, statusRegionMinX: 6008)
        manager.spaceProbe = fakeProbe
        // See FakeRunningApplications above: isolate this test from real
        // menu bar manager state, or the probe assertions below would
        // depend on nothing being detected as running on this machine.
        manager.runningApplicationsProvider = FakeRunningApplications()

        let config = MultiProfileDisplayConfig(
            iconStyle: .percentage,
            showWeek: false,
            showProfileLabel: false
        )
        // `currentOverflowPlan` reads config from
        // `ProfileManager.shared.multiProfileConfig`, not a value passed
        // in — so the shared config must be set to match what this test
        // measures against, and restored afterward since `.shared` is a
        // process-wide singleton other tests also rely on.
        let previousConfig = ProfileManager.shared.multiProfileConfig
        ProfileManager.shared.multiProfileConfig = config
        defer { ProfileManager.shared.multiProfileConfig = previousConfig }

        let claudeProfile = makeProfile(sessionPercentage: 42)
        let codexProfile = Profile(
            name: "Codex",
            providerConfiguration: .codex(.init())
        )

        // Computed before any status item exists, matching the state
        // `currentOverflowPlan` sees internally during `setupMultiProfile`
        // (which calls `cleanup()` first) — `calibratedButtonPadding()` is
        // stateful and returns a different (real, measured) value once
        // status items exist, so comparing against a post-setup call here
        // would compare two different paddings rather than the same width.
        // `isActive` must also match what `currentOverflowPlan` resolves
        // internally (`profile.id == ProfileManager.shared.activeClaudeProfileID`),
        // since the active-profile underline changes the rendered width.
        let expectedClaudeWidth = manager.intendedItemWidth(
            for: claudeProfile,
            config: config,
            isActive: claudeProfile.id
                == ProfileManager.shared.activeClaudeProfileID
        )

        let target = MenuTarget()
        manager.setupMultiProfile(
            profiles: [claudeProfile, codexProfile],
            target: target,
            action: #selector(MenuTarget.toggle)
        )

        XCTAssertEqual(
            fakeProbe.lastOurItemWidths.count,
            2,
            "the space probe must be asked to plan both profiles"
        )

        XCTAssertEqual(
            fakeProbe.lastOurItemWidths[0],
            expectedClaudeWidth,
            accuracy: 0.01,
            "a Claude profile's planning width must still come from "
                + "intendedItemWidth"
        )

        XCTAssertEqual(
            fakeProbe.lastOurItemWidths[1],
            StatusBarUIManager.estimatedProfileItemWidth,
            "a non-Claude profile has no status item yet, so its planning "
                + "width must fall back to the estimate — not "
                + "intendedItemWidth, which only knows how to render "
                + "Claude's icon and would silently measure the wrong "
                + "provider's content"
        )
    }

    // MARK: - calibratedButtonPadding

    func testCalibratedButtonPaddingReturnsNilWithNoQualifyingItem() {
        let manager = retain(StatusBarUIManager())
        defer { manager.cleanup() }

        XCTAssertNil(
            manager.calibratedButtonPadding(),
            "with no status item created yet, no button has both a "
                + "laid-out window and an image to measure"
        )
    }
}
