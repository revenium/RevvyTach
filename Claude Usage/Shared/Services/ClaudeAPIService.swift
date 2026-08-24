import Foundation

/// Service for fetching usage data directly from Claude's API
class ClaudeAPIService: APIServiceProtocol {
    // MARK: - Types

    /// Authentication method for API requests
    private enum AuthenticationType {
        case claudeAISession(String)      // Cookie: sessionKey=...
        case cliOAuth(String)              // Authorization: Bearer ... (with anthropic-beta header)
        case consoleAPISession(String)     // Cookie: sessionKey=... (different endpoint)
    }

    enum CapturedUsageFetchSource: Equatable, Sendable {
        case claudeAI(checkOverage: Bool)
        case profileCLI
        case systemCLI
    }

    /// Request-scoped authentication captured before async work begins.
    /// Deliberately neither Codable nor CustomStringConvertible so credentials
    /// cannot drift through persistence or routine diagnostics.
    struct CapturedUsageRequest: Sendable {
        let source: CapturedUsageFetchSource
        fileprivate let sessionKey: String?
        fileprivate let organizationID: String?
        fileprivate let oauthAccessToken: String?
        /// The profile this request was captured for. Not a credential — an
        /// identity marker so the eventual fetch can re-resolve the exact
        /// profile in progress instead of guessing one from `organizationID`
        /// alone, which two profiles can share.
        fileprivate let profileID: UUID

        func capturesOAuthToken(_ candidate: String) -> Bool {
            oauthAccessToken == candidate
        }
    }

    /// Request-scoped Console API credentials. This value is intentionally
    /// opaque and has no Codable or printable conformance.
    struct CapturedAPIUsageRequest: Sendable {
        fileprivate let organizationID: String
        fileprivate let apiSessionKey: String

        func capturesCredentials(
            organizationID: String,
            apiSessionKey: String
        ) -> Bool {
            self.organizationID == organizationID
                && self.apiSessionKey == apiSessionKey
        }
    }

    // MARK: - Properties

    private let sessionKeyPath: URL
    private let sessionKeyValidator: SessionKeyValidator
    private let profileManager: ProfileManager
    /// Reads the system Claude Code login for one linked account.
    ///
    /// Takes the account name because a profile's login lives in that
    /// account's own Keychain item; reading without one returns whichever
    /// account happens to own the shared item, which on a multi-account
    /// machine means authenticating as somebody else. The injectable form
    /// stays argument-free so the seam reads the same in tests.
    private let systemCredentialsReader: (String?) throws -> String?

    /// Persists a renewed CLI credential. Injectable for the same reason
    /// `systemCredentialsReader` is: it is the one step of the renewal path
    /// that reaches the real credential store, so without a seam here a test
    /// that exercises renewal writes to the developer's own Keychain and
    /// triggers a macOS authorization prompt.
    private let renewedCredentialWriter: (String, UUID) throws -> Void
    let baseURL = Constants.APIEndpoints.claudeBase
    let consoleBaseURL = Constants.APIEndpoints.consoleBase

    // MARK: - Initialization

    init(
        sessionKeyPath: URL? = nil,
        sessionKeyValidator: SessionKeyValidator = SessionKeyValidator(),
        profileManager: ProfileManager? = nil,
        systemCredentialsReader: (() throws -> String?)? = nil,
        renewedCredentialWriter: ((String, UUID) throws -> Void)? = nil
    ) {
        // Default path: ~/.claude-session-key
        self.sessionKeyPath = sessionKeyPath ?? Constants.ClaudePaths.homeDirectory
            .appendingPathComponent(".claude-session-key")
        self.sessionKeyValidator = sessionKeyValidator
        self.profileManager = profileManager ?? .shared
        self.systemCredentialsReader =
            systemCredentialsReader.map { injected in
                { _ in try injected() }
            }
            ?? { accountName in
                try ClaudeCodeSyncService.shared.readSystemCredentials(
                    forAccountNamed: accountName
                )
            }
        self.renewedCredentialWriter =
            renewedCredentialWriter
            ?? {
                try ClaudeCodeSyncService.shared
                    .saveRefreshedCredentials($0, for: $1)
            }
    }

    // MARK: - Session Key Management

    /// Reads and validates the session key from active profile
    private func readSessionKey() throws -> String {
        do {
            // Load from active profile only
            guard let activeClaudeProfile = profileManager.activeClaudeProfile else {
                LoggingService.shared.logError("ClaudeAPIService.readSessionKey: No active profile")
                throw AppError.sessionKeyNotFound()
            }

            LoggingService.shared.log(
                "ClaudeAPIService.readSessionKey: Resolving active profile credentials"
            )

            guard let key = activeClaudeProfile.claudeSessionKey else {
                LoggingService.shared.logError("ClaudeAPIService.readSessionKey: Profile has NIL claudeSessionKey - throwing sessionKeyNotFound")
                throw AppError.sessionKeyNotFound()
            }

            let validatedKey = try sessionKeyValidator.validate(key)
            LoggingService.shared.log("ClaudeAPIService.readSessionKey: Key validated successfully")
            return validatedKey

        } catch let error as SessionKeyValidationError {
            // Convert validation errors to AppError
            throw AppError.wrap(error)
        } catch let error as AppError {
            // Re-throw AppError as-is
            throw error
        } catch {
            let appError = AppError(
                code: .storageReadFailed,
                message: "Failed to read session key from profile",
                technicalDetails: error.localizedDescription,
                underlyingError: error,
                isRecoverable: true,
                recoverySuggestion: "Please check your session key configuration in the active profile"
            )
            ErrorLogger.shared.log(appError)
            throw appError
        }
    }

    /// Gets the best available authentication method with fallback support
    /// Priority: 1) claude.ai session → 2) saved CLI OAuth → 3) system Keychain CLI OAuth
    /// Note: Console API session is NOT used as fallback (it only provides billing data, not usage)
    private func getAuthentication() throws -> AuthenticationType {
        guard let activeClaudeProfile = profileManager.activeClaudeProfile else {
            LoggingService.shared.logError("ClaudeAPIService.getAuthentication: No active profile")
            throw AppError.sessionKeyNotFound()
        }

        // Try claude.ai session key first
        if let sessionKey = activeClaudeProfile.claudeSessionKey {
            do {
                let validatedKey = try sessionKeyValidator.validate(sessionKey)
                LoggingService.shared.log("ClaudeAPIService: Using claude.ai session key")
                return .claudeAISession(validatedKey)
            } catch {
                LoggingService.shared.logError("ClaudeAPIService: claude.ai session key validation failed: \(error.localizedDescription)")
            }
        }

        // Fall back to saved CLI OAuth token if available and not expired
        if let cliJSON = activeClaudeProfile.cliCredentialsJSON {
            if !ClaudeCodeSyncService.shared.isTokenExpired(cliJSON),
               let accessToken = ClaudeCodeSyncService.shared.extractAccessToken(from: cliJSON) {
                LoggingService.shared.log("ClaudeAPIService: Falling back to saved CLI OAuth token")
                return .cliOAuth(accessToken)
            } else {
                LoggingService.shared.log("ClaudeAPIService: Saved CLI OAuth token is expired or invalid")
            }
        }

        // Fall back to reading CLI credentials directly from system Keychain,
        // scoped to the account this profile is linked to. Reading the shared
        // item here authenticated as whichever account last wrote it.
        do {
            if let systemCredentials = try ClaudeCodeSyncService.shared
                .readSystemCredentials(
                    forAccountNamed: activeClaudeProfile.cliAccountName
                ) {
                LoggingService.shared.log("ClaudeAPIService: Found CLI credentials in system Keychain")

                // Validate token is not expired
                if ClaudeCodeSyncService.shared.isTokenExpired(systemCredentials) {
                    LoggingService.shared.log("ClaudeAPIService: System Keychain CLI token is expired")
                } else if let accessToken = ClaudeCodeSyncService.shared.extractAccessToken(from: systemCredentials) {
                    LoggingService.shared.log("ClaudeAPIService: Using CLI credentials from system Keychain")
                    return .cliOAuth(accessToken)
                } else {
                    LoggingService.shared.log("ClaudeAPIService: Could not extract access token from system Keychain credentials")
                }
            } else {
                LoggingService.shared.log("ClaudeAPIService: No CLI credentials found in system Keychain")
            }
        } catch {
            LoggingService.shared.log("ClaudeAPIService: Could not read system CLI credentials: \(error.localizedDescription)")
        }

        LoggingService.shared.logError("ClaudeAPIService.getAuthentication: No valid credentials for usage data")
        throw AppError.sessionKeyNotFound()
    }

    /// Builds an authenticated request with the appropriate headers for the auth type
    private func buildAuthenticatedRequest(url: URL, auth: AuthenticationType) -> URLRequest {
        var request = URLRequest(url: url)

        switch auth {
        case .claudeAISession(let sessionKey):
            // Existing claude.ai authentication
            request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

        case .cliOAuth(let accessToken):
            // CLI OAuth authentication (requires specific headers)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("claude-code/2.1.5", forHTTPHeaderField: "User-Agent")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        case .consoleAPISession(let apiKey):
            // Console API authentication
            request.setValue("sessionKey=\(apiKey)", forHTTPHeaderField: "Cookie")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        }

        return request
    }

