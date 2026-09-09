import XCTest
@testable import Claude_Usage

@MainActor
final class ClaudeWizardCompletionTests: HostedAppTestCase {
    func testCompletionWithLinkChosenSavesBothSignIns() async throws {
        let context = try await makeContext()

        let completed = try await context.dependencies
            .completeClaudeManualSetup(
                sessionKey: "browser-session",
                organizationID: "browser-org",
                autoStartSessionEnabled: false,
                terminalCredentialsJSON: validTerminalLogin,
                terminalAccountName: "work-account",
                target: .existing(context.profile.id)
            )
        let credentials = try context.manager.loadCredentials(
            for: completed.id
        )

        XCTAssertEqual(credentials.claudeSessionKey, "browser-session")
        XCTAssertEqual(credentials.organizationId, "browser-org")
        XCTAssertEqual(credentials.cliCredentialsJSON, validTerminalLogin)
        XCTAssertTrue(completed.hasCliAccount)
        XCTAssertEqual(completed.cliAccountName, "work-account")
        XCTAssertNotNil(completed.cliAccountSyncedAt)
        XCTAssertEqual(ClaudeSetupState.of(completed), .complete)
    }

    func testCompletionWithoutLinkSavesBrowserSignInOnly() async throws {
        let context = try await makeContext()

        let completed = try await context.dependencies
            .completeClaudeManualSetup(
                sessionKey: "browser-session",
                organizationID: "browser-org",
                autoStartSessionEnabled: false,
                target: .existing(context.profile.id)
            )
        let credentials = try context.manager.loadCredentials(
            for: completed.id
        )

        XCTAssertTrue(completed.hasClaudeAI)
        XCTAssertNil(credentials.cliCredentialsJSON)
        XCTAssertFalse(completed.hasCliAccount)
        XCTAssertNil(completed.cliAccountName)
        XCTAssertNil(completed.cliAccountSyncedAt)
        XCTAssertEqual(ClaudeSetupState.of(completed), .browserOnly)
    }

    func testCompletionRejectsTokenlessDetectedLoginAndStillSavesBrowserSignIn()
        async throws
    {
        let context = try await makeContext()
        let tokenless = #"{"claudeAiOauth":{},"mcpOAuth":{"server":"token"}}"#

        let completed = try await context.dependencies
            .completeClaudeManualSetup(
                sessionKey: "browser-session",
                organizationID: "browser-org",
                autoStartSessionEnabled: false,
                terminalCredentialsJSON: tokenless,
                terminalAccountName: "not-a-login",
                target: .existing(context.profile.id)
            )
        let credentials = try context.manager.loadCredentials(
            for: completed.id
        )

        XCTAssertTrue(completed.hasClaudeAI)
        XCTAssertNil(credentials.cliCredentialsJSON)
        XCTAssertFalse(completed.hasCliAccount)
        XCTAssertNil(completed.cliAccountName)
        XCTAssertNil(completed.cliAccountSyncedAt)
        XCTAssertEqual(ClaudeSetupState.of(completed), .browserOnly)
    }

    func testCompletionRecordsTheChromeProfileTheKeyCameFrom() async throws {
        let context = try await makeContext()
        let source = ProfileChromeSessionKeySource(
            directoryName: "Profile 19",
            label: "Work — Profile 19"
        )

        let completed = try await context.dependencies
            .completeClaudeManualSetup(
                sessionKey: "chrome-session",
                organizationID: "browser-org",
                autoStartSessionEnabled: false,
                target: .existing(context.profile.id),
                chromeSessionKeySource: .set(source)
            )

        // The origin is committed with the key, so the profile it comes back
        // as already carries both.
        XCTAssertEqual(completed.chromeSessionKeySource, source)
        XCTAssertEqual(
            context.manager.profiles.first?.chromeSessionKeySource,
            source
        )
    }

    func testHandEnteredCompletionClearsAPreviousChromeOrigin() async throws {
        let context = try await makeContext()
        context.manager.updateChromeSessionKeySource(
            ProfileChromeSessionKeySource(
                directoryName: "Profile 19",
                label: "Work — Profile 19"
            ),
            for: context.profile.id
        )

        let completed = try await context.dependencies
            .completeClaudeManualSetup(
                sessionKey: "typed-session",
                organizationID: "browser-org",
                autoStartSessionEnabled: false,
                target: .existing(context.profile.id),
                chromeSessionKeySource: .set(nil)
            )

        // A key nobody read from Chrome must not inherit the origin of the
        // key it replaced, or an automatic re-read would overwrite it.
        XCTAssertNil(completed.chromeSessionKeySource)
        XCTAssertNil(
            context.manager.profiles.first?.chromeSessionKeySource
        )
    }

    private struct Context {
        let manager: ProfileManager
        let profile: Profile
        let dependencies: ProviderUIDependencies
    }

    private var validTerminalLogin: String {
        #"{"claudeAiOauth":{"accessToken":"terminal-token"}}"#
    }

    private func makeContext() async throws -> Context {
        let store = retain(makeIsolatedProfileStore())
        let manager = retain(
            ProfileManager(
                profileStore: store,
                activationClaudeEffects: .init(
                    resyncBeforeSwitching: { _ in },
                    applyProfileCredentials: { _ in },
                    switchAccountAndSync: { _ in }
                ),
                activationCodexEffects: .noOp,
                lifecycleEventSink: .init(
                    deletionStarted: { _ in },
                    deletionCompleted: { _ in }
                ),
                postClaudeCreationMigration: { profileID in
                    guard let profile = store.loadProfiles().first(where: {
                        $0.id == profileID
                    }) else {
                        throw TestFailure.missingProfile
                    }
                    return profile
                }
            )
        )
        manager.loadProfiles()
        let profile = try manager.createInitialProfile(
            name: "Claude",
            providerConfiguration: .claude
        )
        await manager.activateProfile(profile.id)
        let dependencies = retain(
            ProviderUIDependencies(
                profileManager: manager,
                availability: .testing(),
                codexCapabilities: CodexProviderFactory.capabilities,
                requestCapture: { _ in
                    throw ProviderUIOperationError.wrongProvider
                },
                setupCompletionWriter: {},
                setupCompletionReader: { false }
            )
        )
        return Context(
            manager: manager,
            profile: profile,
            dependencies: dependencies
        )
    }

    private enum TestFailure: Error {
        case missingProfile
    }
}
