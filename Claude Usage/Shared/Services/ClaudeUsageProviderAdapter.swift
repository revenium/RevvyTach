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
            health: accountHealth(from: usage, base: context.health),
            limitGroups: groups,
            credits: credits,
            sourceUpdatedAt: usage.lastUpdated,
            fetchedAt: context.fetchedAt,
            staleAt: context.staleAt
        )
    }

    /// The account's own health, as the fetched record actually evidences it.
    ///
    /// A completed request used to be reported as `.healthy` unconditionally,
    /// which made the value tautological: it said the fetch had returned, not
    /// that the account behind it was in good order. A profile whose Claude
    /// Code sign-in was functionally dead reported perfect health, and the
    /// header had nothing to show but Anthropic's public service status —
    /// which is about Anthropic, not about you.
    ///
    /// This only ever lowers the caller's verdict. A transport-level failure
    /// stays a transport-level failure; what is added is the case where the
    /// request succeeded and still came back missing something.
    static func accountHealth(
        from usage: ClaudeUsage,
        base: ProviderHealth
    ) -> ProviderHealth {
        guard base.status == .healthy else { return base }

        func degraded(_ issue: ProviderHealthIssue) -> ProviderHealth {
            ProviderHealth(
                status: .degraded,
                checkedAt: base.checkedAt,
                issue: issue
            )
        }

        // No capacity figure at all. The one thing the app exists to show is
        // missing, so this is not a partial answer — it is no answer.
        if !usage.sessionPercentageAvailable,
           !usage.weeklyPercentageAvailable {
            return ProviderHealth(
                status: .unavailable,
                checkedAt: base.checkedAt,
                issue: .responseInvalid
            )
        }
        if !usage.sessionPercentageAvailable
            || !usage.weeklyPercentageAvailable {
            return degraded(.responseInvalid)
        }

        // A connection that exists and is broken. `notLinked` and
        // `differentOrganization` are deliberately absent: nothing is broken
        // in either — one was never connected, the other is a settled fact
        // about a separate account — and reporting them as degraded would
        // leave a permanent complaint on a correctly configured profile.
        switch usage.personalExtraUsageIssue {
        case .signInExpired, .signInHasNoToken, .signInUnusable,
             .claudeAccountUnresolved:
            return degraded(.authenticationRequired)
        case .temporarilyUnavailable:
            // A reading that did not arrive this time, with nothing said or
            // implied about the credential. Classified the same way the
            // organization-scoped miss below is, rather than as an
            // authentication problem: reporting it as one would put a
            // sign-in complaint on a profile whose sign-in is fine.
            return degraded(.optionalUsageUnavailable)
        case .notLinked, .differentOrganization, nil:
            break
        }

        // Exhaustive on purpose, like the member switch above it. An `==`
        // check against `.lookupFailed` used to stand here, which let a newly
        // added case compile silently into "healthy" without anyone deciding
        // — and the case that was added is the one that must stay silent, so
        // the right answer arriving by accident would have been luck.
        switch usage.organizationExtraUsageIssue {
        case .lookupFailed:
            return degraded(.optionalUsageUnavailable)
        case .notEnabled, .notAvailableForOrganization, nil:
            // Switched off, not offered to this organization, or never asked
            // for. Settled answers with nothing to fix; degrading the account
            // for one would leave a permanent complaint on a profile that is
            // working exactly as it should.
            break
        }

        return base
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

    /// What the popover should say about extra usage, when there is no figure
    /// on screen to say it about.
    ///
    /// `personalExtraUsageIssueToExplain` above answers a different question:
    /// it reconciles a company-wide figure the viewer cannot map to
    /// themselves, and only fires when that figure is present. When no figure
    /// reaches the screen at all the extra-usage row simply does not render,
    /// and the app went silent — while holding the exact reason, in six
    /// finished cases, that it could not display.
    enum ExtraUsageAbsence: Equatable {
        /// The viewer's own figure is missing for a known, usually actionable
        /// reason, and no organization figure is standing in front of it.
        case unreadablePersonalFigure(ClaudeUsage.PersonalExtraUsageIssue)
        /// The organization-scoped request did not come back this time. Not
        /// the same as extra usage being switched off, which stays silent.
        case unreadableOrganizationFigure
    }

    static func extraUsageAbsenceToExplain(
        for usage: ClaudeUsage
    ) -> ExtraUsageAbsence? {
        let hasPersonalFigure = usage.personalCostUsed != nil
            && (usage.personalCostLimit ?? 0) > 0
            && usage.personalCostCurrency != nil
        // Their own number is on screen; nothing is missing.
        if hasPersonalFigure { return nil }

        let hasOrganizationFigure = usage.costUsed != nil
            && (usage.costLimit ?? 0) > 0
            && usage.costCurrency != nil
        // A figure is on screen. Either it is this person's own (a personal
        // Max/Pro subscription, where the organization *is* them, and the
        // existing silence there is correct) or it is the company's and
        // `personalExtraUsageIssueToExplain` already reconciles it. Either
        // way this statement would be a second, contradictory voice.
        if hasOrganizationFigure { return nil }

        // Nothing on screen. The member-scoped reason leads when there is
        // one: it names something the reader can act on.
        if let issue = usage.personalExtraUsageIssue {
            return .unreadablePersonalFigure(issue)
        }
        switch usage.organizationExtraUsageIssue {
        case .lookupFailed:
            return .unreadableOrganizationFigure
        case .notEnabled, .notAvailableForOrganization, nil:
            // Switched off, not offered to this organization, or never asked
            // for. Settled answers with nothing to fix, and a notice about
            // them would be noise on every refresh.
            return nil
        }
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