    /// Saves a session key with smart org ID preservation
    /// Only clears org ID if the key actually changed
    func saveSessionKey(_ key: String, preserveOrgIfUnchanged: Bool = true) throws {
        do {
            // Validate the key before saving
            let validatedKey = try sessionKeyValidator.validate(key)

            guard let profileId = profileManager.activeClaudeProfile?.id else {
                throw AppError(
                    code: .storageWriteFailed,
                    message: "No active profile found",
                    technicalDetails: "Cannot save session key without an active profile",
                    isRecoverable: true,
                    recoverySuggestion: "Please ensure a profile is active"
                )
            }

            // Check if key actually changed (for smart org clearing)
            var shouldClearOrg = true
            if preserveOrgIfUnchanged {
                let existingKey = profileManager.activeClaudeProfile?.claudeSessionKey
                shouldClearOrg = (existingKey != validatedKey)
            }

            // Save to active profile
            var credentials = try profileManager.loadCredentials(for: profileId)
            credentials.claudeSessionKey = validatedKey
            if shouldClearOrg {
                credentials.organizationId = nil
            }
            try profileManager.saveCredentials(for: profileId, credentials: credentials)

            LoggingService.shared.log("Session key saved to active profile")

            // Only clear org ID if key actually changed
            if shouldClearOrg {
                clearOrganizationIdCache()
                LoggingService.shared.log("Session key changed - cleared organization ID")
            } else {
                LoggingService.shared.log("Session key unchanged - preserving organization ID")
            }

        } catch let error as SessionKeyValidationError {
            // Convert validation errors to AppError
            throw AppError.wrap(error)
        } catch {
            // Keychain errors
            let appError = AppError(
                code: .sessionKeyStorageFailed,
                message: "Failed to save session key",
                technicalDetails: error.localizedDescription,
                underlyingError: error,
                isRecoverable: true,
                recoverySuggestion: "Please check Keychain access and try again"
            )
            ErrorLogger.shared.log(appError)
            throw appError
        }
    }

    // MARK: - Organization ID Caching

    /// Cache organization ID to reduce API calls
    private var cachedOrgId: String?
    private var cachedOrgIdSessionKey: String?

    /// Clears the cached organization ID (call when session key changes)
    func clearOrganizationIdCache() {
        cachedOrgId = nil
        cachedOrgIdSessionKey = nil
    }

    // MARK: - API Requests

