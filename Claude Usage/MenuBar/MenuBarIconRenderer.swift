//
//  MenuBarIconRenderer.swift
//  Claude Usage
//
//  Created by Claude Code on 2025-12-27.
//

import Cocoa
import UsageCore

/// Which of a profile's menu bar windows have no reading behind them.
///
/// The menu bar's colours are fully spoken for by how much of a limit is used
/// — green, orange, red are three severities of a known figure — so a fourth
/// colour would be read as a fourth severity rather than as an absence. An
/// unknown window is therefore drawn as a different *form*: a dimmed dash
/// where a number would be, a hollow dashed mark where a filled one would be.
/// Nothing about it can be mistaken for a measurement of zero.
struct MenuBarUnknownWindows: OptionSet, Hashable {
    let rawValue: Int

    static let session = MenuBarUnknownWindows(rawValue: 1 << 0)
    static let week = MenuBarUnknownWindows(rawValue: 1 << 1)

    /// The glyph standing in for a number nobody received.
    static let dashGlyph = "\u{2014}"

    /// Dash pattern for the outline marks (rings, dots) that replace a filled
    /// shape when its window has no reading.
    static let strokeDashPattern: [CGFloat] = [2.0, 2.0]
}

/// Handles rendering of individual metric icons for the menu bar
struct MenuBarIconRenderer {

    private static let claudeBadgeColor = NSColor(
        red: 0.85, green: 0.47, blue: 0.34, alpha: 1.0
    )
    private static let codexBadgeColor = NSColor(
        red: 0.06, green: 0.64, blue: 0.50, alpha: 1.0
    )

    // MARK: - Nil-Safe Text Attributes
    //
    // `NSFont.systemFont`/`.monospacedSystemFont`/
    // `.monospacedDigitSystemFont` are all declared to return a
    // non-optional `NSFont`, but they bridge an Objective-C font-matching
    // API that can transiently hand back `nil` (a real crash report showed
    // exactly this: `NSInvalidArgumentException` — "attempt to insert nil
    // object from objects[0]" — building a `[.font: ...]` attributes
    // dictionary from one of these calls). Swift's non-optional return type
    // does not make that impossible; it only stops the compiler from
    // warning about it. Re-binding the result through an explicit
    // `NSFont?` at the call site is what makes the nil observable, which is
    // why every call below is captured as `let font: NSFont? = ...` instead
    // of being inlined straight into a dictionary literal.

    /// Resolves the font actually used for text attributes. Production
    /// code always uses the default, which simply falls back to the plain
    /// system font at the same size when the preferred (usually
    /// monospaced) font construction failed. Tests substitute a resolver
    /// that returns `nil` unconditionally to reproduce the exact production
    /// failure mode — both the preferred call AND the system-font fallback
    /// returning nil — without needing the font-matching service to
    /// actually fail.
    private let fontResolver: (NSFont?, CGFloat) -> NSFont?

    init(
        fontResolver: @escaping (NSFont?, CGFloat) -> NSFont? = {
            preferred, fallbackSize in
            preferred ?? NSFont.systemFont(ofSize: fallbackSize)
        }
    ) {
        self.fontResolver = fontResolver
    }

    private func safeFont(
        preferred: NSFont?,
        fallbackSize: CGFloat
    ) -> NSFont? {
        fontResolver(preferred, fallbackSize)
    }

    /// Builds a text-attributes dictionary, or `nil` if even the system
    /// font fallback is unavailable. `nil` must be treated by the caller as
    /// "skip drawing this text" — never force a dictionary containing a
    /// nil font, which is exactly what crashed the app before this fix.
    private func textAttributes(
        font: NSFont?,
        fallbackSize: CGFloat,
        color: NSColor
    ) -> [NSAttributedString.Key: Any]? {
        guard let font = safeFont(
            preferred: font,
            fallbackSize: fallbackSize
        ) else {
            return nil
        }
        return [.font: font, .foregroundColor: color]
    }

    // MARK: - Public Methods

    /// Renders an arbitrary provider/window metric without assuming a fixed
    /// number of limit groups. Provider and state remain distinguishable in
    /// monochrome and high-contrast modes through text and shape, not color.
    func createProviderMetricImage(
        _ presentation: ProviderMetricPresentation?,
        appearance: ProviderAppearance,
        metricConfig: MetricIconConfig,
        globalConfig: MenuBarIconConfiguration,
        isDarkMode: Bool,
        showProviderLabel: Bool,
        visualLabel: String? = nil,
        placeholderState: ProviderMetricDisplayState = .noData
    ) -> NSImage {
        let state = presentation?.state ?? placeholderState
        let percentage = presentation?.displayedPercentage.flatMap {
            $0.isFinite ? min(max($0, 0), 100) : nil
        }
        let valueText = percentage.map { "\(Int($0.rounded()))%" } ?? "—"
        let stateMark = providerStateMark(state)
        let foreground = menuBarForegroundColor(isDarkMode: isDarkMode)
        let rawElapsed = presentation?.elapsedFraction
        let effectiveStatus: UsageStatusLevel
        if globalConfig.usePaceColoring,
           let used = presentation?.usedPercentage,
           let rawElapsed {
            effectiveStatus = UsageStatusCalculator.calculateStatus(
                usedPercentage: used,
                showRemaining:
                    presentation?.showRemaining == true,
                elapsedFraction: rawElapsed
            )
        } else {
            effectiveStatus = presentation?.statusLevel ?? .safe
        }
        let color: NSColor
        if state == .error || state == .degraded {
            color = globalConfig.colorMode == .monochrome
                ? foreground
                : NSColor.systemOrange
        } else if presentation != nil {
            color = getColorForMode(
                globalConfig.colorMode,
                statusLevel: effectiveStatus,
                singleColorHex: globalConfig.singleColorHex,
                isDarkMode: isDarkMode
            )
        } else {
            color = foreground
        }
        let marker = globalConfig.showTimeMarker
            ? rawElapsed.map {
                CGFloat(
                    presentation?.showRemaining == true ? 1 - $0 : $0
                )
            }
            : nil
        let pace: PaceStatus?
        if globalConfig.showPaceMarker,
           let used = presentation?.usedPercentage,
           let rawElapsed {
            pace = PaceStatus.calculate(
                usedPercentage: used,
                elapsedFraction: rawElapsed
            )
        } else {
            pace = nil
        }
        let label = showProviderLabel
            ? visualLabel ?? appearance.compactBadge
            : ""

        switch metricConfig.iconStyle {
        case .battery:
            return createProviderBarImage(
                value: percentage,
                valueText: valueText,
                providerLabel: label,
                stateMark: stateMark,
                color: color,
                foreground: foreground,
                marker: marker,
                paceStatus: pace,
                showPaceMarker: globalConfig.showPaceMarker,
                isDarkMode: isDarkMode,
                stackedLabel: true
            )
        case .progressBar:
            return createProviderBarImage(
                value: percentage,
                valueText: valueText,
                providerLabel: label,
                stateMark: stateMark,
                color: color,
                foreground: foreground,
                marker: marker,
                paceStatus: pace,
                showPaceMarker: globalConfig.showPaceMarker,
                isDarkMode: isDarkMode,
                stackedLabel: false
            )
        case .percentageOnly:
            return createProviderTextImage(
                text: [label, valueText + stateMark]
                    .filter { !$0.isEmpty }
                    .joined(separator: " "),
                color: color,
                paceStatus: pace,
                showPaceMarker: globalConfig.showPaceMarker
            )
        case .icon:
            return createProviderRingImage(
                value: percentage,
                providerLabel: label,
                stateMark: stateMark,
                color: color,
                foreground: foreground,
                marker: marker,
                paceStatus: pace,
                showPaceMarker: globalConfig.showPaceMarker,
                isDarkMode: isDarkMode
            )
        case .compact:
            return createProviderCompactImage(
                providerLabel: label,
                stateMark: stateMark,
                color: color,
                foreground: foreground,
                paceStatus: pace,
                showPaceMarker: globalConfig.showPaceMarker
            )
        }
    }

    private func providerStateMark(
        _ state: ProviderMetricDisplayState
    ) -> String {
        switch state {
        case .ready: return ""
        case .loading: return "…"
        case .stale: return "◷"
        case .degraded: return "!"
        case .error: return "×"
        case .noData: return "—"
        }
    }

    private func createProviderTextImage(
        text: String,
        color: NSColor,
        paceStatus: PaceStatus?,
        showPaceMarker: Bool
    ) -> NSImage {
        let font: NSFont? = NSFont.monospacedDigitSystemFont(
            ofSize: 11,
            weight: .semibold
        )
        let attributes = textAttributes(
            font: font,
            fallbackSize: 11,
            color: color
        )
        let size = attributes.map {
            (text as NSString).size(withAttributes: $0)
        } ?? .zero
        let paceWidth: CGFloat =
            showPaceMarker && paceStatus != nil ? 7 : 0
        let image = NSImage(
            size: NSSize(
                width: max(18, ceil(size.width) + 4 + paceWidth),
                height: 18
            )
        )
        image.lockFocus()
        defer { image.unlockFocus() }
        if let attributes {
            (text as NSString).draw(
                at: NSPoint(x: 2, y: (18 - size.height) / 2),
                withAttributes: attributes
            )
        }
        if showPaceMarker, let paceStatus {
            paceStatus.color.setFill()
            NSBezierPath(
                ovalIn: NSRect(
                    x: 4 + size.width,
                    y: 7,
                    width: 4,
                    height: 4
                )
            ).fill()
        }
        return image
    }

