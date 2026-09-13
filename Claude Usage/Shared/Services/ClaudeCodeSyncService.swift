//
//  ClaudeCodeSyncService.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-01-07.
//

import CryptoKit
import Darwin
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
    private let keychainCredentialsReader: ((String?) throws -> String?)?
    private let securityRunner: SecurityCommandRunning
    /// Test seam for the directory containing Claude Code's credentials file.
    /// Production deliberately follows Claude Code's account-directory rule.
    private let credentialsFileDirectory: ((String?) -> URL)?
    /// The file repair is best effort, but its precise outcome is useful to
    /// both support logs and isolated tests without observing global logging.
    private let credentialLogSink: ((String) -> Void)?
    /// Whether a `claude` process is currently relying on an account's login.
    /// Consulted by the one write chokepoint below, and by nothing else.
    let liveProcessDetector: LiveClaudeProcessDetector

    init(
        profileStore: ProfileStore = .shared,
        systemCredentialsReader: (() throws -> String?)? = nil,
        keychainCredentialsReader: ((String?) throws -> String?)? = nil,
        securityRunner: SecurityCommandRunning = SecurityCLIRunner(),
        credentialsFileDirectory: ((String?) -> URL)? = nil,
        credentialLogSink: ((String) -> Void)? = nil,
        liveProcessDetector: LiveClaudeProcessDetector
            = LiveClaudeProcessDetector()
    ) {
        self.profileStore = profileStore
        self.systemCredentialsReader = systemCredentialsReader
        self.keychainCredentialsReader = keychainCredentialsReader
        self.securityRunner = securityRunner
        self.credentialsFileDirectory = credentialsFileDirectory
        self.credentialLogSink = credentialLogSink
        self.liveProcessDetector = liveProcessDetector
    }

    // MARK: - System Credentials Access (Claude Code's own order)

    /// Which of the three answers Claude Code's Keychain store gives.
    ///
    /// Claude Code composes two stores — the Keychain item and
    /// `<configDir>/.credentials.json` — and the file is consulted for
    /// exactly one reason: the Keychain read produced no document at all.
    /// A `Bool?` cannot carry that: "the item is there and holds no login"
    /// and "there is no item" are the same `nil` and mean opposite things.
    enum ClaudeCodeKeychainLookup: Equatable {
        /// The item exists and carries a Claude Code login.
        case login(String)
        /// The item exists and its tokens are blank. Claude Code writes this
        /// shape when it retires a dead refresh token, and reads it back as
        /// "logged out" — it never looks at the file behind it, and neither
        /// may we.
        case loggedOut
        /// `security` answered "item not found" (exit 44), or the item's
        /// bytes would not parse. Claude Code's own keychain read returns
        /// null in both cases, and null is what sends it to the file.
        case noItem
    }

    /// Reads a Claude Code login the way Claude Code reads it.
    ///
    /// Keychain item first; `<configDir>/.credentials.json` only when the
    /// Keychain lookup answers "no item". This used to be the other way
    /// round, with a stale file login pre-empting the Keychain and an
    /// expired file login held back as a last resort — so this app and the
    /// CLI could be looking at two different token chains for one account,
    /// which is how one program spent a refresh token the other was still
    /// relying on.
    ///
    /// A blank Keychain item is "signed out", full stop. Falling through to
    /// the file there would resurrect the very login Claude Code has just
    /// retired as dead.
    func readSystemCredentials(
        forAccountNamed accountName: String? = nil
    ) throws -> String? {
        if let systemCredentialsReader {
            return try systemCredentialsReader()
        }

        switch try claudeCodeKeychainLookup(forAccountNamed: accountName) {
        case .login(let json):
            logCredentialDecision(
                "Read \(Self.describeAccount(accountName))'s login from its "
                + "Claude Code Keychain item"
            )
            return json
        case .loggedOut:
            logCredentialDecision(
                "Claude Code's Keychain item for "
                + "\(Self.describeAccount(accountName)) carries no token, "
                + "which is how Claude Code records a signed-out account; "
                + "not reading the credentials file behind it"
            )
            return nil
        case .noItem:
            guard let fileLogin = readCredentialsFile(
                forAccountNamed: accountName
            ) else {
                logCredentialDecision(
                    "\(Self.describeAccount(accountName)) has no Claude Code "
                    + "Keychain item and no credentials file"
                )
                return nil
            }
            logCredentialDecision(
                "\(Self.describeAccount(accountName)) has no Claude Code "
                + "Keychain item; read its login from the credentials file, "
                + "the same fallback Claude Code makes"
            )
            return fileLogin
        }
    }

    /// The Keychain half of Claude Code's read, kept separate so the
    /// three-way answer survives all the way to the caller.
    ///
    /// Not `private`: it is the surface the read-order tests exercise, and a
    /// second implementation of "what did the Keychain say" is exactly how
    /// the two programs drifted apart in the first place.
    func claudeCodeKeychainLookup(
        forAccountNamed accountName: String? = nil
    ) throws -> ClaudeCodeKeychainLookup {
        if let keychainCredentialsReader {
            guard let json = try keychainCredentialsReader(accountName) else {
                return .noItem
            }
            return Self.classifyKeychainDocument(json)
        }

        // The item a write would target, named rather than discovered. A
        // named account's item is that account's login, full stop — never
        // the shared un-suffixed item, which belongs to whichever account
        // last wrote it. Asking `security` and letting exit 44 mean "no
        // item" is also Claude Code's own test, and it keeps the item that
        // is read and the item that is written from ever being two
        // different items.
        let serviceName = accountServiceNameForWriting(
            forAccountNamed: accountName
        ) ?? resolveServiceName()

        let result = try securityRunner.run([
            "find-generic-password",
            "-s", serviceName,
            "-a", NSUserName(),
            "-w"
        ])

        if result.exitCode == Self.itemNotFoundExitCode {
            return .noItem
        }
        guard result.exitCode == 0 else {
            let message = Self.describe(result)
            logCredentialDecision(
                "Could not read Claude Code's Keychain item for "
                + "\(Self.describeAccount(accountName)): \(message)",
                warning: true
            )
            throw ClaudeCodeError.keychainReadFailed(
                exitCode: result.exitCode,
                message: message
            )
        }
        guard let value = result.standardOutput?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty else {
            // Claude Code's own keychain read wraps the parse in a try/catch
            // and answers null when the bytes are unusable, which sends it to
            // the file. Undecodable bytes are the same condition.
            return .noItem
        }
        return Self.classifyKeychainDocument(value)
    }

    /// Sorts one Keychain document into Claude Code's three answers.
    ///
    /// The regex salvage that used to live on this path — rebuilding a
    /// minimal credential from a "truncated" Keychain blob — is gone.
    /// Truncation could not be reproduced: `security add-generic-password`
    /// followed by `find-generic-password -w` round-tripped a 10 KB and a
    /// 60 KB secret byte for byte on macOS 15. What the salvage actually did
    /// was manufacture a credential with an access token and no refresh
    /// token or expiry out of any blob that failed to parse, which then read
    /// back as a valid login forever.
    static func classifyKeychainDocument(
        _ json: String
    ) -> ClaudeCodeKeychainLookup {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else { return .noItem }
        guard object["claudeAiOauth"] != nil else {
            // A document with no `claudeAiOauth` key at all — an
            // MCP-only store, say — is not a signed-out Claude Code
            // account; there is simply no Claude Code record here.
            return .noItem
        }
        return containsClaudeCodeLogin(object) ? .login(json) : .loggedOut
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
    /// none of it, exactly as Claude Code's own plaintext store does.
    ///
    /// Reached only when the Keychain lookup answered "no item". Nothing
    /// here decides whether the file may pre-empt the Keychain, because it
    /// never may: that question is settled in `readSystemCredentials`, and
    /// settled the same way Claude Code settles it.
    ///
    /// The unhidden `credentials.json` is a read-only compatibility name
    /// from older installs. Claude Code itself only writes `.credentials.json`,
    /// and so does this app.
    private func readCredentialsFile(
        forAccountNamed accountName: String? = nil
    ) -> String? {
        // A linked account keeps its own configuration directory, so its
        // credentials file is the one that describes it. Only fall back to
        // the shared directory when no account is named.
        let directory = credentialsDirectory(forAccountNamed: accountName)
        let paths = [
            credentialsFileURL(forAccountNamed: accountName),
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

    /// The one file Claude Code itself uses when its Keychain is unavailable.
    /// The legacy unhidden `credentials.json` remains a read-only fallback in
    /// `readCredentialsFile`; it must never be selected as a write target.
    private func credentialsFileURL(forAccountNamed accountName: String?) -> URL {
        credentialsDirectory(forAccountNamed: accountName)
            .appendingPathComponent(".credentials.json")
    }

    private func credentialsDirectory(forAccountNamed accountName: String?) -> URL {
        credentialsFileDirectory?(accountName) ?? accountName.map {
            Self.configurationDirectory(forAccountNamed: $0)
        } ?? Constants.ClaudePaths.claudeDirectory
    }

    /// Reads only Claude Code's canonical credentials file, unlike the
    /// compatibility reader above which also accepts the old unhidden name.
    private func readCanonicalCredentialsFile(
        forAccountNamed accountName: String?
    ) -> String? {
        let fileURL = credentialsFileURL(forAccountNamed: accountName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil // Claude Code has not selected the file store.
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            logCredentialDecision(
                "Could not read Claude Code's credentials file for "
                + "\(Self.describeAccount(accountName)); leaving it unchanged: "
                + "\(error.localizedDescription)",
                warning: true
            )
            return nil
        }

        guard let json = String(data: data, encoding: .utf8) else {
            logCredentialDecision(
                "Could not parse Claude Code's credentials file for "
                + "\(Self.describeAccount(accountName)); leaving it unchanged "
                + "because it is not valid UTF-8",
                warning: true
            )
            return nil
        }

        guard (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            != nil else {
            logCredentialDecision(
                "Could not parse Claude Code's credentials file for "
                + "\(Self.describeAccount(accountName)); leaving it unchanged "
                + "because it is not valid JSON",
                warning: true
            )
            return nil
        }

        // Ownership is refresh-token-only. Unlike `readSystemCredentials`,
        // this helper must not require an access token: a partial file login
        // carrying the token we just spent still must not be copied into the
        // Keychain or left holding a refresh token that is now invalid.
        return json
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
        if let keychainCredentialsReader {
            return try keychainCredentialsReader(accountName)
        }
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
    private func readKeychainSecret(
        serviceName: String,
        invalidUTF8IsError: Bool = false
    ) throws -> String? {
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
                if invalidUTF8IsError {
                    throw ClaudeCodeError.invalidJSON
                }
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

    // MARK: - Claude Code's cross-process locks

    /// The lock Claude Code takes before it refreshes an OAuth token.
    static let refreshLockName = ".oauth_refresh.lock"
    /// The lock Claude Code takes before it writes its credential store.
    static let storageWriteLockName = ".storage-write"
    /// Claude Code's own staleness thresholds and heartbeat interval.
    static let refreshLockStaleAfter: TimeInterval = 60
    static let refreshLockRefreshEvery: TimeInterval = 5
    static let storageWriteLockStaleAfter: TimeInterval = 15
    static let storageWriteLockRefreshEvery: TimeInterval = 5

    /// Takes the lock Claude Code takes before it refreshes a token.
    ///
    /// Claude Code acquires two locks here: this one and a legacy lock at
    /// `<realpath(configDir)>.lock`. It acquires this one first, so holding
    /// this one is enough to make Claude Code back off — it never reaches
    /// the legacy lock while we have this. Taking only the lock that
    /// actually excludes is one fewer path that can fail half-way and leave
    /// a directory behind.
    ///
    /// Throws `heldByAnotherProcess` when someone else has it. The caller
    /// skips the tick rather than waiting: the process holding it is
    /// refreshing the very token we wanted, and its result is readable next
    /// tick.
    func acquireRefreshLock(
        forAccountNamed accountName: String?
    ) throws -> ClaudeCodeStoreLock {
        try acquireLock(
            named: Self.refreshLockName,
            forAccountNamed: accountName,
            staleAfter: Self.refreshLockStaleAfter,
            refreshEvery: Self.refreshLockRefreshEvery
        )
    }

    private func acquireLock(
        named name: String,
        forAccountNamed accountName: String?,
        staleAfter: TimeInterval,
        refreshEvery: TimeInterval
    ) throws -> ClaudeCodeStoreLock {
        let directory = credentialsDirectory(forAccountNamed: accountName)
        // Claude Code creates the configuration directory before locking in
        // it; a lock cannot be taken inside a directory that is not there.
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return try ClaudeCodeStoreLock.acquire(
            at: directory.appendingPathComponent(name),
            staleAfter: staleAfter,
            refreshEvery: refreshEvery
        )
    }

    /// Whether Claude Code's store has moved past the snapshot we were about
    /// to spend.
    ///
    /// Claude Code re-reads its own store three times before it posts a
    /// refresh, and adopts a sibling's rotated access token at any of them
    /// rather than spending a token that has already been replaced. This is
    /// that same check, asked at the same moment: under the refresh lock,
    /// immediately before the endpoint call.
    ///
    /// Answers `false` when it cannot tell. Being wrong here costs one
    /// wasted exchange; refusing to refresh on every unreadable store would
    /// cost the numbers entirely.
    func storeHasMovedOn(
        from snapshot: String,
        forAccountNamed accountName: String?
    ) -> Bool {
        guard let snapshotToken = extractAccessToken(from: snapshot) else {
            return false
        }
        guard let lookup = try? claudeCodeKeychainLookup(
            forAccountNamed: accountName
        ), case .login(let current) = lookup,
            let currentToken = extractAccessToken(from: current)
        else { return false }
        return currentToken != snapshotToken
    }

    // MARK: - The one way into a Claude Code store

    /// Which of Claude Code's two stores a write is aimed at.
    enum ClaudeCodeStore: String, Equatable {
        /// The Keychain item `Claude Code-credentials-<hash>`. Claude Code's
        /// primary store, and the only one this app ever creates.
        case keychain
        /// `<configDir>/.credentials.json`. Claude Code writes it only when
        /// the Keychain write fails outright, so a machine has one or the
        /// other, never both by design.
        case credentialsFile
    }

    /// Why a write into a Claude Code store was refused.
    ///
    /// Every case is a refusal, never a failure: nothing was written and
    /// nothing is broken. They exist as values so the log line and the tests
    /// name the same reasons.
    enum ClaudeCodeWriteRefusal: String, Equatable {
        /// A `claude` process is using this account right now. Writing its
        /// store — or worse, spending its refresh token — is what leaves
        /// that process holding a token the server has retired.
        case accountInUse
        /// The account has a Keychain item, so the credentials file behind
        /// it is not the store Claude Code reads. Writing both is how two
        /// token chains for one account come to exist.
        case keychainItemExistsForFileWrite
        /// There is no credentials file to update. Creating one would
        /// install a plaintext store on a machine that had chosen not to
        /// have one.
        case noCredentialsFileToUpdate
        /// The file no longer holds the refresh token this write was based
        /// on, or its login is newer than ours. Someone else got there
        /// first; their write stands.
        case fileMovedOn
        /// The Keychain item no longer holds the refresh token that was
        /// posted to the server, so somebody else's rotation landed first
        /// and theirs is the live one. Claude Code calls this adopting a
        /// newer write, and abandons its own save exactly here.
        case keychainMovedOn
        /// `<configDir>/.storage-write` stayed held for every attempt.
        /// Claude Code is writing its own store; ours would land on top of
        /// a write still in progress.
        case storeWriteLockBusy
    }

    /// The single chokepoint for every write into a Claude Code store.
    ///
    /// R4 of the token-race fix: there is deliberately no second way in. The
    /// Keychain primitive below is private, the credentials-file writer is
    /// private, and both are reachable only from here — so a future caller
    /// cannot acquire the ability to overwrite a running `claude`'s login by
    /// forgetting a guard, because there is no guard to forget.
    ///
    /// Phase 1 enforces three rules:
    /// 1. Refuse any write for an account with a live `claude` process.
    /// 2. Refuse a credentials-file write when a Keychain item exists.
    /// 3. Never create a credentials file that is not already there.
    ///
    /// Phase 2 adds the cross-process lock and compare-and-swap around the
    /// Keychain write; the seam is `performGuardedWrite` below, which is the
    /// only place that touches a store once the refusals have been cleared.
    ///
    /// - Returns: `true` when bytes were written.
    @discardableResult
    func commitClaudeCodeStoreWrite(
        _ credentialsJSON: String,
        forAccountNamed accountName: String?,
        store: ClaudeCodeStore,
        purpose: String,
        expectedRefreshToken: String? = nil
    ) throws -> Bool {
        let account = Self.describeAccount(accountName)
        let directory = credentialsDirectory(forAccountNamed: accountName)
        let isLive = liveProcessDetector.isLive(
            configurationDirectory: directory.path
        )

        guard !isLive else {
            logStoreDecision(
                account: account,
                live: true,
                store: store,
                purpose: purpose,
                refusal: .accountInUse
            )
            return false
        }

        if store == .credentialsFile {
            // Claude Code reads the Keychain item and never looks at the
            // file behind it, so a file write here would leave a second,
            // divergent copy of the login that nothing reads and everything
            // can rotate.
            let lookup: ClaudeCodeKeychainLookup
            do {
                lookup = try claudeCodeKeychainLookup(
                    forAccountNamed: accountName
                )
            } catch {
                // Cannot prove the file is the live store. Fail closed.
                logStoreDecision(
                    account: account,
                    live: false,
                    store: store,
                    purpose: purpose,
                    refusal: .keychainItemExistsForFileWrite,
                    detail: "the Keychain item could not be read: "
                        + error.localizedDescription
                )
                return false
            }
            if lookup != .noItem {
                logStoreDecision(
                    account: account,
                    live: false,
                    store: store,
                    purpose: purpose,
                    refusal: .keychainItemExistsForFileWrite
                )
                return false
            }
            guard FileManager.default.fileExists(
                atPath: credentialsFileURL(forAccountNamed: accountName).path
            ) else {
                logStoreDecision(
                    account: account,
                    live: false,
                    store: store,
                    purpose: purpose,
                    refusal: .noCredentialsFileToUpdate
                )
                return false
            }
        }

        return try performGuardedWrite(
            credentialsJSON,
            forAccountNamed: accountName,
            store: store,
            purpose: purpose,
            account: account,
            expectedRefreshToken: expectedRefreshToken
        )
    }

    /// Everything that actually touches a store, once the refusals are clear.
    ///
    /// Phase 2 wraps this body in `<configDir>/.oauth_refresh.lock` and
    /// `<configDir>/.storage-write`, and turns the Keychain write into a
    /// re-read-and-compare-and-swap. Keeping it as its own function means
    /// that change lands in one place and cannot miss a caller.
    private func performGuardedWrite(
        _ credentialsJSON: String,
        forAccountNamed accountName: String?,
        store: ClaudeCodeStore,
        purpose: String,
        account: String,
        expectedRefreshToken: String?
    ) throws -> Bool {
        switch store {
        case .keychain:
            let outcome = try writeKeychainUnderStoreLock(
                credentialsJSON,
                forAccountNamed: accountName,
                expectedRefreshToken: expectedRefreshToken
            )
            logStoreDecision(
                account: account,
                live: false,
                store: store,
                purpose: purpose,
                refusal: outcome
            )
            return outcome == nil
        case .credentialsFile:
            guard let expectedRefreshToken else {
                throw ClaudeCodeError.invalidJSON
            }
            let written = try performCredentialsFileWrite(
                inCredentialsFileFor: accountName,
                with: credentialsJSON,
                expectedRefreshToken: expectedRefreshToken
            )
            logStoreDecision(
                account: account,
                live: false,
                store: store,
                purpose: purpose,
                refusal: written ? nil : .fileMovedOn
            )
            return written
        }
    }

    /// R6: one line per chokepoint decision — which account, whether a
    /// `claude` is using it, which store was aimed at, what asked for the
    /// write, and whether it happened. Never a token value: everything here
    /// is an account name, a store name and a fixed reason string.
    private func logStoreDecision(
        account: String,
        live: Bool,
        store: ClaudeCodeStore,
        purpose: String,
        refusal: ClaudeCodeWriteRefusal?,
        detail: String? = nil
    ) {
        let state = live ? "in use by a running claude" : "idle"
        let verdict: String
        switch refusal {
        case nil:
            verdict = "wrote it"
        case .accountInUse:
            verdict = "refused: a claude process is relying on this login"
        case .keychainItemExistsForFileWrite:
            verdict = "refused: Claude Code keeps this account's login in "
                + "the Keychain, so its credentials file is not the store "
                + "it reads"
        case .noCredentialsFileToUpdate:
            verdict = "refused: there is no credentials file to update, and "
                + "creating one would add a plaintext store this machine "
                + "does not have"
        case .fileMovedOn:
            verdict = "refused: the credentials file changed underneath this "
                + "write, so the other writer's login stands"
        case .keychainMovedOn:
            verdict = "refused: another process rotated this login first, so "
                + "its token is the live one and ours is already spent"
        case .storeWriteLockBusy:
            verdict = "refused: Claude Code is holding the store-write lock, "
                + "so its own write is still in progress"
        }
        let suffix = detail.map { " (\($0))" } ?? ""
        logCredentialDecision(
            "Claude Code store write — \(account), \(state), "
            + "store: \(store.rawValue), asked by: \(purpose) — "
            + "\(verdict)\(suffix)"
        )
    }

    /// Claude Code's own save: under `<configDir>/.storage-write`, re-read
    /// the item, and write only if the refresh token stored there is still
    /// the one that was posted to the server.
    ///
    /// This is the compare-and-swap that stops two programs' rotations from
    /// overwriting each other. A refresh token is single-use: if the stored
    /// token is no longer the one we posted, somebody else's rotation landed
    /// first, theirs is the live pair, and writing ours would install a
    /// token the server has already retired — which is the exact failure
    /// this whole change exists to prevent, only with the roles reversed.
    ///
    /// Three attempts, 100 ms apart, matching Claude Code's own retry.
    /// Retries exist for a busy store-write lock and for a Keychain that
    /// refuses one write; a token that has genuinely moved on is abandoned
    /// on the first look, because retrying cannot make it come back.
    ///
    /// `expectedRefreshToken` is `nil` for a write that was not derived from
    /// a spend — activating a profile, say. There is nothing to compare
    /// then, and a missing item is created rather than refused.
    ///
    /// - Returns: `nil` when the bytes were written, or the reason they were
    ///   not.
    private func writeKeychainUnderStoreLock(
        _ credentialsJSON: String,
        forAccountNamed accountName: String?,
        expectedRefreshToken: String?
    ) throws -> ClaudeCodeWriteRefusal? {
        let attempts = 3
        // Tracked apart from lock failures: a Keychain that refused the
        // write is a real error the caller has to see, while a busy lock is
        // a refusal. Sharing one variable let a late lock failure swallow an
        // earlier write failure.
        var lastWriteError: Error?

        for attempt in 0..<attempts {
            if attempt > 0 {
                Thread.sleep(forTimeInterval: 0.1 * Double(attempt))
            }

            let storeLock: ClaudeCodeStoreLock
            do {
                storeLock = try acquireLock(
                    named: Self.storageWriteLockName,
                    forAccountNamed: accountName,
                    staleAfter: Self.storageWriteLockStaleAfter,
                    refreshEvery: Self.storageWriteLockRefreshEvery
                )
            } catch {
                continue
            }
            defer { storeLock.release() }

            if let expectedRefreshToken,
               let refusal = compareAndSwapVerdict(
                   forAccountNamed: accountName,
                   expectedRefreshToken: expectedRefreshToken
               ) {
                return refusal
            }

            do {
                try performKeychainWrite(
                    credentialsJSON,
                    forAccountNamed: accountName
                )
                return nil
            } catch {
                lastWriteError = error
            }
        }

        if let lastWriteError { throw lastWriteError }
        return .storeWriteLockBusy
    }

    /// `nil` means "go ahead"; anything else is the reason not to.
    ///
    /// A blank refresh token is writable. That is the shape Claude Code
    /// leaves when it retires a dead one, and refusing to write over it
    /// would leave the account signed out with a perfectly good replacement
    /// pair in hand. An item with no Claude Code record at all is refused,
    /// as Claude Code refuses it: there is nothing to swap.
    private func compareAndSwapVerdict(
        forAccountNamed accountName: String?,
        expectedRefreshToken: String
    ) -> ClaudeCodeWriteRefusal? {
        let lookup: ClaudeCodeKeychainLookup
        do {
            lookup = try claudeCodeKeychainLookup(forAccountNamed: accountName)
        } catch {
            // Cannot prove the stored token is still ours. Fail closed.
            return .keychainMovedOn
        }

        switch lookup {
        case .loggedOut:
            return nil
        case .noItem:
            return .keychainMovedOn
        case .login(let current):
            let stored = ClaudeCLITokenRefresher.refreshToken(in: current)
            guard let stored, !stored.isEmpty else { return nil }
            return stored == expectedRefreshToken ? nil : .keychainMovedOn
        }
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
    ///
    /// Private on purpose since the token-race fix: `commitClaudeCodeStoreWrite`
    /// is the only way in. It used to be the app's general-purpose "write the
    /// CLI login" call, which is precisely how a write could reach a running
    /// `claude`'s account without anyone deciding that it should.
    private func performKeychainWrite(
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

    /// Imports only the linked account's Claude Code Keychain item.
    ///
    /// Unlike `syncToProfile`, this deliberately does not consult an account
    /// credentials file. The Link Claude Code sheet uses the distinction:
    /// only a genuinely absent Keychain item permits its separate file
    /// fallback; an item that exists but is malformed or has no token must be
    /// surfaced instead of turning a different file login into a false green.
    func syncKeychainToProfile(_ profileId: UUID) throws {
        let accountName = profileStore.loadProfiles()
            .first { $0.id == profileId }?
            .cliAccountName
        let keychainJSON: String?
        if let keychainCredentialsReader {
            keychainJSON = try keychainCredentialsReader(accountName)
        } else {
            let serviceName = accountServiceNameForWriting(
                forAccountNamed: accountName
            ) ?? resolveServiceName()
            // Read the exact item directly. `readKeychainCredentials` first
            // performs discovery that intentionally collapses some unreadable
            // states to absence for legacy callers; Link Claude Code needs the
            // stricter present-vs-absent distinction.
            keychainJSON = try readKeychainSecret(
                serviceName: serviceName,
                invalidUTF8IsError: true
            )
        }
        guard let jsonData = keychainJSON else {
            throw ClaudeCodeError.noCredentialsFound
        }
        guard let data = jsonData.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data))
                is [String: Any],
              Self.carriesLogin(jsonData) else {
            // The item was present. Keep this distinct from absence so the
            // caller cannot fall back to a file and hide the broken item.
            throw ClaudeCodeError.invalidJSON
        }

        let previous = try profileStore
            .loadProfileCredentials(profileId)
            .cliCredentialsJSON
        try profileStore.saveCLIProfileCredential(jsonData, for: profileId)
        if previous != jsonData {
            postCLIChange(profileID: profileId)
        }
        LoggingService.shared.log(
            "Synced Keychain-only CLI credentials to profile: \(profileId)"
        )
    }

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

        // A profile snapshot may have originated in either one of Claude
        // Code's stores. Never make a second copy of that same refresh-token
        // family: the first process to refresh it invalidates the other.
        let keychainLogin: String?
        do {
            keychainLogin = try readKeychainLoginAtWriteTarget(
                forAccountNamed: accountName
            )
        } catch {
            logCredentialDecision(
                "Could not read this account's Keychain item to determine "
                + "whether the stored CLI credential is at least as new; "
                + "leaving the Keychain unchanged rather than risking a "
                + "rollback: \(error.localizedDescription)",
                warning: true
            )
            return
        }

        if let keychainLogin,
           hasSameLoginPair(keychainLogin, as: jsonData) {
            logCredentialDecision(
                "Claude Code's Keychain item already holds this login for "
                + "\(Self.describeAccount(accountName)); nothing to apply"
            )
            return
        }

        if let keychainLogin,
           !isAtLeastAsFresh(jsonData, as: keychainLogin) {
            logCredentialDecision(
                "Cannot establish that the stored CLI credential is at "
                + "least as new as this account's Keychain login for "
                + "\(Self.describeAccount(accountName)); leaving the "
                + "Keychain login in place rather than risking a rollback"
            )
            return
        }

        if let fileLogin = readCanonicalCredentialsFile(
            forAccountNamed: accountName
        ), let snapshotRefreshToken = ClaudeCLITokenRefresher.refreshToken(
            in: jsonData
        ), ClaudeCLITokenRefresher.refreshToken(in: fileLogin)
            == snapshotRefreshToken {
            logCredentialDecision(
                "This login lives in Claude Code's credentials file for "
                + "\(Self.describeAccount(accountName)); not copying it "
                + "into the Keychain, where a second copy would let two "
                + "stores rotate one login out from under each other"
            )
            return
        }

        guard try commitClaudeCodeStoreWrite(
            jsonData,
            forAccountNamed: accountName,
            store: .keychain,
            purpose: "activating a profile"
        ) else { return }

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

        // Check and repair the Keychain item independently of the file. A
        // machine can legitimately have only one store, or two unrelated
        // logins in those stores; touching one must not decide for the other.
        let keychainLogin: String?
        do {
            keychainLogin = try readKeychainLoginAtWriteTarget(
                forAccountNamed: accountName
            )
        } catch {
            LoggingService.shared.log(
                "Could not read the live Claude Code login for "
                + "\(Self.describeAccount(accountName)) after renewing its "
                + "token; leaving it unchanged: \(error.localizedDescription)"
            )
            // A Keychain failure must not prevent an independent file repair.
            keychainLogin = nil
        }

        if let keychainLogin,
           ClaudeCLITokenRefresher.refreshToken(in: keychainLogin)
                == spentRefreshToken {
            if !isAtLeastAsFresh(renewed, as: keychainLogin) {
                LoggingService.shared.log(
                    "Cannot establish that the renewed token is at least as new "
                    + "as the live login for \(Self.describeAccount(accountName)); "
                    + "leaving that login in place rather than risking a rollback"
                )
            } else {
                do {
                    if try commitClaudeCodeStoreWrite(
                        renewed,
                        forAccountNamed: accountName,
                        store: .keychain,
                        purpose: "mirroring back a token this app rotated",
                        // The check above is a cheap early out; this is the
                        // one that counts, because it happens under
                        // `.storage-write` with the item re-read.
                        expectedRefreshToken: spentRefreshToken
                    ) {
                        LoggingService.shared.log(
                            "Mirrored the rotated token back into Claude Code's own login "
                            + "for \(Self.describeAccount(accountName)), so the CLI keeps "
                            + "working after the app spent its refresh token"
                        )
                    }
                } catch {
                    LoggingService.shared.logWarning(
                        "Could not write the rotated token back into Claude Code's "
                        + "login for \(Self.describeAccount(accountName)): "
                        + "\(error.localizedDescription). Claude Code may ask for a "
                        + "fresh sign-in."
                    )
                }
            }
        }

        guard let fileLogin = readCanonicalCredentialsFile(
            forAccountNamed: accountName
        ), ClaudeCLITokenRefresher.refreshToken(in: fileLogin)
            == spentRefreshToken else { return }

        guard isAtLeastAsFresh(renewed, as: fileLogin) else {
            let message =
                "Cannot establish that the renewed token is at least as new as "
                + "the login in Claude Code's credentials file for "
                + "\(Self.describeAccount(accountName)); leaving that file in place "
                + "rather than risking a rollback"
            logCredentialDecision(message)
            return
        }

        do {
            guard try commitClaudeCodeStoreWrite(
                renewed,
                forAccountNamed: accountName,
                store: .credentialsFile,
                purpose: "mirroring back a token this app rotated",
                expectedRefreshToken: spentRefreshToken
            ) else { return }
            let message =
                "Mirrored the rotated token back into Claude Code's credentials "
                + "file for \(Self.describeAccount(accountName)), so the terminals "
                + "that read that file keep working after the app spent its refresh token"
            logCredentialDecision(message)
        } catch {
            let message =
                "Could not write the rotated token back into Claude Code's "
                + "credentials file for \(Self.describeAccount(accountName)): "
                + "\(error.localizedDescription). Claude Code may ask for a fresh sign-in."
            logCredentialDecision(message, warning: true)
        }
    }

    private func logCredentialDecision(_ message: String, warning: Bool = false) {
        credentialLogSink?(message)
        if warning {
            LoggingService.shared.logWarning(message)
        } else {
            LoggingService.shared.log(message)
        }
    }

    /// Reads the exact Keychain item a write would target. The injected
    /// reader lets isolated tests model that item without opening a real
    /// Keychain, while production deliberately avoids service-name discovery.
    private func readKeychainLoginAtWriteTarget(
        forAccountNamed accountName: String?
    ) throws -> String? {
        if let keychainCredentialsReader {
            return try keychainCredentialsReader(accountName)
        }
        let serviceName = accountServiceNameForWriting(
            forAccountNamed: accountName
        ) ?? resolveServiceName()
        return try readKeychainSecret(serviceName: serviceName)
    }

    private func hasSameLoginPair(_ lhs: String, as rhs: String) -> Bool {
        guard let lhsAccessToken = accessToken(in: lhs),
              let lhsRefreshToken = ClaudeCLITokenRefresher.refreshToken(in: lhs),
              let rhsAccessToken = accessToken(in: rhs),
              let rhsRefreshToken = ClaudeCLITokenRefresher.refreshToken(in: rhs)
        else { return false }
        return lhsAccessToken == rhsAccessToken
            && lhsRefreshToken == rhsRefreshToken
    }

    private func accessToken(in credentialsJSON: String) -> String? {
        guard let data = credentialsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any]
        else { return nil }
        return oauth["accessToken"] as? String
    }

    /// Replaces only the top-level `claudeAiOauth` value. Re-serializing the
    /// entire file would alter unrelated values such as `mcpOAuth`; keeping
    /// the original bytes on either side means those credentials are exactly
    /// as Claude Code wrote them.
    private func replaceOAuthObject(
        in credentialsFile: Data,
        with renewed: String
    ) throws -> Data {
        guard let renewedData = renewed.data(using: .utf8),
              let renewedObject = try JSONSerialization.jsonObject(
                with: renewedData
              ) as? [String: Any],
              let renewedOAuth = renewedObject["claudeAiOauth"],
              JSONSerialization.isValidJSONObject(renewedOAuth),
              let replacement = try? JSONSerialization.data(
                withJSONObject: renewedOAuth
              ),
              let range = topLevelObjectValueRange(
                named: "claudeAiOauth", in: credentialsFile
              )
        else { throw ClaudeCodeError.invalidJSON }

        var updated = credentialsFile
        updated.replaceSubrange(range, with: replacement)
        return updated
    }

    /// Returns the byte range of a named top-level object's value. Credentials
    /// JSON is UTF-8, and JSON punctuation is ASCII, so byte offsets preserve
    /// every unrelated byte even when token values contain Unicode.
    private func topLevelObjectValueRange(
        named name: String,
        in data: Data
    ) -> Range<Data.Index>? {
        let bytes = Array(data)
        var index = 0

        func skipWhitespace() {
            while index < bytes.count,
                  bytes[index] == 0x20 || bytes[index] == 0x09
                    || bytes[index] == 0x0A || bytes[index] == 0x0D {
                index += 1
            }
        }

        func skipJSONString() -> Range<Int>? {
            guard index < bytes.count, bytes[index] == 0x22 else { return nil }
            let start = index
            index += 1
            while index < bytes.count {
                if bytes[index] == 0x5C {
                    index += 2
                } else if bytes[index] == 0x22 {
                    index += 1
                    return start..<index
                } else {
                    index += 1
                }
            }
            return nil
        }

        func objectRange() -> Range<Int>? {
            guard index < bytes.count, bytes[index] == 0x7B else { return nil }
            let start = index
            var depth = 0
            var inString = false
            var escaped = false
            while index < bytes.count {
                let byte = bytes[index]
                if inString {
                    if escaped {
                        escaped = false
                    } else if byte == 0x5C {
                        escaped = true
                    } else if byte == 0x22 {
                        inString = false
                    }
                } else if byte == 0x22 {
                    inString = true
                } else if byte == 0x7B {
                    depth += 1
                } else if byte == 0x7D {
                    depth -= 1
                    if depth == 0 {
                        index += 1
                        return start..<index
                    }
                }
                index += 1
            }
            return nil
        }

        skipWhitespace()
        guard index < bytes.count, bytes[index] == 0x7B else { return nil }
        index += 1
        while index < bytes.count {
            skipWhitespace()
            if bytes[index] == 0x7D { return nil }
            guard let keyRange = skipJSONString() else { return nil }
            let keyData = Data(bytes[keyRange])
            guard let key = try? JSONSerialization.jsonObject(
                with: keyData, options: .fragmentsAllowed
            ) as? String else { return nil }
            skipWhitespace()
            guard index < bytes.count, bytes[index] == 0x3A else { return nil }
            index += 1
            skipWhitespace()

            if key == name {
                guard let valueRange = objectRange() else { return nil }
                return valueRange.lowerBound..<valueRange.upperBound
            }

            // We only need to traverse top-level fields. JSONSerialization
            // already validated this file before callers reach here, so the
            // non-object values can be skipped by matching their next comma
            // or closing brace outside quoted strings.
            var inString = false
            var escaped = false
            var nestedDepth = 0
            while index < bytes.count {
                let byte = bytes[index]
                if inString {
                    if escaped { escaped = false }
                    else if byte == 0x5C { escaped = true }
                    else if byte == 0x22 { inString = false }
                } else if byte == 0x22 {
                    inString = true
                } else if byte == 0x7B || byte == 0x5B {
                    nestedDepth += 1
                } else if byte == 0x7D || byte == 0x5D {
                    if nestedDepth == 0 { break }
                    nestedDepth -= 1
                } else if byte == 0x2C && nestedDepth == 0 {
                    break
                }
                index += 1
            }
            guard index < bytes.count else { return nil }
            if bytes[index] == 0x2C {
                index += 1
            } else if bytes[index] == 0x7D {
                return nil
            } else {
                return nil
            }
        }
        return nil
    }

    /// The credentials-file half of the write, reachable only from
    /// `performGuardedWrite`. It keeps its own byte-level optimistic
    /// concurrency check: the chokepoint's refusals rule on whether the file
    /// is the right store, this rules on whether its bytes still say what we
    /// read.
    private func performCredentialsFileWrite(
        inCredentialsFileFor accountName: String?,
        with renewed: String,
        expectedRefreshToken: String
    ) throws -> Bool {
        let fileURL = credentialsFileURL(forAccountNamed: accountName)
        let original = try Data(contentsOf: fileURL)
        guard let current = String(data: original, encoding: .utf8),
              ClaudeCLITokenRefresher.refreshToken(in: current)
                == expectedRefreshToken,
              isAtLeastAsFresh(renewed, as: current) else { return false }
        let updated = try replaceOAuthObject(in: original, with: renewed)
        let directory = fileURL.deletingLastPathComponent()
        let temporaryURL = directory.appendingPathComponent(
            ".credentials-\(UUID().uuidString).tmp"
        )
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let descriptor = open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw POSIXError(
                POSIXErrorCode(rawValue: errno) ?? .EIO
            )
        }
        guard close(descriptor) == 0 else {
            throw POSIXError(
                POSIXErrorCode(rawValue: errno) ?? .EIO
            )
        }
        // `open` above creates this file as 0600 before any token bytes are
        // written. Reopening an existing file preserves that safe mode.
        try updated.write(to: temporaryURL)
        guard try Data(contentsOf: fileURL) == original else { return false }
        guard rename(temporaryURL.path, fileURL.path) == 0 else {
            throw POSIXError(
                POSIXErrorCode(rawValue: errno) ?? .EIO
            )
        }
        return true
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

    /// How close to expiry Claude Code lets an access token get before it
    /// refreshes: five minutes.
    static let refreshLeadTime: TimeInterval = 300

    /// Whether Claude Code would consider this token due for a refresh.
    ///
    /// The app used to wait until the token had actually expired, which
    /// guarantees a window where every request fails while the refresh is
    /// still in flight. Claude Code refreshes five minutes early, and
    /// matching it means both programs reach for the same token at the same
    /// point in its life rather than at two different ones.
    func isTokenDueForRefresh(
        _ jsonData: String,
        leadTime: TimeInterval = ClaudeCodeSyncService.refreshLeadTime,
        now: Date = Date()
    ) -> Bool {
        guard let expiryDate = extractTokenExpiry(from: jsonData) else {
            // No expiry recorded means nothing can be said about its age.
            // Treated as valid, exactly as `isTokenExpired` treats it.
            return false
        }
        return now.addingTimeInterval(leadTime) >= expiryDate
    }

    /// Whether a `claude` process is relying on this account's login right
    /// now.
    ///
    /// The single question the whole token-race fix turns on, asked in one
    /// place so callers cannot each derive the account's configuration
    /// directory their own way. A nil or empty account name means the
    /// default account, `~/.claude`.
    func isAccountInUse(forAccountNamed accountName: String?) -> Bool {
        liveProcessDetector.isLive(
            configurationDirectory:
                credentialsDirectory(forAccountNamed: accountName).path
        )
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
