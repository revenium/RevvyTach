import Foundation
import UsageCore
import XCTest
@testable import Claude_Usage

final class ClaudeUsageProviderAdapterTests: XCTestCase {
    private let sourceUpdatedAt = Date(timeIntervalSinceReferenceDate: 10_000)
    private let fetchedAt = Date(timeIntervalSinceReferenceDate: 10_030)
    private let sessionReset = Date(timeIntervalSinceReferenceDate: 20_000)
    private let weeklyReset = Date(timeIntervalSinceReferenceDate: 30_000)

    func testMapsExistingClaudeSubscriptionWindowsWithoutFabricatedTokenQuantities() throws {
        let report = try makeReport(
            usage: makeUsage(
                sessionPercentage: 125,
                opusTokens: 120,
                opusPercentage: 12,
                opusAvailable: true,
                sonnetTokens: 340,
                sonnetPercentage: 34,
                sonnetReset: weeklyReset.addingTimeInterval(10),
                sonnetAvailable: true,
                fableTokens: 560,
                fablePercentage: 56,
                fableReset: weeklyReset.addingTimeInterval(20),
                fableAvailable: true
            )
        )

        XCTAssertEqual(report.providerID, .claude)
        XCTAssertEqual(report.limitGroups.map(\.id.rawValue), [
            "subscription", "opus", "sonnet", "fable"
        ])

        let subscription = try XCTUnwrap(report.limitGroups.first)
        XCTAssertEqual(subscription.windows.map(\.id.rawValue), ["session", "weekly"])

        let session = subscription.windows[0]
        XCTAssertEqual(session.usedPercentage, 125)
        XCTAssertNil(session.quantity)
        XCTAssertEqual(session.resetsAt, sessionReset)
        XCTAssertEqual(session.duration, Constants.sessionWindow)

        let weekly = subscription.windows[1]
        XCTAssertEqual(weekly.usedPercentage, 48)
        XCTAssertNil(weekly.quantity)
        XCTAssertEqual(weekly.resetsAt, weeklyReset)
        XCTAssertEqual(weekly.duration, Constants.weeklyWindow)

        let opus = report.limitGroups[1].windows[0]
        XCTAssertEqual(opus.usedPercentage, 12)
        XCTAssertNil(opus.quantity)
        XCTAssertNil(opus.resetsAt)

        XCTAssertEqual(report.limitGroups[2].windows[0].resetsAt, weeklyReset.addingTimeInterval(10))
        XCTAssertEqual(report.limitGroups[3].windows[0].resetsAt, weeklyReset.addingTimeInterval(20))
    }

    func testMissingOptionalModelWindowsRemainAbsent() throws {
        let report = try makeReport(
            usage: makeUsage(
                opusTokens: 0,
                opusPercentage: 80,
                sonnetTokens: 0,
                sonnetPercentage: 70,
                sonnetReset: weeklyReset,
                fableTokens: 0,
                fablePercentage: 60,
                fableReset: weeklyReset,
                fableAvailable: false
            )
        )

        XCTAssertEqual(report.limitGroups.map(\.id.rawValue), ["subscription"])
    }

    func testAvailableFableWindowSurvivesZeroUsage() throws {
        let report = try makeReport(
            usage: makeUsage(
                fableTokens: 0,
                fablePercentage: 0,
                fableReset: weeklyReset,
                fableAvailable: true
            )
        )

        let fable = try XCTUnwrap(
            report.limitGroups.first { $0.id.rawValue == "fable" }
        )
        XCTAssertEqual(fable.windows[0].usedPercentage, 0)
        XCTAssertNil(fable.windows[0].quantity)
        XCTAssertEqual(fable.windows[0].resetsAt, weeklyReset)
    }

    func testExpiredSessionUsesExistingEffectivePercentageSemanticsDeterministically() throws {
        let expiredReset = fetchedAt.addingTimeInterval(-1)
        let report = try makeReport(
            usage: makeUsage(
                sessionPercentage: 88,
                sessionReset: expiredReset
            )
        )

        let session = report.limitGroups[0].windows[0]
        XCTAssertEqual(session.usedPercentage, 0)
        XCTAssertEqual(session.resetsAt, expiredReset)
        XCTAssertNil(session.quantity)
    }

