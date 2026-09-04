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
        runner: RecordingSecurityRunner
    ) -> ClaudeCodeSyncService {
        _ = retain(runner)
        return retain(
            ClaudeCodeSyncService(
                profileStore: retain(makeIsolatedProfileStore()),
                securityRunner: runner
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
        credentialLogSink: ((String) -> Void)? = nil
    ) -> ClaudeCodeSyncService {
        _ = retain(runner)
        // Apply tests provide a system-reader seam and must not fall through
        // to the machine Keychain for the new direct-item ownership check.
        // Rotation tests leave that seam nil so their scripted runner remains
        // the owner of the Keychain interaction.
        let itemReader = keychainCredentialsReader
            ?? (systemCredentialsReader == nil ? nil : { _ in nil })
        let fileDirectory = credentialsFileDirectory ?? { _ in
            FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        }
        return retain(
            ClaudeCodeSyncService(
                profileStore: profileStore,
                systemCredentialsReader: systemCredentialsReader,
                keychainCredentialsReader: itemReader,
                securityRunner: runner,
                credentialsFileDirectory: fileDirectory,
                credentialLogSink: credentialLogSink
            )
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
        let runner = RecordingSecurityRunner()
        try makeService(runner: runner).writeSystemCredentials(credentials)

        XCTAssertEqual(runner.verbs, ["add-generic-password"])
        XCTAssertFalse(
            runner.verbs.contains("delete-generic-password"),
            "A successful write must not delete the user's live credentials"
        )
    }

    @MainActor
    func testWriteUpdatesInPlace() throws {
        let runner = RecordingSecurityRunner()
        try makeService(runner: runner).writeSystemCredentials(credentials)

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

        XCTAssertThrowsError(
            try makeService(runner: runner).writeSystemCredentials(credentials)
        )
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

        XCTAssertThrowsError(
            try makeService(runner: runner).writeSystemCredentials(credentials)
        ) { error in
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

        try makeService(runner: runner).writeSystemCredentials(credentials)

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
    private var rotationAccountServiceName: String {
        ClaudeCodeSyncService.serviceName(
            forConfigurationDirectory: ClaudeCodeSyncService
                .configurationDirectory(
                    forAccountNamed: Self.rotationAccountName
                ).path
        )
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
        runner.results = [
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

    @MainActor
    func testRotatedTokenInBothStoresUpdatesBoth() throws {
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
        XCTAssertTrue(try String(contentsOf: credentialsFile(in: directory)).contains("rotated"))
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

        XCTAssertEqual(
            runner.verbs,
            ["find-generic-password", "add-generic-password"],
            "The rotated token must be written back into Claude Code's login"
        )
        let read = try XCTUnwrap(runner.invocations.first)
        let write = try XCTUnwrap(runner.invocations.last)
        XCTAssertTrue(
            write.contains(rotationRenewed),
            "Claude Code must receive the renewed credential: \(write)"
        )
        XCTAssertTrue(
            write.contains(rotationAccountServiceName),
            "The write must land on this account's own Keychain item, not "
                + "the shared one: \(write)"
        )
        // The whole guard is worthless if the item that was checked is not
        // the item that gets overwritten.
        XCTAssertTrue(
            read.contains(rotationAccountServiceName),
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
}
