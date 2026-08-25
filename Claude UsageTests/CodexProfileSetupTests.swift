import Foundation
import CodexUsageProvider
import UsageCore
import XCTest
@testable import Claude_Usage

@MainActor
final class CodexProfileSetupTests: HostedAppTestCase {
    func testMixedProviderCRUDAndProviderIdentityIsImmutable()
        async throws
    {
        let context = makeContext()
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let dependencies = makeDependencies(manager: context.manager)

        let claude = try dependencies.createProfile(
            name: "Claude",
            provider: .claude,
            linkedCodexHome: nil
        )
        let codex = try dependencies.createProfile(
            name: "Codex",
            provider: .codex,
            linkedCodexHome: home.path
        )

        XCTAssertEqual(
            context.manager.profiles.map(\.providerID),
            [.claude, .codex]
        )
        XCTAssertEqual(
            claude.iconConfig,
            .default(for: .claude)
        )
        XCTAssertEqual(
            codex.iconConfig,
            .default(for: .codex)
        )
        XCTAssertEqual(
            context.store.loadProfiles().first {
                $0.id == codex.id
            }?.iconConfig,
            .default(for: .codex)
        )
        try dependencies.updateName(
            "Renamed Codex",
            profileID: codex.id
        )
        await dependencies.activateProfile(codex.id)
        XCTAssertEqual(
            context.manager.activeProfile?.id,
            codex.id
        )

        var illegal = try XCTUnwrap(
            dependencies.profile(id: codex.id)
        )
        illegal.providerConfiguration = .claude
        XCTAssertThrowsError(
            try context.manager.updateProfileThrowing(illegal)
        ) {
            XCTAssertEqual(
                $0 as? ProfileProviderConfigurationError,
                .providerChangeNotAllowed(codex.id)
            )
        }

        try dependencies.deleteProfile(claude.id)
        XCTAssertEqual(
            context.manager.profiles.map(\.id),
            [codex.id]
        )
    }

    func testDuplicateAndSymlinkCodexHomesFailClosed() throws {
        let context = makeContext()
        let root = try makeHome()
        defer { try? FileManager.default.removeItem(at: root) }
        let alias = root.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(
            at: alias,
            withDestinationURL: root
        )
        defer { try? FileManager.default.removeItem(at: alias) }
        let dependencies = makeDependencies(manager: context.manager)

        _ = try dependencies.createProfile(
            name: "First",
            provider: .codex,
            linkedCodexHome: root.path
        )

        XCTAssertThrowsError(
            try dependencies.createProfile(
                name: "Duplicate",
                provider: .codex,
                linkedCodexHome: alias.path
            )
        ) {
            guard case .duplicateCodexHome =
                    $0 as? ProfileProviderConfigurationError else {
                return XCTFail("Expected duplicate physical home")
            }
        }
    }

    func testProductionGateEnablesCodexCreation()
        throws
    {
        let context = makeContext()
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let dependencies = retain(ProviderUIDependencies(
            profileManager: context.manager,
            availability: .production,
            codexCapabilities: CodexProviderFactory.capabilities,
            requestCapture: { _ in
                XCTFail("Profile creation must not capture a request")
                throw ProviderUIOperationError.wrongProvider
            },
            setupCompletionWriter: {},
            setupCompletionReader: { false }
        ))

        XCTAssertTrue(
            dependencies.availability.codexSupportEnabled
        )
        let profile = try dependencies.createProfile(
            name: "Codex",
            provider: .codex,
            linkedCodexHome: home.path
        )
        XCTAssertEqual(profile.providerID, .codex)
    }

    func testExplicitDisabledGatePreventsCodexCreationAndOperations()
        throws
    {
        let context = makeContext()
        let dependencies = retain(ProviderUIDependencies(
            profileManager: context.manager,
            availability: .testing(codexRefreshEnabled: false),
            codexCapabilities: CodexProviderFactory.capabilities,
            requestCapture: { _ in
                XCTFail("Disabled capture must not run")
                throw ProviderUIOperationError.featureDisabled
            },
            setupCompletionWriter: {},
            setupCompletionReader: { false }
        ))

        XCTAssertFalse(
            dependencies.availability.codexSupportEnabled
        )
        XCTAssertThrowsError(
            try dependencies.createProfile(
                name: "Codex",
                provider: .codex,
                linkedCodexHome: "/tmp/unused"
            )
        ) {
            XCTAssertEqual(
                $0 as? ProviderUIOperationError,
                .featureDisabled
            )
        }

        let disabledProfile = Profile(
            name: "Disabled Codex",
            providerConfiguration: .codex(.init())
        )
        XCTAssertThrowsError(
            try dependencies.captureRequest(
                for: disabledProfile
            )
        ) {
            XCTAssertEqual(
                $0 as? ProviderUIOperationError,
                .featureDisabled
            )
        }
        XCTAssertThrowsError(
            try dependencies.captureCodexDraftRequest(
                homePath: "/tmp/unused"
            )
        ) {
            XCTAssertEqual(
                $0 as? ProviderUIOperationError,
                .featureDisabled
            )
        }
    }

    func testAccountModesArePresentedWithoutInventedData()
        async throws
    {
        let scenarios: [
            (
                Error?,
                ProviderHealth,
                (ProviderAccountViewState) -> Bool
            )
        ] = [
            (
                UsageProviderError.unauthenticated,
                ProviderHealth(
                    status: .unauthenticated,
                    checkedAt: Date(),
                    issue: .authenticationRequired
                ),
                {
                    if case .unauthenticated = $0 { return true }
                    return false
                }
            ),
            (
                UsageProviderError.unsupportedAccount,
                ProviderHealth(
                    status: .unsupported,
                    checkedAt: Date(),
                    issue: .accountUnsupported
                ),
                {
                    if case .unsupported = $0 { return true }
                    return false
                }
            )
        ]

        for (error, health, matches) in scenarios {
            let setup = try makeCodexSetup(
                health: health,
                account: {
                    if let error { throw error }
                    return nil
                }
            )
            defer {
                try? FileManager.default.removeItem(
                    at: setup.home
                )
            }
            let model = makeViewModel(setup.dependencies)
            model.selectProfile(setup.profile.id)
            model.refresh()
            await waitUntil {
                matches(model.accountState)
            }
            XCTAssertTrue(matches(model.accountState))
        }
    }