    func testAccountHealthSourceTimestampAndFreshnessAreExplicitInputs() throws {
        let account = ProviderAccount(
            id: try ProviderAccountID("claude-account"),
            displayName: "Person",
            planName: "Max",
            organizationName: "Example"
        )
        let health = ProviderHealth(
            status: .degraded,
            checkedAt: fetchedAt.addingTimeInterval(-2),
            issue: .transportUnavailable
        )
        let staleAt = fetchedAt.addingTimeInterval(60)
        let report = try ClaudeUsageProviderAdapter.makeReport(
            from: makeUsage(),
            context: ClaudeUsageProviderContext(
                account: account,
                health: health,
                fetchedAt: fetchedAt,
                staleAt: staleAt
            )
        )

        XCTAssertEqual(report.account, account)
        XCTAssertEqual(report.health, health)
        XCTAssertEqual(report.sourceUpdatedAt, sourceUpdatedAt)
        XCTAssertEqual(report.fetchedAt, fetchedAt)
        XCTAssertEqual(report.staleAt, staleAt)
        XCTAssertEqual(report.freshness(at: staleAt.addingTimeInterval(-1)), .fresh)
        XCTAssertEqual(report.freshness(at: staleAt), .stale(since: staleAt))
    }

    func testStableIdentitiesAndCodableOutputDoNotDependOnAccount() throws {
        let withoutAccount = try makeReport(usage: makeUsage())
        let withAccount = try ClaudeUsageProviderAdapter.makeReport(
            from: makeUsage(),
            context: ClaudeUsageProviderContext(
                account: ProviderAccount(id: try ProviderAccountID("different-account")),
                health: ProviderHealth(status: .healthy, checkedAt: fetchedAt),
                fetchedAt: fetchedAt
            )
        )

        XCTAssertEqual(
            withoutAccount.limitGroups.map(\.id),
            withAccount.limitGroups.map(\.id)
        )
        XCTAssertEqual(
            withoutAccount.limitGroups.flatMap { $0.windows.map(\.id) },
            withAccount.limitGroups.flatMap { $0.windows.map(\.id) }
        )

        let data = try JSONEncoder().encode(withAccount)
        let decoded = try JSONDecoder().decode(UsageReport.self, from: data)
        XCTAssertEqual(decoded, withAccount)
        XCTAssertNil(decoded.usageSummary)
        XCTAssertTrue(decoded.credits.isEmpty)
    }

    func testMapsClaudeSubscriptionExtraUsageAndBalanceWithoutPlatformBilling() throws {
        let report = try makeReport(
            usage: makeUsage(
                costUsed: 1_250,
                costLimit: 5_000,
                costCurrency: "usd",
                overageBalance: 875,
                overageBalanceCurrency: "eur"
            )
        )

        let extraUsage = try XCTUnwrap(
            report.limitGroups.first { $0.id.rawValue == "extra-usage" }
        )
        XCTAssertEqual(extraUsage.windows.map(\.id.rawValue), ["current"])
        XCTAssertEqual(extraUsage.windows[0].usedPercentage, 25)
        XCTAssertEqual(extraUsage.windows[0].quantity?.used, 12.5)
        XCTAssertEqual(extraUsage.windows[0].quantity?.limit, 50)
        XCTAssertEqual(extraUsage.windows[0].quantity?.unit, .currency)
        XCTAssertEqual(extraUsage.windows[0].quantity?.currencyCode?.rawValue, "USD")

        XCTAssertEqual(report.credits.map(\.id.rawValue), ["overage-balance"])
        XCTAssertEqual(report.credits[0].balance, 8.75)
        XCTAssertEqual(report.credits[0].unit, .currency)
        XCTAssertEqual(report.credits[0].currencyCode?.rawValue, "EUR")
        XCTAssertNil(report.usageSummary)

        let decoded = try JSONDecoder().decode(
            UsageReport.self,
            from: JSONEncoder().encode(report)
        )
        XCTAssertEqual(decoded, report)
    }

    func testIncompleteClaudeSubscriptionMonetaryDataStaysAbsent() throws {
        let report = try makeReport(
            usage: makeUsage(
                costUsed: 1_250,
                costLimit: nil,
                costCurrency: "USD",
                overageBalance: 875,
                overageBalanceCurrency: nil
            )
        )

        XCTAssertFalse(report.limitGroups.contains { $0.id.rawValue == "extra-usage" })
        XCTAssertTrue(report.credits.isEmpty)
    }

