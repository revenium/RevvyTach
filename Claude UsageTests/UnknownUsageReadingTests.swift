//
//  UnknownUsageReadingTests.swift
//  Claude UsageTests
//
//  Created by Claude Code on 2026-08-24.
//

import AppKit
import UsageCore
import XCTest
@testable import Claude_Usage

/// One invariant, tested from the parser up to the pixels: an unknown must
/// never render as a reassuring known.
///
/// The two tests that matter most here are
/// `testMissingFiveHourWindowIsDistinguishableFromMeasuredZero` and
/// `testNeverLoadedProfileRendersDifferentlyFromZeroPercentProfile`. Before
/// this change a usage response with no `five_hour` window and a response
/// reporting `five_hour` at 0% produced byte-identical results all the way to
/// the menu bar image, so "we could not read your usage" and "you have used
/// nothing" were the same green pixels.
@MainActor
final class UnknownUsageReadingTests: HostedAppTestCase {

    // MARK: - Parsing

    func testMissingFiveHourWindowIsDistinguishableFromMeasuredZero() {
        let withoutWindow: [String: Any] = ["seven_day": ["utilization": 40]]
        let withZeroWindow: [String: Any] = [
            "five_hour": ["utilization": 0],
            "seven_day": ["utilization": 40]
        ]

        let missing = UsageLimitParsing.parsePrimaryWindow(
            from: withoutWindow,
            key: "five_hour"
        )
        let measuredZero = UsageLimitParsing.parsePrimaryWindow(
            from: withZeroWindow,
            key: "five_hour"
        )

        XCTAssertNil(
            missing.percentage,
            "A response with no five_hour window must not report a figure."
        )
        XCTAssertFalse(missing.isAvailable)
        XCTAssertEqual(measuredZero.percentage, 0)
        XCTAssertTrue(
            measuredZero.isAvailable,
            "A reported 0% is a reading and must stay one."
        )
        XCTAssertNotEqual(
            missing,
            measuredZero,
            "The whole point: absent and zero must not be the same value."
        )
    }

    func testMissingSevenDayWindowIsDistinguishableFromMeasuredZero() {
        let missing = UsageLimitParsing.parsePrimaryWindow(
            from: ["five_hour": ["utilization": 10]],
            key: "seven_day"
        )
        let measuredZero = UsageLimitParsing.parsePrimaryWindow(
            from: ["seven_day": ["utilization": 0]],
            key: "seven_day"
        )

        XCTAssertFalse(missing.isAvailable)
        XCTAssertTrue(measuredZero.isAvailable)
        XCTAssertEqual(measuredZero.percentage, 0)
    }

    func testWindowPresentButWithoutUtilizationIsUnavailable() {
        // The window exists and carries only a reset time. There is still no
        // figure, so there is still nothing to display as a percentage.
        let window = UsageLimitParsing.parsePrimaryWindow(
            from: ["five_hour": ["resets_at": "2026-08-24T12:00:00Z"]],
            key: "five_hour"
        )
        XCTAssertFalse(window.isAvailable)
        XCTAssertNotNil(window.resetTime)
    }

    /// A present-but-garbage `utilization` must be treated the same as a
    /// missing one, not as a measured zero. This is the present-but-unusable
    /// case the missing-key tests above don't cover: an explicit JSON `null`
    /// (`JSONSerialization` hands that back as `NSNull`, not an absent key),
    /// a non-numeric string, a value of the wrong type entirely, and a
    /// non-finite number all had the same bug — `parseUtilization`'s
    /// fallback-to-zero made every one of them read as "0% used".
    func testUnparseableUtilizationIsUnavailableRatherThanZero() {
        let cases: [(name: String, utilization: Any)] = [
            ("explicit null", NSNull()),
            ("non-numeric string", "not-a-number"),
            ("wrong type (array)", [1, 2, 3]),
            ("non-finite", Double.nan)
        ]

        for testCase in cases {
            let window = UsageLimitParsing.parsePrimaryWindow(
                from: ["five_hour": ["utilization": testCase.utilization]],
                key: "five_hour"
            )
            XCTAssertNil(
                window.percentage,
                "\(testCase.name) must not report a figure."
            )
            XCTAssertFalse(
                window.isAvailable,
                "\(testCase.name) must not be reported as available."
            )
        }
    }

