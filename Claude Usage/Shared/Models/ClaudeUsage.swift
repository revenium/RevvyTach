import Foundation

/// Main data model representing Claude Code usage statistics
struct ClaudeUsage: Codable, Equatable {
    // Session data (5-hour rolling window)
    var sessionTokensUsed: Int
    var sessionLimit: Int
    var sessionPercentage: Double
    var sessionResetTime: Date
    /// Whether the usage response actually reported the 5-hour window.
    ///
    /// `sessionPercentage` is a plain `Double`, so a response that omits the
    /// window used to land in the model as a confident `0` — indistinguishable
    /// from an account that has genuinely used nothing. Everything downstream
    /// then reported "0% used" in the safe/green tier about a figure nobody
    /// ever received. This flag is the difference between "we read zero" and
    /// "we read nothing", and callers that render a number must consult it.
    var sessionPercentageAvailable: Bool

    /// Returns 0% if the 5-hour session window has expired, otherwise the raw percentage.
    var effectiveSessionPercentage: Double {
        sessionResetTime < Date() ? 0.0 : sessionPercentage
    }

    /// The session figure, or nil when no session figure was ever received.
    ///
    /// Prefer this over the raw `sessionPercentage` anywhere the value is
    /// shown to a person: nil has to reach the UI as "no reading" rather than
    /// being flattened into a reassuring zero.
    ///
    /// This still goes through `effectiveSessionPercentage`, which checks
    /// window expiry against `Date()` at call time — fine for a one-off
    /// read, but not for anything that must stay deterministic against a
    /// fixed "as of" instant. `ClaudeUsageProviderAdapter.makeReport` is
    /// exactly that case: it renders against `context.fetchedAt`, so it
    /// reimplements this expiry check against that timestamp instead of
    /// calling through here. A caller with the same determinism requirement
    /// should do the same rather than adopt this property.
    var readableSessionPercentage: Double? {
        sessionPercentageAvailable ? effectiveSessionPercentage : nil
    }

    // Weekly data (all models)
    var weeklyTokensUsed: Int
    var weeklyLimit: Int
    var weeklyPercentage: Double
    var weeklyResetTime: Date
    /// Whether the usage response actually reported the 7-day window.
    /// Same distinction as `sessionPercentageAvailable`, for the same reason.
    var weeklyPercentageAvailable: Bool

    /// The weekly figure, or nil when no weekly figure was ever received.
    var readableWeeklyPercentage: Double? {
        weeklyPercentageAvailable ? weeklyPercentage : nil
    }

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
        /// One is linked and its sign-in is current, but the app could not
        /// make it produce a reading.
        ///
        /// This used to be the catch-all every unclassified outcome fell
        /// into, and its message told people to re-sync. That was wrong on
        /// two counts. The app already performs the equivalent of a re-sync
        /// on its own — `adoptLiveCLILogin(for:replacing:)` is deliberately
        /// the same read the button performs, and it runs before this verdict
        /// is reached — so the instruction asked for a step that had just
        /// been taken and failed. And the Re-sync import validates JSON shape
        /// only, so a tokenless blob can overwrite a working login and read
        /// back as valid: the advice could destroy the very credential it was
        /// meant to repair. What is left here is a statement of fact with no
        /// instruction attached.
        case signInUnusable
        /// The reading could not be taken this time, for a reason that says
        /// nothing about the credential: the request timed out, was refused
        /// by the server, or came back as something that would not decode.
        ///
        /// Kept apart from `signInUnusable` because the sign-in is not
        /// implicated at all, and apart from silence because the figure does
        /// exist and simply is not here yet. Its message is a plain statement
        /// with no remedy, since the only thing anyone can do is wait for the
        /// next refresh — which the app performs unaided.
        case temporarilyUnavailable
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

