//
//  ChromeCookieCryptoTests.swift
//  Claude UsageTests
//
//  Covers the Chrome cookie crypto parameters that silently corrupt output
//  when they drift: the PBKDF2 shape, the AES-128-CBC round trip, the
//  schema-24 domain-hash prefix, and the fail-closed version check.
//
//  Nothing here touches the real Keychain, the real Chrome directory, or the
//  app's own storage: every input is a literal in this file.
//

import CommonCrypto
import CryptoKit
import Foundation
import XCTest
@testable import Claude_Usage

/// Test-only encryptor mirroring Chrome's writer. Production only ever
/// decrypts, so this half lives with the tests.
enum ChromeCookieTestCrypto {
    static let fixturePassphrase = Data("fixture-safe-storage".utf8)

    static func encrypt(
        value: String,
        hostKey: String,
        key: Data,
        includeDomainPrefix: Bool,
        versionPrefix: Data = ChromeCookieCrypto.versionPrefix
    ) -> Data {
        var plaintext = Data()
        if includeDomainPrefix {
            plaintext.append(Data(SHA256.hash(data: Data(hostKey.utf8))))
        }
        plaintext.append(Data(value.utf8))
        return versionPrefix + encryptRaw(plaintext: plaintext, key: key)
    }

    /// Encrypts arbitrary bytes with no domain-prefix logic, so a test can
    /// prove a plaintext that merely *looks* prefixed is left alone.
    static func encryptRaw(plaintext: Data, key: Data) -> Data {
        var output = Data(count: plaintext.count + kCCBlockSizeAES128)
        var moved = 0
        let status: Int32 = output.withUnsafeMutableBytes { outputBuffer in
            plaintext.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBuffer in
                    ChromeCookieCrypto.iv.withUnsafeBytes { ivBuffer in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBuffer.baseAddress,
                            keyBuffer.count,
                            ivBuffer.baseAddress,
                            input.baseAddress,
                            input.count,
                            outputBuffer.baseAddress,
                            outputBuffer.count,
                            &moved
                        )
                    }
                }
            }
        }
        precondition(status == Int32(kCCSuccess), "fixture encryption failed")
        return Data(output.prefix(moved))
    }
}

final class ChromeCookieCryptoTests: XCTestCase {
    private let hostKey = ".claude.ai"
    private let sessionKey =
        "sk-ant-sid01-FIXTURE-3175-abcdefghijklmnopqrstuvwxyz0123456789"

    private func fixtureKey() throws -> Data {
        try ChromeCookieCrypto.deriveKey(
            passphrase: ChromeCookieTestCrypto.fixturePassphrase
        )
    }

    // MARK: Key derivation

    func testDeriveKeyIsSixteenStableBytesForAKnownPassphrase() throws {
        let key = try fixtureKey()

        XCTAssertEqual(key.count, ChromeCookieCrypto.keyLength)
        // Golden bytes: PBKDF2-HMAC-SHA1("fixture-safe-storage", "saltysalt",
        // 1003, 16). Any drift in the salt, the iteration count, the digest,
        // or a stray base64 decode of the passphrase moves these.
        XCTAssertEqual(
            key.map { String(format: "%02x", $0) }.joined(),
            "db16859dab5511521615299fa064b832"
        )
        XCTAssertEqual(ChromeCookieCrypto.iterations, 1003)
        XCTAssertEqual(ChromeCookieCrypto.salt, Data("saltysalt".utf8))
        XCTAssertEqual(ChromeCookieCrypto.iv, Data(repeating: 0x20, count: 16))
    }

    func testDeriveKeyRejectsAnEmptyPassphrase() {
        XCTAssertThrowsError(
            try ChromeCookieCrypto.deriveKey(passphrase: Data())
        ) { error in
            XCTAssertEqual(
                error as? ChromeCookieReadError, .decryptFailed
            )
        }
    }

    // MARK: Round trips

    func testDecryptsAPreSchema24BlobWithNoDomainPrefix() throws {
        let key = try fixtureKey()
        let blob = ChromeCookieTestCrypto.encrypt(
            value: sessionKey,
            hostKey: hostKey,
            key: key,
            includeDomainPrefix: false
        )

        XCTAssertEqual(
            try ChromeCookieCrypto.decryptCookieValue(
                encryptedValue: blob, hostKey: hostKey, key: key
            ),
            sessionKey
        )
    }

    func testStripsExactlyTheThirtyTwoByteDomainHashPrefix() throws {
        let key = try fixtureKey()
        let blob = ChromeCookieTestCrypto.encrypt(
            value: sessionKey,
            hostKey: hostKey,
            key: key,
            includeDomainPrefix: true
        )

        XCTAssertEqual(
            try ChromeCookieCrypto.decryptCookieValue(
                encryptedValue: blob, hostKey: hostKey, key: key
            ),
            sessionKey
        )
    }

