//
//  HealthStripLocalizationFitTests.swift
//  Claude UsageTests
//
//  Created by Claude Code on 2026-09-08.
//

import AppKit
import XCTest
@testable import Claude_Usage

/// Measures the health strip's accounts list in every shipped locale.
///
/// Measured, not counted, for the reason `PopoverHeaderLocalizationFitTests`
/// records: an earlier pass on this popover predicted two truncations by
/// counting characters and six of the nine locales truncated. These are real
/// Core Text measurements of the real strings at the real font sizes, against
/// the width the row actually gets — which is the 272pt content width minus
/// the three action buttons and their spacing.
final class HealthStripLocalizationFitTests: XCTestCase {

    private static let locales = [
        "de", "en", "es", "fr", "it", "ja", "ko", "pt", "zh-Hans"
    ]

    /// What the name and numbers columns are left with once the three icon
    /// buttons are subtracted.
    private static var rowTextWidth: CGFloat {
        HealthStripAccountsView.rowTextWidth
    }

    /// The footer sits inside the popover's insets and shares one line.
    private static let footerWidth =
        PopoverDesign.width - 2 * PopoverDesign.outerInset
    private static let footerSpacing: CGFloat = 12

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

    /// `PopoverDesign.valueFont` is SF Rounded, which is not the same width
    /// as SF Text at the same size.
    private func roundedWidth(
        _ text: String,
        size: CGFloat,
        weight: NSFont.Weight
    ) -> CGFloat {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        let font: NSFont = {
            guard let descriptor = base.fontDescriptor.withDesign(.rounded)
            else {
                return base
            }
            return NSFont(descriptor: descriptor, size: size) ?? base
        }()
        return (text as NSString).size(
            withAttributes: [.font: font]
        ).width
    }

    // MARK: - The numbers line

    /// "Session 100% · Week 100%" — 100 is the widest figure either window
    /// can render in either polarity, since a remaining-mode account at 0%
    /// used shows 100% too.
    func testTheWindowsLineFitsBesideTheThreeActionButtons() throws {
        for locale in Self.locales {
            let session = try string("appearance.metric.name.session", locale)
            let week = try string("appearance.metric.name.week", locale)
            let line = "\(session) 100% · \(week) 100%"
            let measured = roundedWidth(line, size: 13, weight: .semibold)

            XCTAssertLessThanOrEqual(
                measured,
                Self.rowTextWidth,
                "\(locale) clips the windows line: \(line) needs "
                    + "\(measured)pt of \(Self.rowTextWidth)pt"
            )
        }
    }

    // MARK: - The name line

    /// The name shares its line with a pace dot, an attention glyph and the
    /// Active badge. The name itself is user data and truncates by design,
    /// but everything beside it is localized and must not squeeze the name
    /// out of existence: at least half the line has to be left for it.
    func testTheActiveBadgeLeavesRoomForAnAccountName() throws {
        let dotWidth: CGFloat = 7
        let glyphWidth: CGFloat = 7
        let spacing: CGFloat = 5 * 3

        for locale in Self.locales {
            let badge = try string(
                "menubar.healthstrip.row.active_badge",
                locale
            )
            let decorations = width(badge, size: 11, weight: .medium)
                + dotWidth
                + glyphWidth
                + spacing

            XCTAssertLessThanOrEqual(
                decorations,
                Self.rowTextWidth / 2,
                "\(locale)'s row decorations take \(decorations)pt of "
                    + "\(Self.rowTextWidth)pt, leaving too little for the "
                    + "account name"
            )
        }
    }

    // MARK: - Header and footer

    func testTheHeaderFitsOnOneLine() throws {
        for locale in Self.locales {
            let header = try string("menubar.healthstrip.header", locale)
            // The header is uppercased with 0.6pt of tracking per character.
            let measured = width(
                header.uppercased(),
                size: 11,
                weight: .semibold
            ) + CGFloat(header.count) * 0.6

            XCTAssertLessThanOrEqual(
                measured,
                Self.footerWidth,
                "\(locale) clips the list header"
            )
        }
    }

    func testTheThreeFooterActionsShareOneLine() throws {
        for locale in Self.locales {
            let refreshAll = try string(
                "menubar.healthstrip.footer.refresh_all",
                locale
            )
            let manage = try string("menu.provider.manage_profiles", locale)
            let quit = try string("common.quit", locale)
            let measured = [refreshAll, manage, quit]
                .map { width($0, size: 11, weight: .medium) }
                .reduce(0, +)
                + Self.footerSpacing * 2

            XCTAssertLessThanOrEqual(
                measured,
                Self.footerWidth,
                "\(locale) cannot fit Refresh All, Manage Profiles and Quit "
                    + "on one line: \(measured)pt of \(Self.footerWidth)pt"
            )
        }
    }

    // MARK: - Settings

    /// The layout picker is segmented, so both options share the card's
    /// width and neither may be truncated.
    func testBothLayoutOptionsFitTheSegmentedPicker() throws {
        // The settings window is 720pt wide. 320pt of that is allowed,
        // generously, for the sidebar, the window insets and the card's own
        // padding; what is left is shared by the picker's two segments.
        // Over-stating the chrome is the safe direction: it would fail a
        // label that in fact fits, never pass one that clips.
        let segmentWidth =
            (Constants.WindowSizes.settingsWindow.width - 320) / 2

        for locale in Self.locales {
            for key in [
                "multiprofile.layout.per_profile",
                "multiprofile.layout.health_strip"
            ] {
                let option = try string(key, locale)
                let measured = width(option, size: 13) + 16

                XCTAssertLessThanOrEqual(
                    measured,
                    segmentWidth,
                    "\(locale) clips \(key): \(option) needs \(measured)pt "
                        + "of \(segmentWidth)pt"
                )
            }
        }
    }

    /// Every new key exists and says something in every locale.
    func testEveryNewKeyIsTranslatedEverywhere() throws {
        let keys = [
            "multiprofile.layout.title",
            "multiprofile.layout.per_profile",
            "multiprofile.layout.health_strip",
            "multiprofile.layout.description",
            "multiprofile.layout.health_strip_manager_hint",
            "multiprofile.layout.icon_style_hint",
            "multiprofile.layout.time_marker_hint",
            "multiprofile.healthstrip.numbers_title",
            "multiprofile.healthstrip.numbers_never",
            "multiprofile.healthstrip.numbers_suffix",
            "multiprofile.healthstrip.numbers_hint",
            "menubar.healthstrip.accessibility_label",
            "menubar.healthstrip.header",
            "menubar.healthstrip.footer.refresh_all",
            "menubar.healthstrip.row.active_badge"
        ]
        for locale in Self.locales {
            for key in keys {
                let value = try string(key, locale)
                XCTAssertFalse(
                    value.trimmingCharacters(in: .whitespaces).isEmpty,
                    "\(locale) has an empty value for \(key)"
                )
            }
        }
    }

    /// The strip's accessibility label is built by `String(format:)`, so a
    /// locale that lost its `%@` would announce a count-free sentence.
    func testTheAccessibilityLabelKeepsItsPlaceholder() throws {
        for locale in Self.locales {
            let value = try string(
                "menubar.healthstrip.accessibility_label",
                locale
            )
            XCTAssertTrue(
                value.contains("%@"),
                "\(locale) dropped the count placeholder: \(value)"
            )
        }
    }
}