    /// A genuine zero must survive this same path, in both its numeric and
    /// string forms — the fix above must not overcorrect into treating every
    /// zero as unavailable.
    func testGenuineZeroUtilizationStillReadsAsAvailable() {
        let numericZero = UsageLimitParsing.parsePrimaryWindow(
            from: ["five_hour": ["utilization": 0]],
            key: "five_hour"
        )
        let stringZero = UsageLimitParsing.parsePrimaryWindow(
            from: ["five_hour": ["utilization": "0%"]],
            key: "five_hour"
        )

        XCTAssertEqual(numericZero.percentage, 0)
        XCTAssertTrue(numericZero.isAvailable)
        XCTAssertEqual(stringZero.percentage, 0)
        XCTAssertTrue(stringZero.isAvailable)
    }

    // MARK: - Model

    func testEmptyUsageReportsNoReadingForEitherWindow() {
        let empty = ClaudeUsage.empty
        XCTAssertFalse(empty.sessionPercentageAvailable)
        XCTAssertFalse(empty.weeklyPercentageAvailable)
        XCTAssertNil(empty.readableSessionPercentage)
        XCTAssertNil(empty.readableWeeklyPercentage)
    }

    func testReadablePercentagesSurviveARealZero() {
        var usage = ClaudeUsage.empty
        usage.sessionPercentageAvailable = true
        usage.weeklyPercentageAvailable = true
        usage.sessionResetTime = Date().addingTimeInterval(3_600)

        XCTAssertEqual(usage.readableSessionPercentage, 0)
        XCTAssertEqual(usage.readableWeeklyPercentage, 0)
    }

    func testCachedSnapshotWithoutTheFlagsTreatsAZeroAsUnknown() throws {
        // A snapshot written before the flags existed cannot say whether its
        // zero was received or invented, so a zero decodes as unknown while a
        // real figure decodes as known.
        func decode(sessionPercentage: Double) throws -> ClaudeUsage {
            let json = """
            {
                "sessionTokensUsed": 0,
                "sessionLimit": 0,
                "sessionPercentage": \(sessionPercentage),
                "sessionResetTime": 800000000,
                "weeklyTokensUsed": 0,
                "weeklyLimit": 1000000,
                "weeklyPercentage": \(sessionPercentage),
                "weeklyResetTime": 800000000,
                "opusWeeklyTokensUsed": 0,
                "opusWeeklyPercentage": 0,
                "sonnetWeeklyTokensUsed": 0,
                "sonnetWeeklyPercentage": 0,
                "fableWeeklyTokensUsed": 0,
                "fableWeeklyPercentage": 0,
                "lastUpdated": 800000000,
                "userTimezone": {"identifier": "UTC"}
            }
            """
            return try JSONDecoder().decode(
                ClaudeUsage.self,
                from: Data(json.utf8)
            )
        }

        let zero = try decode(sessionPercentage: 0)
        XCTAssertFalse(zero.sessionPercentageAvailable)
        XCTAssertFalse(zero.weeklyPercentageAvailable)

        let real = try decode(sessionPercentage: 37)
        XCTAssertTrue(real.sessionPercentageAvailable)
        XCTAssertTrue(real.weeklyPercentageAvailable)
    }

    func testAvailabilityFlagsRoundTripThroughCoding() throws {
        var usage = ClaudeUsage.empty
        usage.sessionPercentageAvailable = true
        usage.weeklyPercentageAvailable = false

        let decoded = try JSONDecoder().decode(
            ClaudeUsage.self,
            from: try JSONEncoder().encode(usage)
        )
        XCTAssertTrue(decoded.sessionPercentageAvailable)
        XCTAssertFalse(
            decoded.weeklyPercentageAvailable,
            "An explicitly stored false must not be re-derived from the "
                + "percentage on the way back in."
        )
    }

