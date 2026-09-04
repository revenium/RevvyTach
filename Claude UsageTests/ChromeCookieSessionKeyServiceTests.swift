//
//  ChromeCookieSessionKeyServiceTests.swift
//  Claude UsageTests
//
//  Isolation, by construction:
//  - the Keychain boundary is always an injected closure, so
//    `SecItemCopyMatching` is never called and the developer's real Keychain
//    is never touched;
//  - `userDataDirectory` always points at a fixture tree under a test-owned
//    temporary directory, never `~/Library/Application Support/Google/Chrome`;
//  - every temporary copy is created inside that same test-owned root, and
//    every sweeper test passes an injected `baseDirectory`, so a test run can
//    never delete a real in-flight copy;
//  - nothing here writes to the app's Application Support storage.
//

import Foundation
import SQLite3
import XCTest
@testable import Claude_Usage

// MARK: - Fixture helpers

/// Writes a real Chrome-shaped `Cookies` database, so the production SQL runs
/// against the production schema rather than against a stub.
enum ChromeCookieTestDatabase {
    struct Row {
        var hostKey = ".claude.ai"
        var name = "sessionKey"
        var path = "/"
        var isSecure = true
        var expiresUTC: Int64 = 0
        var creationUTC: Int64 = 0
        var encryptedValue = Data()
        var value = ""
    }

    struct FixtureError: Error {
        let message: String
    }

    private static let schema = """
        CREATE TABLE cookies(
            creation_utc INTEGER NOT NULL,
            host_key TEXT NOT NULL,
            name TEXT NOT NULL,
            value TEXT NOT NULL,
            path TEXT NOT NULL,
            expires_utc INTEGER NOT NULL,
            is_secure INTEGER NOT NULL,
            is_httponly INTEGER NOT NULL,
            encrypted_value BLOB DEFAULT '');
        """

    private static let insert = """
        INSERT INTO cookies (creation_utc, host_key, name, value, path,
                             expires_utc, is_secure, is_httponly,
                             encrypted_value)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 1, ?8)
        """

    static func write(_ rows: [Row], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
            nil
        ) == SQLITE_OK, let database = handle else {
            sqlite3_close(handle)
            throw FixtureError(message: "could not create \(url.path)")
        }
        defer { sqlite3_close(database) }

        guard sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK else {
            throw FixtureError(message: "schema creation failed")
        }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for row in rows {
            var statementHandle: OpaquePointer?
            guard sqlite3_prepare_v2(
                database, insert, -1, &statementHandle, nil
            ) == SQLITE_OK, let statement = statementHandle else {
                sqlite3_finalize(statementHandle)
                throw FixtureError(message: "insert prepare failed")
            }
            sqlite3_bind_int64(statement, 1, row.creationUTC)
            sqlite3_bind_text(statement, 2, row.hostKey, -1, transient)
            sqlite3_bind_text(statement, 3, row.name, -1, transient)
            sqlite3_bind_text(statement, 4, row.value, -1, transient)
            sqlite3_bind_text(statement, 5, row.path, -1, transient)
            sqlite3_bind_int64(statement, 6, row.expiresUTC)
            sqlite3_bind_int64(statement, 7, row.isSecure ? 1 : 0)
            let encrypted = row.encryptedValue
            _ = encrypted.withUnsafeBytes { buffer in
                sqlite3_bind_blob(
                    statement,
                    8,
                    buffer.baseAddress,
                    Int32(buffer.count),
                    transient
                )
            }
            let stepped = sqlite3_step(statement)
            sqlite3_finalize(statement)
            guard stepped == SQLITE_DONE else {
                throw FixtureError(message: "insert step failed")
            }
        }
    }
}

/// Minimal locked boxes so a background read can hand results back without
/// tripping concurrency checking.
final class ChromeCookieTestBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ initial: Value) {
        storage = initial
    }

    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); defer { lock.unlock() }; storage = newValue }
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock()
        body(&storage)
        lock.unlock()
    }
}

/// Fake Keychain boundary. Counting the calls is the regression test for the
/// prompt-ordering rule: a read that cannot decrypt anything must never ask.
final class ChromeKeychainPassphraseSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let outcome: Result<Data, Error>

    init(_ outcome: Result<Data, Error>) {
        self.outcome = outcome
    }

    convenience init(passphrase: Data = ChromeCookieTestCrypto.fixturePassphrase) {
        self.init(.success(passphrase))
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    var read: @Sendable () throws -> Data {
        { [self] in
            lock.lock()
            count += 1
            lock.unlock()
            return try outcome.get()
        }
    }
}

