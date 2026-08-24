import Foundation
import UsageCore

/// Pure inputs supplied by the app when normalizing a previously fetched
/// `ClaudeUsage` value.
///
/// Account, health, and freshness are explicit so this mapping never reaches
/// into profile, credential, refresh, or lifecycle singletons.
struct ClaudeUsageProviderContext: Equatable {
    var account: ProviderAccount?
    var health: ProviderHealth
    var fetchedAt: Date
    var staleAt: Date?

    init(
        account: ProviderAccount? = nil,
        health: ProviderHealth,
        fetchedAt: Date,
        staleAt: Date? = nil
    ) {
        self.account = account
        self.health = health
        self.fetchedAt = fetchedAt
        self.staleAt = staleAt
    }
}

/// Characterization seam from the app's existing Claude subscription model to
/// provider-neutral UsageCore data.
///
/// This type intentionally does not conform to `UsageProvider`: fetching,
/// authentication, cancellation, and profile-keyed refresh ownership remain in
/// the app and are introduced by the provider-aware refresh work. The adapter
/// only maps data already obtained by those services. It also deliberately
/// excludes the separate `APIUsage` Platform-billing model.
enum ClaudeUsageProviderAdapter {
    static let capabilities = ProviderCapabilities([
        .account: .available,
        .health: .available,
        .usageLimits: .available,
        .usageSummary: .unavailable,
        .credits: .available,
        .resetCredits: .unavailable,
        .interactiveLogin: .unavailable,
        .automaticSessionStart: .available,
        .automaticProfileSwitch: .available,
        .usageHistory: .available,
        .usageNotifications: .available,
        .cliAccountSync: .available,
        .apiBilling: .available
    ])

    /// Claude's API only ever reports utilization *percentages* for the
    /// session/weekly/model windows below — it does not expose absolute
    /// token counts, and without knowing the user's plan tier there is no
    /// reliable token limit to divide against. Any token count previously
    /// derived from `percentage * assumedLimit` was fabricated, not real
    /// usage data. So every Claude `UsageWindow` here intentionally carries
    /// `quantity: nil`; the UI renders percentage + reset time only. (The
    /// "extra-usage" currency window below is unrelated real monetary data
    /// and is unaffected.)
    static func makeReport(
        from usage: ClaudeUsage,
        context: ClaudeUsageProviderContext
    ) throws -> UsageReport {
        var groups = [
            try UsageLimitGroup(
                id: UsageLimitGroupID("subscription"),
                windows: [
                    try UsageWindow(
                        id: UsageWindowID("session"),
                        // nil when the response never reported the window, so
                        // the popover says "Unavailable" instead of drawing a
                        // reassuring empty bar. When it was reported, match
                        // ClaudeUsage.effectiveSessionPercentage without its
                        // implicit Date() dependency.
                        usedPercentage: usage.sessionPercentageAvailable
                            ? (usage.sessionResetTime < context.fetchedAt
                                ? 0
                                : usage.sessionPercentage)
                            : nil,
                        quantity: nil,
                        resetsAt: usage.sessionResetTime,
                        duration: Constants.sessionWindow
                    ),
                    try UsageWindow(
                        id: UsageWindowID("weekly"),
                        usedPercentage: usage.weeklyPercentageAvailable
                            ? usage.weeklyPercentage
                            : nil,
                        quantity: nil,
                        resetsAt: usage.weeklyResetTime,
                        duration: Constants.weeklyWindow
                    )
                ]
            )
        ]

        // Preserve the current app's model-window availability semantics:
        // Opus and Sonnet are present when their token fields indicate that the
        // API supplied the window. Fable has a dedicated availability flag so
        // a supported 0% window remains visible immediately after reset.
        if usage.opusWeeklyTokensUsed > 0 {
            groups.append(
                try modelGroup(
                    id: "opus",
                    usedPercentage: usage.opusWeeklyPercentage,
                    tokensUsed: usage.opusWeeklyTokensUsed,
                    resetsAt: nil
                )
            )
        }

        if usage.sonnetWeeklyTokensUsed > 0 {
            groups.append(
                try modelGroup(
                    id: "sonnet",
                    usedPercentage: usage.sonnetWeeklyPercentage,
                    tokensUsed: usage.sonnetWeeklyTokensUsed,
                    resetsAt: usage.sonnetWeeklyResetTime
                )
            )
        }

        if usage.fableWeeklyLimitAvailable {
            groups.append(
                try modelGroup(
                    id: "fable",
                    usedPercentage: usage.fableWeeklyPercentage,
                    tokensUsed: usage.fableWeeklyTokensUsed,
                    resetsAt: usage.fableWeeklyResetTime
                )
            )
        }

        // The viewer's own extra usage leads, because it is the figure they
        // came to read. The organization's follows only when we have it.
        let personalGroup = try extraUsageGroup(
            id: "extra-usage",
            displayName: extraUsageDisplayName(for: .personal),
            used: usage.personalCostUsed,
            limit: usage.personalCostLimit,
            rawCurrency: usage.personalCostCurrency
        )
        if let personalGroup {
            groups.append(personalGroup)
        }

        // Alone, the organization's figure keeps the identifier and the
        // scope-driven name it has always had. Beneath a personal one it is
        // the organization's by construction, so it says so outright.
        if let organizationGroup = try extraUsageGroup(
            id: personalGroup == nil ? "extra-usage" : "extra-usage-organization",
            displayName: personalGroup == nil
                ? extraUsageDisplayName(for: usage.costScope)
                : extraUsageDisplayName(for: .organization),
            used: usage.costUsed,
            limit: usage.costLimit,
            rawCurrency: usage.costCurrency
        ) {
            groups.append(organizationGroup)
        }

        var credits: [UsageCredit] = []
        if let balance = usage.overageBalance,
           let rawCurrency = usage.overageBalanceCurrency {
            credits.append(
                try UsageCredit(
                    id: UsageMetricID("overage-balance"),
                    displayName: overageBalanceDisplayName(for: usage.costScope),
                    balance: balance / 100,
                    unit: .currency,
                    currencyCode: UsageCurrencyCode(rawCurrency)
                )
            )
        }

        return try UsageReport(
            providerID: .claude,
            account: context.account,
            health: context.health,
            limitGroups: groups,
            credits: credits,
            sourceUpdatedAt: usage.lastUpdated,
            fetchedAt: context.fetchedAt,
            staleAt: context.staleAt
        )
    }

