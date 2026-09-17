import Foundation

/// Whether the Claude Code login a profile is bound to is still the account
/// that profile stands for.
///
/// A profile is bound to a Claude Code login by *directory name*
/// (`Profile.cliAccountName` → `~/.claude-accounts/<name>`), and a directory
/// name is not an identity: two directories can hold a login for one account,
/// in which case two profiles fetch that one account and publish its
/// percentages as two independent readings with nothing on screen to say why.
///
/// The identity used here is `oauthAccount.accountUuid` from the bound
/// directory's own `.claude.json` — the file `ClaudeSwitchService` already
/// opens and parses to read `accessToken` out of the same object. No request
/// is made: `GET /api/oauth/profile` answers with an organization, and a
/// personal Max/Pro subscription has none, which is why the organization
/// comparison cannot separate two personal accounts and this one can.
///
/// The decision is a pure function on purpose. Every branch is a judgement
/// about identity rather than about files or networking, which is what makes
/// it testable without a profile store, a directory, or a request.
enum ClaudeAccountIdentityGuard {

    /// Who a Claude Code configuration directory is signed in as.
    ///
    /// The email address is carried for the message a person reads, never for
    /// the comparison: one person can hold two accounts under one email, so
    /// only the uuid decides.
    struct ClaudeCodeAccount: Equatable, Sendable {
        let uuid: String
        let emailAddress: String?

        init(uuid: String, emailAddress: String? = nil) {
            self.uuid = uuid
            self.emailAddress = emailAddress
        }
    }

    /// The parts of a profile this decision reads. A value type rather than
    /// `Profile` so the guard depends on neither the model nor the store.
    struct ProfileBinding: Equatable, Sendable {
        let id: UUID
        let name: String
        /// The claude.ai organization this profile displays. Read only by
        /// `browserSignInVerdict`; the Claude Code verdict never uses it,
        /// because a personal login reports no organization at all.
        let organizationUUID: String?
        /// The Anthropic account its Claude Code login carried when the
        /// binding was last accepted. Nil until the first reading.
        let accountUUID: String?

        init(
            id: UUID,
            name: String,
            organizationUUID: String?,
            accountUUID: String?
        ) {
            self.id = id
            self.name = name
            self.organizationUUID = organizationUUID
            self.accountUUID = accountUUID
        }
    }

    /// Why a credential does not belong to the profile holding it.
    enum Mismatch: Equatable, Sendable {
        /// The bound directory is signed in as an account other than the one
        /// this profile accepted.
        case differentAccount(expected: String, actual: String)
        /// Another profile is already showing this account's numbers. The
        /// case that catches two directory names holding one login, which is
        /// the defect this guard exists for.
        case accountAlreadyBound(profileName: String)
        /// A claude.ai sign-in that cannot see the organization this profile
        /// displays. Configuration-time only.
        case differentOrganization(expected: String, actual: String)
    }

    enum Verdict: Equatable, Sendable {
        case belongsToThisProfile
        /// Nothing could be established: no directory, no `oauthAccount`, an
        /// unreadable file. Always fail open — an identity that could not be
        /// read must never blank a working reading.
        case undetermined
        case mismatch(Mismatch)

        var isMismatch: Bool {
            if case .mismatch = self { return true }
            return false
        }
    }

    /// The verdict on the Claude Code login a profile is bound to.
    ///
    /// - Parameters:
    ///   - account: what the bound directory's `.claude.json` says, or nil
    ///     when there is no directory, no `oauthAccount`, or no readable
    ///     `accountUuid`.
    ///   - profile: the profile the numbers would be published under.
    ///   - otherProfiles: every other profile, so a login already feeding one
    ///     of them is refused here.
    static func verdict(
        claudeCodeAccount account: ClaudeCodeAccount?,
        for profile: ProfileBinding,
        otherProfiles: [ProfileBinding]
    ) -> Verdict {
        // Nothing to compare. A profile with no Claude Code directory, or a
        // directory whose `.claude.json` carries no account, is not evidence
        // of anything and keeps its numbers.
        guard let account, !account.uuid.isEmpty else { return .undetermined }

        // The check the organization comparison cannot make. Two personal
        // subscriptions both report no organization through the API, so this
        // is the only thing that separates them — and one account behind two
        // profiles is the defect itself, not a configuration anyone chose.
        // Checked before the profile's own recorded identity, so a machine
        // that is already in the broken state is caught on the first reading
        // rather than after a re-link.
        if let clash = otherProfiles.first(where: {
            $0.id != profile.id && $0.accountUUID == account.uuid
        }) {
            return .mismatch(.accountAlreadyBound(profileName: clash.name))
        }

        guard let expected = profile.accountUUID else {
            // First reading, or a profile bound before this field existed.
            // Adopting the account it is signed in as is the only answer that
            // does not blank a working profile on upgrade; the clash check
            // above already refused the one case where adopting would be
            // wrong.
            return .belongsToThisProfile
        }

        if expected != account.uuid {
            return .mismatch(
                .differentAccount(expected: expected, actual: account.uuid)
            )
        }

        return .belongsToThisProfile
    }

