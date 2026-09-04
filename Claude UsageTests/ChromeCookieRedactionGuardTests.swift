//
//  ChromeCookieRedactionGuardTests.swift
//  Claude UsageTests
//
//  Silence, not redaction, is the defence here. `LoggingService.emit` logs
//  `os_log("%{public}@", …)`, so anything that reaches the logger is public in
//  the unified log, and `SensitiveDataRedactor` does NOT match the Chrome Safe
//  Storage passphrase — it is a bare base64-looking string with no prefix and
//  no label. So these tests assert the reader emits exactly one fixed line and
//  never interpolates a value into it.
//
//  There is deliberately no assertion that the redactor covers the
//  passphrase. It does not, and a test claiming otherwise would be false
//  comfort.
//

import Foundation
import XCTest
@testable import Claude_Usage

final class ChromeCookieRedactionGuardTests: XCTestCase {
    private static let sessionKeySentinel =
        "sk-ant-sid01-SENTINEL-3175-a1b2c3"
    private static let passphraseSentinel =
        "SENTINEL-PASSPHRASE-3175-do-not-log"

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "revvytach-tests-3175-redaction-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        root = nil
        try super.tearDownWithError()
    }

    /// Every temporary copy lands inside this test's own root, never the real
    /// `$TMPDIR`, so a test run can never collide with an in-flight read.
    private func isolatedFilesystem() -> ChromeCookieFilesystem {
        let temporaryRoot = root.appendingPathComponent(
            "temp", isDirectory: true
        )
        var filesystem = ChromeCookieFilesystem.live
        filesystem = ChromeCookieFilesystem(
            metadata: filesystem.metadata,
            modificationDate: filesystem.modificationDate,
            createDirectory: filesystem.createDirectory,
            copyItem: filesystem.copyItem,
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
                return url
            },
            contentsOfDirectory: filesystem.contentsOfDirectory,
            removeItem: filesystem.removeItem,
            currentUserID: filesystem.currentUserID
        )
        return filesystem
    }

    private func makeReader(
        captured: ChromeCookieTestBox<[String]>,
        passphrase: String = ChromeCookieRedactionGuardTests.passphraseSentinel
    ) -> ChromeCookieSessionKeyReader {
        let passphraseData = Data(passphrase.utf8)
        return ChromeCookieSessionKeyReader(
            userDataDirectory: root.appendingPathComponent(
                "chrome", isDirectory: true
            ),
            filesystem: isolatedFilesystem(),
            readKeychainPassphrase: { passphraseData },
            now: { Date() },
            logOutcome: { message in captured.mutate { $0.append(message) } }
        )
    }

    private func writeFixture(withSessionKey key: String) throws {
        let database = root
            .appendingPathComponent("chrome", isDirectory: true)
            .appendingPathComponent("Profile 3", isDirectory: true)
            .appendingPathComponent("Network", isDirectory: true)
            .appendingPathComponent("Cookies", isDirectory: false)
        let derived = try ChromeCookieCrypto.deriveKey(
            passphrase: Data(Self.passphraseSentinel.utf8)
        )
        try ChromeCookieTestDatabase.write(
            [.init(
                encryptedValue: ChromeCookieTestCrypto.encrypt(
                    value: key,
                    hostKey: ".claude.ai",
                    key: derived,
                    includeDomainPrefix: true
                )
            )],
            to: database
        )
    }

    private func read(
        _ reader: ChromeCookieSessionKeyReader
    ) throws -> String {
        let box = ChromeCookieTestBox<Result<String, Error>?>(nil)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.value = Result {
                try reader.readSessionKey(profileDirectoryName: "Profile 3")
            }
            finished.signal()
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 30), .success)
        return try XCTUnwrap(box.value).get()
    }

    func testASuccessfulReadEmitsOneFixedLineAndNoSecret() throws {
        try writeFixture(withSessionKey: Self.sessionKeySentinel)
        let captured = ChromeCookieTestBox<[String]>([])

        XCTAssertEqual(
            try read(makeReader(captured: captured)), Self.sessionKeySentinel
        )

        // One line, and that line is exactly this. The moment anyone
        // interpolates the value or an error detail into it, this fails.
        XCTAssertEqual(captured.value, ["chrome cookie read: success"])

        let joined = captured.value.joined(separator: "\n")
        XCTAssertFalse(joined.contains(Self.sessionKeySentinel))
        XCTAssertFalse(joined.contains(Self.passphraseSentinel))
        XCTAssertFalse(joined.contains("sk-ant"))
        XCTAssertFalse(joined.contains("Profile 3"))
        XCTAssertFalse(joined.contains(root.path))
    }

    func testAFailedReadLogsTheCaseNameAndNothingElse() throws {
        // A cookie the policy rejects, so the read fails after touching a
        // real database and a real row.
        try writeFixture(withSessionKey: Self.sessionKeySentinel)
        let captured = ChromeCookieTestBox<[String]>([])
        let reader = makeReader(
            captured: captured, passphrase: "wrong-passphrase"
        )

        XCTAssertThrowsError(try read(reader))

        XCTAssertEqual(captured.value, ["chrome cookie read: decryptFailed"])
        let joined = captured.value.joined(separator: "\n")
        XCTAssertFalse(joined.contains("wrong-passphrase"))
        XCTAssertFalse(joined.contains(Self.sessionKeySentinel))
    }

    func testAMissingCookieLogsItsCaseNameWithNoKeychainDetail() throws {
        let captured = ChromeCookieTestBox<[String]>([])

        XCTAssertThrowsError(try read(makeReader(captured: captured)))

        XCTAssertEqual(
            captured.value, ["chrome cookie read: cookieDatabaseMissing"]
        )
    }

    /// The redactor is a real backstop for the session key's shape, which is
    /// why it is worth asserting — and why the passphrase, which it does not
    /// match, gets silence instead.
    func testTheRedactorStillCoversTheSessionKeyShape() {
        let sentinel = Self.sessionKeySentinel

        XCTAssertFalse(
            SensitiveDataRedactor.redact("sessionKey=\(sentinel)")
                .contains(sentinel)
        )
        XCTAssertFalse(
            SensitiveDataRedactor.redact(sentinel).contains(sentinel)
        )
        XCTAssertFalse(
            SensitiveDataRedactor.redact("cookie: \(sentinel)")
                .contains(sentinel)
        )
    }
}
