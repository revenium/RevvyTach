//
//  ChromeCookieSessionKeyService.swift
//  Claude Usage
//
//  Reads the claude.ai `sessionKey` cookie out of one Chrome profile, and
//  only ever after the user has explicitly pressed "Read from Chrome" and
//  approved the macOS prompt that follows.
//
//  Three properties are load-bearing and must survive every future edit:
//
//  1. The macOS Keychain prompt is raised only once a decryptable claude.ai
//     session cookie is already in hand. A profile that never signed in to
//     claude.ai, or whose cookie is unencrypted, sees no prompt at all.
//  2. The temporary copy of the cookie database is unlinked on every
//     in-process exit path (`defer`, placed before the first throwing
//     statement that follows the copy), and `ChromeCookieTempCopySweeper`
//     clears anything a crash stranded.
//  3. Nothing here logs, returns, or embeds in an error the Chrome Safe
//     Storage passphrase, the derived key, the ciphertext, or the plaintext.
//     `LoggingService.emit` logs `%{public}@`, so silence is the defence.
//

import CommonCrypto
import CryptoKit
import Darwin
import Foundation
import SQLite3
import Security

// MARK: - Errors

/// Every failure mode of a Chrome cookie read. No case carries secret bytes:
/// the UI maps the case to a fixed localized string (never `localizedDescription`),
/// and the reader logs the case name alone.
nonisolated enum ChromeCookieReadError: Error, Equatable {
    case invalidProfile
    case cookieDatabaseMissing
    /// SQLITE_BUSY/SQLITE_LOCKED even against the private copy.
    case databaseLocked
    /// Open/prepare/step failed for any other reason, including a schema so
    /// old that the hardened statement cannot be prepared. Never relaxed.
    case databaseUnreadable
    case keychainAccessDenied
    case keychainItemMissing
    case keychainReadFailed(OSStatus)
    /// The blob does not carry the `v10` prefix this version understands.
    case unknownEncryptionVersion
    case sessionCookieMissing
    /// Padding, UTF-8, cipher or shape failure — usually the wrong key.
    case decryptFailed
    case tempCopyFailed

    /// The only thing about an error that is ever logged. Deliberately drops
    /// `keychainReadFailed`'s status code: it tells a user nothing the case
    /// name does not, and every logged string in this app is public.
    var outcomeName: String {
        switch self {
        case .invalidProfile: return "invalidProfile"
        case .cookieDatabaseMissing: return "cookieDatabaseMissing"
        case .databaseLocked: return "databaseLocked"
        case .databaseUnreadable: return "databaseUnreadable"
        case .keychainAccessDenied: return "keychainAccessDenied"
        case .keychainItemMissing: return "keychainItemMissing"
        case .keychainReadFailed: return "keychainReadFailed"
        case .unknownEncryptionVersion: return "unknownEncryptionVersion"
        case .sessionCookieMissing: return "sessionCookieMissing"
        case .decryptFailed: return "decryptFailed"
        case .tempCopyFailed: return "tempCopyFailed"
        }
    }
}

// MARK: - Crypto

