import Foundation

/// Main data model representing Claude Code usage statistics
struct ClaudeUsage: Codable, Equatable {
    // Session data (5-hour rolling window)
    var sessionTokensUsed: Int
    var sessionLimit: Int
    var sessionPercentage: Double
    var sessionResetTime: Date

    /// Returns 0% if the 5-hour session window has expired, otherwise the raw percentage.
    var effectiveSessionPercentage: Double {
        sessionResetTime < Date() ? 0.0 : sessionPercentage
    }

    // Weekly data (all models)
    var weeklyTokensUsed: Int
    var weeklyLimit: Int
    var weeklyPercentage: Double
    var weeklyResetTime: Date

    // Weekly data (Opus only)
    var opusWeeklyTokensUsed: Int
    var opusWeeklyPercentage: Double

    // Weekly data (Sonnet only)
    var sonnetWeeklyTokensUsed: Int
    var sonnetWeeklyPercentage: Double
    var sonnetWeeklyResetTime: Date?

    // Weekly data (Fable only)
    var fableWeeklyTokensUsed: Int
    var fableWeeklyPercentage: Double
    var fableWeeklyResetTime: Date?
    /// Whether the usage API reported a Fable weekly limit for this account.
    /// This distinguishes a supported account at 0% immediately after reset from one
    /// whose response does not include a Fable limit.
    var fableWeeklyLimitAvailable: Bool

    /// Who the extra-usage figures below actually belong to.
    ///
    /// claude.ai reports extra usage from an organization-scoped endpoint, so
    /// on a Team or Enterprise account the amounts are the whole company's
    /// spend rather than the signed-in member's. On a personal Max/Pro
    /// subscription the organization *is* the person, so the same numbers are
    /// individual. The UI needs the distinction to avoid presenting a
    /// company-wide figure as the viewer's own.
    enum ExtraUsageScope: String, Codable, Equatable {
        /// Shared organization (Team/Enterprise): the amounts cover everyone.
        case organization
        /// Single-person organization: the amounts are this person's.
        case personal
    }

    // Extra usage data
    var costUsed: Double?
    var costLimit: Double?
    var costCurrency: String?
    /// Nil on records written before this field existed. Treat nil as
    /// `.organization` at every point of use: that is what the endpoint has
    /// always returned.
    var costScope: ExtraUsageScope?

    /// The signed-in member's own extra usage, from the CLI-authenticated
    /// `/api/oauth/usage` endpoint rather than the organization-scoped
    /// claude.ai one. Nil whenever the member figure could not be obtained:
    /// no CLI credential, a credential belonging to a different organization,
    /// or extra usage switched off for that member. Stored in minor currency
    /// units like `costUsed`/`costLimit`.
    var personalCostUsed: Double?
    var personalCostLimit: Double?
    var personalCostCurrency: String?

    /// Why the member's own extra usage is missing, when it is.
    ///
    /// A profile holds two independent connections: the claude.ai sign-in
    /// that returns the organization's figures, and the Claude Code sign-in
    /// that returns the member's own. The first working while the second does
    /// not is the ordinary case, and the reasons are not interchangeable —
    /// one needs an account linked, another needs an existing link renewed.
    /// Saying only "connect an account" sent people who already had one to a
    /// screen with nothing to do, so the reason travels to the UI.
    enum PersonalExtraUsageIssue: String, Codable, Equatable {
        /// No Claude Code account is linked to this profile.
        case notLinked
        /// One is linked, but its sign-in is too old to renew.
        ///
        /// Signing in to that Claude Code account again is necessary and not
        /// sufficient: the app holds its own copy of the login and re-reads
        /// the real one only when a profile is activated or the account is
        /// re-synced. Advice that stops at "sign in again" leaves people
        /// watching an unchanged number, so both halves have to be said.
        case signInExpired
        /// One is linked, but the login stored for it carries no token at
        /// all — the state Claude Code leaves behind for a configuration
        /// directory it has been signed out of. Nothing the app can do with
        /// this, and re-syncing only re-imports it, so it is kept apart from
        /// `signInUnusable` whose remedy really is a re-sync.
        case signInHasNoToken
        /// One is linked and its sign-in is current, but it could not be
        /// used this time. Re-syncing is the right remedy here.
        case signInUnusable
        /// The linked account is signed in to a different organization than
        /// the one being displayed, so its figures describe someone else's
        /// context.
        case differentOrganization