    func testCapabilitiesDescribeCurrentClaudeAdapterBoundary() {
        let capabilities = ClaudeUsageProviderAdapter.capabilities

        XCTAssertEqual(capabilities[.usageLimits], .available)
        XCTAssertEqual(capabilities[.account], .available)
        XCTAssertEqual(capabilities[.health], .available)
        XCTAssertEqual(capabilities[.usageSummary], .unavailable)
        XCTAssertEqual(capabilities[.credits], .available)
        XCTAssertEqual(capabilities[.resetCredits], .unavailable)
        XCTAssertEqual(capabilities[.automaticSessionStart], .available)
    }

    /// The overage endpoint is organization-scoped, so a Team account's whole
    /// company spend was rendering under one member's own bars with nothing
    /// saying so. The header has to carry the scope.
    func testExtraUsageHeaderNamesTheOrganizationScope() throws {
        let report = try makeReport(
            usage: makeUsage(
                costUsed: 259_316,
                costLimit: 500_000,
                costCurrency: "USD",
                costScope: .organization
            )
        )

        let extraUsage = try XCTUnwrap(
            report.limitGroups.first { $0.id.rawValue == "extra-usage" }
        )
        XCTAssertEqual(
            extraUsage.displayName,
            "menubar.extra_usage_organization".localized
        )
    }

    /// An unclassified organization gets the same wider label: silence would
    /// re-create the bug for every account whose classification is unknown.
    func testUnclassifiedExtraUsageHeaderStillNamesTheOrganizationScope() throws {
        let report = try makeReport(
            usage: makeUsage(
                costUsed: 259_316,
                costLimit: 500_000,
                costCurrency: "USD",
                costScope: nil
            )
        )

        let extraUsage = try XCTUnwrap(
            report.limitGroups.first { $0.id.rawValue == "extra-usage" }
        )
        XCTAssertEqual(
            extraUsage.displayName,
            "menubar.extra_usage_organization".localized
        )
    }

    /// A personal Max/Pro organization is the signed-in person, so the plain
    /// header is accurate there and the scope word would only add noise.
    func testPersonalExtraUsageHeaderOmitsTheScopeWord() throws {
        let report = try makeReport(
            usage: makeUsage(
                costUsed: 259_316,
                costLimit: 500_000,
                costCurrency: "USD",
                costScope: .personal
            )
        )

        let extraUsage = try XCTUnwrap(
            report.limitGroups.first { $0.id.rawValue == "extra-usage" }
        )
        XCTAssertEqual(extraUsage.displayName, "menubar.extra_usage".localized)
        XCTAssertNotEqual(
            extraUsage.displayName,
            "menubar.extra_usage_organization".localized
        )
    }

    /// The customer's reported figures. Labelling the scope must not disturb
    /// the minor-to-major currency conversion underneath it.
    func testCustomerReportedExtraUsageAmountsConvertUnchanged() throws {
        let report = try makeReport(
            usage: makeUsage(
                costUsed: 259_316,
                costLimit: 500_000,
                costCurrency: "USD",
                costScope: .organization
            )
        )

        let window = try XCTUnwrap(
            report.limitGroups
                .first { $0.id.rawValue == "extra-usage" }?
                .windows
                .first
        )
        let quantity = try XCTUnwrap(window.quantity)
        XCTAssertEqual(quantity.used, 2_593.16, accuracy: 0.000_1)
        XCTAssertEqual(try XCTUnwrap(quantity.limit), 5_000, accuracy: 0.000_1)
        let percentage = try XCTUnwrap(window.usedPercentage)
        XCTAssertEqual(percentage, 51.8632, accuracy: 0.000_1)
        XCTAssertEqual((percentage * 100).rounded() / 100, 51.86)
    }

