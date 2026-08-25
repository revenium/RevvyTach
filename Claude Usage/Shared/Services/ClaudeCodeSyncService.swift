//
//  ClaudeCodeSyncService.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-01-07.
//

import CryptoKit
import Foundation
import Security

/// The outcome of one `/usr/bin/security` invocation.
struct SecurityCommandResult {
    let exitCode: Int32

    /// `nil` when the process wrote bytes that are not valid UTF-8.
    ///
    /// Deliberately distinct from `""`. A Keychain item whose secret is
    /// binary — corrupted, or written by some other tool — is *unreadable*,
    /// not *empty*, and `readKeychainCredentials` has to answer `nil` for it
    /// so the user is told to log in rather than told their credentials are
    /// corrupt. Coalescing the decode failure to an empty string here sends
    /// it down the JSON-validation path instead and inverts that message.
    let standardOutput: String?

    /// Diagnostics only, so an undecodable byte here is worth nothing and
    /// coalescing it to empty costs nothing.
    let standardError: String
}

/// Seam over `/usr/bin/security`.
///
/// The credential write path is the one place in this app that can destroy a
/// user's Claude Code login, so it has to be exercisable in tests without
/// touching the real login Keychain.
protocol SecurityCommandRunning {
    func run(_ arguments: [String]) throws -> SecurityCommandResult
}

/// Production runner.
///
/// Both pipes are drained *concurrently*, then joined before
/// `waitUntilExit()`. Draining them one after another deadlocks as soon as
/// the child fills a pipe buffer, and the credential blobs on this path
/// routinely run to several kilobytes.
struct SecurityCLIRunner: SecurityCommandRunning {
    /// Boxes the stderr read so it can cross the background-queue boundary;
    /// the `sync` barrier below guarantees exclusive access before it's read.
    private final class ErrorReadBox: @unchecked Sendable {
        var data = Data()
    }

    func run(_ arguments: [String]) throws -> SecurityCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()

        // Drain stderr on a background queue while stdout drains on this
        // thread, so neither pipe's buffer can back up and stall the child.
        let errorBox = ErrorReadBox()
        let errorQueue = DispatchQueue(label: "com.claudeusage.securityclirunner.stderr")
        errorQueue.async {
            errorBox.data = errorPipe.fileHandleForReading.readDataToEndOfFile()
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        errorQueue.sync {}
        process.waitUntilExit()

        return SecurityCommandResult(
            exitCode: process.terminationStatus,
            standardOutput: String(data: outputData, encoding: .utf8),
            standardError: String(data: errorBox.data, encoding: .utf8) ?? ""
        )
    }
}

/// Manages synchronization of Claude Code CLI credentials between system Keychain and profiles
class ClaudeCodeSyncService {
    static let shared = ClaudeCodeSyncService()

    /// Exit code `security` uses for "the item is not in the keychain".
    private static let itemNotFoundExitCode: Int32 = 44

    /// Exit code `security` uses for "an item with those attributes already exists".
    private static let duplicateItemExitCode: Int32 = 45

    /// Cached resolved keychain service name (cleared per app session).
    ///
    /// Only ever holds a name that was actually *found*. A lookup that finds
    /// nothing must not be cached: it would pin the whole process lifetime to
    /// the legacy name even after the CLI writes its real item.
    private var resolvedServiceName: String?
    private let profileStore: ProfileStore
    private let systemCredentialsReader: (() throws -> String?)?
    private let securityRunner: SecurityCommandRunning

    init(
        profileStore: ProfileStore = .shared,
        systemCredentialsReader: (() throws -> String?)? = nil,
        securityRunner: SecurityCommandRunning = SecurityCLIRunner()
    ) {
        self.profileStore = profileStore
        self.systemCredentialsReader = systemCredentialsReader
        self.securityRunner = securityRunner
    }

    // MARK: - System Credentials Access (Fallback Chain)

