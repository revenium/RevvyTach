//
//  HealthStripAccountsViewLayoutTests.swift
//  Claude UsageTests
//
//  Created by Claude Code on 2026-09-08.
//

import AppKit
import SwiftUI
import UsageCore
import XCTest
@testable import Claude_Usage

/// Renders the strip's accounts list and measures it.
///
/// The list self-sizes under `sizingOptions = .preferredContentSize`, and it
/// puts a `ScrollView` inside `fixedSize(vertical:)` — a combination this app
/// has nowhere else. If the scroll view ever reports something other than its
/// content's height there, the row area collapses and the popover shows a
/// header and a footer with a hairline between them. Nothing else in the suite
/// renders this view, so this is the only place that would catch it.
@MainActor
final class HealthStripAccountsViewLayoutTests: XCTestCase {

    func testResetLabelsRefreshEveryMinute() {
        XCTAssertEqual(HealthStripAccountsView.clockRefreshInterval, 60)
    }

    private func rows(_ count: Int) -> [HealthStripAccountRow] {
        (0..<count).map { index in
            HealthStripAccountRow(
                identity: ProviderStatusItemIdentity(
                    profileID: UUID(),
                    providerID: .claude,
                    providerRevision: 0,
                    metricID: nil
                ),
                name: "Account \(index)",
                windows: [
                    OverflowProfileRow.Window(
                        name: "Session",
                        percentageText: "42%",
                        modeText: "used"
                    ),
                    OverflowProfileRow.Window(
                        name: "Week",
                        percentageText: "78%",
                        modeText: "used"
                    )
                ],
                isActive: index == 0,
                attention: nil,
                paceStatus: nil,
                canActivate: index != 0
            )
        }
    }

    private func measuredSize(rowCount: Int) -> NSSize {
        let view = HealthStripAccountsView(
            rows: rows(rowCount),
            onOpen: { _ in },
            onActivate: { _ in },
            onRefresh: { _ in },
            onRefreshAll: {},
            onManageProfiles: {},
            onQuit: {}
        )
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    func testTheListGrowsWithRowsAndThenStopsAtTheCap() {
        let one = measuredSize(rowCount: 1)
        let five = measuredSize(rowCount: 5)
        let twenty = measuredSize(rowCount: 20)

        // Reported so a future layout change can be compared against real
        // numbers rather than re-derived from the view's constants.
        print(
            "HealthStripAccountsView fitting heights — "
                + "1 row: \(one.height), 5 rows: \(five.height), "
                + "20 rows: \(twenty.height)"
        )

        XCTAssertEqual(one.width, HealthStripAccountsView.width)

        // (a) One row's popover has room for the header, that row, the
        // divider and the footer. A collapsed row area lands well under this.
        XCTAssertGreaterThanOrEqual(
            one.height,
            PopoverDesign.outerInset * 2
                + 16
                + HealthStripAccountsView.rowHeight
                + 30,
            "A one-row list must have room for a header, a row and the "
                + "footer; a collapsed ScrollView would fall short here"
        )

        // (b) It grows with the rows.
        XCTAssertGreaterThan(
            five.height,
            one.height + 3 * HealthStripAccountsView.rowHeight,
            "Four more rows must add height; if they do not, the row area is "
                + "not being measured at all"
        )

        // (c) And it stops growing once the row area is capped. Fifteen
        // more rows add far less than fifteen rows of height.
        XCTAssertGreaterThan(twenty.height, five.height)
        XCTAssertLessThan(
            twenty.height,
            five.height + 15 * HealthStripAccountsView.rowHeight,
            "20 rows must scroll rather than grow the popover"
        )
        XCTAssertLessThanOrEqual(
            twenty.height,
            HealthStripAccountsView.scrollMaxHeight + 140,
            "The capped list is the row area plus the popover's own chrome"
        )
    }

    func testAnEmptyListStillRendersItsHeaderAndFooter() {
        let empty = measuredSize(rowCount: 0)

        XCTAssertEqual(empty.width, HealthStripAccountsView.width)
        XCTAssertGreaterThan(empty.height, 40)
    }
}
