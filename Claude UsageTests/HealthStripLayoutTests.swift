//
//  HealthStripLayoutTests.swift
//  Claude UsageTests
//
//  Created by Claude Code on 2026-09-08.
//

import XCTest
@testable import Claude_Usage

/// Tests the health strip's pure geometry: pitch, total width, and which
/// account a click at a given x belongs to. GUI-free, like
/// `MenuBarSpaceCalculatorTests`.
final class HealthStripLayoutTests: XCTestCase {

    private func plainInputs(_ count: Int) -> [(id: UUID, numbersWidth: CGFloat?)] {
        (0..<count).map { _ in (id: UUID(), numbersWidth: nil) }
    }

    // MARK: - Pitch and total width

    func testSingleProfileCellStartsAfterTheEdgePadding() {
        let inputs = plainInputs(1)
        let cells = HealthStripLayout.cells(for: inputs)

        XCTAssertEqual(cells.count, 1)
        XCTAssertEqual(cells[0].minX, HealthStripLayout.edgePadding)
        XCTAssertEqual(
            cells[0].width,
            HealthStripLayout.barWidth + HealthStripLayout.cellGap
        )
        XCTAssertEqual(HealthStripLayout.totalWidth(cells), 1 + 7 + 1)
    }

    func testEightPlainProfilesUseA7PointPitchAnd58PointsTotal() {
        let inputs = plainInputs(8)
        let cells = HealthStripLayout.cells(for: inputs)

        for index in 1..<cells.count {
            XCTAssertEqual(
                cells[index].minX - cells[index - 1].minX,
                7,
                "Plain cells sit on a 7pt pitch (4pt bar + 3pt gap)"
            )
        }
        XCTAssertEqual(
            HealthStripLayout.totalWidth(cells),
            58,
            "Eight plain accounts must come to 1 + 8*7 + 1 points"
        )
    }

    func testTwentyProfilesStayOnTheSamePitch() {
        let cells = HealthStripLayout.cells(for: plainInputs(20))

        XCTAssertEqual(cells.count, 20)
        XCTAssertEqual(HealthStripLayout.totalWidth(cells), 1 + 20 * 7 + 1)
    }

    func testEmptyInputProducesJustTheTwoEdgePaddings() {
        let cells = HealthStripLayout.cells(for: [])

        XCTAssertTrue(cells.isEmpty)
        XCTAssertEqual(HealthStripLayout.totalWidth(cells), 2)
    }

    // MARK: - Numbers widen only their own cell

    func testANumericCellWidensOnlyItselfAndShiftsWhatFollows() {
        let ids = (0..<3).map { _ in UUID() }
        let inputs: [(id: UUID, numbersWidth: CGFloat?)] = [
            (id: ids[0], numbersWidth: nil),
            (id: ids[1], numbersWidth: 30),
            (id: ids[2], numbersWidth: nil)
        ]
        let cells = HealthStripLayout.cells(for: inputs)

        XCTAssertEqual(cells[0].width, 7)
        XCTAssertEqual(
            cells[1].width,
            HealthStripLayout.barWidth
                + HealthStripLayout.numbersGap
                + 30
                + HealthStripLayout.cellGap,
            "A numeric cell is bar + gap + numbers + trailing gap"
        )
        XCTAssertEqual(cells[2].width, 7, "The neighbour keeps its own width")
        XCTAssertEqual(cells[1].minX, 8)
        XCTAssertEqual(cells[2].minX, 8 + 39)
        XCTAssertEqual(HealthStripLayout.totalWidth(cells), 1 + 7 + 39 + 7 + 1)
    }

    func testAZeroWidthNumbersImageIsTreatedAsNoNumbers() {
        let cells = HealthStripLayout.cells(
            for: [(id: UUID(), numbersWidth: 0)]
        )

        XCTAssertEqual(cells[0].width, 7)
    }

    // MARK: - Order

    func testCellsFollowThePreparedWeeklyResetOrder() {
        func profile(_ name: String, weeklyReset: TimeInterval) -> Profile {
            var usage = ClaudeUsage.empty
            usage.weeklyPercentageAvailable = true
            usage.weeklyResetTime = Date(timeIntervalSince1970: weeklyReset)
            var profile = Profile(name: name)
            profile.claudeUsage = usage
            return profile
        }
        let late = profile("Late", weeklyReset: 300)
        let early = profile("Early", weeklyReset: 100)
        let middle = profile("Middle", weeklyReset: 200)
        let ordered = ProfileResetOrder.sorted(
            [late, early, middle],
            snapshots: [:]
        )
        let cells = HealthStripLayout.cells(
            for: ordered.map { (id: $0.id, numbersWidth: nil) }
        )

        XCTAssertEqual(
            cells.map(\.profileID),
            [early.id, middle.id, late.id]
        )
    }

    // MARK: - Hit testing

    func testHitTestResolvesBothEdgesOfEveryCell() {
        let ids = (0..<3).map { _ in UUID() }
        let cells = HealthStripLayout.cells(
            for: ids.map { (id: $0, numbersWidth: nil) }
        )

        for (index, cell) in cells.enumerated() {
            XCTAssertEqual(
                HealthStripLayout.profileID(atX: cell.minX, in: cells),
                ids[index],
                "The left edge of a cell belongs to that cell"
            )
            XCTAssertEqual(
                HealthStripLayout.profileID(
                    atX: cell.minX + cell.width - 0.01,
                    in: cells
                ),
                ids[index],
                "The last point before the next cell still belongs to this one"
            )
        }
    }

    func testHitTestAtACellBoundaryBelongsToTheFollowingCell() {
        let ids = (0..<2).map { _ in UUID() }
        let cells = HealthStripLayout.cells(
            for: ids.map { (id: $0, numbersWidth: nil) }
        )

        XCTAssertEqual(
            HealthStripLayout.profileID(
                atX: cells[0].minX + cells[0].width,
                in: cells
            ),
            ids[1]
        )
    }

    func testHitTestInThePaddingAtEitherEndReturnsNil() {
        let cells = HealthStripLayout.cells(for: plainInputs(3))

        XCTAssertNil(
            HealthStripLayout.profileID(atX: 0, in: cells),
            "The leading 1pt margin belongs to no account"
        )
        XCTAssertNil(
            HealthStripLayout.profileID(
                atX: HealthStripLayout.totalWidth(cells) - 0.5,
                in: cells
            ),
            "The trailing 1pt margin belongs to no account"
        )
        XCTAssertNil(
            HealthStripLayout.profileID(atX: -5, in: cells)
        )
        XCTAssertNil(
            HealthStripLayout.profileID(atX: 1_000, in: cells)
        )
    }

    func testHitTestOnAnEmptyStripReturnsNil() {
        XCTAssertNil(HealthStripLayout.profileID(atX: 1, in: []))
    }

    func testHitTestLandsOnTheAccountWhoseNumbersWereClicked() {
        let ids = (0..<2).map { _ in UUID() }
        let cells = HealthStripLayout.cells(
            for: [
                (id: ids[0], numbersWidth: 30),
                (id: ids[1], numbersWidth: nil)
            ]
        )

        XCTAssertEqual(
            HealthStripLayout.profileID(atX: 20, in: cells),
            ids[0],
            "A click on the digits belongs to the account they describe"
        )
    }
}