    func testRefreshDiscardsResultAfterRelinkRevisionChange()
        async throws
    {
        let gate = AsyncGate()
        let account = ProviderAccount(
            id: try ProviderAccountID("old-account"),
            displayName: "Old"
        )
        let setup = try makeCodexSetup(account: {
            await gate.wait()
            return account
        })
        defer { try? FileManager.default.removeItem(at: setup.home) }
        let replacement = try makeHome()
        defer { try? FileManager.default.removeItem(at: replacement) }
        let model = makeViewModel(setup.dependencies)

        model.selectProfile(setup.profile.id)
        model.refresh()
        await gate.waitUntilObserved()
        _ = try setup.dependencies.linkCodexHome(
            replacement.path,
            profileID: setup.profile.id
        )
        await gate.open()
        await waitUntil {
            if case .unavailable = model.accountState {
                return true
            }
            return false
        }
    }

    func testRestartDuringAwaitIsDeterministicallyIgnored()
        async throws
    {
        let login = LoginHarness()
        let setup = try makeCodexSetup(login: login)
        defer { try? FileManager.default.removeItem(at: setup.home) }
        let model = makeViewModel(setup.dependencies)
        model.selectProfile(setup.profile.id)

        model.startLogin(.browser)
        await waitUntil {
            if case .awaiting = model.loginState { return true }
            return false
        }
        model.startLogin(.deviceCode)

        let firstBeginCount = await login.beginCount
        XCTAssertEqual(firstBeginCount, 1)
        await login.complete(.failed)
        await waitUntil {
            if case .failed = model.loginState { return true }
            return false
        }
    }

    func testCancelThenImmediateRestartCannotPublishStaleIdle()
        async throws
    {
        let login = LoginHarness()
        let setup = try makeCodexSetup(login: login)
        defer { try? FileManager.default.removeItem(at: setup.home) }
        let model = makeViewModel(setup.dependencies)
        model.selectProfile(setup.profile.id)
        model.startLogin(.browser)
        await waitUntil {
            if case .awaiting = model.loginState { return true }
            return false
        }

        model.cancelLogin()
        model.startLogin(.deviceCode)
        let immediateBeginCount = await login.beginCount
        XCTAssertEqual(immediateBeginCount, 1)
        await waitUntil {
            model.loginState == .idle
        }
        model.startLogin(.deviceCode)
        await waitUntil {
            if case .awaiting = model.loginState { return true }
            return false
        }
        let restartedBeginCount = await login.beginCount
        XCTAssertEqual(restartedBeginCount, 2)
    }

    func testRelinkDuringLoginWaitDisconnectsStaleSession()
        async throws
    {
        let login = LoginHarness()
        let setup = try makeCodexSetup(login: login)
        defer { try? FileManager.default.removeItem(at: setup.home) }
        let replacement = try makeHome()
        defer { try? FileManager.default.removeItem(at: replacement) }
        let model = makeViewModel(setup.dependencies)
        model.selectProfile(setup.profile.id)
        model.startLogin(.browser)
        await waitUntil {
            if case .awaiting = model.loginState { return true }
            return false
        }

        _ = try setup.dependencies.linkCodexHome(
            replacement.path,
            profileID: setup.profile.id
        )
        await login.complete(.succeeded)
        await waitUntil {
            await login.disconnectCount > 0
        }
        let disconnectCount = await login.disconnectCount
        XCTAssertEqual(disconnectCount, 1)
        XCTAssertNotEqual(model.loginState, .succeeded)
    }

    func testRefreshDuringLoginKeepsSessionOwnedUntilTerminalDisconnect()
        async throws
    {
        let login = LoginHarness()
        let setup = try makeCodexSetup(login: login)
        defer { try? FileManager.default.removeItem(at: setup.home) }
        let model = makeViewModel(setup.dependencies)
        model.selectProfile(setup.profile.id)
        model.startLogin(.browser)
        await waitUntil {
            if case .awaiting = model.loginState { return true }
            return false
        }

        model.refresh()
        let beginCount = await login.beginCount
        XCTAssertEqual(beginCount, 1)
        await login.complete(.failed)

        await waitUntil {
            if case .failed = model.loginState { return true }
            return false
        }
        let disconnectCount = await login.disconnectCount
        XCTAssertEqual(disconnectCount, 1)
    }

    func testAlreadyAuthenticatedLoginDoesNotCreateWaitSession()
        async throws
    {
        let account = ProviderAccount(
            id: try ProviderAccountID("account"),
            displayName: "Person",
            planName: "Plus"
        )
        let setup = try makeCodexSetup(
            loginResult: .alreadyAuthenticated(account)
        )
        defer { try? FileManager.default.removeItem(at: setup.home) }
        let model = makeViewModel(setup.dependencies)
        model.selectProfile(setup.profile.id)

        model.startLogin(.browser)
        await waitUntil { model.loginState == .succeeded }

        guard case .linked(let snapshot) = model.accountState else {
            return XCTFail("Expected linked account")
        }
        XCTAssertEqual(snapshot.account, account)
    }

    func testLoginErrorsMapToActionableTypedMessages() {
        XCTAssertTrue(
            ProviderAccountViewModel.message(
                for: UsageProviderError.timedOut
            ).contains("time")
        )
        XCTAssertTrue(
            ProviderAccountViewModel.message(
                for: UsageProviderError.unsupportedAccount
            ).contains("subscription")
        )
        XCTAssertTrue(
            ProviderAccountViewModel.message(
                for: CodexProviderFactoryError.executableMissing
            ).contains("CLI")
        )
        XCTAssertFalse(
            ProviderAccountViewModel.message(
                for: UsageProviderError.transportFailure
            ).contains("auth.json")
        )
    }

