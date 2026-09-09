//
//  HealthStripLayout.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-09-08.
//

import CoreGraphics
import Foundation

/// One account's slot in the health strip, in 1x menu bar points.
///
/// `width` always includes the trailing gap, so a cell owns every point from
/// its own bar up to (but not including) the next account's bar. That is what
/// makes click routing forgiving: a click a couple of points to the right of
/// a bar still belongs to that account rather than falling into a dead zone.
nonisolated struct HealthStripCell: Equatable {
    let profileID: UUID
    /// Left edge of this account's 4pt bar.
    let minX: CGFloat
    /// Bar, plus numbers if any, plus the trailing gap.
    let width: CGFloat
    /// Width of the composited numbers image, or nil when this account is
    /// below the "show numbers" threshold.
    let numbersWidth: CGFloat?
}

/// Pure geometry for the health strip. No AppKit, no drawing, no state — so
/// the pitch, the total width and the click hit-test can all be tested
/// without a status bar, the way `MenuBarSpaceCalculator` is.
nonisolated enum HealthStripLayout {
    /// Width of one account's usage bar.
    static let barWidth: CGFloat = 4
    /// Space between one account's cell content and the next account's bar.
    static let cellGap: CGFloat = 3
    /// Bottom of the bar within the 22pt canvas.
    static let barBottom: CGFloat = 4
    /// Height of the bar's track.
    static let barHeight: CGFloat = 12
    /// Canvas height when no account is showing numbers.
    static let baseCanvasHeight: CGFloat = 22
    /// Blank margin at each end of the strip.
    static let edgePadding: CGFloat = 1
    /// Space between a bar and the numbers drawn beside it.
    static let numbersGap: CGFloat = 2
    /// Bottom edge — the origin, not the centre — of the 4pt attention
    /// marker, which is how `applyAttentionMarker` builds its own rect. The
    /// marker therefore spans 17…21 and its 5.5pt footprint, the marker plus
    /// a ±0.75 halo, runs 16.25…21.75: inside the 22pt canvas, and clear of
    /// the bar top at 16.
    static let markerY: CGFloat = 17

    /// Horizontal offset of the numbers image from the cell's left edge.
    static var numbersOffsetX: CGFloat { barWidth + numbersGap }

    /// How much of the 12pt track is filled for a displayed percentage.
    ///
    /// The caller passes the *displayed* figure, so remaining mode reads
    /// "a full bar means plenty left" exactly as the per-account icons do.
    /// A nil figure means nothing was read, which is not a zero-height bar
    /// but a dash — see `drawUnknownStripDash`.
    static func fillHeight(displayPercentage: Double?) -> CGFloat {
        guard let displayPercentage else { return 0 }
        let clamped = min(max(displayPercentage, 0), 100)
        return barHeight * CGFloat(clamped) / 100
    }

    /// Lays the accounts out left to right in the shared reset order prepared
    /// by `ProfileResetOrder`.
    static func cells(
        for inputs: [(id: UUID, numbersWidth: CGFloat?)]
    ) -> [HealthStripCell] {
        var cells: [HealthStripCell] = []
        cells.reserveCapacity(inputs.count)
        var x = edgePadding
        for input in inputs {
            let width: CGFloat
            if let numbersWidth = input.numbersWidth, numbersWidth > 0 {
                width = barWidth + numbersGap + numbersWidth + cellGap
            } else {
                width = barWidth + cellGap
            }
            cells.append(
                HealthStripCell(
                    profileID: input.id,
                    minX: x,
                    width: width,
                    numbersWidth: input.numbersWidth
                )
            )
            x += width
        }
        return cells
    }

    /// Where a numbers image sits vertically: centred in the full 22pt
    /// canvas.
    ///
    /// The canvas never grows to fit the image. The image's height is a run
    /// time text measurement, so it can land at 23pt, and nothing in this app
    /// pins a menu bar height or an image scaling mode — an oversized image
    /// is left to `NSButtonCell`'s proportional down-scaling. One account
    /// crossing the numbers threshold would then shrink the whole strip by a
    /// few percent, moving every cell's `minX` away from the values the click
    /// hit test depends on, and blurring every bar to make room for one
    /// number. A taller image is clipped, roughly symmetrically, instead.
    ///
    /// Rounded to a whole point so the composite lands on pixel boundaries
    /// rather than resampling the digits.
    static func numbersOriginY(
        numbersHeight: CGFloat,
        canvasHeight: CGFloat = baseCanvasHeight
    ) -> CGFloat {
        ((canvasHeight - numbersHeight) / 2).rounded()
    }

    /// Total canvas width: the padding at both ends plus every cell.
    ///
    /// Eight plain accounts come to `1 + 8 * 7 + 1 = 58` points, against
    /// roughly 470 for eight separate status items.
    static func totalWidth(_ cells: [HealthStripCell]) -> CGFloat {
        guard let last = cells.last else {
            return edgePadding * 2
        }
        return last.minX + last.width + edgePadding
    }

    /// Which account a click at `x` belongs to, or nil when the click landed
    /// in the padding at either end. Callers fall back to the active profile
    /// on nil rather than doing nothing.
    static func profileID(
        atX x: CGFloat,
        in cells: [HealthStripCell]
    ) -> UUID? {
        for cell in cells where x >= cell.minX && x < cell.minX + cell.width {
            return cell.profileID
        }
        return nil
    }
}