    /// Why the organization's extra-usage figure is absent, when it is.
    ///
    /// The figure comes from a second request that was wrapped in `try?`, so
    /// a network failure, a 401, and a rate limit all left the amount, the
    /// limit and the currency nil with no signal — indistinguishable from the
    /// organization having extra usage switched off. One of those is a settled
    /// answer with nothing to fix; the other is a figure that exists and could
    /// not be reached, and only the second is worth telling anyone about.
    enum OrganizationExtraUsageIssue: String, Codable, Equatable {
        /// The request did not come back usable — offline, refused, rate
        /// limited, or a body that would not decode.
        case lookupFailed
        /// Extra usage is switched off for this organization. Settled, and
        /// deliberately silent in the UI.
        case notEnabled
        /// claude.ai answered HTTP 200 carrying no extra-usage record at
        /// all — a zero-byte body, or a literal `null`. There is nothing to
        /// show for this organization, which is as settled as having extra
        /// usage switched off, and just as silent.
        ///
        /// Only those two shapes reach here. A 200 whose body is an array, a
        /// bare scalar, or not JSON at all is a failure to read the figure
        /// and stays `lookupFailed`, because being settled is permanent
        /// silence and a proxy or WAF page answering in claude.ai's place
        /// must not buy it.
        ///
        /// Kept apart from `notEnabled` even though both render as nothing.
        /// They are different facts: one is a preference the organization set
        /// and could set back, the other is the server having no record to
        /// return. Collapsing them would also hide which of the two a profile
        /// is in, and the difference is the whole reason this case exists —
        /// it used to be reported as `lookupFailed`, which puts "Some usage
        /// details are unavailable" on a profile where nothing failed.
        case notAvailableForOrganization
    }

    /// Nil when the organization's figure was obtained, or when it was never
    /// asked for (the per-profile extra-usage preference is off).
    var organizationExtraUsageIssue: OrganizationExtraUsageIssue?

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
        // Defaulted to `true` so the many call sites that build a record from
        // a reading they actually received keep saying so. The parsers that
        // can fail to receive a window pass `false` explicitly, and so does
        // `.empty`, which stands for "nothing has been read yet".
        sessionPercentageAvailable: Bool = true,
        weeklyTokensUsed: Int,
        weeklyLimit: Int,
        weeklyPercentage: Double,
        weeklyResetTime: Date,
        weeklyPercentageAvailable: Bool = true,
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
        organizationExtraUsageIssue: OrganizationExtraUsageIssue? = nil,
        overageBalance: Double? = nil,
        overageBalanceCurrency: String? = nil,
        lastUpdated: Date,
        userTimezone: TimeZone
    ) {
        self.sessionTokensUsed = sessionTokensUsed
        self.sessionLimit = sessionLimit
        self.sessionPercentage = sessionPercentage
        self.sessionResetTime = sessionResetTime
        self.sessionPercentageAvailable = sessionPercentageAvailable
        self.weeklyTokensUsed = weeklyTokensUsed
        self.weeklyLimit = weeklyLimit
        self.weeklyPercentage = weeklyPercentage
        self.weeklyResetTime = weeklyResetTime
        self.weeklyPercentageAvailable = weeklyPercentageAvailable
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
        self.organizationExtraUsageIssue = organizationExtraUsageIssue
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
        // A snapshot cached by a version that had no such flag cannot tell us
        // whether its zero was received or invented, so a zero is treated as
        // unknown. That direction is deliberate: a dash on a genuinely idle
        // account clears itself on the next refresh, whereas a fabricated
        // "0% used" is exactly the reassuring lie this flag exists to stop.
        sessionPercentageAvailable = try container.decodeIfPresent(
            Bool.self,
            forKey: .sessionPercentageAvailable
        ) ?? (sessionPercentage > 0)
        weeklyTokensUsed = try container.decode(Int.self, forKey: .weeklyTokensUsed)
        weeklyLimit = try container.decode(Int.self, forKey: .weeklyLimit)
        weeklyPercentage = try container.decode(Double.self, forKey: .weeklyPercentage)
        weeklyResetTime = try container.decode(Date.self, forKey: .weeklyResetTime)
        weeklyPercentageAvailable = try container.decodeIfPresent(
            Bool.self,
            forKey: .weeklyPercentageAvailable
        ) ?? (weeklyPercentage > 0)
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
        organizationExtraUsageIssue = try container.decodeIfPresent(
            OrganizationExtraUsageIssue.self,
            forKey: .organizationExtraUsageIssue
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

    /// A record standing in for "nothing has been read yet".
    ///
    /// Both availability flags are `false` on purpose. The zeros below are
    /// placeholders, not measurements — a profile that has never completed a
    /// fetch used to render through this value as a pristine `0 · 0` in the
    /// safe/green tier, identical to an account with a real, healthy zero.
    static var empty: ClaudeUsage {
        ClaudeUsage(
            sessionTokensUsed: 0,
            sessionLimit: 0,
            sessionPercentage: 0,
            sessionResetTime: Date().addingTimeInterval(5 * 60 * 60),
            sessionPercentageAvailable: false,
            weeklyTokensUsed: 0,
            weeklyLimit: 1_000_000,
            weeklyPercentage: 0,
            weeklyResetTime: Date().nextMonday1259pm(),
            weeklyPercentageAvailable: false,
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
