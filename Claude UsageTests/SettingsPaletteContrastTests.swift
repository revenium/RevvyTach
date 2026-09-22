//
//  SettingsPaletteContrastTests.swift
//  Claude UsageTests
//
//  Created by Claude Code on 2026-09-21.
//

import AppKit
import SwiftUI
import XCTest
@testable import Claude_Usage

/// Proves every text/fill and control-boundary pairing the Settings palette
/// promises, under both appearances and with Increase Contrast on and off.
///
/// Thresholds are WCAG 2.2 AA: 4.5:1 for text (1.4.3) and 3:1 for a
/// control's visual boundary (1.4.11). The numbers printed here are the
/// ones the PR's visual proof is checked against.
@MainActor
final class SettingsPaletteContrastTests: XCTestCase {
    private struct Mode: CustomStringConvertible {
        let name: String
        let appearance: NSAppearance
        let increaseContrast: Bool

        var description: String {
            "\(name)\(increaseContrast ? " + increase contrast" : "")"
        }
    }

    private static let modes: [Mode] = [
        NSAppearance(named: .darkAqua)!,
        NSAppearance(named: .aqua)!,
    ].flatMap { appearance in
        [false, true].map { contrast in
            Mode(
                name: appearance.name == .darkAqua ? "dark" : "light",
                appearance: appearance,
                increaseContrast: contrast
            )
        }
    }

    func testLabelsReadOnTheWindowAndOnCards() {
        for mode in Self.modes {
            let window = SettingsSurfaces.windowBackground(in: mode.appearance)
            let card = SettingsSurfaces.card(in: mode.appearance, increaseContrast: mode.increaseContrast)
            let labels = [
                ("label", SettingsSurfaces.resolved(.labelColor, in: mode.appearance)),
                ("secondary", SettingsSurfaces.secondaryLabel(in: mode.appearance, increaseContrast: mode.increaseContrast)),
            ]
            for (name, label) in labels {
                assertText(label, over: window, "\(name) text on window", mode)
                assertText(label, over: card, "\(name) text on card", mode)
            }
        }
    }

    func testCardsAreADistinctSurfaceOnTheWindow() {
        for mode in Self.modes {
            let window = SettingsSurfaces.windowBackground(in: mode.appearance)
            let card = SettingsSurfaces.card(in: mode.appearance, increaseContrast: mode.increaseContrast)
            let ratio = WCAGContrast.ratio(card, window)
            report("card vs window", ratio, mode)
            XCTAssertGreaterThanOrEqual(ratio, 1.2, "card does not read as its own surface (\(mode))")
        }
    }

    func testStatusColorsReadAsTextOnCards() {
        for mode in Self.modes {
            let card = SettingsSurfaces.card(in: mode.appearance, increaseContrast: mode.increaseContrast)
            for tone in SettingsTone.allCases where tone != .accent {
                let hue = tone.resolved(in: mode.appearance, increaseContrast: mode.increaseContrast)
                assertText(hue, over: card, "\(tone) text on card", mode)
            }
            assertText(
                SettingsSurfaces.accentText(in: mode.appearance, increaseContrast: mode.increaseContrast),
                over: card,
                "accent text on card",
                mode
            )
        }
    }

    func testBadgeTextReadsOnEveryToneFill() {
        for mode in Self.modes {
            let card = SettingsSurfaces.card(in: mode.appearance, increaseContrast: mode.increaseContrast)
            for tone in SettingsTone.allCases {
                let fill = WCAGContrast.composite(
                    tone.resolved(in: mode.appearance, increaseContrast: mode.increaseContrast),
                    over: card
                )
                let text = tone.textOn(in: mode.appearance, increaseContrast: mode.increaseContrast)
                assertText(text, over: fill, "badge text on \(tone) pill", mode)
            }
        }
    }

    func testStatusBannerTextAndIconRead() {
        for mode in Self.modes {
            let card = SettingsSurfaces.card(in: mode.appearance, increaseContrast: mode.increaseContrast)
            let label = SettingsSurfaces.resolved(.labelColor, in: mode.appearance)
            for tone in [SettingsTone.success, .error, .warning, .info, .secondary] {
                let hue = tone.resolved(in: mode.appearance, increaseContrast: mode.increaseContrast)
                let bannerFill = WCAGContrast.composite(
                    hue.withAlphaComponent(SettingsStatusBanner<Text>.fillOpacity),
                    over: card
                )
                assertText(label, over: bannerFill, "banner text on \(tone) banner", mode)
                let iconRatio = WCAGContrast.ratio(
                    WCAGContrast.composite(hue, over: bannerFill),
                    bannerFill
                )
                report("\(tone) banner icon vs fill", iconRatio, mode)
                XCTAssertGreaterThanOrEqual(
                    iconRatio,
                    WCAGContrast.boundaryMinimum,
                    "\(tone) banner icon is not distinguishable (\(mode))"
                )
            }
        }
    }

