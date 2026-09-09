//
//  HealthStripSettingsPersistenceTests.swift
//  Claude UsageTests
//
//  Created by Claude Code on 2026-09-08.
//

import XCTest
@testable import Claude_Usage

/// Tests `DataStore`'s persistence of the two health strip settings — the
/// multi-profile layout and the "show numbers above" threshold — with the
/// same emphasis on missing-key defaults as `MenuBarOverflowModeTests`.
final class HealthStripSettingsPersistenceTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let (testDefaults, testSuiteName) = try HostedTestDefaults.defaults(
            "HealthStripSettingsPersistenceTests"
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

    // MARK: - Layout

    func testMissingLayoutKeyDefaultsToPerProfileItems() {
        XCTAssertEqual(
            DataStore.menuBarMultiLayout(in: defaults),
            .perProfileItems,
            "The health strip is opt-in: a fresh install, and every user who "
                + "never touches the setting, must keep one item per account"
        )
    }

    func testStoredLayoutsRoundTrip() {
        defaults.set("healthStrip", forKey: "menuBarMultiLayout")
        XCTAssertEqual(
            DataStore.menuBarMultiLayout(in: defaults),
            .healthStrip
        )

        defaults.set("perProfileItems", forKey: "menuBarMultiLayout")
        XCTAssertEqual(
            DataStore.menuBarMultiLayout(in: defaults),
            .perProfileItems
        )
    }

    func testUnrecognizedStoredLayoutFallsBackToPerProfileItems() {
        defaults.set("some-future-layout", forKey: "menuBarMultiLayout")

        XCTAssertEqual(
            DataStore.menuBarMultiLayout(in: defaults),
            .perProfileItems
        )
    }

    // MARK: - Numbers threshold

    func testMissingThresholdKeyDefaultsToDefaultPercent() {
        XCTAssertEqual(
            DataStore.healthStripNumbersThreshold(in: defaults),
            .percent(MenuBarHealthStripNumbersThreshold.defaultPercent)
        )
        XCTAssertEqual(
            MenuBarHealthStripNumbersThreshold.defaultPercent,
            90
        )
    }

    func testStoredPercentRoundTrips() {
        defaults.set("percent", forKey: "menuBarHealthStripNumbersKind")
        defaults.set(80, forKey: "menuBarHealthStripNumbersPercent")

        XCTAssertEqual(
            DataStore.healthStripNumbersThreshold(in: defaults),
            .percent(80)
        )
    }

    func testStoredNeverRoundTrips() {
        defaults.set("never", forKey: "menuBarHealthStripNumbersKind")

        XCTAssertEqual(
            DataStore.healthStripNumbersThreshold(in: defaults),
            .never
        )
    }

    func testPercentKindWithMissingOrZeroPercentFallsBackToDefault() {
        defaults.set("percent", forKey: "menuBarHealthStripNumbersKind")
        // No percentage stored at all.
        XCTAssertEqual(
            DataStore.healthStripNumbersThreshold(in: defaults),
            .percent(MenuBarHealthStripNumbersThreshold.defaultPercent)
        )

        defaults.set(0, forKey: "menuBarHealthStripNumbersPercent")
        XCTAssertEqual(
            DataStore.healthStripNumbersThreshold(in: defaults),
            .percent(MenuBarHealthStripNumbersThreshold.defaultPercent)
        )

        defaults.set(-5, forKey: "menuBarHealthStripNumbersPercent")
        XCTAssertEqual(
            DataStore.healthStripNumbersThreshold(in: defaults),
            .percent(MenuBarHealthStripNumbersThreshold.defaultPercent)
        )
    }

    func testStoredPercentOutsideSelectableSetSnapsToNearestSelectable() {
        defaults.set("percent", forKey: "menuBarHealthStripNumbersKind")

        // 91 is equidistant from nowhere in {80, 90, 95}: it is 1 away from
        // 90, so it must land there rather than blanking the Settings picker,
        // which only offers 80/90/95 tags.
        defaults.set(91, forKey: "menuBarHealthStripNumbersPercent")
        XCTAssertEqual(
            DataStore.healthStripNumbersThreshold(in: defaults),
            .percent(90)
        )

        // Each selectable value must load unchanged.
        for selectable in MenuBarHealthStripNumbersThreshold
            .selectablePercents {
            defaults.set(
                selectable,
                forKey: "menuBarHealthStripNumbersPercent"
            )
            XCTAssertEqual(
                DataStore.healthStripNumbersThreshold(in: defaults),
                .percent(selectable)
            )
        }

        // A tie between two selectable levels (85 is 5 from both 80 and 90)
        // resolves to the higher one, so the app shows numbers less often
        // rather than more often.
        defaults.set(85, forKey: "menuBarHealthStripNumbersPercent")
        XCTAssertEqual(
            DataStore.healthStripNumbersThreshold(in: defaults),
            .percent(90)
        )
    }

    func testUnrecognizedStoredKindFallsBackToDefaultPercent() {
        defaults.set(
            "some-future-kind",
            forKey: "menuBarHealthStripNumbersKind"
        )

        XCTAssertEqual(
            DataStore.healthStripNumbersThreshold(in: defaults),
            .percent(MenuBarHealthStripNumbersThreshold.defaultPercent),
            "An unrecognized kind must not silently mean 'never show numbers'"
        )
    }

    /// The instance-level pair writes through to `UserDefaults.standard`;
    /// this restores the previous values so the suite can't leak into other
    /// tests or the developer machine running it.
    func testInstanceSaveAndLoadRoundTripThroughStandardDefaults() {
        let previousLayout = DataStore.shared.loadMenuBarMultiLayout()
        let previousThreshold =
            DataStore.shared.loadHealthStripNumbersThreshold()
        addTeardownBlock {
            DataStore.shared.saveMenuBarMultiLayout(previousLayout)
            DataStore.shared.saveHealthStripNumbersThreshold(
                previousThreshold
            )
        }

        DataStore.shared.saveMenuBarMultiLayout(.healthStrip)
        XCTAssertEqual(
            DataStore.shared.loadMenuBarMultiLayout(),
            .healthStrip
        )

        DataStore.shared.saveHealthStripNumbersThreshold(.percent(95))
        XCTAssertEqual(
            DataStore.shared.loadHealthStripNumbersThreshold(),
            .percent(95)
        )

        DataStore.shared.saveHealthStripNumbersThreshold(.never)
        XCTAssertEqual(
            DataStore.shared.loadHealthStripNumbersThreshold(),
            .never
        )
    }
}