    // MARK: - Normalized report

    func testUnreadWindowsReachTheReportAsNoMeasurement() throws {
        let report = try ClaudeUsageProviderAdapter.makeReport(
            from: .empty,
            context: ClaudeUsageProviderContext(
                health: ProviderHealth(status: .healthy, checkedAt: Date()),
                fetchedAt: Date()
            )
        )
        let windows = try XCTUnwrap(report.limitGroups.first).windows
        XCTAssertEqual(windows.count, 2)
        for window in windows {
            XCTAssertNil(
                window.usedPercentage,
                "\(window.id.rawValue) had no reading, so the popover must "
                    + "print no percentage and draw no bar for it."
            )
        }
    }

    func testMeasuredZeroReachesTheReportAsZero() throws {
        var usage = ClaudeUsage.empty
        usage.sessionPercentageAvailable = true
        usage.weeklyPercentageAvailable = true
        usage.sessionResetTime = Date().addingTimeInterval(3_600)

        let report = try ClaudeUsageProviderAdapter.makeReport(
            from: usage,
            context: ClaudeUsageProviderContext(
                health: ProviderHealth(status: .healthy, checkedAt: Date()),
                fetchedAt: Date()
            )
        )
        let windows = try XCTUnwrap(report.limitGroups.first).windows
        XCTAssertEqual(windows.map(\.usedPercentage), [0, 0])
    }

    // MARK: - Account health

    private func health(
        for usage: ClaudeUsage,
        base: ProviderHealthStatus = .healthy
    ) -> ProviderHealth {
        ClaudeUsageProviderAdapter.accountHealth(
            from: usage,
            base: ProviderHealth(status: base, checkedAt: Date())
        )
    }

    private func fullyReadUsage() -> ClaudeUsage {
        var usage = ClaudeUsage.empty
        usage.sessionPercentageAvailable = true
        usage.weeklyPercentageAvailable = true
        return usage
    }

    func testAFullyReadAccountIsHealthy() {
        XCTAssertEqual(health(for: fullyReadUsage()).status, .healthy)
    }

    func testAnAccountWithNoCapacityReadingIsNotHealthy() {
        // The report carries no usable figure at all, so this is not a
        // partial answer — it is no answer.
        XCTAssertEqual(health(for: .empty).status, .unavailable)
    }

    func testOneMissingWindowIsPartialRatherThanFine() {
        var usage = fullyReadUsage()
        usage.weeklyPercentageAvailable = false
        XCTAssertEqual(health(for: usage).status, .degraded)
    }

    /// The state from the screenshot that started this: claude.ai answers
    /// fine, the Claude Code sign-in is functionally dead, and the header
    /// reported nothing but Anthropic's public service status.
    func testABrokenClaudeCodeSignInDegradesAccountHealth() {
        for issue in [
            ClaudeUsage.PersonalExtraUsageIssue.signInExpired,
            .signInHasNoToken,
            .signInUnusable,
            .claudeAccountUnresolved
        ] {
            var usage = fullyReadUsage()
            usage.personalExtraUsageIssue = issue
            XCTAssertEqual(
                health(for: usage).status,
                .degraded,
                "\(issue) leaves a connection that exists and is broken, so "
                    + "the account is not in good order."
            )
        }
    }

    func testAnUnconnectedOrForeignAccountIsNotReportedAsBroken() {
        // Nothing is broken in either: one was never connected, the other is
        // a settled fact about a separate account. Reporting them as degraded
        // would leave a permanent complaint on a correct configuration.
        for issue in [
            ClaudeUsage.PersonalExtraUsageIssue.notLinked,
            .differentOrganization
        ] {
            var usage = fullyReadUsage()
            usage.personalExtraUsageIssue = issue
            XCTAssertEqual(
                health(for: usage).status,
                .healthy,
                "\(issue) must not read as a fault."
            )
        }
    }

