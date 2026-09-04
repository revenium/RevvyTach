import Foundation

/// Determines whether a claude.ai organization is a single-person
/// organization (a personal Max/Pro subscription, where the org IS the user)
/// or a shared one (Team/Enterprise, where org-scoped figures belong to the
/// company rather than to the signed-in member).
///
/// Only the extra-usage scope depends on this today: `/organizations/{id}/
/// overage_spend_limit` reports the whole organization's spend, which is the
/// individual's own spend precisely when the organization has one member.
///
/// Shapes observed on a live five-organization account (2026-08-22):
///
/// | kind             | `capabilities`                            | `raven_type`   |
/// |------------------|-------------------------------------------|----------------|
/// | personal Max     | `["chat", "claude_max"]`                  | `nil`          |
/// | Team             | `["chat", "raven"]`                       | `"team"`       |
/// | Enterprise       | `["raven_enterprise", "raven", "chat", …]`| `"enterprise"` |
/// | console/API only | `["api"]`                                 | `nil`          |
///
/// "raven" is Anthropic's internal name for Team/Enterprise. Note that the
/// equivalent field on `api.anthropic.com/api/oauth/profile` is spelled
/// differently — `organization_type`, with values `"claude_max"` and
/// `"claude_team"` — so do not assume one endpoint's vocabulary applies to
/// the other.
enum ClaudeOrganizationClassifier {
    /// The capability every Team and Enterprise organization carries.
    private static let sharedCapability = "raven"

    /// The extra capability only Enterprise organizations carry.
    private static let enterpriseCapability = "raven_enterprise"

    /// Capabilities that mark an organization as shared (Team/Enterprise).
    private static let sharedCapabilities: Set<String> = [
        sharedCapability, enterpriseCapability
    ]

    /// Capabilities that mark an organization as one person's subscription.
    private static let maxCapability = "claude_max"
    private static let proCapability = "claude_pro"
    private static let personalCapabilities: Set<String> = [
        maxCapability, proCapability
    ]

    /// `raven_type` values observed on shared organizations.
    private static let teamRavenType = "team"
    private static let enterpriseRavenType = "enterprise"

    /// The capability an organization must have for any Claude subscription
    /// usage to exist against it. Console/API-only organizations lack it.
    static let chatCapability = "chat"

    /// The capability a console/API organization carries. Only used to tell a
    /// genuine console organization apart from one whose capabilities the
    /// server did not report at all.
    static let apiCapability = "api"

    /// - Returns: `true` personal, `false` shared, `nil` indeterminate.
    ///
    /// Both `nil` and `false` must be treated as organization-wide by callers:
    /// showing a company figure labelled as one person's is the failure this
    /// exists to prevent, so "unknown" errs toward the wider label.
    static func isPersonal(_ info: ClaudeAPIService.AccountInfo) -> Bool? {
        // Shared organizations are identified by `raven_type` when present,
        // and by the "raven" capabilities otherwise. Checked first so an
        // Enterprise org that also lists a personal-looking capability is
        // never misread as an individual's.
        if info.ravenType != nil {
            return false
        }
        if !sharedCapabilities.isDisjoint(with: info.capabilities) {
            return false
        }
        if !personalCapabilities.isDisjoint(with: info.capabilities) {
            return true
        }
        // Console/API-only organizations (`["api"]`) and anything unrecognized:
        // no personal Claude subscription is known to sit behind them.
        return nil
    }

    /// Whether the organization can carry Claude subscription usage at all.
    ///
    /// The `/organizations` list mixes Claude organizations with console/API
    /// organizations. The latter have no usage, no limits and no extra-usage
    /// budget, so binding a profile to one produces nothing but failed
    /// requests.
    static func isChatCapable(_ info: ClaudeAPIService.AccountInfo) -> Bool {
        info.capabilities.contains(chatCapability)
    }

    /// Short human label for an organization, so a picker never shows two
    /// identically-named entries distinguishable only by UUID.
    ///
    /// Driven by the same signals as `isPersonal`: an account can hold several
    /// organizations sharing one company name, and the kind is the only thing
    /// that tells a person which row is the one carrying their subscription.
    static func descriptor(_ info: ClaudeAPIService.AccountInfo) -> String {
        // Enterprise first: an Enterprise organization also carries "raven",
        // so checking Team first would mislabel it.
        if info.ravenType == enterpriseRavenType
            || info.capabilities.contains(enterpriseCapability) {
            return ProviderUILocalization.text(
                "wizard.org_kind.enterprise",
                fallback: "Enterprise"
            )
        }
        if info.ravenType == teamRavenType
            || info.capabilities.contains(sharedCapability) {
            return ProviderUILocalization.text(
                "wizard.org_kind.team",
                fallback: "Team"
            )
        }
        // Console/API organizations reach here; say why they cannot be picked
        // rather than leaving the row unexplained.
        if !isChatCapable(info) {
            return ProviderUILocalization.text(
                "wizard.org_kind.api_only",
                fallback: "API only · no Claude subscription"
            )
        }
        if info.capabilities.contains(maxCapability) {
            return ProviderUILocalization.text(
                "wizard.org_kind.personal_max",
                fallback: "Personal · Max"
            )
        }
        if info.capabilities.contains(proCapability) {
            return ProviderUILocalization.text(
                "wizard.org_kind.personal_pro",
                fallback: "Personal · Pro"
            )
        }
        return ProviderUILocalization.text(
            "wizard.org_kind.unknown",
            fallback: "Unknown"
        )
    }