    /// Why the popover should explain a missing personal figure, if it should.
    ///
    /// Returned only when the organization's spend is on screen and the
    /// viewer's own is not — someone reading a company-wide number with no
    /// way to find their own. The reason comes back with it because the
    /// remedies differ: one person has no Claude Code account linked, another
    /// has one whose sign-in stopped working, and a third is linked to a
    /// different organization entirely. A single "connect your account" line
    /// was wrong for two of the three.
    static func personalExtraUsageIssueToExplain(
        for usage: ClaudeUsage
    ) -> ClaudeUsage.PersonalExtraUsageIssue? {
        let hasOrganizationFigure = usage.costUsed != nil
            && (usage.costLimit ?? 0) > 0
            && usage.costCurrency != nil
            && usage.costScope != .personal
        let hasPersonalFigure = usage.personalCostUsed != nil
            && (usage.personalCostLimit ?? 0) > 0
            && usage.personalCostCurrency != nil
        guard hasOrganizationFigure, !hasPersonalFigure else { return nil }
        return usage.personalExtraUsageIssue
    }

    /// One extra-usage group, or nil when the figure is absent or unusable.
    private static func extraUsageGroup(
        id: String,
        displayName: String,
        used: Double?,
        limit: Double?,
        rawCurrency: String?
    ) throws -> UsageLimitGroup? {
        guard let used, let limit, let rawCurrency, limit > 0 else {
            return nil
        }
        return try UsageLimitGroup(
            id: UsageLimitGroupID(id),
            displayName: displayName,
            windows: [
                try UsageWindow(
                    id: UsageWindowID("current"),
                    usedPercentage: used / limit * 100,
                    quantity: try UsageQuantity(
                        // ClaudeUsage stores monetary values in minor currency
                        // units; UsageCore carries display values in major
                        // units with an explicit code.
                        used: used / 100,
                        limit: limit / 100,
                        unit: .currency,
                        currencyCode: try UsageCurrencyCode(rawCurrency)
                    )
                )
            ]
        )
    }

    /// Header for the extra-usage group.
    ///
    /// The amounts come from an organization-scoped endpoint, so on a Team or
    /// Enterprise account they are the company's spend and not the viewer's.
    /// An unclassified organization (`nil`) gets the same wider label: saying
    /// "organization" about one person is mildly wrong, saying nothing about a
    /// whole company's spend sitting under someone's personal bars is not.
    /// The organization's own name is deliberately absent — the popover keeps
    /// names out of prose and has no width for them.
    static func extraUsageDisplayName(
        for scope: ClaudeUsage.ExtraUsageScope?
    ) -> String {
        switch scope {
        case .personal:
            return ProviderUILocalization.text(
                "menubar.extra_usage",
                fallback: "Extra Usage"
            )
        case .organization, nil:
            return ProviderUILocalization.text(
                "menubar.extra_usage_organization",
                fallback: "Extra Usage · Organization"
            )
        }
    }

    /// Label for the overage credit balance.
    ///
    /// `overage_credit_grant` is organization-scoped for the same reason
    /// `overage_spend_limit` is, so the remaining balance shown to a member of
    /// a Team or Enterprise account is the company's pool, not theirs. Scope
    /// wording is kept identical to the extra-usage group header so the two
    /// read as one fact rather than two.
    static func overageBalanceDisplayName(
        for scope: ClaudeUsage.ExtraUsageScope?
    ) -> String {
        switch scope {
        case .personal:
            return ProviderUILocalization.text(
                "menubar.overage_balance",
                fallback: "Credit Balance"
            )
        case .organization, nil:
            return ProviderUILocalization.text(
                "menubar.overage_balance_organization",
                fallback: "Credit Balance · Organization"
            )
        }
    }

    private static func modelGroup(
        id: String,
        usedPercentage: Double,
        tokensUsed: Int,
        resetsAt: Date?
    ) throws -> UsageLimitGroup {
        try UsageLimitGroup(
            id: UsageLimitGroupID(id),
            windows: [
                try UsageWindow(
                    id: UsageWindowID("weekly"),
                    usedPercentage: usedPercentage,
                    quantity: nil,
                    resetsAt: resetsAt,
                    duration: Constants.weeklyWindow
                )
            ]
        )
    }
}
