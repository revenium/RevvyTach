//
//  OrganizationPickerFootnoteFitTests.swift
//  Claude UsageTests
//
//  Created by Claude Code on 2026-09-03.
//

import AppKit
import XCTest
@testable import Claude_Usage

/// Measures the organization picker's "N API-only organizations hidden"
/// footnote in every shipped locale.
///
/// Measured, not counted. An earlier pass on this app's popover predicted two
/// truncations by counting characters and six of nine locales truncated — a
/// character is not a width. These are real Core Text measurements of the real
/// strings at the real font size.
///
/// The footnote exists because the sheet it lives in is a fixed 560x650 and
/// the rows below it were already overflowing. A footnote that wraps to a
/// second line spends 13pt of the margin this ticket bought, so the widths are
/// pinned here rather than left to the next person editing a translation.
final class OrganizationPickerFootnoteFitTests: XCTestCase {

    private static let locales = [
        "de", "en", "es", "fr", "it", "ja", "ko", "pt", "zh-Hans"
    ]

    /// `Image(systemName: "eye.slash")` at 10pt, measured through
    /// `NSHostingView.fittingSize`. Deliberately generous: under-stating the
    /// glyph would make this test pass a footnote that wraps.
    private static let glyphWidth: CGFloat = 16

    /// The `HStack(spacing: 6)` between the glyph and the sentence.
    private static let glyphSpacing: CGFloat = 6

    /// Width the sentence gets in the credentials sheet's step 2: the sheet is
    /// 560 wide (`ClaudeAccountView.swift`, where the sheet is presented), less
    /// the body's 32pt of outer padding, less the card's 32pt, less the glyph
    /// and its spacing.
    private static let credentialsSheetBudget: CGFloat =
        560 - 32 - 32 - glyphWidth - glyphSpacing

    /// The same in the setup wizard's organization step: a 580pt window, less
    /// that step's 32pt padding on each side, less the glyph and its spacing.
    private static let setupWizardBudget: CGFloat =
        580 - 64 - glyphWidth - glyphSpacing

    /// The font `APIOnlyHiddenFootnote` draws the sentence at.
    private static let fontSize: CGFloat = 11

    /// Two digits, so the plural is measured at a width a real account could
    /// reach rather than at its narrowest.
    private static let worstCaseCount = 12

    private func resourceBundle(for locale: String) throws -> Bundle {
        let host = Bundle(for: MenuBarManager.self)
        let path = try XCTUnwrap(
            host.path(forResource: locale, ofType: "lproj"),
            "\(locale).lproj is missing from the built bundle"
        )
        return try XCTUnwrap(Bundle(path: path))
    }

    private func string(_ key: String, _ locale: String) throws -> String {
        let value = try resourceBundle(for: locale)
            .localizedString(forKey: key, value: nil, table: nil)
        XCTAssertNotEqual(
            value,
            key,
            "\(locale) has no translation for \(key)"
        )
        return value
    }

    private func width(_ text: String) -> CGFloat {
        (text as NSString).size(
            withAttributes: [
                .font: NSFont.systemFont(
                    ofSize: Self.fontSize,
                    weight: .regular
                )
            ]
        ).width
    }

    func testHiddenApiOnlyFootnoteFitsOneLineInEveryLocale() throws {
        for locale in Self.locales {
            let singular = try string("wizard.api_only_hidden.one", locale)
            let plural = String(
                format: try string("wizard.api_only_hidden.other", locale),
                Self.worstCaseCount
            )

            for sentence in [singular, plural] {
                let measured = width(sentence)
                XCTAssertLessThanOrEqual(
                    measured,
                    Self.credentialsSheetBudget,
                    "\(locale) wraps in the credentials sheet at "
                        + "\(Int(measured))pt of \(Int(Self.credentialsSheetBudget))pt: "
                        + sentence
                )
                XCTAssertLessThanOrEqual(
                    measured,
                    Self.setupWizardBudget,
                    "\(locale) wraps in the setup wizard at "
                        + "\(Int(measured))pt of \(Int(Self.setupWizardBudget))pt: "
                        + sentence
                )
            }
        }
    }

    /// The plural carries `%ld`, so a locale that writes `%d`, `%@` or nothing
    /// at all would either drop the count or crash the format call. The
    /// localization validator catches a signature mismatch against `en`; this
    /// catches the result actually being usable.
    func testHiddenApiOnlyPluralCarriesItsCountInEveryLocale() throws {
        for locale in Self.locales {
            let plural = String(
                format: try string("wizard.api_only_hidden.other", locale),
                Self.worstCaseCount
            )

            XCTAssertTrue(
                plural.contains("\(Self.worstCaseCount)"),
                "\(locale) plural drops the count: \(plural)"
            )
            XCTAssertFalse(
                plural.contains("%"),
                "\(locale) plural leaves a placeholder unsubstituted: \(plural)"
            )

            let singular = try string("wizard.api_only_hidden.one", locale)
            XCTAssertFalse(
                singular.contains("%"),
                "\(locale) singular must bake the 1 into the sentence and take "
                    + "no placeholder: \(singular)"
            )
        }
    }
}
