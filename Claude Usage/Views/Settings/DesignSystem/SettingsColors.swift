//
//  SettingsColors.swift
//  Claude Usage - Settings Design System
//
//  Created by Claude Code on 2025-12-20.
//

import AppKit
import SwiftUI

/// Semantic color palette for Settings UI — the single source of truth.
///
/// Status colors are system colors, so they follow dark mode and Increase
/// Contrast on their own. Surfaces are opaque colors derived from the system
/// window color at resolve time (`SettingsSurfaces`), with a stronger branch
/// when Increase Contrast is on. `SettingsPaletteContrastTests` proves every
/// text/fill and boundary pairing this file promises.
enum SettingsColors {
    // MARK: - Status Colors

    static let success = SettingsTone.success.color
    static let error = SettingsTone.error.color
    static let warning = SettingsTone.warning.color
    static let info = SettingsTone.info.color
    static let caution = SettingsTone.caution.color
    static let neutral = SettingsTone.neutral.color

    // MARK: - Semantic UI Colors

    /// Primary action color (system accent)
    static let primary = SettingsTone.accent.color

    /// Text that sits on the accent color. Black or white, whichever reads
    /// better on the accent the app is built with.
    static let textOnAccent = SettingsTone.accent.textOn

    /// The accent used AS text or a meaningful icon on a card: pushed toward
    /// ink until it clears 4.5:1 (the brand orange alone is 2.3:1 on the
    /// light card). Fills keep `primary`.
    static let accentText = Color(nsColor: SettingsSurfaces.dynamic(SettingsSurfaces.accentText))

    /// Secondary text. Not the system secondary label, which is only
    /// 3.95:1 on a white window; see `SettingsSurfaces.secondaryLabel`.
    static let secondary = SettingsTone.secondary.color

    static let windowBackground = Color(nsColor: .windowBackgroundColor)
    static let cardBackground = Color(nsColor: SettingsSurfaces.dynamic(SettingsSurfaces.card))
    static let inputBackground = Color(nsColor: SettingsSurfaces.dynamic(SettingsSurfaces.input))

    /// Hairline for cards and inputs — decorative, so it only needs to be
    /// visible, not to clear a contrast bar.
    static let border = Color(nsColor: SettingsSurfaces.dynamic(SettingsSurfaces.border))

    /// Fill for a hovered sidebar or list row.
    static let hoverFill = Color(nsColor: SettingsSurfaces.dynamic(SettingsSurfaces.hoverFill))

    /// Fill and outline for a plain (non-accent) button. The outline is what
    /// makes the button read as a control: it clears 3:1 against the card.
    static let buttonFill = Color(nsColor: SettingsSurfaces.dynamic(SettingsSurfaces.buttonFill))
    static let buttonBorder = Color(nsColor: SettingsSurfaces.dynamic(SettingsSurfaces.buttonBorder))

    /// Outline for an accent-filled button; visible only where the accent
    /// itself does not clear 3:1 against the card.
    static let accentButtonBorder = Color(nsColor: SettingsSurfaces.dynamic(SettingsSurfaces.accentButtonBorder))

    /// Solid fill for a destructive button; white text on it clears 4.5:1.
    static let destructiveFill = Color(nsColor: SettingsSurfaces.dynamic(SettingsSurfaces.destructiveFill))
    static let destructiveButtonBorder = Color(nsColor: SettingsSurfaces.dynamic(SettingsSurfaces.destructiveButtonBorder))
    static let textOnDestructive = Color.white

    // MARK: - Feature-Specific Colors

    /// Icon color for feature highlights
    static let featureIcon = info

    /// Beta badge color
    static let betaBadge = warning

    /// Pro feature badge
    static let proBadge = SettingsTone.pro.color

    // MARK: - Threshold Colors (for usage indicators)

    /// Low usage (0-50%)
    static let usageLow = success

    /// Medium usage (50-75%)
    static let usageMedium = caution

    /// High usage (75-90%)
    static let usageHigh = warning

    /// Critical usage (90%+)
    static let usageCritical = error

    // MARK: - Opacity Variants

