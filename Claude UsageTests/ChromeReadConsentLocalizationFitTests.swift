//
//  ChromeReadConsentLocalizationFitTests.swift
//  Claude UsageTests
//
//  Fit is measured by rendering at the real fonts and the real pt widths,
//  never by counting characters — six of nine locales once truncated where a
//  character count predicted two would.
//
//  The consent sheet is the one place in this app where a clipped sentence
//  would be a security problem rather than a cosmetic one, so the body's
//  wrapped height is asserted too. The body scrolls rather than clips, so
//  this assertion's job is to catch a translation that has drifted into an
//  overrun before a user ever has to scroll a consent notice.
//

import AppKit
import XCTest
@testable import Claude_Usage

// `@MainActor` because the sheet's layout constants live on a SwiftUI
// view, which the app target's default actor isolation makes
// main-actor-isolated; the unit-test target sets no such default.
@MainActor
final class ChromeReadConsentLocalizationFitTests: XCTestCase {
    private static let locales = [
        "de", "en", "es", "fr", "it", "ja", "ko", "pt", "zh-Hans"
    ]

    /// The wizard card the Read from Chrome button sits in: a 580pt wizard,
    /// 32pt content insets, and the card's own 12pt padding.
    private static let cardContentWidth: CGFloat = 580 - 2 * 32 - 2 * 12

    /// Conservative allowance for a bordered button's horizontal chrome plus
    /// its leading SF Symbol.
    private static let buttonChrome: CGFloat = 24
    private static let iconAllowance: CGFloat = 18

    /// Three wrapped lines of 12pt system text. Every locale's card sentence
    /// currently takes two, so this leaves one line of headroom and still
    /// fails a translation that has grown into a wall of text in a card the
    /// user is meant to skim.
    private static let cardSentenceHeightBudget: CGFloat = 45