    private func createProviderBarImage(
        value: Double?,
        valueText: String,
        providerLabel: String,
        stateMark: String,
        color: NSColor,
        foreground: NSColor,
        marker: CGFloat?,
        paceStatus: PaceStatus?,
        showPaceMarker: Bool,
        isDarkMode: Bool,
        stackedLabel: Bool
    ) -> NSImage {
        let barWidth: CGFloat = 40
        let labelText = [providerLabel, valueText + stateMark]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let barFont: NSFont? = NSFont.monospacedDigitSystemFont(
            ofSize: stackedLabel ? 8 : 7,
            weight: .semibold
        )
        let attributes = textAttributes(
            font: barFont,
            fallbackSize: stackedLabel ? 8 : 7,
            color: foreground
        )
        let text = labelText as NSString
        let textSize = attributes.map {
            text.size(withAttributes: $0)
        } ?? .zero
        let labelWidth = ceil(textSize.width)
        let totalWidth = stackedLabel
            ? max(barWidth, labelWidth + 2)
            : labelWidth + 4 + barWidth
        let image = NSImage(
            size: NSSize(
                width: totalWidth,
                height: stackedLabel ? 28 : 18
            )
        )
        image.lockFocus()
        defer { image.unlockFocus() }
        let barX: CGFloat = stackedLabel
            ? (totalWidth - barWidth) / 2
            : labelWidth + 4
        let barY: CGFloat = stackedLabel ? 15 : 5
        let barHeight: CGFloat = 8
        foreground.withAlphaComponent(0.22).setFill()
        NSBezierPath(
            roundedRect: NSRect(
                x: barX,
                y: barY,
                width: barWidth,
                height: barHeight
            ),
            xRadius: 3,
            yRadius: 3
        ).fill()
        if let value {
            let fillWidth = barWidth * CGFloat(value / 100)
            if fillWidth > 0 {
                color.setFill()
                NSBezierPath(
                    roundedRect: NSRect(
                        x: barX,
                        y: barY,
                        width: fillWidth,
                        height: barHeight
                    ),
                    xRadius: 3,
                    yRadius: 3
                ).fill()
            }
        }
        if let marker {
            let tick = NSBezierPath()
            let x = barX + barWidth * min(max(marker, 0), 1)
            tick.move(to: NSPoint(x: x, y: barY - 1))
            tick.line(to: NSPoint(x: x, y: barY + barHeight + 1))
            drawPaceMarkerTick(
                tick,
                paceStatus: paceStatus,
                showPaceMarker: showPaceMarker,
                isDarkMode: isDarkMode
            )
        }
        let point = stackedLabel
            ? NSPoint(
                x: max(0, (totalWidth - textSize.width) / 2),
                y: 1
            )
            : NSPoint(
                x: 0,
                y: (18 - textSize.height) / 2
            )
        if let attributes {
            text.draw(at: point, withAttributes: attributes)
        }
        return image
    }

    private func createProviderRingImage(
        value: Double?,
        providerLabel: String,
        stateMark: String,
        color: NSColor,
        foreground: NSColor,
        marker: CGFloat?,
        paceStatus: PaceStatus?,
        showPaceMarker: Bool,
        isDarkMode: Bool
    ) -> NSImage {
        let text = (providerLabel + stateMark) as NSString
        let ringFont: NSFont? = NSFont.monospacedSystemFont(
            ofSize: 7,
            weight: .bold
        )
        let attributes = textAttributes(
            font: ringFont,
            fallbackSize: 7,
            color: foreground
        )
        let textSize = attributes.map {
            text.size(withAttributes: $0)
        } ?? .zero
        let width: CGFloat = providerLabel.isEmpty
            ? 18
            : max(35, ceil(textSize.width) + 19)
        let image = NSImage(size: NSSize(width: width, height: 18))
        image.lockFocus()
        defer { image.unlockFocus() }
        let center = NSPoint(x: 9, y: 9)
        let background = NSBezierPath()
        background.appendArc(
            withCenter: center,
            radius: 6,
            startAngle: 0,
            endAngle: 360
        )
        foreground.withAlphaComponent(0.25).setStroke()
        background.lineWidth = 2
        background.stroke()
        if let value, value > 0 {
            let progress = NSBezierPath()
            progress.appendArc(
                withCenter: center,
                radius: 6,
                startAngle: 90,
                endAngle: 90 - 360 * CGFloat(value / 100),
                clockwise: true
            )
            color.setStroke()
            progress.lineWidth = 2
            progress.lineCapStyle = .round
            progress.stroke()
        }
        if let marker {
            let angle = (90 - 360 * min(max(marker, 0), 1))
                * .pi / 180
            let tick = NSBezierPath()
            tick.move(
                to: NSPoint(
                    x: center.x + 4 * cos(angle),
                    y: center.y + 4 * sin(angle)
                )
            )
            tick.line(
                to: NSPoint(
                    x: center.x + 8 * cos(angle),
                    y: center.y + 8 * sin(angle)
                )
            )
            drawPaceMarkerTick(
                tick,
                paceStatus: paceStatus,
                showPaceMarker: showPaceMarker,
                isDarkMode: isDarkMode
            )
        }
        if let attributes {
            text.draw(
                at: NSPoint(x: 17, y: 4),
                withAttributes: attributes
            )
        }
        return image
    }

    private func createProviderCompactImage(
        providerLabel: String,
        stateMark: String,
        color: NSColor,
        foreground: NSColor,
        paceStatus: PaceStatus?,
        showPaceMarker: Bool
    ) -> NSImage {
        let text = (providerLabel + stateMark) as NSString
        let compactFont: NSFont? = NSFont.monospacedSystemFont(
            ofSize: 8,
            weight: .bold
        )
        let attributes = textAttributes(
            font: compactFont,
            fallbackSize: 8,
            color: foreground
        )
        let textSize = attributes.map {
            text.size(withAttributes: $0)
        } ?? .zero
        let paceWidth: CGFloat =
            showPaceMarker && paceStatus != nil ? 6 : 0
        let image = NSImage(
            size: NSSize(
                width: max(15, 7 + textSize.width + paceWidth),
                height: 18
            )
        )
        image.lockFocus()
        defer { image.unlockFocus() }
        color.setFill()
        NSBezierPath(
            ovalIn: NSRect(x: 1, y: 6, width: 6, height: 6)
        ).fill()
        if let attributes {
            text.draw(
                at: NSPoint(x: 8, y: (18 - textSize.height) / 2),
                withAttributes: attributes
            )
        }
        if showPaceMarker, let paceStatus {
            paceStatus.color.setFill()
            NSBezierPath(
                ovalIn: NSRect(
                    x: 9 + textSize.width,
                    y: 7,
                    width: 4,
                    height: 4
                )
            ).fill()
        }
        return image
    }

    /// Creates an image for a specific metric
    func createImage(
        for metricType: MenuBarMetricType,
        config: MetricIconConfig,
        globalConfig: MenuBarIconConfiguration,
        usage: ClaudeUsage,
        apiUsage: APIUsage?,
        isDarkMode: Bool,
        colorMode: MenuBarColorMode,
        singleColorHex: String,
        showIconName: Bool,
        showNextSessionTime: Bool
    ) -> NSImage {
        // Get the metric value and percentage
        let metricData = getMetricData(
            metricType: metricType,
            config: config,
            usage: usage,
            apiUsage: apiUsage,
            showRemaining: globalConfig.showRemainingPercentage,
            usePaceColoring: globalConfig.usePaceColoring
        )

        // Calculate time marker fraction for session/week metrics
        let timeMarkerFraction: CGFloat? = globalConfig.showTimeMarker
            ? calculateTimeMarkerFraction(
                metricType: metricType,
                usage: usage,
                showRemaining: globalConfig.showRemainingPercentage
            )
            : nil

        // Compute pace status from RAW values (not display-adjusted)
        let paceStatus: PaceStatus? = {
            guard globalConfig.showPaceMarker, metricType != .api else { return nil }
            // Get raw elapsed fraction (always non-inverted)
            guard let rawElapsed = calculateTimeMarkerFraction(
                metricType: metricType, usage: usage, showRemaining: false
            ) else { return nil }
            // Get raw used percentage
            let rawUsed: Double = metricType == .session
                ? usage.sessionPercentage
                : usage.weeklyPercentage
            return PaceStatus.calculate(
                usedPercentage: rawUsed,
                elapsedFraction: Double(rawElapsed)
            )
        }()
        let showPaceMarker = globalConfig.showPaceMarker

        // API is ALWAYS text-based (no icon styles)
        if metricType == .api {
            return createAPITextStyle(
                metricData: metricData,
                isDarkMode: isDarkMode,
                colorMode: colorMode,
                singleColorHex: singleColorHex,
                showIconName: showIconName
            )
        }

        // Render based on icon style for Session and Week
        switch config.iconStyle {
        case .battery:
            return createBatteryStyle(
                metricType: metricType,
                metricData: metricData,
                isDarkMode: isDarkMode,
                colorMode: colorMode,
                singleColorHex: singleColorHex,
                showIconName: showIconName,
                showNextSessionTime: showNextSessionTime,
                usage: usage,
                timeMarkerFraction: timeMarkerFraction,
                paceStatus: paceStatus,
                showPaceMarker: showPaceMarker
            )
        case .progressBar:
            return createProgressBarStyle(
                metricType: metricType,
                metricData: metricData,
                isDarkMode: isDarkMode,
                colorMode: colorMode,
                singleColorHex: singleColorHex,
                showIconName: showIconName,
                showNextSessionTime: showNextSessionTime,
                usage: usage,
                timeMarkerFraction: timeMarkerFraction,
                paceStatus: paceStatus,
                showPaceMarker: showPaceMarker
            )
        case .percentageOnly:
            return createPercentageOnlyStyle(
                metricType: metricType,
                metricData: metricData,
                isDarkMode: isDarkMode,
                colorMode: colorMode,
                singleColorHex: singleColorHex,
                showIconName: showIconName,
                paceStatus: paceStatus,
                showPaceMarker: showPaceMarker
            )
        case .icon:
            return createIconWithBarStyle(
                metricType: metricType,
                metricData: metricData,
                isDarkMode: isDarkMode,
                colorMode: colorMode,
                singleColorHex: singleColorHex,
                showIconName: showIconName,
                timeMarkerFraction: timeMarkerFraction,
                paceStatus: paceStatus,
                showPaceMarker: showPaceMarker
            )
        case .compact:
            return createCompactStyle(
                metricType: metricType,
                metricData: metricData,
                isDarkMode: isDarkMode,
                colorMode: colorMode,
                singleColorHex: singleColorHex,
                showIconName: showIconName,
                paceStatus: paceStatus,
                showPaceMarker: showPaceMarker
            )
        }
    }

    // MARK: - Metric Data Extraction

    private struct MetricData {
        let percentage: Double
        let displayText: String
        let statusLevel: UsageStatusLevel
        let sessionResetTime: Date?  // Only populated for session metric
    }