    func testAFailedExtraUsageLookupDegradesAccountHealth() {
        var usage = fullyReadUsage()
        usage.organizationExtraUsageIssue = .lookupFailed
        XCTAssertEqual(health(for: usage).status, .degraded)

        var notEnabled = fullyReadUsage()
        notEnabled.organizationExtraUsageIssue = .notEnabled
        XCTAssertEqual(
            health(for: notEnabled).status,
            .healthy,
            "Extra usage being switched off is not a fault."
        )
    }

    func testAccountHealthOnlyEverLowersTheCallersVerdict() {
        // A transport-level failure stays one; this mapping must never
        // promote it just because the record happens to look complete.
        for base in [
            ProviderHealthStatus.unauthenticated,
            .unavailable,
            .unsupported,
            .degraded
        ] {
            XCTAssertEqual(
                health(for: fullyReadUsage(), base: base).status,
                base,
                "\(base) was overwritten."
            )
        }
    }

    func testTheReportCarriesTheDerivedHealthRatherThanAnAssumedOne() throws {
        var usage = fullyReadUsage()
        usage.personalExtraUsageIssue = .signInExpired

        let report = try ClaudeUsageProviderAdapter.makeReport(
            from: usage,
            context: ClaudeUsageProviderContext(
                health: ProviderHealth(status: .healthy, checkedAt: Date()),
                fetchedAt: Date()
            )
        )
        XCTAssertEqual(report.health.status, .degraded)
        XCTAssertEqual(report.health.issue, .authenticationRequired)
    }

    // MARK: - Age of the figures

    func testAgeIsRelativeAndCompact() {
        let now = Date()
        XCTAssertEqual(
            NormalizedUsageFormatter.age(
                now.addingTimeInterval(-30),
                now: now
            ),
            "as of just now"
        )
        XCTAssertEqual(
            NormalizedUsageFormatter.age(
                now.addingTimeInterval(-4 * 60),
                now: now
            ),
            "as of 4m ago"
        )
        XCTAssertEqual(
            NormalizedUsageFormatter.age(
                now.addingTimeInterval(-((3 * 60) + 5) * 60),
                now: now
            ),
            "as of 3h 5m ago"
        )
        XCTAssertEqual(
            NormalizedUsageFormatter.age(
                now.addingTimeInterval(-2 * 24 * 3_600),
                now: now
            ),
            "as of 2d ago"
        )
    }

    func testTheAgeShownIsWhenTheFiguresWereRead() throws {
        let read = Date(timeIntervalSince1970: 1_700_000_000)
        var usage = ClaudeUsage.empty
        usage.sessionPercentageAvailable = true
        usage.weeklyPercentageAvailable = true
        usage.lastUpdated = read

        let report = try ClaudeUsageProviderAdapter.makeReport(
            from: usage,
            context: ClaudeUsageProviderContext(
                health: ProviderHealth(status: .healthy, checkedAt: Date()),
                fetchedAt: read.addingTimeInterval(5)
            )
        )
        XCTAssertEqual(
            report.sourceUpdatedAt,
            read,
            "The age must come from when the figures were read, not from "
                + "whenever the popover happens to be looking at them."
        )
    }

    // MARK: - Menu bar

    private func neverLoadedProfile() -> Profile {
        Profile(name: "Test")
    }

    private func zeroPercentProfile() -> Profile {
        var usage = ClaudeUsage.empty
        usage.sessionPercentageAvailable = true
        usage.weeklyPercentageAvailable = true
        usage.sessionResetTime = Date().addingTimeInterval(3_600)
        var profile = Profile(name: "Test")
        profile.claudeUsage = usage
        return profile
    }

