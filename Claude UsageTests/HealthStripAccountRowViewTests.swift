//
//  HealthStripAccountRowViewTests.swift
//  Claude UsageTests
//
//  Created by Claude Code on 2026-09-08.
//

import AppKit
import SwiftUI
import UsageCore
import XCTest
@testable import Claude_Usage

/// The three action buttons on a row of the strip's accounts list.
///
/// Asserting that a handful of localization keys return strings proved
/// nothing about the view: it could not catch a button removed from the row,
/// a dropped label, or Make Active missing when the account could in fact be
/// activated. Walking the rendered row's accessibility tree was tried first
/// and does not work — `NSHostingView` vends no accessibility children
/// outside a real accessibility session, so every assertion silently skipped.
/// The row instead renders `HealthStripAccountRow.actions` through a
/// `ForEach`, so that list *is* the set of buttons, and this inspects it.
@MainActor
final class HealthStripAccountRowViewTests: XCTestCase {

    private func makeRow(
        name: String = "Work",
        canActivate: Bool
    ) -> HealthStripAccountRow {
        HealthStripAccountRow(
            identity: ProviderStatusItemIdentity(
                profileID: UUID(),
                providerID: .claude,
                providerRevision: 0,
                metricID: nil
            ),
            name: name,
            windows: [
                OverflowProfileRow.Window(
                    name: "Session",
                    percentageText: "42%",
                    modeText: "used"
                )
            ],
            isActive: !canActivate,
            attention: nil,
            paceStatus: nil,
            canActivate: canActivate
        )
    }

    func testAnActivatableRowOffersAllThreeActionsInOrder() {
        let row = makeRow(canActivate: true)

        XCTAssertEqual(
            row.actions.map(\.kind),
            [.makeActive, .refresh, .open]
        )
    }

    func testTheActiveAccountLosesOnlyMakeActive() {
        let row = makeRow(canActivate: false)

        XCTAssertEqual(row.actions.map(\.kind), [.refresh, .open])
    }

    func testEveryActionCarriesALocalizedLabelAndASymbol() {
        for canActivate in [true, false] {
            for action in makeRow(canActivate: canActivate).actions {
                XCTAssertFalse(
                    action.label.isEmpty,
                    "\(action.kind) has no label"
                )
                XCTAssertFalse(
                    action.label.contains("menu.provider")
                        || action.label.contains("common.")
                        || action.label.contains("menubar."),
                    "A raw key reached the button: \(action.label)"
                )
                XCTAssertFalse(
                    action.systemName.isEmpty,
                    "\(action.kind) has no symbol"
                )
            }
        }
    }

    func testOpenNamesTheAccountItWouldOpen() throws {
        let row = makeRow(name: "Consulting", canActivate: true)
        let open = try XCTUnwrap(
            row.actions.first { $0.kind == .open }
        )

        XCTAssertEqual(open.label, row.openLabel)
        XCTAssertTrue(row.openLabel.contains("Consulting"))
    }

    /// The name and windows column is the same affordance as the Open
    /// button, so it must announce the same thing.
    func testTheNameColumnAndTheOpenButtonShareOneLabel() {
        let row = makeRow(canActivate: true)
        let open = row.actions.first { $0.kind == .open }

        XCTAssertEqual(open?.label, row.openLabel)
    }

    func testAPercentageWithoutAUsableResetShowsOnlyThePercentage() {
        let row = makeRow(canActivate: true)

        XCTAssertEqual(row.valueLines, ["Session 42%"])
        XCTAssertFalse(row.valueText.localizedCaseInsensitiveContains("reset"))
    }

    /// The row still has to render. This catches a view that fails to build
    /// at all, which the action list alone would not.
    func testTheRowRendersAtTheWidthTheListGivesIt() {
        let view = HealthStripAccountRowView(
            row: makeRow(canActivate: true),
            onOpen: {},
            onActivate: {},
            onRefresh: {}
        )
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(
            x: 0,
            y: 0,
            width: HealthStripAccountsView.width,
            height: HealthStripAccountsView.rowHeight
        )
        host.layoutSubtreeIfNeeded()

        XCTAssertGreaterThanOrEqual(
            host.fittingSize.height,
            HealthStripAccountsView.rowHeight
        )
        XCTAssertLessThanOrEqual(
            host.fittingSize.width,
            HealthStripAccountsView.width
        )
    }
}