    /// Light background overlay (for cards on cards)
    static func lightOverlay(_ color: Color, opacity: Double = 0.1) -> Color {
        return color.opacity(opacity)
    }

    /// Border with opacity
    static func borderColor(_ color: Color, opacity: Double = 0.3) -> Color {
        return color.opacity(opacity)
    }
}

/// A status hue that is legible wherever the Settings window uses it, plus
/// the text color that reads on it when it is used as a solid fill.
///
/// The system hue is the starting point; it is pushed toward white (dark
/// mode) or black (light mode) only as far as needed to clear 4.5:1 against
/// the card, so red stays red and green (already `adaptiveGreen`) does not
/// move at all. Solid fills are used for pills because colored text on a
/// faint tint of the same hue cannot reach 4.5:1 for red in dark mode.
enum SettingsTone: CaseIterable {
    case success
    case error
    case warning
    case info
    case caution
    case neutral
    case pro
    case accent
    case secondary

    var systemHue: NSColor {
        switch self {
        case .success: return .adaptiveGreen
        case .error: return .systemRed
        case .warning: return .systemOrange
        case .info: return .systemBlue
        case .caution: return .systemYellow
        case .neutral: return .systemGray
        case .pro: return .systemPurple
        case .accent: return .controlAccentColor
        case .secondary: return .secondaryLabelColor
        }
    }

    func resolved(in appearance: NSAppearance, increaseContrast: Bool) -> NSColor {
        switch self {
        case .accent:
            // The brand color is a fill, never body text; it is left alone.
            return SettingsSurfaces.resolved(systemHue, in: appearance)
        case .secondary:
            return SettingsSurfaces.secondaryLabel(in: appearance, increaseContrast: increaseContrast)
        default:
            return SettingsSurfaces.legible(systemHue, in: appearance, increaseContrast: increaseContrast)
        }
    }

    func textOn(in appearance: NSAppearance, increaseContrast: Bool) -> NSColor {
        SettingsSurfaces.textOn(
            fill: resolved(in: appearance, increaseContrast: increaseContrast),
            in: appearance,
            increaseContrast: increaseContrast
        )
    }

    var nsColor: NSColor {
        SettingsSurfaces.dynamic { appearance, increaseContrast in
            resolved(in: appearance, increaseContrast: increaseContrast)
        }
    }

    var color: Color { Color(nsColor: nsColor) }

    /// Black or white, chosen per appearance against this tone composited
    /// over the card it sits on.
    var textOn: Color {
        Color(nsColor: SettingsSurfaces.dynamic { appearance, increaseContrast in
            textOn(in: appearance, increaseContrast: increaseContrast)
        })
    }
}