    /// The verdict on a claude.ai browser sign-in, which names organizations
    /// rather than an account.
    ///
    /// Kept separate from the Claude Code verdict because the two credentials
    /// carry different identities: the browser sign-in can see a list of
    /// organizations, and the terminal sign-in belongs to an account.
    ///
    /// - Parameters:
    ///   - organizationUUIDs: every organization the pasted key can see, from
    ///     `GET /api/organizations`.
    static func browserSignInVerdict(
        organizationUUIDs: [String],
        for profile: ProfileBinding,
        otherProfiles: [ProfileBinding]
    ) -> Verdict {
        guard !organizationUUIDs.isEmpty else { return .undetermined }

        if let expected = profile.organizationUUID,
           !organizationUUIDs.contains(expected) {
            return .mismatch(
                .differentOrganization(
                    expected: expected,
                    actual: organizationUUIDs[0]
                )
            )
        }

        // Deliberately NOT refusing a key whose organization another profile
        // already shows. Two profiles on one ORGANIZATION is a supported
        // setup — a team with two seats, two people, two sets of member
        // figures — and this codebase says so twice, at
        // `ClaudeAPIService.swift`'s `fetchUsageData(using:)` ("organization
        // id which more than one profile can share") and on
        // `CapturedUsageRequest.profileID` ("which two profiles can share").
        // Two profiles on one ACCOUNT is the defect; one organization is not.
        return .belongsToThisProfile
    }

    // MARK: - Refusals people read

    /// Why a pasted claude.ai sign-in was refused, in the words shown in the
    /// sign-in sheet.
    ///
    /// Localized with an English default rather than a bare key, the way the
    /// popover's notices are: a locale with no translation yet must read as a
    /// sentence, not as `claude_identity.browser.already_bound`.
    static func browserSignInRefusal(
        _ mismatch: Mismatch,
        accountName: String?
    ) -> String {
        switch mismatch {
        case .differentOrganization, .differentAccount:
            let name = accountName ?? "another account"
            return string(
                "claude_identity.browser.different_account",
                default: "This sign-in belongs to %@, not to this profile's "
                    + "account. Sign in to the account this profile is for, "
                    + "or set up a separate profile for that one.",
                name
            )
        case .accountAlreadyBound(let profileName):
            // Not reachable from `browserSignInVerdict`, which no longer
            // refuses a shared organization. Kept because `Mismatch` is
            // shared with the Claude Code verdict and this switch is total.
            return string(
                "claude_identity.browser.already_bound",
                default: "Profile '%@' is already signed in to this "
                    + "account.",
                profileName
            )
        }
    }

    /// Why a Claude Code account was refused, in the words shown on the
    /// Claude Account settings card.
    static func claudeCodeLinkRefusal(
        _ mismatch: Mismatch,
        emailAddress: String? = nil
    ) -> String {
        switch mismatch {
        case .differentOrganization, .differentAccount:
            // Names the step that actually re-points a profile. Unlinking
            // clears the account this profile accepted, so the next link
            // adopts whichever account the directory is signed in as; saying
            // "make another profile" would send someone building a second
            // profile when what they want is this one pointed elsewhere.
            if let emailAddress {
                return string(
                    "claude_identity.terminal.different_account_named",
                    default: "This Claude Code account directory is signed "
                        + "in as %@, which is not the account this profile "
                        + "was linked to. Sign in to that account again "
                        + "here, or use Unlink and then Link to point this "
                        + "profile at the account the directory now holds.",
                    emailAddress
                )
            }
            return string(
                "claude_identity.terminal.different_account",
                default: "This Claude Code account directory is signed in as "
                    + "a different account than this profile was linked to. "
                    + "Sign in to that account again here, or use Unlink and "
                    + "then Link to point this profile at the account the "
                    + "directory now holds."
            )
        case .accountAlreadyBound(let profileName):
            return string(
                "claude_identity.terminal.already_bound",
                default: "Profile '%@' is already using this Claude Code "
                    + "account, and two profiles on one account show the "
                    + "same numbers. Sign this directory in to a different "
                    + "account, or unlink it from '%@' first.",
                profileName,
                profileName
            )
        }
    }

    private static func string(
        _ key: String,
        default defaultValue: String,
        _ arguments: CVarArg...
    ) -> String {
        let format = Bundle.main.localizedString(
            forKey: key,
            value: defaultValue,
            table: nil
        )
        guard !arguments.isEmpty else { return format }
        return String(
            format: format,
            locale: .autoupdatingCurrent,
            arguments: arguments
        )
    }

    /// Whether a freshly read account uuid is worth writing to the profile.
    /// Recorded once, on the first reading that passes, so a later re-link to
    /// a different account is a `differentAccount` mismatch rather than a
    /// silent re-binding.
    static func shouldRecordAccountUUID(
        _ account: String?,
        on profile: ProfileBinding
    ) -> Bool {
        guard let account, !account.isEmpty else { return false }
        return profile.accountUUID != account
    }
}