    func testUnlinkRemovesOnlyAssociationAndNeverStartsProvider()
        throws
    {
        let captureCount = Counter()
        let setup = try makeCodexSetup(captureObserver: captureCount)
        defer { try? FileManager.default.removeItem(at: setup.home) }

        let updated = try setup.dependencies.unlinkCodexHome(
            profileID: setup.profile.id
        )

        XCTAssertNil(
            updated.providerConfiguration
                .codexConfiguration?.linkedHome
        )
        XCTAssertEqual(captureCount.value, 0)
    }

    func testCapabilitiesHideClaudeOnlyControlsForCodex()
        throws
    {
        let setup = try makeCodexSetup()
        defer { try? FileManager.default.removeItem(at: setup.home) }
        let capabilities = setup.dependencies.capabilities(
            for: .codex
        )

        XCTAssertTrue(capabilities.supports(.interactiveLogin))
        XCTAssertFalse(
            capabilities.supports(.automaticSessionStart)
        )
    }

    func testTypedNavigationRoutesBothProvidersAndExistingWindow()
        async throws
    {
        let context = makeContext()
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let dependencies = makeDependencies(manager: context.manager)
        let claude = try dependencies.createProfile(
            name: "Claude",
            provider: .claude,
            linkedCodexHome: nil
        )
        let codex = try dependencies.createProfile(
            name: "Codex",
            provider: .codex,
            linkedCodexHome: home.path
        )
        let controller = retain(
            SettingsWindowBuilder.makeController(
                size: CGSize(width: 720, height: 600),
                dependencies: dependencies,
                destination:
                    .providerAccount(profileID: codex.id)
            )
        )
        let navigation = controller.navigation
        XCTAssertTrue(navigation.isResolvingProfile)
        await waitUntil {
            !navigation.isResolvingProfile
        }
        XCTAssertNil(navigation.selectedProfileID)
        XCTAssertEqual(navigation.selectedSection, .providerAccount)
        XCTAssertEqual(context.manager.activeProfile?.id, codex.id)

        controller.navigate(
            to: .providerAccount(profileID: claude.id)
        )
        XCTAssertTrue(navigation.isResolvingProfile)
        await waitUntil {
            !navigation.isResolvingProfile
        }
        XCTAssertNil(navigation.selectedProfileID)
        XCTAssertEqual(navigation.selectedSection, .claudeAI)
        XCTAssertEqual(context.manager.activeProfile?.id, claude.id)
    }

    func testManualProfileSwitchWaitsForActivationThenNormalizesCredentials()
        async throws
    {
        let context = makeContext()
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let dependencies = makeDependencies(manager: context.manager)
        let claude = try dependencies.createProfile(
            name: "Claude",
            provider: .claude,
            linkedCodexHome: nil
        )
        let codex = try dependencies.createProfile(
            name: "Codex",
            provider: .codex,
            linkedCodexHome: home.path
        )
        let navigation = retain(
            SettingsNavigationModel(
                destination:
                    .providerAccount(profileID: claude.id)
            )
        )
        navigation.userSelectedProfile(
            codex.id,
            providerID: .codex,
            dependencies: dependencies
        )
        XCTAssertEqual(navigation.selectedProfileID, codex.id)
        XCTAssertTrue(navigation.isResolvingProfile)
        await waitUntil { !navigation.isResolvingProfile }
        XCTAssertNil(navigation.selectedProfileID)
        XCTAssertEqual(navigation.selectedSection, .providerAccount)
        XCTAssertEqual(context.manager.activeProfile?.id, codex.id)

        navigation.userSelectedProfile(
            claude.id,
            providerID: .claude,
            dependencies: dependencies
        )
        XCTAssertEqual(navigation.selectedProfileID, claude.id)
        XCTAssertTrue(navigation.isResolvingProfile)
        await waitUntil { !navigation.isResolvingProfile }
        XCTAssertNil(navigation.selectedProfileID)
        XCTAssertEqual(navigation.selectedSection, .claudeAI)
        XCTAssertEqual(context.manager.activeProfile?.id, claude.id)
    }

    func testProviderAwareWizardCanReopenForCodexAndIncompleteSetupReturns()
        throws
    {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let linked = try CodexHomeCanonicalizer().canonicalize(
            home.path
        )
        let profile = Profile(
            name: "Codex",
            providerConfiguration: .codex(
                .init(linkedHome: linked)
            )
        )
        var claudeProbeCount = 0

        XCTAssertTrue(
            SetupWizardDecision.canPresentProviderAwareWizard(
                activeProfile: profile
            )
        )
        XCTAssertTrue(
            SetupWizardDecision.shouldShow(
                hasShownWizardOnce: true,
                hasCompletedSetup: false,
                activeProfile: profile
            ) {
                claudeProbeCount += 1
                return true
            }
        )
        XCTAssertFalse(
            SetupWizardDecision.shouldShow(
                hasShownWizardOnce: true,
                hasCompletedSetup: true,
                activeProfile: profile
            ) {
                claudeProbeCount += 1
                return true
            }
        )
        XCTAssertEqual(claudeProbeCount, 0)
    }

    func testRefreshDiscardsResultAfterProfileDeletion()
        async throws
    {
        let gate = AsyncGate()
        let setup = try makeCodexSetup(account: {
            await gate.wait()
            return ProviderAccount(
                id: try ProviderAccountID("deleted-account")
            )
        })
        defer { try? FileManager.default.removeItem(at: setup.home) }
        _ = try setup.dependencies.createProfile(
            name: "Survivor",
            provider: .claude,
            linkedCodexHome: nil
        )
        let model = makeViewModel(setup.dependencies)
        model.selectProfile(setup.profile.id)
        model.refresh()
        await gate.waitUntilObserved()

        try setup.dependencies.deleteProfile(setup.profile.id)
        await gate.open()
        await waitUntil {
            if case .unavailable = model.accountState {
                return true
            }
            return false
        }
    }

