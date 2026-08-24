import Foundation
import XCTest
@testable import UsageCore

final class UsageCoreTests: XCTestCase {
    private let providerID = try! ProviderID("provider.example")
    private let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)

    func testCompleteReportCodableRoundTripPreservesDynamicData() throws {
        let primary = try UsageWindow(
            id: UsageWindowID("primary"),
            displayName: "Five hour",
            usedPercentage: 27.5,
            quantity: UsageQuantity(used: 275, limit: 1_000, unit: .tokens),
            startedAt: fetchedAt.addingTimeInterval(-3_600),
            resetsAt: fetchedAt.addingTimeInterval(14_400),
            duration: 18_000
        )
        let secondary = try UsageWindow(
            id: UsageWindowID("secondary"),
            displayName: "Weekly",
            usedPercentage: 61,
            resetsAt: fetchedAt.addingTimeInterval(86_400),
            duration: 604_800
        )
        let flexibleGroup = try UsageLimitGroup(
            id: UsageLimitGroupID("model.gpt-next"),
            displayName: "GPT Next",
            windows: [primary, secondary]
        )
        let summary = try UsageSummary(
            metrics: [
                UsageMetric(
                    id: UsageMetricID("input-tokens"),
                    displayName: "Input tokens",
                    value: 12_345,
                    unit: .tokens
                ),
                UsageMetric(
                    id: UsageMetricID("requests"),
                    value: 42,
                    unit: .requests
                )
            ],
            periodStartedAt: fetchedAt.addingTimeInterval(-86_400),
            periodEndsAt: fetchedAt.addingTimeInterval(86_400),
            dailyBuckets: [
                UsageDailyBucket(
                    startedAt: fetchedAt.addingTimeInterval(-86_400),
                    endsAt: fetchedAt,
                    metrics: [
                        UsageMetric(
                            id: UsageMetricID("input-tokens"),
                            value: 1_234,
                            unit: .tokens
                        )
                    ]
                )
            ]
        )
        let report = try UsageReport(
            providerID: providerID,
            account: ProviderAccount(
                id: ProviderAccountID("account-123"),
                displayName: "person@example.com",
                planName: "Team",
                organizationName: "Example"
            ),
            health: ProviderHealth(status: .healthy, checkedAt: fetchedAt),
            limitGroups: [flexibleGroup],
            usageSummary: summary,
            credits: [
                UsageCredit(
                    id: UsageMetricID("reset-credits"),
                    displayName: "Reset credits",
                    balance: 3,
                    unit: .count
                )
            ],
            sourceUpdatedAt: fetchedAt.addingTimeInterval(-5),
            fetchedAt: fetchedAt,
            staleAt: fetchedAt.addingTimeInterval(300)
        )

        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(UsageReport.self, from: data)

        XCTAssertEqual(decoded, report)
        XCTAssertEqual(decoded.limitGroups[0].windows.map(\.id.rawValue), ["primary", "secondary"])
        XCTAssertEqual(decoded.usageSummary?.metrics.count, 2)
        XCTAssertEqual(
            decoded.usageSummary?.dailyBuckets?.first?.metrics.first?.value,
            1_234
        )
        let encodedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let encodedCredits = try XCTUnwrap(encodedObject["credits"] as? [[String: Any]])
        XCTAssertNil(encodedCredits[0]["isReadOnly"])
    }

    func testReportRoundTripPreservesMoreThanTwoValidatedWindows() throws {
        let percentages: [Double] = [0, 25, 100, 125]
        let windows = try percentages.enumerated().map { index, percentage in
            try UsageWindow(
                id: UsageWindowID("dynamic-\(index)"),
                displayName: "Dynamic \(index)",
                usedPercentage: percentage,
                resetsAt: fetchedAt.addingTimeInterval(
                    TimeInterval((index + 1) * 3_600)
                ),
                duration: TimeInterval((index + 1) * 1_800)
            )
        }
        let report = try UsageReport(
            providerID: providerID,
            health: ProviderHealth(
                status: .degraded,
                checkedAt: fetchedAt,
                issue: .optionalUsageUnavailable
            ),
            limitGroups: [
                UsageLimitGroup(
                    id: UsageLimitGroupID("dynamic"),
                    windows: windows
                )
            ],
            fetchedAt: fetchedAt
        )

        let encoded = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(
            UsageReport.self,
            from: encoded
        )

        XCTAssertEqual(decoded, report)
        XCTAssertEqual(decoded.health.status, .degraded)
        XCTAssertEqual(
            decoded.health.issue,
            .optionalUsageUnavailable
        )
        XCTAssertEqual(decoded.limitGroups[0].windows.count, 4)
        XCTAssertEqual(
            decoded.limitGroups[0].windows.compactMap(\.usedPercentage),
            percentages
        )

        let duplicatePayload = try JSONSerialization.jsonObject(
            with: encoded
        )
        var object = try XCTUnwrap(
            duplicatePayload as? [String: Any]
        )
        var groups = try XCTUnwrap(
            object["limitGroups"] as? [[String: Any]]
        )
        var encodedWindows = try XCTUnwrap(
            groups[0]["windows"] as? [[String: Any]]
        )
        encodedWindows.append(encodedWindows[0])
        groups[0]["windows"] = encodedWindows
        object["limitGroups"] = groups
        let duplicateData = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                UsageReport.self,
                from: duplicateData
            )
        )
    }

    func testDynamicGroupAndWindowIdentityIsStableAndOrderIndependent() throws {
        let firstID = try UsageWindowID("provider-window")
        let secondID = try UsageWindowID("provider-window")
        let otherID = try UsageWindowID("another-window")

        XCTAssertEqual(firstID, secondID)
        XCTAssertNotEqual(firstID, otherID)
        XCTAssertEqual(Set([firstID, secondID, otherID]).count, 2)

        let windows = try [
            UsageWindow(id: firstID, usedPercentage: 10),
            UsageWindow(id: otherID, usedPercentage: 20)
        ]
        let group = try UsageLimitGroup(
            id: UsageLimitGroupID("dynamic-group"),
            windows: windows
        )
        XCTAssertEqual(group.windows.map(\.id), [firstID, otherID])
    }

    func testCapabilitiesDistinguishUnavailableFromUnknown() throws {
        let providerDefinedCapability = try ProviderCapability("provider-defined-capability")
        var capabilities = ProviderCapabilities([
            .usageLimits: .available,
            .interactiveLogin: .unavailable,
            providerDefinedCapability: .available
        ])

        XCTAssertTrue(capabilities.supports(.usageLimits))
        XCTAssertEqual(capabilities[.interactiveLogin], .unavailable)
        XCTAssertEqual(capabilities[.usageSummary], .unknown)

        capabilities[.credits] = .available
        let data = try JSONEncoder().encode(capabilities)
        let decoded = try JSONDecoder().decode(ProviderCapabilities.self, from: data)
        XCTAssertEqual(decoded, capabilities)
        XCTAssertEqual(decoded[.credits], .available)
        XCTAssertEqual(decoded[providerDefinedCapability], .available)
    }

    func testFreshnessHasFreshStaleAndUnknownStates() throws {
        let health = ProviderHealth(status: .healthy, checkedAt: fetchedAt)
        let unknown = try UsageReport(
            providerID: providerID,
            health: health,
            limitGroups: [],
            fetchedAt: fetchedAt
        )
        let expiring = try UsageReport(
            providerID: providerID,
            health: health,
            limitGroups: [],
            fetchedAt: fetchedAt,
            staleAt: fetchedAt.addingTimeInterval(60)
        )

        XCTAssertEqual(unknown.freshness(at: fetchedAt.addingTimeInterval(10)), .unknown)
        XCTAssertEqual(expiring.freshness(at: fetchedAt.addingTimeInterval(59)), .fresh)
        XCTAssertEqual(
            expiring.freshness(at: fetchedAt.addingTimeInterval(60)),
            .stale(since: fetchedAt.addingTimeInterval(60))
        )
        XCTAssertTrue(expiring.isStale(at: fetchedAt.addingTimeInterval(61)))
    }

    func testAccountAndHealthAllowUnavailableUsageWithoutInventedLimits() throws {
        let report = try UsageReport(
            providerID: providerID,
            account: ProviderAccount(
                displayName: "Unavailable account",
                planName: nil
            ),
            health: ProviderHealth(
                status: .unauthenticated,
                checkedAt: fetchedAt,
                issue: .authenticationRequired
            ),
            limitGroups: [],
            usageSummary: nil,
            credits: [],
            fetchedAt: fetchedAt
        )

        XCTAssertTrue(report.limitGroups.isEmpty)
        XCTAssertNil(report.usageSummary)
        XCTAssertTrue(report.credits.isEmpty)
        XCTAssertEqual(report.health.issue, .authenticationRequired)
    }

    func testIdentifiersRejectAmbiguousOrUnsafeValuesAndInvalidJSON() throws {
        XCTAssertEqual(ProviderID.claude.rawValue, "claude")
        XCTAssertEqual(ProviderID.codex.rawValue, "codex")
        XCTAssertNotEqual(ProviderID.claude, ProviderID.codex)
        XCTAssertThrowsError(try ProviderID(""))
        XCTAssertThrowsError(try ProviderID(" provider"))
        XCTAssertThrowsError(try UsageWindowID("window\nname"))

        let invalidEncodedID = Data(#"" bad-provider""#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ProviderID.self, from: invalidEncodedID))
    }

    func testWindowValidationRejectsInvalidMeasurementsAndRanges() throws {
        let id = try UsageWindowID("window")
        XCTAssertThrowsError(try UsageWindow(id: id, usedPercentage: -.leastNonzeroMagnitude))
        XCTAssertThrowsError(try UsageWindow(id: id, usedPercentage: .infinity))
        XCTAssertThrowsError(try UsageWindow(id: id, usedPercentage: 1, duration: 0))
        XCTAssertThrowsError(
            try UsageWindow(
                id: id,
                usedPercentage: 1,
                startedAt: fetchedAt,
                resetsAt: fetchedAt.addingTimeInterval(-1)
            )
        )

        let overage = try UsageWindow(id: id, usedPercentage: 125)
        XCTAssertEqual(overage.usedPercentage, 125)
    }

    /// A window may carry no measurement at all. That is a provider saying
    /// "this limit exists and I could not read it", and it has to be
    /// expressible: while the initializer rejected it, a percentage-only
    /// provider had nowhere to put an unread window and sent a fabricated 0%
    /// instead, which displayed as a healthy figure.
    func testWindowMayCarryNoMeasurementToMeanNoReading() throws {
        let window = try UsageWindow(id: try UsageWindowID("window"))
        XCTAssertNil(window.usedPercentage)
        XCTAssertNil(window.quantity)

        // And it survives a round trip, so a stored report keeps saying
        // "unread" rather than decoding into something else.
        let decoded = try JSONDecoder().decode(
            UsageWindow.self,
            from: try JSONEncoder().encode(window)
        )
        XCTAssertEqual(decoded, window)
    }

    func testDuplicateIdentitiesAndInvalidReportDatesAreRejected() throws {
        let window = try UsageWindow(id: UsageWindowID("same"), usedPercentage: 10)
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
            try UsageReport(
                providerID: providerID,
                health: ProviderHealth(status: .healthy, checkedAt: fetchedAt),
                limitGroups: [group, group],
                fetchedAt: fetchedAt
            )
        )
        XCTAssertThrowsError(
            try UsageReport(
                providerID: providerID,
                health: ProviderHealth(status: .healthy, checkedAt: fetchedAt),
                limitGroups: [],
                fetchedAt: fetchedAt,
                staleAt: fetchedAt.addingTimeInterval(-1)
            )
        )
    }

    func testQuantityAndSummaryValidationRejectNonFiniteNegativeAndDuplicateValues() throws {
        XCTAssertThrowsError(try UsageQuantity(used: -1, unit: .tokens))
        XCTAssertThrowsError(try UsageQuantity(used: .nan, unit: .tokens))
        XCTAssertThrowsError(try UsageQuantity(used: 1, limit: -.leastNonzeroMagnitude, unit: .tokens))

        let metric = try UsageMetric(
            id: UsageMetricID("tokens"),
            value: 1,
            unit: .tokens
        )
        XCTAssertThrowsError(try UsageSummary(metrics: [metric, metric]))
        XCTAssertThrowsError(
            try UsageSummary(
                metrics: [],
                periodStartedAt: fetchedAt,
                periodEndsAt: fetchedAt.addingTimeInterval(-1)
            )
        )

        let quantity = try UsageQuantity(used: 250, limit: 1_000, unit: .tokens)
        XCTAssertEqual(quantity.calculatedUsedPercentage, 25)
    }

    func testDailySummaryBucketsPreserveAbsentEmptyAndPartialSemantics()
        throws
    {
        let metric = try UsageMetric(
            id: UsageMetricID("tokens"),
            value: 0,
            unit: .tokens
        )
        let absent = try UsageSummary(metrics: [])
        let empty = try UsageSummary(metrics: [], dailyBuckets: [])
        let partial = try UsageSummary(
            metrics: [],
            dailyBuckets: [
                UsageDailyBucket(
                    startedAt: fetchedAt,
                    metrics: [metric]
                )
            ]
        )

        XCTAssertNil(absent.dailyBuckets)
        XCTAssertEqual(empty.dailyBuckets, [])
        XCTAssertEqual(partial.dailyBuckets?.first?.metrics, [metric])

        let oldPayload = Data(#"{"metrics":[]}"#.utf8)
        XCTAssertNil(
            try JSONDecoder()
                .decode(UsageSummary.self, from: oldPayload)
                .dailyBuckets
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                UsageSummary.self,
                from: JSONEncoder().encode(empty)
            ),
            empty
        )

        XCTAssertThrowsError(
            try UsageSummary(
                metrics: [],
                dailyBuckets: [
                    UsageDailyBucket(
                        startedAt: fetchedAt,
                        metrics: []
                    ),
                    UsageDailyBucket(
                        startedAt: fetchedAt,
                        metrics: []
                    )
                ]
            )
        )
        XCTAssertThrowsError(
            try UsageDailyBucket(
                startedAt: fetchedAt,
                endsAt: fetchedAt,
                metrics: []
            )
        )
        XCTAssertThrowsError(
            try UsageDailyBucket(
                startedAt: fetchedAt,
                metrics: [metric, metric]
            )
        )
    }

    func testCurrencyCodesAreExplicitNormalizedAndCodableAcrossValueTypes() throws {
        let usd = try UsageCurrencyCode("usd")
        XCTAssertEqual(usd.rawValue, "USD")
        XCTAssertThrowsError(try UsageCurrencyCode("US"))
        XCTAssertThrowsError(try UsageCurrencyCode("12$"))

        let quantity = try UsageQuantity(
            used: 12.34,
            limit: 50,
            unit: .currency,
            currencyCode: usd
        )
        let metric = try UsageMetric(
            id: UsageMetricID("spend"),
            value: 12.34,
            unit: .currency,
            currencyCode: usd
        )
        let credit = try UsageCredit(
            id: UsageMetricID("balance"),
            balance: 7.89,
            unit: .currency,
            currencyCode: usd
        )

        XCTAssertThrowsError(
            try UsageQuantity(
                used: 1,
                unit: .tokens,
                currencyCode: usd
            )
        )
        XCTAssertThrowsError(
            try UsageQuantity(used: 1, unit: .currency)
        )
        XCTAssertThrowsError(
            try UsageMetric(
                id: UsageMetricID("invalid"),
                value: 1,
                unit: .tokens,
                currencyCode: usd
            )
        )
        XCTAssertThrowsError(
            try UsageMetric(
                id: UsageMetricID("missing-code"),
                value: 1,
                unit: .currency
            )
        )
        XCTAssertThrowsError(
            try UsageCredit(
                id: UsageMetricID("invalid"),
                balance: 1,
                unit: .count,
                currencyCode: usd
            )
        )
        XCTAssertThrowsError(
            try UsageCredit(
                id: UsageMetricID("missing-code"),
                balance: 1,
                unit: .currency
            )
        )

        let values = CurrencyValues(quantity: quantity, metric: metric, credit: credit)
        let data = try JSONEncoder().encode(values)
        XCTAssertEqual(try JSONDecoder().decode(CurrencyValues.self, from: data), values)
    }

    func testDecodingReappliesModelValidation() throws {
        let invalidWindow = Data(
            #"{"id":"window","usedPercentage":-1}"#.utf8
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(UsageWindow.self, from: invalidWindow)
        )

        let invalidReport = Data(
            """
            {
              "providerID": "provider.example",
              "health": {
                "status": "healthy",
                "checkedAt": \(fetchedAt.timeIntervalSinceReferenceDate)
              },
              "limitGroups": [],
              "credits": [],
              "fetchedAt": \(fetchedAt.timeIntervalSinceReferenceDate),
              "staleAt": \(fetchedAt.addingTimeInterval(-1).timeIntervalSinceReferenceDate)
            }
            """.utf8
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(UsageReport.self, from: invalidReport)
        )
    }

    func testMinimalReportDecodingDefaultsAdditiveSurfaces() throws {
        let minimalReport = Data(
            """
            {
              "providerID": "claude",
              "health": {
                "status": "healthy",
                "checkedAt": \(fetchedAt.timeIntervalSinceReferenceDate)
              },
              "fetchedAt": \(fetchedAt.timeIntervalSinceReferenceDate)
            }
            """.utf8
        )

        let decoded = try JSONDecoder().decode(UsageReport.self, from: minimalReport)

        XCTAssertEqual(decoded.providerID, .claude)
        XCTAssertTrue(decoded.limitGroups.isEmpty)
        XCTAssertNil(decoded.account)
        XCTAssertNil(decoded.usageSummary)
        XCTAssertTrue(decoded.credits.isEmpty)
        XCTAssertNil(decoded.sourceUpdatedAt)
        XCTAssertNil(decoded.staleAt)
    }

    func testUsageProviderProtocolExposesAccountHealthCapabilitiesAndReport() async throws {
        let report = try UsageReport(
            providerID: providerID,
            account: ProviderAccount(id: ProviderAccountID("account")),
            health: ProviderHealth(status: .healthy, checkedAt: fetchedAt),
            limitGroups: [],
            fetchedAt: fetchedAt
        )
        let provider = StubProvider(report: report)

        XCTAssertEqual(provider.id, providerID)
        XCTAssertTrue(provider.capabilities.supports(.account))
        let account = try await provider.account()
        XCTAssertEqual(account?.id, try ProviderAccountID("account"))
        let health = await provider.health()
        XCTAssertEqual(health.status, .healthy)
        let fetchedReport = try await provider.fetchUsage()
        XCTAssertEqual(fetchedReport, report)
    }
}

private struct StubProvider: UsageProvider {
    let report: UsageReport

    var id: ProviderID { report.providerID }
    var capabilities: ProviderCapabilities {
        ProviderCapabilities([
            .account: .available,
            .health: .available,
            .usageLimits: .available
        ])
    }

    func account() async throws -> ProviderAccount? {
        report.account
    }

    func health() async -> ProviderHealth {
        report.health
    }

    func fetchUsage() async throws -> UsageReport {
        report
    }
}

private struct CurrencyValues: Codable, Equatable {
    var quantity: UsageQuantity
    var metric: UsageMetric
    var credit: UsageCredit
}