/// Chrome's macOS cookie encryption, as a pure function of its inputs.
///
/// Parameters verified against Chromium's `components/os_crypt/sync/
/// os_crypt_mac.mm`: PBKDF2-HMAC-SHA1 over the *stored* Keychain string's
/// bytes, salt `saltysalt`, 1003 iterations, 16-byte key, AES-128-CBC with
/// PKCS#7 and an IV of sixteen `0x20` bytes.
nonisolated enum ChromeCookieCrypto {
    /// macOS today. `v11` is a Linux artifact and `v20` is Windows
    /// app-bound encryption; both fail closed (see `decryptCookieValue`).
    static let versionPrefix = Data("v10".utf8)
    static let salt = Data("saltysalt".utf8)
    /// 1003 on macOS. Linux uses 1; using 1 here derives the wrong key.
    static let iterations: UInt32 = 1003
    static let keyLength = 16
    static let iv = Data(repeating: 0x20, count: 16)

    /// PBKDF2 over the passphrase bytes **exactly as the Keychain returned
    /// them**. Chrome stores a base64-looking string and hashes that string's
    /// UTF-8 bytes; base64-decoding it first silently derives the wrong key.
    static func deriveKey(passphrase: Data) throws -> Data {
        guard !passphrase.isEmpty else {
            throw ChromeCookieReadError.decryptFailed
        }
        var derived = Data(count: keyLength)
        let status: Int32 = derived.withUnsafeMutableBytes { derivedBuffer in
            passphrase.withUnsafeBytes { passphraseBuffer in
                salt.withUnsafeBytes { saltBuffer in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passphraseBuffer.baseAddress?
                            .assumingMemoryBound(to: CChar.self),
                        passphrase.count,
                        saltBuffer.baseAddress?
                            .assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        iterations,
                        derivedBuffer.baseAddress?
                            .assumingMemoryBound(to: UInt8.self),
                        keyLength
                    )
                }
            }
        }
        guard status == Int32(kCCSuccess) else {
            throw ChromeCookieReadError.decryptFailed
        }
        return derived
    }

    /// Decrypts one `v10` blob and strips the schema-24 domain-hash prefix if
    /// it is there.
    ///
    /// The prefix is detected by digest match rather than by reading the
    /// database's schema version: that is correct on both pre-24 and 24+
    /// jars, and it cannot over-strip, because a real session key never
    /// begins with the SHA-256 of its own host key.
    static func decryptCookieValue(
        encryptedValue: Data,
        hostKey: String,
        key: Data
    ) throws -> String {
        guard encryptedValue.count > versionPrefix.count,
              encryptedValue.prefix(versionPrefix.count) == versionPrefix else {
            throw ChromeCookieReadError.unknownEncryptionVersion
        }
        let ciphertext = Data(encryptedValue.dropFirst(versionPrefix.count))
        guard !ciphertext.isEmpty,
              ciphertext.count % kCCBlockSizeAES128 == 0,
              key.count == keyLength else {
            throw ChromeCookieReadError.decryptFailed
        }

        var plaintext = Data(count: ciphertext.count + kCCBlockSizeAES128)
        var moved = 0
        let status: Int32 = plaintext.withUnsafeMutableBytes { output in
            ciphertext.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBuffer in
                    iv.withUnsafeBytes { ivBuffer in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBuffer.baseAddress,
                            keyBuffer.count,
                            ivBuffer.baseAddress,
                            input.baseAddress,
                            input.count,
                            output.baseAddress,
                            output.count,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == Int32(kCCSuccess), moved <= plaintext.count else {
            throw ChromeCookieReadError.decryptFailed
        }

        var value = Data(plaintext.prefix(moved))
        let digest = Data(SHA256.hash(data: Data(hostKey.utf8)))
        if value.count >= digest.count, value.prefix(digest.count) == digest {
            value = Data(value.dropFirst(digest.count))
        }
        guard let text = String(data: value, encoding: .utf8) else {
            throw ChromeCookieReadError.decryptFailed
        }
        return text
    }
}

// MARK: - Time

/// Chrome stores cookie timestamps as microseconds since 1601-01-01 UTC.
nonisolated enum ChromeCookieTime {
    /// Seconds between 1601-01-01 UTC and 1970-01-01 UTC.
    static let epochOffsetSeconds: Double = 11_644_473_600

    static func microseconds(from date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 + epochOffsetSeconds) * 1_000_000)
    }

    static func date(fromMicroseconds value: Int64) -> Date {
        Date(
            timeIntervalSince1970:
                Double(value) / 1_000_000 - epochOffsetSeconds
        )
    }
}

// MARK: - Row