    private func maximumRasterAlpha(in image: NSImage) throws -> CGFloat {
        var proposedRect = NSRect(origin: .zero, size: image.size)
        let source = try XCTUnwrap(
            image.cgImage(
                forProposedRect: &proposedRect,
                context: nil,
                hints: nil
            )
        )
        let bytesPerRow = source.width * 4
        var pixels = [UInt8](
            repeating: 0,
            count: bytesPerRow * source.height
        )
        try pixels.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(
                CGContext(
                    data: storage.baseAddress,
                    width: source.width,
                    height: source.height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            )
            context.clear(
                CGRect(x: 0, y: 0, width: source.width, height: source.height)
            )
            context.draw(
                source,
                in: CGRect(
                    x: 0,
                    y: 0,
                    width: source.width,
                    height: source.height
                )
            )
        }
        let maximum = stride(from: 3, to: pixels.count, by: 4)
            .map { pixels[$0] }
            .max() ?? 0
        return CGFloat(maximum) / 255
    }

    func testLegacySingleProfileMetricsDistinguishUnreadFromMeasuredZero()
        throws
    {
        let renderer = MenuBarIconRenderer()
        let globalConfig = MenuBarIconConfiguration(
            colorMode: .monochrome,
            showIconNames: false,
            showTimeMarker: false,
            showPaceMarker: false,
            usePaceColoring: false
        )
        let unread = ClaudeUsage.empty

        func render(
            _ usage: ClaudeUsage,
            metric: MenuBarMetricType,
            style: MenuBarIconStyle
        ) -> NSImage {
            renderer.createImage(
                for: metric,
                config: MetricIconConfig(
                    metricType: metric,
                    isEnabled: true,
                    iconStyle: style
                ),
                globalConfig: globalConfig,
                usage: usage,
                apiUsage: nil,
                isDarkMode: false,
                colorMode: globalConfig.colorMode,
                singleColorHex: globalConfig.singleColorHex,
                showIconName: globalConfig.showIconNames,
                showNextSessionTime: false
            )
        }

        XCTAssertFalse(unread.sessionPercentageAvailable)
        XCTAssertFalse(unread.weeklyPercentageAvailable)
        for metric in [MenuBarMetricType.session, .week] {
            var measuredZero = ClaudeUsage.empty
            if metric == .session {
                measuredZero.sessionPercentageAvailable = true
                XCTAssertEqual(measuredZero.sessionPercentage, 0)
                XCTAssertTrue(measuredZero.sessionPercentageAvailable)
                XCTAssertFalse(measuredZero.weeklyPercentageAvailable)
            } else {
                measuredZero.weeklyPercentageAvailable = true
                XCTAssertEqual(measuredZero.weeklyPercentage, 0)
                XCTAssertTrue(measuredZero.weeklyPercentageAvailable)
                XCTAssertFalse(measuredZero.sessionPercentageAvailable)
            }

            for style in [MenuBarIconStyle.battery, .percentageOnly] {
                let unreadImage = render(unread, metric: metric, style: style)
                let zeroImage = render(
                    measuredZero,
                    metric: metric,
                    style: style
                )
                XCTAssertNotEqual(
                    try XCTUnwrap(
                        StatusBarUIManager.imageFingerprint(unreadImage)
                    ),
                    try XCTUnwrap(
                        StatusBarUIManager.imageFingerprint(zeroImage)
                    ),
                    "\(metric) \(style): the legacy single-profile icon "
                        + "must not render unread usage as a measured 0%."
                )
                let unreadAlpha = try maximumRasterAlpha(in: unreadImage)
                let measuredZeroAlpha = try maximumRasterAlpha(in: zeroImage)
                XCTAssertEqual(
                    unreadAlpha,
                    0.55,
                    accuracy: 0.08,
                    "\(metric) \(style): the unknown dash must use the "
                        + "established dimmed treatment."
                )
                XCTAssertGreaterThan(
                    measuredZeroAlpha,
                    unreadAlpha + 0.25,
                    "\(metric) \(style): a genuine measured 0% must remain "
                        + "more opaque than unknown."
                )
            }
        }
    }