    private func getMetricData(
        metricType: MenuBarMetricType,
        config: MetricIconConfig,
        usage: ClaudeUsage,
        apiUsage: APIUsage?,
        showRemaining: Bool,
        usePaceColoring: Bool = true
    ) -> MetricData {
        switch metricType {
        case .session:
            let usedPercentage = usage.effectiveSessionPercentage
            let displayPercentage = UsageStatusCalculator.getDisplayPercentage(
                usedPercentage: usedPercentage,
                showRemaining: showRemaining
            )
            let sessionElapsed: Double? = usePaceColoring
                ? UsageStatusCalculator.elapsedFraction(
                    resetTime: usage.sessionResetTime,
                    duration: Constants.sessionWindow,
                    showRemaining: false
                )
                : nil
            let statusLevel = UsageStatusCalculator.calculateStatus(
                usedPercentage: usedPercentage,
                showRemaining: showRemaining,
                elapsedFraction: sessionElapsed
            )

            return MetricData(
                percentage: displayPercentage,
                displayText: "\(Int(displayPercentage))%",
                statusLevel: statusLevel,
                sessionResetTime: usage.sessionResetTime
            )

        case .week:
            let usedPercentage = usage.weeklyPercentage
            let displayPercentage = UsageStatusCalculator.getDisplayPercentage(
                usedPercentage: usedPercentage,
                showRemaining: showRemaining
            )
            let weekElapsed: Double? = usePaceColoring
                ? UsageStatusCalculator.elapsedFraction(
                    resetTime: usage.weeklyResetTime,
                    duration: Constants.weeklyWindow,
                    showRemaining: false
                )
                : nil
            let statusLevel = UsageStatusCalculator.calculateStatus(
                usedPercentage: usedPercentage,
                showRemaining: showRemaining,
                elapsedFraction: weekElapsed
            )

            // Claude's API only reports utilization percentages — it has no
            // real per-window token counts (see ClaudeUsageProviderAdapter).
            // Token display mode falls back to percentage rather than
            // showing a number derived from an assumed plan limit.
            let displayText = "\(Int(displayPercentage))%"

            return MetricData(
                percentage: displayPercentage,
                displayText: displayText,
                statusLevel: statusLevel,
                sessionResetTime: nil
            )

        case .api:
            guard let apiUsage = apiUsage else {
                return MetricData(
                    percentage: showRemaining ? 100 : 0,  // 100% remaining or 0% used when no data
                    displayText: "N/A",
                    statusLevel: .safe,
                    sessionResetTime: nil
                )
            }

            let usedPercentage = apiUsage.usagePercentage
            let displayPercentage = UsageStatusCalculator.getDisplayPercentage(
                usedPercentage: usedPercentage,
                showRemaining: showRemaining
            )
            let statusLevel = UsageStatusCalculator.calculateStatus(
                usedPercentage: usedPercentage,
                showRemaining: showRemaining
            )

            let displayText: String
            switch config.apiDisplayMode {
            case .remaining:
                displayText = apiUsage.formattedRemaining
            case .used:
                displayText = apiUsage.formattedUsed
            case .both:
                displayText = "\(apiUsage.formattedUsed)/\(apiUsage.formattedTotal)"
            }

            return MetricData(
                percentage: displayPercentage,
                displayText: displayText,
                statusLevel: statusLevel,
                sessionResetTime: nil
            )
        }
    }

    // MARK: - Icon Style Renderers

    private func createBatteryStyle(
        metricType: MenuBarMetricType,
        metricData: MetricData,
        isDarkMode: Bool,
        colorMode: MenuBarColorMode,
        singleColorHex: String,
        showIconName: Bool,
        showNextSessionTime: Bool,
        usage: ClaudeUsage,
        timeMarkerFraction: CGFloat? = nil,
        paceStatus: PaceStatus? = nil,
        showPaceMarker: Bool = false
    ) -> NSImage {
        let percentage = CGFloat(metricData.percentage) / 100.0

        // Battery style: NO prefix before the bar, label goes below
        let batteryWidth: CGFloat = 42  // Match original exactly
        let totalWidth = batteryWidth
        let totalHeight: CGFloat = 28  // Taller to fit bar on top, text below
        let barHeight: CGFloat = 10  // Match original

        let image = NSImage(size: NSSize(width: totalWidth, height: totalHeight))

        image.lockFocus()
        defer { image.unlockFocus() }

        // Use isDarkMode to determine correct foreground color for menu bar
        let foregroundColor = menuBarForegroundColor(isDarkMode: isDarkMode)
        let outlineColor: NSColor = foregroundColor
        let textColor: NSColor = foregroundColor
        let fillColor: NSColor = getColorForMode(colorMode, statusLevel: metricData.statusLevel, singleColorHex: singleColorHex, isDarkMode: isDarkMode)

        let xOffset: CGFloat = 0

        // Battery bar at TOP (like original)
        let barY = totalHeight - barHeight - 4
        let barWidth = batteryWidth - 2
        let padding: CGFloat = 2.0

        // Outer container
        let containerPath = NSBezierPath(
            roundedRect: NSRect(x: xOffset + 1, y: barY, width: barWidth, height: barHeight),
            xRadius: 2.5,
            yRadius: 2.5
        )
        outlineColor.withAlphaComponent(0.5).setStroke()
        containerPath.lineWidth = 1.2
        containerPath.stroke()

        // Fill level
        let fillWidth = (barWidth - padding * 2) * percentage
        if fillWidth > 1 {
            let fillPath = NSBezierPath(
                roundedRect: NSRect(
                    x: xOffset + 1 + padding,
                    y: barY + padding,
                    width: fillWidth,
                    height: barHeight - padding * 2
                ),
                xRadius: 1.5,
                yRadius: 1.5
            )
            fillColor.setFill()
            fillPath.fill()
        }

        // Time-elapsed tick mark on the battery bar
        if let fraction = timeMarkerFraction {
            let tickX = round(xOffset + 1 + padding + (barWidth - padding * 2) * fraction)
            let tickPath = NSBezierPath()
            tickPath.move(to: NSPoint(x: tickX, y: barY))
            tickPath.line(to: NSPoint(x: tickX, y: barY + barHeight))
            drawPaceMarkerTick(tickPath, paceStatus: paceStatus, showPaceMarker: showPaceMarker, isDarkMode: isDarkMode)
        }

        // Label BELOW the battery (replaces percentage text)
        let batteryLabelFont: NSFont? = NSFont.systemFont(
            ofSize: 9,
            weight: .medium
        )
        let batteryTextAttributes = textAttributes(
            font: batteryLabelFont,
            fallbackSize: 9,
            color: textColor.withAlphaComponent(0.85)
        )

        // Show metric label if enabled, otherwise show percentage
        let text: NSString
        if showNextSessionTime && metricType == .session, let resetTime = metricData.sessionResetTime {
            if showIconName {
                // Show "S (→2H)" when labels enabled
                text = "S (\(resetTime.timeRemainingHoursString()))" as NSString
            } else {
                // Show just "→2H" when labels disabled
                text = resetTime.timeRemainingHoursString() as NSString
            }
        } else if showIconName {
            // Show full word: "Session" or "Week"
            text = (metricType == .session ? "Session" : "Week") as NSString
        } else {
            // No label mode - show percentage instead
            text = "\(Int(metricData.percentage))%" as NSString
        }

        let textSize = batteryTextAttributes.map {
            text.size(withAttributes: $0)
        } ?? .zero
        let textX = xOffset + (batteryWidth - textSize.width) / 2
        let textY: CGFloat = 2
        if let batteryTextAttributes {
            text.draw(
                at: NSPoint(x: textX, y: textY),
                withAttributes: batteryTextAttributes
            )
        }

        return image
    }

    private func createProgressBarStyle(
        metricType: MenuBarMetricType,
        metricData: MetricData,
        isDarkMode: Bool,
        colorMode: MenuBarColorMode,
        singleColorHex: String,
        showIconName: Bool,
        showNextSessionTime: Bool,
        usage: ClaudeUsage,
        timeMarkerFraction: CGFloat? = nil,
        paceStatus: PaceStatus? = nil,
        showPaceMarker: Bool = false
    ) -> NSImage {
        // For progress bar: show "S" or "W" before the bar (not full prefix)
        let labelWidth: CGFloat = showIconName ? 10 : 0
        let barWidth: CGFloat = 40
        let spacing: CGFloat = showIconName ? 2 : 0
        let totalWidth = labelWidth + spacing + barWidth + 2
        let height: CGFloat = 18

        let image = NSImage(size: NSSize(width: totalWidth, height: height))

        image.lockFocus()
        defer { image.unlockFocus() }

        // Use isDarkMode to determine correct foreground color for menu bar
        let foregroundColor = menuBarForegroundColor(isDarkMode: isDarkMode)
        let textColor: NSColor = foregroundColor
        let fillColor: NSColor = getColorForMode(colorMode, statusLevel: metricData.statusLevel, singleColorHex: singleColorHex, isDarkMode: isDarkMode)
        let backgroundColor: NSColor = foregroundColor.withAlphaComponent(0.2)

        var xOffset: CGFloat = 1

        // Draw label before bar (just "S" or "W")
        if showIconName {
            let progressLabelFont: NSFont? = NSFont.systemFont(
                ofSize: 10,
                weight: .semibold
            )
            let labelAttributes = textAttributes(
                font: progressLabelFont,
                fallbackSize: 10,
                color: textColor.withAlphaComponent(0.9)
            )
            let label = (metricType == .session ? "S" : "W") as NSString
            if let labelAttributes {
                let labelSize = label.size(withAttributes: labelAttributes)
                label.draw(
                    at: NSPoint(x: xOffset, y: (height - labelSize.height) / 2),
                    withAttributes: labelAttributes
                )
            }
            xOffset += labelWidth + spacing
        }

        // Progress bar
        let barHeight: CGFloat = 9  // Slightly taller
        let barY = (height - barHeight) / 2

        // Background
        let bgPath = NSBezierPath(
            roundedRect: NSRect(x: xOffset, y: barY, width: barWidth, height: barHeight),
            xRadius: 4,
            yRadius: 4
        )
        backgroundColor.setFill()
        bgPath.fill()

        // Fill
        let fillWidth = barWidth * CGFloat(metricData.percentage / 100.0)
        if fillWidth > 1 {
            let fillPath = NSBezierPath(
                roundedRect: NSRect(x: xOffset, y: barY, width: fillWidth, height: barHeight),
                xRadius: 4,
                yRadius: 4
            )
            fillColor.setFill()
            fillPath.fill()

            // Time-elapsed tick mark on the progress bar
            if let fraction = timeMarkerFraction {
                let tickX = round(xOffset + barWidth * fraction)
                let tickPath = NSBezierPath()
                tickPath.move(to: NSPoint(x: tickX, y: barY))
                tickPath.line(to: NSPoint(x: tickX, y: barY + barHeight))
                drawPaceMarkerTick(tickPath, paceStatus: paceStatus, showPaceMarker: showPaceMarker, isDarkMode: isDarkMode)
            }

            // Draw session reset time inside the fill area if enabled and this is a session metric
            if showNextSessionTime && metricType == .session, let resetTime = metricData.sessionResetTime {
                let timeString = resetTime.timeRemainingHoursString() as NSString
                let timeFont: NSFont? = NSFont.systemFont(ofSize: 5.5, weight: .medium)
                let timeAttributes = textAttributes(
                    font: timeFont,
                    fallbackSize: 5.5,
                    color: NSColor.white
                )

                if let timeAttributes {
                    let timeSize = timeString.size(withAttributes: timeAttributes)
                    // Only draw if there's enough space in the fill area
                    if fillWidth > timeSize.width + 2 {
                        // Right-align the text in the fill area
                        let timeX = xOffset + fillWidth - timeSize.width - 4
                        let timeY = barY + (barHeight - timeSize.height) / 2
                        timeString.draw(at: NSPoint(x: timeX, y: timeY), withAttributes: timeAttributes)
                    }
                }
            }
        }

        return image
    }