nonisolated struct ChromeCookieRow: Equatable, Sendable {
    /// As stored, e.g. `.claude.ai` — the leading dot is part of the value
    /// the schema-24 domain hash is computed over.
    let hostKey: String
    let path: String
    let isSecure: Bool
    /// Microseconds since 1601-01-01 UTC. `0` means a session cookie.
    let expiresUTC: Int64
    let creationUTC: Int64
    let encryptedValue: Data
    let plaintextValue: String

    init(
        hostKey: String,
        path: String = "/",
        isSecure: Bool = true,
        expiresUTC: Int64 = 0,
        creationUTC: Int64 = 0,
        encryptedValue: Data = Data(),
        plaintextValue: String = ""
    ) {
        self.hostKey = hostKey
        self.path = path
        self.isSecure = isSecure
        self.expiresUTC = expiresUTC
        self.creationUTC = creationUTC
        self.encryptedValue = encryptedValue
        self.plaintextValue = plaintextValue
    }
}

// MARK: - Selection policy

/// The authority on which cookie row is used, mirroring the policy the
/// embedded sign-in already ships in
/// `ConsoleAuthWebView.Coordinator.sessionCookieResult`.
///
/// The same predicates are applied in SQL as well, so a large jar is filtered
/// by the query rather than materialised — but the query is a convenience.
/// This type is what tests and reviewers read, and what governs the merged
/// rows when a profile carries two cookie databases.
nonisolated enum ChromeCookieSelectionPolicy {
    static let name = "sessionKey"
    /// Chrome's domain-scoped form.
    static let exactHostKey = ".claude.ai"
    static let bareHostKey = "claude.ai"
    static let requiredPath = "/"

    static func select(
        _ rows: [ChromeCookieRow],
        nowChromeMicroseconds: Int64
    ) -> ChromeCookieRow? {
        rows.filter { row in
            (row.hostKey == exactHostKey || row.hostKey == bareHostKey)
                && row.path == requiredPath
                && row.isSecure
                && (row.expiresUTC == 0
                    || row.expiresUTC > nowChromeMicroseconds)
                && !(row.encryptedValue.isEmpty && row.plaintextValue.isEmpty)
        }
        .sorted(by: order)
        .first
    }

    /// A total order, so a duplicate pair never depends on SQLite row order:
    ///
    /// 1. `.claude.ai` before `claude.ai`.
    /// 2. Later `creation_utc` first. This deliberately outranks expiry.
    ///    The single-store precedent ranks session cookies first, but two
    ///    cookie databases can be merged here, and a stale jar's
    ///    session-shaped leftover would then beat the live jar's current
    ///    key. The most recently *issued* cookie is the live one; expiry is
    ///    a liveness filter, already applied above, not a recency signal.
    /// 3. Session cookies (`expires_utc == 0`) before dated ones.
    /// 4. Later `expires_utc` first.
    /// 5. Encrypted rows before unencrypted ones.
    /// 6. A byte-wise tiebreak, so the comparator is total.
    static func order(
        _ lhs: ChromeCookieRow,
        _ rhs: ChromeCookieRow
    ) -> Bool {
        let lhsIsExactHost = lhs.hostKey == exactHostKey
        let rhsIsExactHost = rhs.hostKey == exactHostKey
        if lhsIsExactHost != rhsIsExactHost { return lhsIsExactHost }

        if lhs.creationUTC != rhs.creationUTC {
            return lhs.creationUTC > rhs.creationUTC
        }

        let lhsIsSession = lhs.expiresUTC == 0
        let rhsIsSession = rhs.expiresUTC == 0
        if lhsIsSession != rhsIsSession { return lhsIsSession }

        if lhs.expiresUTC != rhs.expiresUTC {
            return lhs.expiresUTC > rhs.expiresUTC
        }

        let lhsIsEncrypted = !lhs.encryptedValue.isEmpty
        let rhsIsEncrypted = !rhs.encryptedValue.isEmpty
        if lhsIsEncrypted != rhsIsEncrypted { return lhsIsEncrypted }

        if lhs.encryptedValue != rhs.encryptedValue {
            return lhs.encryptedValue
                .lexicographicallyPrecedes(rhs.encryptedValue)
        }
        return lhs.plaintextValue < rhs.plaintextValue
    }
}

// MARK: - Filesystem seam