        /// This profile could not be lined up with the organization on
        /// screen at all — either its claude.ai organization is not the one
        /// this refresh is showing, or no profile could be found to check in
        /// the first place. Both leave the app unable to say whose member
        /// figure would even apply, which is a claude.ai-side problem: the
        /// remedy is reconnecting the account there, not the Claude Code
        /// link that the other cases point to. Kept apart from extra usage
        /// being switched off for a member, which is a settled answer with
        /// nothing to fix and stays silent rather than becoming a case here.
        case claudeAccountUnresolved
    }

    /// Nil when the member's figure is present, or when there is no
    /// organization figure for it to sit beneath.
    var personalExtraUsageIssue: PersonalExtraUsageIssue?

    // Overage credit grant balance
    var overageBalance: Double?
    var overageBalanceCurrency: String?

    // Metadata
    var lastUpdated: Date
    var userTimezone: TimeZone

    init(
        sessionTokensUsed: Int,
        sessionLimit: Int,
        sessionPercentage: Double,
        sessionResetTime: Date,
        weeklyTokensUsed: Int,
        weeklyLimit: Int,
        weeklyPercentage: Double,
        weeklyResetTime: Date,
        opusWeeklyTokensUsed: Int,
        opusWeeklyPercentage: Double,
        sonnetWeeklyTokensUsed: Int,
        sonnetWeeklyPercentage: Double,
        sonnetWeeklyResetTime: Date?,
        fableWeeklyTokensUsed: Int,
        fableWeeklyPercentage: Double,
        fableWeeklyResetTime: Date?,
        fableWeeklyLimitAvailable: Bool = false,
        costUsed: Double?,
        costLimit: Double?,
        costCurrency: String?,
        costScope: ExtraUsageScope? = nil,
        personalCostUsed: Double? = nil,
        personalCostLimit: Double? = nil,
        personalCostCurrency: String? = nil,
        personalExtraUsageIssue: PersonalExtraUsageIssue? = nil,
        overageBalance: Double? = nil,
        overageBalanceCurrency: String? = nil,
        lastUpdated: Date,
        userTimezone: TimeZone
    ) {
        self.sessionTokensUsed = sessionTokensUsed
        self.sessionLimit = sessionLimit
        self.sessionPercentage = sessionPercentage
        self.sessionResetTime = sessionResetTime
        self.weeklyTokensUsed = weeklyTokensUsed
        self.weeklyLimit = weeklyLimit
        self.weeklyPercentage = weeklyPercentage
        self.weeklyResetTime = weeklyResetTime
        self.opusWeeklyTokensUsed = opusWeeklyTokensUsed
        self.opusWeeklyPercentage = opusWeeklyPercentage
        self.sonnetWeeklyTokensUsed = sonnetWeeklyTokensUsed
        self.sonnetWeeklyPercentage = sonnetWeeklyPercentage
        self.sonnetWeeklyResetTime = sonnetWeeklyResetTime
        self.fableWeeklyTokensUsed = fableWeeklyTokensUsed
        self.fableWeeklyPercentage = fableWeeklyPercentage
        self.fableWeeklyResetTime = fableWeeklyResetTime
        self.fableWeeklyLimitAvailable = fableWeeklyLimitAvailable
        self.costUsed = costUsed
        self.costLimit = costLimit
        self.costCurrency = costCurrency
        self.costScope = costScope
        self.personalCostUsed = personalCostUsed
        self.personalCostLimit = personalCostLimit
        self.personalCostCurrency = personalCostCurrency
        self.personalExtraUsageIssue = personalExtraUsageIssue
        self.overageBalance = overageBalance
        self.overageBalanceCurrency = overageBalanceCurrency
        self.lastUpdated = lastUpdated
        self.userTimezone = userTimezone
    }