    private static let newKeys = [
        "chrome_assisted.read_button",
        "chrome_assisted.reading",
        "chrome_assisted.read_consent_title",
        "chrome_assisted.read_consent_body",
        "chrome_assisted.read_consent_continue",
        "chrome_assisted.read_scope_note",
        "chrome_assisted.read_failed_generic",
        "chrome_assisted.read_failed_denied",
        "chrome_assisted.read_failed_locked",
        "chrome_assisted.read_failed_missing",
        "chrome_assisted.read_failed_version",
        "chrome_assisted.launch_superseded",
    ]

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
            value, key, "\(locale) has no translation for \(key)"
        )
        XCTAssertFalse(
            value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "\(locale) has an empty value for \(key)"
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

    private func height(
        _ text: String,
        size: CGFloat,
        wrapWidth: CGFloat
    ) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        return (text as NSString).boundingRect(
            with: NSSize(
                width: wrapWidth, height: .greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [
                .font: NSFont.systemFont(ofSize: size),
                .paragraphStyle: paragraph,
            ]
        ).height
    }

    func testConsentTitleFitsTheSheetTextColumnInEveryLocale() throws {
        for locale in Self.locales {
            let title = try string(
                "chrome_assisted.read_consent_title", locale
            )
            let measured = width(title, size: 16, weight: .semibold)
            XCTAssertLessThanOrEqual(
                measured,
                ChromeReadConsentSheet.textColumnWidth,
                "\(locale) truncates the consent title \"\(title)\" — "
                    + "\(Int(measured))pt in "
                    + "\(Int(ChromeReadConsentSheet.textColumnWidth))pt"
            )
        }
    }

    func testConsentBodyStaysInsideTheSheetInEveryLocale() throws {
        for locale in Self.locales {
            let body = try string("chrome_assisted.read_consent_body", locale)
            let measured = height(
                body,
                size: 12,
                wrapWidth: ChromeReadConsentSheet.textColumnWidth
            )
            XCTAssertLessThanOrEqual(
                measured,
                ChromeReadConsentSheet.bodyHeightBudget,
                "\(locale)'s consent body needs \(Int(measured))pt in a "
                    + "\(Int(ChromeReadConsentSheet.bodyHeightBudget))pt "
                    + "budget — shorten that locale without dropping any "
                    + "of the disclosures"
            )
        }
    }

    func testConsentFooterButtonsFitOnOneRowInEveryLocale() throws {
        for locale in Self.locales {
            let cancel = try string("common.cancel", locale)
            let proceed = try string(
                "chrome_assisted.read_consent_continue", locale
            )
            let measured = width(cancel, size: 13)
                + width(proceed, size: 13)
                + 2 * Self.buttonChrome
                + 8
            XCTAssertLessThanOrEqual(
                measured,
                ChromeReadConsentSheet.textColumnWidth,
                "\(locale) overflows the consent footer row — "
                    + "\(Int(measured))pt in "
                    + "\(Int(ChromeReadConsentSheet.textColumnWidth))pt"
            )
        }
    }

    func testReadButtonAndItsBusyLabelFitTheWizardCardInEveryLocale() throws {
        for key in ["chrome_assisted.read_button", "chrome_assisted.reading"] {
            for locale in Self.locales {
                let label = try string(key, locale)
                let measured = width(label, size: 12)
                    + Self.iconAllowance
                    + Self.buttonChrome
                XCTAssertLessThanOrEqual(
                    measured,
                    Self.cardContentWidth,
                    "\(locale) truncates \(key) \"\(label)\" — "
                        + "\(Int(measured))pt in "
                        + "\(Int(Self.cardContentWidth))pt"
                )
            }
        }
    }

    /// The card's opening sentence used to promise only a manual paste, which
    /// stopped being true the moment Read from Chrome shipped. Naming the
    /// button is the assertion, because a translator who reworks this sentence
    /// without it has quietly hidden the feature again.
    func testCardDescriptionNamesTheReadButtonInEveryLocale() throws {
        for locale in Self.locales {
            let description = try string(
                "chrome_assisted.description", locale
            )
            let readButton = try string(
                "chrome_assisted.read_button", locale
            )
            XCTAssertTrue(
                description.contains(readButton),
                "\(locale)'s card description \"\(description)\" never "
                    + "mentions \"\(readButton)\", so the panel still reads "
                    + "as if pasting a key by hand were the only route"
            )
        }
    }

    func testCardSentencesStayShortEnoughToSkimInEveryLocale() throws {
        for key in [
            "chrome_assisted.description",
            "chrome_assisted.launch_superseded",
        ] {
            for locale in Self.locales {
                let sentence = try string(key, locale)
                let measured = height(
                    sentence, size: 12, wrapWidth: Self.cardContentWidth
                )
                XCTAssertLessThanOrEqual(
                    measured,
                    Self.cardSentenceHeightBudget,
                    "\(locale)'s \(key) needs \(Int(measured))pt in a "
                        + "\(Int(Self.cardSentenceHeightBudget))pt budget"
                )
            }
        }
    }

    func testEveryNewKeyIsTranslatedInEveryLocale() throws {
        for key in Self.newKeys {
            for locale in Self.locales {
                _ = try string(key, locale)
            }
        }
        // The revised promise is a changed value rather than a new key, and
        // it is the one sentence in the card that would otherwise still say
        // a session key is never read.
        for locale in Self.locales {
            _ = try string("chrome_assisted.no_extraction", locale)
        }
    }

    func testTheScopeNoteKeepsItsProfilePlaceholderInEveryLocale() throws {
        for locale in Self.locales {
            let note = try string("chrome_assisted.read_scope_note", locale)
            XCTAssertTrue(
                note.contains("%@"),
                "\(locale) dropped the profile placeholder from the scope note"
            )
            let rendered = String(format: note, "Work — Profile 3")
            XCTAssertTrue(rendered.contains("Work — Profile 3"))
            XCTAssertLessThanOrEqual(
                height(
                    rendered,
                    size: 11,
                    wrapWidth: ChromeReadConsentSheet.textColumnWidth
                ),
                39,
                "\(locale)'s scope note needs more than the three lines the "
                    + "sheet's fixed frame reserves for it"
            )
        }
    }
}
