import XCTest
import UsageCore
@testable import Claude_Usage

final class ClaudeSetupStateTests: HostedAppTestCase {
    func testCompleteWhenBrowserAndTerminalSignInsArePresent() {
        let profile = Profile(
            name: "Complete",
            claudeSessionKey: "session-key",
            organizationId: "organization-id",
            cliCredentialsJSON: "terminal-sign-in"
        )

        XCTAssertEqual(ClaudeSetupState.of(profile), .complete)
    }

    func testBrowserOnlyWhenOnlyBrowserSignInIsPresent() {
        let profile = Profile(
            name: "Browser only",
            claudeSessionKey: "session-key",
            organizationId: "organization-id"
        )

        XCTAssertEqual(ClaudeSetupState.of(profile), .browserOnly)
    }

    func testTerminalOnlyWhenOnlyTerminalSignInIsPresent() {
        let profile = Profile(
            name: "Terminal only",
            hasCliAccount: true
        )

        XCTAssertEqual(ClaudeSetupState.of(profile), .terminalOnly)
    }

    func testNoneWhenNeitherSignInIsPresent() {
        let profile = Profile(name: "Not set up")

        XCTAssertEqual(ClaudeSetupState.of(profile), .none)
    }

    func testOnlyTerminalOnlyClaudeProfilesNeedPersistentAttention() {
        let terminalOnly = Profile(
            name: "Terminal",
            cliCredentialsJSON: "{}",
            hasCliAccount: true
        )
        let browserOnly = Profile(
            name: "Browser",
            claudeSessionKey: "session",
            organizationId: "org"
        )
        let complete = Profile(
            name: "Complete",
            claudeSessionKey: "session",
            organizationId: "org",
            cliCredentialsJSON: "{}",
            hasCliAccount: true
        )
        let codex = Profile(
            name: "Codex",
            providerConfiguration: .codex(
                CodexProfileConfiguration(linkedHome: nil)
            ),
            cliCredentialsJSON: "{}",
            hasCliAccount: true
        )

        XCTAssertTrue(
            ClaudeAccountAttention.isSetupIncomplete(terminalOnly)
        )
        XCTAssertFalse(
            ClaudeAccountAttention.isSetupIncomplete(browserOnly)
        )
        XCTAssertFalse(
            ClaudeAccountAttention.isSetupIncomplete(complete)
        )
        XCTAssertFalse(
            ClaudeAccountAttention.isSetupIncomplete(codex)
        )
    }

    func testTerminalSummaryMarksExpiredAndTokenlessSignInsAsUnhealthy() {
        let expired = Profile(
            name: "Expired",
            claudeSessionKey: "browser",
            organizationId: "org",
            cliCredentialsJSON:
                #"{"claudeAiOauth":{"accessToken":"old","expiresAt":1}}"#,
            hasCliAccount: true
        )
        let tokenless = Profile(
            name: "Signed out",
            cliCredentialsJSON:
                #"{"claudeAiOauth":{"accessToken":""}}"#,
            hasCliAccount: true
        )

        XCTAssertEqual(
            ClaudeAccountView.terminalSummaryHealth(expired),
            .needsAttention
        )
        XCTAssertEqual(
            ClaudeAccountView.terminalSummaryHealth(tokenless),
            .needsAttention
        )
    }

    func testTerminalSummaryOnlyUsesGreenForUsableSignIns() {
        let valid = #"{"claudeAiOauth":{"accessToken":"working"}}"#
        let complete = Profile(
            name: "Complete",
            claudeSessionKey: "browser",
            organizationId: "org",
            cliCredentialsJSON: valid,
            hasCliAccount: true
        )
        let terminalOnly = Profile(
            name: "Terminal",
            cliCredentialsJSON: valid,
            hasCliAccount: true
        )

        XCTAssertEqual(
            ClaudeAccountView.terminalSummaryHealth(complete),
            .working
        )
        XCTAssertEqual(
            ClaudeAccountView.terminalSummaryHealth(terminalOnly),
            .workingNotRenewable
        )
    }

