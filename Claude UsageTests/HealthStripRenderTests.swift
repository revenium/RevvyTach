//
//  HealthStripRenderTests.swift
//  Claude UsageTests
//
//  Created by Claude Code on 2026-09-08.
//

import AppKit
import XCTest
@testable import Claude_Usage

/// Tests what the health strip actually draws, by reading pixels back out of
/// the rendered image rather than trusting the drawing code's own arithmetic.
@MainActor
final class HealthStripRenderTests: XCTestCase {
    private let renderer = MenuBarIconRenderer()

    // MARK: - Pixel helpers

    /// Alpha at a point in the image's own coordinate space (origin bottom
    /// left), read back from the rendered bitmap.
    private func alpha(
        atX x: CGFloat,
        y: CGFloat,
        in image: NSImage
    ) -> CGFloat {
        color(atX: x, y: y, in: image)?.alphaComponent ?? 0
    }

    private func color(
        atX x: CGFloat,
        y: CGFloat,
        in image: NSImage
    ) -> NSColor? {
        guard let cgImage = image.cgImage(
            forProposedRect: nil,
            context: nil,
            hints: nil
        ) else {
            return nil
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard rep.pixelsWide > 0, rep.pixelsHigh > 0 else {
            return nil
        }
        let scaleX = CGFloat(rep.pixelsWide) / image.size.width
        let scaleY = CGFloat(rep.pixelsHigh) / image.size.height
        // A point exactly on the image's right or bottom edge scales to
        // rep.pixelsWide / rep.pixelsHigh, one past the last valid index;
        // clamp so a boundary sample reads the last row/column instead of
        // silently missing (nil, treated as fully transparent) or, further
        // out of range, going negative.
        let pixelX = min(
            max(Int((x * scaleX).rounded(.down)), 0),
            rep.pixelsWide - 1
        )
        // NSBitmapImageRep counts rows from the top.
        let pixelY = min(
            max(Int(((image.size.height - y) * scaleY).rounded(.down)), 0),
            rep.pixelsHigh - 1
        )
        return rep.colorAt(x: pixelX, y: pixelY)?
            .usingColorSpace(.deviceRGB)
    }

    /// The highest point in a bar's column that is painted solidly.
    ///
    /// The track is drawn at 18% alpha and the no-reading dash at 55%, so a
    /// 0.75 threshold sees only a real fill.
    private func fillTop(
        forBarAt minX: CGFloat,
        in image: NSImage
    ) -> CGFloat? {
        let x = minX + HealthStripLayout.barWidth / 2
        var top: CGFloat?
        var y = HealthStripLayout.barBottom + 0.5
        let limit = HealthStripLayout.barBottom + HealthStripLayout.barHeight
        while y < limit {
            if alpha(atX: x, y: y, in: image) > 0.75 {
                top = y
            }
            y += 0.5
        }
        return top.map { $0 + 0.5 }
    }

    // MARK: - Inputs

    private func input(
        displayPercentage: Double?,
        status: UsageStatusLevel = .safe,
        showRemaining: Bool = false,
        isActive: Bool = false,
        attention: MenuBarAttentionSignal.Credential? = nil,
        numbers: NSImage? = nil,
        name: String = "Work"
    ) -> MenuBarIconRenderer.HealthStripProfileInput {
        MenuBarIconRenderer.HealthStripProfileInput(
            profileID: UUID(),
            profileName: name,
            displayPercentage: displayPercentage,
            status: status,
            showRemaining: showRemaining,
            isActive: isActive,
            attention: attention,
            numbersImage: numbers
        )
    }

    private func strip(
        _ inputs: [MenuBarIconRenderer.HealthStripProfileInput]
    ) -> MenuBarIconRenderer.HealthStripRender {
        renderer.createHealthStrip(
            profiles: inputs,
            monochromeMode: false,
            isDarkMode: false
        )
    }

    private func numbersImage(showProfileLabel: Bool) -> NSImage {
        renderer.createMultiProfilePercentage(
            sessionPercentage: 93,
            weekPercentage: 88,
            sessionStatus: .critical,
            weekStatus: .critical,
            profileName: showProfileLabel ? "Work" : nil,
            monochromeMode: false,
            isDarkMode: false
        )
    }

    // MARK: - Fill height

    func testFillHeightTracksTheDisplayPercentage() {
        for percentage in [25.0, 50.0, 75.0, 100.0] {
            let render = strip([input(displayPercentage: percentage)])
            let expectedTop = HealthStripLayout.barBottom
                + HealthStripLayout.fillHeight(displayPercentage: percentage)
            let top = fillTop(
                forBarAt: render.cells[0].minX,
                in: render.image
            )
            XCTAssertNotNil(top, "\(percentage)% must draw a fill")
            XCTAssertEqual(
                top ?? 0,
                expectedTop,
                accuracy: 1.0,
                "The fill must reach \(expectedTop) for \(percentage)%"
            )
        }
    }

    func testAZeroReadingDrawsAnEmptyTrackRatherThanAFill() {
        let render = strip([input(displayPercentage: 0)])

        XCTAssertNil(
            fillTop(forBarAt: render.cells[0].minX, in: render.image),
            "A measured zero is an empty track, with no solid fill"
        )
    }

    /// Remaining mode inverts the figure upstream, at
    /// `getDisplayPercentage`; the strip then draws it literally, so a
    /// barely-used account reads as a nearly full bar.
    func testRemainingModeInvertsTheFill() {
        let used = 20.0
        let remainingDisplay = UsageStatusCalculator.getDisplayPercentage(
            usedPercentage: used,
            showRemaining: true
        )
        XCTAssertEqual(remainingDisplay, 80)

        let usedRender = strip(
            [input(displayPercentage: used, showRemaining: false)]
        )
        let remainingRender = strip(
            [input(displayPercentage: remainingDisplay, showRemaining: true)]
        )

        let usedTop = fillTop(
            forBarAt: usedRender.cells[0].minX,
            in: usedRender.image
        ) ?? 0
        let remainingTop = fillTop(
            forBarAt: remainingRender.cells[0].minX,
            in: remainingRender.image
        ) ?? 0
        XCTAssertGreaterThan(
            remainingTop,
            usedTop,
            "20% used must draw a short bar and 80% remaining a tall one"
        )
        XCTAssertEqual(
            remainingTop,
            HealthStripLayout.barBottom
                + HealthStripLayout.fillHeight(displayPercentage: 80),
            accuracy: 1.0
        )
    }

    /// The input carries the tighter window's figure, so a bar can be tall
    /// because of the week even when the session is idle.
    func testTheBarDrawsWhateverTighterFigureItIsGiven() {
        let render = strip([input(displayPercentage: 85)])
        let top = fillTop(forBarAt: render.cells[0].minX, in: render.image)

        XCTAssertEqual(
            top ?? 0,
            HealthStripLayout.barBottom
                + HealthStripLayout.fillHeight(displayPercentage: 85),
            accuracy: 1.0
        )
    }

    // MARK: - No reading

    func testAnUnreadSessionDrawsTheDashAndNoFill() {
        let render = strip([input(displayPercentage: nil)])
        let minX = render.cells[0].minX
        let x = minX + HealthStripLayout.barWidth / 2

        XCTAssertNil(
            fillTop(forBarAt: minX, in: render.image),
            "No reading must never be drawn as a measurement of zero"
        )
        let trackMidY = HealthStripLayout.barBottom
            + HealthStripLayout.barHeight / 2
        XCTAssertGreaterThan(
            alpha(atX: x, y: trackMidY, in: render.image),
            0.4,
            "The dash sits across the middle of the track"
        )
        XCTAssertLessThan(
            alpha(atX: x, y: HealthStripLayout.barBottom + 1, in: render.image),
            0.4,
            "and nothing is drawn at the foot of the track"
        )
    }

    // MARK: - Numbers

    /// The canvas is pinned at 22pt whatever the numbers image measures.
    /// Growing it would let AppKit scale the whole strip down, blurring
    /// every bar and moving the cell positions the click hit test reads.
    func testTheCanvasIsExactly22InBothLabelStates() {
        for showProfileLabel in [false, true] {
            let numbers = numbersImage(showProfileLabel: showProfileLabel)
            let render = strip(
                [input(displayPercentage: 93, numbers: numbers)]
            )

            XCTAssertEqual(
                render.image.size.height,
                22,
                "The canvas must stay 22pt with label \(showProfileLabel), "
                    + "even though the numbers image measures "
                    + "\(numbers.size.height)pt"
            )
            XCTAssertEqual(
                HealthStripLayout.baseCanvasHeight,
                22
            )
        }
    }

    func testTheNumbersImageIsCentredInTheCanvas() {
        for showProfileLabel in [false, true] {
            let numbers = numbersImage(showProfileLabel: showProfileLabel)
            let originY = HealthStripLayout.numbersOriginY(
                numbersHeight: numbers.size.height
            )
            let topGap = HealthStripLayout.baseCanvasHeight
                - (originY + numbers.size.height)

            XCTAssertLessThanOrEqual(
                abs(originY - topGap),
                1,
                "The gap above and below the digits must match within a "
                    + "point, with label \(showProfileLabel)"
            )
            XCTAssertGreaterThanOrEqual(
                originY,
                0,
                "A real numbers image fits inside 22pt and must not be "
                    + "clipped, with label \(showProfileLabel)"
            )
        }
    }

    /// A future font could push the image past 22pt. It is then clipped
    /// roughly symmetrically rather than allowed to resize the strip.
    func testAnOversizedNumbersImageIsClippedSymmetrically() {
        for height in stride(from: 1.0, through: 40.0, by: 0.5) {
            let originY = HealthStripLayout.numbersOriginY(
                numbersHeight: CGFloat(height)
            )
            let topGap = HealthStripLayout.baseCanvasHeight
                - (originY + CGFloat(height))

            XCTAssertLessThanOrEqual(
                abs(originY - topGap),
                1,
                "height \(height) is not centred"
            )
            if height > HealthStripLayout.baseCanvasHeight {
                XCTAssertLessThanOrEqual(
                    originY,
                    0,
                    "height \(height) must overhang, not resize the canvas"
                )
            }
        }
    }

    func testANumericCellWidensTheStripAndDrawsTheDigits() {
        let numbers = numbersImage(showProfileLabel: false)
        let plain = strip([input(displayPercentage: 93)])
        let withNumbers = strip(
            [input(displayPercentage: 93, numbers: numbers)]
        )

        XCTAssertGreaterThan(
            withNumbers.image.size.width,
            plain.image.size.width
        )
        let originY = HealthStripLayout.numbersOriginY(
            numbersHeight: numbers.size.height
        )
        var painted = false
        var x = withNumbers.cells[0].minX
            + HealthStripLayout.numbersOffsetX
        let limit = x + numbers.size.width
        while x < limit, !painted {
            var y = originY
            while y < originY + numbers.size.height {
                if alpha(atX: x, y: y, in: withNumbers.image) > 0.5 {
                    painted = true
                    break
                }
                y += 0.5
            }
            x += 0.5
        }
        XCTAssertTrue(painted, "The digits must actually be drawn")
    }

    // MARK: - Attention markers

    func testTheTwoCredentialsProduceDifferentImages() {
        let plain = strip([input(displayPercentage: 50)])
        let claudeCode = strip(
            [input(displayPercentage: 50, attention: .claudeCode)]
        )
        let claudeAI = strip(
            [input(displayPercentage: 50, attention: .claudeAI)]
        )

        let plainPrint = StatusBarUIManager.imageFingerprint(plain.image)
        let codePrint = StatusBarUIManager.imageFingerprint(claudeCode.image)
        let aiPrint = StatusBarUIManager.imageFingerprint(claudeAI.image)

        XCTAssertNotNil(codePrint)
        XCTAssertNotNil(aiPrint)
        XCTAssertNotEqual(
            codePrint,
            aiPrint,
            "A filled disc and a punched ring must not collapse into one "
                + "shape: colour alone carries nothing for a colourblind "
                + "viewer at 4pt"
        )
        XCTAssertNotEqual(plainPrint, codePrint)
        XCTAssertNotEqual(plainPrint, aiPrint)
    }

    func testTheMarkerSitsAboveTheBarInsideTheCanvas() {
        let render = strip(
            [input(displayPercentage: 50, attention: .claudeCode)]
        )
        let x = render.cells[0].minX + HealthStripLayout.barWidth / 2

        XCTAssertGreaterThan(
            alpha(atX: x, y: HealthStripLayout.markerY + 2, in: render.image),
            0.5,
            "The marker is painted at its own height above the bar"
        )
        XCTAssertLessThanOrEqual(
            HealthStripLayout.markerY + 4 + 0.75,
            render.image.size.height,
            "The halo's top must stay inside the canvas"
        )
    }

    // MARK: - Active profile

    func testOnlyTheActiveProfileGetsTheGreenBase() {
        let active = input(displayPercentage: 50, isActive: true, name: "One")
        let idle = input(displayPercentage: 50, name: "Two")
        let render = strip([active, idle])

        let activeX = render.cells[0].minX + HealthStripLayout.barWidth / 2
        let idleX = render.cells[1].minX + HealthStripLayout.barWidth / 2

        let baseColor = color(atX: activeX, y: 2, in: render.image)
        XCTAssertGreaterThan(
            baseColor?.alphaComponent ?? 0,
            0.75,
            "The active account gets a solid base under its bar"
        )
        XCTAssertGreaterThan(
            baseColor?.greenComponent ?? 0,
            baseColor?.redComponent ?? 1,
            "and it is green"
        )
        XCTAssertLessThan(
            alpha(atX: idleX, y: 2, in: render.image),
            0.2,
            "No other account gets one"
        )
    }

    // MARK: - Geometry passthrough

    func testTheRenderCarriesTheCellsAClickIsResolvedAgainst() {
        let inputs = (0..<4).map { _ in input(displayPercentage: 50) }
        let render = strip(inputs)

        XCTAssertEqual(
            render.cells.map(\.profileID),
            inputs.map(\.profileID)
        )
        XCTAssertEqual(
            render.image.size.width,
            HealthStripLayout.totalWidth(render.cells)
        )
    }

    func testAnEmptyStripStillRendersACanvas() {
        let render = strip([])

        XCTAssertTrue(render.cells.isEmpty)
        XCTAssertEqual(render.image.size.height, 22)
    }
}