    func testDoesNotStripThirtyTwoBytesThatAreNotTheDomainHash() throws {
        let key = try fixtureKey()
        // A plaintext long enough to be prefixed, whose first 32 bytes are
        // not this host's digest. Stripping here would silently corrupt the
        // value. (Printable bytes, so the "is it UTF-8" check is not what
        // this test ends up measuring.)
        let decoy = Data(String(repeating: "A", count: 32).utf8)
        let plaintext = decoy + Data(sessionKey.utf8)
        let blob = ChromeCookieCrypto.versionPrefix
            + ChromeCookieTestCrypto.encryptRaw(plaintext: plaintext, key: key)

        let decrypted = try ChromeCookieCrypto.decryptCookieValue(
            encryptedValue: blob, hostKey: hostKey, key: key
        )

        XCTAssertEqual(decrypted.count, plaintext.count)
        XCTAssertTrue(decrypted.hasSuffix(sessionKey))
    }

    // MARK: Fail-closed paths

    func testWrongPassphraseFailsInsteadOfReturningCorruptedText() throws {
        let blob = ChromeCookieTestCrypto.encrypt(
            value: sessionKey,
            hostKey: hostKey,
            key: try fixtureKey(),
            includeDomainPrefix: true
        )
        let wrongKey = try ChromeCookieCrypto.deriveKey(
            passphrase: Data("peanuts".utf8)
        )

        XCTAssertThrowsError(
            try ChromeCookieCrypto.decryptCookieValue(
                encryptedValue: blob, hostKey: hostKey, key: wrongKey
            )
        ) { error in
            XCTAssertEqual(error as? ChromeCookieReadError, .decryptFailed)
        }
    }

    func testRejectsEveryVersionPrefixOtherThanV10() throws {
        let key = try fixtureKey()
        let payload = ChromeCookieTestCrypto.encryptRaw(
            plaintext: Data(sessionKey.utf8), key: key
        )

        for prefix in ["v11", "v20", "v99"] {
            XCTAssertThrowsError(
                try ChromeCookieCrypto.decryptCookieValue(
                    encryptedValue: Data(prefix.utf8) + payload,
                    hostKey: hostKey,
                    key: key
                ),
                prefix
            ) { error in
                XCTAssertEqual(
                    error as? ChromeCookieReadError, .unknownEncryptionVersion
                )
            }
        }

        // No prefix at all, and a blob that is nothing but a prefix.
        XCTAssertThrowsError(
            try ChromeCookieCrypto.decryptCookieValue(
                encryptedValue: payload, hostKey: hostKey, key: key
            )
        ) { error in
            XCTAssertEqual(
                error as? ChromeCookieReadError, .unknownEncryptionVersion
            )
        }
        XCTAssertThrowsError(
            try ChromeCookieCrypto.decryptCookieValue(
                encryptedValue: ChromeCookieCrypto.versionPrefix,
                hostKey: hostKey,
                key: key
            )
        ) { error in
            XCTAssertEqual(
                error as? ChromeCookieReadError, .unknownEncryptionVersion
            )
        }
    }

    func testNonUTF8PlaintextFailsRatherThanReturningRubbish() throws {
        let key = try fixtureKey()
        let blob = ChromeCookieCrypto.versionPrefix
            + ChromeCookieTestCrypto.encryptRaw(
                plaintext: Data([0xFF, 0xFE, 0xFD, 0xFC]), key: key
            )

        XCTAssertThrowsError(
            try ChromeCookieCrypto.decryptCookieValue(
                encryptedValue: blob, hostKey: hostKey, key: key
            )
        ) { error in
            XCTAssertEqual(error as? ChromeCookieReadError, .decryptFailed)
        }
    }

    // MARK: Time

    func testChromeTimestampsRoundTripThroughTheFiletimeEpoch() {
        XCTAssertEqual(
            ChromeCookieTime.microseconds(from: Date(timeIntervalSince1970: 0)),
            11_644_473_600_000_000
        )
        XCTAssertEqual(
            ChromeCookieTime.date(fromMicroseconds: 11_644_473_600_000_000),
            Date(timeIntervalSince1970: 0)
        )

        let sample = Date(timeIntervalSince1970: 1_767_225_600)
        XCTAssertEqual(
            ChromeCookieTime.date(
                fromMicroseconds: ChromeCookieTime.microseconds(from: sample)
            ).timeIntervalSince1970,
            sample.timeIntervalSince1970,
            accuracy: 0.001
        )
    }
}