    func testBrowserCredentialSaveMetadataIsOptionalAndPersists() throws {
        let legacy = Profile(name: "Before metadata")
        let legacyRoundTrip = try JSONDecoder().decode(
            Profile.self,
            from: JSONEncoder().encode(legacy)
        )
        XCTAssertNil(legacyRoundTrip.claudeBrowserCredentialSavedAt)

        let timestamp = Date(timeIntervalSinceReferenceDate: 8_400)
        let current = Profile(
            name: "With metadata",
            claudeBrowserCredentialSavedAt: timestamp
        )
        let currentRoundTrip = try JSONDecoder().decode(
            Profile.self,
            from: JSONEncoder().encode(current)
        )
        XCTAssertEqual(
            currentRoundTrip.claudeBrowserCredentialSavedAt,
            timestamp
        )
    }

    func testBrowserDetailNeverSubstitutesLastUsedForUnknownSaveTime() {
        let activityTime = Date(timeIntervalSinceReferenceDate: 7_700)
        let legacy = Profile(
            name: "Legacy",
            claudeSessionKey: "session",
            organizationId: "org",
            lastUsedAt: activityTime
        )
        let detail = ClaudeBrowserCredentialDetail(profile: legacy)

        XCTAssertEqual(detail.organization, "org")
        XCTAssertNil(detail.savedAt)
        XCTAssertNotEqual(detail.savedAt, legacy.lastUsedAt)
        XCTAssertEqual(
            ClaudeAccountView.browserDetail(legacy),
            String(
                format: "claude_account.browser.detail_without_saved_time"
                    .localized,
                "org"
            )
        )
    }

    func testBrowserDetailIncludesActualSavedDateWhenRecorded() {
        let savedAt = Date(timeIntervalSinceReferenceDate: 7_000)
        let now = savedAt.addingTimeInterval(60)
        let profile = Profile(
            name: "New",
            claudeSessionKey: "session",
            organizationId: "org",
            claudeBrowserCredentialSavedAt: savedAt
        )
        let detail = ClaudeAccountView.browserDetail(profile, now: now)

        XCTAssertTrue(detail.contains("org"), detail)
        XCTAssertTrue(detail.contains("session key stored"), detail)
        XCTAssertNotEqual(
            detail,
            String(
                format: "claude_account.browser.detail_without_saved_time"
                    .localized,
                "org"
            )
        )
    }

    func testTerminalOnlyDetailDistinguishesKnownAndUnknownExpiry() {
        let now = Date()
        let futureMilliseconds = now.addingTimeInterval(7_200)
            .timeIntervalSince1970 * 1_000
        let known = Profile(
            name: "Known",
            cliCredentialsJSON:
                #"{"claudeAiOauth":{"accessToken":"working","expiresAt":\#(futureMilliseconds)}}"#,
            hasCliAccount: true,
            cliAccountName: "work"
        )
        let unknown = Profile(
            name: "Unknown",
            cliCredentialsJSON:
                #"{"claudeAiOauth":{"accessToken":"working"}}"#,
            hasCliAccount: true,
            cliAccountName: "work"
        )

        let knownDetail = ClaudeAccountView.terminalDetail(
            known,
            setupState: .terminalOnly,
            now: now
        )
        let unknownDetail = ClaudeAccountView.terminalDetail(
            unknown,
            setupState: .terminalOnly,
            now: now
        )
        XCTAssertTrue(knownDetail.contains("expires in"), knownDetail)
        XCTAssertEqual(
            unknownDetail,
            String(
                format: "claude_account.terminal.expiry_unknown_detail"
                    .localized,
                "work"
            )
        )
        XCTAssertFalse(unknownDetail.contains("written back"), unknownDetail)
    }