    /// Reads Claude Code credentials using a fallback chain:
    /// 1. ~/.claude/.credentials.json, but only when its login is unexpired —
    ///    an expired file login is held back rather than returned here
    /// 2. System Keychain (may be truncated for large payloads >2KB)
    /// 3. Regex extraction of accessToken from truncated keychain data
    /// 4. The held-back expired file login from step 1, as the true last resort
    func readSystemCredentials(
        forAccountNamed accountName: String? = nil
    ) throws -> String? {
        if let systemCredentialsReader {
            return try systemCredentialsReader()
        }

        // 1. Try credentials file first (most reliable) — but only when its
        // login actually pre-empts the Keychain. A file login that has
        // itself gone stale must not win here just for being first in the
        // chain: it is held back as a last resort (below) so the Keychain,
        // which Claude Code keeps current, gets a real look first.
        let fileLogin = readCredentialsFile(forAccountNamed: accountName)
        if let fileLogin, fileLoginPreemptsKeychain(fileLogin) {
            LoggingService.shared.log("Read credentials from .credentials.json file")
            return fileLogin
        } else if let fileLogin {
            LoggingService.shared.log(
                "The credentials file holds an expired login; holding it "
                + "back in favor of the Keychain rather than returning it "
                + "as the answer"
            )
        }
        // Held back rather than discarded — the last-resort returns below
        // hand it back if the Keychain turns out to have nothing better.
        let expiredFileFallback = fileLogin

        // 2. Try keychain
        //
        // A thrown Keychain read (e.g. the `security` process failing to
        // launch) must not turn into "no login found" when an expired file
        // login is available as the documented last resort — that would
        // regress from "expired login" to "no login at all", the exact
        // outcome this fallback chain exists to avoid.
        let keychainData: String?
        do {
            keychainData = try readKeychainCredentials(
                forAccountNamed: accountName
            )
        } catch {
            // Only fall back when there is something to fall back to. With
            // no held file login, this rethrow preserves today's behavior
            // for both callers that key off a thrown error here:
            // `resyncBeforeSwitching` treats `nil` as "nothing found, skip
            // silently" and `syncCredentials` turns `nil` into
            // `.noCredentialsFound` ("not signed in") — neither should
            // absorb a genuine Keychain failure as if it were simply absent.
            guard let expiredFileFallback else { throw error }
            LoggingService.shared.log(
                "Keychain read threw for account "
                + "'\(accountName ?? "default")': \(error). Falling back to "
                + "the held file login rather than reporting no login found"
            )
            return expiredFileFallback
        }

        guard let rawJSON = keychainData else {
            // No credentials in the Keychain. An expired file login is still
            // better than nothing — it is the last resort, not the first
            // choice — so behavior never regresses from "expired login" to
            // "no login at all".
            return expiredFileFallback
        }

        // 3. Validate keychain JSON, and that it actually holds a login.
        //
        // Syntactic validity was the only check here, which is how an item
        // carrying `claudeAiOauth` with an empty `accessToken` — the shape
        // Claude Code leaves behind for a configuration directory with no
        // login — was imported over a working credential. Falling back to
        // the expired file login sends the caller down the "no login found"
        // path only when there is truly nothing else to offer.
        if let data = rawJSON.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any] {
            guard Self.containsClaudeCodeLogin(object) else {
                LoggingService.shared.log(
                    "The Keychain login for account "
                    + "'\(accountName ?? "default")' holds no Claude Code "
                    + "token; treating it as absent rather than importing a "
                    + "credential that cannot authenticate"
                )
                return expiredFileFallback
            }
            return rawJSON
        }

        // 4. Keychain data is truncated/invalid — try regex extraction
        LoggingService.shared.log("Keychain JSON is invalid (likely truncated), attempting regex extraction")
        if let token = extractAccessTokenViaRegex(from: rawJSON) {
            let minimalJSON = "{\"claudeAiOauth\":{\"accessToken\":\"\(token)\"}}"
            LoggingService.shared.log("Built minimal credentials from regex-extracted token")
            return minimalJSON
        }

