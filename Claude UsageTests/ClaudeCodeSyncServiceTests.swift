import XCTest
@testable import Claude_Usage

/// Records every `/usr/bin/security` invocation and replays scripted results.
///
/// The point of the seam: the write path here is the only code in this app
/// that can destroy a user's Claude Code login, and its failure modes — a
/// locked Keychain, a denied ACL, a dismissed SecurityAgent prompt — are
/// exactly the ones no test can arrange against the real Keychain.
private final class RecordingSecurityRunner: SecurityCommandRunning {
    private(set) var invocations: [[String]] = []

    /// Consulted in order; the last entry is reused once exhausted.
    var results: [SecurityCommandResult] = [
        SecurityCommandResult(exitCode: 0, standardOutput: "", standardError: "")
    ]
    private var nextResultIndex = 0

    /// The verb of each invocation, e.g. `add-generic-password`.
    var verbs: [String] { invocations.compactMap(\.first) }

    func run(_ arguments: [String]) throws -> SecurityCommandResult {
        invocations.append(arguments)
        let result = results[min(nextResultIndex, results.count - 1)]
        nextResultIndex += 1
        return result
    }
}

final class ClaudeCodeSyncServiceTests: HostedAppTestCase {
    private let credentials = #"{"claudeAiOauth":{"accessToken":"abc"}}"#

    /// Everything injected here is retained for the process lifetime, per
    /// `HostedAppTestCase`: the app target uses main-actor default isolation,
    /// and releasing an injected actor-isolated service from the XCTest thunk
    /// trips a runtime allocator bug that crashes the host.
    @MainActor
    private func makeService(
        runner: RecordingSecurityRunner,
        liveProcessDetector: LiveClaudeProcessDetector = .stubbedIdle()
    ) -> ClaudeCodeSyncService {
        _ = retain(runner)
        return retain(
            ClaudeCodeSyncService(
                profileStore: retain(makeIsolatedProfileStore()),
                securityRunner: runner,
                liveProcessDetector: liveProcessDetector
            )
        )
    }

    /// For `applyProfileCredentials` tests: `systemCredentialsReader` stands
    /// in for the account's live login without touching the real Keychain or
    /// filesystem, and `profileStore` is supplied by the caller so a test can
    /// seed the profile `applyProfileCredentials` looks up.
    @MainActor
    private func makeService(
        runner: RecordingSecurityRunner,
        profileStore: ProfileStore,
        systemCredentialsReader: (() throws -> String?)? = nil,
        keychainCredentialsReader: ((String?) throws -> String?)? = nil,
        credentialsFileDirectory: ((String?) -> URL)? = nil,
        credentialLogSink: ((String) -> Void)? = nil,
        liveProcessDetector: LiveClaudeProcessDetector = .stubbedIdle()
    ) -> ClaudeCodeSyncService {
        _ = retain(runner)
        // Apply tests provide a system-reader seam and must not fall through
        // to the machine Keychain for the new direct-item ownership check.
        // Rotation tests leave that seam nil so their scripted runner remains
        // the owner of the Keychain interaction.
        let itemReader = keychainCredentialsReader
            ?? (systemCredentialsReader == nil ? nil : { _ in nil })
        // One directory for the life of this service, not a fresh UUID on
        // every call. The closure used to mint a new path each time it was
        // asked, which was invisible while it only resolved the credentials
        // file — and became a real defect the moment the Keychain service
        // name was derived from the same directory: the item that was read
        // and the item that was written came out with different hashes,
        // which is precisely the drift this resolution exists to prevent.
        let stableDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileDirectory = credentialsFileDirectory ?? { _ in stableDirectory }
        return retain(
            ClaudeCodeSyncService(
                profileStore: profileStore,
                systemCredentialsReader: systemCredentialsReader,
                keychainCredentialsReader: itemReader,
                securityRunner: runner,
                credentialsFileDirectory: fileDirectory,
                credentialLogSink: credentialLogSink,
                liveProcessDetector: liveProcessDetector
            )
        )
    }

    /// The one call every production write now goes through. Tests that are
    /// about the Keychain mechanics — `-U`, the delete-then-add recovery,
    /// the stderr in the error — call it with an idle account, because the
    /// low-level primitive behind it is private on purpose.
    @MainActor
    @discardableResult
    private func write(
        _ credentialsJSON: String,
        with service: ClaudeCodeSyncService,
        forAccountNamed accountName: String? = nil,
        purpose: String = "a test"
    ) throws -> Bool {
        try service.commitClaudeCodeStoreWrite(
            credentialsJSON,
            forAccountNamed: accountName,
            store: .keychain,
            purpose: purpose
        )
    }

    /// A credential blob with an explicit expiry, in the milliseconds-since-
    /// epoch shape the CLI actually stores.
    private func credentials(expiresAtMillis: Double) -> String {
        #"{"claudeAiOauth":{"accessToken":"abc","expiresAt":\#(expiresAtMillis)}}"#
    }

    // MARK: - Writes must never open a window with no login

    /// The regression this file exists for. The previous implementation ran
    /// `delete-generic-password` before adding, so a failure of the add left
    /// the user logged out of Claude Code. `-U` already updates in place.
    @MainActor
    func testSuccessfulWriteNeverDeletesTheExistingItem() throws {
        // Contract change: the write now enters through
        // `commitClaudeCodeStoreWrite`, the one chokepoint, rather than
        // through a public primitive any caller could reach. What is
        // asserted about the Keychain mechanics is unchanged.
        let runner = RecordingSecurityRunner()
        let service = makeService(runner: runner)
        XCTAssertTrue(try write(credentials, with: service))

        XCTAssertEqual(runner.verbs, ["add-generic-password"])
        XCTAssertFalse(
            runner.verbs.contains("delete-generic-password"),
            "A successful write must not delete the user's live credentials"
        )
    }

    @MainActor
    func testWriteUpdatesInPlace() throws {
        // Contract change: same assertion, now made of the write that goes
        // through the one chokepoint.
        let runner = RecordingSecurityRunner()
        XCTAssertTrue(try write(credentials, with: makeService(runner: runner)))

        let add = try XCTUnwrap(runner.invocations.first)
        XCTAssertTrue(add.contains("-U"), "The add must update an existing item")
        XCTAssertTrue(add.contains(credentials))
        XCTAssertTrue(add.contains(NSUserName()))
    }

    /// A failed write must leave whatever was already in the Keychain alone.
    @MainActor
    func testFailedWriteLeavesExistingCredentialsUntouched() {
        let runner = RecordingSecurityRunner()
        runner.results = [
            SecurityCommandResult(
                exitCode: 1,
                standardOutput: "",
                standardError: "security: SecKeychainItemCreateFromContent: "
                    + "User interaction is not allowed."
            )
        ]

        // Contract change: the failure still surfaces as a throw, and now
        // surfaces it through the one chokepoint.
        let service = makeService(runner: runner)
        XCTAssertThrowsError(try write(credentials, with: service))
        XCTAssertFalse(runner.verbs.contains("delete-generic-password"))
    }

    /// The exit code alone is not an `OSStatus` and explains nothing; the
    /// CLI's stderr is the only real diagnostic, so it has to survive.
    @MainActor
    func testWriteFailureCarriesExitCodeAndStderr() {
        let runner = RecordingSecurityRunner()
        runner.results = [
            SecurityCommandResult(
                exitCode: 51,
                standardOutput: "",
                standardError: "security: the specified keychain is not valid"
            )
        ]

        // Contract change: routed through the one chokepoint; the error the
        // caller sees is still the Keychain's own, exit code and stderr
        // intact.
        let service = makeService(runner: runner)
        XCTAssertThrowsError(try write(credentials, with: service)) { error in
            guard case ClaudeCodeError.keychainWriteFailed(
                let exitCode,
                let message
            ) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(exitCode, 51)
            XCTAssertTrue(message.contains("not valid"), message)
            XCTAssertTrue(
                error.localizedDescription.contains("not valid"),
                error.localizedDescription
            )
        }
    }

    /// `-U` should make this unreachable, but if the Keychain refuses the
    /// update as a duplicate anyway there still has to be a way through.
    @MainActor
    func testDuplicateItemFallsBackToDeleteThenAdd() throws {
        let runner = RecordingSecurityRunner()
        runner.results = [
            SecurityCommandResult(exitCode: 45, standardOutput: "", standardError: ""),
            SecurityCommandResult(exitCode: 0, standardOutput: "", standardError: ""),
            SecurityCommandResult(exitCode: 0, standardOutput: "", standardError: "")
        ]

        // Contract change: routed through the one chokepoint. The
        // duplicate-item recovery is unchanged.
        XCTAssertTrue(try write(credentials, with: makeService(runner: runner)))

        XCTAssertEqual(
            runner.verbs,
            [
                "add-generic-password",
                "delete-generic-password",
                "add-generic-password"
            ]
        )
    }

    // MARK: - Reads

    @MainActor
    func testKeychainOnlyImportWinsOverDifferentFallbackChainCredential() throws {
        let profile = Profile(
            name: "Frozen Link Target",
            hasCliAccount: false,
            cliAccountName: "target-account"
        )
        let store = retain(makeIsolatedProfileStore())
        try seedProfilesForTesting([profile], in: store)
        let fileCredential =
            #"{"claudeAiOauth":{"accessToken":"FILE"}}"#
        let keychainCredential =
            #"{"claudeAiOauth":{"accessToken":"KEYCHAIN"}}"#
        let service = retain(
            ClaudeCodeSyncService(
                profileStore: store,
                systemCredentialsReader: { fileCredential },
                keychainCredentialsReader: { accountName in
                    XCTAssertEqual(accountName, "target-account")
                    return keychainCredential
                }
            )
        )

        try service.syncKeychainToProfile(profile.id)

        XCTAssertEqual(
            try store.loadProfileCredentials(profile.id).cliCredentialsJSON,
            keychainCredential
        )
    }