/// Opaque Settings surfaces, derived from the system window color under a
/// given appearance so they track the OS rather than a hard-coded gray.
///
/// Every function is pure in `(appearance, increaseContrast)` so the
/// contrast tests can evaluate the Increase Contrast branch without
/// flipping the machine's accessibility settings.
nonisolated enum SettingsSurfaces {
    /// The appearance names AppKit substitutes when Increase Contrast is
    /// on — never assigned directly to a view, only returned by
    /// `NSAppearance.bestMatch` once the system has already swapped in
    /// the high-contrast variant of whatever appearance was active.
    private static let highContrastNames: [NSAppearance.Name] = [
        .accessibilityHighContrastAqua,
        .accessibilityHighContrastDarkAqua,
        .accessibilityHighContrastVibrantLight,
        .accessibilityHighContrastVibrantDark,
    ]

    /// Wraps a resolver in a dynamic `NSColor`, keyed by appearance rather
    /// than by a view identity that has to be torn down and rebuilt:
    /// toggling Increase Contrast swaps every window's effective
    /// appearance to its `accessibilityHighContrast*` counterpart, and
    /// that appearance change is what AppKit re-resolves dynamic colors
    /// against, so a stale cached value can never outlive it.
    static func dynamic(
        _ resolve: @escaping (NSAppearance, Bool) -> NSColor
    ) -> NSColor {
        NSColor(name: nil) { appearance in
            resolve(appearance, increaseContrast(of: appearance))
        }
    }

    /// True when the appearance AppKit is resolving against is itself one
    /// of the `accessibilityHighContrast*` names, or — belt and braces —
    /// when the live system setting says so even if the name mapping
    /// differs on some macOS release. Either signal alone is enough: the
    /// appearance identity is what forces AppKit to re-resolve at all: the
    /// workspace flag is what guarantees the resolved value is correct
    /// even where the name isn't recognized as high-contrast.
    static func increaseContrast(of appearance: NSAppearance) -> Bool {
        let nameMatchesHighContrast: Bool
        if let best = appearance.bestMatch(from: [.aqua, .darkAqua] + highContrastNames) {
            nameMatchesHighContrast = highContrastNames.contains(best)
        } else {
            nameMatchesHighContrast = false
        }
        return nameMatchesHighContrast || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    static func windowBackground(in appearance: NSAppearance) -> NSColor {
        resolved(.windowBackgroundColor, in: appearance)
    }

    static func card(in appearance: NSAppearance, increaseContrast: Bool) -> NSColor {
        towardInk(windowBackground(in: appearance), by: increaseContrast ? 0.16 : 0.10, in: appearance)
    }

    static func input(in appearance: NSAppearance, increaseContrast: Bool) -> NSColor {
        towardInk(windowBackground(in: appearance), by: increaseContrast ? 0.22 : 0.14, in: appearance)
    }

    static func border(in appearance: NSAppearance, increaseContrast: Bool) -> NSColor {
        towardInk(card(in: appearance, increaseContrast: increaseContrast), by: increaseContrast ? 0.50 : 0.12, in: appearance)
    }

    static func hoverFill(in appearance: NSAppearance, increaseContrast: Bool) -> NSColor {
        resolved(.unemphasizedSelectedContentBackgroundColor, in: appearance)
    }

    /// The system secondary label is black at 50% in light mode, which is
    /// only 3.95:1 on white. Starting alpha is 0.58/0.70, stepped up in 2%
    /// increments — the same search `legible` runs — until it clears 4.5:1
    /// against both the window and the card: `windowBackgroundColor` itself
    /// resolves to a different value across macOS releases, so a value
    /// proven on one OS is not proven on all of them.
    static func secondaryLabel(in appearance: NSAppearance, increaseContrast: Bool) -> NSColor {
        let window = windowBackground(in: appearance)
        let card = card(in: appearance, increaseContrast: increaseContrast)
        func clears(_ candidate: NSColor) -> Bool {
            [window, card].allSatisfy {
                WCAGContrast.ratio(WCAGContrast.composite(candidate, over: $0), $0) >= WCAGContrast.textMinimum
            }
        }
        var alpha: CGFloat = increaseContrast ? 0.70 : 0.58
        var candidate = ink(in: appearance).withAlphaComponent(alpha)
        while !clears(candidate), alpha < 1 {
            alpha += 0.02
            candidate = ink(in: appearance).withAlphaComponent(alpha)
        }
        return candidate
    }

    /// Dark mode lifts the button above the card — `.labelColor` is
    /// already effectively white there, so it is the fill, not the text,
    /// that has to make room for 4.5:1: starting from the intended lift
    /// (10%/14% toward ink, i.e. toward white in dark mode), step it DOWN
    /// in 2% increments until `.labelColor` clears 4.5:1 against it.
    /// `.labelColor` is ~85% alpha, not opaque, so the check composites it
    /// over the candidate first — `WCAGContrast.ratio` ignores alpha, and
    /// comparing the raw (effectively opaque-white) component values
    /// overstates the contrast a viewer actually sees. A
    /// `windowBackgroundColor` that resolves lighter (as it does on some
    /// macOS releases) leaves less room in the lift, not less contrast.
    /// Light mode keeps Apple's white button on a gray card.
    static func buttonFill(in appearance: NSAppearance, increaseContrast: Bool) -> NSColor {
        guard isDark(appearance) else { return windowBackground(in: appearance) }
        let card = card(in: appearance, increaseContrast: increaseContrast)
        let label = resolved(.labelColor, in: appearance)
        func clears(_ candidate: NSColor) -> Bool {
            WCAGContrast.ratio(WCAGContrast.composite(label, over: candidate), candidate) >= WCAGContrast.textMinimum
        }
        var lift: CGFloat = increaseContrast ? 0.14 : 0.10
        var candidate = towardInk(card, by: lift, in: appearance)
        while !clears(candidate), lift > 0 {
            lift -= 0.02
            candidate = towardInk(card, by: lift, in: appearance)
        }
        return candidate
    }

    static func buttonBorder(in appearance: NSAppearance, increaseContrast: Bool) -> NSColor {
        outline(for: buttonFill(in: appearance, increaseContrast: increaseContrast), in: appearance, increaseContrast: increaseContrast)
    }

    static func accentButtonBorder(in appearance: NSAppearance, increaseContrast: Bool) -> NSColor {
        outline(for: resolved(.controlAccentColor, in: appearance), in: appearance, increaseContrast: increaseContrast)
    }

    static func destructiveButtonBorder(in appearance: NSAppearance, increaseContrast: Bool) -> NSColor {
        outline(for: destructiveFill(in: appearance, increaseContrast: increaseContrast), in: appearance, increaseContrast: increaseContrast)
    }

    /// A button's boundary against the card: the fill itself when that
    /// already clears 3:1, otherwise the fill pushed toward ink until it does.
    static func outline(for fill: NSColor, in appearance: NSAppearance, increaseContrast: Bool) -> NSColor {
        let card = card(in: appearance, increaseContrast: increaseContrast)
        if !increaseContrast, WCAGContrast.ratio(fill, card) >= WCAGContrast.boundaryMinimum {
            return fill
        }
        let fraction: CGFloat = isDark(appearance)
            ? (increaseContrast ? 0.60 : 0.35)
            : (increaseContrast ? 0.75 : 0.55)
        return towardInk(fill, by: fraction, in: appearance)
    }

    /// System red darkened enough for white text to clear 4.5:1 — plain
    /// system red only reaches about 3.9:1.
    static func destructiveFill(in appearance: NSAppearance, increaseContrast: Bool) -> NSColor {
        WCAGContrast.mix(resolved(.systemRed, in: appearance), toward: .black, fraction: 0.25)
    }

    /// `hue` pushed toward ink, in 2% steps, until it clears 4.5:1 against
    /// the card — so it can be used as text or an icon anywhere on a card.
    static func legible(_ hue: NSColor, in appearance: NSAppearance, increaseContrast: Bool) -> NSColor {
        let card = card(in: appearance, increaseContrast: increaseContrast)
        var candidate = resolved(hue, in: appearance)
        var fraction: CGFloat = 0
        while WCAGContrast.ratio(candidate, card) < WCAGContrast.textMinimum, fraction < 1 {
            fraction += 0.02
            candidate = towardInk(resolved(hue, in: appearance), by: fraction, in: appearance)
        }
        return candidate
    }

    static func accentText(in appearance: NSAppearance, increaseContrast: Bool) -> NSColor {
        legible(.controlAccentColor, in: appearance, increaseContrast: increaseContrast)
    }

    static func textOn(fill: NSColor, in appearance: NSAppearance, increaseContrast: Bool) -> NSColor {
        let composited = WCAGContrast.composite(
            resolved(fill, in: appearance),
            over: card(in: appearance, increaseContrast: increaseContrast)
        )
        return WCAGContrast.blackOrWhite(on: composited)
    }

    static func resolved(_ color: NSColor, in appearance: NSAppearance) -> NSColor {
        var result = color
        appearance.performAsCurrentDrawingAppearance {
            result = WCAGContrast.sRGB(color)
        }
        return result
    }

    /// White in dark mode, black in light: the direction that adds contrast.
    private static func ink(in appearance: NSAppearance) -> NSColor {
        isDark(appearance) ? .white : .black
    }

    private static func towardInk(_ base: NSColor, by fraction: CGFloat, in appearance: NSAppearance) -> NSColor {
        WCAGContrast.mix(base, toward: ink(in: appearance), fraction: fraction)
    }
}