    func testZeroProfileDraftBackFailureAndCancellationDoNotPersist()
        async throws
    {
        let context = makeContext()
        let login = LoginHarness()
        let dependencies = makeDraftDependencies(
            manager: context.manager,
            login: login,
            account: {
                throw UsageProviderError.unauthenticated
            }
        )
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let model = makeViewModel(dependencies)

        try model.selectDraftCodexHome(home.path)
        model.refresh()
        await waitUntil {
            if case .unauthenticated = model.accountState {
                return true
            }
            return false
        }
        XCTAssertTrue(context.manager.profiles.isEmpty)

        model.startLogin(.browser)
        await waitUntil {
            if case .awaiting = model.loginState { return true }
            return false
        }
        model.cancelLogin()
        await waitUntil { model.loginState == .idle }
        model.invalidateDraft()

        XCTAssertTrue(context.manager.profiles.isEmpty)
        XCTAssertNil(context.manager.activeProfile)
    }

    func testZeroProfileDraftCommitsOnlyAfterVerifiedSuccess()
        async throws
    {
        let context = makeContext()
        let account = ProviderAccount(
            id: try ProviderAccountID("verified"),
            displayName: "Verified",
            planName: "Plus"
        )
        let dependencies = makeDraftDependencies(
            manager: context.manager,
            account: { account }
        )
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let model = makeViewModel(dependencies)

        try model.selectDraftCodexHome(home.path)
        model.refresh()
        await waitUntil {
            if case .linked = model.accountState { return true }
            return false
        }
        XCTAssertTrue(context.manager.profiles.isEmpty)
        let identity = try XCTUnwrap(
            model.verifiedDraftIdentity
        )

        let profile = try dependencies.commitCodexDraft(
            name: "Codex",
            homePath: home.path,
            verifiedIdentity: identity
        )

        XCTAssertEqual(context.manager.profiles, [profile])
        XCTAssertEqual(context.manager.activeProfile?.id, profile.id)
    }