    func testButtonsHaveReadableTextAndAVisibleBoundary() {
        for mode in Self.modes {
            let appearance = mode.appearance
            let contrast = mode.increaseContrast
            let card = SettingsSurfaces.card(in: appearance, increaseContrast: contrast)

            let standardFill = SettingsSurfaces.buttonFill(in: appearance, increaseContrast: contrast)
            assertText(
                SettingsSurfaces.resolved(.labelColor, in: appearance),
                over: standardFill,
                "standard button text",
                mode
            )
            assertBoundary(
                fill: standardFill,
                border: SettingsSurfaces.buttonBorder(in: appearance, increaseContrast: contrast),
                against: card,
                "standard button",
                mode
            )

            let accentFill = SettingsTone.accent.resolved(in: appearance, increaseContrast: contrast)
            assertText(
                SettingsTone.accent.textOn(in: appearance, increaseContrast: contrast),
                over: accentFill,
                "accent button text",
                mode
            )
            assertBoundary(
                fill: accentFill,
                border: SettingsSurfaces.accentButtonBorder(in: appearance, increaseContrast: contrast),
                against: card,
                "accent button",
                mode
            )

            let destructiveFill = SettingsSurfaces.destructiveFill(in: appearance, increaseContrast: contrast)
            assertText(.white, over: destructiveFill, "destructive button text", mode)
            assertBoundary(
                fill: destructiveFill,
                border: SettingsSurfaces.destructiveButtonBorder(in: appearance, increaseContrast: contrast),
                against: card,
                "destructive button",
                mode
            )
        }
    }

    func testIncreaseContrastStrengthensEveryBoundary() {
        for appearance in [NSAppearance(named: .darkAqua)!, NSAppearance(named: .aqua)!] {
            let normalCard = SettingsSurfaces.card(in: appearance, increaseContrast: false)
            let strongCard = SettingsSurfaces.card(in: appearance, increaseContrast: true)
            let normalBorder = WCAGContrast.ratio(
                SettingsSurfaces.border(in: appearance, increaseContrast: false), normalCard
            )
            let strongBorder = WCAGContrast.ratio(
                SettingsSurfaces.border(in: appearance, increaseContrast: true), strongCard
            )
            XCTAssertGreaterThan(strongBorder, normalBorder, "\(appearance.name.rawValue): card hairline did not strengthen")
            XCTAssertGreaterThanOrEqual(
                strongBorder,
                WCAGContrast.boundaryMinimum,
                "\(appearance.name.rawValue): card hairline under Increase Contrast is still faint"
            )
        }
    }

    func testSidebarPaintsOpaqueUnderReduceTransparency() {
        let translucent = SidebarBackground.makeView(reduceTransparency: false)
        XCTAssertEqual(SidebarBackground.opaqueFallback(in: translucent)?.isHidden, true)
        XCTAssertTrue(translucent.subviews.contains { $0 is NSVisualEffectView })

        let opaque = SidebarBackground.makeView(reduceTransparency: true)
        let fallback = try? XCTUnwrap(SidebarBackground.opaqueFallback(in: opaque))
        XCTAssertEqual(fallback?.isHidden, false)
        XCTAssertEqual(fallback?.isOpaque, true)

        SidebarBackground.apply(reduceTransparency: false, to: opaque)
        XCTAssertEqual(fallback?.isHidden, true)
    }

    func testSidebarMaterialIsTheSystemSidebarWithNoTint() throws {
        let view = SidebarBackground.makeView(reduceTransparency: false)
        let effect = try XCTUnwrap(view.subviews.compactMap { $0 as? NSVisualEffectView }.first)
        XCTAssertEqual(effect.material, .sidebar)
        XCTAssertEqual(effect.blendingMode, .behindWindow)
        XCTAssertEqual(effect.state, .followsWindowActiveState)
        XCTAssertEqual(view.subviews.count, 2, "a tint layer crept back in")
    }

    /// Only the false cases are assertable here: a high-contrast appearance
    /// cannot be constructed while the live system setting is off (AppKit
    /// only ever hands out an `accessibilityHighContrast*`-named
    /// appearance as its own substitution when the setting is genuinely
    /// on), so there is no way to build the true case without flipping the
    /// machine's real accessibility setting. The true case is covered by
    /// `testIncreaseContrastStrengthensEveryBoundary` and every
    /// `increaseContrast: true` row in `modes`, which call the palette
    /// functions with an explicit `Bool` rather than through this
    /// appearance-derived entry point.
    func testIncreaseContrastOfIsFalseForPlainAppearances() {
        XCTAssertFalse(SettingsSurfaces.increaseContrast(of: NSAppearance(named: .aqua)!))
        XCTAssertFalse(SettingsSurfaces.increaseContrast(of: NSAppearance(named: .darkAqua)!))
    }

    // MARK: - Helpers

    private func assertText(_ text: NSColor, over fill: NSColor, _ what: String, _ mode: Mode,
                            file: StaticString = #filePath, line: UInt = #line) {
        let composited = WCAGContrast.composite(text, over: fill)
        let ratio = WCAGContrast.ratio(composited, fill)
        report(what, ratio, mode)
        XCTAssertGreaterThanOrEqual(
            ratio, WCAGContrast.textMinimum,
            "\(what) is \(format(ratio)) in \(mode); WCAG AA needs 4.5:1",
            file: file, line: line
        )
    }

    private func assertBoundary(fill: NSColor, border: NSColor, against surface: NSColor,
                                _ what: String, _ mode: Mode,
                                file: StaticString = #filePath, line: UInt = #line) {
        let fillRatio = WCAGContrast.ratio(fill, surface)
        let borderRatio = WCAGContrast.ratio(border, surface)
        let ratio = max(fillRatio, borderRatio)
        report("\(what) boundary vs card", ratio, mode)
        XCTAssertGreaterThanOrEqual(
            ratio, WCAGContrast.boundaryMinimum,
            "\(what) has no visible boundary in \(mode): fill \(format(fillRatio)), border \(format(borderRatio))",
            file: file, line: line
        )
    }

    private func report(_ what: String, _ ratio: CGFloat, _ mode: Mode) {
        print("CONTRAST\t\(mode)\t\(what)\t\(format(ratio))")
    }

    private func format(_ ratio: CGFloat) -> String {
        String(format: "%.2f:1", ratio)
    }
}