    /// Custom decoding so that fields added after this struct's first release (like the Fable
    /// weekly fields) don't break decoding of usage data cached by older app versions — missing
    /// keys default instead of failing the whole decode.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionTokensUsed = try container.decode(Int.self, forKey: .sessionTokensUsed)
        sessionLimit = try container.decode(Int.self, forKey: .sessionLimit)
        sessionPercentage = try container.decode(Double.self, forKey: .sessionPercentage)
        sessionResetTime = try container.decode(Date.self, forKey: .sessionResetTime)
        weeklyTokensUsed = try container.decode(Int.self, forKey: .weeklyTokensUsed)
        weeklyLimit = try container.decode(Int.self, forKey: .weeklyLimit)
        weeklyPercentage = try container.decode(Double.self, forKey: .weeklyPercentage)
        weeklyResetTime = try container.decode(Date.self, forKey: .weeklyResetTime)
        opusWeeklyTokensUsed = try container.decode(Int.self, forKey: .opusWeeklyTokensUsed)
        opusWeeklyPercentage = try container.decode(Double.self, forKey: .opusWeeklyPercentage)
        sonnetWeeklyTokensUsed = try container.decode(Int.self, forKey: .sonnetWeeklyTokensUsed)
        sonnetWeeklyPercentage = try container.decode(Double.self, forKey: .sonnetWeeklyPercentage)
        sonnetWeeklyResetTime = try container.decodeIfPresent(Date.self, forKey: .sonnetWeeklyResetTime)
        fableWeeklyTokensUsed = try container.decodeIfPresent(Int.self, forKey: .fableWeeklyTokensUsed) ?? 0
        fableWeeklyPercentage = try container.decodeIfPresent(Double.self, forKey: .fableWeeklyPercentage) ?? 0
        fableWeeklyResetTime = try container.decodeIfPresent(Date.self, forKey: .fableWeeklyResetTime)
        fableWeeklyLimitAvailable = try container.decodeIfPresent(Bool.self, forKey: .fableWeeklyLimitAvailable)
            ?? (fableWeeklyPercentage > 0)
        costUsed = try container.decodeIfPresent(Double.self, forKey: .costUsed)
        costLimit = try container.decodeIfPresent(Double.self, forKey: .costLimit)
        costCurrency = try container.decodeIfPresent(String.self, forKey: .costCurrency)
        costScope = try container.decodeIfPresent(ExtraUsageScope.self, forKey: .costScope)
        personalCostUsed = try container.decodeIfPresent(Double.self, forKey: .personalCostUsed)
        personalCostLimit = try container.decodeIfPresent(Double.self, forKey: .personalCostLimit)
        personalCostCurrency = try container.decodeIfPresent(
            String.self,
            forKey: .personalCostCurrency
        )
        personalExtraUsageIssue = try container.decodeIfPresent(
            PersonalExtraUsageIssue.self,
            forKey: .personalExtraUsageIssue
        )
        overageBalance = try container.decodeIfPresent(Double.self, forKey: .overageBalance)
        overageBalanceCurrency = try container.decodeIfPresent(String.self, forKey: .overageBalanceCurrency)
        lastUpdated = try container.decode(Date.self, forKey: .lastUpdated)
        userTimezone = try container.decode(TimeZone.self, forKey: .userTimezone)
    }

    /// Remaining percentage (100 - used percentage)
    var remainingPercentage: Double {
        max(0, 100 - effectiveSessionPercentage)
    }

    /// Returns the status level based on remaining percentage (like Mac battery indicator)
    /// DEPRECATED: Use UsageStatusCalculator.calculateStatus() instead for display-aware logic
    /// This property remains for backwards compatibility only
    /// - > 20% remaining: safe (green)
    /// - 10-20% remaining: moderate (orange)
    /// - < 10% remaining: critical (red)
    @available(*, deprecated, message: "Use UsageStatusCalculator.calculateStatus() with showRemaining parameter")
    var statusLevel: UsageStatusLevel {
        switch remainingPercentage {
        case 20...:
            return .safe
        case 10..<20:
            return .moderate
        default:
            return .critical
        }
    }

    /// Empty usage data (used when no data is available)
    static var empty: ClaudeUsage {
        ClaudeUsage(
            sessionTokensUsed: 0,
            sessionLimit: 0,
            sessionPercentage: 0,
            sessionResetTime: Date().addingTimeInterval(5 * 60 * 60),
            weeklyTokensUsed: 0,
            weeklyLimit: 1_000_000,
            weeklyPercentage: 0,
            weeklyResetTime: Date().nextMonday1259pm(),
            opusWeeklyTokensUsed: 0,
            opusWeeklyPercentage: 0,
            sonnetWeeklyTokensUsed: 0,
            sonnetWeeklyPercentage: 0,
            sonnetWeeklyResetTime: nil,
            fableWeeklyTokensUsed: 0,
            fableWeeklyPercentage: 0,
            fableWeeklyResetTime: nil,
            costUsed: nil,
            costLimit: nil,
            costCurrency: nil,
            overageBalance: nil,
            overageBalanceCurrency: nil,
            lastUpdated: Date(),
            userTimezone: .current
        )
    }

}

/// Usage status level for color coding
/// Thresholds depend on display mode (used vs remaining percentage)
enum UsageStatusLevel {
    case safe       // Used mode: 0-50% used | Remaining mode: >20% remaining
    case moderate   // Used mode: 50-80% used | Remaining mode: 10-20% remaining
    case critical   // Used mode: 80-100% used | Remaining mode: <10% remaining
}
