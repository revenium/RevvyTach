import AppKit

/// WCAG 2.x relative luminance and contrast ratio over sRGB.
///
/// Shared by the Settings palette (to pick black or white text for a fill)
/// and by the contrast tests that guard the palette, so both agree on the
/// arithmetic.
nonisolated enum WCAGContrast {
    /// The minimum ratio for normal-size text (WCAG 1.4.3, level AA).
    static let textMinimum: CGFloat = 4.5

    /// The minimum ratio for a control's visual boundary (WCAG 1.4.11).
    static let boundaryMinimum: CGFloat = 3.0

    static func relativeLuminance(of color: NSColor) -> CGFloat {
        let srgb = sRGB(color)
        return 0.2126 * linearized(srgb.redComponent)
            + 0.7152 * linearized(srgb.greenComponent)
            + 0.0722 * linearized(srgb.blueComponent)
    }

    /// The contrast ratio between two opaque colors. Translucent colors must
    /// be composited over what they sit on first (`composite(_:over:)`);
    /// alpha is ignored here.
    static func ratio(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let la = relativeLuminance(of: a)
        let lb = relativeLuminance(of: b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Source-over compositing of `top` onto an opaque `bottom`, in sRGB.
    static func composite(_ top: NSColor, over bottom: NSColor) -> NSColor {
        let t = sRGB(top)
        let b = sRGB(bottom)
        let alpha = t.alphaComponent
        func blend(_ over: CGFloat, _ under: CGFloat) -> CGFloat {
            over * alpha + under * (1 - alpha)
        }
        return NSColor(
            srgbRed: blend(t.redComponent, b.redComponent),
            green: blend(t.greenComponent, b.greenComponent),
            blue: blend(t.blueComponent, b.blueComponent),
            alpha: 1
        )
    }

    /// Moves `color` toward `target` by `fraction` in sRGB, staying opaque.
    /// (`NSColor.blended(withFraction:of:)` mixes in Generic RGB, which
    /// makes the result hard to reason about in sRGB terms.)
    static func mix(_ color: NSColor, toward target: NSColor, fraction: CGFloat) -> NSColor {
        let a = sRGB(color)
        let b = sRGB(target)
        func lerp(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * fraction }
        return NSColor(
            srgbRed: lerp(a.redComponent, b.redComponent),
            green: lerp(a.greenComponent, b.greenComponent),
            blue: lerp(a.blueComponent, b.blueComponent),
            alpha: 1
        )
    }

    /// Black or white, whichever contrasts more with `fill`.
    static func blackOrWhite(on fill: NSColor) -> NSColor {
        ratio(.black, fill) >= ratio(.white, fill) ? .black : .white
    }

    static func sRGB(_ color: NSColor) -> NSColor {
        color.usingColorSpace(.sRGB) ?? color
    }

    private static func linearized(_ channel: CGFloat) -> CGFloat {
        channel <= 0.03928
            ? channel / 12.92
            : pow((channel + 0.055) / 1.055, 2.4)
    }
}