    private func createPercentageOnlyStyle(
        metricType: MenuBarMetricType,
        metricData: MetricData,
        isDarkMode: Bool,
        colorMode: MenuBarColorMode,
        singleColorHex: String,
        showIconName: Bool,
        paceStatus: PaceStatus? = nil,
        showPaceMarker: Bool = false
    ) -> NSImage {
        let percentageFont: NSFont? = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)  // Larger font
        let fillColor: NSColor = getColorForMode(colorMode, statusLevel: metricData.statusLevel, singleColorHex: singleColorHex, isDarkMode: isDarkMode)

        var fullText = ""

        if showIconName {
            fullText = "\(metricType.prefixText) \(metricData.displayText)"
        } else {
            fullText = metricData.displayText
        }

        let attributes = textAttributes(
            font: percentageFont,
            fallbackSize: 12,
            color: fillColor
        )

        let textSize = attributes.map {
            fullText.size(withAttributes: $0)
        } ?? .zero
        let hasPaceDot = showPaceMarker && paceStatus != nil
        let paceDotExtra: CGFloat = hasPaceDot ? 8 : 0  // dot(4) + gaps(2+2)
        let image = NSImage(size: NSSize(width: textSize.width + 2 + paceDotExtra, height: 18))

        image.lockFocus()
        defer { image.unlockFocus() }

        let textY = (18 - textSize.height) / 2
        if let attributes {
            fullText.draw(at: NSPoint(x: 2, y: textY), withAttributes: attributes)
        }

        // Pace dot after text
        if showPaceMarker, let pace = paceStatus {
            let dotSize: CGFloat = 4.0
            let dotX = 2 + textSize.width + 2
            let dotY = (18 - dotSize) / 2
            let dotPath = NSBezierPath(ovalIn: NSRect(x: dotX, y: dotY, width: dotSize, height: dotSize))
            pace.color.setFill()
            dotPath.fill()
        }