    func testDraftPathEditAndSamePathReplacementRequireReverification()
        throws
    {
        let context = makeContext()
        let dependencies = makeDraftDependencies(
            manager: context.manager
        )
        let first = try makeHome()
        let second = try makeHome()
        defer { try? FileManager.default.removeItem(at: first) }
        defer { try? FileManager.default.removeItem(at: second) }
        let model = makeViewModel(dependencies)

        try model.selectDraftCodexHome(first.path)
        let identity = try XCTUnwrap(
            model.verifiedDraftIdentity
        )
        XCTAssertThrowsError(
            try dependencies.commitCodexDraft(
                name: nil,
                homePath: second.path,
                verifiedIdentity: identity
            )
        ) {
            XCTAssertEqual(
                $0 as? CodexHomeCanonicalizationError,
                .changedSinceVerification
            )
        }
        XCTAssertTrue(context.manager.profiles.isEmpty)

        let moved = first.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: first, to: moved)
        defer { try? FileManager.default.removeItem(at: moved) }
        try FileManager.default.createDirectory(
            at: first,
            withIntermediateDirectories: true
        )
        XCTAssertThrowsError(
            try dependencies.commitCodexDraft(
                name: nil,
                homePath: first.path,
                verifiedIdentity: identity
            )
        ) {
            XCTAssertEqual(
                $0 as? CodexHomeCanonicalizationError,
                .changedSinceVerification
            )
        }
        XCTAssertTrue(context.manager.profiles.isEmpty)
    }

    func testDraftReplacementDuringRefreshInvalidatesVerification()
        async throws
    {
        let context = makeContext()
        let gate = AsyncGate()
        let dependencies = makeDraftDependencies(
            manager: context.manager,
            account: {
                await gate.wait()
                return ProviderAccount(
                    id: try ProviderAccountID("stale-draft")
                )
            }
        )
        let home = try makeHome()
        let moved = home.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        defer { try? FileManager.default.removeItem(at: moved) }
        let model = makeViewModel(dependencies)

        try model.selectDraftCodexHome(home.path)
        model.refresh()
        await gate.waitUntilObserved()
        try FileManager.default.moveItem(at: home, to: moved)
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: true
        )
        await gate.open()

        await waitUntil {
            if case .unavailable = model.accountState {
                return true
            }
            return false
        }
        XCTAssertNil(model.verifiedDraftIdentity)
        XCTAssertTrue(context.manager.profiles.isEmpty)
    }

    func testFailedDraftReselectionClearsPreviouslyVerifiedIdentity()
        throws
    {
        let context = makeContext()
        let dependencies = makeDraftDependencies(
            manager: context.manager
        )
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let model = makeViewModel(dependencies)

        try model.selectDraftCodexHome(home.path)
        XCTAssertNotNil(model.verifiedDraftIdentity)
        XCTAssertThrowsError(
            try model.selectDraftCodexHome(
                home.appendingPathComponent("missing").path
            )
        )

        XCTAssertNil(model.verifiedDraftIdentity)
        XCTAssertEqual(model.accountState, .idle)
        XCTAssertTrue(context.manager.profiles.isEmpty)
    }

    func testDismissDropsTerminalLateRefreshResult()
        async throws
    {
        let gate = AsyncGate()
        let setup = try makeCodexSetup(account: {
            await gate.wait()
            return ProviderAccount(
                id: try ProviderAccountID("late-result")
            )
        })
        defer { try? FileManager.default.removeItem(at: setup.home) }
        let model = makeViewModel(setup.dependencies)

        model.selectProfile(setup.profile.id)
        model.refresh()
        await gate.waitUntilObserved()
        model.dismiss()
        await gate.open()
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(model.accountState, .idle)
        XCTAssertEqual(model.loginState, .idle)
    }

    func testCLIDetectedClaudeSetupFromActiveCodexCreatesAndActivatesClaude()
        async throws
    {
        let context = makeContext()
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let codex = try context.manager.createInitialCodexProfile(
            name: "Codex",
            linkedHomePath: home.path
        )
        let completion = Counter()
        let dependencies = makeDependencies(
            manager: context.manager,
            setupCompletionWriter: {
                completion.increment()
            }
        )

        let claude = try await dependencies
            .completeClaudeCLISetup(
                credentials: #"{"token":"test-only"}"#
            )

        XCTAssertEqual(context.manager.profiles.count, 2)
        XCTAssertEqual(claude.providerID, .claude)
        XCTAssertEqual(context.manager.activeProfile?.id, claude.id)
        XCTAssertNil(
            dependencies.profile(id: codex.id)?
                .cliCredentialsJSON
        )
        XCTAssertNotNil(
            dependencies.profile(id: claude.id)?
                .cliCredentialsJSON
        )
        XCTAssertEqual(completion.value, 1)
    }

    func testManualClaudeSetupFromActiveCodexCreatesAndActivatesClaude()
        async throws
    {
        let context = makeContext()
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let codex = try context.manager.createInitialCodexProfile(
            name: "Codex",
            linkedHomePath: home.path
        )
        let completion = Counter()
        let dependencies = makeDependencies(
            manager: context.manager,
            setupCompletionWriter: {
                completion.increment()
            }
        )

        let claude = try await dependencies
            .completeClaudeManualSetup(
                sessionKey: "test-session-key",
                organizationID: "test-org",
                autoStartSessionEnabled: true
            )

        XCTAssertEqual(context.manager.profiles.count, 2)
        XCTAssertEqual(claude.providerID, .claude)
        XCTAssertEqual(context.manager.activeProfile?.id, claude.id)
        XCTAssertTrue(claude.autoStartSessionEnabled)
        XCTAssertNil(
            dependencies.profile(id: codex.id)?
                .claudeSessionKey
        )
        let credentials = try context.manager.loadCredentials(
            for: claude.id
        )
        XCTAssertEqual(
            credentials.claudeSessionKey,
            "test-session-key"
        )
        XCTAssertEqual(credentials.organizationId, "test-org")
        XCTAssertEqual(completion.value, 1)
    }

    func testManualClaudeSetupRejectsExistingTargetAfterActiveProfileSwitch()
        async throws
    {
        let context = makeContext()
        let first = try context.manager.createInitialProfile(
            name: "First Claude",
            providerConfiguration: .claude
        )
        let second = try context.manager.createProfileThrowing(
            name: "Second Claude",
            providerConfiguration: .claude
        )
        await context.manager.activateProfile(second.id)
        let dependencies = makeDependencies(manager: context.manager)

        do {
            _ = try await dependencies.completeClaudeManualSetup(
                sessionKey: "test-session-key",
                organizationID: "test-org",
                autoStartSessionEnabled: false,
                target: .existing(first.id)
            )
            XCTFail("Expected captured target switch to be rejected")
        } catch {
            XCTAssertEqual(
                error as? ProviderUIOperationError,
                .profileChanged
            )
        }
    }

    func testManualClaudeSetupRejectsNewTargetWhenClaudeAppeared()
        async throws
    {
        let context = makeContext()
        _ = try context.manager.createInitialProfile(
            name: "Appeared Claude",
            providerConfiguration: .claude
        )
        let dependencies = makeDependencies(manager: context.manager)

        do {
            _ = try await dependencies.completeClaudeManualSetup(
                sessionKey: "test-session-key",
                organizationID: "test-org",
                autoStartSessionEnabled: false,
                target: .newProfile
            )
            XCTFail("Expected new-profile target to be rejected")
        } catch {
            XCTAssertEqual(
                error as? ProviderUIOperationError,
                .profileChanged
            )
        }
    }

    func testManualClaudeSetupRetriesTheExactPartiallyCreatedProfile()
        async throws
    {
        let context = makeContext()
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let codex = try context.manager.createInitialCodexProfile(
            name: "Codex",
            linkedHomePath: home.path
        )
        let dependencies = makeDependencies(manager: context.manager)
        let createdClaude = try dependencies.createProfile(
            name: "Created Claude",
            provider: .claude,
            linkedCodexHome: nil
        )
        XCTAssertNil(context.manager.activeClaudeProfile)

        let completed = try await dependencies.completeClaudeManualSetup(
            sessionKey: "test-session-key",
            organizationID: "test-org",
            autoStartSessionEnabled: false,
            acceptSessionOnlyStorage: true,
            target: .createdProfile(createdClaude.id)
        )

        XCTAssertEqual(completed.id, createdClaude.id)
        XCTAssertEqual(context.manager.activeClaudeProfile?.id, createdClaude.id)
        XCTAssertEqual(context.manager.activeProfile?.id, createdClaude.id)
        XCTAssertEqual(context.manager.profiles.count, 2)
        XCTAssertEqual(dependencies.profile(id: codex.id)?.providerID, .codex)
    }

    func testIncompleteCodexCommitResumesExactExistingProfile()
        async throws
    {
        let context = makeContext()
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let existing = try context.manager
            .createInitialCodexProfile(
                name: "Existing Codex",
                linkedHomePath: home.path
            )
        let completion = Counter()
        let dependencies = makeDraftDependencies(
            manager: context.manager,
            setupCompletionWriter: {
                completion.increment()
            },
            setupCompletionReader: { false }
        )
        let model = makeViewModel(dependencies)

        try model.selectDraftCodexHome(home.path)
        model.refresh()
        await waitUntil {
            if case .linked = model.accountState { return true }
            return false
        }
        let identity = try XCTUnwrap(
            model.verifiedDraftIdentity
        )
        let resumed = try await dependencies.completeCodexSetup(
            name: "Ignored on resume",
            homePath: home.path,
            verifiedIdentity: identity
        )

        XCTAssertEqual(resumed.id, existing.id)
        XCTAssertEqual(context.manager.profiles.count, 1)
        XCTAssertEqual(context.manager.activeProfile?.id, existing.id)
        XCTAssertEqual(completion.value, 1)
    }

    func testCodexSetupWithExistingClaudeActivatesBeforeCompletion()
        async throws
    {
        let context = makeContext()
        let claude = try context.manager.createInitialProfile(
            name: "Claude",
            providerConfiguration: .claude
        )
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let completion = Counter()
        let dependencies = makeDraftDependencies(
            manager: context.manager,
            setupCompletionWriter: {
                XCTAssertNotEqual(
                    context.manager.activeProfile?.id,
                    claude.id
                )
                completion.increment()
            },
            setupCompletionReader: { false }
        )
        let model = makeViewModel(dependencies)

        try model.selectDraftCodexHome(home.path)
        model.refresh()
        await waitUntil {
            if case .linked = model.accountState { return true }
            return false
        }
        let identity = try XCTUnwrap(
            model.verifiedDraftIdentity
        )
        let codex = try await dependencies.completeCodexSetup(
            name: "Codex",
            homePath: home.path,
            verifiedIdentity: identity
        )

        XCTAssertEqual(context.manager.activeProfile?.id, codex.id)
        XCTAssertEqual(codex.providerID, .codex)
        XCTAssertEqual(completion.value, 1)
    }

    func testProfileMutationRetryAndPresentationStayProviderCorrect()
        throws
    {
        let context = makeContext()
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let dependencies = makeDependencies(manager: context.manager)
        _ = try dependencies.createProfile(
            name: "Claude",
            provider: .claude,
            linkedCodexHome: nil
        )
        let codex = try dependencies.createProfile(
            name: "Codex",
            provider: .codex,
            linkedCodexHome: home.path
        )
        var staleMetadata = codex
        staleMetadata.hasCliAccount = true
        staleMetadata.cliAccountName = "must-not-render"
        let presentation = ProviderProfilePresentation(
            profile: staleMetadata
        )

        try ProfileRowMutation.rename("Renamed").perform(
            profileID: codex.id,
            dependencies: dependencies
        )

        XCTAssertEqual(context.manager.profiles.count, 2)
        XCTAssertEqual(
            dependencies.profile(id: codex.id)?.name,
            "Renamed"
        )
        XCTAssertEqual(presentation.providerLabel, "Codex")
        XCTAssertFalse(
            presentation.detailText.contains("must-not-render")
        )
        XCTAssertTrue(presentation.isConnected)
        XCTAssertNotEqual(
            ProfileRenameErrorPresentation.genericMessage,
            ProfileDeletionErrorPresentation.genericMessage
        )
    }

    func testProviderPresentationRequiresCurrentPhysicalHome()
        throws
    {
        let home = try makeHome()
        let moved = home.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        defer { try? FileManager.default.removeItem(at: moved) }
        let linked = try CodexHomeCanonicalizer().canonicalize(
            home.path
        )
        let profile = Profile(
            name: "Codex",
            providerConfiguration: .codex(
                .init(linkedHome: linked)
            )
        )
        XCTAssertTrue(
            ProviderProfilePresentation(
                profile: profile
            ).isConnected
        )

        try FileManager.default.moveItem(at: home, to: moved)
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: true
        )
        let replaced = ProviderProfilePresentation(
            profile: profile
        )

        XCTAssertFalse(replaced.isConnected)
        XCTAssertTrue(
            replaced.detailText.localizedCaseInsensitiveContains(
                "relink"
            )
        )
    }

    func testInvalidTypedDestinationFallsBackToManageProfiles() {
        let context = makeContext()
        let dependencies = makeDependencies(manager: context.manager)
        let navigation = retain(SettingsNavigationModel())

        navigation.navigate(
            to: .providerAccount(profileID: UUID()),
            dependencies: dependencies
        )

        XCTAssertEqual(navigation.selectedSection, .manageProfiles)
        XCTAssertNil(navigation.selectedProfileID)
        XCTAssertFalse(navigation.isResolvingProfile)
    }

    func testCompletionFlagWaitsForSuccessfulCodexDurableCommit()
        async throws
    {
        let context = makeContext()
        let completion = Counter()
        let dependencies = makeDraftDependencies(
            manager: context.manager,
            setupCompletionWriter: {
                completion.increment()
            }
        )
        let home = try makeHome()
        let moved = home.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        defer { try? FileManager.default.removeItem(at: moved) }
        let model = makeViewModel(dependencies)

        try model.selectDraftCodexHome(home.path)
        let identity = try XCTUnwrap(
            model.verifiedDraftIdentity
        )
        try FileManager.default.moveItem(at: home, to: moved)
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: true
        )

        do {
            _ = try await dependencies.completeCodexSetup(
                name: nil,
                homePath: home.path,
                verifiedIdentity: identity
            )
            XCTFail("Expected changed identity to reject commit")
        } catch {
            XCTAssertEqual(
                error as? CodexHomeCanonicalizationError,
                .changedSinceVerification
            )
        }
        XCTAssertEqual(completion.value, 0)
        XCTAssertTrue(context.manager.profiles.isEmpty)
    }

    func testCompletionFlagIsNotWrittenWhenCredentialUpdateFails()
        async throws
    {
        let context = makeContext(
            secretStore: FailingSecrets()
        )
        _ = try context.manager.createInitialProfile(
            name: "Claude",
            providerConfiguration: .claude
        )
        let completion = Counter()
        let dependencies = makeDependencies(
            manager: context.manager,
            setupCompletionWriter: {
                completion.increment()
            }
        )

        do {
            _ = try await dependencies
                .completeClaudeCLISetup(
                    credentials: "test-only"
                )
            XCTFail("Expected credential write failure")
        } catch {}
        XCTAssertEqual(completion.value, 0)
    }

    func testCompletionFlagIsNotWrittenWhenActivationFails()
        async throws
    {
        let context = makeContext()
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let codex = try context.manager
            .createInitialCodexProfile(
                name: "Codex",
                linkedHomePath: home.path
            )
        let completion = Counter()
        let dependencies = makeDependencies(
            manager: context.manager,
            setupCompletionWriter: {
                completion.increment()
            },
            setupProfileActivator: { _ in }
        )

        do {
            _ = try await dependencies
                .completeClaudeCLISetup(
                    credentials: "test-only"
                )
            XCTFail("Expected activation failure")
        } catch {
            XCTAssertEqual(
                error as? ProviderUIOperationError,
                .activationFailed
            )
        }
        XCTAssertEqual(
            context.manager.activeProfile?.id,
            codex.id
        )
        XCTAssertEqual(completion.value, 0)
    }

    func testProfileSpecificDestinationIsHiddenUntilActivation()
        async throws
    {
        let context = makeContext()
        let dependencies = makeDependencies(manager: context.manager)
        let first = try dependencies.createProfile(
            name: "First",
            provider: .claude,
            linkedCodexHome: nil
        )
        let second = try dependencies.createProfile(
            name: "Second",
            provider: .claude,
            linkedCodexHome: nil
        )
        XCTAssertEqual(context.manager.activeProfile?.id, first.id)
        let navigation = retain(SettingsNavigationModel())

        navigation.navigate(
            to: .general(profileID: second.id),
            dependencies: dependencies
        )

        XCTAssertTrue(navigation.isResolvingProfile)
        await waitUntil {
            !navigation.isResolvingProfile
        }
        XCTAssertEqual(context.manager.activeProfile?.id, second.id)
        XCTAssertEqual(navigation.selectedSection, .general)
    }

    // MARK: - Test support

    private struct Context {
        let manager: ProfileManager
        let store: ProfileStore
    }

    private struct CodexSetup {
        let home: URL
        let profile: Profile
        let dependencies: ProviderUIDependencies
    }

    private func makeContext(
        secretStore: any ProfileSecretStore = TestSecrets()
    ) -> Context {
        let defaults = TestDefaults()
        let store = retain(
            makeIsolatedProfileStore(
                defaults: defaults,
                secretStore: secretStore,
                usageFileStore: TestUsageStore()
            )
        )
        let manager = retain(
            ProfileManager(
                profileStore: store,
                historyService: TestHistory(),
                activationClaudeEffects: .init(
                    resyncBeforeSwitching: { _ in },
                    applyProfileCredentials: { _ in },
                    switchAccountAndSync: { _ in }
                ),
                lifecycleEventSink: .init(
                    deletionStarted: { _ in },
                    deletionCompleted: { _ in }
                ),
                postClaudeCreationMigration: { profileID in
                    guard let profile = store.loadProfiles()
                        .first(where: { $0.id == profileID }) else {
                        throw TestError.missingProfile
                    }
                    return profile
                }
            )
        )
        manager.loadProfiles()
        return Context(manager: manager, store: store)
    }

    private func makeDependencies(
        manager: ProfileManager,
        setupCompletionWriter:
            @escaping SetupCompletionWriter = {},
        setupProfileActivator:
            SetupProfileActivator? = nil
    ) -> ProviderUIDependencies {
        retain(ProviderUIDependencies(
            profileManager: manager,
            availability: .testing(),
            codexCapabilities: CodexProviderFactory.capabilities,
            requestCapture: { _ in
                throw ProviderUIOperationError.wrongProvider
            },
            setupCompletionWriter: setupCompletionWriter,
            setupCompletionReader: { false },
            setupProfileActivator:
                setupProfileActivator
        ))
    }

    private func makeCodexSetup(
        health: ProviderHealth = ProviderHealth(
            status: .healthy,
            checkedAt: Date()
        ),
        account: @escaping @Sendable () async throws
            -> ProviderAccount? = {
                ProviderAccount(
                    id: try ProviderAccountID("account"),
                    displayName: "Person",
                    planName: "Plus"
                )
            },
        login: LoginHarness? = nil,
        loginResult: ProviderUILoginStartResult? = nil,
        captureObserver: Counter? = nil
    ) throws -> CodexSetup {
        let context = makeContext()
        let home = try makeHome()
        let canonicalHome = try CodexHomeCanonicalizer()
            .canonicalize(home.path)
        let profile = try context.manager.createInitialCodexProfile(
            name: "Codex",
            linkedHomePath: home.path
        )
        let dependencies = retain(ProviderUIDependencies(
            profileManager: context.manager,
            availability: .testing(),
            codexCapabilities: CodexProviderFactory.capabilities,
            requestCapture: { capturedProfile in
            captureObserver?.increment()
            let identity = ProviderUIDependencies.identity(
                for: capturedProfile
            )
            return CapturedProviderUIRequest(
                identity: identity,
                capabilities: CodexProviderFactory.capabilities,
                account: account,
                health: { health },
                beginLogin: { flow in
                    if let loginResult {
                        return loginResult
                    }
                    let login = login ?? LoginHarness()
                    await login.recordBegin()
                    let challenge: ProviderUILoginChallenge
                    switch flow {
                    case .browser:
                        challenge = .browser(
                            URL(string: "https://example.com/login")!
                        )
                    case .deviceCode:
                        challenge = .deviceCode(
                            verificationURL: URL(
                                string: "https://example.com/device"
                            )!,
                            userCode: "SAFE-CODE"
                        )
                    }
                    return .started(
                        ProviderUILoginSession(
                            challenge: challenge,
                            wait: {
                                try await login.wait()
                            },
                            cancel: {
                                await login.cancel()
                            },
                            disconnect: {
                                await login.disconnect()
                            }
                        )
                    )
                }
            )
        },
            setupCompletionWriter: {},
            setupCompletionReader: { false }
        ))
        XCTAssertEqual(
            canonicalHome,
            profile.providerConfiguration
                .codexConfiguration?.linkedHome
        )
        return CodexSetup(
            home: home,
            profile: profile,
            dependencies: dependencies
        )
    }

    private func makeDraftDependencies(
        manager: ProfileManager,
        login: LoginHarness? = nil,
        account: @escaping @Sendable () async throws
            -> ProviderAccount? = {
                ProviderAccount(
                    id: try ProviderAccountID("draft-account"),
                    displayName: "Draft",
                    planName: "Plus"
                )
            },
        setupCompletionWriter:
            @escaping SetupCompletionWriter = {},
        setupCompletionReader:
            @escaping SetupCompletionReader = { false }
    ) -> ProviderUIDependencies {
        let capabilities = CodexProviderFactory.capabilities
        let requestCapture:
            ProviderUIRequestCapture = { profile in
                let identity = ProviderUIDependencies.identity(
                    for: profile
                )
                return CapturedProviderUIRequest(
                    identity: identity,
                    capabilities: capabilities,
                    account: account,
                    health: {
                        ProviderHealth(
                            status: .healthy,
                            checkedAt: Date()
                        )
                    },
                    beginLogin: { _ in
                        let login = login ?? LoginHarness()
                        await login.recordBegin()
                        return .started(
                            ProviderUILoginSession(
                                challenge: .browser(
                                    URL(
                                        string:
                                            "https://example.com/login"
                                    )!
                                ),
                                wait: {
                                    try await login.wait()
                                },
                                cancel: {
                                    await login.cancel()
                                },
                                disconnect: {
                                    await login.disconnect()
                                }
                            )
                        )
                    }
                )
            }
        return retain(
            ProviderUIDependencies(
                profileManager: manager,
                availability: .testing(),
                codexCapabilities: capabilities,
                requestCapture: requestCapture,
                setupCompletionWriter:
                    setupCompletionWriter,
                setupCompletionReader:
                    setupCompletionReader
            )
        )
    }

    private func makeViewModel(
        _ dependencies: ProviderUIDependencies
    ) -> ProviderAccountViewModel {
        retain(
            ProviderAccountViewModel(
                dependencies: dependencies
            )
        )
    }

    private func makeHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "codex-profile-ui-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @MainActor () async -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for condition")
    }
}

