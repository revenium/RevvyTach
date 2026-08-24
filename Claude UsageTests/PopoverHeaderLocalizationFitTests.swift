//
//  PopoverHeaderLocalizationFitTests.swift
//  Claude UsageTests
//
//  Created by Claude Code on 2026-08-24.
//

import AppKit
import XCTest
@testable import Claude_Usage

/// Measures the header's new meta rows in every shipped locale.
///
/// Measured, not counted. A previous pass on this popover predicted two
/// truncations by counting characters and six of the nine locales truncated,
/// because a character is not a width — "Nicht unterstütztes Konto" and
/// "アカウント" have nothing to do with each other per glyph. These are real
/// Core Text measurements of the real strings at the real font sizes.
final class PopoverHeaderLocalizationFitTests: XCTestCase {

    /// Width the header's meta rows actually get: the popover width, less the
    /// horizontal insets, less the 40pt indent that lines them up under the
    /// account name rather than the avatar.
    private static let availableWidth =
        PopoverDesign.width - 2 * PopoverDesign.outerInset - 40

    private static let locales = [
        "de", "en", "es", "fr", "it", "ja", "ko", "pt", "zh-Hans"
    ]

    /// The SF Symbol leading the account row, at 9pt. Deliberately generous:
    /// under-stating the glyph would make this test pass a row that clips.
    private static let glyphWidth: CGFloat = 16

    private static let dotWidth: CGFloat = 6
    private static let rowSpacing: CGFloat = 5

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

    /// Every health verdict the account row can carry.
    private static let healthKeys = [
        "popover.normalized.health.healthy",
        "popover.normalized.health.degraded",
        "popover.normalized.health.unavailable",
        "popover.normalized.health.sign_in",
        "popover.normalized.health.unsupported",
        "popover.normalized.health.checking"
    ]

    func testAccountHealthRowFitsInEveryLocale() throws {
        for locale in Self.locales {
            let label = try string(
                "popover.normalized.account_health.label",
                locale
            )
            let fixed = Self.glyphWidth
                + width(label, size: 11, weight: .semibold)
                + width("·", size: 11)
                + Self.rowSpacing * 3

            for key in Self.healthKeys {
                let verdict = try string(key, locale)
                let total = fixed + width(verdict, size: 11)
                XCTAssertLessThanOrEqual(
                    total,
                    Self.availableWidth,
                    "\(locale) truncates \"\(label) · \(verdict)\" — "
                        + "\(Int(total))pt in \(Int(Self.availableWidth))pt"
                )
            }
        }
    }

    /// The service-status row is unchanged by the account row above it, but it
    /// is the string that already truncated once here, so its headroom is
    /// asserted rather than assumed.
    func testServiceStatusRowStillFits() {
        // Not localized: it is Anthropic's own wording, from status.claude.com.
        let longestKnownStatus = "All Systems Operational"
        let total = width("Claude", size: 11, weight: .semibold)
            + width("·", size: 11)
            + Self.dotWidth
            + width(longestKnownStatus, size: 11)
            + Self.rowSpacing * 3
        XCTAssertLessThanOrEqual(total, Self.availableWidth)
    }

    func testFigureAgeLineFitsInEveryLocale() throws {
        for locale in Self.locales {
            for key in [
                "popover.normalized.age.ago",
                "popover.normalized.age.just_now"
            ] {
                let format = try string(key, locale)
                // The longest duration the compact formatter produces.
                let rendered = String(
                    format: format,
                    locale: Locale(identifier: locale),
                    "365d 23h"
                )
                XCTAssertLessThanOrEqual(
                    width(rendered, size: 10),
                    Self.availableWidth,
                    "\(locale) truncates \"\(rendered)\""
                )
            }
        }
    }
}
