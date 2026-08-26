//
//  MenuBarOverflowModeTests.swift
//  Claude UsageTests
//
//  Created by Claude Code on 2026-08-07.
//

import XCTest
@testable import Claude_Usage

/// Tests `DataStore`'s persistence of the menu bar overflow mode, in
/// particular the missing-key default — the exact class of bug
/// `DataStore.masterSwitchEnabled(in:)` exists to prevent for the
/// notifications master switch (see `ProviderHistoryNotificationTests`).
final class MenuBarOverflowModeTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let (testDefaults, testSuiteName) = try HostedTestDefaults.defaults(
            "MenuBarOverflowModeTests"
        )
        suiteName = testSuiteName
        defaults = testDefaults
        HostedTestDefaults.reset(defaults, suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        HostedTestDefaults.finish(defaults, suiteName: suiteName)
        defaults = nil
        suiteName = nil
        try super.tearDownWithError()
    }

    private func makeIsolatedDefaults() -> UserDefaults {
        return defaults
    }

    func testMissingKeyDefaultsToAutomatic() {
        let defaults = makeIsolatedDefaults()

        XCTAssertEqual(
            DataStore.menuBarOverflowMode(in: defaults),
            .automatic,
            "A fresh install (no stored key) must default to .automatic, "
                + "not to whatever a bare zero-value read would give"
        )
    }

    func testSavingNeverRoundTrips() {
        let defaults = makeIsolatedDefaults()
        defaults.set("never", forKey: "menuBarOverflowMode")

        XCTAssertEqual(
            DataStore.menuBarOverflowMode(in: defaults),
            .never
        )
    }

    func testSavingAutomaticRoundTrips() {
        let defaults = makeIsolatedDefaults()
        defaults.set("automatic", forKey: "menuBarOverflowMode")

        XCTAssertEqual(
            DataStore.menuBarOverflowMode(in: defaults),
            .automatic
        )
    }

    func testSavingAfterCountRoundTripsItsThreshold() {
        let defaults = makeIsolatedDefaults()
        defaults.set("afterCount", forKey: "menuBarOverflowMode")
        defaults.set(7, forKey: "menuBarOverflowAfterCountThreshold")

        XCTAssertEqual(
            DataStore.menuBarOverflowMode(in: defaults),
            .afterCount(7)
        )
    }

    func testAfterCountWithMissingOrNonPositiveThresholdFallsBackToDefault() {
        let defaults = makeIsolatedDefaults()
        defaults.set("afterCount", forKey: "menuBarOverflowMode")
        // No threshold stored at all.

        XCTAssertEqual(
            DataStore.menuBarOverflowMode(in: defaults),
            .afterCount(MenuBarOverflowMode.defaultAfterCountThreshold)
        )

        defaults.set(0, forKey: "menuBarOverflowAfterCountThreshold")
        XCTAssertEqual(
            DataStore.menuBarOverflowMode(in: defaults),
            .afterCount(MenuBarOverflowMode.defaultAfterCountThreshold)
        )
    }

    func testUnrecognizedStoredValueFallsBackToAutomatic() {
        let defaults = makeIsolatedDefaults()
        // Simulates a future/foreign build writing a raw value this
        // version doesn't recognize.
        defaults.set("some-future-mode", forKey: "menuBarOverflowMode")

        XCTAssertEqual(
            DataStore.menuBarOverflowMode(in: defaults),
            .automatic
        )
    }

    /// `DataStore.shared.saveMenuBarOverflowMode(_:)` /
    /// `loadMenuBarOverflowMode()` write through to
    /// `UserDefaults.standard`; this is the one test in the file that
    /// exercises that instance-level pair directly, restoring the prior
    /// value afterward so it can't leak into other tests or the real
    /// developer machine running this suite.
    func testInstanceSaveAndLoadRoundTripThroughStandardDefaults() {
        let previous = DataStore.shared.loadMenuBarOverflowMode()
        addTeardownBlock {
            DataStore.shared.saveMenuBarOverflowMode(previous)
        }

        DataStore.shared.saveMenuBarOverflowMode(.afterCount(9))
        XCTAssertEqual(
            DataStore.shared.loadMenuBarOverflowMode(),
            .afterCount(9)
        )

        DataStore.shared.saveMenuBarOverflowMode(.never)
        XCTAssertEqual(
            DataStore.shared.loadMenuBarOverflowMode(),
            .never
        )
    }
}