private final class TestDefaults: ProfileDefaultsStore {
    var values: [String: Any] = [:]

    func data(forKey defaultName: String) -> Data? {
        values[defaultName] as? Data
    }

    func string(forKey defaultName: String) -> String? {
        values[defaultName] as? String
    }

    func set(_ value: Any?, forKey defaultName: String) {
        values[defaultName] = value
    }

    func removeObject(forKey defaultName: String) {
        values.removeValue(forKey: defaultName)
    }
}

private final class TestSecrets: ProfileSecretStore {
    var values: [ProfileSecretLocator: String] = [:]

    func read(
        _ locator: ProfileSecretLocator
    ) throws -> ProfileSecretReadResult {
        values[locator].map(ProfileSecretReadResult.value)
            ?? .absent
    }

    func write(
        _ value: String,
        to locator: ProfileSecretLocator
    ) throws {
        values[locator] = value
    }

    func delete(_ locator: ProfileSecretLocator) throws {
        values.removeValue(forKey: locator)
    }
}

private final class TestUsageStore:
    ProfileCurrentUsageFileStoring
{
    var values: [UUID: ProfileCurrentUsage] = [:]

    func loadCurrentUsage(
        for profileID: UUID
    ) throws -> ProfileCurrentUsage? {
        values[profileID]
    }

    func saveCurrentUsage(
        _ usage: ProfileCurrentUsage,
        for profileID: UUID
    ) throws {
        values[profileID] = usage
    }

    func updateCurrentUsage(
        for profileID: UUID,
        transform: (inout ProfileCurrentUsage) throws -> Void
    ) throws -> ProfileCurrentUsage {
        var usage = values[profileID] ?? .init()
        try transform(&usage)
        values[profileID] = usage
        return usage
    }

    func deleteCurrentUsage(for profileID: UUID) throws {
        values.removeValue(forKey: profileID)
    }

    func deleteAllData(for profileID: UUID) throws {
        values.removeValue(forKey: profileID)
    }
}