    // MARK: - Picker policy
    //
    // Both organization pickers (the setup wizard and the credentials pane)
    // call these, so the two cannot drift apart.

    /// The organizations a picker may draw: chat-capable only, in the server's
    /// own order.
    ///
    /// Console/API-only organizations are left out rather than dimmed. They can
    /// never be chosen and carry no Claude subscription usage for this app to
    /// track, so a disabled row was only ever an obstacle — on a live
    /// five-organization account the two dead rows pushed the real choices, and
    /// the Back/Next bar, off the bottom of a fixed-size sheet.
    ///
    /// A caller that draws this list must also draw `hiddenAPIOnlyNotice(for:)`,
    /// or an account holder sees a workspace missing from the picker with no
    /// explanation.
    static func pickerRows(
        _ organizations: [ClaudeAPIService.AccountInfo]
    ) -> [ClaudeAPIService.AccountInfo] {
        organizations.filter { isChatCapable($0) }
    }

    /// How many organizations `pickerRows` left out, for the footnote that
    /// explains the gap.
    static func hiddenAPIOnlyCount(
        _ organizations: [ClaudeAPIService.AccountInfo]
    ) -> Int {
        organizations.filter { !isChatCapable($0) }.count
    }

    /// The footnote a picker shows beside `pickerRows`, or `nil` when nothing
    /// was left out and there is nothing to explain.
    ///
    /// Takes the same array `pickerRows` takes, so the sentence and the list can
    /// never be built from different inputs.
    static func hiddenAPIOnlyNotice(
        for organizations: [ClaudeAPIService.AccountInfo]
    ) -> String? {
        hiddenAPIOnlyNotice(count: hiddenAPIOnlyCount(organizations))
    }

    /// The footnote for a known count. Exposed separately so the
    /// singular/plural choice can be tested without building organizations.
    ///
    /// Two keys rather than one: "1 API-only organizations hidden" is wrong in
    /// English and worse in German. This app ships no `.stringsdict`, so the
    /// choice is made here, by `count == 1`, rather than by CLDR plural
    /// categories. Every one of the nine shipped locales (de en es fr it ja ko
    /// pt zh-Hans) has at most a one/other distinction, so two forms are enough;
    /// a language with a paucal or few form would need a `.stringsdict` instead.
    static func hiddenAPIOnlyNotice(count: Int) -> String? {
        guard count > 0 else { return nil }
        if count == 1 {
            return ProviderUILocalization.text(
                "wizard.api_only_hidden.one",
                fallback: "1 API-only organization hidden — it has no Claude usage to track."
            )
        }
        return String(
            format: ProviderUILocalization.text(
                "wizard.api_only_hidden.other",
                fallback: "%ld API-only organizations hidden — they have no Claude usage to track."
            ),
            count
        )
    }

    /// Organizations the pickers leave out that are not positively marked
    /// `"api"` — the shape the server has never actually returned.
    ///
    /// `capabilities` decodes as `decodeIfPresent(…) ?? []`, so an organization
    /// returned without the field at all reads as not chat-capable and is left
    /// out under a footnote calling it API-only. That would be the wrong
    /// sentence about a real Claude workspace, so the case is logged where the
    /// list is first received rather than left silent.
    static func unclassifiableOrganizations(
        _ organizations: [ClaudeAPIService.AccountInfo]
    ) -> [ClaudeAPIService.AccountInfo] {
        organizations.filter {
            !isChatCapable($0) && !$0.capabilities.contains(apiCapability)
        }
    }

    /// The organization a picker should start on: the first one that can
    /// actually report usage, in server order. `nil` when the account has no
    /// Claude subscription organization at all — the picker must then select
    /// nothing rather than fall back to a console organization.
    static func defaultSelection(
        _ organizations: [ClaudeAPIService.AccountInfo]
    ) -> String? {
        organizations.first(where: { isChatCapable($0) })?.uuid
    }

    /// Whether an account has any organization worth selecting.
    static func hasSelectableOrganization(
        _ organizations: [ClaudeAPIService.AccountInfo]
    ) -> Bool {
        defaultSelection(organizations) != nil
    }

    /// The last line of defence before a selection is persisted.
    ///
    /// Binding a profile to a console/API organization produces a permanently
    /// unavailable popover, so this must not depend on the UI having disabled
    /// the row. An id with no matching organization is refused too: the only
    /// legitimate source of the id is the list being checked against.
    static func permitsSelection(
        of organizationID: String?,
        from organizations: [ClaudeAPIService.AccountInfo]
    ) -> Bool {
        guard
            let organizationID,
            let organization = organizations.first(
                where: { $0.uuid == organizationID }
            )
        else { return false }
        return isChatCapable(organization)
    }
}