    /// When the member's own CLI-authenticated figure and the organization's
    /// claude.ai figure are both present, the viewer's own leads and the
    /// organization's follows underneath — as two distinct groups, not one
    /// overwriting the other.
    func testPersonalAndOrganizationExtraUsageBothAppearAsDistinctGroups() throws {
        let report = try makeReport(
            usage: makeUsage(
                costUsed: 26_118,
                costLimit: 100_000,
                costCurrency: "USD",
                costScope: .organization,
                personalCostUsed: 1_250,
                personalCostLimit: 5_000,
                personalCostCurrency: "USD",
                overageBalance: 875,
                overageBalanceCurrency: "EUR"
            )
        )

        XCTAssertEqual(
            report.limitGroups.map(\.id.rawValue),
            ["subscription", "extra-usage", "extra-usage-organization"]
        )

        let personal = try XCTUnwrap(
            report.limitGroups.first { $0.id.rawValue == "extra-usage" }
        )
        XCTAssertEqual(personal.displayName, "menubar.extra_usage".localized)
        XCTAssertEqual(personal.windows[0].usedPercentage, 25)
        XCTAssertEqual(personal.windows[0].quantity?.used, 12.5)
        XCTAssertEqual(personal.windows[0].quantity?.limit, 50)
        XCTAssertEqual(personal.windows[0].quantity?.currencyCode?.rawValue, "USD")

        let organization = try XCTUnwrap(
            report.limitGroups.first { $0.id.rawValue == "extra-usage-organization" }
        )
        XCTAssertEqual(
            organization.displayName,
            "menubar.extra_usage_organization".localized
        )
        let organizationPercentage = try XCTUnwrap(organization.windows[0].usedPercentage)
        XCTAssertEqual(organizationPercentage, 26.118, accuracy: 0.000_1)
        let organizationQuantity = try XCTUnwrap(organization.windows[0].quantity)
        XCTAssertEqual(organizationQuantity.used, 261.18, accuracy: 0.000_1)
        XCTAssertEqual(try XCTUnwrap(organizationQuantity.limit), 1_000, accuracy: 0.000_1)
        XCTAssertEqual(organization.windows[0].quantity?.currencyCode?.rawValue, "USD")

        XCTAssertEqual(report.credits.map(\.id.rawValue), ["overage-balance"])
        XCTAssertEqual(
            report.credits[0].displayName,
            "menubar.overage_balance_organization".localized
        )
        XCTAssertEqual(report.credits[0].balance, 8.75)
    }

    private func makeReport(usage: ClaudeUsage) throws -> UsageReport {
        try ClaudeUsageProviderAdapter.makeReport(
            from: usage,
            context: ClaudeUsageProviderContext(
                health: ProviderHealth(status: .healthy, checkedAt: fetchedAt),
                fetchedAt: fetchedAt,
                staleAt: fetchedAt.addingTimeInterval(300)
            )
        )
    }

    private func makeUsage(
        sessionTokens: Int = 1_250,
        sessionPercentage: Double = 12.5,
        sessionReset: Date? = nil,
        opusTokens: Int = 0,
        opusPercentage: Double = 0,
        opusAvailable: Bool = false,
        sonnetTokens: Int = 0,
        sonnetPercentage: Double = 0,
        sonnetReset: Date? = nil,
        sonnetAvailable: Bool = false,
        fableTokens: Int = 0,
        fablePercentage: Double = 0,
        fableReset: Date? = nil,
        fableAvailable: Bool = false,
        costUsed: Double? = nil,
        costLimit: Double? = nil,
        costCurrency: String? = nil,
        costScope: ClaudeUsage.ExtraUsageScope? = nil,
        personalCostUsed: Double? = nil,
        personalCostLimit: Double? = nil,
        personalCostCurrency: String? = nil,
        personalExtraUsageIssue: ClaudeUsage.PersonalExtraUsageIssue? = nil,
        overageBalance: Double? = nil,
        overageBalanceCurrency: String? = nil
    ) -> ClaudeUsage {
        ClaudeUsage(
            sessionTokensUsed: sessionTokens,
            sessionLimit: 10_000,
            sessionPercentage: sessionPercentage,
            sessionResetTime: sessionReset ?? self.sessionReset,
            weeklyTokensUsed: 480_000,
            weeklyLimit: 1_000_000,
            weeklyPercentage: 48,
            weeklyResetTime: weeklyReset,
            opusWeeklyTokensUsed: opusTokens,
            opusWeeklyPercentage: opusPercentage,
            opusWeeklyLimitAvailable: opusAvailable,
            sonnetWeeklyTokensUsed: sonnetTokens,
            sonnetWeeklyPercentage: sonnetPercentage,
            sonnetWeeklyResetTime: sonnetReset,
            sonnetWeeklyLimitAvailable: sonnetAvailable,
            fableWeeklyTokensUsed: fableTokens,
            fableWeeklyPercentage: fablePercentage,
            fableWeeklyResetTime: fableReset,
            fableWeeklyLimitAvailable: fableAvailable,
            costUsed: costUsed,
            costLimit: costLimit,
            costCurrency: costCurrency,
            costScope: costScope,
            personalCostUsed: personalCostUsed,
            personalCostLimit: personalCostLimit,
            personalCostCurrency: personalCostCurrency,
            personalExtraUsageIssue: personalExtraUsageIssue,
            overageBalance: overageBalance,
            overageBalanceCurrency: overageBalanceCurrency,
            lastUpdated: sourceUpdatedAt,
            userTimezone: TimeZone(secondsFromGMT: 0)!
        )
    }
}