/// The filesystem boundary for the cookie read and the launch-time sweep,
/// deliberately narrower than `FileManager` and injectable in tests.
nonisolated struct ChromeCookieFilesystem: Sendable {
    let metadata: @Sendable (URL) -> ChromeProfileFileMetadata
    /// The sweeper's age check. `ChromeProfileFileMetadata` carries no date
    /// and is shared with profile discovery, so the seam lives here.
    let modificationDate: @Sendable (URL) -> Date?
    let createDirectory: @Sendable (URL) throws -> Void
    let copyItem: @Sendable (_ from: URL, _ to: URL) throws -> Void
    let makeUniqueTempDirectory: @Sendable () throws -> URL
    /// `[]` on failure — a directory that cannot be listed simply sweeps
    /// nothing.
    let contentsOfDirectory: @Sendable (URL) -> [URL]
    /// Best-effort and never throwing, so cleanup cannot mask a real error.
    let removeItem: @Sendable (URL) -> Void
    let currentUserID: @Sendable () -> UInt32

    static let live = Self(
        metadata: ChromeProfileFilesystem.live.metadata,
        modificationDate: { url in
            (try? FileManager.default.attributesOfItem(atPath: url.path))?[
                .modificationDate
            ] as? Date
        },
        createDirectory: { url in
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        },
        copyItem: { from, to in
            try FileManager.default.copyItem(at: from, to: to)
        },
        makeUniqueTempDirectory: {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(
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
        contentsOfDirectory: { url in
            (try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil
            )) ?? []
        },
        removeItem: { url in
            _ = try? FileManager.default.removeItem(at: url)
        },
        currentUserID: { UInt32(getuid()) }
    )
}

// MARK: - Reader

nonisolated struct ChromeCookieSessionKeyReader: Sendable {
    typealias KeychainPassphraseReader = @Sendable () throws -> Data
    typealias CookieRowReader = @Sendable (
        _ databaseCopy: URL,
        _ nowChromeMicroseconds: Int64
    ) throws -> [ChromeCookieRow]

    /// A sanity ceiling, per file, on the database and each sidecar. Real
    /// cookie jars are single-digit MB; this exists so a path that resolves
    /// to something absurd fails closed instead of filling `$TMPDIR`.
    static let maximumCookieFileSize = 256 * 1024 * 1024
    static let sidecarSuffixes = ["-wal", "-shm"]

    private let userDataDirectory: URL
    private let filesystem: ChromeCookieFilesystem
    private let readKeychainPassphrase: KeychainPassphraseReader
    private let readCookieRows: CookieRowReader
    private let now: @Sendable () -> Date
    private let logOutcome: @Sendable (String) -> Void

    init(
        userDataDirectory: URL = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Google/Chrome",
                isDirectory: true
            ),
        filesystem: ChromeCookieFilesystem = .live,
        readKeychainPassphrase: @escaping KeychainPassphraseReader =
            ChromeCookieSessionKeyReader.liveKeychainPassphrase,
        readCookieRows: @escaping CookieRowReader =
            ChromeCookieSessionKeyReader.liveCookieRowReader,
        now: @escaping @Sendable () -> Date = Date.init,
        // `LoggingService` is a plain `final class`, so under
        // SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor it is MainActor-isolated.
        // This reader runs off the main actor, so the default hops rather
        // than touching it directly.
        logOutcome: @escaping @Sendable (String) -> Void = { message in
            Task { @MainActor in LoggingService.shared.log(message) }
        }
    ) {
        self.userDataDirectory = userDataDirectory
        self.filesystem = filesystem
        self.readKeychainPassphrase = readKeychainPassphrase
        self.readCookieRows = readCookieRows
        self.now = now
        self.logOutcome = logOutcome
    }

    /// The one public entry point. It blocks on the macOS password prompt, so
    /// callers MUST invoke it off the main queue; the wizard wraps it in a
    /// `withCheckedContinuation` over a global queue.
    ///
    /// Emits exactly one outcome line — never a value, a path or an
    /// `OSStatus` — and rethrows.
    func readSessionKey(profileDirectoryName: String) throws -> String {
        // A refactor that puts this back on the main queue would freeze the
        // wizard behind the system password dialog. Fail loudly in Debug.
        dispatchPrecondition(condition: .notOnQueue(.main))
        do {
            let key = try perform(profileDirectoryName: profileDirectoryName)
            logOutcome("chrome cookie read: success")
            return key
        } catch let error as ChromeCookieReadError {
            logOutcome("chrome cookie read: \(error.outcomeName)")
            throw error
        } catch {
            logOutcome("chrome cookie read: unexpected")
            throw error
        }
    }

    // MARK: The ordered steps

    private func perform(profileDirectoryName: String) throws -> String {
        guard ChromeProfilePathPolicy.isValidDirectoryName(
            profileDirectoryName
        ) else {
            throw ChromeCookieReadError.invalidProfile
        }

        // Step 1. Find the databases. Nothing has been copied and no prompt
        // has been raised.
        let profileDirectory = userDataDirectory.appendingPathComponent(
            profileDirectoryName,
            isDirectory: true
        )
        let candidates = [
            (
                slot: "network",
                url: profileDirectory
                    .appendingPathComponent("Network", isDirectory: true)
                    .appendingPathComponent("Cookies", isDirectory: false)
            ),
            (
                slot: "legacy",
                url: profileDirectory
                    .appendingPathComponent("Cookies", isDirectory: false)
            ),
        ].filter { isSafeFile($0.url) }
        guard !candidates.isEmpty else {
            throw ChromeCookieReadError.cookieDatabaseMissing
        }

        // Step 2. Create the private copy directory and arm its unlink before
        // anything below can throw.
        let temporaryDirectory: URL
        do {
            temporaryDirectory = try filesystem.makeUniqueTempDirectory()
        } catch {
            throw ChromeCookieReadError.tempCopyFailed
        }
        defer { filesystem.removeItem(temporaryDirectory) }

        // Step 3. Copy and query each database. One unreadable slot must not
        // veto a healthy one, so per-slot failures are collected and only
        // surfaced when no candidate row survives.
        let nowChromeMicroseconds = ChromeCookieTime.microseconds(from: now())
        var rows: [ChromeCookieRow] = []
        var firstSlotError: ChromeCookieReadError?
        for candidate in candidates {
            do {
                rows += try readSlot(
                    slot: candidate.slot,
                    source: candidate.url,
                    temporaryDirectory: temporaryDirectory,
                    nowChromeMicroseconds: nowChromeMicroseconds
                )
            } catch let error as ChromeCookieReadError {
                if firstSlotError == nil { firstSlotError = error }
            }
        }

        // Step 4. Choose one row. Still no prompt: a profile that never
        // signed in to claude.ai stops here.
        guard let row = ChromeCookieSelectionPolicy.select(
            rows,
            nowChromeMicroseconds: nowChromeMicroseconds
        ) else {
            throw firstSlotError ?? ChromeCookieReadError.sessionCookieMissing
        }

        // Step 5. Only now, and only for an encrypted row, ask macOS for
        // Chrome's key. This is the call that raises the consented prompt.
        let value: String
        if row.encryptedValue.isEmpty {
            value = row.plaintextValue
        } else {
            value = try decrypt(row)
        }

        // Step 6. Shape-check without echoing. The validator's error is
        // discarded on purpose: `invalidCharacters` quotes the offending
        // characters, and a mis-decrypted blob must never reach the screen.
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (try? SessionKeyValidator().validate(trimmed)) != nil else {
            throw ChromeCookieReadError.decryptFailed
        }
        return trimmed
    }

    private func decrypt(_ row: ChromeCookieRow) throws -> String {
        var passphrase = try readKeychainPassphrase()
        defer { passphrase.resetBytes(in: 0..<passphrase.count) }
        var key = try ChromeCookieCrypto.deriveKey(passphrase: passphrase)
        defer { key.resetBytes(in: 0..<key.count) }
        return try ChromeCookieCrypto.decryptCookieValue(
            encryptedValue: row.encryptedValue,
            hostKey: row.hostKey,
            key: key
        )
    }

    private func readSlot(
        slot: String,
        source: URL,
        temporaryDirectory: URL,
        nowChromeMicroseconds: Int64
    ) throws -> [ChromeCookieRow] {
        let slotDirectory = temporaryDirectory.appendingPathComponent(
            slot,
            isDirectory: true
        )
        let destination = slotDirectory.appendingPathComponent(
            "Cookies",
            isDirectory: false
        )
        do {
            try filesystem.createDirectory(slotDirectory)
            try filesystem.copyItem(source, destination)
        } catch {
            throw ChromeCookieReadError.tempCopyFailed
        }

        // A missing sidecar is normal (the database was checkpointed). One
        // that exists but fails a safety check aborts: proceeding without a
        // WAL the database needs either fails to open or reads a stale jar,
        // and neither is acceptable for a credential read.
        for suffix in Self.sidecarSuffixes {
            let sidecar = URL(fileURLWithPath: source.path + suffix)
            guard filesystem.metadata(sidecar).exists else { continue }
            guard isSafeFile(sidecar) else {
                throw ChromeCookieReadError.tempCopyFailed
            }
            do {
                try filesystem.copyItem(
                    sidecar,
                    URL(fileURLWithPath: destination.path + suffix)
                )
            } catch {
                throw ChromeCookieReadError.tempCopyFailed
            }
        }

        return try readCookieRows(destination, nowChromeMicroseconds)
    }

    private func isSafeFile(_ url: URL) -> Bool {
        let metadata = filesystem.metadata(url)
        return metadata.exists
            && metadata.isRegularFile
            && !metadata.isSymbolicLink
            && metadata.ownerUserID == filesystem.currentUserID()
            && (metadata.size ?? Int.max) <= Self.maximumCookieFileSize
    }

    // MARK: Live boundaries

    /// The in-process Keychain read. `/usr/bin/security` is deliberately not
    /// used: Chrome's item ACL trusts Chrome, so an in-process
    /// `SecItemCopyMatching` is exactly what raises the consented macOS
    /// prompt offering Allow / Always Allow / Deny.
    static func liveKeychainPassphrase() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Chrome Safe Storage",
            kSecAttrAccount as String: "Chrome",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        // No UI-suppression key is set, so the system shows its own prompt.
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, !data.isEmpty else {
                throw ChromeCookieReadError.keychainReadFailed(status)
            }
            return data
        case errSecItemNotFound:
            throw ChromeCookieReadError.keychainItemMissing
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            throw ChromeCookieReadError.keychainAccessDenied
        default:
            throw ChromeCookieReadError.keychainReadFailed(status)
        }
    }

    /// The hardened statement. Its predicates mirror
    /// `ChromeCookieSelectionPolicy` exactly, and it is never relaxed: if it
    /// cannot be prepared (a column missing on an ancient schema, say) the
    /// read fails closed rather than retrying without `is_secure`, `path`,
    /// or the expiry filter.
    static let cookieQuery = """
        SELECT host_key, path, is_secure, expires_utc, creation_utc,
               encrypted_value, value
        FROM cookies
        WHERE name = ?1
          AND (host_key = ?2 OR host_key = ?3)
          AND path = '/'
          AND is_secure = 1
          AND (expires_utc = 0 OR expires_utc > ?4)
        ORDER BY (host_key = ?2) DESC,
                 creation_utc DESC,
                 (expires_utc = 0) DESC,
                 expires_utc DESC
        """

    static func liveCookieRowReader(
        databaseCopy: URL,
        nowChromeMicroseconds: Int64
    ) throws -> [ChromeCookieRow] {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            databaseCopy.path,
            &handle,
            SQLITE_OPEN_READONLY,
            nil
        ) == SQLITE_OK, let database = handle else {
            sqlite3_close(handle)
            throw ChromeCookieReadError.databaseUnreadable
        }
        defer { sqlite3_close(database) }
        // A transient lock surfaces as `.databaseLocked` rather than hanging
        // the background read.
        sqlite3_busy_timeout(database, 250)

        var statementHandle: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            cookieQuery,
            -1,
            &statementHandle,
            nil
        ) == SQLITE_OK, let statement = statementHandle else {
            sqlite3_finalize(statementHandle)
            throw ChromeCookieReadError.databaseUnreadable
        }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(
            -1,
            to: sqlite3_destructor_type.self
        )
        sqlite3_bind_text(
            statement, 1, ChromeCookieSelectionPolicy.name, -1, transient
        )
        sqlite3_bind_text(
            statement, 2, ChromeCookieSelectionPolicy.exactHostKey, -1,
            transient
        )
        sqlite3_bind_text(
            statement, 3, ChromeCookieSelectionPolicy.bareHostKey, -1,
            transient
        )
        sqlite3_bind_int64(statement, 4, nowChromeMicroseconds)

        var rows: [ChromeCookieRow] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                rows.append(makeRow(statement))
            case SQLITE_DONE:
                return rows
            case SQLITE_BUSY, SQLITE_LOCKED:
                throw ChromeCookieReadError.databaseLocked
            default:
                throw ChromeCookieReadError.databaseUnreadable
            }
        }
    }

    private static func makeRow(_ statement: OpaquePointer) -> ChromeCookieRow {
        func text(_ index: Int32) -> String {
            guard let pointer = sqlite3_column_text(statement, index) else {
                return ""
            }
            let count = Int(sqlite3_column_bytes(statement, index))
            return String(
                decoding: UnsafeBufferPointer(start: pointer, count: count),
                as: UTF8.self
            )
        }
        var encrypted = Data()
        if let bytes = sqlite3_column_blob(statement, 5) {
            let count = Int(sqlite3_column_bytes(statement, 5))
            if count > 0 {
                encrypted = Data(bytes: bytes, count: count)
            }
        }
        return ChromeCookieRow(
            hostKey: text(0),
            path: text(1),
            isSecure: sqlite3_column_int64(statement, 2) != 0,
            expiresUTC: sqlite3_column_int64(statement, 3),
            creationUTC: sqlite3_column_int64(statement, 4),
            encryptedValue: encrypted,
            plaintextValue: text(6)
        )
    }
}