    @MainActor
    func testCredentialRepairSynchronizesEverySetupIncompleteConsumer()
        throws
    {
        var terminalOnly = Profile(
            name: "Repair me",
            cliCredentialsJSON:
                #"{"claudeAiOauth":{"accessToken":"working"}}"#,
            hasCliAccount: true
        )
        let profileStore = retain(makeIsolatedProfileStore())
        try seedProfilesForTesting([terminalOnly], in: profileStore)
        let manager = retain(ProfileManager(profileStore: profileStore))
        manager.loadProfiles()
        let presentationStore = retain(UsagePresentationStore())
        let context = UsagePresentationContext(
            epoch: 1,
            focusedProfileID: terminalOnly.id,
            visibleProfileIDs: [terminalOnly.id]
        )
        let stale = PresentationSnapshot(
            profileID: terminalOnly.id,
            profileName: terminalOnly.name,
            providerID: .claude,
            providerRevision: terminalOnly.providerRevision,
            presentationEpoch: 1,
            capabilities: ProviderCapabilities([:]),
            configurationState: .ready,
            report: nil,
            claudeUsage: nil,
            claudeAPIUsage: nil,
            activity: .refreshing(
                requestID: UUID(),
                trigger: .manual,
                startedAt: Date()
            ),
            lastSuccessfulAt: nil,
            currentFailure: nil,
            claudeSetupState: .terminalOnly
        )
        presentationStore.activate(context, hydrated: [terminalOnly.id: stale])

        try manager.saveCredentials(
            for: terminalOnly.id,
            credentials: ProfileCredentials(
                claudeSessionKey: "browser",
                organizationId: "org",
                cliCredentialsJSON: terminalOnly.cliCredentialsJSON
            ),
            browserCredentialSave: true
        )
        terminalOnly = try XCTUnwrap(manager.profiles.first)
        let repairedState = try XCTUnwrap(
            manager.claudeSetupState(for: terminalOnly)
        )
        presentationStore.synchronizeClaudeSetupState(
            repairedState,
            profileID: terminalOnly.id
        )
        XCTAssertTrue(presentationStore.publish(stale, expected: context))
        let snapshotState = presentationStore.snapshot(
            for: terminalOnly.id
        )?.claudeSetupState

        XCTAssertEqual(snapshotState, .complete)
        XCTAssertFalse(
            ClaudeAccountAttention.isSetupIncomplete(
                terminalOnly,
                snapshot: snapshotState
            )
        )
        XCTAssertNil(
            LegacyPopoverBanner.resolve(
                hasCredentialError: false,
                setupState: snapshotState,
                consecutiveRefreshFailures: 0,
                lastSuccessfulRefreshTime: Date(),
                now: Date()
            )
        )
        XCTAssertNil(
            MenuBarAttentionSignal.attention(
                cliSignInIssue: nil,
                credentialFailureStreak: 0,
                healthStatus: .healthy,
                setupState: snapshotState
            )
        )
    }

    @MainActor
    func testBrowserSessionOnlyWarningExcludesAPIAndCLICredentials() throws {
        let browser = Profile(name: "Browser held")
        let api = Profile(name: "API held")
        let cli = Profile(name: "CLI held")
        let otherBrowser = Profile(name: "Other browser held")
        let secrets = RetryableBrowserSecretStore()
        let store = retain(
            makeIsolatedProfileStore(
                defaults: IsolatedProfileDefaults(),
                secretStore: secrets
            )
        )
        try seedProfilesForTesting(
            [browser, api, cli, otherBrowser],
            in: store
        )
        let manager = retain(ProfileManager(profileStore: store))
        manager.loadProfiles()
        secrets.refusedFields = Set(ProfileSecretField.allCases)

        try manager.saveCredentials(
            for: browser.id,
            credentials: ProfileCredentials(
                claudeSessionKey: "browser",
                organizationId: "org"
            ),
            acceptingSessionOnly: true,
            browserCredentialSave: true
        )
        try manager.saveCredentials(
            for: api.id,
            credentials: ProfileCredentials(
                apiSessionKey: "api",
                apiOrganizationId: "api-org"
            ),
            acceptingSessionOnly: true
        )
        try manager.saveCredentials(
            for: cli.id,
            credentials: ProfileCredentials(
                cliCredentialsJSON:
                    #"{"claudeAiOauth":{"accessToken":"cli"}}"#
            ),
            acceptingSessionOnly: true
        )
        try manager.saveCredentials(
            for: otherBrowser.id,
            credentials: ProfileCredentials(
                claudeSessionKey: "other-browser",
                organizationId: "other-org"
            ),
            acceptingSessionOnly: true,
            browserCredentialSave: true
        )

        XCTAssertEqual(
            manager.sessionOnlyCredentialProfileIDs,
            [browser.id, api.id, cli.id, otherBrowser.id]
        )
        XCTAssertEqual(
            manager.sessionOnlyClaudeAICredentialProfileIDs,
            [browser.id, otherBrowser.id]
        )
        XCTAssertTrue(
            ClaudeAccountView.showsBrowserCredentialNotSavedWarning(
                profileID: browser.id,
                browserSessionOnlyProfileIDs:
                    manager.sessionOnlyClaudeAICredentialProfileIDs
            )
        )
        XCTAssertFalse(
            ClaudeAccountView.showsBrowserCredentialNotSavedWarning(
                profileID: api.id,
                browserSessionOnlyProfileIDs:
                    manager.sessionOnlyClaudeAICredentialProfileIDs
            )
        )
        XCTAssertFalse(
            ClaudeAccountView.showsBrowserCredentialNotSavedWarning(
                profileID: cli.id,
                browserSessionOnlyProfileIDs:
                    manager.sessionOnlyClaudeAICredentialProfileIDs
            )
        )
        XCTAssertFalse(
            ClaudeAccountView.showsBrowserCredentialNotSavedWarning(
                profileID: UUID(),
                browserSessionOnlyProfileIDs: [otherBrowser.id]
            )
        )
    }