// MARK: - Tests

final class ChromeCookieSessionKeyServiceTests: XCTestCase {
    private var root: URL!
    private var createdTemporaryDirectories: ChromeCookieTestBox<[URL]>!

    private let profileDirectoryName = "Profile 3"
    private let sessionKey =
        "sk-ant-sid01-FIXTURE-3175-abcdefghijklmnopqrstuvwxyz0123456789"
    private let alternateSessionKey =
        "sk-ant-sid01-ALTERNATE-3175-zyxwvutsrqponmlkjihgfedcba98765"

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "revvytach-tests-3175-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        createdTemporaryDirectories = ChromeCookieTestBox([])
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        root = nil
        createdTemporaryDirectories = nil
        try super.tearDownWithError()
    }

    // MARK: Fixture plumbing

    private enum Slot {
        case network
        case legacy
    }

    private var userDataDirectory: URL {
        root.appendingPathComponent("chrome", isDirectory: true)
    }

    private func cookieDatabaseURL(_ slot: Slot) -> URL {
        let profile = userDataDirectory.appendingPathComponent(
            profileDirectoryName, isDirectory: true
        )
        switch slot {
        case .network:
            return profile
                .appendingPathComponent("Network", isDirectory: true)
                .appendingPathComponent("Cookies", isDirectory: false)
        case .legacy:
            return profile.appendingPathComponent(
                "Cookies", isDirectory: false
            )
        }
    }

    private func writeCookies(
        _ rows: [ChromeCookieTestDatabase.Row],
        slot: Slot = .network
    ) throws {
        try ChromeCookieTestDatabase.write(rows, to: cookieDatabaseURL(slot))
    }

    private func fixtureKey() throws -> Data {
        try ChromeCookieCrypto.deriveKey(
            passphrase: ChromeCookieTestCrypto.fixturePassphrase
        )
    }

    private func encrypted(
        _ value: String,
        hostKey: String = ".claude.ai",
        includeDomainPrefix: Bool = true
    ) throws -> Data {
        ChromeCookieTestCrypto.encrypt(
            value: value,
            hostKey: hostKey,
            key: try fixtureKey(),
            includeDomainPrefix: includeDomainPrefix
        )
    }

    /// A real-filesystem seam whose temporary directories land inside the
    /// test root, plus optional per-path metadata overrides so the unsafe
    /// sidecar and wrong-owner cases can be forced without root.
    private func filesystem(
        metadataOverrides: [String: ChromeProfileFileMetadata] = [:],
        metadataOverridesByName: [String: ChromeProfileFileMetadata] = [:],
        metadataCalls: ChromeCookieTestBox<[String]>? = nil,
        stuckRemovalNames: Set<String> = [],
        currentUserID: UInt32 = UInt32(getuid())
    ) -> ChromeCookieFilesystem {
        let temporaryRoot = root.appendingPathComponent(
            "temp", isDirectory: true
        )
        let created = createdTemporaryDirectories!
        let live = ChromeCookieFilesystem.live
        return ChromeCookieFilesystem(
            metadata: { url in
                metadataCalls?.mutate { $0.append(url.path) }
                if let override = metadataOverrides[url.path]
                    ?? metadataOverridesByName[url.lastPathComponent] {
                    return override
                }
                return live.metadata(url)
            },
            modificationDate: live.modificationDate,
            createDirectory: live.createDirectory,
            copyItem: live.copyItem,
            makeUniqueTempDirectory: {
                let url = temporaryRoot.appendingPathComponent(
                    ChromeCookieTempCopySweeper.directoryPrefix
                        + UUID().uuidString,
                    isDirectory: true
                )
                try FileManager.default.createDirectory(
                    at: url,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                created.mutate { $0.append(url) }
                return url
            },
            contentsOfDirectory: live.contentsOfDirectory,
            removeItem: { url in
                guard !stuckRemovalNames.contains(url.lastPathComponent) else {
                    return
                }
                live.removeItem(url)
            },
            currentUserID: { currentUserID }
        )
    }

    private func makeReader(
        keychain: ChromeKeychainPassphraseSpy,
        filesystem: ChromeCookieFilesystem? = nil,
        readCookieRows: ChromeCookieSessionKeyReader.CookieRowReader? = nil,
        now: Date = Date(),
        logOutcome: (@Sendable (String) -> Void)? = nil
    ) -> ChromeCookieSessionKeyReader {
        ChromeCookieSessionKeyReader(
            userDataDirectory: userDataDirectory,
            filesystem: filesystem ?? self.filesystem(),
            readKeychainPassphrase: keychain.read,
            readCookieRows: readCookieRows ?? { copy, nowMicroseconds in
                try ChromeCookieSessionKeyReader.liveCookieRowReader(
                    databaseCopy: copy,
                    nowChromeMicroseconds: nowMicroseconds
                )
            },
            now: { now },
            logOutcome: logOutcome ?? { _ in }
        )
    }

    /// `readSessionKey` refuses to run on the main queue, because on the main
    /// queue it would freeze the wizard behind the system password dialog.
    private func readOffMain(
        _ reader: ChromeCookieSessionKeyReader,
        profile: String? = nil
    ) throws -> String {
        let directoryName = profile ?? profileDirectoryName
        let box = ChromeCookieTestBox<Result<String, Error>?>(nil)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.value = Result {
                try reader.readSessionKey(
                    profileDirectoryName: directoryName
                )
            }
            finished.signal()
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 30), .success)
        return try XCTUnwrap(box.value).get()
    }

    private func expectReadError(
        _ expected: ChromeCookieReadError,
        _ reader: ChromeCookieSessionKeyReader,
        profile: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try readOffMain(reader, profile: profile), file: file, line: line
        ) { error in
            XCTAssertEqual(
                error as? ChromeCookieReadError, expected,
                file: file, line: line
            )
        }
    }

    private func chromeMicroseconds(
        _ now: Date, offsetSeconds: TimeInterval
    ) -> Int64 {
        ChromeCookieTime.microseconds(
            from: now.addingTimeInterval(offsetSeconds)
        )
    }

    // MARK: Orchestration

    /// O1
    func testHappyPathReturnsTheSessionKeyWithoutTheRealKeychainOrChrome() throws {
        let now = Date()
        let keychain = ChromeKeychainPassphraseSpy()
        try writeCookies([
            .init(
                creationUTC: chromeMicroseconds(now, offsetSeconds: -60),
                encryptedValue: try encrypted(sessionKey)
            ),
        ])

        let reader = makeReader(keychain: keychain, now: now)

        XCTAssertEqual(try readOffMain(reader), sessionKey)
        XCTAssertEqual(keychain.callCount, 1)
        // The fixture tree is the only Chrome directory this reader saw.
        XCTAssertTrue(
            userDataDirectory.path.hasPrefix(root.path),
            "the reader must never be pointed at the real Chrome directory"
        )
    }

    /// O2 — the prompt-ordering regression test.
    func testNoKeychainPromptWhenTheSessionCookieIsMissing() throws {
        let keychain = ChromeKeychainPassphraseSpy()
        try writeCookies([
            .init(name: "someOtherCookie", value: "irrelevant"),
        ])

        expectReadError(.sessionCookieMissing, makeReader(keychain: keychain))
        XCTAssertEqual(keychain.callCount, 0)
    }

    /// O3
    func testNoKeychainPromptForAnUnencryptedRow() throws {
        let keychain = ChromeKeychainPassphraseSpy()
        try writeCookies([.init(value: sessionKey)])

        XCTAssertEqual(
            try readOffMain(makeReader(keychain: keychain)), sessionKey
        )
        XCTAssertEqual(keychain.callCount, 0)
    }

    /// O4
    func testNoKeychainPromptWhenNoCookieDatabaseExists() {
        let keychain = ChromeKeychainPassphraseSpy()

        expectReadError(
            .cookieDatabaseMissing, makeReader(keychain: keychain)
        )
        XCTAssertEqual(keychain.callCount, 0)
        XCTAssertTrue(
            createdTemporaryDirectories.value.isEmpty,
            "nothing may be copied before a database is found"
        )
    }

    /// O5
    func testKeychainIsAskedExactlyOnceOnTheEncryptedPath() throws {
        let now = Date()
        let keychain = ChromeKeychainPassphraseSpy()
        try writeCookies([
            .init(
                creationUTC: chromeMicroseconds(now, offsetSeconds: -60),
                encryptedValue: try encrypted(sessionKey)
            ),
            .init(
                hostKey: "claude.ai",
                creationUTC: chromeMicroseconds(now, offsetSeconds: -120),
                encryptedValue: try encrypted(
                    alternateSessionKey, hostKey: "claude.ai"
                )
            ),
        ])

        _ = try readOffMain(makeReader(keychain: keychain, now: now))

        XCTAssertEqual(keychain.callCount, 1)
    }

    /// O6
    func testLockedAndUnreadableDatabasesDegradeWithoutGuessing() throws {
        let keychain = ChromeKeychainPassphraseSpy()
        try writeCookies([
            .init(encryptedValue: try encrypted(sessionKey)),
        ])

        expectReadError(
            .databaseLocked,
            makeReader(
                keychain: keychain,
                readCookieRows: { _, _ in
                    throw ChromeCookieReadError.databaseLocked
                }
            )
        )
        XCTAssertEqual(keychain.callCount, 0)

        // The production reader against a file that is not a database at all.
        let garbage = root.appendingPathComponent("garbage.db")
        try Data("this is not a database".utf8).write(to: garbage)
        XCTAssertThrowsError(
            try ChromeCookieSessionKeyReader.liveCookieRowReader(
                databaseCopy: garbage, nowChromeMicroseconds: 0
            )
        ) { error in
            XCTAssertEqual(
                error as? ChromeCookieReadError, .databaseUnreadable
            )
        }
    }

    /// O7
    func testKeychainDenialPropagates() throws {
        let now = Date()
        let keychain = ChromeKeychainPassphraseSpy(
            .failure(ChromeCookieReadError.keychainAccessDenied)
        )
        try writeCookies([
            .init(
                creationUTC: chromeMicroseconds(now, offsetSeconds: -60),
                encryptedValue: try encrypted(sessionKey)
            ),
        ])

        expectReadError(
            .keychainAccessDenied, makeReader(keychain: keychain, now: now)
        )
    }

    /// O8 — the `defer` unlink runs on the throwing path.
    func testTemporaryCopyIsRemovedWhenTheReadThrows() throws {
        let keychain = ChromeKeychainPassphraseSpy()
        try writeCookies([
            .init(encryptedValue: try encrypted(sessionKey)),
        ])
        let copyExisted = ChromeCookieTestBox(false)

        expectReadError(
            .databaseLocked,
            makeReader(
                keychain: keychain,
                readCookieRows: { copy, _ in
                    copyExisted.value = FileManager.default.fileExists(
                        atPath: copy.path
                    )
                    throw ChromeCookieReadError.databaseLocked
                }
            )
        )

        XCTAssertTrue(
            copyExisted.value, "the copy must exist when the read throws"
        )
        let temporaryDirectories = createdTemporaryDirectories.value
        XCTAssertEqual(temporaryDirectories.count, 1)
        for directory in temporaryDirectories {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: directory.path),
                "the temporary copy survived a throw"
            )
        }
    }

    /// O8, success path.
    func testTemporaryCopyIsRemovedOnTheSuccessPath() throws {
        let now = Date()
        try writeCookies([
            .init(
                creationUTC: chromeMicroseconds(now, offsetSeconds: -60),
                encryptedValue: try encrypted(sessionKey)
            ),
        ])

        _ = try readOffMain(
            makeReader(keychain: ChromeKeychainPassphraseSpy(), now: now)
        )

        XCTAssertEqual(createdTemporaryDirectories.value.count, 1)
        for directory in createdTemporaryDirectories.value {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: directory.path)
            )
        }
    }

    /// O9 — a mis-decoded value must not reach the UI as text.
    func testMisDecodedPlaintextFailsWithoutEchoingItsBytes() throws {
        let keychain = ChromeKeychainPassphraseSpy()
        let junk = "not a key!!"
        try writeCookies([
            .init(encryptedValue: try encrypted(junk)),
        ])

        XCTAssertThrowsError(
            try readOffMain(makeReader(keychain: keychain))
        ) { error in
            XCTAssertEqual(error as? ChromeCookieReadError, .decryptFailed)
            let rendered = String(describing: error)
                + (error.localizedDescription)
            XCTAssertFalse(rendered.contains(junk))
            XCTAssertFalse(rendered.contains("not a key"))
        }
    }

    /// O10
    func testUnsafeSidecarAbortsWhileAMissingSidecarIsNormal() throws {
        let now = Date()
        try writeCookies([
            .init(
                creationUTC: chromeMicroseconds(now, offsetSeconds: -60),
                encryptedValue: try encrypted(sessionKey)
            ),
        ])
        // A missing sidecar is the normal, checkpointed case.
        XCTAssertEqual(
            try readOffMain(
                makeReader(keychain: ChromeKeychainPassphraseSpy(), now: now)
            ),
            sessionKey
        )

        // A sidecar that exists but belongs to another user aborts the read
        // rather than being skipped: a stale jar is not an acceptable
        // fallback for a credential read.
        let sidecar = URL(
            fileURLWithPath: cookieDatabaseURL(.network).path + "-wal"
        )
        try Data("wal".utf8).write(to: sidecar)
        let foreign = ChromeProfileFileMetadata(
            exists: true,
            isRegularFile: true,
            isDirectory: false,
            isSymbolicLink: false,
            ownerUserID: 999,
            size: 3
        )
        expectReadError(
            .tempCopyFailed,
            makeReader(
                keychain: ChromeKeychainPassphraseSpy(),
                filesystem: filesystem(
                    metadataOverrides: [sidecar.path: foreign]
                ),
                now: now
            )
        )
        for directory in createdTemporaryDirectories.value {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: directory.path)
            )
        }
    }

    /// O11
    func testInvalidProfileDirectoryNameTouchesNothing() {
        let calls = ChromeCookieTestBox<[String]>([])
        let keychain = ChromeKeychainPassphraseSpy()
        let reader = makeReader(
            keychain: keychain,
            filesystem: filesystem(metadataCalls: calls)
        )

        for name in ["../escape", "Profile/evil", "", "/absolute"] {
            expectReadError(.invalidProfile, reader, profile: name)
        }
        XCTAssertTrue(calls.value.isEmpty)
        XCTAssertEqual(keychain.callCount, 0)
        XCTAssertTrue(createdTemporaryDirectories.value.isEmpty)
    }

    // MARK: Selection policy — asserted in SQL and again in Swift

    /// C1
    func testInsecureRowIsRejectedByBothLayers() throws {
        let now = Date()
        try writeCookies([
            .init(
                isSecure: false,
                encryptedValue: try encrypted(sessionKey)
            ),
        ])

        expectReadError(
            .sessionCookieMissing,
            makeReader(keychain: ChromeKeychainPassphraseSpy(), now: now)
        )
        XCTAssertNil(
            ChromeCookieSelectionPolicy.select(
                [ChromeCookieRow(
                    hostKey: ".claude.ai",
                    isSecure: false,
                    plaintextValue: sessionKey
                )],
                nowChromeMicroseconds: ChromeCookieTime.microseconds(from: now)
            )
        )
    }

    /// C2 — an expired but perfectly shaped key is the "wrong but plausible"
    /// outcome this feature must never produce.
    func testExpiredRowIsRejectedByBothLayersEvenThoughItWouldValidate() throws {
        let now = Date()
        let expired = chromeMicroseconds(now, offsetSeconds: -3600)
        try writeCookies([
            .init(
                expiresUTC: expired,
                encryptedValue: try encrypted(sessionKey)
            ),
        ])

        expectReadError(
            .sessionCookieMissing,
            makeReader(keychain: ChromeKeychainPassphraseSpy(), now: now)
        )
        XCTAssertNil(
            ChromeCookieSelectionPolicy.select(
                [ChromeCookieRow(
                    hostKey: ".claude.ai",
                    expiresUTC: expired,
                    plaintextValue: sessionKey
                )],
                nowChromeMicroseconds: ChromeCookieTime.microseconds(from: now)
            )
        )
    }

    /// C3 — `expires_utc = 0` is a session cookie, not "expired in 1601".
    func testSessionCookieIsAcceptedByBothLayers() throws {
        let now = Date()
        try writeCookies([
            .init(expiresUTC: 0, encryptedValue: try encrypted(sessionKey)),
        ])

        XCTAssertEqual(
            try readOffMain(
                makeReader(keychain: ChromeKeychainPassphraseSpy(), now: now)
            ),
            sessionKey
        )
        XCTAssertNotNil(
            ChromeCookieSelectionPolicy.select(
                [ChromeCookieRow(
                    hostKey: ".claude.ai",
                    expiresUTC: 0,
                    plaintextValue: sessionKey
                )],
                nowChromeMicroseconds: ChromeCookieTime.microseconds(from: now)
            )
        )
    }

    /// C4
    func testNonRootPathIsRejectedByBothLayers() throws {
        let now = Date()
        try writeCookies([
            .init(
                path: "/settings",
                encryptedValue: try encrypted(sessionKey)
            ),
        ])

        expectReadError(
            .sessionCookieMissing,
            makeReader(keychain: ChromeKeychainPassphraseSpy(), now: now)
        )
        XCTAssertNil(
            ChromeCookieSelectionPolicy.select(
                [ChromeCookieRow(
                    hostKey: ".claude.ai",
                    path: "/settings",
                    plaintextValue: sessionKey
                )],
                nowChromeMicroseconds: ChromeCookieTime.microseconds(from: now)
            )
        )
    }

    /// C5
    func testLookalikeHostsAreRejectedByBothLayers() throws {
        let now = Date()
        try writeCookies([
            .init(
                hostKey: "claude.ai.attacker.example",
                encryptedValue: try encrypted(
                    sessionKey, hostKey: "claude.ai.attacker.example"
                )
            ),
            .init(
                hostKey: "notclaude.ai",
                encryptedValue: try encrypted(
                    sessionKey, hostKey: "notclaude.ai"
                )
            ),
            .init(
                hostKey: ".claude.ai.attacker.example",
                encryptedValue: try encrypted(
                    sessionKey, hostKey: ".claude.ai.attacker.example"
                )
            ),
        ])

        expectReadError(
            .sessionCookieMissing,
            makeReader(keychain: ChromeKeychainPassphraseSpy(), now: now)
        )
        XCTAssertNil(
            ChromeCookieSelectionPolicy.select(
                [
                    ChromeCookieRow(
                        hostKey: "claude.ai.attacker.example",
                        plaintextValue: sessionKey
                    ),
                    ChromeCookieRow(
                        hostKey: "notclaude.ai", plaintextValue: sessionKey
                    ),
                ],
                nowChromeMicroseconds: ChromeCookieTime.microseconds(from: now)
            )
        )
    }

    /// C6 — duplicates resolve the same way every time, and the Swift policy,
    /// not the SQL, is the authority.
    func testDuplicateRowsResolveDeterministically() throws {
        let now = Date()
        let nowMicroseconds = ChromeCookieTime.microseconds(from: now)
        let issued = chromeMicroseconds(now, offsetSeconds: -600)
        let farFuture = chromeMicroseconds(now, offsetSeconds: 365 * 86_400)
        let nearFuture = chromeMicroseconds(now, offsetSeconds: 86_400)

        // Every row is issued at the same moment, so the session-cookie rule
        // is what decides. Insert order is deliberately shuffled.
        let sessionRow = ChromeCookieRow(
            hostKey: ".claude.ai",
            expiresUTC: 0,
            creationUTC: issued,
            plaintextValue: "session"
        )
        let exactFarFuture = ChromeCookieRow(
            hostKey: ".claude.ai",
            expiresUTC: farFuture,
            creationUTC: issued,
            plaintextValue: "exact-far"
        )
        let exactNearFuture = ChromeCookieRow(
            hostKey: ".claude.ai",
            expiresUTC: nearFuture,
            creationUTC: issued,
            plaintextValue: "exact-near"
        )
        let bareFarFuture = ChromeCookieRow(
            hostKey: "claude.ai",
            expiresUTC: farFuture,
            creationUTC: issued,
            plaintextValue: "bare-far"
        )

        XCTAssertEqual(
            ChromeCookieSelectionPolicy.select(
                [bareFarFuture, exactNearFuture, sessionRow, exactFarFuture],
                nowChromeMicroseconds: nowMicroseconds
            ),
            sessionRow
        )
        XCTAssertEqual(
            ChromeCookieSelectionPolicy.select(
                [exactFarFuture, bareFarFuture, exactNearFuture],
                nowChromeMicroseconds: nowMicroseconds
            ),
            exactFarFuture
        )

        // The same four rows through the real SQL and the real crypto.
        try writeCookies([
            .init(
                hostKey: "claude.ai",
                expiresUTC: farFuture,
                creationUTC: issued,
                encryptedValue: try encrypted(
                    alternateSessionKey, hostKey: "claude.ai"
                )
            ),
            .init(
                expiresUTC: nearFuture,
                creationUTC: issued,
                encryptedValue: try encrypted(alternateSessionKey)
            ),
            .init(
                expiresUTC: 0,
                creationUTC: issued,
                encryptedValue: try encrypted(sessionKey)
            ),
            .init(
                expiresUTC: farFuture,
                creationUTC: issued,
                encryptedValue: try encrypted(alternateSessionKey)
            ),
        ])

        XCTAssertEqual(
            try readOffMain(
                makeReader(keychain: ChromeKeychainPassphraseSpy(), now: now)
            ),
            sessionKey
        )
    }

    /// C7 — both jars are read and merged, so a migration leftover cannot win
    /// on ordering alone, and the modern path gets no blind preference.
    func testBothCookieDatabasesAreMergedAndTheNewestIssuedCookieWins() throws {
        let now = Date()
        let older = chromeMicroseconds(now, offsetSeconds: -7200)
        let newer = chromeMicroseconds(now, offsetSeconds: -60)
        let tomorrow = chromeMicroseconds(now, offsetSeconds: 86_400)
        let nextYear = chromeMicroseconds(now, offsetSeconds: 365 * 86_400)

        // The legacy jar holds the more recently issued cookie. Preferring
        // `Network/Cookies` blindly would return the other one.
        try writeCookies(
            [.init(
                expiresUTC: tomorrow,
                creationUTC: older,
                encryptedValue: try encrypted(alternateSessionKey)
            )],
            slot: .network
        )
        try writeCookies(
            [.init(
                expiresUTC: nextYear,
                creationUTC: newer,
                encryptedValue: try encrypted(sessionKey)
            )],
            slot: .legacy
        )

        XCTAssertEqual(
            try readOffMain(
                makeReader(keychain: ChromeKeychainPassphraseSpy(), now: now)
            ),
            sessionKey
        )
    }

    /// C7 / R4 — a session-shaped leftover in the stale jar must lose to a
    /// more recently issued dated cookie in the live jar. Ranking session
    /// cookies first (correct for a single live store) is the exact mechanism
    /// by which a stale jar would win here.
    func testStaleSessionShapedLeftoverLosesToANewerDatedCookie() throws {
        let now = Date()
        let nowMicroseconds = ChromeCookieTime.microseconds(from: now)
        let leftover = ChromeCookieRow(
            hostKey: ".claude.ai",
            expiresUTC: 0,
            creationUTC: chromeMicroseconds(now, offsetSeconds: -90 * 86_400),
            plaintextValue: "stale-leftover"
        )
        let live = ChromeCookieRow(
            hostKey: ".claude.ai",
            expiresUTC: chromeMicroseconds(now, offsetSeconds: 365 * 86_400),
            creationUTC: chromeMicroseconds(now, offsetSeconds: -60),
            plaintextValue: "live"
        )

        XCTAssertEqual(
            ChromeCookieSelectionPolicy.select(
                [leftover, live], nowChromeMicroseconds: nowMicroseconds
            ),
            live
        )
        XCTAssertEqual(
            ChromeCookieSelectionPolicy.select(
                [live, leftover], nowChromeMicroseconds: nowMicroseconds
            ),
            live
        )

        try writeCookies(
            [.init(
                expiresUTC: live.expiresUTC,
                creationUTC: live.creationUTC,
                encryptedValue: try encrypted(sessionKey)
            )],
            slot: .network
        )
        try writeCookies(
            [.init(
                expiresUTC: 0,
                creationUTC: leftover.creationUTC,
                encryptedValue: try encrypted(alternateSessionKey)
            )],
            slot: .legacy
        )

        XCTAssertEqual(
            try readOffMain(
                makeReader(keychain: ChromeKeychainPassphraseSpy(), now: now)
            ),
            sessionKey
        )
    }

    /// The comparator must be total, so a duplicate pair never depends on
    /// SQLite's row order or on sort stability.
    func testComparatorIsATotalOrder() {
        let left = ChromeCookieRow(
            hostKey: ".claude.ai", plaintextValue: "a"
        )
        let right = ChromeCookieRow(
            hostKey: ".claude.ai", plaintextValue: "b"
        )

        XCTAssertTrue(ChromeCookieSelectionPolicy.order(left, right))
        XCTAssertFalse(ChromeCookieSelectionPolicy.order(right, left))
        XCTAssertFalse(ChromeCookieSelectionPolicy.order(left, left))

        let encryptedLow = ChromeCookieRow(
            hostKey: ".claude.ai", encryptedValue: Data([0x01])
        )
        let encryptedHigh = ChromeCookieRow(
            hostKey: ".claude.ai", encryptedValue: Data([0x02])
        )
        XCTAssertTrue(
            ChromeCookieSelectionPolicy.order(encryptedLow, encryptedHigh)
        )
        XCTAssertFalse(
            ChromeCookieSelectionPolicy.order(encryptedHigh, encryptedLow)
        )
    }

    /// F5 — one unreadable jar must not veto a healthy one.
    func testAFailingSlotDoesNotVetoTheSlotThatYieldsAKey() throws {
        let now = Date()
        try writeCookies(
            [.init(
                creationUTC: chromeMicroseconds(now, offsetSeconds: -60),
                encryptedValue: try encrypted(sessionKey)
            )],
            slot: .network
        )
        // A legacy jar that is not a database at all.
        try Data("corrupt".utf8).write(to: cookieDatabaseURL(.legacy))

        XCTAssertEqual(
            try readOffMain(
                makeReader(keychain: ChromeKeychainPassphraseSpy(), now: now)
            ),
            sessionKey
        )
    }

    /// F5 — when no slot yields a candidate, the first slot error is what the
    /// user hears about.
    func testTheFirstSlotErrorSurfacesWhenNoCandidateSurvives() throws {
        try Data("corrupt".utf8).write(to: cookieDatabaseURL(.network))

        expectReadError(
            .databaseUnreadable,
            makeReader(keychain: ChromeKeychainPassphraseSpy())
        )
    }

    // MARK: Launch-time sweep

    /// S1-S6, all against an injected base directory.
    func testSweeperRemovesOnlyStaleDirectoriesThisFeatureOwns() throws {
        let base = root.appendingPathComponent("sweep", isDirectory: true)
        try FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true
        )
        let now = Date()

        func makeDirectory(_ name: String, ageSeconds: TimeInterval) throws -> URL {
            let url = base.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true
            )
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(-ageSeconds)],
                ofItemAtPath: url.path
            )
            return url
        }

        let prefix = ChromeCookieTempCopySweeper.directoryPrefix
        let stale = try makeDirectory("\(prefix)stale", ageSeconds: 7200)
        let fresh = try makeDirectory("\(prefix)fresh", ageSeconds: 60)
        let foreignTool = try makeDirectory(
            "some-other-tool-abc", ageSeconds: 7200
        )
        let otherOwner = try makeDirectory(
            "\(prefix)otheruser", ageSeconds: 7200
        )
        let stuck = try makeDirectory("\(prefix)stuck", ageSeconds: 7200)

        let link = base.appendingPathComponent(
            "\(prefix)symlink", isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: stale
        )

        ChromeCookieTempCopySweeper.sweep(
            baseDirectory: base,
            filesystem: filesystem(
                metadataOverridesByName: [
                    otherOwner.lastPathComponent: ChromeProfileFileMetadata(
                        exists: true,
                        isRegularFile: false,
                        isDirectory: true,
                        isSymbolicLink: false,
                        ownerUserID: 999,
                        size: nil
                    ),
                ],
                stuckRemovalNames: [stuck.lastPathComponent]
            ),
            now: now
        )

        let manager = FileManager.default
        XCTAssertFalse(manager.fileExists(atPath: stale.path), "S1 stale")
        XCTAssertTrue(manager.fileExists(atPath: fresh.path), "S2 fresh")
        XCTAssertTrue(
            manager.fileExists(atPath: foreignTool.path), "S3 other prefix"
        )
        XCTAssertTrue(
            manager.fileExists(atPath: otherOwner.path), "S4 other owner"
        )
        // S5: a symlink is never followed or removed.
        XCTAssertNotNil(try? manager.destinationOfSymbolicLink(atPath: link.path))
        // S6: an entry this process cannot remove stays, and the sweep still
        // cleared `stale` above — one stuck directory does not abort the pass.
        XCTAssertTrue(manager.fileExists(atPath: stuck.path), "S6 stuck")
    }

    func testSweeperRetentionAndPrefixAreTheDocumentedValues() {
        XCTAssertEqual(
            ChromeCookieTempCopySweeper.directoryPrefix, "revvytach-chrome-"
        )
        XCTAssertEqual(ChromeCookieTempCopySweeper.retention, 3600)
    }
}
