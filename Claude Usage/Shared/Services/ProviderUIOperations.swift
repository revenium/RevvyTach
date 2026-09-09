import Foundation
import UsageCore
import CodexUsageProvider

/// Immutable provider inputs captured before a settings or setup operation.
///
/// UI results are accepted only while this complete identity still matches
/// the stored profile. In particular, a directory installed later at the same
/// path is not treated as the linked home.
nonisolated struct ProviderUIRequestIdentity: Equatable, Sendable {
    let profileID: UUID
    let providerID: ProviderID
    let providerRevision: UInt64
    let codexHomePath: String?
    let codexHomeIdentity: CodexHomeFilesystemIdentity?
}

/// An immutable target selected before a manual Claude setup attempt begins.
/// `.compatibilityCurrent` exists for older callers; new UI must capture and
/// supply either an exact existing profile or the explicit no-profile state.
nonisolated enum ClaudeManualSetupTarget: Equatable, Sendable {
    case compatibilityCurrent
    case existing(UUID)
    case newProfile
    case createdProfile(UUID)
}

/// Provider-correct profile status shared by settings pickers and CRUD rows.
///
/// Claude CLI metadata is intentionally ignored for Codex profiles, even if
/// stale legacy fields survive a migration.
@MainActor
struct ProviderProfilePresentation: Equatable {
    let providerLabel: String
    let connectionDetail: String?
    let systemImage: String
    let isConnected: Bool

    init(profile: Profile) {
        switch profile.providerID {
        case .claude:
            providerLabel = "Claude"
            if let accountName = profile.cliAccountName {
                connectionDetail = "CLI: \(accountName)"
            } else if profile.hasCliAccount {
                connectionDetail = ProviderUILocalization.text(
                    "profiles.claude_cli_linked",
                    fallback: "CLI linked"
                )
            } else {
                connectionDetail = nil
            }
            systemImage = profile.hasCliAccount
                ? "person.crop.circle.fill.badge.checkmark"
                : "person.crop.circle.fill"
            isConnected = profile.hasCliAccount
        case .codex:
            providerLabel = "Codex"
            if let home = profile.providerConfiguration
                .codexConfiguration?.linkedHome {
                let liveIdentity =
                    CodexHomeFilesystemIdentity.read(
                        from: URL(fileURLWithPath: home.path)
                    )
                if home.filesystemIdentity == nil
                    || liveIdentity != home.filesystemIdentity {
                    connectionDetail = ProviderUILocalization.text(
                        "profiles.codex_relink",
                        fallback: "Relink required"
                    )
                    systemImage =
                        "person.crop.circle.badge.exclamationmark"
                    isConnected = false
                } else {
                    connectionDetail = ProviderUILocalization.text(
                        "profiles.codex_home_linked",
                        fallback: "Home linked"
                    )
                    systemImage =
                        "person.crop.circle.fill.badge.checkmark"
                    isConnected = true
                }
            } else {
                connectionDetail = ProviderUILocalization.text(
                    "profiles.codex_unlinked",
                    fallback: "Home unlinked"
                )
                systemImage =
                    "person.crop.circle.badge.exclamationmark"
                isConnected = false
            }
        default:
            providerLabel = ProviderUILocalization.text(
                "profiles.provider_unknown",
                fallback: "Provider unavailable"
            )
            connectionDetail = nil
            systemImage = "person.crop.circle.badge.questionmark"
            isConnected = false
        }
    }

    var detailText: String {
        [providerLabel, connectionDetail]
            .compactMap { $0 }
            .joined(separator: " • ")
    }
}

/// Every provider-sensitive settings/automation surface has one explicit
/// policy entry. Generic app controls deliberately remain provider-neutral.
nonisolated enum ProviderFeatureSurface:
    CaseIterable,
    Equatable,
    Hashable,
    Sendable
{
    case history
    case notifications
    case automaticSessionStart
    case automaticProfileSwitch
    case cliAccountSync
    case apiBilling
    case genericRefresh
    case shortcuts
    case launchAtLogin

    var capability: ProviderCapability? {
        switch self {
        case .history:
            return .usageHistory
        case .notifications:
            return .usageNotifications
        case .automaticSessionStart:
            return .automaticSessionStart
        case .automaticProfileSwitch:
            return .automaticProfileSwitch
        case .cliAccountSync:
            return .cliAccountSync
        case .apiBilling:
            return .apiBilling
        case .genericRefresh, .shortcuts, .launchAtLogin:
            return nil
        }
    }
}