    @MainActor
    func testKeychainOnlyImportDistinguishesAbsentFromPresentInvalidItem() throws {
        let profile = Profile(
            name: "Keychain State",
            cliAccountName: "target-account"
        )
        let store = retain(makeIsolatedProfileStore())
        try seedProfilesForTesting([profile], in: store)

        let absent = retain(
            ClaudeCodeSyncService(
                profileStore: store,
                keychainCredentialsReader: { _ in nil }
            )
        )
        XCTAssertThrowsError(try absent.syncKeychainToProfile(profile.id)) {
            guard case ClaudeCodeError.noCredentialsFound = $0 else {
                return XCTFail("Expected absence, got \($0)")
            }
        }

        for invalid in [
            #"{"claudeAiOauth":{"accessToken":""}}"#,
            "not-json"
        ] {
            let present = retain(
                ClaudeCodeSyncService(
                    profileStore: store,
                    keychainCredentialsReader: { _ in invalid }
                )
            )
            XCTAssertThrowsError(
                try present.syncKeychainToProfile(profile.id)
            ) {
                guard case ClaudeCodeError.invalidJSON = $0 else {
                    return XCTFail("Expected invalid item, got \($0)")
                }
            }
        }
    }

    @MainActor
    func testKeychainOnlyImportRejectsPresentUnreadableItem() throws {
        let profile = Profile(
            name: "Unreadable Keychain",
            cliAccountName: "target-account"
        )
        let store = retain(makeIsolatedProfileStore())
        try seedProfilesForTesting([profile], in: store)
        let runner = RecordingSecurityRunner()
        runner.results = [
            SecurityCommandResult(
                exitCode: 0,
                standardOutput: nil,
                standardError: ""
            )
        ]
        let service = retain(
            ClaudeCodeSyncService(
                profileStore: store,
                securityRunner: runner
            )
        )

        XCTAssertThrowsError(
            try service.syncKeychainToProfile(profile.id)
        ) {
            guard case ClaudeCodeError.invalidJSON = $0 else {
                return XCTFail("Expected invalid item, got \($0)")
            }
        }
        XCTAssertEqual(runner.verbs, ["find-generic-password"])
    }

    @MainActor
    func testReadReturnsTrimmedKeychainValue() throws {
        let runner = RecordingSecurityRunner()
        runner.results = [
            SecurityCommandResult(
                exitCode: 0,
                standardOutput: credentials + "\n",
                standardError: ""
            )
        ]
        let service = makeService(runner: runner)

        XCTAssertEqual(try service.readKeychainCredentials(), credentials)
    }

    /// 44 is `security`'s "no such item", which is an absence, not a failure.
    @MainActor
    func testMissingItemReadsAsAbsentRatherThanFailing() throws {
        let runner = RecordingSecurityRunner()
        runner.results = [
            SecurityCommandResult(exitCode: 44, standardOutput: "", standardError: "")
        ]
        let service = makeService(runner: runner)

        XCTAssertNil(try service.readKeychainCredentials())
    }

    /// A Keychain item whose secret is not valid UTF-8 is unreadable, not
    /// empty. Returning `""` here would satisfy `readSystemCredentials`'s
    /// non-nil check, fail its JSON validation, and tell the user their
    /// credentials are corrupt — when the actionable answer is "log in".
    @MainActor
    func testUndecodableSecretReadsAsAbsentRatherThanEmpty() throws {
        let runner = RecordingSecurityRunner()
        runner.results = [
            SecurityCommandResult(
                exitCode: 0,
                standardOutput: nil,
                standardError: ""
            )
        ]
        let service = makeService(runner: runner)

        XCTAssertNil(try service.readKeychainCredentials())
    }

    @MainActor
    func testReadFailureCarriesExitCodeAndStderr() {
        let runner = RecordingSecurityRunner()
        runner.results = [
            SecurityCommandResult(
                exitCode: 36,
                standardOutput: "",
                standardError: "security: interaction not allowed"
            )
        ]
        let service = makeService(runner: runner)

        XCTAssertThrowsError(try service.readKeychainCredentials()) { error in
            guard case ClaudeCodeError.keychainReadFailed(
                let exitCode,
                let message
            ) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(exitCode, 36)
            XCTAssertTrue(message.contains("interaction not allowed"), message)
        }
    }

    // MARK: - Named-account reads must never cross into another account's login

    /// A named account with no Keychain item of its own must read as absent,
    /// never fall through to the shared/legacy item. Before this fix, a
    /// missing account-specific item silently resolved to whichever account
    /// last wrote the shared one — which then authenticated requests, and
    /// synchronization could persist, as the wrong account.
    ///
    /// The account name here is unique per test run, so it is guaranteed to
    /// have no real Keychain item — `accountServiceName` finds none and
    /// `readKeychainCredentials` must return `nil` without ever invoking
    /// `security` looking for the shared item.
    @MainActor
    func testNamedAccountWithNoOwnItemNeverFallsBackToSharedKeychainItem() throws {
        let runner = RecordingSecurityRunner()
        let service = makeService(runner: runner)
        let accountName = "no-such-account-\(UUID().uuidString)"

        XCTAssertNil(try service.readKeychainCredentials(forAccountNamed: accountName))
        XCTAssertTrue(
            runner.invocations.isEmpty,
            "A named account with no item of its own must never search for "
                + "the shared/legacy item: \(runner.invocations)"
        )
    }

    // MARK: - applyProfileCredentials must fail closed on unknown freshness

    private func seedProfileForApply(
        cliCredentialsJSON: String,
        in store: ProfileStore
    ) throws -> UUID {
        let profile = Profile(
            name: "Apply Test",
            cliCredentialsJSON: cliCredentialsJSON,
            hasCliAccount: true,
            cliAccountName: "apply-test-account"
        )
        try seedProfilesForTesting([profile], in: store)
        // `seedProfilesForTesting` writes the profile's non-secret fields;
        // the CLI credential itself lives in the secret store and needs the
        // explicit secure-write API, or `loadProfileCredentials` reads back
        // `nil` and `applyProfileCredentials` throws `noProfileCredentials`.
        try store.saveCLIProfileCredential(cliCredentialsJSON, for: profile.id)
        return profile.id
    }

    /// No live login exists for the account at all — there is nothing to
    /// protect, so the write proceeds. This is the case the write exists for.
    @MainActor
    func testApplyProfileCredentialsWritesWhenNoLiveLoginExists() throws {
        let runner = RecordingSecurityRunner()
        let store = retain(makeIsolatedProfileStore())
        let profileId = try seedProfileForApply(
            cliCredentialsJSON: credentials(expiresAtMillis: 1_000),
            in: store
        )
        let service = makeService(
            runner: runner,
            profileStore: store,
            systemCredentialsReader: { nil }
        )

        try service.applyProfileCredentials(profileId)

        XCTAssertEqual(runner.verbs, ["add-generic-password"])
    }

