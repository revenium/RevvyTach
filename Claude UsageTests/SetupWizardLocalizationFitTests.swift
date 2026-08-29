//
//  SetupWizardLocalizationFitTests.swift
//  Claude UsageTests
//

import AppKit
import XCTest
@testable import Claude_Usage

/// Measures the fixed-width text added by the four-step Claude setup wizard
/// in every shipped locale.
///
/// Descriptions are intentionally absent: those views opt into vertical
/// wrapping. These assertions cover the headings, buttons, row labels, and
/// status pills whose horizontal space is constrained by the 580pt wizard.
final class SetupWizardLocalizationFitTests: XCTestCase {
    private static let locales = [
        "de", "en", "es", "fr", "it", "ja", "ko", "pt", "zh-Hans"
    ]

    private static let wizardWidth: CGFloat = 580
    private static let contentInset: CGFloat = 32
    private static let footerInset: CGFloat = 20
    private static let cardInset: CGFloat = 16
    private static let rowInset: CGFloat = 16
    private static let standardSpacing: CGFloat = 8

    /// `SetupStepHeader`: 580pt wizard, 32pt content insets, a 28pt numbered
    /// circle, and the view's 10pt gap before its 16pt semibold title.
    private static let stepHeadingWidth =
        wizardWidth - 2 * contentInset - 28 - 10

    /// Step-three cards fill the content column and add 16pt internal insets.
    private static let cardContentWidth =
        wizardWidth - 2 * contentInset - 2 * cardInset

    /// Card labels include one SF Symbol plus the default Label spacing. This
    /// deliberately reserves a generous 24pt so the test cannot understate
    /// the icon's cost.
    private static let cardHeadingWidth = cardContentWidth - 24

    /// Wizard footers use 20pt horizontal padding.
    private static let footerWidth = wizardWidth - 2 * footerInset

    /// `ClaudeSignInSummaryView` fills the 516pt content column and each row
    /// has 16pt horizontal padding.
    private static let summaryRowWidth =
        wizardWidth - 2 * contentInset - 2 * rowInset

    /// Conservative allowance for the horizontal chrome SwiftUI adds to a
    /// bordered button at the default control size.
    private static let buttonChrome: CGFloat = 24

    /// The command card needs most of its row for the one-line command. Keep
    /// each trailing/standalone card button within this realistic allocation.
    private static let cardButtonWidth: CGFloat = 160

    private func resourceBundle(for locale: String) throws -> Bundle {
        let host = Bundle(for: MenuBarManager.self)
        let path = try XCTUnwrap(
            host.path(forResource: locale, ofType: "lproj"),
            "\(locale).lproj is missing from the built bundle"
        )
        return try XCTUnwrap(Bundle(path: path))
    }

    private func string(
        _ key: String,
        _ locale: String
    ) throws -> String {
        let value = try resourceBundle(for: locale)
            .localizedString(forKey: key, value: nil, table: nil)
        XCTAssertNotEqual(
            value,
            key,
            "\(locale) has no translation for \(key)"
        )
        return value
    }

    private func width(
        _ text: String,
        size: CGFloat,
        weight: NSFont.Weight = .regular
    ) -> CGFloat {
        (text as NSString).size(
            withAttributes: [
                .font: NSFont.systemFont(ofSize: size, weight: weight)
            ]
        ).width
    }

    func testStepAndCardHeadingsFitOnOneLineInEveryLocale() throws {
        for locale in Self.locales {
            for key in [
                "wizard.browser_sign_in.title",
                "wizard.organization.title",
                "wizard.link_terminal.title",
                "wizard.review.title"
            ] {
                let heading = try string(key, locale)
                let measured = width(heading, size: 16, weight: .semibold)
                XCTAssertLessThanOrEqual(
                    measured,
                    Self.stepHeadingWidth,
                    "\(locale) truncates heading \"\(heading)\" — "
                        + "\(Int(measured))pt in "
                        + "\(Int(Self.stepHeadingWidth))pt"
                )
            }

            for key in [
                "wizard.link_terminal.detected_title",
                "wizard.link_terminal.not_found_title"
            ] {
                let heading = try string(key, locale)
                let measured = width(heading, size: 14, weight: .semibold)
                XCTAssertLessThanOrEqual(
                    measured,
                    Self.cardHeadingWidth,
                    "\(locale) truncates card heading \"\(heading)\" — "
                        + "\(Int(measured))pt in "
                        + "\(Int(Self.cardHeadingWidth))pt"
                )
            }
        }
    }

    func testDetectedFooterButtonsFitTogetherInEveryLocale() throws {
        for locale in Self.locales {
            // No Back: the terminal sign-in is step 1 now, so there is
            // nothing before it to go back to.
            let keys = [
                "wizard.link_terminal.continue_without",
                "wizard.link_terminal.link_continue"
            ]
            let labels = try keys.map { try string($0, locale) }
            let measured = labels.reduce(CGFloat.zero) {
                $0 + width($1, size: 13) + Self.buttonChrome
            } + Self.standardSpacing * CGFloat(labels.count - 1)

            XCTAssertLessThanOrEqual(
                measured,
                Self.footerWidth,
                "\(locale) truncates the detected-state footer "
                    + "\"\(labels.joined(separator: " · "))\" — "
                    + "\(Int(measured))pt in \(Int(Self.footerWidth))pt"
            )
        }
    }