    /// Fetches all organizations for the authenticated user
    func fetchAllOrganizations(sessionKey: String? = nil) async throws -> [AccountInfo] {
        return try await ErrorRecovery.shared.executeWithRetry(maxAttempts: 3) {
            let sessionKey = try sessionKey ?? self.readSessionKey()

            // Build URL safely
            let url: URL
            do {
                url = try URLBuilder(baseURL: self.baseURL)
                    .appendingPath("/organizations")
                    .build()
            } catch {
                throw AppError.wrap(error)
            }

            var request = URLRequest(url: url)
            request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.httpMethod = "GET"
            request.timeoutInterval = 30

            let startTime = Date()
            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch {
                // Network errors
                let duration = Date().timeIntervalSince(startTime)
                NetworkLoggerService.shared.logRequest(
                    url: url.absoluteString,
                    method: "GET",
                    requestBody: request.httpBody,
                    responseData: nil,
                    statusCode: nil,
                    duration: duration,
                    error: error
                )

                let appError = AppError(
                    code: .networkGenericError,
                    message: "Failed to connect to Claude API",
                    technicalDetails: error.localizedDescription,
                    underlyingError: error,
                    isRecoverable: true,
                    recoverySuggestion: "Please check your internet connection and try again"
                )
                ErrorLogger.shared.log(appError)
                throw appError
            }

            let duration = Date().timeIntervalSince(startTime)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw AppError(
                    code: .apiInvalidResponse,
                    message: "Invalid response from server",
                    isRecoverable: true
                )
            }

            // Log to NetworkLoggerService
            NetworkLoggerService.shared.logRequest(
                url: url.absoluteString,
                method: "GET",
                requestBody: request.httpBody,
                responseData: data,
                statusCode: httpResponse.statusCode,
                duration: duration,
                error: nil
            )

            switch httpResponse.statusCode {
            case 200:
                // Parse organizations array
                do {
                    let organizations = try JSONDecoder().decode([AccountInfo].self, from: data)
                    guard !organizations.isEmpty else {
                        throw AppError(
                            code: .apiParsingFailed,
                            message: "No organizations found",
                            technicalDetails: "Organizations array is empty",
                            isRecoverable: false,
                            recoverySuggestion: "Please ensure your Claude account has access to organizations"
                        )
                    }

                    // Log all available organizations for debugging
                    LoggingService.shared.logInfo("Found \(organizations.count) organization(s):")
                    for (index, org) in organizations.enumerated() {
                        LoggingService.shared.logInfo("  [\(index)] \(org.name) (ID: \(org.uuid))")
                    }

                    return organizations
                } catch {
                    let appError = AppError(
                        code: .apiParsingFailed,
                        message: "Failed to parse organizations",
                        technicalDetails: error.localizedDescription,
                        underlyingError: error,
                        isRecoverable: false
                    )
                    ErrorLogger.shared.log(appError)
                    throw appError
                }

            case 401, 403:
                throw AppError.apiUnauthorized()

            case 429:
                throw AppError.apiRateLimited()

            case 500...599:
                throw AppError.apiServerError(statusCode: httpResponse.statusCode)

            default:
                throw AppError(
                    code: .apiGenericError,
                    message: "Unexpected API response",
                    technicalDetails: "HTTP \(httpResponse.statusCode)",
                    isRecoverable: true
                )
            }
        }
    }

    // MARK: - Read-Only Testing

    /// Tests a session key without saving to Keychain
    /// Returns available organizations if successful
    func testSessionKey(_ key: String) async throws -> [AccountInfo] {
        // Validate using professional validator
        let validatedKey = try sessionKeyValidator.validate(key)

        // Fetch organizations using the test key (don't save it)
        let organizations = try await fetchAllOrganizations(sessionKey: validatedKey)

        LoggingService.shared.logInfo("Tested session key - found \(organizations.count) organization(s)")

        return organizations
    }

    /// Fetches the organization ID for the authenticated user
    /// Uses stored org ID if available, otherwise fetches all orgs and auto-selects
    func fetchOrganizationId(sessionKey: String? = nil) async throws -> String {
        let sessionKey = try sessionKey ?? self.readSessionKey()

        // Check for stored organization ID in active profile first
        if let storedOrgId = profileManager.activeClaudeProfile?.organizationId {
            LoggingService.shared.logInfo("Using stored organization ID from profile: \(storedOrgId)")
            return storedOrgId
        }

        // No stored org ID - fetch all organizations
        LoggingService.shared.logInfo("No stored organization ID - fetching all organizations")
        let organizations = try await fetchAllOrganizations(sessionKey: sessionKey)

        guard !organizations.isEmpty else {
            throw AppError(
                code: .apiParsingFailed,
                message: "No organizations found",
                technicalDetails: "Organizations array is empty",
                isRecoverable: false,
                recoverySuggestion: "Please ensure your Claude account has access to organizations"
            )
        }

        // The list mixes Claude organizations with console/API-only ones that
        // have no chat, no subscription and no usage to report. Selecting one
        // of those binds the profile to an organization every usage request
        // will fail against — and on a real account an API-only organization
        // was the FIRST entry returned.
        let usableOrganizations = organizations.filter(
            ClaudeOrganizationClassifier.isChatCapable
        )

        guard let selectedOrg = usableOrganizations.first else {
            throw AppError(
                code: .apiParsingFailed,
                message: "No Claude organizations found",
                technicalDetails:
                    "None of the \(organizations.count) organization(s) for this session key "
                    + "have the \"chat\" capability; they appear to be console/API-only "
                    + "organizations without a Claude subscription",
                isRecoverable: false,
                recoverySuggestion:
                    "Sign in with an account that has a Claude subscription (Pro, Max, Team or Enterprise)"
            )
        }

        // TODO: An account belonging to more than one organization needs an
        // interactive picker here. Auto-selecting silently binds the profile
        // to whichever organization the API happened to list first.
        if usableOrganizations.count > 1 {
            LoggingService.shared.logWarning(
                "Session key belongs to \(usableOrganizations.count) Claude organizations "
                + "(\(organizations.count) total including console/API-only); "
                + "auto-selected \(selectedOrg.name) (ID: \(selectedOrg.uuid)) "
                + "without asking. Usage and extra-usage figures will describe "
                + "that organization only."
            )
        } else {
            LoggingService.shared.logInfo(
                "Auto-selected organization: \(selectedOrg.name) (ID: \(selectedOrg.uuid))"
            )
        }

        // Store the selected org ID in active profile
        if let profileId = profileManager.activeClaudeProfile?.id {
            profileManager.updateOrganizationId(selectedOrg.uuid, for: profileId)
            applyOrganizationClassification(selectedOrg, to: profileId)
        }

        return selectedOrg.uuid
    }

    /// Caches the organizations whose classification lookup already ran and
    /// came back inconclusive, so a refresh tick does not re-request
    /// `/organizations` on every single poll.
    private var classificationAttemptedOrganizationIDs: Set<String> = []

    /// Records an organization's name and personal/shared classification on a
    /// profile so the extra-usage label can be resolved without a network
    /// request on subsequent refreshes.
    private func applyOrganizationClassification(
        _ organization: AccountInfo,
        to profileId: UUID
    ) {
        profileManager.updateOrganizationName(organization.name, for: profileId)
        if let isPersonal = ClaudeOrganizationClassifier.isPersonal(organization) {
            profileManager.updateOrganizationIsPersonal(isPersonal, for: profileId)
        }
    }

    /// Resolves who the organization-scoped extra-usage figures belong to.
    ///
    /// `overage_spend_limit` is organization-scoped with no member parameter,
    /// so the honest default is `.organization`; `.personal` is returned only
    /// when the organization is known to have a single member. The
    /// `/organizations` lookup runs at most once per organization per app run
    /// and only when the profile has no stored classification — the sequential
    /// request discipline in `fetchUsageData` exists because extra per-profile
    /// requests on every tick contributed to 429s.
    private func resolveExtraUsageScope(
        organizationId: String,
        sessionKey: String
    ) async -> ClaudeUsage.ExtraUsageScope {
        guard let profile = profileManager.profiles.first(
            where: { $0.organizationId == organizationId }
        ) else {
            return .organization
        }

        if let isPersonal = profile.organizationIsPersonal {
            return isPersonal ? .personal : .organization
        }

        guard !classificationAttemptedOrganizationIDs.contains(organizationId) else {
            return .organization
        }
        classificationAttemptedOrganizationIDs.insert(organizationId)

        guard
            let organizations = try? await fetchAllOrganizations(sessionKey: sessionKey),
            let match = organizations.first(where: { $0.uuid == organizationId })
        else {
            LoggingService.shared.logWarning(
                "Could not classify organization \(organizationId) as personal "
                + "or shared; extra usage will be labelled organization-wide."
            )
            return .organization
        }

        applyOrganizationClassification(match, to: profile.id)
        return ClaudeOrganizationClassifier.isPersonal(match) == true
            ? .personal
            : .organization
    }

    // MARK: - Member-scoped extra usage

    /// `api.anthropic.com` endpoints reached with the CLI OAuth token. These
    /// describe the signed-in member; the claude.ai `/organizations/...`
    /// endpoints above describe the whole organization.
    private static let oauthUsageURL =
        "https://api.anthropic.com/api/oauth/usage"
    private static let oauthProfileURL =
        "https://api.anthropic.com/api/oauth/profile"

    /// The credential fingerprint each profile last presented, so a
    /// replacement can retire the failure records of the one it replaced.
    private var lastSeenCredentialFingerprints: [UUID: Int] = [:]

    /// Credentials whose renewal failed because the login itself is too old —
    /// the token endpoint answered `invalid_grant`.
    ///
    /// This is the *only* short circuit. It is a settled answer about a
    /// specific credential: retrying costs a request per refresh tick and
    /// cannot succeed until that credential is replaced, which
    /// `forgetRenewalFailures(for:nowPresenting:)` detects.
    ///
    /// Everything else — offline, a 500, a timeout — is now retried on the
    /// next tick. It used to land in a companion set that was never cleared,
    /// so one bad moment disabled renewal of that credential for the rest of
    /// the process. This app runs for days at a time, so "the network blipped
    /// once" and "this login is dead" became the same outcome, and the second
    /// is what the popover reported.
    private var expiredCLILogins: Set<Int> = []

    /// Stored credentials this run has already tried to replace with the
    /// CLI's own live login, keyed to when that attempt happened, so the
    /// Keychain read behind `adoptLiveCLILogin(for:replacing:)` is throttled
    /// per dead credential rather than repeated on every refresh tick. A
    /// successful adoption changes the stored credential, so the next
    /// credential to go stale has a different fingerprint and gets its own
    /// attempt.
    ///
    /// This is throttled by time, not blocked forever after one try: the
    /// notice shown once adoption fails tells the user that signing in to
    /// Claude Code is enough for usage to reappear on its own, and that is
    /// only true if a later refresh gets to look again. A `Set` recorded the
    /// attempt permanently, so the one adoption attempt was normally already
    /// spent by the time the notice appeared, and the promised recovery could
    /// never actually happen without an app restart.
    private var liveCLILoginAdoptionAttempts: [Int: Date] = [:]

    /// How long a stale credential's failed adoption attempt is honored
    /// before another Keychain read is allowed. Exposed for tests: the
    /// default makes a live back-to-back refresh over the same dead
    /// credential read once, and a zero interval makes every refresh retry.
    var liveCLILoginAdoptionRetryInterval: TimeInterval = 60

    /// Credentials renewed during this app run, keyed by profile, each paired
    /// with the fingerprint of the stored credential it was renewed *from*.
    /// The durable store holds the same value; this keeps the run from
    /// re-reading the expired copy still held in memory by the profile list.
    ///
    /// The base fingerprint is what makes a re-link visible. Renewing a token
    /// does not change which account a profile is linked to, but re-linking
    /// does — and without this, the renewed copy of the OLD account's login
    /// went on being preferred over the replacement for the rest of the run.
    /// The replacement's fingerprint then never reached
    /// `cliOrganizationID(for:credential:)`, so the invalidation there could
    /// not fire and the profile kept the previous account's identity until
    /// the app restarted.
    private var renewedCLICredentials: [UUID: (base: Int, credentialsJSON: String)] = [:]

    /// The CLI credential each profile's organization was last resolved
    /// from. An absent entry means the lookup has not run yet this app run.
    private var cliOrganizationCredentialHashes: [UUID: Int] = [:]

    /// Profiles whose organization lookup already failed this app run.
    private var failedCLIOrganizationLookups: Set<UUID> = []

    /// The credential fingerprint in use the last time a profile's entry in
    /// `failedCLIOrganizationLookups` was recorded. `cliOrganizationCredentialHashes`
    /// is only ever written on a *successful* lookup, so it cannot answer
    /// "has the credential changed since the failure" — this does. A later
    /// call presenting a different fingerprint means the profile was
    /// re-linked to a different Claude Code account since that failure, and
    /// the failure must not suppress a retry with the new credential.
    private var failedCLIOrganizationLookupFingerprints: [UUID: Int] = [:]

    /// The member's figure, or the reason it is missing. The reason reaches
    /// the popover: "link an account" and "renew the one you have" send a
    /// person to different actions on the same screen, and telling a linked
    /// user to link sends them somewhere with nothing to do.
    private enum PersonalExtraUsageOutcome {
        case available(OAuthUsageResponse.ExtraUsage)
        case issue(ClaudeUsage.PersonalExtraUsageIssue)
        /// Nothing to report: no profile, or the member has extra usage off.
        case notApplicable
    }

    private func personalExtraUsage(
        for profile: Profile,
        organizationId: String
    ) async -> PersonalExtraUsageOutcome {
        // The profile is threaded straight through from the caller that is
        // actually refreshing it, rather than re-derived here by matching
        // `organizationId` against `profileManager.profiles`: two profiles
        // can be bound to the same claude.ai organization while holding
        // different Claude Code CLI logins, and `.first(where:)` over that
        // list would arbitrarily attach one profile's member-scoped figure
        // to whichever profile happened to trigger the refresh.
        // Each exit below says why. Returning nil silently made a member's
        // figure that never arrived indistinguishable from one that is
        // genuinely unavailable, which cost a live debugging session.
        guard profile.organizationId == organizationId else {
            LoggingService.shared.logWarning(
                "Profile '\(profile.name)' is bound to organization "
                + "\(profile.organizationId ?? "none"), not the "
                + "organization \(organizationId) currently being "
                + "refreshed; skipping the member's own extra usage."
            )
            return .issue(.claudeAccountUnresolved)
        }

        // A renewal is only good for the credential it was derived from. If
        // the profile has since been re-linked to a different Claude Code
        // account, its stored credential no longer matches and the renewed
        // copy is discarded rather than allowed to shadow the replacement.
        let stored: String?
        if let renewal = renewedCLICredentials[profile.id] {
            if renewal.base == profile.cliCredentialsJSON?.hashValue {
                stored = renewal.credentialsJSON
            } else {
                renewedCLICredentials[profile.id] = nil
                stored = profile.cliCredentialsJSON
            }
        } else {
            stored = profile.cliCredentialsJSON
        }
        guard let stored else {
            LoggingService.shared.logDebug(
                "Profile '\(profile.name)' has no stored Claude Code "
                + "credential; skipping the member's own extra usage."
            )
            return .issue(.notLinked)
        }

        forgetRenewalFailures(for: profile.id, nowPresenting: stored)

        // A stored credential with no token in it is its own state. It used
        // to reach `usableCLICredential`, which answered with an empty access
        // token because an empty string is not nil, so the request went out as
        // a bare `Bearer `, 401ed, and was reported as "couldn't be read just
        // now — re-sync", the one action that re-imports it.
        // A tokenless stored copy is recoverable for the same reason an
        // unrenewable one is: Claude Code may be signed in to this account
        // perfectly well, and only our snapshot of it is useless. Asking
        // someone to sign in again when they already are is the annoyance
        // this whole recovery path exists to remove, so consult the live
        // login before concluding the account is signed out.
        var presented = stored
        if !ClaudeCodeSyncService.carriesLogin(presented) {
            guard let adopted = await adoptLiveCLILogin(
                for: profile,
                replacing: presented
            ) else {
                LoggingService.shared.logWarning(
                    "The Claude Code login stored for profile "
                    + "'\(profile.name)' carries no access token, and Claude "
                    + "Code holds no usable login for that account either; "
                    + "the member's own extra usage cannot be read until it "
                    + "is signed in again."
                )
                return .issue(.signInHasNoToken)
            }
            presented = adopted.credentialsJSON
        }

        guard let credential = await usableCLICredential(
            for: profile,
            credentialsJSON: presented
        ) else {
            // Keyed on what was actually presented to the renewal path, which
            // is the adopted login when one was taken up — the verdict was
            // recorded against that, not against the copy we started with.
            let expired = expiredCLILogins.contains(presented.hashValue)
            LoggingService.shared.logDebug(
                "Profile '\(profile.name)' has a Claude Code credential that "
                + "could not be made usable; skipping the member's own extra "
                + "usage. Login expired: \(expired)."
            )
            return .issue(expired ? .signInExpired : .signInUnusable)
        }

        guard let cliOrganizationId = await cliOrganizationID(
            for: profile,
            credential: credential
        ) else { return .issue(.signInUnusable) }

        // The guard this whole path exists for. One person can hold two CLI
        // logins under the same email — one on their company's team, one on
        // a personal subscription — so an email or account match proves
        // nothing. Only the organization does.
        guard cliOrganizationId == organizationId else {
            LoggingService.shared.logWarning(
                "The linked Claude Code account belongs to organization "
                + "\(cliOrganizationId) but this profile is showing "
                + "organization \(organizationId); skipping the member's own "
                + "extra usage rather than showing one context's figure under "
                + "the other's label."
            )
            return .issue(.differentOrganization)
        }

        guard let data = await performOAuthRequest(
            urlString: Self.oauthUsageURL,
            accessToken: credential.accessToken
        ) else { return .issue(.signInUnusable) }

        guard let usage = try? JSONDecoder().decode(
            OAuthUsageResponse.self,
            from: data
        ) else {
            LoggingService.shared.logWarning(
                "Could not read the member's extra usage response."
            )
            return .issue(.signInUnusable)
        }

        // Extra usage switched off for this member is a settled answer, not a
        // problem to report: there is no figure to show and nothing to fix.
        guard let extraUsage = usage.extraUsage,
              extraUsage.isEnabled == true else { return .notApplicable }
        return .available(extraUsage)
    }

    /// Retires the expired verdict recorded against the credential a profile
    /// has just stopped presenting.
    ///
    /// This is what makes "sign in to Claude Code again, then re-sync"
    /// actually work: the re-sync replaces the credential, and the verdict
    /// recorded against the old one must not outlive it. Keyed per profile
    /// rather than cleared wholesale, so one profile's re-sync does not make
    /// every other profile retry a renewal already known to be hopeless.
    private func forgetRenewalFailures(
        for profileID: UUID,
        nowPresenting credentialsJSON: String
    ) {
        let fingerprint = credentialsJSON.hashValue
        let previous = lastSeenCredentialFingerprints[profileID]
        lastSeenCredentialFingerprints[profileID] = fingerprint
        guard let previous, previous != fingerprint else { return }
        expiredCLILogins.remove(previous)
        // The adoption attempt recorded against the retired credential goes
        // with it, for the same reason: if that credential is ever presented
        // again it deserves a fresh look at the CLI's live login rather than
        // inheriting a verdict from a previous incarnation.
        liveCLILoginAdoptionAttempts.removeValue(forKey: previous)
    }

    /// A CLI credential with a token that is actually usable right now.
    ///
    /// The stored credential is a snapshot taken when the profile was last
    /// synced, and these tokens last hours, so a menu bar app left running
    /// goes stale within a day. An expired one is renewed once per credential
    /// per app run; a failed renewal leaves the stored credential exactly as
    /// it was.
    private func usableCLICredential(
        for profile: Profile,
        credentialsJSON: String
    ) async -> (credentialsJSON: String, accessToken: String)? {
        let sync = ClaudeCodeSyncService.shared
        if !sync.isTokenExpired(credentialsJSON),
           let accessToken = sync.extractAccessToken(from: credentialsJSON) {
            return (credentialsJSON, accessToken)
        }

        let fingerprint = credentialsJSON.hashValue
        // A credential already recorded as dead cannot be renewed — that
        // verdict does not change — but Claude Code may have been signed
        // back in since the verdict was recorded, and adoption is the only
        // thing left that could still recover it. Without this, a known-dead
        // credential returned early forever, and the notice's promise that
        // signing back in was enough was false for exactly the credentials
        // it was shown for.
        guard !expiredCLILogins.contains(fingerprint) else {
            return await adoptLiveCLILogin(for: profile, replacing: credentialsJSON)
        }

        let outcome = await ClaudeCLITokenRefresher.refreshOutcome(
            from: credentialsJSON
        )
        guard
            case .renewed(let refreshed) = outcome,
            let accessToken = sync.extractAccessToken(from: refreshed)
        else {
            // Our own snapshot cannot be renewed. Before telling anyone their
            // sign-in expired, look at the login Claude Code itself is
            // holding — the remedy the message used to ask for by hand.
            if let adopted = await adoptLiveCLILogin(
                for: profile,
                replacing: credentialsJSON
            ) {
                return adopted
            }
            if case .failed(.expired) = outcome {
                expiredCLILogins.insert(fingerprint)
            }
            return nil
        }
        expiredCLILogins.remove(fingerprint)

        do {
            try renewedCredentialWriter(refreshed, profile.id)
        } catch {
            // The stored credential is untouched. The renewed token still
            // works for this run, so use it rather than discarding a
            // successful renewal because persistence failed.
            LoggingService.shared.logWarning(
                "Could not store the renewed Claude Code token: "
                + "\(error.localizedDescription). The saved credential is "
                + "unchanged."
            )
        }
        // Keyed on the profile's own stored credential, not `credentialsJSON`
        // — that argument may already be a renewal from earlier in this run,
        // and chaining fingerprints would lose the link back to the account
        // the profile is actually bound to.
        renewedCLICredentials[profile.id] = (
            base: profile.cliCredentialsJSON?.hashValue ?? credentialsJSON.hashValue,
            credentialsJSON: refreshed
        )
        // A rotated token is not a different account, so the organization
        // already resolved for this profile still stands.
        if cliOrganizationCredentialHashes[profile.id] == fingerprint {
            cliOrganizationCredentialHashes[profile.id] = refreshed.hashValue
        }
        return (refreshed, accessToken)
    }

    /// Adopts the login Claude Code itself is holding, when the app's own
    /// snapshot of it can no longer be renewed.
    ///
    /// The stored credential is a copy taken at sync time, and its *refresh*
    /// token rotates: Claude Code renews on its own schedule, and once it
    /// has, the refresh token in our copy is no longer accepted. Renewal then
    /// fails as `.expired`, which is indistinguishable — from inside this
    /// function — from a genuinely dead login. The member's own extra usage
    /// therefore reported "sign in to Claude Code again, then re-sync", when
    /// Claude Code had been signed in the whole time and pressing Re-sync on
    /// its own fixed it. That asked for the one step that was not needed, and
    /// asked it of someone whose app already held everything required to
    /// recover unaided.
    ///
    /// This is deliberately the same read Re-sync performs, scoped to the
    /// account the profile is linked to, and it adopts the result only when
    /// that result is demonstrably better than what we hold:
    ///
    /// - it must parse and carry an actual token (`carriesLogin`), because a
    ///   credential write here validates shape, and a blob without a token
    ///   would otherwise overwrite a working login and read back as valid;
    /// - it must not itself be expired, so a dead login is never swapped for
    ///   another dead login;
    /// - it must differ from the credential that just failed, so a failure is
    ///   never reported as a recovery.
    ///
    /// A live login that is *also* expired is left alone rather than renewed
    /// here. Claude Code keeps its own copy current, so that state means the
    /// account really is signed out, which is exactly what the notice should
    /// then say.
    ///
    /// The account name is what scopes this read to the account this profile
    /// is actually linked to: `systemCredentialsReader` with a nil account
    /// name answers with whichever account happens to own the shared
    /// Keychain item, which on a multi-account machine can be a different
    /// person's login entirely. A profile can hold a stored credential with
    /// no linked account name — a legacy decode of an older persisted format
    /// sets `cliCredentialsJSON` without requiring `cliAccountName` — and
    /// this function persists whatever it reads via `renewedCredentialWriter`,
    /// so an unscoped read here would write another local account's OAuth
    /// token into this profile's storage. A nil account name is therefore
    /// treated as adoption already having failed, never as a reason to fall
    /// back to the unscoped read.
    private func adoptLiveCLILogin(
        for profile: Profile,
        replacing stale: String
    ) async -> (credentialsJSON: String, accessToken: String)? {
        guard let accountName = profile.cliAccountName else { return nil }

        let fingerprint = stale.hashValue
        if let lastAttempt = liveCLILoginAdoptionAttempts[fingerprint],
           Date().timeIntervalSince(lastAttempt) < liveCLILoginAdoptionRetryInterval {
            return nil
        }
        liveCLILoginAdoptionAttempts[fingerprint] = Date()

        let live: String?
        do {
            live = try systemCredentialsReader(accountName)
        } catch {
            LoggingService.shared.logDebug(
                "Could not read the live Claude Code login for profile "
                + "'\(profile.name)' while trying to recover from a failed "
                + "renewal: \(error.localizedDescription)."
            )
            return nil
        }

        let sync = ClaudeCodeSyncService.shared
        guard let live,
              live != stale,
              ClaudeCodeSyncService.carriesLogin(live),
              !sync.isTokenExpired(live),
              let accessToken = sync.extractAccessToken(from: live)
        else { return nil }

        do {
            try renewedCredentialWriter(live, profile.id)
        } catch {
            // Same reasoning as the renewal path: the adopted login works for
            // this run, so a persistence failure is not a reason to discard
            // it and go on reporting an expired sign-in.
            LoggingService.shared.logWarning(
                "Could not store the live Claude Code login adopted for "
                + "profile '\(profile.name)': \(error.localizedDescription). "
                + "The saved credential is unchanged."
            )
        }

        LoggingService.shared.log(
            "Recovered the member's own extra usage for profile "
            + "'\(profile.name)' by adopting the login Claude Code is "
            + "currently holding; the stored copy could no longer be renewed."
        )

        renewedCLICredentials[profile.id] = (
            base: profile.cliCredentialsJSON?.hashValue ?? stale.hashValue,
            credentialsJSON: live
        )
        // Deliberately NOT carried over from the stale credential the way a
        // rotated token's is. A renewal is provably the same login; an
        // adopted one only provably belongs to the same account *name*, so
        // the organization is re-resolved rather than assumed, and the
        // existing organization guard downstream stays meaningful.
        return (live, accessToken)
    }

    /// The organization the CLI login belongs to.
    ///
    /// Resolved at most once per profile per app run, and again if the stored
    /// credential changes: the sequential request discipline in
    /// `fetchUsageData` exists because extra per-profile requests on every
    /// tick contributed to 429s. The answer is cached on the profile so a
    /// lookup that cannot be repeated (offline, expired login) still has an
    /// answer to fall back on.
    private func cliOrganizationID(
        for profile: Profile,
        credential: (credentialsJSON: String, accessToken: String)
    ) async -> String? {
        let fingerprint = credential.credentialsJSON.hashValue
        if cliOrganizationCredentialHashes[profile.id] == fingerprint,
           let cached = profile.cliOrganizationId {
            return cached
        }

        if failedCLIOrganizationLookups.contains(profile.id) {
            if failedCLIOrganizationLookupFingerprints[profile.id] == fingerprint {
                // The same credential that already failed this run: honor
                // the short-circuit rather than repeating a lookup that can
                // only fail again. Nil for the same reason the live failure
                // above answers nil — the cached id belongs to whichever
                // credential last resolved successfully, which is not this
                // one.
                return nil
            }
            // A different credential is presented than the one that failed
            // — the profile was re-linked to a different Claude Code
            // account since then. That earlier failure says nothing about
            // this credential, so it must not suppress a retry with it.
            failedCLIOrganizationLookups.remove(profile.id)
            failedCLIOrganizationLookupFingerprints.removeValue(forKey: profile.id)
        }

        guard
            let data = await performOAuthRequest(
                urlString: Self.oauthProfileURL,
                accessToken: credential.accessToken
            ),
            let response = try? JSONDecoder().decode(
                OAuthProfileResponse.self,
                from: data
            ),
            let uuid = response.organization?.uuid
        else {
            failedCLIOrganizationLookups.insert(profile.id)
            failedCLIOrganizationLookupFingerprints[profile.id] = fingerprint
            LoggingService.shared.logWarning(
                "Could not establish which organization the linked Claude "
                + "Code account belongs to; the member's own extra usage is "
                + "skipped rather than attributed on a cached answer."
            )
            // Deliberately nil, not `profile.cliOrganizationId`.
            //
            // The cached id was resolved from a *different* credential — this
            // lookup only runs because the fingerprint changed. Answering
            // with it let the caller's organization-match guard pass on the
            // strength of the previous account's identity and then read the
            // member figure with the new account's token, which is exactly
            // the cross-account attribution this guard exists to stop. One
            // failed request was enough to reach it.
            return nil
        }

        cliOrganizationCredentialHashes[profile.id] = fingerprint
        failedCLIOrganizationLookups.remove(profile.id)
        failedCLIOrganizationLookupFingerprints.removeValue(forKey: profile.id)
        if profile.cliOrganizationId != uuid {
            profileManager.updateCliOrganizationId(uuid, for: profile.id)
        }
        return uuid
    }

    /// A GET against an `api.anthropic.com` OAuth endpoint. Every failure is
    /// answered with nil: none of these responses is worth failing a whole
    /// refresh over.
    private func performOAuthRequest(
        urlString: String,
        accessToken: String
    ) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        var request = buildAuthenticatedRequest(
            url: url,
            auth: .cliOAuth(accessToken)
        )
        request.httpMethod = "GET"
        request.timeoutInterval = 30

        let startTime = Date()
        do {
            let (data, response) = try await URLSession.shared.data(
                for: request
            )
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            NetworkLoggerService.shared.logRequest(
                url: urlString,
                method: "GET",
                requestBody: nil,
                responseData: nil,
                statusCode: statusCode,
                duration: Date().timeIntervalSince(startTime),
                error: nil
            )
            guard statusCode == 200 else { return nil }
            return data
        } catch {
            NetworkLoggerService.shared.logRequest(
                url: urlString,
                method: "GET",
                requestBody: nil,
                responseData: nil,
                statusCode: nil,
                duration: Date().timeIntervalSince(startTime),
                error: error
            )
            return nil
        }
    }

    /// Copies a member's extra usage onto the usage record, leaving the
    /// fields nil whenever the figure could not be established.
    private func applyPersonalExtraUsage(
        to usage: inout ClaudeUsage,
        profile: Profile,
        organizationId: String
    ) async {
        switch await personalExtraUsage(
            for: profile,
            organizationId: organizationId
        ) {
        case .available(let extraUsage):
            guard let used = extraUsage.usedCredits,
                  let limit = extraUsage.monthlyLimit else {
                usage.personalExtraUsageIssue = .signInUnusable
                return
            }
            usage.personalCostUsed = used
            usage.personalCostLimit = limit
            usage.personalCostCurrency = extraUsage.currency
        case .issue(let issue):
            usage.personalExtraUsageIssue = issue
        case .notApplicable:
            break
        }
    }

    /// Fetches usage data for a specific profile using provided credentials
    /// - Parameters:
    ///   - sessionKey: The Claude.ai session key
    ///   - organizationId: The organization ID
    ///   - profile: The exact profile being refreshed, used to attach the
    ///     member's own extra usage to the profile that actually triggered
    ///     this fetch rather than any profile sharing `organizationId`. Pass
    ///     nil only when no specific profile identity is available; the
    ///     member figure is then left unset instead of being guessed.
    /// - Returns: ClaudeUsage data for the profile
    func fetchUsageData(
        sessionKey: String,
        organizationId: String,
        profile: Profile?,
        checkOverageLimitEnabled: Bool = true
    ) async throws -> ClaudeUsage {
        // Sequenced rather than fired concurrently (async let): three
        // simultaneous requests per profile, multiplied across every
        // selected profile on each refresh tick, was a meaningful
        // contributor to the Claude API's 429 responses. Sequencing keeps
        // each profile's own request volume modest; multi-profile spacing
        // is handled separately by the refresh engine's stagger policy.
        let usageData = try await performRequest(
            endpoint: "/organizations/\(organizationId)/usage",
            sessionKey: sessionKey
        )
        var claudeUsage = try parseUsageResponse(usageData)

        if checkOverageLimitEnabled,
           let data = try? await performRequest(
                endpoint: "/organizations/\(organizationId)/overage_spend_limit",
                sessionKey: sessionKey
           ),
           let overage = try? JSONDecoder().decode(OverageSpendLimitResponse.self, from: data),
           overage.isEnabled == true {
            claudeUsage.costUsed = overage.usedCredits
            claudeUsage.costLimit = overage.monthlyCreditLimit
            claudeUsage.costCurrency = overage.currency
            // The endpoint is organization-scoped: these amounts are the whole
            // organization's unless that organization has one member.
            claudeUsage.costScope = await resolveExtraUsageScope(
                organizationId: organizationId,
                sessionKey: sessionKey
            )
        }

        // The member's own figure, from a CLI-authenticated endpoint. Still
        // sequential, gated on the same preference as the organization's
        // figure, and skipped entirely unless the linked Claude Code account
        // belongs to the organization on screen.
        if checkOverageLimitEnabled, let profile {
            await applyPersonalExtraUsage(
                to: &claudeUsage,
                profile: profile,
                organizationId: organizationId
            )
        } else if checkOverageLimitEnabled, claudeUsage.costUsed != nil {
            // No profile survived to check against — it was removed, or the
            // request's captured id no longer resolves — yet the
            // organization's extra usage row is about to be shown. Leaving
            // `personalExtraUsageIssue` nil here is exactly the silent
            // fifth outcome this case exists to close off.
            LoggingService.shared.logWarning(
                "No profile could be resolved for organization "
                + "\(organizationId) on this refresh; the member's own "
                + "extra usage will be reported as unresolved rather than "
                + "left unexplained."
            )
            claudeUsage.personalExtraUsageIssue = .claudeAccountUnresolved
        }

        if checkOverageLimitEnabled,
           let creditData = try? await performRequest(
                endpoint: "/organizations/\(organizationId)/overage_credit_grant",
                sessionKey: sessionKey
           ),
           let creditGrant = try? JSONDecoder().decode(OverageCreditGrantResponse.self, from: creditData) {
            claudeUsage.overageBalance = creditGrant.remainingBalance
            claudeUsage.overageBalanceCurrency = creditGrant.currency
        }

        return claudeUsage
    }

    func captureUsageRequest(
        for profile: Profile
    ) throws -> CapturedUsageRequest {
        if let sessionKey = profile.claudeSessionKey,
           let organizationID = profile.organizationId {
            return CapturedUsageRequest(
                source: .claudeAI(
                    checkOverage: profile.checkOverageLimitEnabled
                ),
                sessionKey: sessionKey,
                organizationID: organizationID,
                oauthAccessToken: nil,
                profileID: profile.id
            )
        }
        if let cliJSON = profile.cliCredentialsJSON,
           !ClaudeCodeSyncService.shared.isTokenExpired(cliJSON),
           let accessToken =
            ClaudeCodeSyncService.shared.extractAccessToken(
                from: cliJSON
            ) {
            return CapturedUsageRequest(
                source: .profileCLI,
                sessionKey: nil,
                organizationID: nil,
                oauthAccessToken: accessToken,
                profileID: profile.id
            )
        }
        if let systemCredentials = try systemCredentialsReader(
                profile.cliAccountName
           ),
           !ClaudeCodeSyncService.shared.isTokenExpired(
                systemCredentials
           ),
           let accessToken =
            ClaudeCodeSyncService.shared.extractAccessToken(
                from: systemCredentials
            ) {
            return CapturedUsageRequest(
                source: .systemCLI,
                sessionKey: nil,
                organizationID: nil,
                oauthAccessToken: accessToken,
                profileID: profile.id
            )
        }
        throw AppError(
            code: .sessionKeyNotFound,
            message: "Missing credentials for the selected profile",
            isRecoverable: false
        )
    }

    func captureAPIUsageRequest(
        for profile: Profile
    ) -> CapturedAPIUsageRequest? {
        guard let organizationID = profile.apiOrganizationId,
              let apiSessionKey = profile.apiSessionKey else {
            return nil
        }
        return CapturedAPIUsageRequest(
            organizationID: organizationID,
            apiSessionKey: apiSessionKey
        )
    }

    func fetchAPIUsageData(
        using request: CapturedAPIUsageRequest
    ) async throws -> APIUsage {
        try await fetchAPIUsageData(
            organizationId: request.organizationID,
            apiSessionKey: request.apiSessionKey
        )
    }

    func fetchUsageData(
        using request: CapturedUsageRequest
    ) async throws -> ClaudeUsage {
        switch request.source {
        case .claudeAI(let checkOverage):
            guard let sessionKey = request.sessionKey,
                  let organizationID = request.organizationID else {
                throw AppError(
                    code: .sessionKeyNotFound,
                    message: "Missing credentials for the selected profile",
                    isRecoverable: false
                )
            }
            // Re-resolved by the request's own unique profile id, never by
            // matching `organizationID` against the profile list: that id is
            // exact, unlike organization id which more than one profile can
            // share. A profile removed since the request was captured simply
            // yields nil, and the member's own figure is left unset rather
            // than attached to a guess.
            let profile = profileManager.profiles.first(
                where: { $0.id == request.profileID }
            )
            return try await fetchUsageData(
                sessionKey: sessionKey,
                organizationId: organizationID,
                profile: profile,
                checkOverageLimitEnabled: checkOverage
            )

        case .profileCLI:
            guard let accessToken = request.oauthAccessToken else {
                throw AppError(
                    code: .sessionKeyNotFound,
                    message: "Missing credentials for the selected profile",
                    isRecoverable: false
                )
            }
            return try await fetchUsageData(oauthAccessToken: accessToken)

        case .systemCLI:
            guard let accessToken = request.oauthAccessToken else {
                throw AppError(
                    code: .sessionKeyNotFound,
                    message: "Missing credentials for the selected profile",
                    isRecoverable: false
                )
            }
            return try await fetchUsageData(
                oauthAccessToken: accessToken
            )
        }
    }

    /// Fetches usage data via OAuth access token (CLI credential flow)
    func fetchUsageData(oauthAccessToken: String) async throws -> ClaudeUsage {
        // The dedicated OAuth usage endpoint is disabled. Make the same
        // minimal Messages request as the active-profile path and parse its
        // rate-limit headers, but use the initiating profile's captured token.
        LoggingService.shared.log(
            "ClaudeAPIService: Fetching usage via Messages API headers (OAuth)"
        )

        guard let url = URL(
            string: "https://api.anthropic.com/v1/messages"
        ) else {
            throw AppError(
                code: .urlMalformed,
                message: "Invalid Messages API endpoint",
                isRecoverable: false
            )
        }

        var request = buildAuthenticatedRequest(
            url: url,
            auth: .cliOAuth(oauthAccessToken)
        )
        request.httpMethod = "POST"
        request.setValue(
            "2023-06-01",
            forHTTPHeaderField: "anthropic-version"
        )
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 1,
            "messages": [["role": "user", "content": "hi"]]
        ]
        request.httpBody = try JSONSerialization.data(
            withJSONObject: body
        )

        let startTime = Date()
        let response: URLResponse
        do {
            let (_, receivedResponse) =
                try await URLSession.shared.data(for: request)
            response = receivedResponse
        } catch {
            let duration = Date().timeIntervalSince(startTime)
            NetworkLoggerService.shared.logRequest(
                url: url.absoluteString,
                method: "POST",
                requestBody: request.httpBody,
                responseData: nil,
                statusCode: nil,
                duration: duration,
                error: error
            )
            throw error
        }

        let duration = Date().timeIntervalSince(startTime)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppError(
                code: .apiInvalidResponse,
                message: "Invalid response from Messages API",
                isRecoverable: true
            )
        }

        NetworkLoggerService.shared.logRequest(
            url: url.absoluteString,
            method: "POST",
            requestBody: request.httpBody,
            responseData: nil,
            statusCode: httpResponse.statusCode,
            duration: duration,
            error: nil
        )

        guard httpResponse.statusCode == 200 else {
            throw AppError(
                code: .apiUnauthorized,
                message: "OAuth Messages API request failed",
                technicalDetails: "Status: \(httpResponse.statusCode)",
                isRecoverable: true,
                recoverySuggestion:
                    "Please re-sync your CLI account in Settings"
            )
        }

        return parseUsageFromRateLimitHeaders(httpResponse)
    }

    /// Fetches real usage data from Claude's API
    func fetchUsageData() async throws -> ClaudeUsage {
        let auth = try getAuthentication()

        switch auth {
        case .claudeAISession(let sessionKey):
            // Use existing claude.ai flow
            let orgId = try await fetchOrganizationId(sessionKey: sessionKey)

            // Captured once so the personal-usage call below attaches to the
            // exact same profile this check was read from, rather than a
            // profile re-derived later by matching organization id.
            let activeProfile = profileManager.activeClaudeProfile
            // Use active profile's checkOverageLimitEnabled setting
            let checkOverage = activeProfile?.checkOverageLimitEnabled ?? true

            // Sequenced rather than fired concurrently (async let): see the
            // comment on the credentials-based fetchUsageData overload above.
            let usageData = try await performRequest(
                endpoint: "/organizations/\(orgId)/usage",
                sessionKey: sessionKey
            )
            var claudeUsage = try parseUsageResponse(usageData)

            if checkOverage,
               let data = try? await performRequest(
                    endpoint: "/organizations/\(orgId)/overage_spend_limit",
                    sessionKey: sessionKey
               ),
               let overage = try? JSONDecoder().decode(OverageSpendLimitResponse.self, from: data),
               overage.isEnabled == true {
                claudeUsage.costUsed = overage.usedCredits
                claudeUsage.costLimit = overage.monthlyCreditLimit
                claudeUsage.costCurrency = overage.currency
                // See the identical block in the credentials-based overload:
                // this endpoint reports the organization's spend, not the
                // signed-in member's.
                claudeUsage.costScope = await resolveExtraUsageScope(
                    organizationId: orgId,
                    sessionKey: sessionKey
                )
            }

            // See the identical call in the credentials-based overload.
            if checkOverage, let activeProfile {
                await applyPersonalExtraUsage(
                    to: &claudeUsage,
                    profile: activeProfile,
                    organizationId: orgId
                )
            }

            if checkOverage,
               let creditData = try? await performRequest(
                    endpoint: "/organizations/\(orgId)/overage_credit_grant",
                    sessionKey: sessionKey
               ),
               let creditGrant = try? JSONDecoder().decode(OverageCreditGrantResponse.self, from: creditData) {
                claudeUsage.overageBalance = creditGrant.remainingBalance
                claudeUsage.overageBalanceCurrency = creditGrant.currency
            }

            return claudeUsage

        case .cliOAuth(let accessToken):
            return try await fetchUsageData(
                oauthAccessToken: accessToken
            )

        case .consoleAPISession:
            // Console API is for billing/credits only, not usage data
            throw AppError(
                code: .sessionKeyNotFound,
                message: "No valid credentials for usage data",
                technicalDetails: "Console API only provides billing data, not usage statistics",
                isRecoverable: true,
                recoverySuggestion: "Please add a claude.ai session key or sync your CLI account"
            )
        }
    }

    private func performRequest(endpoint: String, sessionKey: String) async throws -> Data {
        // Build URL safely
        let url = try URLBuilder(baseURL: baseURL)
            .appendingPath(endpoint)
            .build()

        var request = URLRequest(url: url)
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpMethod = "GET"
        request.timeoutInterval = 30

        LoggingService.shared.logAPIRequest(endpoint)

        let startTime = Date()
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            // Network-level errors
            let duration = Date().timeIntervalSince(startTime)
            NetworkLoggerService.shared.logRequest(
                url: url.absoluteString,
                method: "GET",
                requestBody: request.httpBody,
                responseData: nil,
                statusCode: nil,
                duration: duration,
                error: error
            )

            LoggingService.shared.logAPIError(endpoint, error: error)
            let appError = AppError(
                code: .networkGenericError,
                message: "Failed to connect to Claude API",
                technicalDetails: "Endpoint: \(endpoint)\nError: \(error.localizedDescription)",
                underlyingError: error,
                isRecoverable: true,
                recoverySuggestion: "Please check your internet connection and try again"
            )
            throw appError
        }

        let duration = Date().timeIntervalSince(startTime)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppError(
                code: .apiInvalidResponse,
                message: "Invalid response from server",
                technicalDetails: "Endpoint: \(endpoint)",
                isRecoverable: true
            )
        }

        LoggingService.shared.logAPIResponse(endpoint, statusCode: httpResponse.statusCode)

        // Log to NetworkLoggerService
        NetworkLoggerService.shared.logRequest(
            url: url.absoluteString,
            method: "GET",
            requestBody: request.httpBody,
            responseData: data,
            statusCode: httpResponse.statusCode,
            duration: duration,
            error: nil
        )

        // Log raw response if debug logging is enabled
        if DataStore.shared.loadDebugAPILoggingEnabled() {
            if let responseString = String(data: data, encoding: .utf8) {
                // Truncate to first 500 chars to avoid huge logs
                let truncated = responseString.prefix(500)
                LoggingService.shared.logDebug("API Response [\(endpoint)]: \(truncated)...")
            }
        }

        switch httpResponse.statusCode {
        case 200:
            return data

        case 401, 403:
            // Include response body in error for debugging
            let responsePreview = String(data: data, encoding: .utf8)?.prefix(200) ?? "Unable to read response"
            throw AppError(
                code: .apiUnauthorized,
                message: "Unauthorized. Your session key may have expired.",
                technicalDetails: "Endpoint: \(endpoint)\nStatus: \(httpResponse.statusCode)\nResponse: \(responsePreview)",
                isRecoverable: true,
                recoverySuggestion: "Please update your session key in Settings",
                statusCode: httpResponse.statusCode
            )

        case 429:
            let retryAfter = Self.parseRetryAfterSeconds(
                from: httpResponse
            )
            try Self.throwLogged(
                AppError(
                    code: .apiRateLimited,
                    message: "Rate limited by Claude API",
                    technicalDetails: "Endpoint: \(endpoint)\nStatus: 429"
                        + (retryAfter.map { "\nRetry-After: \($0)s" } ?? ""),
                    isRecoverable: true,
                    recoverySuggestion: "Please wait a few minutes before trying again",
                    retryAfter: retryAfter,
                    statusCode: 429
                )
            )

        case 500...599:
            let responsePreview = String(data: data, encoding: .utf8)?.prefix(200) ?? "Unable to read response"
            try Self.throwLogged(
                AppError(
                    code: .apiServerError,
                    message: "Claude API server error",
                    technicalDetails: "Endpoint: \(endpoint)\nStatus: \(httpResponse.statusCode)\nResponse: \(responsePreview)",
                    isRecoverable: true,
                    recoverySuggestion: "Please try again later",
                    statusCode: httpResponse.statusCode
                )
            )

        default:
            let responsePreview = String(data: data, encoding: .utf8)?.prefix(200) ?? "Unable to read response"
            throw AppError(
                code: .apiGenericError,
                message: "Unexpected API response",
                technicalDetails: "Endpoint: \(endpoint)\nStatus: \(httpResponse.statusCode)\nResponse: \(responsePreview)",
                isRecoverable: true,
                statusCode: httpResponse.statusCode
            )
        }
    }

    /// Logs an `AppError` at warning severity, then throws it. Centralizes
    /// the "log before throwing an HTTP failure" policy so the 429 and
    /// 5xx branches above can't drift from each other (the `default`
    /// branch intentionally doesn't log, since it isn't a recognized
    /// failure policy).
    private static func throwLogged(_ error: AppError) throws -> Never {
        ErrorLogger.shared.log(error, severity: .warning)
        throw error
    }

    // MARK: - Rate Limit Retry Parsing

    /// Parses a `Retry-After` response header, which per RFC 9110 may be
    /// either a delay in seconds or an HTTP-date. Returns `nil` when the
    /// header is absent or unparseable in either form.
    static func parseRetryAfterSeconds(
        from response: HTTPURLResponse
    ) -> TimeInterval? {
        guard let value = response.value(
            forHTTPHeaderField: "Retry-After"
        ) else {
            return nil
        }
        if let seconds = TimeInterval(value.trimmingCharacters(in: .whitespaces)),
           seconds >= 0 {
            return seconds
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: value) {
            let interval = date.timeIntervalSinceNow
            return interval > 0 ? interval : 0
        }
        return nil
    }

    // MARK: - Response Parsing

    private func parseUsageResponse(_ data: Data) throws -> ClaudeUsage {
        // Parse Claude's actual API response structure

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Extract session usage (five_hour)
            var sessionPercentage = 0.0
            var sessionResetTime = Date().addingTimeInterval(5 * 3600)
            if let fiveHour = json["five_hour"] as? [String: Any] {
                if let utilization = fiveHour["utilization"] {
                    sessionPercentage = parseUtilization(utilization)
                }
                if let resetsAt = fiveHour["resets_at"] as? String {
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    sessionResetTime = formatter.date(from: resetsAt) ?? sessionResetTime
                }
            }

            // Extract weekly usage (seven_day)
            var weeklyPercentage = 0.0
            var weeklyResetTime = Date().nextMonday1259pm()
            if let sevenDay = json["seven_day"] as? [String: Any] {
                if let utilization = sevenDay["utilization"] {
                    weeklyPercentage = parseUtilization(utilization)
                }
                if let resetsAt = sevenDay["resets_at"] as? String {
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    weeklyResetTime = formatter.date(from: resetsAt) ?? weeklyResetTime
                }
            }

            let opusUsage = UsageLimitParsing.parseWeeklyModelUsage(
                from: json, legacyKey: "seven_day_opus", modelDisplayName: "Opus")
            let sonnetUsage = UsageLimitParsing.parseWeeklyModelUsage(
                from: json, legacyKey: "seven_day_sonnet", modelDisplayName: "Sonnet")
            let fableUsage = UsageLimitParsing.parseWeeklyModelUsage(
                from: json, legacyKey: nil, modelDisplayName: "Fable")
            let opusPercentage = opusUsage?.percentage ?? 0.0
            let sonnetPercentage = sonnetUsage?.percentage ?? 0.0
            let sonnetResetTime = sonnetUsage?.resetTime
            let fablePercentage = fableUsage?.percentage ?? 0.0
            let fableResetTime = fableUsage?.resetTime

            // We don't know user's plan, so we use 0 for limits we can't determine
            let weeklyLimit = Constants.weeklyLimit

            // Calculate token counts from percentages (using weekly limit as reference)
            let sessionTokens = 0  // Can't calculate without knowing plan
            let sessionLimit = 0   // Unknown without plan
            let weeklyTokens = Int(Double(weeklyLimit) * (weeklyPercentage / 100.0))
            let opusTokens = Int(Double(weeklyLimit) * (opusPercentage / 100.0))
            let sonnetTokens = Int(Double(weeklyLimit) * (sonnetPercentage / 100.0))
            let fableTokens = Int(Double(weeklyLimit) * (fablePercentage / 100.0))

            let usage = ClaudeUsage(
                sessionTokensUsed: sessionTokens,
                sessionLimit: sessionLimit,
                sessionPercentage: sessionPercentage,
                sessionResetTime: sessionResetTime,
                weeklyTokensUsed: weeklyTokens,
                weeklyLimit: weeklyLimit,
                weeklyPercentage: weeklyPercentage,
                weeklyResetTime: weeklyResetTime,
                opusWeeklyTokensUsed: opusTokens,
                opusWeeklyPercentage: opusPercentage,
                sonnetWeeklyTokensUsed: sonnetTokens,
                sonnetWeeklyPercentage: sonnetPercentage,
                sonnetWeeklyResetTime: sonnetResetTime,
                fableWeeklyTokensUsed: fableTokens,
                fableWeeklyPercentage: fablePercentage,
                fableWeeklyResetTime: fableResetTime,
                fableWeeklyLimitAvailable: fableUsage != nil,
                costUsed: nil,
                costLimit: nil,
                costCurrency: nil,
                lastUpdated: Date(),
                userTimezone: .current
            )

            return usage
        }

        // Log the actual response for debugging
        if DataStore.shared.loadDebugAPILoggingEnabled() {
            if let responseString = String(data: data, encoding: .utf8) {
                LoggingService.shared.logDebug("Failed to parse usage response: \(responseString)")
            }
        }

        throw AppError(
            code: .apiParsingFailed,
            message: "Failed to parse usage data",
            technicalDetails: "Unable to parse JSON response structure",
            isRecoverable: false,
            recoverySuggestion: "Please check the error log and report this issue"
        )
    }

    // MARK: - Rate Limit Header Parsing

    /// Parses usage data from Messages API rate limit response headers.
    /// Headers use format: anthropic-ratelimit-unified-{window}-{field}
    /// Utilization values are 0.0-1.0 (converted to 0-100 percentage).
    private func parseUsageFromRateLimitHeaders(_ response: HTTPURLResponse) -> ClaudeUsage {
        func headerDouble(_ name: String) -> Double? {
            if let value = response.value(forHTTPHeaderField: name) {
                return Double(value)
            }
            return nil
        }

        // Session (5h) usage — utilization is 0.0-1.0, convert to 0-100
        let sessionUtilization = headerDouble("anthropic-ratelimit-unified-5h-utilization") ?? 0
        var sessionPercentage = sessionUtilization * 100.0

        let sessionResetTimestamp = headerDouble("anthropic-ratelimit-unified-5h-reset") ?? 0
        let sessionResetTime = sessionResetTimestamp > 0
            ? Date(timeIntervalSince1970: sessionResetTimestamp)
            : Date().addingTimeInterval(5 * 3600)

        // If the 5-hour window has already expired, the session has reset
        if sessionResetTime < Date() {
            sessionPercentage = 0.0
        }

        // Weekly (7d) usage
        let weeklyUtilization = headerDouble("anthropic-ratelimit-unified-7d-utilization") ?? 0
        let weeklyPercentage = weeklyUtilization * 100.0

        let weeklyResetTimestamp = headerDouble("anthropic-ratelimit-unified-7d-reset") ?? 0
        let weeklyResetTime = weeklyResetTimestamp > 0
            ? Date(timeIntervalSince1970: weeklyResetTimestamp)
            : Date().nextMonday1259pm()

        // Per-model breakdowns not available in rate limit headers
        let weeklyLimit = Constants.weeklyLimit
        let weeklyTokens = Int(Double(weeklyLimit) * (weeklyPercentage / 100.0))

        LoggingService.shared.log("ClaudeAPIService: Parsed usage from headers - session: \(String(format: "%.1f", sessionPercentage))%, weekly: \(String(format: "%.1f", weeklyPercentage))%")

        return ClaudeUsage(
            sessionTokensUsed: 0,
            sessionLimit: 0,
            sessionPercentage: sessionPercentage,
            sessionResetTime: sessionResetTime,
            weeklyTokensUsed: weeklyTokens,
            weeklyLimit: weeklyLimit,
            weeklyPercentage: weeklyPercentage,
            weeklyResetTime: weeklyResetTime,
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

    // MARK: - Parsing Helpers

    /// Robust utilization parser that handles Int, Double, or String types
    /// - Parameter value: The utilization value from API (can be Int, Double, or String)
    /// - Returns: Parsed percentage as Double, or 0.0 if parsing fails
    private func parseUtilization(_ value: Any) -> Double {
        UsageLimitParsing.parseUtilization(value)
    }

    // MARK: - Session Initialization

    /// Sends a minimal message to Claude to initialize a new session
    /// Uses Claude 3.5 Haiku (cheapest model)
    /// Creates a temporary conversation that is deleted after initialization to avoid cluttering chat history
    func sendInitializationMessage() async throws {
        let sessionKey = try readSessionKey()
        let orgId = try await fetchOrganizationId(sessionKey: sessionKey)

        // Create a new conversation
        let conversationURL = try URLBuilder(baseURL: baseURL)
            .appendingPathComponents(["/organizations", orgId, "/chat_conversations"])
            .build()

        var conversationRequest = URLRequest(url: conversationURL)
        conversationRequest.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        conversationRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        conversationRequest.httpMethod = "POST"

        let conversationBody: [String: Any] = [
            "uuid": UUID().uuidString.lowercased(),
            "name": ""
        ]
        conversationRequest.httpBody = try JSONSerialization.data(withJSONObject: conversationBody)

        let startTime1 = Date()
        let (conversationData, conversationResponse) = try await URLSession.shared.data(for: conversationRequest)
        let duration1 = Date().timeIntervalSince(startTime1)

        guard let httpResponse = conversationResponse as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        NetworkLoggerService.shared.logRequest(
            url: conversationURL.absoluteString,
            method: "POST",
            requestBody: conversationRequest.httpBody,
            responseData: conversationData,
            statusCode: httpResponse.statusCode,
            duration: duration1,
            error: nil
        )

        guard httpResponse.statusCode == 200 || httpResponse.statusCode == 201 else {
            throw APIError.serverError(statusCode: httpResponse.statusCode)
        }

        // Parse conversation UUID
        guard let json = try? JSONSerialization.jsonObject(with: conversationData) as? [String: Any],
              let conversationUUID = json["uuid"] as? String else {
            throw APIError.invalidResponse
        }

        // Send a minimal "Hi" message to initialize the session
        let messageURL = try URLBuilder(baseURL: baseURL)
            .appendingPathComponents(["/organizations", orgId, "/chat_conversations", conversationUUID, "/completion"])
            .build()

        var messageRequest = URLRequest(url: messageURL)
        messageRequest.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        messageRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        messageRequest.httpMethod = "POST"

        let messageBody: [String: Any] = [
            "prompt": "Hi",
            "model": "claude-haiku-4-5-20251001",
            "timezone": "UTC"
        ]
        messageRequest.httpBody = try JSONSerialization.data(withJSONObject: messageBody)

        let startTime2 = Date()
        let (messageData, messageResponse) = try await URLSession.shared.data(for: messageRequest)
        let duration2 = Date().timeIntervalSince(startTime2)

        guard let messageHTTPResponse = messageResponse as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        NetworkLoggerService.shared.logRequest(
            url: messageURL.absoluteString,
            method: "POST",
            requestBody: messageRequest.httpBody,
            responseData: messageData,
            statusCode: messageHTTPResponse.statusCode,
            duration: duration2,
            error: nil
        )

        guard messageHTTPResponse.statusCode == 200 else {
            throw APIError.serverError(statusCode: messageHTTPResponse.statusCode)
        }

        // Delete the conversation to keep it out of chat history (incognito mode)
        let deleteURL = try URLBuilder(baseURL: baseURL)
            .appendingPathComponents(["/organizations", orgId, "/chat_conversations", conversationUUID])
            .build()

        var deleteRequest = URLRequest(url: deleteURL)
        deleteRequest.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        deleteRequest.httpMethod = "DELETE"

        // Attempt to delete, but don't fail if deletion fails
        // The session is already initialized, which is the primary goal
        do {
            let startTime3 = Date()
            let (deleteData, deleteResponse) = try await URLSession.shared.data(for: deleteRequest)
            let duration3 = Date().timeIntervalSince(startTime3)

            if let deleteHTTPResponse = deleteResponse as? HTTPURLResponse {
                NetworkLoggerService.shared.logRequest(
                    url: deleteURL.absoluteString,
                    method: "DELETE",
                    requestBody: deleteRequest.httpBody,
                    responseData: deleteData,
                    statusCode: deleteHTTPResponse.statusCode,
                    duration: duration3,
                    error: nil
                )
            }
        } catch {
            // Silently ignore deletion errors - session is already initialized
        }
    }

}