nonisolated struct ProviderFeatureSurfacePolicy:
    Equatable,
    Sendable
{
    let capabilities: ProviderCapabilities

    func supports(_ surface: ProviderFeatureSurface) -> Bool {
        guard let capability = surface.capability else {
            return true
        }
        return capabilities.supports(capability)
    }
}

nonisolated enum ProviderUILoginFlow: Equatable, Sendable {
    case browser
    case deviceCode
}

nonisolated enum ProviderUILoginChallenge: Equatable, Sendable {
    case browser(URL)
    case deviceCode(verificationURL: URL, userCode: String)
}

nonisolated struct ProviderUILoginSession: Sendable {
    let challenge: ProviderUILoginChallenge
    private let waitOperation:
        @Sendable () async throws -> CodexLoginOutcome
    private let cancelOperation:
        @Sendable () async throws -> CodexLoginCancellationOutcome
    private let disconnectOperation:
        @Sendable () async throws -> Void

    init(
        challenge: ProviderUILoginChallenge,
        wait: @escaping @Sendable () async throws -> CodexLoginOutcome,
        cancel: @escaping @Sendable () async throws
            -> CodexLoginCancellationOutcome,
        disconnect: @escaping @Sendable () async throws -> Void
    ) {
        self.challenge = challenge
        waitOperation = wait
        cancelOperation = cancel
        disconnectOperation = disconnect
    }

    func waitForCompletion() async throws -> CodexLoginOutcome {
        try await waitOperation()
    }

    func cancel() async throws -> CodexLoginCancellationOutcome {
        try await cancelOperation()
    }

    func disconnect() async throws {
        try await disconnectOperation()
    }
}

nonisolated enum ProviderUILoginStartResult: Sendable {
    case alreadyAuthenticated(ProviderAccount)
    case started(ProviderUILoginSession)
}

/// Request-scoped provider work. Each operation creates its own provider and
/// app-server client through the shared factory.
nonisolated struct CapturedProviderUIRequest: Sendable {
    let identity: ProviderUIRequestIdentity
    let capabilities: ProviderCapabilities
    let account: @Sendable () async throws -> ProviderAccount?
    let health: @Sendable () async throws -> ProviderHealth
    let beginLogin:
        @Sendable (ProviderUILoginFlow) async throws
            -> ProviderUILoginStartResult
}

typealias ProviderUIRequestCapture =
    @MainActor @Sendable (Profile) throws -> CapturedProviderUIRequest
typealias CodexDraftUIRequestCapture =
    @MainActor @Sendable (String) throws -> CapturedProviderUIRequest
typealias SetupCompletionWriter = @MainActor () -> Void
typealias SetupCompletionReader = @MainActor () -> Bool
typealias SetupProfileActivator =
    @MainActor (UUID) async -> Void

/// One injectable, provider-neutral dependency boundary for setup and settings.
///
/// Profile metadata remains owned by `ProfileManager`; provider processes are
/// always request scoped and authentication remains owned by Codex.
@MainActor
final class ProviderUIDependencies {
    let profileManager: ProfileManager
    let availability: UsageProviderFeatureAvailability
    let codexCapabilities: ProviderCapabilities

    private let requestCapture: ProviderUIRequestCapture
    private let codexDraftCapture: CodexDraftUIRequestCapture
    private let setupCompletionWriter: SetupCompletionWriter
    private let setupCompletionReader: SetupCompletionReader
    private let setupProfileActivator: SetupProfileActivator

    init(
        profileManager: ProfileManager,
        availability: UsageProviderFeatureAvailability,
        codexCapabilities: ProviderCapabilities,
        requestCapture: @escaping ProviderUIRequestCapture,
        codexDraftCapture: CodexDraftUIRequestCapture? = nil,
        setupCompletionWriter: @escaping SetupCompletionWriter = {
            SharedDataStore.shared.saveHasCompletedSetup(true)
        },
        setupCompletionReader: @escaping SetupCompletionReader = {
            SharedDataStore.shared.hasCompletedSetup()
        },
        setupProfileActivator: SetupProfileActivator? = nil
    ) {
        self.profileManager = profileManager
        self.availability = availability
        self.codexCapabilities = codexCapabilities
        self.requestCapture = requestCapture
        self.setupCompletionWriter = setupCompletionWriter
        self.setupCompletionReader = setupCompletionReader
        self.setupProfileActivator =
            setupProfileActivator
            ?? { profileID in
                await profileManager.activateProfile(profileID)
            }
        self.codexDraftCapture =
            codexDraftCapture
            ?? { path in
                let resumableProfileID: UUID?
                if setupCompletionReader() {
                    resumableProfileID = nil
                } else {
                    resumableProfileID = Self
                        .resumableCodexProfile(
                            matching: path,
                            profiles: profileManager.profiles
                        )?.id
                }
                let home = try CodexHomeCanonicalizer()
                    .canonicalize(
                        path,
                        excludingProfileID: resumableProfileID,
                        existingProfiles: profileManager.profiles
                    )
                let draft = Profile(
                    name: "Codex Setup Draft",
                    providerConfiguration: .codex(
                        .init(linkedHome: home)
                    )
                )
                return try requestCapture(draft)
            }
    }

