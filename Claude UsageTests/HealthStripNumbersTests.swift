//
//  HealthStripNumbersTests.swift
//  Claude UsageTests
//
//  Created by Claude Code on 2026-09-08.
//

import XCTest
@testable import Claude_Usage

/// Tests the rule that decides when a health strip cell spells out its
/// numbers, including the hysteresis that stops the strip flapping width on
/// every refresh.
final class HealthStripNumbersTests: XCTestCase {
    private let ninety = MenuBarHealthStripNumbersThreshold.percent(90)

    private func shows(
        session: Double?,
        week: Double?,
        threshold: MenuBarHealthStripNumbersThreshold? = nil,
        showing: Bool = false
    ) -> Bool {
        HealthStripNumbers.showsNumbers(
            sessionUsed: session,
            weekUsed: week,
            threshold: threshold ?? ninety,
            isCurrentlyShowing: showing
        )
    }

    // MARK: - Which window triggers

    func testSessionAloneOverTheThresholdTriggers() {
        XCTAssertTrue(shows(session: 93, week: 10))
    }

    func testWeekAloneOverTheThresholdTriggers() {
        XCTAssertTrue(shows(session: 4, week: 91))
    }

    func testBothUnderTheThresholdDoesNotTrigger() {
        XCTAssertFalse(shows(session: 89.9, week: 88))
    }

    func testExactlyAtTheThresholdTriggers() {
        XCTAssertTrue(
            shows(session: 90, week: 0),
            "The comparison is >=, so an account at exactly 90 shows numbers"
        )
    }

    func testUnknownWindowsNeverTrigger() {
        XCTAssertFalse(
            shows(session: nil, week: nil),
            "An account with no reading has nothing to show"
        )
        XCTAssertFalse(
            shows(session: nil, week: nil, showing: true),
            "And it does not keep numbers it was already showing"
        )
        XCTAssertTrue(
            shows(session: nil, week: 95),
            "One unknown window does not suppress the other's trigger"
        )
    }

    func testNeverThresholdNeverTriggers() {
        XCTAssertFalse(shows(session: 100, week: 100, threshold: .never))
        XCTAssertFalse(
            shows(
                session: 100,
                week: 100,
                threshold: .never,
                showing: true
            ),
            "Switching the setting to Never must drop numbers already shown"
        )
    }

    func testOtherThresholdLevelsMoveTheTrigger() {
        XCTAssertTrue(shows(session: 82, week: 0, threshold: .percent(80)))
        XCTAssertFalse(shows(session: 82, week: 0, threshold: .percent(95)))
    }

    // MARK: - Used, never displayed

    /// The trigger reads the *used* percentage of each window. Remaining mode
    /// changes only what the bar and the digits look like, so an idle account
    /// showing "95% left" must not widen the strip.
    @MainActor
    func testRemainingModeDoesNotFlipTheTrigger() {
        var usage = ClaudeUsage.empty
        usage.sessionPercentage = 5
        usage.sessionPercentageAvailable = true
        usage.sessionResetTime = Date().addingTimeInterval(3_600)
        usage.weeklyPercentage = 5
        usage.weeklyPercentageAvailable = true

        let inputs = HealthStripNumbers.usedPercentages(for: usage)
        XCTAssertEqual(inputs.session, 5)
        XCTAssertEqual(inputs.week, 5)
        XCTAssertFalse(
            shows(session: inputs.session, week: inputs.week),
            "5% used is 95% remaining, and must not trigger at a 90 threshold"
        )
    }

    @MainActor
    func testUnreadWindowsReachTheTriggerAsNil() {
        let inputs = HealthStripNumbers.usedPercentages(for: .empty)

        XCTAssertNil(inputs.session)
        XCTAssertNil(inputs.week)
    }

    // MARK: - Hysteresis

    func testNumbersStayUntilThreePointsBelowTheThreshold() {
        XCTAssertTrue(
            shows(session: 89, week: 0, showing: true),
            "A dip of one point must not narrow the strip again"
        )
        XCTAssertTrue(
            shows(session: 87.5, week: 0, showing: true)
        )
        XCTAssertFalse(
            shows(session: 87, week: 0, showing: true),
            "Three full points below the threshold releases the numbers"
        )
        XCTAssertFalse(
            shows(session: 80, week: 0, showing: true)
        )
    }

    func testHysteresisDoesNotLowerTheTriggerForACellThatIsNotShowing() {
        XCTAssertFalse(
            shows(session: 88, week: 0, showing: false),
            "88 is inside the hysteresis band but has not reached 90 yet"
        )
    }

    func testHysteresisBandFollowsTheChosenThreshold() {
        XCTAssertTrue(
            shows(session: 78, week: 0, threshold: .percent(80), showing: true)
        )
        XCTAssertFalse(
            shows(session: 77, week: 0, threshold: .percent(80), showing: true)
        )
    }

    func testHysteresisPointsIsThree() {
        XCTAssertEqual(
            MenuBarHealthStripNumbersThreshold.hysteresisPoints,
            3
        )
    }
}