@MainActor
private final class TestHistory: ProfileHistoryDeleting {
    func deleteHistoryThrowing(for profileId: UUID) throws {}
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    func increment() {
        lock.withLock { storage += 1 }
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var observed = false

    func wait() async {
        observed = true
        while !isOpen {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func waitUntilObserved() async {
        while !observed {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func open() {
        isOpen = true
    }
}

private actor LoginHarness {
    private(set) var beginCount = 0
    private(set) var cancelCount = 0
    private(set) var disconnectCount = 0
    private var outcome: CodexLoginOutcome?

    func recordBegin() {
        beginCount += 1
        outcome = nil
    }

    func wait() async throws -> CodexLoginOutcome {
        while outcome == nil {
            if Task.isCancelled {
                throw UsageProviderError.cancelled
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        return outcome!
    }

    func cancel() -> CodexLoginCancellationOutcome {
        cancelCount += 1
        outcome = .failed
        return .canceled
    }

    func disconnect() {
        disconnectCount += 1
    }

    func complete(_ outcome: CodexLoginOutcome) {
        self.outcome = outcome
    }
}

private final class FailingSecrets: ProfileSecretStore {
    func read(
        _ locator: ProfileSecretLocator
    ) throws -> ProfileSecretReadResult {
        .absent
    }

    func write(
        _ value: String,
        to locator: ProfileSecretLocator
    ) throws {
        throw TestError.forcedFailure
    }

    func delete(_ locator: ProfileSecretLocator) throws {}
}

private enum TestError: Error {
    case missingProfile
    case forcedFailure
}
