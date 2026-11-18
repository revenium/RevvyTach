//
//  ClaudeLinkedAccountCredentialTests.swift
//  Claude UsageTests
//

import XCTest
@testable import Claude_Usage

/// The identity a profile is checked against must come from the credential
/// its requests actually send.
///
/// A linked account directory can hold two credential files, and
/// `readLinkedAccountCredentials` prefers `.credentials.json`. Reading the
/// identity from `.claude.json` regardless meant the guard could inspect one
/// credential while the request authenticated with the other, which holds
/// only for as long as the two files happen to name the same account.
///
/// `ClaudeSwitchService` resolves paths from the real `HOME`, so these tests
/// redirect it to a temporary directory, the way `CodexSwitchServiceTests`
/// does.
final class ClaudeLinkedAccountCredentialTests: XCTestCase {
    private var originalHome: String?
    private var temporaryHome: URL!

    /// The account `.claude.json` names.
    private let fileAccount = "048a9b16-1391-4949-94be-b4f0f3c866c3"
    /// A different account, named by `.credentials.json`.
    private let credentialAccount = "ed73b56e-85e9-4a68-81e6-e7db3e26c2b9"
    private let directoryName = "fixture-account"

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalHome = ProcessInfo.processInfo.environment["HOME"]
        temporaryHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "claude-linked-credential-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: accountDirectory,
            withIntermediateDirectories: true
        )
        setenv("HOME", temporaryHome.path, 1)
    }

    override func tearDownWithError() throws {
        if let originalHome {
            setenv("HOME", originalHome, 1)
        } else {
            unsetenv("HOME")
        }
        try? FileManager.default.removeItem(at: temporaryHome)
        try super.tearDownWithError()
    }

    private var accountDirectory: URL {
        temporaryHome
            .appendingPathComponent(".claude-accounts", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    private func write(_ contents: String, to fileName: String) throws {
        try contents.write(
            to: accountDirectory.appendingPathComponent(fileName),
            atomically: true,
            encoding: .utf8
        )
    }

    private func claudeJSON(account: String) -> String {
        """
        {
          "oauthAccount": {
            "accountUuid": "\(account)",
            "emailAddress": "someone@example.com",
            "accessToken": "sk-ant-oat01-claude-json-token"
          }
        }
        """
    }

    private func credentialsJSON(account: String?) -> String {
        let identity = account.map {
            ", \"accountUuid\": \"\($0)\", "
            + "\"emailAddress\": \"other@example.com\""
        } ?? ""
        return """
        {
          "claudeAiOauth": {
            "accessToken": "sk-ant-oat01-credentials-file-token",
            "refreshToken": "sk-ant-ort01-credentials-file-refresh",
            "expiresAt": 4102444800000\(identity)
          }
        }
        """
    }

    // MARK: - The control

    /// With one file present the identity is that file's, which is what the
    /// guard has always read. Without this the assertions below could pass
    /// on a resolver that answers nothing at all.
    func testTheClaudeJSONAccountIsReadWhenItIsTheOnlyCredential() throws {
        try write(claudeJSON(account: fileAccount), to: ".claude.json")

        let identity = ClaudeSwitchService.shared.linkedAccountIdentity(
            directoryName: directoryName
        )

        XCTAssertEqual(identity?.uuid, fileAccount)
        XCTAssertEqual(identity?.emailAddress, "someone@example.com")
    }

    // MARK: - One resolver, one answer

    /// Both files present, naming different accounts. The credential the
    /// request will send is `.credentials.json`, so that is the account the
    /// guard must judge — not the one the stale `.claude.json` still names.
    func testTheIdentityFollowsTheCredentialThatWillAuthenticate() throws {
        try write(claudeJSON(account: fileAccount), to: ".claude.json")
        try write(
            credentialsJSON(account: credentialAccount),
            to: ".credentials.json"
        )

        let service = ClaudeSwitchService.shared
        let credentials = service.readLinkedAccountCredentials(
            directoryName: directoryName
        )
        let identity = service.linkedAccountIdentity(
            directoryName: directoryName
        )

        XCTAssertEqual(
            identity?.uuid,
            credentialAccount,
            "the identity must come from the file the token comes from"
        )
        XCTAssertEqual(
            credentials?.contains("credentials-file-token"),
            true,
            "the token must still come from the preferred file"
        )
    }

    /// The preferred credential carries no account uuid, which is the
    /// ordinary shape of Claude Code's own credential store. That is "not
    /// established", never a match against the other file: a guard that
    /// answered with `.claude.json`'s account here would be validating an
    /// identity the request does not use.
    func testACredentialWithNoIdentityEstablishesNothing() throws {
        try write(claudeJSON(account: fileAccount), to: ".claude.json")
        try write(credentialsJSON(account: nil), to: ".credentials.json")

        XCTAssertNil(
            ClaudeSwitchService.shared.linkedAccountIdentity(
                directoryName: directoryName
            )
        )
        XCTAssertEqual(
            ClaudeAccountIdentityGuard.verdict(
                claudeCodeAccount: nil,
                for: ClaudeAccountIdentityGuard.ProfileBinding(
                    id: UUID(),
                    name: "fixture",
                    organizationUUID: nil,
                    accountUUID: fileAccount
                ),
                otherProfiles: []
            ),
            .undetermined,
            "an identity that could not be read must not blank a reading"
        )
    }

    /// A credential file that carries no login at all loses precedence, the
    /// same way it does for the token, so the fallback file answers both
    /// questions.
    func testAFileWithNoLoginDoesNotWinPrecedence() throws {
        try write(claudeJSON(account: fileAccount), to: ".claude.json")
        try write("{\"mcpServers\": {}}", to: ".credentials.json")

        XCTAssertEqual(
            ClaudeSwitchService.shared.linkedAccountIdentity(
                directoryName: directoryName
            )?.uuid,
            fileAccount
        )
    }

    /// No directory, no answer.
    func testAnAbsentDirectoryEstablishesNothing() {
        XCTAssertNil(
            ClaudeSwitchService.shared.linkedAccountIdentity(
                directoryName: "no-such-account"
            )
        )
        XCTAssertNil(
            ClaudeSwitchService.shared.readLinkedAccountCredentials(
                directoryName: "no-such-account"
            )
        )
    }
}