    /// A live login exists, but its expiry can't be read — freshness is
    /// indeterminate, so the write must be declined rather than risk rolling
    /// back a login this code can't reason about.
    @MainActor
    func testApplyProfileCredentialsDeclinesWriteWhenLiveExpiryIsUnknown() throws {
        let runner = RecordingSecurityRunner()
        let store = retain(makeIsolatedProfileStore())
        let profileId = try seedProfileForApply(
            cliCredentialsJSON: credentials(expiresAtMillis: 1_000),
            in: store
        )
        let service = makeService(
            runner: runner,
            profileStore: store,
            // A live login with no `expiresAt` at all.
            systemCredentialsReader: { #"{"claudeAiOauth":{"accessToken":"live"}}"# }
        )

        try service.applyProfileCredentials(profileId)

        XCTAssertTrue(
            runner.invocations.isEmpty,
            "Unknown freshness must decline the write, not permit it: \(runner.invocations)"
        )
    }

    /// The live read itself fails — same "can't establish freshness" case as
    /// a missing `expiresAt`, and must fail closed the same way.
    @MainActor
    func testApplyProfileCredentialsDeclinesWriteWhenLiveReadFails() throws {
        let runner = RecordingSecurityRunner()
        let store = retain(makeIsolatedProfileStore())
        let profileId = try seedProfileForApply(
            cliCredentialsJSON: credentials(expiresAtMillis: 1_000),
            in: store
        )
        let service = makeService(
            runner: runner,
            profileStore: store,
            systemCredentialsReader: { throw ClaudeCodeError.invalidJSON }
        )

        try service.applyProfileCredentials(profileId)

        XCTAssertTrue(
            runner.invocations.isEmpty,
            "A failed freshness read must decline the write, not permit it: \(runner.invocations)"
        )
    }

    /// The live login is demonstrably newer than the stored snapshot —
    /// applying the snapshot would sign the account backwards, so the write
    /// must be declined.
    @MainActor
    func testApplyProfileCredentialsDeclinesWriteWhenLiveLoginIsNewer() throws {
        let runner = RecordingSecurityRunner()
        let store = retain(makeIsolatedProfileStore())
        let profileId = try seedProfileForApply(
            cliCredentialsJSON: credentials(expiresAtMillis: 1_000),
            in: store
        )
        let service = makeService(
            runner: runner,
            profileStore: store,
            systemCredentialsReader: { self.credentials(expiresAtMillis: 2_000) }
        )

        try service.applyProfileCredentials(profileId)

        XCTAssertTrue(
            runner.invocations.isEmpty,
            "A newer live login must not be rolled back: \(runner.invocations)"
        )
    }

    /// The stored snapshot is at least as new as the live login — the write
    /// is safe and must proceed.
    @MainActor
    func testApplyProfileCredentialsWritesWhenStoredIsAtLeastAsNewAsLive() throws {
        let runner = RecordingSecurityRunner()
        let store = retain(makeIsolatedProfileStore())
        let profileId = try seedProfileForApply(
            cliCredentialsJSON: credentials(expiresAtMillis: 2_000),
            in: store
        )
        let service = makeService(
            runner: runner,
            profileStore: store,
            systemCredentialsReader: { self.credentials(expiresAtMillis: 1_000) }
        )

        try service.applyProfileCredentials(profileId)

        XCTAssertEqual(runner.verbs, ["add-generic-password"])
    }

    @MainActor
    func testApplyProfileCredentialsSkipsIdenticalKeychainLogin() throws {
        let runner = RecordingSecurityRunner()
        let store = retain(makeIsolatedProfileStore())
        let snapshot = credentials(
            accessToken: "same", refreshToken: "same-refresh", expiresAtMillis: 2_000
        )
        let profileId = try seedProfileForApply(
            cliCredentialsJSON: snapshot, in: store
        )
        var logs: [String] = []
        let service = makeService(
            runner: runner,
            profileStore: store,
            systemCredentialsReader: { snapshot },
            keychainCredentialsReader: { _ in snapshot },
            credentialLogSink: { logs.append($0) }
        )

        try service.applyProfileCredentials(profileId)

        XCTAssertTrue(runner.invocations.isEmpty)
        XCTAssertTrue(logs.contains { $0.contains("Keychain item already holds this login") })
    }

    @MainActor
    func testApplyProfileCredentialsDoesNotReplaceFresherKeychainLogin() throws {
        let runner = RecordingSecurityRunner()
        let store = retain(makeIsolatedProfileStore())
        let fileLogin = credentials(
            accessToken: "file", refreshToken: "file-refresh", expiresAtMillis: 1_000
        )
        let snapshot = credentials(
            accessToken: "stored", refreshToken: "stored-refresh", expiresAtMillis: 2_000
        )
        let keychainLogin = credentials(
            accessToken: "keychain", refreshToken: "keychain-refresh", expiresAtMillis: 3_000
        )
        let profileId = try seedProfileForApply(
            cliCredentialsJSON: snapshot, in: store
        )
        let directory = try makeTemporaryCredentialsDirectory()
        try writeCredentialsFile(fileLogin, in: directory)
        var logs: [String] = []
        let service = makeService(
            runner: runner,
            profileStore: store,
            systemCredentialsReader: { fileLogin },
            keychainCredentialsReader: { _ in keychainLogin },
            credentialsFileDirectory: { _ in directory },
            credentialLogSink: { logs.append($0) }
        )

        try service.applyProfileCredentials(profileId)

        XCTAssertTrue(
            runner.invocations.isEmpty,
            "A fresher Keychain login must not be replaced: \(runner.invocations)"
        )
        XCTAssertTrue(logs.contains { message in
            message.contains("stored CLI credential is at least as new")
                && message.contains("Keychain login")
        })
    }

    @MainActor
    func testApplyProfileCredentialsDeclinesWriteWhenKeychainTargetReadFails() throws {
        let runner = RecordingSecurityRunner()
        let store = retain(makeIsolatedProfileStore())
        let fileLogin = credentials(
            accessToken: "file", refreshToken: "file-refresh", expiresAtMillis: 1_000
        )
        let snapshot = credentials(
            accessToken: "stored", refreshToken: "stored-refresh", expiresAtMillis: 2_000
        )
        let profileId = try seedProfileForApply(
            cliCredentialsJSON: snapshot, in: store
        )
        let directory = try makeTemporaryCredentialsDirectory()
        try writeCredentialsFile(fileLogin, in: directory)
        var logs: [String] = []
        let service = makeService(
            runner: runner,
            profileStore: store,
            systemCredentialsReader: { fileLogin },
            keychainCredentialsReader: { _ in
                throw ClaudeCodeError.invalidJSON
            },
            credentialsFileDirectory: { _ in directory },
            credentialLogSink: { logs.append($0) }
        )

        try service.applyProfileCredentials(profileId)

        XCTAssertTrue(
            runner.invocations.isEmpty,
            "A failed Keychain freshness read must decline the write: \(runner.invocations)"
        )
        XCTAssertTrue(logs.contains { message in
            message.contains("Could not read this account's Keychain item")
                && message.contains("leaving the Keychain unchanged")
        })
    }

    @MainActor
    func testApplyProfileCredentialsDoesNotCopyFileLoginIntoKeychain() throws {
        let runner = RecordingSecurityRunner()
        let store = retain(makeIsolatedProfileStore())
        let snapshot = credentials(
            accessToken: "file", refreshToken: "file-refresh", expiresAtMillis: 2_000
        )
        let profileId = try seedProfileForApply(
            cliCredentialsJSON: snapshot, in: store
        )
        let directory = try makeTemporaryCredentialsDirectory()
        try writeCredentialsFile(snapshot, in: directory)
        var logs: [String] = []
        let service = makeService(
            runner: runner,
            profileStore: store,
            systemCredentialsReader: { snapshot },
            keychainCredentialsReader: { _ in nil },
            credentialsFileDirectory: { _ in directory },
            credentialLogSink: { logs.append($0) }
        )

        try service.applyProfileCredentials(profileId)

        XCTAssertTrue(runner.invocations.isEmpty)
        XCTAssertTrue(logs.contains { $0.contains("This login lives in Claude Code's credentials file") })
    }

    @MainActor
    func testApplyProfileCredentialsDoesNotCopyPartialFileLoginIntoKeychain() throws {
        let runner = RecordingSecurityRunner()
        let store = retain(makeIsolatedProfileStore())
        let snapshot = credentials(
            accessToken: "file", refreshToken: "file-refresh", expiresAtMillis: 2_000
        )
        let profileId = try seedProfileForApply(
            cliCredentialsJSON: snapshot, in: store
        )
        let directory = try makeTemporaryCredentialsDirectory()
        try writeCredentialsFile(
            #"{"claudeAiOauth":{"refreshToken":"file-refresh","expiresAt":1000}}"#,
            in: directory
        )
        let service = makeService(
            runner: runner,
            profileStore: store,
            systemCredentialsReader: { snapshot },
            keychainCredentialsReader: { _ in nil },
            credentialsFileDirectory: { _ in directory }
        )

        try service.applyProfileCredentials(profileId)

        XCTAssertTrue(runner.invocations.isEmpty)
    }

    @MainActor
    func testApplyProfileCredentialsWritesWhenFileIsDifferentAndKeychainIsOlder() throws {
        let runner = RecordingSecurityRunner()
        let store = retain(makeIsolatedProfileStore())
        let snapshot = credentials(
            accessToken: "stored", refreshToken: "stored-refresh", expiresAtMillis: 2_000
        )
        let profileId = try seedProfileForApply(
            cliCredentialsJSON: snapshot, in: store
        )
        let directory = try makeTemporaryCredentialsDirectory()
        try writeCredentialsFile(
            credentials(
                accessToken: "file", refreshToken: "file-refresh", expiresAtMillis: 3_000
            ),
            in: directory
        )
        let olderKeychain = credentials(
            accessToken: "keychain", refreshToken: "keychain-refresh", expiresAtMillis: 1_000
        )
        let service = makeService(
            runner: runner,
            profileStore: store,
            systemCredentialsReader: { olderKeychain },
            keychainCredentialsReader: { _ in olderKeychain },
            credentialsFileDirectory: { _ in directory }
        )

        try service.applyProfileCredentials(profileId)

        XCTAssertEqual(runner.verbs, ["add-generic-password"])
    }

    // MARK: - A rotation must not invalidate Claude Code's own login

    /// Anthropic rotates the refresh token on every use, so the moment this
    /// app renews a credential Claude Code is also holding, the CLI's copy is
    /// dead and the next `claude` command demands a fresh sign-in. These tests
    /// pin the repair — and, just as importantly, every case where the app
    /// must keep its hands off Claude Code's login entirely.

    private func credentials(
        accessToken: String = "abc",
        refreshToken: String,
        expiresAtMillis: Double
    ) -> String {
        #"{"claudeAiOauth":{"accessToken":"\#(accessToken)","refreshToken":"\#(refreshToken)","expiresAt":\#(expiresAtMillis)}}"#
    }

    private static let rotationAccountName = "rotation-test-account"

    /// The Keychain item Claude Code keeps that account's login in. Derived
    /// the same way production derives it, so a test asserting on the write
    /// is asserting it landed on the account's own item and not the shared
    /// one.
    ///
    /// Contract change: taken from the service's own configuration
    /// directory rather than the production account path, because the
    /// Keychain item is now named from the same directory the liveness check
    /// uses. Asking the service is also the only way to assert the thing
    /// that matters — that the item read and the item written are one item.
    private func rotationAccountServiceName(
        _ service: ClaudeCodeSyncService
    ) -> String {
        service.keychainServiceName(forAccountNamed: Self.rotationAccountName)
    }

    @MainActor
    private func seedProfileForRotation(in store: ProfileStore) throws -> UUID {
        let profile = Profile(
            name: "Rotation Test",
            hasCliAccount: true,
            cliAccountName: Self.rotationAccountName
        )
        try seedProfilesForTesting([profile], in: store)
        return profile.id
    }

    /// Scripts what `security find-generic-password` finds in Claude Code's
    /// own item, then lets the write that may follow succeed.
    private func securityRunner(holdingLiveLogin live: String?) -> RecordingSecurityRunner {
        let runner = RecordingSecurityRunner()
        let found = live.map {
            SecurityCommandResult(exitCode: 0, standardOutput: $0, standardError: "")
        } ?? SecurityCommandResult(exitCode: 44, standardOutput: "", standardError: "")
        // Two reads, then the write. The second read is the
        // compare-and-swap: under `.storage-write` the item is read again
        // and the write only proceeds if the refresh token stored there is
        // still the one that was posted to the server.
        runner.results = [
            found,
            found,
            SecurityCommandResult(exitCode: 0, standardOutput: "", standardError: "")
        ]
        return runner
    }

    private let rotationRenewed = #"{"claudeAiOauth":{"accessToken":"renewed","refreshToken":"rotated","expiresAt":2000.0}}"#

    @MainActor
    private func makeTemporaryCredentialsDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func credentialsFile(in directory: URL) -> URL {
        directory.appendingPathComponent(".credentials.json")
    }

    private func writeCredentialsFile(_ contents: String, in directory: URL) throws {
        let fileURL = credentialsFile(in: directory)
        try contents.data(using: .utf8)?.write(to: fileURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: fileURL.path
        )
    }

    private func fileMode(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
    }

    @MainActor
    private func makeFileRotationService(
        runner: RecordingSecurityRunner,
        store: ProfileStore,
        directory: URL,
        keychainLogin: String?,
        logs: ((String) -> Void)? = nil
    ) -> ClaudeCodeSyncService {
        makeService(
            runner: runner,
            profileStore: store,
            keychainCredentialsReader: { _ in keychainLogin },
            credentialsFileDirectory: { _ in directory },
            credentialLogSink: logs
        )
    }

    // MARK: - File-backed Claude Code login rotation

    @MainActor
    func testRotatedTokenInCredentialsFileIsRewrittenWithoutTouchingKeychain() throws {
        let directory = try makeTemporaryCredentialsDirectory()
        let spent = credentials(refreshToken: "shared", expiresAtMillis: 1_000)
        let mcpOAuth = #""mcpOAuth" : { "nested" : { "value" : "keep these exact bytes" } }"#
        let fileContents = #"{ \#(mcpOAuth), "claudeAiOauth" : { "accessToken" : "old", "refreshToken" : "shared", "expiresAt" : 1000 }, "unchanged" : true }"#
        try writeCredentialsFile(fileContents, in: directory)
        let runner = RecordingSecurityRunner()
        let store = retain(makeIsolatedProfileStore())
        let profileId = try seedProfileForRotation(in: store)
        var logs: [String] = []
        let service = makeFileRotationService(
            runner: runner,
            store: store,
            directory: directory,
            keychainLogin: nil,
            logs: { logs.append($0) }
        )

        try service.saveRefreshedCredentials(
            rotationRenewed, for: profileId, rotatedFrom: spent
        )

        let updated = try String(contentsOf: credentialsFile(in: directory))
        XCTAssertTrue(updated.contains(mcpOAuth), "mcpOAuth must retain its original bytes")
        XCTAssertTrue(updated.contains(#""refreshToken":"rotated""#))
        XCTAssertEqual(try fileMode(at: credentialsFile(in: directory)), 0o600)
        XCTAssertTrue(runner.invocations.isEmpty, "The file-only login must not write a Keychain item")
        XCTAssertTrue(logs.contains { $0.contains("Mirrored the rotated token back into Claude Code's credentials file") })
    }

    /// Ownership of a refresh-token family cannot require an access token:
    /// even a partial file login holds a spent refresh token that must be
    /// repaired in place rather than copied into a second store.
    @MainActor
    func testFileLoginWithNoAccessTokenStillReceivesRotatedRefreshToken() throws {
        let directory = try makeTemporaryCredentialsDirectory()
        let spent = credentials(refreshToken: "shared", expiresAtMillis: 1_000)
        try writeCredentialsFile(
            #"{"mcpOAuth":{"untouched":"yes"},"claudeAiOauth":{"refreshToken":"shared","expiresAt":1000}}"#,
            in: directory
        )
        let runner = RecordingSecurityRunner()
        let store = retain(makeIsolatedProfileStore())
        let profileId = try seedProfileForRotation(in: store)
        let service = makeFileRotationService(
            runner: runner, store: store, directory: directory, keychainLogin: nil
        )

        try service.saveRefreshedCredentials(
            rotationRenewed, for: profileId, rotatedFrom: spent
        )

        let updated = try String(contentsOf: credentialsFile(in: directory))
        XCTAssertTrue(updated.contains(#""refreshToken":"rotated""#))
        XCTAssertTrue(updated.contains(#""mcpOAuth":{"untouched":"yes"}"#))
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    @MainActor
    func testInvalidCredentialsFileLogsWarningAndIsNotRewritten() throws {
        let directory = try makeTemporaryCredentialsDirectory()
        let invalid = "{not json"
        try writeCredentialsFile(invalid, in: directory)
        let runner = RecordingSecurityRunner()
        let store = retain(makeIsolatedProfileStore())
        let profileId = try seedProfileForRotation(in: store)
        var logs: [String] = []
        let service = makeFileRotationService(
            runner: runner,
            store: store,
            directory: directory,
            keychainLogin: nil,
            logs: { logs.append($0) }
        )

        try service.saveRefreshedCredentials(
            rotationRenewed,
            for: profileId,
            rotatedFrom: credentials(refreshToken: "shared", expiresAtMillis: 1_000)
        )

        XCTAssertEqual(try String(contentsOf: credentialsFile(in: directory)), invalid)
        XCTAssertTrue(logs.contains { $0.contains("Could not parse Claude Code's credentials file") })
    }

    /// Contract change: an account with a Keychain item now has its file
    /// left alone, where this test used to require both stores to be
    /// updated.
    ///
    /// Claude Code reads the Keychain item and never looks at the file
    /// behind it — it writes the file only when the Keychain write fails
    /// outright, and deletes one when it writes the other. Keeping both
    /// current was this app inventing a state Claude Code does not produce:
    /// two copies of one login, each holding a refresh token that the other
    /// copy's owner can rotate away.
    @MainActor
    func testAFileIsLeftAloneWhenTheAccountKeepsItsLoginInTheKeychain() throws {
        let directory = try makeTemporaryCredentialsDirectory()
        let spent = credentials(refreshToken: "shared", expiresAtMillis: 1_000)
        try writeCredentialsFile(spent, in: directory)
        let runner = RecordingSecurityRunner()
        let store = retain(makeIsolatedProfileStore())
        let profileId = try seedProfileForRotation(in: store)
        let service = makeFileRotationService(
            runner: runner, store: store, directory: directory, keychainLogin: spent
        )

        try service.saveRefreshedCredentials(
            rotationRenewed, for: profileId, rotatedFrom: spent
        )

        XCTAssertEqual(runner.verbs, ["add-generic-password"])
        XCTAssertEqual(
            try String(contentsOf: credentialsFile(in: directory)),
            spent,
            "The Keychain is the store Claude Code reads; the file must not "
                + "become a second copy of the same login"
        )
    }

    @MainActor
    func testFileWithDifferentRefreshTokenIsLeftUntouchedWhenKeychainMatches() throws {
        let directory = try makeTemporaryCredentialsDirectory()
        let spent = credentials(refreshToken: "shared", expiresAtMillis: 1_000)
        let different = credentials(refreshToken: "different", expiresAtMillis: 1_000)
        try writeCredentialsFile(different, in: directory)
        let runner = RecordingSecurityRunner()
        let store = retain(makeIsolatedProfileStore())
        let profileId = try seedProfileForRotation(in: store)
        let service = makeFileRotationService(
            runner: runner, store: store, directory: directory, keychainLogin: spent
        )

        try service.saveRefreshedCredentials(
            rotationRenewed, for: profileId, rotatedFrom: spent
        )

        XCTAssertEqual(runner.verbs, ["add-generic-password"])
        XCTAssertEqual(try String(contentsOf: credentialsFile(in: directory)), different)
    }

    @MainActor
    func testRotationDoesNotCreateMissingCredentialsFile() throws {
        let directory = try makeTemporaryCredentialsDirectory()
        let spent = credentials(refreshToken: "shared", expiresAtMillis: 1_000)
        let runner = RecordingSecurityRunner()
        let store = retain(makeIsolatedProfileStore())
        let profileId = try seedProfileForRotation(in: store)
        let service = makeFileRotationService(
            runner: runner, store: store, directory: directory, keychainLogin: nil
        )

        try service.saveRefreshedCredentials(
            rotationRenewed, for: profileId, rotatedFrom: spent
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: credentialsFile(in: directory).path))
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    @MainActor
    func testRotationDoesNotRollBackNewerCredentialsFile() throws {
        let directory = try makeTemporaryCredentialsDirectory()
        let spent = credentials(refreshToken: "shared", expiresAtMillis: 1_000)
        let newer = credentials(refreshToken: "shared", expiresAtMillis: 3_000)
        try writeCredentialsFile(newer, in: directory)
        let runner = RecordingSecurityRunner()
        let store = retain(makeIsolatedProfileStore())
        let profileId = try seedProfileForRotation(in: store)
        var logs: [String] = []
        let service = makeFileRotationService(
            runner: runner,
            store: store,
            directory: directory,
            keychainLogin: nil,
            logs: { logs.append($0) }
        )

        try service.saveRefreshedCredentials(
            rotationRenewed, for: profileId, rotatedFrom: spent
        )

        XCTAssertEqual(try String(contentsOf: credentialsFile(in: directory)), newer)
        XCTAssertTrue(logs.contains { $0.contains("credentials file") && $0.contains("at least as new") })
    }

    /// The fix. The app spent the refresh token Claude Code was relying on,
    /// so the rotated one has to be written back into Claude Code's own
    /// Keychain item or that account is signed out without ever being told
    /// why.
    @MainActor
    func testRotatedTokenIsWrittenBackIntoClaudeCodesOwnLogin() throws {
        let spent = credentials(refreshToken: "shared", expiresAtMillis: 1_000)
        let runner = securityRunner(holdingLiveLogin: spent)
        let store = retain(makeIsolatedProfileStore())
        let profileId = try seedProfileForRotation(in: store)
        let service = makeService(runner: runner, profileStore: store)

        try service.saveRefreshedCredentials(
            rotationRenewed,
            for: profileId,
            rotatedFrom: spent
        )

        // Contract change: a second read sits between the ownership check
        // and the write. That is the compare-and-swap, taken under Claude
        // Code's own `.storage-write` lock — without it, two rotations
        // racing each other both write, and the loser's token is the one
        // left in the store.
        XCTAssertEqual(
            runner.verbs,
            [
                "find-generic-password",
                "find-generic-password",
                "add-generic-password"
            ],
            "The rotated token must be written back into Claude Code's login"
        )
        let read = try XCTUnwrap(runner.invocations.first)
        let write = try XCTUnwrap(runner.invocations.last)
        XCTAssertTrue(
            write.contains(rotationRenewed),
            "Claude Code must receive the renewed credential: \(write)"
        )
        XCTAssertTrue(
            write.contains(rotationAccountServiceName(service)),
            "The write must land on this account's own Keychain item, not "
                + "the shared one: \(write)"
        )
        // The whole guard is worthless if the item that was checked is not
        // the item that gets overwritten.
        XCTAssertTrue(
            read.contains(rotationAccountServiceName(service)),
            "Ownership must be checked against the very item the write "
                + "replaces: \(read)"
        )
    }

    /// Claude Code is on a different login — signed in again since, or never
    /// sharing this credential at all. Nothing it holds was invalidated by
    /// this renewal, so its login is not ours to rewrite.
    @MainActor
    func testClaudeCodeIsLeftAloneWhenItHoldsADifferentLogin() throws {
        let runner = securityRunner(
            holdingLiveLogin: credentials(
                refreshToken: "claude-codes-own",
                expiresAtMillis: 1_500
            )
        )
        let store = retain(makeIsolatedProfileStore())
        let profileId = try seedProfileForRotation(in: store)
        let service = makeService(runner: runner, profileStore: store)

        try service.saveRefreshedCredentials(
            rotationRenewed,
            for: profileId,
            rotatedFrom: credentials(
                refreshToken: "ours",
                expiresAtMillis: 1_000
            )
        )

        XCTAssertEqual(
            runner.verbs,
            ["find-generic-password"],
            "A login Claude Code did not share must never be overwritten: "
                + "\(runner.invocations)"
        )
    }

    /// Claude Code has no login stored for this account, so this renewal
    /// invalidated nothing and there is no item to replace.
    @MainActor
    func testWriteBackIsSkippedWhenClaudeCodeHasNoLoginStored() throws {
        let runner = securityRunner(holdingLiveLogin: nil)
        let store = retain(makeIsolatedProfileStore())
        let profileId = try seedProfileForRotation(in: store)
        let service = makeService(runner: runner, profileStore: store)

        try service.saveRefreshedCredentials(
            rotationRenewed,
            for: profileId,
            rotatedFrom: credentials(
                refreshToken: "shared",
                expiresAtMillis: 1_000
            )
        )

        XCTAssertEqual(
            runner.verbs,
            ["find-generic-password"],
            "With no item to replace there is nothing to repair: "
                + "\(runner.invocations)"
        )
    }

    /// No refresh token was spent — this is the adoption path, which copies
    /// Claude Code's own live login as-is. There is nothing to mirror back,
    /// and writing anyway would be a pointless rewrite of a working login.
    @MainActor
    func testNonRotatingSaveNeverTouchesClaudeCodesLogin() throws {
        let live = credentials(refreshToken: "live", expiresAtMillis: 1_000)
        let runner = securityRunner(holdingLiveLogin: live)
        let store = retain(makeIsolatedProfileStore())
        let profileId = try seedProfileForRotation(in: store)
        let service = makeService(runner: runner, profileStore: store)

        try service.saveRefreshedCredentials(live, for: profileId)

        XCTAssertTrue(
            runner.invocations.isEmpty,
            "A save that spent no refresh token must not read or write "
                + "Claude Code's login: \(runner.invocations)"
        )
    }

    /// The same fail-closed rule `applyProfileCredentials` obeys: freshness
    /// that cannot be established is not freshness. Here Claude Code's login
    /// carries no `expiresAt` at all, so there is no way to prove the write
    /// would not roll it backwards — and it must be declined.
    @MainActor
    func testWriteBackIsDeclinedWhenFreshnessCannotBeEstablished() throws {
        let runner = securityRunner(
            holdingLiveLogin:
                #"{"claudeAiOauth":{"accessToken":"live","refreshToken":"shared"}}"#
        )
        let store = retain(makeIsolatedProfileStore())
        let profileId = try seedProfileForRotation(in: store)
        let service = makeService(runner: runner, profileStore: store)

        try service.saveRefreshedCredentials(
            rotationRenewed,
            for: profileId,
            rotatedFrom: credentials(
                refreshToken: "shared",
                expiresAtMillis: 1_000
            )
        )

        XCTAssertEqual(
            runner.verbs,
            ["find-generic-password"],
            "Unprovable freshness must decline the write, not permit it: "
                + "\(runner.invocations)"
        )
    }

    /// Claude Code's login is demonstrably newer than what we would write.
    /// Writing would sign that account backwards, which is the one outcome
    /// worse than leaving it alone.
    @MainActor
    func testWriteBackNeverRollsClaudeCodeBackwards() throws {
        let runner = securityRunner(
            holdingLiveLogin: credentials(
                accessToken: "live",
                refreshToken: "shared",
                expiresAtMillis: 9_000
            )
        )
        let store = retain(makeIsolatedProfileStore())
        let profileId = try seedProfileForRotation(in: store)
        let service = makeService(runner: runner, profileStore: store)

        try service.saveRefreshedCredentials(
            rotationRenewed,
            for: profileId,
            rotatedFrom: credentials(
                refreshToken: "shared",
                expiresAtMillis: 1_000
            )
        )

        XCTAssertEqual(
            runner.verbs,
            ["find-generic-password"],
            "A newer Claude Code login must never be rolled back: "
                + "\(runner.invocations)"
        )
    }

    /// A profile with no linked Claude Code account has no CLI login to keep
    /// in sync, and the unscoped write would land on the shared item — which
    /// on a multi-account machine belongs to somebody else.
    @MainActor
    func testWriteBackIsSkippedForAProfileWithNoLinkedAccount() throws {
        let spent = credentials(refreshToken: "shared", expiresAtMillis: 1_000)
        let runner = securityRunner(holdingLiveLogin: spent)
        let store = retain(makeIsolatedProfileStore())
        let profile = Profile(name: "No CLI Account")
        try seedProfilesForTesting([profile], in: store)
        let service = makeService(runner: runner, profileStore: store)

        try service.saveRefreshedCredentials(
            rotationRenewed,
            for: profile.id,
            rotatedFrom: spent
        )

        XCTAssertTrue(
            runner.invocations.isEmpty,
            "With no linked account there is no CLI login to repair: "
                + "\(runner.invocations)"
        )
    }

    // MARK: - Reading the login the way Claude Code reads it

    /// A staged configuration directory with a `.credentials.json` in it.
    private func stagedConfigurationDirectory(
        containing fileLogin: String?
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        if let fileLogin {
            try Data(fileLogin.utf8).write(
                to: directory.appendingPathComponent(".credentials.json")
            )
        }
        return directory
    }

    private static let keychainLogin =
        #"{"claudeAiOauth":{"accessToken":"from-keychain","refreshToken":"r1","expiresAt":99999999999999}}"#
    private static let fileLogin =
        #"{"claudeAiOauth":{"accessToken":"from-file","refreshToken":"r2","expiresAt":99999999999999}}"#
    /// What Claude Code leaves behind when it retires a dead refresh token.
    private static let blankedKeychainItem =
        #"{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0,"subscriptionType":"max"}}"#

    /// Claude Code reads its Keychain item first and consults the file for
    /// exactly one reason: no item. A file sitting behind a working item is
    /// never read, however fresh it looks.
    @MainActor
    func testAKeychainLoginWinsAndTheFileIsNeverRead() throws {
        let runner = RecordingSecurityRunner()
        runner.results = [
            SecurityCommandResult(
                exitCode: 0,
                standardOutput: Self.keychainLogin,
                standardError: ""
            )
        ]
        let directory = try stagedConfigurationDirectory(
            containing: Self.fileLogin
        )
        let service = makeService(
            runner: runner,
            profileStore: retain(makeIsolatedProfileStore()),
            credentialsFileDirectory: { _ in directory }
        )

        XCTAssertEqual(
            try service.readSystemCredentials(),
            Self.keychainLogin
        )
    }

    /// The regression that made this app and the CLI look at two different
    /// token chains for one account: a blank Keychain item means the account
    /// is signed out, and the file behind it must not be resurrected.
    @MainActor
    func testABlankKeychainItemIsLoggedOutAndTheFileIsNotConsulted() throws {
        let runner = RecordingSecurityRunner()
        runner.results = [
            SecurityCommandResult(
                exitCode: 0,
                standardOutput: Self.blankedKeychainItem,
                standardError: ""
            )
        ]
        let directory = try stagedConfigurationDirectory(
            containing: Self.fileLogin
        )
        let service = makeService(
            runner: runner,
            profileStore: retain(makeIsolatedProfileStore()),
            credentialsFileDirectory: { _ in directory }
        )

        XCTAssertNil(try service.readSystemCredentials())
    }

    /// Exit 44 is `security` saying the item is not there, and it is the one
    /// condition that sends Claude Code — and now this app — to the file.
    @MainActor
    func testOnlyAMissingKeychainItemSendsTheReadToTheFile() throws {
        let runner = RecordingSecurityRunner()
        runner.results = [
            SecurityCommandResult(exitCode: 44, standardOutput: "", standardError: "")
        ]
        let directory = try stagedConfigurationDirectory(
            containing: Self.fileLogin
        )
        let service = makeService(
            runner: runner,
            profileStore: retain(makeIsolatedProfileStore()),
            credentialsFileDirectory: { _ in directory }
        )

        XCTAssertEqual(try service.readSystemCredentials(), Self.fileLogin)
    }

    /// No item and no file is "not signed in", not an error.
    @MainActor
    func testNoKeychainItemAndNoFileReadsAsNoLogin() throws {
        let runner = RecordingSecurityRunner()
        runner.results = [
            SecurityCommandResult(exitCode: 44, standardOutput: "", standardError: "")
        ]
        let directory = try stagedConfigurationDirectory(containing: nil)
        let service = makeService(
            runner: runner,
            profileStore: retain(makeIsolatedProfileStore()),
            credentialsFileDirectory: { _ in directory }
        )

        XCTAssertNil(try service.readSystemCredentials())
    }

    /// A Keychain that refuses the read is a failure, not an absence. The
    /// old chain could quietly answer with an expired file login here, which
    /// is how the app ended up holding a different token chain from the CLI.
    @MainActor
    func testARefusedKeychainReadThrowsRatherThanFallingBackToTheFile() throws {
        let runner = RecordingSecurityRunner()
        runner.results = [
            SecurityCommandResult(
                exitCode: 36,
                standardOutput: "",
                standardError: "security: User interaction is not allowed."
            )
        ]
        let directory = try stagedConfigurationDirectory(
            containing: Self.fileLogin
        )
        let service = makeService(
            runner: runner,
            profileStore: retain(makeIsolatedProfileStore()),
            credentialsFileDirectory: { _ in directory }
        )

        XCTAssertThrowsError(try service.readSystemCredentials())
    }

    // MARK: - The one write chokepoint

    @MainActor
    private func makeChokepointService(
        runner: RecordingSecurityRunner,
        directory: URL,
        live: Bool,
        sink: @escaping (String) -> Void = { _ in }
    ) -> ClaudeCodeSyncService {
        let detector = live
            ? LiveClaudeProcessDetector(
                source: StubRunningProcessSource(processes: [
                    .claude(configurationDirectory: directory.path)
                ]),
                defaultConfigurationDirectory: "/tmp/no-such-claude-home",
                log: { _ in }
            )
            : LiveClaudeProcessDetector.stubbedIdle()
        return makeService(
            runner: runner,
            profileStore: retain(makeIsolatedProfileStore()),
            credentialsFileDirectory: { _ in directory },
            credentialLogSink: sink,
            liveProcessDetector: detector
        )
    }

    /// The rule the whole fix exists for. A `claude` process holds its
    /// account's refresh token in memory; Anthropic rotates that token on
    /// every use, so writing — or spending — it is what leaves that process
    /// asking the person to sign in to an account they never left.
    @MainActor
    func testAWriteIsRefusedWhileAClaudeProcessIsUsingTheAccount() throws {
        let runner = RecordingSecurityRunner()
        let directory = try stagedConfigurationDirectory(containing: nil)
        var logged: [String] = []
        let service = makeChokepointService(
            runner: runner,
            directory: directory,
            live: true,
            sink: { logged.append($0) }
        )

        XCTAssertFalse(
            try service.commitClaudeCodeStoreWrite(
                Self.keychainLogin,
                forAccountNamed: "work",
                store: .keychain,
                purpose: "a test"
            )
        )
        XCTAssertTrue(
            runner.invocations.isEmpty,
            "Nothing may reach `security` for a live account: \(runner.invocations)"
        )
        // R6: the refusal says which account, that it is in use, and why.
        let line = try XCTUnwrap(logged.first)
        XCTAssertTrue(line.contains("work"), line)
        XCTAssertTrue(line.contains("in use by a running claude"), line)
        XCTAssertTrue(line.contains("refused"), line)
        XCTAssertFalse(
            line.contains("from-keychain"),
            "No token value may reach a log line: \(line)"
        )
    }

    /// An idle account is written, and the log says so in the same shape.
    @MainActor
    func testAnIdleAccountIsWrittenAndTheDecisionIsLogged() throws {
        let runner = RecordingSecurityRunner()
        let directory = try stagedConfigurationDirectory(containing: nil)
        var logged: [String] = []
        let service = makeChokepointService(
            runner: runner,
            directory: directory,
            live: false,
            sink: { logged.append($0) }
        )

        XCTAssertTrue(
            try service.commitClaudeCodeStoreWrite(
                Self.keychainLogin,
                forAccountNamed: "work",
                store: .keychain,
                purpose: "a test"
            )
        )
        XCTAssertEqual(runner.verbs, ["add-generic-password"])
        let line = try XCTUnwrap(logged.first)
        XCTAssertTrue(line.contains("idle"), line)
        XCTAssertTrue(line.contains("wrote it"), line)
    }

    /// Claude Code reads the Keychain item and never looks at the file
    /// behind it. Writing both would leave two copies of one login that
    /// nothing reconciles and either side can rotate.
    @MainActor
    func testAFileWriteIsRefusedWhenTheAccountHasAKeychainItem() throws {
        let runner = RecordingSecurityRunner()
        runner.results = [
            SecurityCommandResult(
                exitCode: 0,
                standardOutput: Self.keychainLogin,
                standardError: ""
            )
        ]
        let directory = try stagedConfigurationDirectory(
            containing: Self.fileLogin
        )
        var logged: [String] = []
        let service = makeChokepointService(
            runner: runner,
            directory: directory,
            live: false,
            sink: { logged.append($0) }
        )

        XCTAssertFalse(
            try service.commitClaudeCodeStoreWrite(
                Self.keychainLogin,
                forAccountNamed: "work",
                store: .credentialsFile,
                purpose: "a test",
                expectedRefreshToken: "r2"
            )
        )
        let contents = try String(
            contentsOf: directory.appendingPathComponent(".credentials.json"),
            encoding: .utf8
        )
        XCTAssertEqual(contents, Self.fileLogin, "The file must be untouched")
        XCTAssertTrue(
            try XCTUnwrap(logged.first).contains("refused"),
            logged.description
        )
    }

    /// Installing a plaintext credential store on a machine that chose not to
    /// have one is not this app's decision to make.
    @MainActor
    func testAMissingCredentialsFileIsNeverCreated() throws {
        let runner = RecordingSecurityRunner()
        runner.results = [
            SecurityCommandResult(exitCode: 44, standardOutput: "", standardError: "")
        ]
        let directory = try stagedConfigurationDirectory(containing: nil)
        let service = makeChokepointService(
            runner: runner,
            directory: directory,
            live: false
        )

        XCTAssertFalse(
            try service.commitClaudeCodeStoreWrite(
                Self.keychainLogin,
                forAccountNamed: "work",
                store: .credentialsFile,
                purpose: "a test",
                expectedRefreshToken: "r2"
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(
                    ".credentials.json"
                ).path
            )
        )
    }

    /// The compare-and-swap survives the move behind the chokepoint: a file
    /// that no longer holds the refresh token this write was based on
    /// belongs to whoever got there first.
    @MainActor
    func testAFileWriteIsAbandonedWhenItsRefreshTokenHasMovedOn() throws {
        let runner = RecordingSecurityRunner()
        runner.results = [
            SecurityCommandResult(exitCode: 44, standardOutput: "", standardError: "")
        ]
        let directory = try stagedConfigurationDirectory(
            containing: Self.fileLogin
        )
        let service = makeChokepointService(
            runner: runner,
            directory: directory,
            live: false
        )

        XCTAssertFalse(
            try service.commitClaudeCodeStoreWrite(
                Self.keychainLogin,
                forAccountNamed: "work",
                store: .credentialsFile,
                purpose: "a test",
                expectedRefreshToken: "some-other-token"
            )
        )
        let contents = try String(
            contentsOf: directory.appendingPathComponent(".credentials.json"),
            encoding: .utf8
        )
        XCTAssertEqual(contents, Self.fileLogin)
    }

    // MARK: - Claude Code's refresh timing

    /// Claude Code refreshes five minutes before expiry. Waiting for the
    /// expiry itself guarantees a window where every request fails while a
    /// renewal is still in flight.
    @MainActor
    func testATokenWithinFiveMinutesOfExpiryIsDueForRefresh() {
        let service = makeService(runner: RecordingSecurityRunner())
        // A realistic epoch: `extractTokenExpiry` reads values above 1e12
        // as milliseconds, which is the shape Claude Code actually stores.
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        func credential(minutesFromNow: Double) -> String {
            let expiry = now.addingTimeInterval(minutesFromNow * 60)
            return credentials(
                expiresAtMillis: expiry.timeIntervalSince1970 * 1000
            )
        }

        XCTAssertFalse(
            service.isTokenDueForRefresh(credential(minutesFromNow: 10), now: now)
        )
        XCTAssertTrue(
            service.isTokenDueForRefresh(credential(minutesFromNow: 4), now: now)
        )
        XCTAssertTrue(
            service.isTokenDueForRefresh(credential(minutesFromNow: -1), now: now)
        )
        // Being due is not being expired: a token with four minutes left
        // still authenticates, which is what a live account falls back on.
        XCTAssertFalse(
            ClaudeCodeSyncService.shared.isTokenExpired(
                credential(minutesFromNow: 4)
            )
        )
    }

    // MARK: - Compare-and-swap on the Keychain write

    /// A refresh token is single-use. If the item no longer holds the one
    /// that was posted to the server, somebody else's rotation landed first
    /// and theirs is the live pair — writing ours would install a token the
    /// server has already retired, which is this whole change's failure with
    /// the roles reversed.
    @MainActor
    func testARotationIsAbandonedWhenAnotherProcessGotThereFirst() throws {
        let runner = RecordingSecurityRunner()
        runner.results = [
            SecurityCommandResult(
                exitCode: 0,
                standardOutput:
                    #"{"claudeAiOauth":{"accessToken":"newer","refreshToken":"someone-elses","expiresAt":99999999999999}}"#,
                standardError: ""
            )
        ]
        let directory = try stagedConfigurationDirectory(containing: nil)
        var logged: [String] = []
        let service = makeChokepointService(
            runner: runner,
            directory: directory,
            live: false,
            sink: { logged.append($0) }
        )

        XCTAssertFalse(
            try service.commitClaudeCodeStoreWrite(
                Self.keychainLogin,
                forAccountNamed: "work",
                store: .keychain,
                purpose: "a test",
                expectedRefreshToken: "the-one-we-posted"
            )
        )
        XCTAssertFalse(
            runner.verbs.contains("add-generic-password"),
            "Nothing may be written once the stored token has moved on: "
                + "\(runner.verbs)"
        )
        XCTAssertTrue(
            try XCTUnwrap(logged.first).contains("rotated this login first"),
            logged.description
        )
    }

    /// The ordinary case: the item still holds the token that was posted, so
    /// the rotated pair goes in.
    @MainActor
    func testARotationIsWrittenWhenTheStoredTokenIsStillOurs() throws {
        let runner = RecordingSecurityRunner()
        runner.results = [
            SecurityCommandResult(
                exitCode: 0,
                standardOutput:
                    #"{"claudeAiOauth":{"accessToken":"old","refreshToken":"the-one-we-posted","expiresAt":1000}}"#,
                standardError: ""
            ),
            SecurityCommandResult(exitCode: 0, standardOutput: "", standardError: "")
        ]
        let directory = try stagedConfigurationDirectory(containing: nil)
        let service = makeChokepointService(
            runner: runner,
            directory: directory,
            live: false
        )

        XCTAssertTrue(
            try service.commitClaudeCodeStoreWrite(
                Self.keychainLogin,
                forAccountNamed: "work",
                store: .keychain,
                purpose: "a test",
                expectedRefreshToken: "the-one-we-posted"
            )
        )
        XCTAssertEqual(
            runner.verbs,
            ["find-generic-password", "add-generic-password"],
            "The item is re-read under the lock, then written"
        )
    }

    /// Claude Code blanks the tokens in place when it retires a dead refresh
    /// token. Refusing to write over that would leave the account signed out
    /// with a perfectly good replacement pair in hand — so a blank token is
    /// writable, exactly as it is for Claude Code.
    @MainActor
    func testARotationIsWrittenOverABlankedOutItem() throws {
        let runner = RecordingSecurityRunner()
        runner.results = [
            SecurityCommandResult(
                exitCode: 0,
                standardOutput: Self.blankedKeychainItem,
                standardError: ""
            ),
            SecurityCommandResult(exitCode: 0, standardOutput: "", standardError: "")
        ]
        let directory = try stagedConfigurationDirectory(containing: nil)
        let service = makeChokepointService(
            runner: runner,
            directory: directory,
            live: false
        )

        XCTAssertTrue(
            try service.commitClaudeCodeStoreWrite(
                Self.keychainLogin,
                forAccountNamed: "work",
                store: .keychain,
                purpose: "a test",
                expectedRefreshToken: "the-one-we-posted"
            )
        )
        XCTAssertTrue(runner.verbs.contains("add-generic-password"))
    }

    /// A rotation has nothing to swap when there is no item, so it is
    /// abandoned. Activating a profile carries no posted token and is a
    /// different question — that one may create the item.
    @MainActor
    func testARotationIsAbandonedWhenTheItemHasGoneButActivationStillWrites()
        throws
    {
        let rotationRunner = RecordingSecurityRunner()
        rotationRunner.results = [
            SecurityCommandResult(exitCode: 44, standardOutput: "", standardError: "")
        ]
        let directory = try stagedConfigurationDirectory(containing: nil)
        let rotation = makeChokepointService(
            runner: rotationRunner,
            directory: directory,
            live: false
        )
        XCTAssertFalse(
            try rotation.commitClaudeCodeStoreWrite(
                Self.keychainLogin,
                forAccountNamed: "work",
                store: .keychain,
                purpose: "a test",
                expectedRefreshToken: "the-one-we-posted"
            )
        )
        XCTAssertFalse(rotationRunner.verbs.contains("add-generic-password"))

        let activationRunner = RecordingSecurityRunner()
        let activation = makeChokepointService(
            runner: activationRunner,
            directory: try stagedConfigurationDirectory(containing: nil),
            live: false
        )
        XCTAssertTrue(
            try activation.commitClaudeCodeStoreWrite(
                Self.keychainLogin,
                forAccountNamed: "work",
                store: .keychain,
                purpose: "a test"
            )
        )
        XCTAssertEqual(activationRunner.verbs, ["add-generic-password"])
    }

    /// The write happens under Claude Code's own store-write lock, so a
    /// write of theirs that is already in progress is not landed on.
    @MainActor
    func testAWriteWaitsForNobodyWhenTheStoreWriteLockIsHeld() throws {
        let runner = RecordingSecurityRunner()
        let directory = try stagedConfigurationDirectory(containing: nil)
        // Stand in for Claude Code holding it: a fresh lock directory that
        // nothing here will release. The path is written out rather than
        // taken from the constant on purpose — building it from the same
        // constant the code uses is what let this test pass while the real
        // directory was one suffix away from Claude Code's and excluded
        // nobody.
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(".storage-write.lock"),
            withIntermediateDirectories: false
        )
        var logged: [String] = []
        let service = makeChokepointService(
            runner: runner,
            directory: directory,
            live: false,
            sink: { logged.append($0) }
        )

        XCTAssertFalse(
            try service.commitClaudeCodeStoreWrite(
                Self.keychainLogin,
                forAccountNamed: "work",
                store: .keychain,
                purpose: "a test"
            )
        )
        XCTAssertTrue(
            runner.invocations.isEmpty,
            "Nothing may reach `security` while Claude Code is writing: "
                + "\(runner.invocations)"
        )
        XCTAssertTrue(
            try XCTUnwrap(logged.first).contains("store-write lock"),
            logged.description
        )
    }

    /// The lock is taken and given back, not leaked. A lock directory left
    /// behind would block Claude Code's own writes for fifteen seconds every
    /// time this app wrote anything.
    @MainActor
    func testTheStoreWriteLockIsReleasedAfterTheWrite() throws {
        let runner = RecordingSecurityRunner()
        let directory = try stagedConfigurationDirectory(containing: nil)
        let service = makeChokepointService(
            runner: runner,
            directory: directory,
            live: false
        )

        XCTAssertTrue(
            try service.commitClaudeCodeStoreWrite(
                Self.keychainLogin,
                forAccountNamed: "work",
                store: .keychain,
                purpose: "a test"
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(
                    ".storage-write.lock"
                ).path
            )
        )
    }

    // MARK: - Taking Claude Code's refresh lock

    @MainActor
    func testTheRefreshLockIsClaudeCodesOwnLockPathAndThresholds() throws {
        let directory = try stagedConfigurationDirectory(containing: nil)
        let service = makeChokepointService(
            runner: RecordingSecurityRunner(),
            directory: directory,
            live: false
        )

        let lock = try service.acquireRefreshLock(forAccountNamed: "work")
        defer { lock.release() }
        XCTAssertEqual(
            lock.url.path,
            directory.appendingPathComponent(".oauth_refresh.lock").path
        )
        XCTAssertEqual(ClaudeCodeSyncService.refreshLockStaleAfter, 60)
        XCTAssertEqual(ClaudeCodeSyncService.refreshLockRefreshEvery, 5)
        XCTAssertEqual(ClaudeCodeSyncService.storageWriteLockStaleAfter, 15)

        XCTAssertThrowsError(
            try service.acquireRefreshLock(forAccountNamed: "work")
        ) { error in
            XCTAssertEqual(
                error as? ClaudeCodeStoreLock.AcquisitionFailure,
                .heldByAnotherProcess
            )
        }
    }

    /// The check Claude Code makes immediately before it posts a refresh: has
    /// the store already moved past the token I was about to spend?
    @MainActor
    func testTheStoreIsSeenToHaveMovedOnWhenItsAccessTokenDiffers() throws {
        let directory = try stagedConfigurationDirectory(containing: nil)

        func service(
            holding stored: String
        ) -> ClaudeCodeSyncService {
            let runner = RecordingSecurityRunner()
            runner.results = [
                SecurityCommandResult(
                    exitCode: 0,
                    standardOutput: stored,
                    standardError: ""
                )
            ]
            return makeChokepointService(
                runner: runner,
                directory: directory,
                live: false
            )
        }

        XCTAssertEqual(
            service(holding: Self.fileLogin).compareStore(
                with: Self.keychainLogin,
                forAccountNamed: "work"
            ),
            .movedOn
        )
        XCTAssertEqual(
            service(holding: Self.keychainLogin).compareStore(
                with: Self.keychainLogin,
                forAccountNamed: "work"
            ),
            .unchanged
        )
    }

    // MARK: - Review fixes

    /// B1. Claude Code locks `.storage-write` WITHOUT passing
    /// `proper-lockfile`'s `lockfilePath`, and that library appends `.lock`
    /// to whatever path it is handed — `return r.lockfilePath || `${e}.lock``,
    /// read out of the 2.1.270 binary. So its directory is
    /// `.storage-write.lock`, and a lock one suffix away from it excluded
    /// nobody while looking exactly as though it did.
    @MainActor
    func testTheStoreWriteLockIsTheDirectoryClaudeCodeActuallyTakes() throws {
        XCTAssertEqual(
            ClaudeCodeSyncService.storageWriteLockName,
            ".storage-write.lock"
        )
        // The refresh lock is the other way round: Claude Code passes
        // `lockfilePath` for that one, so no suffix is appended.
        XCTAssertEqual(
            ClaudeCodeSyncService.refreshLockName,
            ".oauth_refresh.lock"
        )

        let runner = RecordingSecurityRunner()
        let directory = try stagedConfigurationDirectory(containing: nil)
        let service = makeChokepointService(
            runner: runner,
            directory: directory,
            live: false
        )
        // Stand in for Claude Code holding its own store-write lock.
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(".storage-write.lock"),
            withIntermediateDirectories: false
        )

        XCTAssertFalse(
            try service.commitClaudeCodeStoreWrite(
                Self.keychainLogin,
                forAccountNamed: "work",
                store: .keychain,
                purpose: "a test"
            )
        )
        XCTAssertTrue(
            runner.invocations.isEmpty,
            "Nothing may reach `security` while Claude Code is writing"
        )
    }

    /// B2. The liveness answer can be five seconds old and the token exchange
    /// runs for up to thirty, so a `claude` that starts mid-flight used to
    /// turn the mirror-back into a refusal — leaving that process holding the
    /// exact token the server had just retired, with nothing to try again
    /// later. A write carrying a posted refresh token is a repair of a token
    /// this app already spent, and the compare-and-swap is what makes it
    /// safe: it can only ever replace that one token.
    @MainActor
    func testARepairOfASpentTokenIsWrittenEvenForALiveAccount() throws {
        let runner = RecordingSecurityRunner()
        runner.results = [
            SecurityCommandResult(
                exitCode: 0,
                standardOutput:
                    #"{"claudeAiOauth":{"accessToken":"old","refreshToken":"the-one-we-posted","expiresAt":1000}}"#,
                standardError: ""
            ),
            SecurityCommandResult(exitCode: 0, standardOutput: "", standardError: "")
        ]
        let directory = try stagedConfigurationDirectory(containing: nil)
        var logged: [String] = []
        let service = makeChokepointService(
            runner: runner,
            directory: directory,
            live: true,
            sink: { logged.append($0) }
        )

        XCTAssertTrue(
            try service.commitClaudeCodeStoreWrite(
                Self.keychainLogin,
                forAccountNamed: "work",
                store: .keychain,
                purpose: "mirroring back a token this app rotated",
                expectedRefreshToken: "the-one-we-posted"
            )
        )
        XCTAssertTrue(runner.verbs.contains("add-generic-password"))
        // The log still says the account is in use — the write happened
        // anyway, and the log has to show that rather than hide it.
        let line = try XCTUnwrap(logged.first)
        XCTAssertTrue(line.contains("in use by a running claude"), line)
        XCTAssertTrue(line.contains("wrote it"), line)
    }

    /// And the exception is exactly that: a write with nothing to swap — a
    /// profile activation, a re-sync — is still refused for a live account.
    @MainActor
    func testAWriteWithNothingToSwapIsStillRefusedForALiveAccount() throws {
        let runner = RecordingSecurityRunner()
        let directory = try stagedConfigurationDirectory(containing: nil)
        let service = makeChokepointService(
            runner: runner,
            directory: directory,
            live: true
        )

        XCTAssertFalse(
            try service.commitClaudeCodeStoreWrite(
                Self.keychainLogin,
                forAccountNamed: "work",
                store: .keychain,
                purpose: "activating a profile"
            )
        )
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    /// A repair that arrives after somebody else's rotation is still
    /// abandoned, live account or not. This is what makes B2's exception
    /// safe rather than a hole in it.
    @MainActor
    func testARepairIsStillAbandonedWhenTheTokenHasMovedOn() throws {
        let runner = RecordingSecurityRunner()
        runner.results = [
            SecurityCommandResult(
                exitCode: 0,
                standardOutput:
                    #"{"claudeAiOauth":{"accessToken":"newer","refreshToken":"someone-elses","expiresAt":99999999999999}}"#,
                standardError: ""
            )
        ]
        let directory = try stagedConfigurationDirectory(containing: nil)
        let service = makeChokepointService(
            runner: runner,
            directory: directory,
            live: true
        )

        XCTAssertFalse(
            try service.commitClaudeCodeStoreWrite(
                Self.keychainLogin,
                forAccountNamed: "work",
                store: .keychain,
                purpose: "mirroring back a token this app rotated",
                expectedRefreshToken: "the-one-we-posted"
            )
        )
        XCTAssertFalse(runner.verbs.contains("add-generic-password"))
    }

    /// S3. A store that cannot be read is not permission to spend. Answering
    /// "unchanged" there spent the token and then hit the compare-and-swap,
    /// which fails closed on that same unreadable item — so the token was
    /// gone and the mirror-back refused, which is the original bug by
    /// another road.
    @MainActor
    func testAnUnreadableStoreIsItsOwnAnswerRatherThanPermissionToSpend()
        throws
    {
        let runner = RecordingSecurityRunner()
        runner.results = [
            SecurityCommandResult(
                exitCode: 36,
                standardOutput: "",
                standardError: "security: User interaction is not allowed."
            )
        ]
        let directory = try stagedConfigurationDirectory(containing: nil)
        let service = makeChokepointService(
            runner: runner,
            directory: directory,
            live: false
        )

        XCTAssertEqual(
            service.compareStore(
                with: Self.keychainLogin,
                forAccountNamed: "work"
            ),
            .unreadable
        )
    }

    /// An account with no Keychain item is a file-backed account, which is a
    /// legitimate state and must still permit a refresh.
    @MainActor
    func testAnAbsentKeychainItemStillPermitsARefresh() throws {
        let runner = RecordingSecurityRunner()
        runner.results = [
            SecurityCommandResult(exitCode: 44, standardOutput: "", standardError: "")
        ]
        let directory = try stagedConfigurationDirectory(containing: nil)
        let service = makeChokepointService(
            runner: runner,
            directory: directory,
            live: false
        )

        XCTAssertEqual(
            service.compareStore(
                with: Self.keychainLogin,
                forAccountNamed: "work"
            ),
            .unchanged
        )
    }

    /// S5. The item a write lands on and the directory whose liveness was
    /// checked must be the same account. For a profile with no linked
    /// account name they were not: liveness was checked against `~/.claude`
    /// and the write went to whichever hashed item a prefix search returned
    /// first — some other account's.
    @MainActor
    func testAnUnnamedAccountResolvesToTheOneItemClaudeCodeUses() throws {
        let service = makeService(runner: RecordingSecurityRunner())

        // With no `CLAUDE_CONFIG_DIR` in this process's environment, Claude
        // Code drops the hash suffix entirely.
        XCTAssertNil(ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"])
        XCTAssertEqual(
            service.keychainServiceName(forAccountNamed: nil),
            "Claude Code-credentials"
        )

        // A named account is the hash of its own directory, which is the
        // same directory the liveness check uses.
        let account = "work"
        XCTAssertEqual(
            service.keychainServiceName(forAccountNamed: account),
            ClaudeCodeSyncService.serviceName(
                forConfigurationDirectory: ClaudeCodeSyncService
                    .configurationDirectory(forAccountNamed: account).path
            )
        )
    }

    /// N3. A refresh must not resurrect an account directory somebody
    /// unlinked.
    @MainActor
    func testNoLockIsTakenWhereThereIsNoConfigurationDirectory() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let service = makeService(
            runner: RecordingSecurityRunner(),
            profileStore: retain(makeIsolatedProfileStore()),
            credentialsFileDirectory: { _ in missing }
        )

        XCTAssertThrowsError(
            try service.acquireRefreshLock(forAccountNamed: "unlinked")
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }
}