    func testLegacySingleProfileBarsDoNotFabricateProportionalFill()
        throws
    {
        let renderer = MenuBarIconRenderer()
        let styles: [MenuBarIconStyle] = [.battery, .progressBar, .icon]

        func fixtures(
            for metric: MenuBarMetricType,
            sessionResetTime: Date? = nil
        ) -> (unread: ClaudeUsage, measuredZero: ClaudeUsage) {
            var unread = ClaudeUsage.empty
            if let sessionResetTime {
                unread.sessionResetTime = sessionResetTime
            }
            var measuredZero = unread
            if metric == .session {
                measuredZero.sessionPercentageAvailable = true
            } else {
                measuredZero.weeklyPercentageAvailable = true
            }
            return (unread, measuredZero)
        }

        func fingerprint(
            _ usage: ClaudeUsage,
            metric: MenuBarMetricType,
            style: MenuBarIconStyle,
            showRemaining: Bool,
            showNextSessionTime: Bool
        ) throws -> Data {
            let globalConfig = MenuBarIconConfiguration(
                colorMode: .monochrome,
                showIconNames: true,
                showRemainingPercentage: showRemaining,
                showTimeMarker: false,
                showPaceMarker: false,
                usePaceColoring: false
            )
            let image = renderer.createImage(
                for: metric,
                config: MetricIconConfig(
                    metricType: metric,
                    isEnabled: true,
                    iconStyle: style,
                    showNextSessionTime: showNextSessionTime
                ),
                globalConfig: globalConfig,
                usage: usage,
                apiUsage: nil,
                isDarkMode: false,
                colorMode: globalConfig.colorMode,
                singleColorHex: globalConfig.singleColorHex,
                showIconName: true,
                showNextSessionTime: showNextSessionTime
            )
            return try XCTUnwrap(
                StatusBarUIManager.imageFingerprint(image)
            )
        }

        // A: labels replace percentage text, so the bar itself must expose
        // the difference between no reading and a measured zero.
        for metric in [MenuBarMetricType.session, .week] {
            let pair = fixtures(for: metric)
            for style in styles {
                XCTAssertNotEqual(
                    try fingerprint(
                        pair.unread,
                        metric: metric,
                        style: style,
                        showRemaining: false,
                        showNextSessionTime: false
                    ),
                    try fingerprint(
                        pair.measuredZero,
                        metric: metric,
                        style: style,
                        showRemaining: false,
                        showNextSessionTime: false
                    ),
                    "\(metric) \(style): an unread bar must not look like "
                        + "a measured 0% bar when its label is visible."
                )
            }
        }

        // B: a reset label must not hide the same distinction.
        let resetPair = fixtures(
            for: .session,
            sessionResetTime: Date().addingTimeInterval(7_200)
        )
        for style in styles {
            XCTAssertNotEqual(
                try fingerprint(
                    resetPair.unread,
                    metric: .session,
                    style: style,
                    showRemaining: false,
                    showNextSessionTime: true
                ),
                try fingerprint(
                    resetPair.measuredZero,
                    metric: .session,
                    style: style,
                    showRemaining: false,
                    showNextSessionTime: true
                ),
                "\(style): a reset label must not make an unread session "
                    + "bar look like measured 0%."
            )
        }

        // C: unknown has no direction to invert. Known zero, by contrast,
        // legitimately becomes a full bar in remaining mode.
        for metric in [MenuBarMetricType.session, .week] {
            let pair = fixtures(for: metric)
            for style in styles {
                let unreadRemaining = try fingerprint(
                    pair.unread,
                    metric: metric,
                    style: style,
                    showRemaining: true,
                    showNextSessionTime: false
                )
                XCTAssertEqual(
                    try fingerprint(
                        pair.unread,
                        metric: metric,
                        style: style,
                        showRemaining: false,
                        showNextSessionTime: false
                    ),
                    unreadRemaining,
                    "\(metric) \(style): unknown must render identically "
                        + "in used and remaining modes."
                )
                XCTAssertNotEqual(
                    unreadRemaining,
                    try fingerprint(
                        pair.measuredZero,
                        metric: metric,
                        style: style,
                        showRemaining: true,
                        showNextSessionTime: false
                    ),
                    "\(metric) \(style): unknown must not look like the "
                        + "legitimate 100% remaining state."
                )
            }
        }
    }