        // 5. All attempts failed — except an expired file login remains a
        // valid last resort; only throw once that too is unavailable.
        if let expiredFileFallback {
            return expiredFileFallback
        }
        throw ClaudeCodeError.invalidJSON
    }

    // MARK: - Private Credential Sources

    /// Whether a decoded credentials file actually carries a Claude Code
    /// login, as opposed to merely being well-formed JSON.
    ///
    /// `.credentials.json` is shared with other features: an installation
    /// with only MCP server logins has one containing just `mcpOAuth` and no
    /// account at all. Treating "parses as JSON" as "is a login" made the
    /// file win over the Keychain, so every profile stored a credential with
    /// no token in it and every member-scoped request was skipped.
    static func containsClaudeCodeLogin(_ object: [String: Any]) -> Bool {
        guard
            let oauth = object["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String,
            !token.isEmpty
        else { return false }
        return true
    }

    /// Whether a credentials file's login may pre-empt the Keychain.
    ///
    /// A file that parses and carries a login is not automatically the
    /// better source: the per-account file is a snapshot Claude Code does
    /// not keep current the way it keeps the Keychain item current, so a
    /// file can sit expired for weeks while the Keychain a step below it
    /// holds a login that is valid the same day. Measured on a real machine:
    /// file logins expired 5 and 7 August, Keychain logins for the same
    /// accounts valid on the day they were checked. Returning `true` here
    /// used to be "parses and has a login"; that let a stale file win over a
    /// current Keychain and left the account reporting a false sign-out.
    ///
    /// This predicate is also the seam a unit test can exercise: the real
    /// chain in `readSystemCredentials` touches both the filesystem and the
    /// Keychain, neither of which a test can stage, so the tested surface is
    /// this pure function rather than the chain around it — using it from
    /// both `readCredentialsFile` and `readSystemCredentials` keeps the
    /// tested predicate and the one actually deciding from drifting apart.
    /// The last-resort path this predicate enables — falling back to an
    /// expired file login when the Keychain has nothing — is NOT covered by
    /// a unit test: it needs a real filesystem and a real Keychain, neither
    /// of which this test target can fabricate.
    func fileLoginPreemptsKeychain(_ json: String) -> Bool {
        guard
            let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            Self.containsClaudeCodeLogin(object)
        else { return false }
        return !isTokenExpired(json)
    }

    /// Whether a credential blob is safe to store against a profile.
    ///
    /// The one rule every import path shares: never replace a stored
    /// credential with one that cannot authenticate. `readSystemCredentials`
    /// already filters the ordinary case, but it can be bypassed — an
    /// injected reader in tests, the truncated-Keychain regex fallback, a
    /// credential handed in by a caller — and the cost of getting this wrong
    /// is a working login destroyed and an error message whose advised
    /// remedy reproduces the problem.
    static func carriesLogin(_ credentialsJSON: String) -> Bool {
        guard
            let data = credentialsJSON.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else { return false }
        return containsClaudeCodeLogin(object)
    }

    /// Reads credentials from ~/.claude/.credentials.json or ~/.claude/credentials.json file.
    ///
    /// Returns whatever login the file holds — expired or not — and rules on
    /// none of it: whether that login is allowed to pre-empt the Keychain is
    /// `readSystemCredentials`'s call, not this function's. This function
    /// used to return an expired login indistinguishably from a fresh one,
    /// and the chain accepted it, used it, then discarded it as expired,
    /// while a valid Keychain login for the same account went unread.
    private func readCredentialsFile(
        forAccountNamed accountName: String? = nil
    ) -> String? {
        // A linked account keeps its own configuration directory, so its
        // credentials file is the one that describes it. Only fall back to
        // the shared directory when no account is named.
        let directory = accountName.map {
            Self.configurationDirectory(forAccountNamed: $0)
        } ?? Constants.ClaudePaths.claudeDirectory
        let paths = [
            directory.appendingPathComponent(".credentials.json"),
            directory.appendingPathComponent("credentials.json")
        ]

        for fileURL in paths {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }

            guard let data = try? Data(contentsOf: fileURL),
                  let jsonString = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !jsonString.isEmpty else {
                LoggingService.shared.log("credentials file exists but could not be read: \(fileURL.lastPathComponent)")
                continue
            }

            // Validate it's actually valid JSON
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                LoggingService.shared.log("credentials file contains invalid JSON: \(fileURL.lastPathComponent)")
                continue
            }

            // Being valid JSON is not enough. This file is shared with other
            // features — an installation with only MCP server logins has a
            // `.credentials.json` holding just `mcpOAuth`, with no Claude
            // Code login in it at all. Accepting that as the credential shed
            // the account silently: the profile looked linked, the stored
            // credential carried no token, and every member-scoped request
            // was skipped for the life of the install. The Keychain below is
            // the real source, so anything without a login must fall through
            // to it rather than short-circuit the chain.
            guard Self.containsClaudeCodeLogin(object) else {
                LoggingService.shared.log(
                    "credentials file \(fileURL.lastPathComponent) holds no "
                    + "Claude Code login; falling through to the Keychain"
                )
                continue
            }

            return jsonString
        }

        return nil
    }

    /// Reads Claude Code credentials from system Keychain using security command.
    ///
    /// This one stays on the `security` CLI rather than `SecItemCopyMatching`:
    /// the item's ACL trusts `/usr/bin/security`, which wrote it, so reading it
    /// from inside this app would raise a Keychain access prompt.
    ///
    /// Not `private`: `readSystemCredentials` reaches it only after the
    /// credentials file misses, which on a developer machine depends on
    /// whether `~/.claude/.credentials.json` happens to exist. Tests address
    /// it directly so their coverage of the failure codes does not vary by
    /// machine.
    func readKeychainCredentials(
        forAccountNamed accountName: String? = nil
    ) throws -> String? {
        let serviceName: String
        if let accountName, !accountName.isEmpty {
            // A named account's Keychain item is that account's login, full
            // stop. Falling through to `resolveServiceName()` here — the
            // shared/legacy item — used to hand back whichever account last
            // wrote it, which authenticated requests as the wrong account
            // and let a sync persist that account's credential into this
            // one's profile. `readCredentialsFile(forAccountNamed:)` never
            // had this problem: it already only falls back to the shared
            // directory when no account is named. This matches it.
            guard let accountSpecific = accountServiceName(forAccountNamed: accountName) else {
                return nil
            }
            serviceName = accountSpecific
        } else {
            serviceName = resolveServiceName()
        }
        return try readKeychainSecret(serviceName: serviceName)
    }

    /// Reads one named Keychain item, with no service-name resolution of its
    /// own.
    ///
    /// Split out of `readKeychainCredentials` because the rotation write-back
    /// has to read *the exact item it is about to overwrite*, which it names
    /// itself. Resolving the name a second way there would let the item that
    /// was checked and the item that gets written drift apart — the one
    /// mistake that would turn this repair into a way to destroy a login.
    private func readKeychainSecret(serviceName: String) throws -> String? {
        let result = try securityRunner.run([
            "find-generic-password",
            "-s", serviceName,
            "-a", NSUserName(),
            "-w"  // Print password only
        ])

        if result.exitCode == 0 {
            // Undecodable bytes read as absent, not as an empty credential:
            // letting `""` through would fail JSON validation upstream and
            // tell the user their credentials are corrupt, when the actionable
            // answer is that there is nothing here to read.
            guard let value = result.standardOutput else {
                LoggingService.shared.log(
                    "Keychain item is not valid UTF-8; treating as absent"
                )
                return nil
            }
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if result.exitCode == Self.itemNotFoundExitCode {
            return nil
        } else {
            let message = Self.describe(result)
            LoggingService.shared.log("Failed to read keychain: \(message)")
            throw ClaudeCodeError.keychainReadFailed(
                exitCode: result.exitCode,
                message: message
            )
        }
    }

    /// Renders a failed `security` invocation as something a support
    /// conversation can act on.
    ///
    /// The previous code threw `OSStatus(exitCode)`, which silently retyped a
    /// *process exit status* as a Security framework status — so every real
    /// failure surfaced as the uninformative "status: 1" and the CLI's own
    /// explanation, the only diagnostic that existed, was discarded.
    private static func describe(_ result: SecurityCommandResult) -> String {
        let stderr = result.standardError
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stderr.isEmpty else {
            return "security exited with code \(result.exitCode)"
        }
        return "security exited with code \(result.exitCode): \(stderr)"
    }

    /// Extracts accessToken from potentially truncated JSON using regex
    private func extractAccessTokenViaRegex(from rawString: String) -> String? {
        let pattern = "\"accessToken\"\\s*:\\s*\"([^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: rawString, range: NSRange(rawString.startIndex..., in: rawString)),
              let tokenRange = Range(match.range(at: 1), in: rawString) else {
            return nil
        }
        return String(rawString[tokenRange])
    }

    // MARK: - Keychain Service Name Discovery

    private static let legacyServiceName = "Claude Code-credentials"

    /// The Keychain item Claude Code writes for one configuration directory.
    ///
    /// Claude Code names it `Claude Code-credentials-<hash>`, where the hash
    /// is the first 8 hex characters of the SHA-256 of the configuration
    /// directory's absolute path. Confirmed against a machine holding 13 such
    /// items: 10 mapped exactly onto their `~/.claude-accounts/<name>`
    /// directories, the rest belonging to directories since deleted.
    ///
    /// This exists because every profile was otherwise reading one shared
    /// login. `resolveServiceName` tries the legacy un-suffixed name first,
    /// which still exists on any machine that ran an older Claude Code — so
    /// it matched immediately, was cached for the process, and served every
    /// profile the same credential regardless of which account the profile
    /// was linked to.
    static func serviceName(forConfigurationDirectory path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(legacyServiceName)-\(hex.prefix(8))"
    }

    /// The configuration directory a linked CLI account lives in.
    ///
    /// Delegates to `ClaudeSwitchService.accountDirectoryPath(for:)` — the
    /// same computation used where the account directory is actually
    /// created — rather than recomputing the path independently. The
    /// Keychain service name above is a hash of this exact path string, so a
    /// second, drifting implementation here would silently break the lookup
    /// the moment the two disagreed.
    static func configurationDirectory(forAccountNamed name: String) -> URL {
        ClaudeSwitchService.shared.accountDirectoryPath(for: name)
    }

    /// The Keychain service that *should* hold one linked account's login,
    /// whether or not it already does.
    ///
    /// Distinct from `accountServiceName` on purpose, though no longer
    /// because they disagree about falling back — neither falls back for a
    /// named account any more. This one does not consult the Keychain at
    /// all: it names where the login *belongs*, so a first write can create
    /// an item that does not exist yet. `accountServiceName` requires the
    /// item to already exist, which is right for a read and would make a
    /// write impossible. `nil` only for no account name.
    private func accountServiceNameForWriting(
        forAccountNamed name: String?
    ) -> String? {
        guard let name, !name.isEmpty else { return nil }
        return Self.serviceName(
            forConfigurationDirectory:
                Self.configurationDirectory(forAccountNamed: name).path
        )
    }

    /// The Keychain service holding one linked account's login, when that
    /// account actually has one.
    ///
    /// `nil` means this account has no login stored, full stop — its only
    /// caller, `readKeychainCredentials`, now returns nil rather than
    /// resolving the shared item. It used to fall back, which is how a
    /// profile with no item of its own authenticated as whoever owned the
    /// shared one. A named account always lives under
    /// `~/.claude-accounts/<name>`, so it can never legitimately own the
    /// legacy un-suffixed item and nothing is lost by refusing it.
    private func accountServiceName(forAccountNamed name: String?) -> String? {
        guard let name, !name.isEmpty else { return nil }
        let directory = Self.configurationDirectory(forAccountNamed: name)
        let candidate = Self.serviceName(
            forConfigurationDirectory: directory.path
        )
        guard keychainItemExists(serviceName: candidate) else {
            LoggingService.shared.logDebug(
                "No Claude Code login stored for account '\(name)'; treating "
                + "it as having none rather than reading another account's "
                + "shared login."
            )
            return nil
        }
        return candidate
    }

    /// Resolves the correct keychain service name for Claude Code credentials.
    /// Claude Code v2.1.52+ changed from "Claude Code-credentials" to "Claude Code-credentials-HASH".
    /// Tries legacy name first, then falls back to prefix search.
    private func resolveServiceName() -> String {
        if let cached = resolvedServiceName {
            return cached
        }

        // Try legacy name first (fast path)
        if keychainItemExists(serviceName: Self.legacyServiceName) {
            resolvedServiceName = Self.legacyServiceName
            return Self.legacyServiceName
        }

        // Fall back to searching for "Claude Code-credentials-" prefix
        if let hashedName = findHashedServiceName() {
            resolvedServiceName = hashedName
            LoggingService.shared.log("Resolved hashed keychain service name: \(hashedName)")
            return hashedName
        }

        // Nothing on this machine yet. Answer with the legacy name so the
        // caller still has something to try, but deliberately do NOT cache it:
        // "not found yet" is a transient state, and caching it would keep the
        // app writing the legacy item for the rest of the process lifetime even
        // after the CLI creates its real per-config-dir item.
        return Self.legacyServiceName
    }

    /// Checks if a keychain item exists with the given service name.
    ///
    /// Attributes only — no `kSecReturnData`, so this cannot raise a Keychain
    /// access prompt, and it costs no subprocess.
    private func keychainItemExists(serviceName: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: NSUserName(),
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Searches the keychain for a hashed service name matching
    /// "Claude Code-credentials-*".
    ///
    /// Deliberately not `security dump-keychain`: that dumps the attributes of
    /// every item in the user's login Keychain — every service name, account,
    /// and comment they have ever saved — into this process, to learn one
    /// string. This query is scoped to generic passwords owned by the current
    /// account and returns attributes only.
    private func findHashedServiceName() -> String? {
        let prefix = "Claude Code-credentials-"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: NSUserName(),
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else {
            return nil
        }

        // Sorted so a machine with several config directories resolves to the
        // same item on every launch rather than whichever one the Keychain
        // happened to return first.
        let matches = items
            .compactMap { $0[kSecAttrService as String] as? String }
            .filter { $0.hasPrefix(prefix) }
            .sorted()

        if matches.count > 1 {
            LoggingService.shared.log(
                "Found \(matches.count) hashed Claude Code keychain items; "
                    + "using the first by name"
            )
        }
        return matches.first
    }

    /// Invalidates the cached service name, forcing re-discovery on next access
    func invalidateServiceNameCache() {
        resolvedServiceName = nil
    }

    /// Writes Claude Code credentials to system Keychain using security command.
    ///
    /// The write is a single `add-generic-password -U`, which updates the item
    /// in place when it already exists. It deliberately does *not* delete first.
    ///
    /// The previous implementation ran `delete-generic-password` and only then
    /// re-added, which opened a window with no CLI login at all: any failure of
    /// the add — a locked Keychain, a denied ACL, a SecurityAgent prompt the
    /// user dismisses — left the user logged out of Claude Code, and cost a
    /// second full atomic rewrite of the login Keychain on every profile
    /// switch. `-U` was already being passed, so the delete bought nothing.
    func writeSystemCredentials(
        _ jsonData: String,
        forAccountNamed accountName: String? = nil
    ) throws {
        // Reads have honoured the account name since per-account logins
        // landed; this write never did, so applying a profile's login always
        // targeted the shared un-suffixed item and never the account's own.
        // On a machine whose shared item belongs to a different account that
        // is a cross-account overwrite, and it is why the shared item here
        // ends up holding whichever profile was activated last.
        let serviceName = accountServiceNameForWriting(
            forAccountNamed: accountName
        ) ?? resolveServiceName()
        LoggingService.shared.log("Writing credentials to keychain using security command (service: \(serviceName))")

        let result = try addGenericPassword(jsonData, serviceName: serviceName)
        if result.exitCode == 0 {
            LoggingService.shared.log("✅ Added Claude Code system credentials successfully using security command")
            return
        }

        // `-U` should make this unreachable. If some Keychain state defeats it
        // anyway, fall back to the old delete-then-add — but only from here, as
        // recovery from an already-failed write, never on the happy path.
        guard result.exitCode == Self.duplicateItemExitCode else {
            let message = Self.describe(result)
            LoggingService.shared.log("❌ Failed to add credentials: \(message)")
            throw ClaudeCodeError.keychainWriteFailed(
                exitCode: result.exitCode,
                message: message
            )
        }

        LoggingService.shared.log(
            "Update-in-place was refused as a duplicate; retrying via delete"
        )
        let deleteResult = try securityRunner.run([
            "delete-generic-password",
            "-s", serviceName,
            "-a", NSUserName()
        ])
        if deleteResult.exitCode != 0 {
            LoggingService.shared.log(
                "No existing keychain item to delete "
                    + "(\(Self.describe(deleteResult)))"
            )
        }

        let retry = try addGenericPassword(jsonData, serviceName: serviceName)
        guard retry.exitCode == 0 else {
            let message = Self.describe(retry)
            // The delete above already ran, so this path really can leave the
            // system without a CLI login. Say so plainly in the log.
            LoggingService.shared.log(
                "❌ Failed to add credentials after delete; the system has no "
                    + "Claude Code login until this is retried: \(message)"
            )
            throw ClaudeCodeError.keychainWriteFailed(
                exitCode: retry.exitCode,
                message: message
            )
        }
        LoggingService.shared.log("✅ Added Claude Code system credentials successfully using security command")
    }

    private func addGenericPassword(
        _ jsonData: String,
        serviceName: String
    ) throws -> SecurityCommandResult {
        try securityRunner.run([
            "add-generic-password",
            "-s", serviceName,
            "-a", NSUserName(),
            "-w", jsonData,
            "-U"  // Update if exists
        ])
    }

    // MARK: - Profile Sync Operations

    /// Syncs credentials from system to profile (one-time copy)
    func syncToProfile(_ profileId: UUID) throws {
        // Read the login of the account THIS profile is linked to. Reading
        // the shared default gave every profile the same credential, so a
        // member-scoped figure could never be right for more than one of
        // them — and was wrong or unusable for the rest.
        let accountName = profileStore.loadProfiles()
            .first { $0.id == profileId }?
            .cliAccountName
        guard let jsonData = try readSystemCredentials(
            forAccountNamed: accountName
        ) else {
            throw ClaudeCodeError.noCredentialsFound
        }

        // Validate JSON format
        guard let data = jsonData.data(using: .utf8),
              let _ = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeCodeError.invalidJSON
        }

        // A blob with no token in it must never be stored. Importing one used
        // to succeed silently, overwrite a working credential, and then read
        // back as valid — which is why pressing this button repeatedly had no
        // effect and was not even harmless.
        guard Self.carriesLogin(jsonData) else {
            throw ClaudeCodeError.noCredentialsFound
        }

        let previous = try profileStore
            .loadProfileCredentials(profileId)
            .cliCredentialsJSON
        // This explicit credential API performs a verified Keychain write.
        try profileStore.saveCLIProfileCredential(jsonData, for: profileId)
        if previous != jsonData {
            postCLIChange(profileID: profileId)
        }

        LoggingService.shared.log("Synced CLI credentials to profile: \(profileId)")
    }

    /// Applies profile's CLI credentials to system (overwrites current login)
    func applyProfileCredentials(_ profileId: UUID) throws {
        LoggingService.shared.log("🔄 Applying CLI credentials for profile: \(profileId)")

        guard let jsonData = try profileStore
            .loadProfileCredentials(profileId).cliCredentialsJSON else {
            LoggingService.shared.log("❌ No CLI credentials found for profile: \(profileId)")
            throw ClaudeCodeError.noProfileCredentials
        }

        let accountName = profileStore.loadProfiles()
            .first { $0.id == profileId }?
            .cliAccountName

        // Now that this write lands on the account's own Keychain item rather
        // than the shared one, it reaches the item Claude Code actively uses.
        // That makes it able to do harm the old shared-item write could not:
        // the app's snapshot can be older than the CLI's live login, and
        // pushing it would sign the account backwards on every activation.
        // The CLI keeps its own copy current, so the newer one wins.
        //
        // `readSystemCredentials(forAccountNamed:)` no longer crosses account
        // boundaries for a named account (see `readKeychainCredentials`), so
        // a non-nil result here is genuinely this account's own live login —
        // never another account's credential borrowed from the shared item.
        //
        // Freshness fails CLOSED, not open: no live login at all means there
        // is nothing to protect, so the write proceeds. A live login DOES
        // exist but we can't prove our snapshot is at least as new — missing
        // `expiresAt` on either side, or the read itself failing — and we
        // decline the write rather than risk rolling back a login we can't
        // reason about.
        do {
            if let live = try readSystemCredentials(forAccountNamed: accountName) {
                guard isAtLeastAsFresh(jsonData, as: live) else {
                    LoggingService.shared.log(
                        "Cannot establish that the stored CLI credential is "
                        + "at least as new as this account's live Claude "
                        + "Code login; leaving the live login in place "
                        + "rather than risking a rollback"
                    )
                    return
                }
            }
        } catch {
            LoggingService.shared.log(
                "Could not read this account's live Claude Code login to "
                + "compare freshness; leaving the system unchanged rather "
                + "than risking a rollback: \(error.localizedDescription)"
            )
            return
        }

        LoggingService.shared.log("📦 Found CLI credentials, writing to keychain...")
        try writeSystemCredentials(jsonData, forAccountNamed: accountName)

        LoggingService.shared.log("✅ Applied profile CLI credentials to system: \(profileId)")
    }

    /// Whether `candidate` may be written over `live` without signing the
    /// account backwards.
    ///
    /// Fails CLOSED: a missing `expiresAt` on either side means "cannot
    /// establish", never "probably fine". Every path that writes into Claude
    /// Code's own Keychain item asks this first, because the cost of getting
    /// it wrong is a working CLI login replaced by an older one — and the two
    /// callers must not be able to drift apart on what "safe" means.
    func isAtLeastAsFresh(_ candidate: String, as live: String) -> Bool {
        guard let liveExpiry = extractTokenExpiry(from: live),
              let candidateExpiry = extractTokenExpiry(from: candidate)
        else { return false }
        return candidateExpiry >= liveExpiry
    }

    /// Persists a credential blob the app renewed itself.
    ///
    /// Same verified Keychain write as every other credential path here, with
    /// one deliberate difference: no change notification is posted. A token
    /// rotation is not a change of account, and `.credentialsChanged` triggers
    /// a usage refresh — which is what asked for the rotation in the first
    /// place.
    ///
    /// `rotatedFrom` is the credential whose refresh token was spent to obtain
    /// `jsonData`. Supplying it is what lets Claude Code's own login be kept
    /// working across the rotation; `nil` means no refresh token was spent —
    /// an adopted live login, say — and nothing needs mirroring.
    func saveRefreshedCredentials(
        _ jsonData: String,
        for profileId: UUID,
        rotatedFrom spentCredential: String? = nil
    ) throws {
        guard let data = jsonData.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data))
                as? [String: Any] != nil else {
            throw ClaudeCodeError.invalidJSON
        }
        guard Self.carriesLogin(jsonData) else {
            throw ClaudeCodeError.invalidJSON
        }
        try profileStore.saveCLIProfileCredential(jsonData, for: profileId)

        // The account name is here for the log as much as for the write-back.
        // Nothing recorded which Claude Code account a rotation belonged to,
        // so when a member was asked to sign in again there was no way to tell
        // from the log whether this app had rotated the token out from under
        // them or the login had simply aged out on its own.
        let accountName = profileStore.loadProfiles()
            .first { $0.id == profileId }?
            .cliAccountName
        LoggingService.shared.log(
            "Stored a renewed CLI access token for profile: \(profileId) "
            + "(\(Self.describeAccount(accountName)))"
        )

        if let spentCredential {
            propagateRotatedTokenToClaudeCode(
                jsonData,
                rotatedFrom: spentCredential,
                accountName: accountName
            )
        }
    }

    /// Names a linked Claude Code account for a log line.
    static func describeAccount(_ accountName: String?) -> String {
        guard let accountName, !accountName.isEmpty else {
            return "no linked Claude Code account"
        }
        return "Claude Code account '\(accountName)'"
    }

    /// Keeps Claude Code's own login working after this app spends its refresh
    /// token.
    ///
    /// Anthropic rotates the refresh token on every use. When the credential
    /// the app just renewed is the one Claude Code is itself relying on, that
    /// renewal invalidates the CLI's login: the token in Claude Code's Keychain
    /// item has been rotated away, and the next `claude` command asks the
    /// person to sign in again — with nothing in either program's output
    /// connecting the demand to the app that caused it. An app whose whole job
    /// is watching credential health must not be the thing degrading it, so
    /// the rotated token is mirrored back rather than kept to ourselves.
    ///
    /// Ownership is established at the moment it matters rather than recorded
    /// when the credential was adopted: Claude Code depends on this credential
    /// exactly when its live login still carries the refresh token we just
    /// spent. A flag recorded at adoption time would go stale the moment that
    /// account was signed in again anywhere else, and a stale "the CLI relies
    /// on this" is an instruction to overwrite a login we no longer understand.
    ///
    /// Two guards, both failing closed:
    ///
    /// - the live login must carry the refresh token that was spent, so a
    ///   Claude Code that has moved on is never rewritten from here;
    /// - the renewed credential must be provably at least as new as the live
    ///   login (`isAtLeastAsFresh`), the same protection `applyProfileCredentials`
    ///   uses, so this can never roll Claude Code backwards.
    ///
    /// Everything here is best effort and never throws. The renewed token is
    /// already stored against the profile by the time this runs; failing to
    /// mirror it leaves Claude Code exactly where the old code left it, which
    /// is bad but no worse than not trying.
    private func propagateRotatedTokenToClaudeCode(
        _ renewed: String,
        rotatedFrom spent: String,
        accountName: String?
    ) {
        guard let accountName, !accountName.isEmpty else { return }
        guard let spentRefreshToken = ClaudeCLITokenRefresher.refreshToken(
            in: spent
        ) else { return }

        // Deliberately the Keychain item itself, not `readSystemCredentials`.
        // That chain prefers an unexpired `.credentials.json` snapshot, which
        // can carry a different refresh token from the Keychain item Claude
        // Code actually authenticates with — and the Keychain item is both
        // what this renewal invalidated and what the write below replaces.
        // Checking one and overwriting the other would skip the repair in
        // exactly the case it is needed, leaving the user signed out.
        guard let serviceName = accountServiceNameForWriting(
            forAccountNamed: accountName
        ) else { return }

        let live: String?
        do {
            live = try readKeychainSecret(serviceName: serviceName)
        } catch {
            LoggingService.shared.log(
                "Could not read the live Claude Code login for "
                + "\(Self.describeAccount(accountName)) after renewing its "
                + "token; leaving it unchanged: \(error.localizedDescription)"
            )
            return
        }

        // No item at all means Claude Code is holding nothing this renewal
        // could have invalidated, and nothing this write would replace.
        guard let live else { return }

        guard ClaudeCLITokenRefresher.refreshToken(in: live) == spentRefreshToken
        else { return }

        guard isAtLeastAsFresh(renewed, as: live) else {
            LoggingService.shared.log(
                "Cannot establish that the renewed token is at least as new "
                + "as the live login for \(Self.describeAccount(accountName)); "
                + "leaving that login in place rather than risking a rollback"
            )
            return
        }

        do {
            try writeSystemCredentials(renewed, forAccountNamed: accountName)
            LoggingService.shared.log(
                "Mirrored the rotated token back into Claude Code's own login "
                + "for \(Self.describeAccount(accountName)), so the CLI keeps "
                + "working after the app spent its refresh token"
            )
        } catch {
            LoggingService.shared.logWarning(
                "Could not write the rotated token back into Claude Code's "
                + "login for \(Self.describeAccount(accountName)): "
                + "\(error.localizedDescription). Claude Code may ask for a "
                + "fresh sign-in."
            )
        }
    }

    /// Removes CLI credentials from profile (doesn't affect system)
    func removeFromProfile(_ profileId: UUID) throws {
        let previous = try profileStore
            .loadProfileCredentials(profileId)
            .cliCredentialsJSON
        try profileStore.saveCLIProfileCredential(nil, for: profileId)
        if previous != nil {
            postCLIChange(profileID: profileId)
        }

        LoggingService.shared.log("Removed CLI credentials from profile: \(profileId)")
    }

    // MARK: - Access Token Extraction

    /// The access token in a stored credential, or nil when there isn't one.
    ///
    /// An empty string is answered as *absent*, not as a token. Claude Code
    /// leaves `claudeAiOauth` in place with `accessToken` set to `""` when a
    /// configuration directory holds no login — MCP server logins only, or an
    /// account that has been signed out. Returning `""` here let that pass
    /// every `if let` in the app, so requests went out with a bare
    /// `Authorization: Bearer `, 401ed, and were reported as a transient
    /// read failure whose advised remedy re-imported the same empty blob.
    func extractAccessToken(from jsonData: String) -> String? {
        guard let data = jsonData.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Self.containsClaudeCodeLogin(json),
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else {
            return nil
        }
        return token
    }

    func extractSubscriptionInfo(from jsonData: String) -> (type: String, scopes: [String])? {
        guard let data = jsonData.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any] else {
            return nil
        }

        let subType = oauth["subscriptionType"] as? String ?? "unknown"
        let scopes = oauth["scopes"] as? [String] ?? []

        return (subType, scopes)
    }

    /// Extracts the token expiry date from CLI credentials JSON
    func extractTokenExpiry(from jsonData: String) -> Date? {
        guard let data = jsonData.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let expiresAt = oauth["expiresAt"] as? TimeInterval else {
            return nil
        }
        // Claude Code CLI stores expiresAt in milliseconds since epoch
        // Values > 1e12 are definitely milliseconds (year 2001+ in ms vs year 33658 in seconds)
        let epochSeconds = expiresAt > 1e12 ? expiresAt / 1000.0 : expiresAt
        return Date(timeIntervalSince1970: epochSeconds)
    }

    /// Checks if the OAuth token in the credentials JSON is expired
    func isTokenExpired(_ jsonData: String) -> Bool {
        guard let expiryDate = extractTokenExpiry(from: jsonData) else {
            // No expiry info = assume valid
            return false
        }
        return Date() > expiryDate
    }

    // MARK: - Auto Re-sync Before Switching

    /// Re-syncs credentials from system Keychain before profile switching
    /// This ensures we always have the latest CLI login when switching profiles
    func resyncBeforeSwitching(for profileId: UUID) throws {
        LoggingService.shared.log("Re-syncing CLI credentials before profile switch: \(profileId)")

        // Read fresh credentials from the account THIS profile is linked
        // to. Reading the shared default here is how one login propagated
        // into every profile: each switch overwrote the profile being left
        // with whatever the default account happened to hold.
        let accountName = profileStore.loadProfiles()
            .first { $0.id == profileId }?
            .cliAccountName
        guard let freshJSON = try readSystemCredentials(
            forAccountNamed: accountName
        ) else {
            // No credentials in system - user not logged into CLI anymore
            LoggingService.shared.log("No system credentials found - skipping re-sync")
            return
        }

        // Validate JSON before saving (defense-in-depth against truncated data)
        guard let data = freshJSON.data(using: .utf8),
              let _ = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            LoggingService.shared.log("Re-synced credentials contain invalid JSON - skipping save")
            return
        }

        // Switching profiles must never cost the outgoing profile its login.
        // The system copy can legitimately hold no token — Claude Code leaves
        // `claudeAiOauth` behind with an empty `accessToken` for a signed-out
        // configuration directory — and storing that over a working
        // credential is a silent loss the user cannot undo by re-syncing.
        guard Self.carriesLogin(freshJSON) else {
            LoggingService.shared.log(
                "The system Claude Code login for this account holds no "
                + "token - keeping the stored credential instead"
            )
            return
        }

        let previous = try profileStore
            .loadProfileCredentials(profileId)
            .cliCredentialsJSON
        try profileStore.saveCLIProfileCredential(
            freshJSON,
            for: profileId,
            syncedAt: Date()
        )
        if previous != freshJSON {
            postCLIChange(profileID: profileId)
        }

        LoggingService.shared.log("✓ Re-synced CLI credentials from system and updated timestamp")
    }

    private func postCLIChange(profileID: UUID) {
        NotificationCenter.default.post(
            name: .credentialsChanged,
            object: profileID,
            userInfo: [
                "profileID": profileID,
                "component": "cli"
            ]
        )
    }
}

// MARK: - ClaudeCodeError

enum ClaudeCodeError: LocalizedError {
    case noCredentialsFound
    case invalidJSON
    /// Carries the `security` process exit code plus whatever the CLI wrote to
    /// stderr. Both are needed: the exit code alone is not an `OSStatus` and
    /// says almost nothing about why the Keychain refused the operation.
    case keychainReadFailed(exitCode: Int32, message: String)
    case keychainWriteFailed(exitCode: Int32, message: String)
    case noProfileCredentials

    var errorDescription: String? {
        switch self {
        case .noCredentialsFound:
            return "No Claude Code credentials found in system Keychain. Please log in to Claude Code first."
        case .invalidJSON:
            return "Claude Code credentials are corrupted or invalid."
        case .keychainReadFailed(_, let message):
            return "Failed to read credentials from system Keychain (\(message))."
        case .keychainWriteFailed(_, let message):
            return "Failed to write credentials to system Keychain (\(message))."
        case .noProfileCredentials:
            return "This profile has no synced CLI account."
        }
    }
}