    /// The browser step's footer, which gained the skip button when that step
    /// became optional. Four buttons on one row is the tightest footer in the
    /// wizard, and the skip label is the longest of the four in every locale.
    func testBrowserStepFooterFitsWithTheSkipButtonInEveryLocale() throws {
        for locale in Self.locales {
            let keys = [
                "common.back",
                "common.cancel",
                "wizard.link_terminal.skip_browser"
            ]
            let labels = try keys.map { try string($0, locale) }
            let measured = labels.reduce(CGFloat.zero) {
                $0 + width($1, size: 13) + Self.buttonChrome
            } + Self.standardSpacing * CGFloat(labels.count - 1)

            XCTAssertLessThanOrEqual(
                measured,
                Self.footerWidth,
                "\(locale) truncates the browser-step footer "
                    + "\"\(labels.joined(separator: " · "))\" — "
                    + "\(Int(measured))pt in \(Int(Self.footerWidth))pt"
            )
        }
    }

    /// The step order itself, which is a product decision and had no
    /// coverage at all. Claude Code is step 1 because it is the sign-in that
    /// produces every usage number; the browser sign-in follows it and is
    /// skippable. `Comparable` and the four step circles both read the raw
    /// values, so getting these wrong reorders the whole wizard silently.
    func testClaudeCodeIsTheFirstWizardStep() {
        XCTAssertEqual(SetupWizardStep.linkClaudeCode.rawValue, 1)
        XCTAssertEqual(SetupWizardStep.enterKey.rawValue, 2)
        XCTAssertEqual(SetupWizardStep.selectOrg.rawValue, 3)
        XCTAssertEqual(SetupWizardStep.confirm.rawValue, 4)
        XCTAssertTrue(SetupWizardStep.linkClaudeCode < SetupWizardStep.enterKey)
        XCTAssertTrue(SetupWizardStep.selectOrg < SetupWizardStep.confirm)
    }

    func testCardAndReviewButtonsFitInEveryLocale() throws {
        for locale in Self.locales {
            let copyCommand = try string(
                "wizard.link_terminal.copy_command",
                locale
            )
            let copyWidth = width(copyCommand, size: 11) + 20
            XCTAssertLessThanOrEqual(
                copyWidth,
                Self.cardButtonWidth,
                "\(locale) truncates card button \"\(copyCommand)\" — "
                    + "\(Int(copyWidth))pt in "
                    + "\(Int(Self.cardButtonWidth))pt"
            )

            let checkAgain = try string(
                "wizard.link_terminal.check_again",
                locale
            )
            let checkWidth = width(checkAgain, size: 13) + Self.buttonChrome
            XCTAssertLessThanOrEqual(
                checkWidth,
                Self.cardButtonWidth,
                "\(locale) truncates card button \"\(checkAgain)\" — "
                    + "\(Int(checkWidth))pt in "
                    + "\(Int(Self.cardButtonWidth))pt"
            )

            let startTracking = try string("wizard.start_tracking", locale)
            let startWidth = width(startTracking, size: 13)
            XCTAssertLessThanOrEqual(
                startWidth,
                100,
                "\(locale) truncates review button \"\(startTracking)\" — "
                    + "\(Int(startWidth))pt in its 100pt label frame"
            )
        }
    }

    func testSummaryRowLabelsAndStatusPillsFitInEveryLocale() throws {
        let rowKeys = [
            "claude_account.summary.browser.title",
            "claude_account.summary.terminal.title"
        ]
        let statusKeys = [
            "claude_account.summary.status.working",
            "claude_account.summary.status.working_not_renewable",
            "claude_account.summary.status.needs_attention",
            "claude_account.summary.status.not_linked",
            "claude_account.summary.status.missing"
        ]

        for locale in Self.locales {
            for rowKey in rowKeys {
                let rowLabel = try string(rowKey, locale)
                for statusKey in statusKeys {
                    let status = try string(statusKey, locale)
                    // The pill adds 7pt on each side of its 9pt-bold label.
                    let measured = width(
                        rowLabel,
                        size: 13,
                        weight: .medium
                    ) + Self.standardSpacing
                        + width(status, size: 9, weight: .bold) + 14

                    XCTAssertLessThanOrEqual(
                        measured,
                        Self.summaryRowWidth,
                        "\(locale) truncates summary row "
                            + "\"\(rowLabel) · \(status)\" — "
                            + "\(Int(measured))pt in "
                            + "\(Int(Self.summaryRowWidth))pt"
                    )
                }
            }
        }
    }
}