    func testNeverLoadedProfileRendersDifferentlyFromZeroPercentProfile() {
        let manager = retain(StatusBarUIManager())
        defer { manager.cleanup() }

        for style in MultiProfileIconStyle.allCases {
            let config = MultiProfileDisplayConfig(iconStyle: style)
            let unread = manager.renderProfileMenuBar(
                for: neverLoadedProfile(),
                config: config,
                isDarkMode: false,
                isActive: false
            )
            let measuredZero = manager.renderProfileMenuBar(
                for: zeroPercentProfile(),
                config: config,
                isDarkMode: false,
                isActive: false
            )

            XCTAssertEqual(
                unread.unknownWindows,
                [.session, .week],
                "\(style): a profile that never fetched has no reading for "
                    + "either window."
            )
            XCTAssertEqual(
                measuredZero.unknownWindows,
                [],
                "\(style): a reported 0% is a reading."
            )
            XCTAssertNotEqual(
                unread.image.tiffRepresentation,
                measuredZero.image.tiffRepresentation,
                "\(style): the two states render to identical pixels, so a "
                    + "glance at the menu bar cannot tell them apart."
            )
        }
    }

    func testUnreadWindowNeverWidensTheMenuBarItem() {
        // The menu bar has real width constraints and an overflow planner
        // that budgets from these widths, so the unknown form must not be
        // wider than the figure it replaces.
        let manager = retain(StatusBarUIManager())
        defer { manager.cleanup() }

        for style in MultiProfileIconStyle.allCases {
            let config = MultiProfileDisplayConfig(iconStyle: style)
            let unread = manager.renderProfileMenuBar(
                for: neverLoadedProfile(),
                config: config,
                isDarkMode: false,
                isActive: false
            ).image.size.width
            let widest = manager.renderProfileMenuBar(
                for: {
                    var profile = zeroPercentProfile()
                    profile.claudeUsage?.sessionPercentage = 100
                    profile.claudeUsage?.weeklyPercentage = 100
                    return profile
                }(),
                config: config,
                isDarkMode: false,
                isActive: false
            ).image.size.width

            XCTAssertLessThanOrEqual(
                unread,
                widest,
                "\(style): the no-reading render is wider than a full "
                    + "three-digit reading, which would disturb the "
                    + "multi-profile layout."
            )
        }
    }

    func testAccessibilityLabelSaysNoReadingRatherThanZeroPercent() {
        let manager = retain(StatusBarUIManager())
        defer { manager.cleanup() }
        let config = MultiProfileDisplayConfig(iconStyle: .percentage)

        let unread = manager.renderProfileMenuBar(
            for: neverLoadedProfile(),
            config: config,
            isDarkMode: false,
            isActive: false
        )
        let measuredZero = manager.renderProfileMenuBar(
            for: zeroPercentProfile(),
            config: config,
            isDarkMode: false,
            isActive: false
        )

        let unreadValue = StatusBarUIManager.sessionAccessibilityValue(
            for: unread
        )
        let zeroValue = StatusBarUIManager.sessionAccessibilityValue(
            for: measuredZero
        )

        XCTAssertFalse(
            unreadValue.contains("0%"),
            "VoiceOver must not read a fabricated 0% where the image shows "
                + "a dash. Got: \(unreadValue)"
        )
        XCTAssertTrue(zeroValue.contains("0%"))
        XCTAssertNotEqual(unreadValue, zeroValue)
    }
}