    convenience init(
        profileManager: ProfileManager? = nil,
        codexProviderFactory: CodexProviderFactory,
        setupCompletionWriter:
            @escaping SetupCompletionWriter = {
                SharedDataStore.shared.saveHasCompletedSetup(true)
            },
        setupCompletionReader:
            @escaping SetupCompletionReader = {
                SharedDataStore.shared.hasCompletedSetup()
            },
        setupProfileActivator: SetupProfileActivator? = nil
    ) {
        self.init(
            profileManager: profileManager ?? .shared,
            availability: UsageProviderFeatureAvailability(
                codexRefreshEnabled: codexProviderFactory.isEnabled
            ),
            codexCapabilities: codexProviderFactory.capabilities,
            requestCapture: { profile in
                guard case .codex(let configuration) =
                        profile.providerConfiguration else {
                    throw ProviderUIOperationError.wrongProvider
                }
                let captured = try codexProviderFactory.capture(
                    linkedHome: configuration.linkedHome
                )
                let identity = Self.identity(for: profile)
                return CapturedProviderUIRequest(
                    identity: identity,
                    capabilities:
                        codexProviderFactory.capabilities,
                    account: {
                        let provider = try codexProviderFactory
                            .makeFreshProvider(captured)
                        return try await provider.account()
                    },
                    health: {
                        let provider = try codexProviderFactory
                            .makeFreshProvider(captured)
                        return await provider.health()
                    },
                    beginLogin: { flow in
                        let provider = try codexProviderFactory
                            .makeFreshProvider(captured)
                        let providerFlow: CodexLoginFlow
                        switch flow {
                        case .browser:
                            providerFlow = .browser()
                        case .deviceCode:
                            providerFlow = .deviceCode
                        }
                        switch try await provider.beginLogin(
                            providerFlow
                        ) {
                        case .alreadyAuthenticated(let account):
                            await provider.disconnect()
                            return .alreadyAuthenticated(account)
                        case .started(let attempt):
                            return .started(
                                ProviderUILoginSession(
                                    challenge: Self.challenge(
                                        from: attempt.challenge
                                    ),
                                    wait: {
                                        try await attempt
                                            .waitForCompletion()
                                    },
                                    cancel: {
                                        try await attempt.cancel()
                                    },
                                    disconnect: {
                                        try await attempt.disconnect()
                                    }
                                )
                            )
                        }
                    }
                )
            },
            setupCompletionWriter: setupCompletionWriter,
            setupCompletionReader: setupCompletionReader,
            setupProfileActivator: setupProfileActivator
        )
    }

    func captureRequest(
        for profile: Profile
    ) throws -> CapturedProviderUIRequest {
        if profile.providerID == .codex,
           !availability.codexSupportEnabled {
            throw ProviderUIOperationError.featureDisabled
        }
        return try requestCapture(profile)
    }

    /// Validates a setup draft without creating a profile UUID or writing app
    /// metadata. The same canonicalization and duplicate checks run again at
    /// commit time.
    func captureCodexDraftRequest(
        homePath: String
    ) throws -> CapturedProviderUIRequest {
        guard availability.codexSupportEnabled else {
            throw ProviderUIOperationError.featureDisabled
        }
        return try codexDraftCapture(homePath)
    }

