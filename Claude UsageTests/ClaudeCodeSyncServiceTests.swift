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
        systemCredentialsReader: (() throws -> String?)? = nil
    ) -> ClaudeCodeSyncService {
        _ = retain(runner)
        return retain(
            ClaudeCodeSyncService(
                profileStore: profileStore,
                systemCredentialsReader: systemCredentialsReader,
                securityRunner: runner
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
}