// MARK: - Crash sweep

/// `defer` covers a normal return, a thrown error, and task cancellation, but
/// not `SIGKILL`, an uncaught trap, or `exit()`. A crash between the copy and
/// its unlink would strand a complete copy of a Chrome profile's cookie jar
/// in `$TMPDIR` until reboot, so launch sweeps what this feature owns.
///
/// Modelled on `AtomicJSONFileStore.sweepStaleArtifacts(now:)`: match a
/// naming convention this feature owns, check ownership, apply a retention
/// window, and remove best-effort so one stuck entry cannot abort the pass.
nonisolated enum ChromeCookieTempCopySweeper {
    /// Every temp copy this feature makes carries this prefix, directly
    /// inside `FileManager.default.temporaryDirectory`.
    static let directoryPrefix = "revvytach-chrome-"

    /// One hour. A read finishes in seconds; the only thing that stretches it
    /// is the user leaving the macOS password prompt on screen. An hour is
    /// far past that and far short of the multi-day `$TMPDIR` reap this
    /// exists to beat. Unlinking a directory whose database is still open is
    /// harmless on macOS — the open descriptor survives the unlink.
    static let retention: TimeInterval = 60 * 60

    static func sweep(
        baseDirectory: URL = FileManager.default.temporaryDirectory,
        filesystem: ChromeCookieFilesystem = .live,
        now: Date = Date()
    ) {
        for entry in filesystem.contentsOfDirectory(baseDirectory) {
            guard entry.lastPathComponent.hasPrefix(directoryPrefix) else {
                continue
            }
            let metadata = filesystem.metadata(entry)
            guard metadata.exists,
                  metadata.isDirectory,
                  !metadata.isSymbolicLink,
                  metadata.ownerUserID == filesystem.currentUserID() else {
                continue
            }
            guard let modified = filesystem.modificationDate(entry),
                  now.timeIntervalSince(modified) > retention else {
                continue
            }
            filesystem.removeItem(entry)
        }
    }
}