    @discardableResult
    func commitCodexDraft(
        name: String?,
        homePath: String,
        verifiedIdentity: ProviderUIRequestIdentity
    ) throws -> Profile {
        guard availability.codexSupportEnabled else {
            throw ProviderUIOperationError.featureDisabled
        }
        guard verifiedIdentity.providerID == .codex,
              let expectedPath =
                verifiedIdentity.codexHomePath,
              let expectedIdentity =
                verifiedIdentity.codexHomeIdentity else {
            throw CodexHomeCanonicalizationError
                .filesystemIdentityUnavailable
        }
        if !setupCompletionReader(),
           let resumable = Self.resumableCodexProfile(
               matching: homePath,
               profiles: profileManager.profiles
           ),
           resumable.providerConfiguration
               .codexConfiguration?.linkedHome?.path
               == expectedPath,
           resumable.providerConfiguration
               .codexConfiguration?.linkedHome?
               .filesystemIdentity == expectedIdentity {
            return resumable
        }
        return try profileManager.createVerifiedCodexProfile(
            name: name,
            linkedHomePath: homePath,
            expectedPath: expectedPath,
            expectedIdentity: expectedIdentity
        )
    }

    func profile(id: UUID) -> Profile? {
        profileManager.profiles.first {
            $0.id == id && !$0.deletionInProgress
        }
    }

    func identity(for profileID: UUID) -> ProviderUIRequestIdentity? {
        profile(id: profileID).map(Self.identity(for:))
    }

    func loadCredentials(
        for profileID: UUID
    ) throws -> ProfileCredentials {
        try profileManager.loadCredentials(for: profileID)
    }

    /// Verifies that provider-owned filesystem state still matches the
    /// immutable request capture. Metadata equality alone is insufficient:
    /// a directory can be replaced at the same canonical path while an
    /// account or login operation is in flight.
    func hasCurrentProviderIdentity(
        _ identity: ProviderUIRequestIdentity
    ) -> Bool {
        guard identity.providerID == .codex else {
            return true
        }
        guard let path = identity.codexHomePath,
              let expected = identity.codexHomeIdentity else {
            return false
        }
        return CodexHomeFilesystemIdentity.read(
            from: URL(fileURLWithPath: path)
        ) == expected
    }

    /// Returns an existing active Claude setup target without ever writing
    /// Claude-owned state into an active Codex profile. Choosing Claude while
    /// another provider is active is an explicit add-profile operation.
    func claudeSetupProfile() throws -> Profile {
        if let active = profileManager.activeClaudeProfile {
            return active
        }
        return try createProfile(
            name: nil,
            provider: .claude,
            linkedCodexHome: nil
        )
    }

    /// One durable completion action shared by Claude setup, Codex setup, and
    /// successful profile migration.
    func markSetupCompleted() {
        setupCompletionWriter()
    }

    /// Completes a Claude setup by writing the browser session key, the
    /// organization it belongs to, and an optional linked terminal sign-in.
    ///
    /// `chromeSessionKeySource` defaults to `.set(nil)` because this function
    /// always writes a new `claudeSessionKey`, and a caller that says nothing
    /// about where that key came from has not said it came from Chrome. The
    /// fail-safe reading of silence is therefore "no Chrome origin": leaving
    /// the previous key's origin in place would let an automatic re-read
    /// overwrite the new key out of a browser profile the user never pointed
    /// at it. A caller that genuinely wants the recorded origin preserved
    /// across a key change has to pass `.unchanged` deliberately.
    @discardableResult
    func completeClaudeManualSetup(
        sessionKey: String,
        organizationID: String?,
        autoStartSessionEnabled: Bool,
        terminalCredentialsJSON: String? = nil,
        terminalAccountName: String? = nil,
        acceptSessionOnlyStorage: Bool = false,
        target: ClaudeManualSetupTarget = .compatibilityCurrent,
        chromeSessionKeySource: ChromeSessionKeySourceWrite = .set(nil)
    ) async throws -> Profile {
        let targetProfile = try resolvedClaudeManualSetupTarget(target)
        var profile = try requiredProfile(targetProfile.id)
        profile.claudeSessionKey = sessionKey
        profile.organizationId = organizationID
        // Carried on the same profile record as the key it describes. Both
        // fields are only local struct assignments here, committed together by
        // the single `updateProfileThrowing` call below, so the ordering is
        // cosmetic and no partial write is possible at this call site. What
        // matters is that the origin is written at all: a hand-typed key that
        // kept the Chrome origin of the key it replaced would be eligible for
        // an automatic re-read out of a browser profile the user never
        // pointed at it.
        if case .set(let source) = chromeSessionKeySource {
            profile.chromeSessionKeySource = source
        }
        let shouldAttemptTerminalLink = terminalCredentialsJSON != nil
        let validatedTerminalCredentials = terminalCredentialsJSON.flatMap {
            ClaudeCodeSyncService.carriesLogin($0) ? $0 : nil
        }
        if shouldAttemptTerminalLink {
            profile.cliCredentialsJSON = validatedTerminalCredentials
        }
        profile.autoStartSessionEnabled =
            autoStartSessionEnabled
        if shouldAttemptTerminalLink,
           validatedTerminalCredentials != nil {
            profile.hasCliAccount = true
            profile.cliAccountSyncedAt = Date()
            profile.cliAccountName = terminalAccountName
        } else if shouldAttemptTerminalLink {
            // This wizard never manufactures a terminal-only or falsely linked
            // profile. A detected blob without an access token is ignored and
            // browser setup still completes normally.
            profile.hasCliAccount = false
            profile.cliAccountSyncedAt = nil
            profile.cliAccountName = nil
        }
        // Commit browser credentials, an optional terminal sign-in, and its
        // link metadata together. A failed write must not leave a terminal
        // secret behind without the metadata that describes it.
        try profileManager.updateProfileThrowing(
            profile,
            acceptingSessionOnly: acceptSessionOnlyStorage
        )
        try await activateForCompletedSetup(profile.id)
        markSetupCompleted()
        return try requiredProfile(profile.id)
    }

