import UsageCore
import XCTest
@testable import Claude_Usage

@MainActor
final class NormalizedUsagePresentationTests: HostedAppTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testClaudeStatusURLPointsAtStatusPage() {
        XCTAssertEqual(
            ProviderPopoverHeader.claudeStatusURL.absoluteString,
            "https://status.claude.com"
        )
    }

    func testCompactPercentageTextOmitsQualifierWord() {
        XCTAssertEqual(
            NormalizedUsageFormatter.compactPercentageText(
                usedPercentage: 78,
                showRemaining: false
            ),
            "78%"
        )
        XCTAssertEqual(
            NormalizedUsageFormatter.compactPercentageText(
                usedPercentage: 25,
                showRemaining: true
            ),
            "75%"
        )
        XCTAssertEqual(
            NormalizedUsageFormatter.percentageText(
                usedPercentage: 78,
                showRemaining: false
            ),
            "78% used"
        )
    }

    func testRefreshFailureBannerDetailIsNeverEmptyForAnyFailureKind()
        throws
    {
        // The refresh-failure banner's chevron only ever appears when it
        // will reveal real content; assert every failure kind (including
        // "no failure captured yet", i.e. nil) produces a distinct,
        // non-empty explanation rather than silently falling through.
        let allKinds: [ProviderRefreshFailureKind?] = [
            .disabled, .unlinked, .dependencyMissing,
            .unauthenticated, .unsupportedAccount,
            .invalidConfiguration, .transport, .protocolMismatch,
            .malformedResponse, .timedOut, .persistence,
            .rateLimited, .serverError, .unknown,
            nil
        ]
        for kind in allKinds {
            let explanation = LegacyPopoverBannerDetail.explanation(
                for: kind
            )
            XCTAssertFalse(
                explanation.isEmpty,
                "Expected non-empty explanation for \(String(describing: kind))"
            )
        }

        XCTAssertEqual(
            LegacyPopoverBannerDetail.explanation(for: .unauthenticated),
            "popover.normalized.notice.unauthenticated".localized
        )
        XCTAssertEqual(
            LegacyPopoverBannerDetail.explanation(for: .timedOut),
            "popover.normalized.notice.refresh_failed".localized
        )
        XCTAssertEqual(
            LegacyPopoverBannerDetail.explanation(for: nil),
            "popover.normalized.notice.refresh_failed".localized
        )
        XCTAssertEqual(
            LegacyPopoverBannerDetail.explanation(for: .rateLimited),
            "popover.normalized.notice.rate_limited".localized
        )
        XCTAssertEqual(
            LegacyPopoverBannerDetail.explanation(for: .serverError),
            "popover.normalized.notice.server_error".localized
        )
    }

    /// 429 and 5xx failures get their own retry-oriented copy rather than
    /// falling into the generic "refresh failed" bucket every other
    /// recoverable-but-uninteresting kind (transport, timeout, ...) shares.
    func testRateLimitedAndServerErrorNoticesUseDistinctVocabulary()
        throws
    {
        let cachedReport = try makeReport()

        let rateLimited = makePresentation(
            report: cachedReport,
            failure: ProviderRefreshFailure(
                kind: .rateLimited,
                occurredAt: now,
                isRecoverable: true,
                consecutiveCount: 1,
                retryAfter: 30
            )
        )
        let refreshFailedNotice = rateLimited.notices.first {
            $0.kind == .refreshFailed
        }
        XCTAssertEqual(
            refreshFailedNotice?.localizationKey,
            NormalizedUsageFailureVocabulary.rateLimited.key
        )
        XCTAssertEqual(
            refreshFailedNotice?.defaultMessage,
            NormalizedUsageFailureVocabulary.rateLimited.default
        )

        let serverError = makePresentation(
            report: cachedReport,
            failure: ProviderRefreshFailure(
                kind: .serverError,
                occurredAt: now,
                isRecoverable: true,
                consecutiveCount: 1
            )
        )
        let serverErrorNotice = serverError.notices.first {
            $0.kind == .refreshFailed
        }
        XCTAssertEqual(
            serverErrorNotice?.localizationKey,
            NormalizedUsageFailureVocabulary.serverError.key
        )
        XCTAssertEqual(
            serverErrorNotice?.defaultMessage,
            NormalizedUsageFailureVocabulary.serverError.default
        )

        // A kind with no dedicated vocabulary (e.g. transport) still falls
        // back to the generic copy, proving the switch is additive rather
        // than having silently dropped the default case.
        let transport = makePresentation(
            report: cachedReport,
            failure: ProviderRefreshFailure(
                kind: .transport,
                occurredAt: now,
                isRecoverable: true,
                consecutiveCount: 1
            )
        )
        XCTAssertEqual(
            transport.notices.first { $0.kind == .refreshFailed }?
                .localizationKey,
            NormalizedUsageFailureVocabulary.refreshFailed.key
        )
    }

    func testRetryTextOmittedWithoutKnownRetryTimeAndFormattedWhenKnown() {
        XCTAssertNil(
            LegacyPopoverBannerDetail.retryText(nil, formatted: { _ in
                "unused"
            })
        )
        let retryAt = now.addingTimeInterval(60)
        XCTAssertEqual(
            LegacyPopoverBannerDetail.retryText(retryAt) { date in
                XCTAssertEqual(date, retryAt)
                return "3:04 PM"
            },
            "Retrying at 3:04 PM"
        )
    }

    func testTechnicalDetailTextFormatsWhenKnownAndNilWhenAbsent() {
        XCTAssertNil(
            LegacyPopoverBannerDetail.technicalDetailText(nil)
        )
        XCTAssertEqual(
            LegacyPopoverBannerDetail.technicalDetailText(
                "HTTP 429 — Rate limited by Claude API"
            ),
            "Details: HTTP 429 — Rate limited by Claude API"
        )
    }

    /// `ProviderRefreshFailure.retryNotBefore` is the wiring between a
    /// server's `Retry-After` hint and the UI's "Retrying at" line: it must
    /// be derived from `occurredAt + retryAfter`, and stay nil without one.
    func testRetryNotBeforeDerivesFromOccurredAtAndRetryAfter() {
        let noHint = ProviderRefreshFailure(
            kind: .transport,
            occurredAt: now,
            isRecoverable: true,
            consecutiveCount: 1
        )
        XCTAssertNil(noHint.retryNotBefore)

        let withHint = ProviderRefreshFailure(
            kind: .rateLimited,
            occurredAt: now,
            isRecoverable: true,
            consecutiveCount: 1,
            retryAfter: 90
        )
        XCTAssertEqual(
            withHint.retryNotBefore,
            now.addingTimeInterval(90)
        )
    }

    /// The legacy expandable banner's failure explanations must be
    /// single-sourced from the same vocabulary as the normalized notice
    /// list, not an independently maintained copy that can drift.
    func testLegacyBannerExplanationsReuseNormalizedNoticeVocabulary() {
        XCTAssertEqual(
            LegacyPopoverBannerDetail.explanationLocalization(
                for: .unauthenticated
            ).key,
            NormalizedUsageFailureVocabulary.unauthenticated.key
        )
        XCTAssertEqual(
            LegacyPopoverBannerDetail.explanationLocalization(
                for: .unsupportedAccount
            ).default,
            NormalizedUsageFailureVocabulary.unsupportedAccount.default
        )
        XCTAssertEqual(
            LegacyPopoverBannerDetail.explanationLocalization(
                for: .invalidConfiguration
            ).key,
            NormalizedUsageFailureVocabulary.configuration.key
        )
        XCTAssertEqual(
            LegacyPopoverBannerDetail.explanationLocalization(for: nil)
                .default,
            NormalizedUsageFailureVocabulary.refreshFailed.default
        )
    }

    func testLastSuccessTextReflectsKnownAndUnknownRefreshTime() {
        XCTAssertEqual(
            LegacyPopoverBannerDetail.lastSuccessText(
                nil,
                formatted: { _ in "unused" }
            ),
            "popover.banner.never_succeeded".localized
        )
        XCTAssertEqual(
            LegacyPopoverBannerDetail.lastSuccessText(
                now,
                formatted: { _ in "Jan 1, 2026 at 9:00 AM" }
            ),
            String(
                format: "popover.banner.last_success".localized,
                "Jan 1, 2026 at 9:00 AM"
            )
        )
    }

    func testLegacyBannerMessageFormatsCountAndMinutes() {
        XCTAssertEqual(
            LegacyPopoverBanner.refreshFailed(count: 12).message,
            String(format: "popover.banner.refresh_failed".localized, 12)
        )
        XCTAssertEqual(
            LegacyPopoverBanner.stale(minutesAgo: 7).message,
            String(format: "popover.banner.updated_ago".localized, 7)
        )
        XCTAssertEqual(
            LegacyPopoverBanner.credentialError.message,
            "popover.banner.credentials_expired".localized
        )
    }

    /// Outranks everything else: the other banners describe something
    /// already broken, this one describes something the user can still
    /// prevent — the credential is lost at quit.
    func testCredentialsNotSavedOutranksEveryOtherBanner() {
        let stale = now.addingTimeInterval(-301)

        XCTAssertEqual(
            LegacyPopoverBanner.resolve(
                sessionOnlyCredentialCount: 2,
                hasCredentialError: true,
                consecutiveRefreshFailures: 8,
                lastSuccessfulRefreshTime: stale,
                now: now
            ),
            .credentialsNotSaved(count: 2)
        )
        XCTAssertEqual(
            LegacyPopoverBanner.credentialsNotSaved(count: 2).action,
            .retryCredentialSave
        )
    }

    func testNoHeldCredentialsLeavesTheOtherBannersUntouched() {
        XCTAssertEqual(
            LegacyPopoverBanner.resolve(
                sessionOnlyCredentialCount: 0,
                hasCredentialError: true,
                consecutiveRefreshFailures: 0,
                lastSuccessfulRefreshTime: nil,
                now: now
            ),
            .credentialError
        )
        XCTAssertNil(
            LegacyPopoverBanner.resolve(
                sessionOnlyCredentialCount: 0,
                hasCredentialError: false,
                consecutiveRefreshFailures: 0,
                lastSuccessfulRefreshTime: nil,
                now: now
            )
        )
    }

    func testLegacyBannerPrecedenceThresholdsAndActions() {
        let stale = now.addingTimeInterval(-301)

        XCTAssertEqual(
            LegacyPopoverBanner.resolve(
                hasCredentialError: true,
                consecutiveRefreshFailures: 8,
                lastSuccessfulRefreshTime: stale,
                now: now
            ),
            .credentialError
        )
        // REGRESSION: this used to be `.preferences`, which opened Settings
        // with no section selected. `hasCredentialError` is reachable only
        // from the claude.ai session-key failures, so a user with a healthy
        // claude.ai key and a stale CLI login would land in Settings, re-sync
        // the CLI account, watch it succeed, and find the banner unchanged —
        // because re-syncing the CLI can never clear a claude.ai 401.
        XCTAssertEqual(
            LegacyPopoverBanner.credentialError.action,
            .claudeAIAccount
        )
        XCTAssertNotEqual(
            LegacyPopoverBanner.credentialError.action,
            .preferences
        )
        XCTAssertNil(
            LegacyPopoverBanner.resolve(
                hasCredentialError: false,
                consecutiveRefreshFailures: 2,
                lastSuccessfulRefreshTime:
                    now.addingTimeInterval(-300),
                now: now
            )
        )
        XCTAssertEqual(
            LegacyPopoverBanner.resolve(
                hasCredentialError: false,
                consecutiveRefreshFailures: 3,
                lastSuccessfulRefreshTime: stale,
                now: now
            ),
            .refreshFailed(count: 3)
        )
        XCTAssertEqual(
            LegacyPopoverBanner.refreshFailed(count: 3).action,
            .refresh
        )
        XCTAssertEqual(
            LegacyPopoverBanner.resolve(
                hasCredentialError: false,
                consecutiveRefreshFailures: 0,
                lastSuccessfulRefreshTime: stale,
                now: now
            ),
            .stale(minutesAgo: 5)
        )
        XCTAssertEqual(
            LegacyPopoverBanner.stale(minutesAgo: 5).action,
            .refresh
        )
    }

    func testDynamicGroupsPreserveReportOrderAndCompositeIdentity()
        throws
    {
        let sharedWindowID = try UsageWindowID("shared")
        let firstGroup = try UsageLimitGroup(
            id: UsageLimitGroupID("zeta"),
            displayName: "Zeta",
            windows: [
                UsageWindow(
                    id: sharedWindowID,
                    displayName: "First",
                    usedPercentage: 0
                ),
                UsageWindow(
                    id: UsageWindowID("middle"),
                    usedPercentage: 51
                ),
                UsageWindow(
                    id: UsageWindowID("last"),
                    usedPercentage: 100
                )
            ]
        )
        let secondGroup = try UsageLimitGroup(
            id: UsageLimitGroupID("alpha"),
            windows: [
                UsageWindow(
                    id: sharedWindowID,
                    usedPercentage: 25
                )
            ]
        )
        let report = try makeReport(
            groups: [firstGroup, secondGroup]
        )

        let presentation = makePresentation(report: report)

        XCTAssertEqual(
            presentation.groups.map(\.title),
            ["Zeta", "Alpha"]
        )
        XCTAssertEqual(
            presentation.groups[0].windows.map(\.title),
            ["First", "Middle", "Last"]
        )
        XCTAssertEqual(
            presentation.groups[0].windows
                .compactMap(\.usedPercentage),
            [0, 51, 100]
        )
        XCTAssertNotEqual(
            presentation.groups[0].windows[0].id,
            presentation.groups[1].windows[0].id
        )
        XCTAssertEqual(
            presentation.groups[0].windows[0]
                .accessibilityIdentifier,
            "popover.usage.window.codex.zeta.shared"
        )
        XCTAssertEqual(
            Set(
                presentation.groups.flatMap(\.windows).map(\.id)
            ).count,
            4
        )
    }

    func testAccessibilityComponentsEscapeDynamicIDsInjectively() {
        XCTAssertEqual(
            NormalizedUsageAccessibility.safeComponent("model.a"),
            "model%2Ea"
        )
        XCTAssertEqual(
            NormalizedUsageAccessibility.safeComponent("model_a"),
            "model_a"
        )
        XCTAssertNotEqual(
            NormalizedUsageAccessibility.safeComponent("model.a"),
            NormalizedUsageAccessibility.safeComponent("model_a")
        )
        XCTAssertEqual(
            NormalizedUsageAccessibility.safeComponent("a%b"),
            "a%25b"
        )
    }

    func testCoreRejectsDuplicateIDsBeforePresentation() throws {
        let window = try UsageWindow(
            id: UsageWindowID("duplicate"),
            usedPercentage: 1
        )
        XCTAssertThrowsError(
            try UsageLimitGroup(
                id: UsageLimitGroupID("group"),
                windows: [window, window]
            )
        )
        let group = try UsageLimitGroup(
            id: UsageLimitGroupID("group"),
            windows: [window]
        )
        XCTAssertThrowsError(
            try makeReport(groups: [group, group])
        )
    }

    func testProgressAndValueFormattingHandlesBoundariesAndMissing()
        throws
    {
        XCTAssertEqual(
            NormalizedUsageFormatter.progressFraction(
                usedPercentage: 0,
                showRemaining: false
            ),
            0
        )
        XCTAssertEqual(
            NormalizedUsageFormatter.progressFraction(
                usedPercentage: 100,
                showRemaining: false
            ),
            1
        )
        XCTAssertEqual(
            NormalizedUsageFormatter.progressFraction(
                usedPercentage: 150,
                showRemaining: false
            ),
            1
        )
        XCTAssertEqual(
            NormalizedUsageFormatter.percentage(
                usedPercentage: 0,
                showRemaining: true
            ),
            100
        )
        XCTAssertNil(
            NormalizedUsageFormatter.percentage(
                usedPercentage: .nan,
                showRemaining: false
            )
        )
        XCTAssertEqual(
            NormalizedUsageFormatter.progressFraction(
                usedPercentage: nil,
                showRemaining: false
            ),
            0
        )

        let quantity = try UsageQuantity(
            used: 25,
            limit: 100,
            unit: .tokens
        )
        XCTAssertTrue(
            NormalizedUsageFormatter.quantity(
                quantity,
                showRemaining: false
            ).contains("25")
        )
        XCTAssertTrue(
            NormalizedUsageFormatter.quantity(
                quantity,
                showRemaining: true
            ).contains("75")
        )
    }

    func testResetFormattingUsesProvidedClockAtAndAfterBoundary() {
        XCTAssertEqual(
            NormalizedUsageFormatter.reset(
                now,
                now: now,
                display: .remainingTime
            ),
            "Resets now"
        )
        XCTAssertEqual(
            NormalizedUsageFormatter.reset(
                now.addingTimeInterval(-1),
                now: now,
                display: .resetTime
            ),
            "Resets now"
        )
        XCTAssertTrue(
            NormalizedUsageFormatter.reset(
                now.addingTimeInterval(3_660),
                now: now,
                display: .remainingTime
            ).contains("1h 1m")
        )
    }

    func testDynamicWindowElapsedFractionHandlesResetBoundaries()
    {
        XCTAssertEqual(
            NormalizedUsageWindowIndicators.elapsedFraction(
                resetsAt: now.addingTimeInterval(100),
                duration: 100,
                now: now
            ),
            0
        )
        XCTAssertEqual(
            NormalizedUsageWindowIndicators.elapsedFraction(
                resetsAt: now.addingTimeInterval(50),
                duration: 100,
                now: now
            ),
            0.5
        )
        XCTAssertEqual(
            NormalizedUsageWindowIndicators.elapsedFraction(
                resetsAt: now,
                duration: 100,
                now: now
            ),
            1
        )
        XCTAssertEqual(
            NormalizedUsageWindowIndicators.elapsedFraction(
                resetsAt: now.addingTimeInterval(-1),
                duration: 100,
                now: now
            ),
            1
        )
        XCTAssertEqual(
            NormalizedUsageWindowIndicators.elapsedFraction(
                resetsAt: now.addingTimeInterval(200),
                duration: 100,
                now: now
            ),
            0
        )
    }

    func testDynamicWindowElapsedFractionRejectsMissingDuration() {
        XCTAssertNil(
            NormalizedUsageWindowIndicators.elapsedFraction(
                resetsAt: nil,
                duration: 100,
                now: now
            )
        )
        XCTAssertNil(
            NormalizedUsageWindowIndicators.elapsedFraction(
                resetsAt: now.addingTimeInterval(50),
                duration: nil,
                now: now
            )
        )
        for duration in [0, -1, .infinity, .nan] {
            XCTAssertNil(
                NormalizedUsageWindowIndicators.elapsedFraction(
                    resetsAt: now.addingTimeInterval(50),
                    duration: duration,
                    now: now
                )
            )
        }
    }

    func testDynamicWindowPreferencesControlMarkersAndPaceColoring() {
        let enabled = NormalizedUsageDisplayPreferences(
            showRemainingPercentage: false,
            showTimeMarker: true,
            showPaceMarker: true,
            usePaceColoring: true
        )
        let indicators = NormalizedUsageWindowIndicators.make(
            usedPercentage: 55,
            resetsAt: now.addingTimeInterval(50),
            duration: 100,
            preferences: enabled,
            now: now
        )

        XCTAssertEqual(indicators.elapsedFraction, 0.5)
        XCTAssertEqual(indicators.timeMarkerFraction, 0.5)
        XCTAssertEqual(indicators.paceStatus, .critical)
        XCTAssertEqual(indicators.statusLevel, .critical)
        XCTAssertEqual(
            indicators.paceStatus.map {
                NormalizedUsageWindowIndicators.paceSymbol(for: $0)
            },
            "!"
        )

        let disabled = NormalizedUsageDisplayPreferences(
            showRemainingPercentage: false,
            showTimeMarker: false,
            showPaceMarker: false,
            usePaceColoring: false
        )
        let baseline = NormalizedUsageWindowIndicators.make(
            usedPercentage: 55,
            resetsAt: now.addingTimeInterval(50),
            duration: 100,
            preferences: disabled,
            now: now
        )
        XCTAssertNil(baseline.timeMarkerFraction)
        XCTAssertNil(baseline.paceStatus)
        XCTAssertEqual(baseline.statusLevel, .moderate)
    }

    func testDynamicWindowRemainingMarkerAndPaceBoundary() {
        let remaining = NormalizedUsageDisplayPreferences(
            showRemainingPercentage: true,
            showTimeMarker: true,
            showPaceMarker: true,
            usePaceColoring: true
        )
        let remainingIndicators =
            NormalizedUsageWindowIndicators.make(
                usedPercentage: 20,
                resetsAt: now.addingTimeInterval(75),
                duration: 100,
                preferences: remaining,
                now: now
            )
        XCTAssertEqual(
            remainingIndicators.timeMarkerFraction,
            0.75
        )

        let belowPaceColorBoundary =
            NormalizedUsageWindowIndicators.make(
                usedPercentage: 20,
                resetsAt: now.addingTimeInterval(85.1),
                duration: 100,
                preferences: remaining,
                now: now
            )
        let atPaceColorBoundary =
            NormalizedUsageWindowIndicators.make(
                usedPercentage: 20,
                resetsAt: now.addingTimeInterval(85),
                duration: 100,
                preferences: remaining,
                now: now
            )
        XCTAssertEqual(
            belowPaceColorBoundary.statusLevel,
            .safe
        )
        XCTAssertEqual(atPaceColorBoundary.statusLevel, .critical)
    }

    func testDynamicWindowPaceMarkersHaveDistinctNonColorSymbols() {
        XCTAssertEqual(
            Set(
                PaceStatus.allCases.map {
                    NormalizedUsageWindowIndicators.paceSymbol(for: $0)
                }
            ).count,
            PaceStatus.allCases.count
        )
    }

    func testDailyBucketCalendarDateAlwaysRendersInUTC() throws {
        let midnightUTC = try XCTUnwrap(
            ISO8601DateFormatter().date(
                from: "2026-07-02T00:00:00Z"
            )
        )

        XCTAssertEqual(
            NormalizedUsageFormatter.day(
                midnightUTC,
                locale: Locale(identifier: "en_US_POSIX")
            ),
            "Jul 2"
        )
    }

    func testSummaryPreservesAbsentEmptyPartialAndDailyBuckets()
        throws
    {
        let absent = makePresentation(
            report: try makeReport(summary: nil)
        )
        XCTAssertNil(absent.summary)

        let explicitlyEmpty = try UsageSummary(
            metrics: [],
            dailyBuckets: []
        )
        let empty = makePresentation(
            report: try makeReport(summary: explicitlyEmpty)
        )
        XCTAssertEqual(empty.summary?.metrics, [])
        XCTAssertEqual(empty.summary?.dailyBuckets, [])

        let partialMetric = try UsageMetric(
            id: UsageMetricID("tokens"),
            value: 0,
            unit: .tokens
        )
        let partialSummary = try UsageSummary(
            metrics: [],
            periodStartedAt: now,
            periodEndsAt: now.addingTimeInterval(86_400),
            dailyBuckets: [
                UsageDailyBucket(
                    startedAt: now,
                    endsAt: now.addingTimeInterval(86_400),
                    metrics: [partialMetric]
                )
            ]
        )
        let partial = makePresentation(
            report: try makeReport(summary: partialSummary)
        )
        XCTAssertEqual(
            partial.summary?.dailyBuckets?.first?.metrics,
            [partialMetric]
        )
        XCTAssertEqual(partial.summary?.periodStartedAt, now)
        XCTAssertEqual(
            partial.summary?.periodEndsAt,
            now.addingTimeInterval(86_400)
        )
    }

    func testCapabilityGatesSummaryAndReadOnlyCredits() throws {
        let summary = try UsageSummary(
            metrics: [
                UsageMetric(
                    id: UsageMetricID("requests"),
                    value: 2,
                    unit: .requests
                )
            ]
        )
        let credit = try UsageCredit(
            id: UsageMetricID("reset-credit"),
            displayName: "Reset credit",
            balance: 2,
            unit: .count
        )
        let report = try makeReport(
            summary: summary,
            credits: [credit]
        )
        let available = makePresentation(report: report)
        XCTAssertEqual(available.summary?.metrics.count, 1)
        XCTAssertEqual(available.credits, [credit])

        let gated = makePresentation(
            report: report,
            capabilities: ProviderCapabilities([
                .usageLimits: .available,
                .usageSummary: .unavailable,
                .credits: .unavailable
            ])
        )
        XCTAssertNil(gated.summary)
        XCTAssertTrue(gated.credits.isEmpty)
    }

    func testLoadingStaleDegradedAndErrorPreserveCachedContent()
        throws
    {
        let group = try UsageLimitGroup(
            id: UsageLimitGroupID("cached"),
            windows: [
                UsageWindow(
                    id: UsageWindowID("primary"),
                    usedPercentage: 44
                )
            ]
        )
        let staleReport = try makeReport(
            health: ProviderHealth(
                status: .degraded,
                checkedAt: now.addingTimeInterval(-100),
                issue: .optionalUsageUnavailable
            ),
            groups: [group],
            fetchedAt: now.addingTimeInterval(-100),
            staleAt: now.addingTimeInterval(-50)
        )
        let requestID = UUID()
        let presentation = makePresentation(
            report: staleReport,
            activity: .refreshing(
                requestID: requestID,
                trigger: .manual,
                startedAt: now
            ),
            failure: ProviderRefreshFailure(
                kind: .transport,
                occurredAt: now,
                isRecoverable: true,
                consecutiveCount: 1
            )
        )

        XCTAssertNil(presentation.emptyState)
        XCTAssertEqual(presentation.groups.count, 1)
        XCTAssertEqual(
            presentation.notices.map(\.kind),
            [.loading, .stale, .degraded, .refreshFailed]
        )
    }

    func testErrorWithoutCacheProducesUnavailableState() {
        let presentation = makePresentation(
            report: nil,
            failure: ProviderRefreshFailure(
                kind: .timedOut,
                occurredAt: now,
                isRecoverable: true,
                consecutiveCount: 2
            )
        )

        XCTAssertEqual(presentation.emptyState, .unavailable)
        XCTAssertEqual(
            presentation.notices.map(\.kind),
            [.refreshFailed]
        )
    }

    func testEmptyUnsupportedAndUnsupportedCapabilityStates()
        throws
    {
        let empty = makePresentation(report: try makeReport())
        XCTAssertEqual(empty.emptyState, .empty)

        let unsupported = makePresentation(
            report: nil,
            configurationState: .unsupported
        )
        XCTAssertEqual(
            unsupported.emptyState,
            .unsupportedAccount
        )
        XCTAssertEqual(
            unsupported.healthStatus,
            .unsupported
        )

        let unauthenticated = makePresentation(
            report: nil,
            configurationState: .unauthenticated
        )
        XCTAssertEqual(
            unauthenticated.healthStatus,
            .unauthenticated
        )

        let dependencyMissing = makePresentation(
            report: nil,
            configurationState: .dependencyMissing
        )
        XCTAssertEqual(
            dependencyMissing.healthStatus,
            .unavailable
        )

        let unsupportedUsage = makePresentation(
            report: try makeReport(),
            capabilities: ProviderCapabilities([
                .usageLimits: .unavailable,
                .usageSummary: .unavailable,
                .credits: .unavailable
            ])
        )
        XCTAssertEqual(
            unsupportedUsage.emptyState,
            .unsupportedUsage
        )
    }

    func testAccountPlanAndProviderIdentityAreExplicit() throws {
        let report = try UsageReport(
            providerID: .codex,
            account: ProviderAccount(
                displayName: "person@example.com",
                planName: "Pro",
                organizationName: "Example"
            ),
            health: ProviderHealth(
                status: .healthy,
                checkedAt: now
            ),
            limitGroups: [],
            fetchedAt: now
        )
        let presentation = makePresentation(report: report)

        XCTAssertEqual(presentation.providerName, "Codex")
        XCTAssertEqual(presentation.accountName, "person@example.com")
        XCTAssertEqual(presentation.planName, "Pro")
        XCTAssertEqual(presentation.organizationName, "Example")
        XCTAssertEqual(
            presentation.providerHeaderAccessibilityIdentifier,
            "popover.provider.header.codex"
        )
        XCTAssertEqual(
            presentation.accountAccessibilityIdentifier,
            "popover.provider.account.codex"
        )
    }

    func testClickedMissingSnapshotNeverUsesAnotherProfileSnapshot()
        throws
    {
        let clickedID = UUID()
        let activeID = UUID()
        let activeReport = try makeReport(
            groups: [
                UsageLimitGroup(
                    id: UsageLimitGroupID("active-data"),
                    windows: [
                        UsageWindow(
                            id: UsageWindowID("window"),
                            usedPercentage: 99
                        )
                    ]
                )
            ]
        )
        let activeSnapshot = makeSnapshot(
            profileID: activeID,
            report: activeReport
        )

        let clicked = NormalizedUsagePresentationBuilder.make(
            snapshot: activeSnapshot,
            expectedProfile: NormalizedUsageExpectedProfile(
                id: clickedID,
                name: "Clicked",
                providerID: .codex,
                providerRevision: 1
            ),
            now: now
        )

        XCTAssertEqual(clicked.profileID, clickedID)
        XCTAssertEqual(clicked.profileName, "Clicked")
        XCTAssertEqual(clicked.emptyState, .missingSnapshot)
        XCTAssertTrue(clicked.groups.isEmpty)
        XCTAssertNil(clicked.summary)
        XCTAssertEqual(
            clicked.emptyState?.accessibilityIdentifier,
            "popover.state.missing-snapshot"
        )
    }

    func testMixedProviderMismatchFailsClosed() throws {
        let profileID = UUID()
        let codexSnapshot = makeSnapshot(
            profileID: profileID,
            providerID: .codex,
            report: try makeReport()
        )
        let presentation = NormalizedUsagePresentationBuilder.make(
            snapshot: codexSnapshot,
            expectedProfile: NormalizedUsageExpectedProfile(
                id: profileID,
                name: "Claude profile",
                providerID: .claude,
                providerRevision: 1
            ),
            now: now
        )

        XCTAssertEqual(presentation.providerID, .claude)
        XCTAssertEqual(presentation.emptyState, .missingSnapshot)
        XCTAssertTrue(presentation.groups.isEmpty)
    }

    func testProviderRevisionMismatchFailsClosedAfterRelink()
        throws
    {
        let profileID = UUID()
        let presentation = NormalizedUsagePresentationBuilder.make(
            snapshot: makeSnapshot(
                profileID: profileID,
                report: try makeReport(
                    groups: [
                        UsageLimitGroup(
                            id: UsageLimitGroupID("old-home"),
                            windows: []
                        )
                    ]
                )
            ),
            expectedProfile: NormalizedUsageExpectedProfile(
                id: profileID,
                name: "Relinked Codex",
                providerID: .codex,
                providerRevision: 2
            ),
            now: now
        )

        XCTAssertEqual(presentation.profileName, "Relinked Codex")
        XCTAssertEqual(presentation.emptyState, .missingSnapshot)
        XCTAssertTrue(presentation.groups.isEmpty)
        XCTAssertNil(presentation.accountName)
    }

    func testReportProviderMismatchFailsClosed() throws {
        let profileID = UUID()
        let mismatchedReport = try UsageReport(
            providerID: .claude,
            health: ProviderHealth(
                status: .healthy,
                checkedAt: now
            ),
            limitGroups: [
                UsageLimitGroup(
                    id: UsageLimitGroupID("wrong-provider"),
                    windows: []
                )
            ],
            fetchedAt: now
        )
        let presentation = NormalizedUsagePresentationBuilder.make(
            snapshot: makeSnapshot(
                profileID: profileID,
                providerID: .codex,
                report: mismatchedReport
            ),
            expectedProfile: NormalizedUsageExpectedProfile(
                id: profileID,
                name: "Codex profile",
                providerID: .codex,
                providerRevision: 1
            ),
            now: now
        )

        XCTAssertEqual(presentation.providerID, .codex)
        XCTAssertEqual(presentation.emptyState, .missingSnapshot)
        XCTAssertTrue(presentation.groups.isEmpty)
    }

    func testCurrentProfileNameOverridesSnapshotNameAfterRename()
        throws
    {
        let profileID = UUID()
        let presentation = NormalizedUsagePresentationBuilder.make(
            snapshot: makeSnapshot(
                profileID: profileID,
                report: try makeReport()
            ),
            expectedProfile: NormalizedUsageExpectedProfile(
                id: profileID,
                name: "Renamed Codex",
                providerID: .codex,
                providerRevision: 1
            ),
            now: now
        )

        XCTAssertEqual(presentation.profileName, "Renamed Codex")
        XCTAssertNotEqual(presentation.profileName, "Codex profile")
    }

    func testClickedClaudePreferencesDoNotUseActiveProfileConfig() {
        let clicked = Profile(
            name: "Clicked Claude",
            iconConfig: MenuBarIconConfiguration(
                showRemainingPercentage: true,
                showTimeMarker: false,
                showPaceMarker: false,
                usePaceColoring: false
            )
        )
        let active = Profile(
            name: "Active Claude",
            iconConfig: MenuBarIconConfiguration(
                showRemainingPercentage: false,
                showTimeMarker: true,
                showPaceMarker: true,
                usePaceColoring: true
            )
        )

        let clickedPreferences =
            NormalizedUsageDisplayPreferences.make(
                displayMode: .single,
                displayedProfile: clicked,
                multiProfileConfiguration: .default
            )
        let activePreferences =
            NormalizedUsageDisplayPreferences.make(
                displayMode: .single,
                displayedProfile: active,
                multiProfileConfiguration: .default
            )

        XCTAssertEqual(
            clickedPreferences,
            NormalizedUsageDisplayPreferences(
                iconConfiguration: clicked.iconConfig
            )
        )
        XCTAssertNotEqual(clickedPreferences, activePreferences)
        XCTAssertTrue(
            clickedPreferences.showRemainingPercentage
        )
        XCTAssertFalse(clickedPreferences.showTimeMarker)
        XCTAssertFalse(clickedPreferences.showPaceMarker)
        XCTAssertFalse(clickedPreferences.usePaceColoring)
    }

    func testAccountChipGroupsListEveryProfileGroupedByProvider() {
        let claudeActive = Profile(
            id: UUID(),
            name: "jc@example.com",
            providerConfiguration: .claude
        )
        let claudeOther = Profile(
            id: UUID(),
            name: "jason@example.com",
            providerConfiguration: .claude
        )
        let codex = Profile(
            id: UUID(),
            name: "codex",
            providerConfiguration: .codex(
                CodexProfileConfiguration()
            )
        )

        let groups = AccountChipGroup.make(
            profiles: [claudeActive, codex, claudeOther],
            isActive: { $0.id == claudeActive.id || $0.id == codex.id },
            viewedProfileID: claudeOther.id
        )

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].providerName, "Claude")
        XCTAssertEqual(
            groups[0].chips.map(\.id),
            [claudeActive.id, claudeOther.id]
        )
        XCTAssertEqual(groups[1].providerName, "Codex")
        XCTAssertEqual(groups[1].chips.map(\.id), [codex.id])

        let activeChip = groups[0].chips[0]
        XCTAssertTrue(activeChip.isActive)
        XCTAssertFalse(activeChip.isViewing)

        let viewedChip = groups[0].chips[1]
        XCTAssertFalse(viewedChip.isActive)
        XCTAssertTrue(viewedChip.isViewing)

        let codexChip = groups[1].chips[0]
        XCTAssertTrue(codexChip.isActive)
        XCTAssertFalse(codexChip.isViewing)
    }

    func testAccountChipGroupsOmitProviderWithNoProfiles() {
        let claude = Profile(name: "Solo Claude")

        let groups = AccountChipGroup.make(
            profiles: [claude],
            isActive: { _ in true },
            viewedProfileID: claude.id
        )

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].providerName, "Claude")
        XCTAssertEqual(groups[0].chips.count, 1)
        XCTAssertTrue(groups[0].chips[0].isActive)
        XCTAssertTrue(groups[0].chips[0].isViewing)
    }

    func testAccountChipGroupsAreEmptyForNoProfiles() {
        XCTAssertTrue(
            AccountChipGroup.make(
                profiles: [],
                isActive: { _ in false },
                viewedProfileID: nil
            ).isEmpty
        )
    }

    func testUnknownRemovedProfileIsNotLabeledClaude() throws {
        let unknown = try ProviderID("unknown")
        let profileID = UUID()
        let presentation = NormalizedUsagePresentationBuilder.make(
            snapshot: nil,
            expectedProfile: NormalizedUsageExpectedProfile(
                id: profileID,
                name: "Selected profile",
                providerID: unknown,
                providerRevision: 0
            ),
            now: now
        )

        XCTAssertEqual(presentation.providerID, unknown)
        XCTAssertEqual(presentation.providerName, "Unknown")
        XCTAssertNotEqual(presentation.providerName, "Claude")
        XCTAssertEqual(presentation.emptyState, .missingSnapshot)
    }

    func testPopoverNavigationActionsKeepManageAndPreferencesDistinct() {
        var routed: [String] = []
        let actions = PopoverNavigationActions(
            manageProfiles: {
                routed.append("profiles")
            },
            preferences: {
                routed.append("preferences")
            },
            cliAccount: {
                routed.append("cli-account")
            },
            claudeAIAccount: {
                routed.append("claude-ai-account")
            }
        )

        actions.manageProfiles()
        actions.preferences()
        actions.cliAccount()
        actions.claudeAIAccount()

        XCTAssertEqual(
            routed,
            ["profiles", "preferences", "cli-account", "claude-ai-account"]
        )
    }

    func testClaudeAdapterKeepsLegacyCardsAndAPIBillingSeparate()
        throws
    {
        let usage = makeClaudeUsage()
        let report = try ClaudeUsageProviderAdapter.makeReport(
            from: usage,
            context: ClaudeUsageProviderContext(
                account: ProviderAccount(
                    displayName: "claude@example.com",
                    planName: "Max"
                ),
                health: ProviderHealth(
                    status: .healthy,
                    checkedAt: now
                ),
                fetchedAt: now,
                staleAt: now.addingTimeInterval(300)
            )
        )
        let apiUsage = APIUsage(
            currentSpendCents: 500,
            resetsAt: now.addingTimeInterval(86_400),
            prepaidCreditsCents: 1_500,
            currency: "USD",
            apiTokenCostCents: 100,
            apiCostByModel: ["claude": 100],
            costBySource: nil,
            dailyCostCents: nil
        )
        let profileID = UUID()
        let exact = NormalizedUsagePresentationBuilder.make(
            snapshot: PresentationSnapshot(
                profileID: profileID,
                profileName: "Claude",
                providerID: .claude,
                providerRevision: 0,
                presentationEpoch: 1,
                capabilities:
                    ClaudeUsageProviderAdapter.capabilities,
                configurationState: .ready,
                report: report,
                claudeUsage: usage,
                claudeAPIUsage: apiUsage,
                activity: .idle,
                lastSuccessfulAt: now,
                currentFailure: nil
            ),
            expectedProfile: NormalizedUsageExpectedProfile(
                id: profileID,
                name: "Claude",
                providerID: .claude,
                providerRevision: 0
            ),
            now: now
        )

        XCTAssertEqual(exact.legacyClaudeUsage, usage)
        XCTAssertEqual(exact.legacyClaudeAPIUsage, apiUsage)
        XCTAssertEqual(exact.groups.first?.id.groupID.rawValue, "subscription")
        XCTAssertEqual(
            exact.groups.first?.windows.map(\.id.windowID.rawValue),
            ["session", "weekly"]
        )
        XCTAssertNil(exact.summary)
        XCTAssertEqual(exact.accountName, "claude@example.com")
        XCTAssertEqual(exact.planName, "Max")
    }

    private func makePresentation(
        report: UsageReport?,
        capabilities: ProviderCapabilities = ProviderCapabilities([
            .usageLimits: .available,
            .usageSummary: .available,
            .credits: .available
        ]),
        configurationState: ProviderConfigurationState = .ready,
        activity: UsageRefreshActivity = .idle,
        failure: ProviderRefreshFailure? = nil
    ) -> NormalizedUsagePresentation {
        let profileID = UUID()
        return NormalizedUsagePresentationBuilder.make(
            snapshot: makeSnapshot(
                profileID: profileID,
                providerID: report?.providerID ?? .codex,
                report: report,
                capabilities: capabilities,
                configurationState: configurationState,
                activity: activity,
                failure: failure
            ),
            expectedProfile: NormalizedUsageExpectedProfile(
                id: profileID,
                name: "Codex profile",
                providerID: report?.providerID ?? .codex,
                providerRevision: 1
            ),
            now: now
        )
    }

    private func makeSnapshot(
        profileID: UUID,
        providerID: ProviderID = .codex,
        report: UsageReport?,
        capabilities: ProviderCapabilities = ProviderCapabilities([
            .usageLimits: .available,
            .usageSummary: .available,
            .credits: .available
        ]),
        configurationState: ProviderConfigurationState = .ready,
        activity: UsageRefreshActivity = .idle,
        failure: ProviderRefreshFailure? = nil
    ) -> PresentationSnapshot {
        PresentationSnapshot(
            profileID: profileID,
            profileName: "Codex profile",
            providerID: providerID,
            providerRevision: 1,
            presentationEpoch: 1,
            capabilities: capabilities,
            configurationState: configurationState,
            report: report,
            claudeUsage: nil,
            claudeAPIUsage: nil,
            activity: activity,
            lastSuccessfulAt: report?.fetchedAt,
            currentFailure: failure
        )
    }

    private func makeReport(
        health: ProviderHealth? = nil,
        groups: [UsageLimitGroup] = [],
        summary: UsageSummary? = nil,
        credits: [UsageCredit] = [],
        fetchedAt: Date? = nil,
        staleAt: Date? = nil
    ) throws -> UsageReport {
        let fetchDate = fetchedAt ?? now
        return try UsageReport(
            providerID: .codex,
            account: ProviderAccount(
                displayName: "person@example.com",
                planName: "Pro"
            ),
            health: health ?? ProviderHealth(
                status: .healthy,
                checkedAt: fetchDate
            ),
            limitGroups: groups,
            usageSummary: summary,
            credits: credits,
            fetchedAt: fetchDate,
            staleAt: staleAt
        )
    }

    private func makeClaudeUsage() -> ClaudeUsage {
        ClaudeUsage(
            sessionTokensUsed: 25,
            sessionLimit: 100,
            sessionPercentage: 25,
            sessionResetTime: now.addingTimeInterval(18_000),
            weeklyTokensUsed: 60,
            weeklyLimit: 100,
            weeklyPercentage: 60,
            weeklyResetTime: now.addingTimeInterval(604_800),
            opusWeeklyTokensUsed: 10,
            opusWeeklyPercentage: 10,
            sonnetWeeklyTokensUsed: 20,
            sonnetWeeklyPercentage: 20,
            sonnetWeeklyResetTime:
                now.addingTimeInterval(604_800),
            fableWeeklyTokensUsed: 0,
            fableWeeklyPercentage: 0,
            fableWeeklyResetTime:
                now.addingTimeInterval(604_800),
            fableWeeklyLimitAvailable: true,
            costUsed: 100,
            costLimit: 1_000,
            costCurrency: "USD",
            overageBalance: 500,
            overageBalanceCurrency: "USD",
            lastUpdated: now,
            userTimezone: TimeZone(secondsFromGMT: 0)!
        )
    }
}