    @MainActor
    func testDurableBrowserSaveStampsExactSaveTime() throws {
        let timestamp = Date(timeIntervalSinceReferenceDate: 9_100)
        let profile = Profile(name: "Browser save")
        let store = retain(makeIsolatedProfileStore())
        try seedProfilesForTesting([profile], in: store)
        let manager = retain(
            ProfileManager(profileStore: store, now: { timestamp })
        )
        manager.loadProfiles()

        try manager.saveCredentials(
            for: profile.id,
            credentials: ProfileCredentials(
                claudeSessionKey: "session",
                organizationId: "org"
            ),
            browserCredentialSave: true
        )

        XCTAssertEqual(
            manager.profiles.first?.claudeBrowserCredentialSavedAt,
            timestamp
        )
        XCTAssertEqual(
            store.loadProfiles().first?.claudeBrowserCredentialSavedAt,
            timestamp
        )
    }

    @MainActor
    func testSessionOnlyBrowserSaveStampsOnlyAfterRetrySucceeds() throws {
        let oldTimestamp = Date(timeIntervalSinceReferenceDate: 9_100)
        let retryTimestamp = Date(timeIntervalSinceReferenceDate: 9_200)
        let profile = Profile(
            name: "Retry save",
            claudeBrowserCredentialSavedAt: oldTimestamp
        )
        let secrets = RetryableBrowserSecretStore()
        let store = retain(
            makeIsolatedProfileStore(
                defaults: IsolatedProfileDefaults(),
                secretStore: secrets
            )
        )
        try seedProfilesForTesting([profile], in: store)
        let manager = retain(
            ProfileManager(profileStore: store, now: { retryTimestamp })
        )
        manager.loadProfiles()

        secrets.refusesWrites = true
        try manager.saveCredentials(
            for: profile.id,
            credentials: ProfileCredentials(
                claudeSessionKey: "session",
                organizationId: "org"
            ),
            acceptingSessionOnly: true,
            browserCredentialSave: true
        )
        XCTAssertNil(
            manager.profiles.first?.claudeBrowserCredentialSavedAt
        )
        XCTAssertEqual(
            store.loadProfiles().first?.claudeBrowserCredentialSavedAt,
            oldTimestamp,
            "session-only replacement must not rewrite durable metadata"
        )
        XCTAssertTrue(
            manager.sessionOnlyCredentialProfileIDs.contains(profile.id)
        )

        secrets.refusesWrites = false
        XCTAssertTrue(
            manager.retrySessionOnlyCredentialSave(profileID: profile.id)
        )
        XCTAssertEqual(
            manager.profiles.first?.claudeBrowserCredentialSavedAt,
            retryTimestamp
        )
        XCTAssertEqual(
            store.loadProfiles().first?.claudeBrowserCredentialSavedAt,
            retryTimestamp
        )
    }
}

private final class RetryableBrowserSecretStore: ProfileSecretStore {
    enum Refusal: Error { case expected }
    var refusesWrites = false
    var refusedFields: Set<ProfileSecretField> = []
    private var values: [ProfileSecretLocator: String] = [:]

    func read(
        _ locator: ProfileSecretLocator
    ) throws -> ProfileSecretReadResult {
        values[locator].map(ProfileSecretReadResult.value) ?? .absent
    }

    func write(_ value: String, to locator: ProfileSecretLocator) throws {
        if refusesWrites || refusedFields.contains(locator.field) {
            throw Refusal.expected
        }
        values[locator] = value
    }

    func delete(_ locator: ProfileSecretLocator) throws {
        values.removeValue(forKey: locator)
    }
}