    @discardableResult
    func completeCodexSetup(
        name: String?,
        homePath: String,
        verifiedIdentity: ProviderUIRequestIdentity
    ) async throws -> Profile {
        let profile = try commitCodexDraft(
            name: name,
            homePath: homePath,
            verifiedIdentity: verifiedIdentity
        )
        try await activateForCompletedSetup(profile.id)
        markSetupCompleted()
        return try requiredProfile(profile.id)
    }

    @discardableResult
    func createProfile(
        name: String?,
        provider: ProfileProviderKind,
        linkedCodexHome: String?
    ) throws -> Profile {
        switch provider {
        case .claude:
            if profileManager.profiles.isEmpty {
                return try profileManager.createInitialProfile(
                    name: name,
                    providerConfiguration: .claude
                )
            }
            return try profileManager.createProfileThrowing(
                name: name,
                providerConfiguration: .claude
            )
        case .codex:
            guard availability.codexSupportEnabled else {
                throw ProviderUIOperationError.featureDisabled
            }
            guard let linkedCodexHome else {
                throw CodexHomeCanonicalizationError.empty
            }
            if profileManager.profiles.isEmpty {
                return try profileManager.createInitialCodexProfile(
                    name: name,
                    linkedHomePath: linkedCodexHome
                )
            }
            return try profileManager.createCodexProfile(
                name: name,
                linkedHomePath: linkedCodexHome
            )
        }
    }

    @discardableResult
    func linkCodexHome(
        _ path: String,
        profileID: UUID
    ) throws -> Profile {
        guard availability.codexSupportEnabled else {
            throw ProviderUIOperationError.featureDisabled
        }
        return try profileManager.linkCodexHome(path, for: profileID)
    }

    @discardableResult
    func unlinkCodexHome(profileID: UUID) throws -> Profile {
        try profileManager.unlinkCodexHome(for: profileID)
    }

    func updateName(_ name: String, profileID: UUID) throws {
        guard var profile = profile(id: profileID) else {
            throw ProfileStoreError.profileNotFound(profileID)
        }
        profile.name = name
        try profileManager.updateProfileThrowing(profile)
    }

    func deleteProfile(_ profileID: UUID) throws {
        try profileManager.deleteProfile(profileID)
    }

    func activateProfile(_ profileID: UUID) async {
        await profileManager.activateProfile(profileID)
    }

    func capabilities(
        for providerID: ProviderID
    ) -> ProviderCapabilities {
        switch providerID {
        case .claude:
            return ClaudeUsageProviderAdapter.capabilities
        case .codex:
            return codexCapabilities
        default:
            return ProviderCapabilities()
        }
    }

    static func identity(
        for profile: Profile
    ) -> ProviderUIRequestIdentity {
        let codex = profile.providerConfiguration.codexConfiguration
        return ProviderUIRequestIdentity(
            profileID: profile.id,
            providerID: profile.providerID,
            providerRevision: profile.providerRevision,
            codexHomePath: codex?.linkedHome?.path,
            codexHomeIdentity: codex?.linkedHome?.filesystemIdentity
        )
    }

    private nonisolated static func challenge(
        from challenge: CodexLoginChallenge
    ) -> ProviderUILoginChallenge {
        switch challenge {
        case .browser(_, let authorizationURL):
            return .browser(authorizationURL)
        case .deviceCode(
            _,
            let verificationURL,
            let userCode
        ):
            return .deviceCode(
                verificationURL: verificationURL,
                userCode: userCode
            )
        }
    }