        return image
    }

    private func createIconWithBarStyle(
        metricType: MenuBarMetricType,
        metricData: MetricData,
        isDarkMode: Bool,
        colorMode: MenuBarColorMode,
        singleColorHex: String,
        showIconName: Bool,
        timeMarkerFraction: CGFloat? = nil,
        paceStatus: PaceStatus? = nil,
        showPaceMarker: Bool = false
    ) -> NSImage {
        // For circle: make it bigger to fit S/W in center
        let circleSize: CGFloat = showIconName ? 22 : 18  // Bigger when showing label
        let size: CGFloat = showIconName ? 22 : 18
        let totalWidth = circleSize + 1

        let image = NSImage(size: NSSize(width: totalWidth, height: size))

        image.lockFocus()
        defer { image.unlockFocus() }

        // Use isDarkMode to determine correct foreground color for menu bar
        let foregroundColor = menuBarForegroundColor(isDarkMode: isDarkMode)
        let textColor: NSColor = foregroundColor
        let fillColor: NSColor = getColorForMode(colorMode, statusLevel: metricData.statusLevel, singleColorHex: singleColorHex, isDarkMode: isDarkMode)

        let xOffset: CGFloat = 1

        // Progress arc
        let percentage = metricData.percentage / 100.0
        let centerX = xOffset + circleSize / 2
        let center = NSPoint(x: centerX, y: size / 2)
        let radius = (circleSize - 4.0) / 2
        let startAngle: CGFloat = 90
        let endAngle = startAngle - (360 * CGFloat(percentage))

        // Background ring
        let bgArcPath = NSBezierPath()
        bgArcPath.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: 0,
            endAngle: 360,
            clockwise: false
        )
        textColor.withAlphaComponent(0.15).setStroke()
        bgArcPath.lineWidth = 3.0
        bgArcPath.lineCapStyle = .round
        bgArcPath.stroke()

        // Progress ring (clockwise from 12 o'clock)
        if percentage > 0 {
            let arcPath = NSBezierPath()
            arcPath.appendArc(
                withCenter: center,
                radius: radius,
                startAngle: startAngle,
                endAngle: endAngle,
                clockwise: true
            )
            fillColor.setStroke()
            arcPath.lineWidth = 3.0
            arcPath.lineCapStyle = .round
            arcPath.stroke()
        }

        // Time-elapsed tick mark on the ring (clockwise from 12 o'clock)
        if let fraction = timeMarkerFraction {
            let tickAngle = (90 - 360 * fraction) * .pi / 180
            let innerR = radius - 2.0
            let outerR = radius + 2.0
            let tickPath = NSBezierPath()
            tickPath.move(to: NSPoint(
                x: center.x + innerR * cos(tickAngle),
                y: center.y + innerR * sin(tickAngle)
            ))
            tickPath.line(to: NSPoint(
                x: center.x + outerR * cos(tickAngle),
                y: center.y + outerR * sin(tickAngle)
            ))
            drawPaceMarkerTick(tickPath, paceStatus: paceStatus, showPaceMarker: showPaceMarker, isDarkMode: isDarkMode)
        }

        // Draw S/W in the CENTER of the circle
        if showIconName {
            let ringCenterFont: NSFont? = NSFont.systemFont(ofSize: 9, weight: .bold)
            let labelAttributes = textAttributes(
                font: ringCenterFont,
                fallbackSize: 9,
                color: textColor
            )
            let label = (metricType == .session ? "S" : "W") as NSString
            if let labelAttributes {
                let labelSize = label.size(withAttributes: labelAttributes)
                let labelX = center.x - labelSize.width / 2
                let labelY = center.y - labelSize.height / 2
                label.draw(at: NSPoint(x: labelX, y: labelY), withAttributes: labelAttributes)
            }
        }

        return image
    }

    private func createCompactStyle(
        metricType: MenuBarMetricType,
        metricData: MetricData,
        isDarkMode: Bool,
        colorMode: MenuBarColorMode,
        singleColorHex: String,
        showIconName: Bool,
        paceStatus: PaceStatus? = nil,
        showPaceMarker: Bool = false
    ) -> NSImage {
        let prefixWidth: CGFloat = showIconName ? 16 : 0
        let dotSize: CGFloat = 8
        let spacing: CGFloat = showIconName ? 1 : 0
        let hasPaceDot = showPaceMarker && paceStatus != nil
        let paceDotExtra: CGFloat = hasPaceDot ? 6 : 0  // gap(2) + dot(4)
        let totalWidth = prefixWidth + spacing + dotSize + paceDotExtra + 1
        let height: CGFloat = 18

        let image = NSImage(size: NSSize(width: totalWidth, height: height))

        image.lockFocus()
        defer { image.unlockFocus() }

        // Use isDarkMode to determine correct foreground color for menu bar
        let foregroundColor = menuBarForegroundColor(isDarkMode: isDarkMode)
        let textColor: NSColor = foregroundColor
        let fillColor: NSColor = getColorForMode(colorMode, statusLevel: metricData.statusLevel, singleColorHex: singleColorHex, isDarkMode: isDarkMode)

        var xOffset: CGFloat = 1

        // Draw prefix if enabled
        if showIconName {
            let compactPrefixFont: NSFont? = NSFont.systemFont(ofSize: 9, weight: .medium)
            let prefixAttributes = textAttributes(
                font: compactPrefixFont,
                fallbackSize: 9,
                color: textColor.withAlphaComponent(0.85)
            )
            let prefixText = metricType.prefixText as NSString
            if let prefixAttributes {
                let prefixSize = prefixText.size(withAttributes: prefixAttributes)
                prefixText.draw(
                    at: NSPoint(x: xOffset, y: (height - prefixSize.height) / 2),
                    withAttributes: prefixAttributes
                )
            }
            xOffset += prefixWidth + spacing
        }

        // Draw dot
        let dotY = (height - dotSize) / 2
        let dotRect = NSRect(x: xOffset, y: dotY, width: dotSize, height: dotSize)
        let dotPath = NSBezierPath(ovalIn: dotRect)
        fillColor.setFill()
        dotPath.fill()

        // Pace dot next to main dot
        if showPaceMarker, let pace = paceStatus {
            let paceDotSize: CGFloat = 4.0
            let paceDotX = xOffset + dotSize + 2
            let paceDotY = (height - paceDotSize) / 2
            let paceDotPath = NSBezierPath(ovalIn: NSRect(x: paceDotX, y: paceDotY, width: paceDotSize, height: paceDotSize))
            pace.color.setFill()
            paceDotPath.fill()
        }

        return image
    }

    // MARK: - API Text Style (Always Text-Based)

    private func createAPITextStyle(
        metricData: MetricData,
        isDarkMode: Bool,
        colorMode: MenuBarColorMode,
        singleColorHex: String,
        showIconName: Bool
    ) -> NSImage {
        let apiTextFont: NSFont? = NSFont.systemFont(ofSize: 11, weight: .medium)

        // Use isDarkMode to determine correct foreground color for menu bar
        let textColor: NSColor = menuBarForegroundColor(isDarkMode: isDarkMode)

        var fullText = ""

        if showIconName {
            fullText = "API: \(metricData.displayText)"
        } else {
            fullText = metricData.displayText
        }

        let attributes = textAttributes(
            font: apiTextFont,
            fallbackSize: 11,
            color: textColor
        )

        let textSize = attributes.map {
            fullText.size(withAttributes: $0)
        } ?? .zero
        let image = NSImage(size: NSSize(width: textSize.width + 4, height: 18))

        image.lockFocus()
        defer { image.unlockFocus() }

        let textY = (18 - textSize.height) / 2
        if let attributes {
            fullText.draw(at: NSPoint(x: 2, y: textY), withAttributes: attributes)
        }

        return image
    }

    // MARK: - Multi-Profile Concentric Icon

    /// Creates a compact concentric circle icon for multi-profile display mode
    /// - Parameters:
    ///   - sessionPercentage: Session usage percentage (0-100)
    ///   - weekPercentage: Week usage percentage (0-100)
    ///   - sessionStatus: Status level for session (for coloring)
    ///   - weekStatus: Status level for week (for coloring)
    ///   - profileInitial: Single character to display in center (e.g., "W" for Work)
    ///   - monochromeMode: If true, use foreground color for all elements
    ///   - isDarkMode: Whether the menu bar is in dark mode
    ///   - useSystemColor: If true, use system accent color instead of status colors
    /// - Returns: NSImage with concentric circles showing both metrics
    func createConcentricIcon(
        sessionPercentage: Double,
        weekPercentage: Double,
        sessionStatus: UsageStatusLevel,
        weekStatus: UsageStatusLevel,
        profileInitial: String,
        monochromeMode: Bool,
        isDarkMode: Bool,
        useSystemColor: Bool = false,
        sessionTimeMarker: CGFloat? = nil,
        weekTimeMarker: CGFloat? = nil,
        sessionPaceStatus: PaceStatus? = nil,
        weekPaceStatus: PaceStatus? = nil,
        showPaceMarker: Bool = false,
        unknownWindows: MenuBarUnknownWindows = []
    ) -> NSImage {
        let size: CGFloat = 24
        let image = NSImage(size: NSSize(width: size, height: size))

        image.lockFocus()
        defer { image.unlockFocus() }

        let center = NSPoint(x: size / 2, y: size / 2)

        // Use isDarkMode to determine correct foreground color for menu bar
        let foregroundColor = menuBarForegroundColor(isDarkMode: isDarkMode)
        let textColor: NSColor = foregroundColor
        let sessionColor: NSColor = getColor(for: sessionStatus, monochromeMode: monochromeMode, useSystemColor: useSystemColor, isDarkMode: isDarkMode)
        let weekColor: NSColor = getColor(for: weekStatus, monochromeMode: monochromeMode, useSystemColor: useSystemColor, isDarkMode: isDarkMode)
        let backgroundColor: NSColor = foregroundColor.withAlphaComponent(0.15)
        let sessionUnknown = unknownWindows.contains(.session)
        let weekUnknown = unknownWindows.contains(.week)

        // Outer ring (Session) - larger radius, thicker stroke - Session is primary/more important
        let outerRadius: CGFloat = (size - 4) / 2  // 10pt radius
        let outerStrokeWidth: CGFloat = 3.0

        // Background ring for outer
        let outerBgPath = NSBezierPath()
        outerBgPath.appendArc(
            withCenter: center,
            radius: outerRadius,
            startAngle: 0,
            endAngle: 360,
            clockwise: false
        )
        backgroundColor.setStroke()
        outerBgPath.lineWidth = outerStrokeWidth
        // A dashed track is the ring's "no reading" form. A solid empty track
        // is what 0% looks like, so an unread window must not borrow it.
        if sessionUnknown {
            outerBgPath.setLineDash(
                MenuBarUnknownWindows.strokeDashPattern,
                count: MenuBarUnknownWindows.strokeDashPattern.count,
                phase: 0
            )
        }
        outerBgPath.stroke()

        // Session progress ring (outer - primary metric, clockwise from 12 o'clock)
        if !sessionUnknown, sessionPercentage > 0 {
            let sessionEndAngle = 90 - (360 * CGFloat(sessionPercentage / 100.0))
            let outerProgressPath = NSBezierPath()
            outerProgressPath.appendArc(
                withCenter: center,
                radius: outerRadius,
                startAngle: 90,
                endAngle: sessionEndAngle,
                clockwise: true
            )
            sessionColor.setStroke()
            outerProgressPath.lineWidth = outerStrokeWidth
            outerProgressPath.lineCapStyle = .round
            outerProgressPath.stroke()
        }

        // Session time marker on outer ring. Suppressed without a
        // reading: a pace tick against no figure implies a comparison.
        if !sessionUnknown, let fraction = sessionTimeMarker {
            let tickAngle = (90 - 360 * fraction) * .pi / 180
            let innerR = outerRadius - 2.0
            let outerR = outerRadius + 2.0
            let tickPath = NSBezierPath()
            tickPath.move(to: NSPoint(x: center.x + innerR * cos(tickAngle), y: center.y + innerR * sin(tickAngle)))
            tickPath.line(to: NSPoint(x: center.x + outerR * cos(tickAngle), y: center.y + outerR * sin(tickAngle)))
            drawPaceMarkerTick(tickPath, paceStatus: sessionPaceStatus, showPaceMarker: showPaceMarker, isDarkMode: isDarkMode)
        }

        // Inner ring (Week) - smaller radius, thinner stroke - Week is secondary
        let innerRadius: CGFloat = outerRadius - 4.5  // 5.5pt radius
        let innerStrokeWidth: CGFloat = 2.0

        // Background ring for inner
        let innerBgPath = NSBezierPath()
        innerBgPath.appendArc(
            withCenter: center,
            radius: innerRadius,
            startAngle: 0,
            endAngle: 360,
            clockwise: false
        )
        backgroundColor.setStroke()
        innerBgPath.lineWidth = innerStrokeWidth
        if weekUnknown {
            innerBgPath.setLineDash(
                MenuBarUnknownWindows.strokeDashPattern,
                count: MenuBarUnknownWindows.strokeDashPattern.count,
                phase: 0
            )
        }
        innerBgPath.stroke()

        // Week progress ring (inner - secondary metric, clockwise from 12 o'clock)
        if !weekUnknown, weekPercentage > 0 {
            let weekEndAngle = 90 - (360 * CGFloat(weekPercentage / 100.0))
            let innerProgressPath = NSBezierPath()
            innerProgressPath.appendArc(
                withCenter: center,
                radius: innerRadius,
                startAngle: 90,
                endAngle: weekEndAngle,
                clockwise: true
            )
            weekColor.setStroke()
            innerProgressPath.lineWidth = innerStrokeWidth
            innerProgressPath.lineCapStyle = .round
            innerProgressPath.stroke()
        }

        // Week time marker on inner ring
        if !weekUnknown, let fraction = weekTimeMarker {
            let tickAngle = (90 - 360 * fraction) * .pi / 180
            let innerR = innerRadius - 2.0
            let outerR = innerRadius + 2.0
            let tickPath = NSBezierPath()
            tickPath.move(to: NSPoint(x: center.x + innerR * cos(tickAngle), y: center.y + innerR * sin(tickAngle)))
            tickPath.line(to: NSPoint(x: center.x + outerR * cos(tickAngle), y: center.y + outerR * sin(tickAngle)))
            drawPaceMarkerTick(tickPath, paceStatus: weekPaceStatus, showPaceMarker: showPaceMarker, isDarkMode: isDarkMode)
        }

        // Profile initial in center
        let initial = String(profileInitial.prefix(1)).uppercased()
        let concentricInitialFont: NSFont? = NSFont.systemFont(ofSize: 8, weight: .bold)
        let labelAttributes = textAttributes(
            font: concentricInitialFont,
            fallbackSize: 8,
            color: textColor
        )
        let labelString = initial as NSString
        if let labelAttributes {
            let labelSize = labelString.size(withAttributes: labelAttributes)
            let labelX = center.x - labelSize.width / 2
            let labelY = center.y - labelSize.height / 2
            labelString.draw(at: NSPoint(x: labelX, y: labelY), withAttributes: labelAttributes)
        }

        return image
    }

    /// Creates a concentric icon with profile label below for multi-profile mode
    /// - Returns: NSImage with concentric circles and profile name label
    func createConcentricIconWithLabel(
        sessionPercentage: Double,
        weekPercentage: Double,
        sessionStatus: UsageStatusLevel,
        weekStatus: UsageStatusLevel,
        profileName: String,
        monochromeMode: Bool,
        isDarkMode: Bool,
        useSystemColor: Bool = false,
        sessionTimeMarker: CGFloat? = nil,
        weekTimeMarker: CGFloat? = nil,
        sessionPaceStatus: PaceStatus? = nil,
        weekPaceStatus: PaceStatus? = nil,
        showPaceMarker: Bool = false,
        unknownWindows: MenuBarUnknownWindows = []
    ) -> NSImage {
        let circleSize: CGFloat = 20
        let labelHeight: CGFloat = 10
        let spacing: CGFloat = 1
        let totalHeight = circleSize + spacing + labelHeight
        let labelWidth: CGFloat = max(circleSize, CGFloat(profileName.prefix(3).count) * 6 + 4)
        let totalWidth = max(circleSize, labelWidth)

        let image = NSImage(size: NSSize(width: totalWidth, height: totalHeight))

        image.lockFocus()
        defer { image.unlockFocus() }

        let circleCenter = NSPoint(x: totalWidth / 2, y: totalHeight - circleSize / 2)

        // Use isDarkMode to determine correct foreground color for menu bar
        let foregroundColor = menuBarForegroundColor(isDarkMode: isDarkMode)
        let textColor: NSColor = foregroundColor
        let sessionColor: NSColor = getColor(for: sessionStatus, monochromeMode: monochromeMode, useSystemColor: useSystemColor, isDarkMode: isDarkMode)
        let weekColor: NSColor = getColor(for: weekStatus, monochromeMode: monochromeMode, useSystemColor: useSystemColor, isDarkMode: isDarkMode)
        let backgroundColor: NSColor = foregroundColor.withAlphaComponent(0.15)
        let sessionUnknown = unknownWindows.contains(.session)
        let weekUnknown = unknownWindows.contains(.week)

        // Outer ring (Session) - Session is primary/more important
        let outerRadius: CGFloat = (circleSize - 4) / 2
        let outerStrokeWidth: CGFloat = 2.5

        // Background ring for outer
        let outerBgPath = NSBezierPath()
        outerBgPath.appendArc(
            withCenter: circleCenter,
            radius: outerRadius,
            startAngle: 0,
            endAngle: 360,
            clockwise: false
        )
        backgroundColor.setStroke()
        outerBgPath.lineWidth = outerStrokeWidth
        // Dashed track = no reading; a solid empty track is what 0% looks like.
        if sessionUnknown {
            outerBgPath.setLineDash(
                MenuBarUnknownWindows.strokeDashPattern,
                count: MenuBarUnknownWindows.strokeDashPattern.count,
                phase: 0
            )
        }
        outerBgPath.stroke()

        // Session progress ring (outer - primary metric, clockwise from 12 o'clock)
        if !sessionUnknown, sessionPercentage > 0 {
            let sessionEndAngle = 90 - (360 * CGFloat(sessionPercentage / 100.0))
            let outerProgressPath = NSBezierPath()
            outerProgressPath.appendArc(
                withCenter: circleCenter,
                radius: outerRadius,
                startAngle: 90,
                endAngle: sessionEndAngle,
                clockwise: true
            )
            sessionColor.setStroke()
            outerProgressPath.lineWidth = outerStrokeWidth
            outerProgressPath.lineCapStyle = .round
            outerProgressPath.stroke()
        }

        // Session time marker on outer ring
        if !sessionUnknown, let fraction = sessionTimeMarker {
            let tickAngle = (90 - 360 * fraction) * .pi / 180
            let innerR = outerRadius - 2.0
            let outerR = outerRadius + 2.0
            let tickPath = NSBezierPath()
            tickPath.move(to: NSPoint(x: circleCenter.x + innerR * cos(tickAngle), y: circleCenter.y + innerR * sin(tickAngle)))
            tickPath.line(to: NSPoint(x: circleCenter.x + outerR * cos(tickAngle), y: circleCenter.y + outerR * sin(tickAngle)))
            drawPaceMarkerTick(tickPath, paceStatus: sessionPaceStatus, showPaceMarker: showPaceMarker, isDarkMode: isDarkMode)
        }

        // Inner ring (Week) - Week is secondary
        let innerRadius: CGFloat = outerRadius - 3.5
        let innerStrokeWidth: CGFloat = 1.5

        // Background ring for inner
        let innerBgPath = NSBezierPath()
        innerBgPath.appendArc(
            withCenter: circleCenter,
            radius: innerRadius,
            startAngle: 0,
            endAngle: 360,
            clockwise: false
        )
        backgroundColor.setStroke()
        innerBgPath.lineWidth = innerStrokeWidth
        if weekUnknown {
            innerBgPath.setLineDash(
                MenuBarUnknownWindows.strokeDashPattern,
                count: MenuBarUnknownWindows.strokeDashPattern.count,
                phase: 0
            )
        }
        innerBgPath.stroke()

        // Week progress ring (inner - secondary metric, clockwise from 12 o'clock)
        if !weekUnknown, weekPercentage > 0 {
            let weekEndAngle = 90 - (360 * CGFloat(weekPercentage / 100.0))
            let innerProgressPath = NSBezierPath()
            innerProgressPath.appendArc(
                withCenter: circleCenter,
                radius: innerRadius,
                startAngle: 90,
                endAngle: weekEndAngle,
                clockwise: true
            )
            weekColor.setStroke()
            innerProgressPath.lineWidth = innerStrokeWidth
            innerProgressPath.lineCapStyle = .round
            innerProgressPath.stroke()
        }

        // Week time marker on inner ring
        if !weekUnknown, let fraction = weekTimeMarker {
            let tickAngle = (90 - 360 * fraction) * .pi / 180
            let innerR = innerRadius - 2.0
            let outerR = innerRadius + 2.0
            let tickPath = NSBezierPath()
            tickPath.move(to: NSPoint(x: circleCenter.x + innerR * cos(tickAngle), y: circleCenter.y + innerR * sin(tickAngle)))
            tickPath.line(to: NSPoint(x: circleCenter.x + outerR * cos(tickAngle), y: circleCenter.y + outerR * sin(tickAngle)))
            drawPaceMarkerTick(tickPath, paceStatus: weekPaceStatus, showPaceMarker: showPaceMarker, isDarkMode: isDarkMode)
        }

        // Profile label below the circle (first 3 characters)
        let label = String(profileName.prefix(3))
        let concentricLabelFont: NSFont? = NSFont.systemFont(ofSize: 8, weight: .medium)
        let labelAttributes = textAttributes(
            font: concentricLabelFont,
            fallbackSize: 8,
            color: textColor.withAlphaComponent(0.85)
        )
        let labelString = label as NSString
        if let labelAttributes {
            let labelSize = labelString.size(withAttributes: labelAttributes)
            let labelX = (totalWidth - labelSize.width) / 2
            let labelY: CGFloat = 0
            labelString.draw(at: NSPoint(x: labelX, y: labelY), withAttributes: labelAttributes)
        }

        return image
    }

    // MARK: - Multi-Profile Progress Bar Style

    /// Creates a progress bar style icon for multi-profile mode
    func createMultiProfileProgressBar(
        sessionPercentage: Double,
        weekPercentage: Double?,
        sessionStatus: UsageStatusLevel,
        weekStatus: UsageStatusLevel,
        profileName: String?,
        monochromeMode: Bool,
        isDarkMode: Bool,
        useSystemColor: Bool = false,
        sessionTimeMarker: CGFloat? = nil,
        weekTimeMarker: CGFloat? = nil,
        sessionPaceStatus: PaceStatus? = nil,
        weekPaceStatus: PaceStatus? = nil,
        showPaceMarker: Bool = false,
        unknownWindows: MenuBarUnknownWindows = []
    ) -> NSImage {
        let barWidth: CGFloat = 24
        let barHeight: CGFloat = 4
        let spacing: CGFloat = 2
        let labelHeight: CGFloat = profileName != nil ? 10 : 0
        let hasWeek = weekPercentage != nil

        let totalHeight = barHeight + (hasWeek ? spacing + barHeight : 0) + (profileName != nil ? spacing + labelHeight : 0)
        let totalWidth = barWidth

        let image = NSImage(size: NSSize(width: totalWidth, height: totalHeight))

        image.lockFocus()
        defer { image.unlockFocus() }

        // Use isDarkMode to determine correct foreground color for menu bar
        let foregroundColor = menuBarForegroundColor(isDarkMode: isDarkMode)
        let sessionColor: NSColor = getColor(for: sessionStatus, monochromeMode: monochromeMode, useSystemColor: useSystemColor, isDarkMode: isDarkMode)
        let weekColor: NSColor = getColor(for: weekStatus, monochromeMode: monochromeMode, useSystemColor: useSystemColor, isDarkMode: isDarkMode)
        let backgroundColor: NSColor = foregroundColor.withAlphaComponent(0.2)
        let sessionUnknown = unknownWindows.contains(.session)
        let weekUnknown = unknownWindows.contains(.week)
        let unknownMarkColor = foregroundColor.withAlphaComponent(0.55)

        /// A short dash centred inside an empty track: the bar's "no reading"
        /// form. Centred and thinner than the track on purpose — a
        /// left-anchored fill of any width would read as a small percentage.
        func drawUnknownDash(inTrackAt y: CGFloat) {
            let dashWidth: CGFloat = 8
            let dashHeight: CGFloat = 1.5
            let dashRect = NSRect(
                x: (barWidth - dashWidth) / 2,
                y: y + (barHeight - dashHeight) / 2,
                width: dashWidth,
                height: dashHeight
            )
            unknownMarkColor.setFill()
            NSBezierPath(
                roundedRect: dashRect,
                xRadius: dashHeight / 2,
                yRadius: dashHeight / 2
            ).fill()
        }

        var currentY = totalHeight

        // Session bar (top)
        currentY -= barHeight
        let sessionBgRect = NSRect(x: 0, y: currentY, width: barWidth, height: barHeight)
        backgroundColor.setFill()
        NSBezierPath(roundedRect: sessionBgRect, xRadius: 2, yRadius: 2).fill()

        if sessionUnknown {
            drawUnknownDash(inTrackAt: currentY)
        } else {
            let sessionFillWidth = barWidth * CGFloat(sessionPercentage / 100.0)
            let sessionFillRect = NSRect(x: 0, y: currentY, width: sessionFillWidth, height: barHeight)
            sessionColor.setFill()
            NSBezierPath(roundedRect: sessionFillRect, xRadius: 2, yRadius: 2).fill()
        }

        // Session time marker tick. Omitted without a reading, since a pace
        // tick beside no figure invites a comparison that cannot be made.
        if !sessionUnknown, let fraction = sessionTimeMarker {
            let tickX = round(barWidth * fraction)
            let tickPath = NSBezierPath()
            tickPath.move(to: NSPoint(x: tickX, y: currentY))
            tickPath.line(to: NSPoint(x: tickX, y: currentY + barHeight))
            drawPaceMarkerTick(tickPath, paceStatus: sessionPaceStatus, showPaceMarker: showPaceMarker, isDarkMode: isDarkMode)
        }

        // Week bar (if shown)
        if let weekPct = weekPercentage {
            currentY -= (spacing + barHeight)
            let weekBgRect = NSRect(x: 0, y: currentY, width: barWidth, height: barHeight)
            backgroundColor.setFill()
            NSBezierPath(roundedRect: weekBgRect, xRadius: 2, yRadius: 2).fill()

            if weekUnknown {
                drawUnknownDash(inTrackAt: currentY)
            } else {
                let weekFillWidth = barWidth * CGFloat(weekPct / 100.0)
                let weekFillRect = NSRect(x: 0, y: currentY, width: weekFillWidth, height: barHeight)
                weekColor.setFill()
                NSBezierPath(roundedRect: weekFillRect, xRadius: 2, yRadius: 2).fill()
            }

            // Week time marker tick
            if !weekUnknown, let fraction = weekTimeMarker {
                let tickX = round(barWidth * fraction)
                let tickPath = NSBezierPath()
                tickPath.move(to: NSPoint(x: tickX, y: currentY))
                tickPath.line(to: NSPoint(x: tickX, y: currentY + barHeight))
                drawPaceMarkerTick(tickPath, paceStatus: weekPaceStatus, showPaceMarker: showPaceMarker, isDarkMode: isDarkMode)
            }
        }

        // Profile label (if shown)
        if let name = profileName {
            let label = String(name.prefix(3))
            let progressBarLabelFont: NSFont? = NSFont.systemFont(ofSize: 8, weight: .medium)
            let labelAttributes = textAttributes(
                font: progressBarLabelFont,
                fallbackSize: 8,
                color: foregroundColor.withAlphaComponent(0.85)
            )
            let labelString = label as NSString
            if let labelAttributes {
                let labelSize = labelString.size(withAttributes: labelAttributes)
                let labelX = (totalWidth - labelSize.width) / 2
                labelString.draw(at: NSPoint(x: labelX, y: 0), withAttributes: labelAttributes)
            }
        }

        return image
    }

    // MARK: - Multi-Profile Compact Dot Style

    /// Creates a minimal dot indicator for multi-profile mode
    func createCompactDot(
        percentage: Double,
        status: UsageStatusLevel,
        profileInitial: String?,
        monochromeMode: Bool,
        isDarkMode: Bool,
        useSystemColor: Bool = false,
        paceStatus: PaceStatus? = nil,
        showPaceMarker: Bool = false,
        unknownWindows: MenuBarUnknownWindows = []
    ) -> NSImage {
        let dotSize: CGFloat = 10
        let labelHeight: CGFloat = profileInitial != nil ? 10 : 0
        let spacing: CGFloat = profileInitial != nil ? 1 : 0
        let sessionUnknown = unknownWindows.contains(.session)
        let hasPaceDot = showPaceMarker && paceStatus != nil && !sessionUnknown
        let paceDotExtra: CGFloat = hasPaceDot ? 6 : 0  // gap(2) + dot(4)

        let totalHeight = dotSize + spacing + labelHeight
        let totalWidth = max(dotSize + paceDotExtra, 16)

        let image = NSImage(size: NSSize(width: totalWidth, height: totalHeight))

        image.lockFocus()
        defer { image.unlockFocus() }

        // Use isDarkMode to determine correct foreground color for menu bar
        let foregroundColor = menuBarForegroundColor(isDarkMode: isDarkMode)
        let dotColor: NSColor = getColor(for: status, monochromeMode: monochromeMode, useSystemColor: useSystemColor, isDarkMode: isDarkMode)

        // Draw main status dot
        let mainDotX = (totalWidth - dotSize - paceDotExtra) / 2
        let dotRect = NSRect(
            x: mainDotX,
            y: totalHeight - dotSize,
            width: dotSize,
            height: dotSize
        )
        if sessionUnknown {
            // A hollow dashed outline instead of a filled dot. The filled dot
            // always carries a colour that means a severity, so an unread
            // window has to stop being a filled dot at all.
            let outlinePath = NSBezierPath(ovalIn: dotRect.insetBy(dx: 0.75, dy: 0.75))
            outlinePath.lineWidth = 1.5
            outlinePath.setLineDash(
                MenuBarUnknownWindows.strokeDashPattern,
                count: MenuBarUnknownWindows.strokeDashPattern.count,
                phase: 0
            )
            foregroundColor.withAlphaComponent(0.55).setStroke()
            outlinePath.stroke()
        } else {
            dotColor.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
        }

        // Pace dot next to main dot
        if !sessionUnknown, showPaceMarker, let pace = paceStatus {
            let paceDotSize: CGFloat = 4.0
            let paceDotX = mainDotX + dotSize + 2
            let paceDotY = totalHeight - dotSize + (dotSize - paceDotSize) / 2
            let paceDotPath = NSBezierPath(ovalIn: NSRect(x: paceDotX, y: paceDotY, width: paceDotSize, height: paceDotSize))
            pace.color.setFill()
            paceDotPath.fill()
        }

        // Profile initial (if shown)
        if let initial = profileInitial {
            let compactDotFont: NSFont? = NSFont.systemFont(ofSize: 8, weight: .bold)
            let labelAttributes = textAttributes(
                font: compactDotFont,
                fallbackSize: 8,
                color: foregroundColor.withAlphaComponent(0.85)
            )
            let labelString = initial.uppercased() as NSString
            if let labelAttributes {
                let labelSize = labelString.size(withAttributes: labelAttributes)
                let labelX = (totalWidth - labelSize.width) / 2
                labelString.draw(at: NSPoint(x: labelX, y: 0), withAttributes: labelAttributes)
            }
        }

        return image
    }

    // MARK: - Default App Logo (for profiles without credentials)

    /// Creates a default app logo icon for the menu bar when no credentials are configured
    func createDefaultAppLogo(isDarkMode: Bool) -> NSImage {
        // Try to load the app logo from assets
        if let logo = NSImage(named: "HeaderLogo") {
            // Create a copy to avoid modifying the original
            let resizedLogo = NSImage(size: NSSize(width: 20, height: 20))
            resizedLogo.lockFocus()
            defer { resizedLogo.unlockFocus() }

            // Draw the logo centered
            logo.draw(in: NSRect(x: 0, y: 0, width: 20, height: 20),
                     from: NSRect.zero,
                     operation: .sourceOver,
                     fraction: 1.0)

            return resizedLogo
        }

        // Fallback: Create a simple circle icon if logo not found
        let size: CGFloat = 20
        let image = NSImage(size: NSSize(width: size, height: size))

        image.lockFocus()
        defer { image.unlockFocus() }

        // Use isDarkMode to determine correct foreground color for menu bar
        let color: NSColor = menuBarForegroundColor(isDarkMode: isDarkMode)

        // Draw a simple circle
        let circlePath = NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: size - 4, height: size - 4))
        color.withAlphaComponent(0.7).setStroke()
        circlePath.lineWidth = 2.0
        circlePath.stroke()

        // Draw a small dot in the center
        let dotPath = NSBezierPath(ovalIn: NSRect(x: size/2 - 2, y: size/2 - 2, width: 4, height: 4))
        color.setFill()
        dotPath.fill()

        return image
    }

    // MARK: - Multi-Profile Percentage Style

    /// Creates a percentage text icon for multi-profile mode
    /// Format: "30 · 4" (session · week) with status colors, optional profile label below
    func createMultiProfilePercentage(
        sessionPercentage: Double?,
        weekPercentage: Double?,
        sessionStatus: UsageStatusLevel,
        weekStatus: UsageStatusLevel,
        profileName: String?,
        monochromeMode: Bool,
        isDarkMode: Bool,
        useSystemColor: Bool = false,
        sessionPaceStatus: PaceStatus? = nil,
        weekPaceStatus: PaceStatus? = nil,
        showPaceMarker: Bool = false,
        unknownWindows: MenuBarUnknownWindows = []
    ) -> NSImage {
        let compactFont: NSFont? = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        let font = safeFont(preferred: compactFont, fallbackSize: 9)
        let foregroundColor = menuBarForegroundColor(isDarkMode: isDarkMode)
        let separatorColor = foregroundColor.withAlphaComponent(0.4)
        // `sessionPercentage == nil` has always meant "nothing to draw here";
        // an explicitly unknown window is the same statement made by the
        // caller, so both arrive at the same dash.
        let sessionUnknown = unknownWindows.contains(.session)
            || sessionPercentage == nil
        let weekUnknown = unknownWindows.contains(.week)
        let unknownColor = foregroundColor.withAlphaComponent(0.55)

        let sessionColor: NSColor = getColor(for: sessionStatus, monochromeMode: monochromeMode, useSystemColor: useSystemColor, isDarkMode: isDarkMode)
        let weekColor: NSColor = getColor(for: weekStatus, monochromeMode: monochromeMode, useSystemColor: useSystemColor, isDarkMode: isDarkMode)

        // Build the attributed string. If even the system font fallback is
        // unavailable, leave this empty rather than insert a nil font into
        // an attributes dictionary — the image still renders (minus the
        // percentage text) instead of crashing the app.
        let attributed = NSMutableAttributedString()
        if let font {
            // Session number, or a dimmed dash when there is no reading
            // behind it. Dimmed rather than recoloured: the three status
            // colours are three severities of a known figure, so a fourth
            // colour would be read as a fourth severity.
            let sessionText = sessionUnknown
                ? MenuBarUnknownWindows.dashGlyph
                : "\(Int(sessionPercentage ?? 0))"
            attributed.append(NSAttributedString(string: sessionText, attributes: [
                .font: font,
                .foregroundColor: sessionUnknown ? unknownColor : sessionColor
            ]))

            // Separator and week number (if shown)
            if let weekPct = weekPercentage {
                attributed.append(NSAttributedString(string: " · ", attributes: [
                    .font: font,
                    .foregroundColor: separatorColor
                ]))
                let weekText = weekUnknown
                    ? MenuBarUnknownWindows.dashGlyph
                    : "\(Int(weekPct))"
                attributed.append(NSAttributedString(string: weekText, attributes: [
                    .font: font,
                    .foregroundColor: weekUnknown ? unknownColor : weekColor
                ]))
            }
        }

        let textSize = attributed.size()
        let hasPaceDot = showPaceMarker
            && sessionPaceStatus != nil
            && !sessionUnknown
        let paceDotExtra: CGFloat = hasPaceDot ? 6 : 0  // gap(2) + dot(4)
        let labelHeight: CGFloat = profileName != nil ? 10 : 0
        let labelSpacing: CGFloat = profileName != nil ? 1 : 0
        let totalWidth = max(textSize.width + 2 + paceDotExtra, profileName != nil ? CGFloat(String(profileName!.prefix(3)).count) * 6 + 4 : 0)
        let totalHeight = textSize.height + labelSpacing + labelHeight

        let image = NSImage(size: NSSize(width: totalWidth, height: totalHeight))

        image.lockFocus()
        defer { image.unlockFocus() }

        // Draw percentage text at top, centered (shift left slightly if pace dot present)
        let textX = (totalWidth - textSize.width - paceDotExtra) / 2
        let textY = totalHeight - textSize.height
        attributed.draw(at: NSPoint(x: textX, y: textY))

        // Pace dot after the percentage text
        if !sessionUnknown, showPaceMarker, let pace = sessionPaceStatus {
            let dotSize: CGFloat = 4.0
            let dotX = textX + textSize.width + 2
            let dotY = textY + (textSize.height - dotSize) / 2
            let dotPath = NSBezierPath(ovalIn: NSRect(x: dotX, y: dotY, width: dotSize, height: dotSize))
            pace.color.setFill()
            dotPath.fill()
        }

        // Profile label below (if shown)
        if let name = profileName {
            let label = String(name.prefix(3))
            let percentageLabelFont: NSFont? = NSFont.systemFont(ofSize: 8, weight: .medium)
            let labelAttributes = textAttributes(
                font: percentageLabelFont,
                fallbackSize: 8,
                color: foregroundColor.withAlphaComponent(0.85)
            )
            let labelString = label as NSString
            if let labelAttributes {
                let labelSize = labelString.size(withAttributes: labelAttributes)
                let labelX = (totalWidth - labelSize.width) / 2
                labelString.draw(at: NSPoint(x: labelX, y: 0), withAttributes: labelAttributes)
            }
        }

        return image
    }

    // MARK: - Provider Badge

    /// Applies the user-selected provider badge to an already-rendered menu
    /// bar image. Running as a final compositing pass lets every icon style
    /// (battery, progress bar, rings, concentric, compact, ...) get the same
    /// treatment without threading provider identity through each style's
    /// own drawing code.
    ///
    /// - `glyph` grows the canvas to the left and draws a small monochrome
    ///   provider mark there.
    /// - `tint` draws a low-opacity provider-colored pill behind the
    ///   existing content, at the existing canvas size.
    /// - `glyphAndTint` does both; the pill spans the grown canvas.
    func applyProviderBadge(
        to image: NSImage,
        providerID: ProviderID,
        style: ProviderBadgeStyle,
        isDarkMode: Bool
    ) -> NSImage {
        guard style != .none else { return image }

        let foreground = menuBarForegroundColor(isDarkMode: isDarkMode)
        let badgeColor = Self.badgeColor(for: providerID)
        let sourceSize = image.size
        let glyphColumnWidth: CGFloat = style.showsGlyph ? 11 : 0
        let glyphGap: CGFloat = style.showsGlyph ? 2 : 0
        let newSize = NSSize(
            width: sourceSize.width + glyphColumnWidth + glyphGap,
            height: sourceSize.height
        )

        let result = NSImage(size: newSize)
        result.lockFocus()
        defer { result.unlockFocus() }

        if style.showsTint {
            let pillAlpha: CGFloat = isDarkMode ? 0.20 : 0.15
            let pillRect = NSRect(origin: .zero, size: newSize)
                .insetBy(dx: 1, dy: 1)
            let pillPath = NSBezierPath(
                roundedRect: pillRect,
                xRadius: 4.5,
                yRadius: 4.5
            )
            badgeColor.withAlphaComponent(pillAlpha).setFill()
            pillPath.fill()
        }

        if style.showsGlyph {
            let glyphRect = NSRect(
                x: 0,
                y: 0,
                width: glyphColumnWidth,
                height: newSize.height
            )
            drawProviderGlyph(
                providerID: providerID,
                in: glyphRect,
                color: foreground
            )
        }

        image.draw(
            at: NSPoint(x: glyphColumnWidth + glyphGap, y: 0),
            from: NSRect(origin: .zero, size: sourceSize),
            operation: .sourceOver,
            fraction: 1.0
        )

        return result
    }

    private static func badgeColor(for providerID: ProviderID) -> NSColor {
        switch providerID {
        case .claude:
            return claudeBadgeColor
        case .codex:
            return codexBadgeColor
        default:
            return NSColor.systemGray
        }
    }

    private func drawProviderGlyph(
        providerID: ProviderID,
        in rect: NSRect,
        color: NSColor
    ) {
        switch providerID {
        case .claude:
            drawSparkGlyph(in: rect, color: color)
        case .codex:
            drawTerminalGlyph(in: rect, color: color)
        default:
            let dotSize: CGFloat = 4
            color.setFill()
            NSBezierPath(
                ovalIn: NSRect(
                    x: rect.midX - dotSize / 2,
                    y: rect.midY - dotSize / 2,
                    width: dotSize,
                    height: dotSize
                )
            ).fill()
        }
    }

    /// A generic four-point spark/starburst for Claude items. Deliberately a
    /// plain geometric mark (two crossing pointed lozenges), not Anthropic's
    /// logo artwork.
    private func drawSparkGlyph(in rect: NSRect, color: NSColor) {
        let size: CGFloat = min(rect.width, rect.height, 10)
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let outerRadius = size / 2
        let innerRadius = outerRadius * 0.35
        let path = NSBezierPath()
        for i in 0..<8 {
            let angle = CGFloat(i) * .pi / 4 - .pi / 2
            let radius = i % 2 == 0 ? outerRadius : innerRadius
            let point = NSPoint(
                x: center.x + radius * cos(angle),
                y: center.y + radius * sin(angle)
            )
            if i == 0 {
                path.move(to: point)
            } else {
                path.line(to: point)
            }
        }
        path.close()
        color.setFill()
        path.fill()
    }

    /// A terminal-prompt mark (">_") for Codex items.
    ///
    /// The original crash: `NSFont.monospacedSystemFont` is declared
    /// non-optional but returned `nil` here in production
    /// (`NSInvalidArgumentException` — "attempt to insert nil object from
    /// objects[0]" — inserting it into this attributes dictionary aborted
    /// the whole app). Routed through `Self.textAttributes`, which detects
    /// the nil via an explicit `Optional` rebind and skips drawing instead.
    private func drawTerminalGlyph(in rect: NSRect, color: NSColor) {
        let text = ">_" as NSString
        let terminalFont: NSFont? = NSFont.monospacedSystemFont(ofSize: 8, weight: .bold)
        guard let attributes = textAttributes(
            font: terminalFont,
            fallbackSize: 8,
            color: color
        ) else {
            return
        }
        let textSize = text.size(withAttributes: attributes)
        let point = NSPoint(
            x: rect.midX - textSize.width / 2,
            y: rect.midY - textSize.height / 2
        )
        text.draw(at: point, withAttributes: attributes)
    }

    // MARK: - Helper Methods

    /// Returns the appropriate foreground color for menu bar icons based on appearance
    /// This is needed because NSColor.labelColor doesn't resolve correctly in image drawing contexts
    private func menuBarForegroundColor(isDarkMode: Bool) -> NSColor {
        return isDarkMode ? .white : .black
    }

    private func getColorForStatusLevel(_ level: UsageStatusLevel) -> NSColor {
        switch level {
        case .safe:
            return NSColor.systemGreen
        case .moderate:
            return NSColor.systemOrange
        case .critical:
            return NSColor.systemRed
        }
    }

    /// Returns the appropriate color based on the color mode setting
    /// - Parameters:
    ///   - colorMode: The color mode to use
    ///   - statusLevel: The usage status level (for multi-color mode)
    ///   - singleColorHex: The custom hex color (for single color mode)
    ///   - isDarkMode: Whether the menu bar is in dark mode
    /// - Returns: The color to use for rendering
    private func getColorForMode(_ colorMode: MenuBarColorMode, statusLevel: UsageStatusLevel, singleColorHex: String, isDarkMode: Bool) -> NSColor {
        switch colorMode {
        case .multiColor:
            return getColorForStatusLevel(statusLevel)
        case .monochrome:
            return menuBarForegroundColor(isDarkMode: isDarkMode)
        case .singleColor:
            return NSColor(hex: singleColorHex) ?? NSColor.systemBlue
        }
    }

    /// Returns the appropriate color based on mode settings
    /// - Parameters:
    ///   - status: The usage status level
    ///   - monochromeMode: If true, return foreground color based on isDarkMode
    ///   - useSystemColor: If true, return foreground color (same as monochrome)
    ///   - isDarkMode: Whether the menu bar is in dark mode
    /// - Returns: The color to use for rendering
    private func getColor(for status: UsageStatusLevel, monochromeMode: Bool, useSystemColor: Bool, isDarkMode: Bool) -> NSColor {
        if monochromeMode || useSystemColor {
            return menuBarForegroundColor(isDarkMode: isDarkMode)
        } else {
            return getColorForStatusLevel(status)
        }
    }

    /// Draws a pace-colored tick mark. When showPaceMarker is on and pace data is available,
    /// the tick color reflects the 6-tier pace urgency (green→purple) regardless of color mode.
    /// Otherwise falls back to the menu bar foreground color (current upstream behavior).
    private func drawPaceMarkerTick(
        _ path: NSBezierPath,
        paceStatus: PaceStatus?,
        showPaceMarker: Bool,
        isDarkMode: Bool
    ) {
        let color: NSColor
        if showPaceMarker, let pace = paceStatus {
            color = pace.color
        } else {
            color = menuBarForegroundColor(isDarkMode: isDarkMode)
        }
        color.setStroke()
        path.lineWidth = 2.0
        path.lineCapStyle = .round
        path.stroke()
    }

    /// Calculates the time marker fraction for a given metric type
    private func calculateTimeMarkerFraction(
        metricType: MenuBarMetricType,
        usage: ClaudeUsage,
        showRemaining: Bool
    ) -> CGFloat? {
        let resetTime: Date?
        let duration: TimeInterval

        switch metricType {
        case .session:
            resetTime = usage.sessionResetTime
            duration = Constants.sessionWindow
        case .week:
            resetTime = usage.weeklyResetTime
            duration = Constants.weeklyWindow
        case .api:
            return nil
        }

        guard let f = UsageStatusCalculator.elapsedFraction(
            resetTime: resetTime,
            duration: duration,
            showRemaining: showRemaining
        ) else { return nil }
        return CGFloat(f)
    }

}