    private func activateForCompletedSetup(
        _ profileID: UUID
    ) async throws {
        await setupProfileActivator(profileID)
        guard profileManager.activeProfile?.id == profileID,
              profile(id: profileID) != nil else {
            throw ProviderUIOperationError.activationFailed
        }
    }

    /// Resolves only the target captured by the UI. In particular, a setup
    /// started with no Claude profile must not silently attach to one that
    /// appeared while validation was in flight.
    private func resolvedClaudeManualSetupTarget(
        _ target: ClaudeManualSetupTarget
    ) throws -> Profile {
        switch target {
        case .compatibilityCurrent:
            return try claudeSetupProfile()
        case .existing(let profileID):
            guard let profile = profile(id: profileID),
                  profile.providerID == .claude,
                  profileManager.activeClaudeProfile?.id == profileID else {
                throw ProviderUIOperationError.profileChanged
            }
            return profile
        case .newProfile:
            guard profileManager.activeClaudeProfile == nil,
                  !profileManager.profiles.contains(where: {
                      $0.providerID == .claude
                  }) else {
                throw ProviderUIOperationError.profileChanged
            }
            return try createProfile(
                name: nil,
                provider: .claude,
                linkedCodexHome: nil
            )
        case .createdProfile(let profileID):
            let claudeProfiles = profileManager.profiles.filter {
                $0.providerID == .claude
            }
            guard claudeProfiles.map(\.id) == [profileID],
                  let profile = claudeProfiles.first,
                  profileManager.activeClaudeProfile == nil
                    || profileManager.activeClaudeProfile?.id == profileID else {
                throw ProviderUIOperationError.profileChanged
            }
            return profile
        }
    }

    private func requiredProfile(_ profileID: UUID) throws -> Profile {
        guard let profile = profile(id: profileID) else {
            throw ProfileStoreError.profileNotFound(profileID)
        }
        return profile
    }

    /// During an incomplete setup only, an exactly matching verified Codex
    /// profile is a resumable commit rather than a duplicate. This covers a
    /// crash after the durable profile write but before activation/completion.
    private static func resumableCodexProfile(
        matching path: String,
        profiles: [Profile]
    ) -> Profile? {
        let canonicalizer = CodexHomeCanonicalizer()
        for profile in profiles where
                !profile.deletionInProgress
                && profile.providerID == .codex {
            guard let linkedHome = profile.providerConfiguration
                    .codexConfiguration?.linkedHome,
                  let candidate = try? canonicalizer.canonicalize(
                      path,
                      excludingProfileID: profile.id,
                      existingProfiles: profiles
                  ),
                  candidate == linkedHome else {
                continue
            }
            return profile
        }
        return nil
    }
}

@MainActor
final class ProviderUICompositionRoot {
    static let shared = ProviderUICompositionRoot()
    static let application: ProviderUICompositionRoot = {
#if UI_TESTING
        UITestApplicationBootstrap.compositionRoot
#else
        shared
#endif
    }()

    let profileManager: ProfileManager
    let codexProviderFactory: CodexProviderFactory
    let dependencies: ProviderUIDependencies

    init(
        profileManager: ProfileManager? = nil,
        availability: UsageProviderFeatureAvailability = .production,
        codexProviderFactory: CodexProviderFactory? = nil,
        setupCompletionWriter:
            @escaping SetupCompletionWriter = {
                SharedDataStore.shared.saveHasCompletedSetup(true)
            },
        setupCompletionReader:
            @escaping SetupCompletionReader = {
                SharedDataStore.shared.hasCompletedSetup()
            },
        setupProfileActivator: SetupProfileActivator? = nil
    ) {
        let factory =
            codexProviderFactory
            ?? CodexProviderFactory(availability: availability)
        let manager = profileManager ?? .shared
        self.profileManager = manager
        self.codexProviderFactory = factory
        dependencies = ProviderUIDependencies(
            profileManager: manager,
            codexProviderFactory: factory,
            setupCompletionWriter: setupCompletionWriter,
            setupCompletionReader: setupCompletionReader,
            setupProfileActivator: setupProfileActivator
        )
    }
}

nonisolated enum ProviderUIOperationError:
    Error,
    Equatable,
    Sendable
{
    case wrongProvider
    case featureDisabled
    case profileChanged
    case activationFailed
}

nonisolated enum ProviderUILocalization {
    static func text(_ key: String, fallback: String) -> String {
        let localized = NSLocalizedString(key, comment: "")
        return localized == key ? fallback : localized
    }
}
