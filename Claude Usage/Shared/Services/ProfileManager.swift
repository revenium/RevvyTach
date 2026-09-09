//
//  ProfileManager.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-01-07.
//

import Foundation
import Combine
import UsageCore

struct ProfileActivationClaudeEffects {
    var resyncBeforeSwitching: (UUID) throws -> Void
    var applyProfileCredentials: (UUID) throws -> Void
    var switchAccountAndSync: (String) throws -> Void

    static func live(
        cliSyncService: ClaudeCodeSyncService
    ) -> ProfileActivationClaudeEffects {
        ProfileActivationClaudeEffects(
            resyncBeforeSwitching: {
                try cliSyncService.resyncBeforeSwitching(for: $0)
            },
            applyProfileCredentials: {
                try cliSyncService.applyProfileCredentials($0)
            },
            switchAccountAndSync: { accountName in
                try ClaudeSwitchService.shared.switchToAccount(accountName)
                if SharedDataStore.shared.loadAutoSyncMCPEnabled() {
                    _ = ClaudeSwitchService.shared.bidirectionalMcpSync()
                    _ = ClaudeSwitchService.shared.syncSkills()
                }
            }
        )
    }
}

/// Codex-only activation side effect: switching CODEX_HOME for the terminal
/// CLI, mirroring `ProfileActivationClaudeEffects.switchAccountAndSync` but
/// scoped to a directory path rather than an account name. Never touches
/// Codex auth.json/tokens — directory-path-level only.
struct ProfileActivationCodexEffects {
    var switchToLinkedHome: (CanonicalCodexHome) throws -> Void
    var clearHome: () -> Void

    static let live = ProfileActivationCodexEffects(
        switchToLinkedHome: {
            try CodexSwitchService.shared.switchToHome($0)
        },
        clearHome: {
            CodexSwitchService.shared.clearHome()
        }
    )
}

struct ProfileLifecycleEventSink {
    var deletionStarted: (Profile) -> Void
    var deletionCleanup: (Profile) throws -> Void
    var deletionCompleted: (Profile) -> Void

    init(
        deletionStarted: @escaping (Profile) -> Void,
        deletionCleanup:
            @escaping (Profile) throws -> Void = { _ in },
        deletionCompleted: @escaping (Profile) -> Void
    ) {
        self.deletionStarted = deletionStarted
        self.deletionCleanup = deletionCleanup
        self.deletionCompleted = deletionCompleted
    }

    static let live = ProfileLifecycleEventSink(
        deletionStarted: {
            NotificationCenter.default.post(
                name: .profileDeletionStarted,
                object: $0.id,
                userInfo: Self.userInfo(for: $0)
            )
        },
        deletionCleanup: {
            try NotificationManager.shared
                .clearNotificationsForProfile(
                    $0.id,
                    providerID: $0.providerID
                )
        },
        deletionCompleted: {
            NotificationCenter.default.post(
                name: .profileDeletionCompleted,
                object: $0.id,
                userInfo: Self.userInfo(for: $0)
            )
        }
    )

    private static func userInfo(for profile: Profile) -> [String: Any] {
        [
            "profileID": profile.id,
            "providerKind": profile.providerConfiguration.kind.rawValue,
            "providerRevision": profile.providerRevision
        ]
    }
}

@MainActor
class ProfileManager: ObservableObject {
    static let shared = ProfileManager()

    @Published var profiles: [Profile] = []
    /// The most recently focused/activated profile, regardless of provider.
    /// Single-display mode, the menu-bar title, and every other "whichever
    /// profile is currently shown" call site key off this — it is preserved
    /// exactly as before the per-provider activation split. Provider-scoped
    /// consumers (Claude CLI sync, Codex CLI switching, etc.)
    /// must use `activeClaudeProfile` / `activeCodexProfile` instead, since
    /// this can point at either provider's profile at any time.
    @Published var activeProfile: Profile? {
        didSet {
            if oldValue?.id != activeProfile?.id {
                activeProfileIdentityGeneration &+= 1
                // Persist focus independently of the legacy single-slot
                // key, which is deleted after its first read (see
                // `loadProfiles()`). Without this, any later call to
                // `loadProfiles()` in the same session would silently fall
                // back to the Claude-first tie-break.
                profileStore.saveLastFocusedProfileId(activeProfile?.id)
            }
        }
    }
    private(set) var activeProfileIdentityGeneration: UInt64 = 0

    /// The independently active profile for each provider. Activating a
    /// Claude profile never touches `activeCodexProfileID` and vice versa —
    /// this is what makes Claude and Codex simultaneously active.
    @Published private(set) var activeClaudeProfileID: UUID?
    @Published private(set) var activeCodexProfileID: UUID?

    var activeClaudeProfile: Profile? {
        guard let id = activeClaudeProfileID else { return nil }
        return profiles.first(where: { $0.id == id })
    }

    var activeCodexProfile: Profile? {
        guard let id = activeCodexProfileID else { return nil }
        return profiles.first(where: { $0.id == id })
    }

    /// Returns whether `profile` is the active profile for its own provider.
    /// Use this (rather than comparing against `activeProfile`) anywhere a
    /// list mixes Claude and Codex rows and needs a per-row "Active" badge.
    func isActive(_ profile: Profile) -> Bool {
        switch profile.providerConfiguration.kind {
        case .claude:
            return profile.id == activeClaudeProfileID
        case .codex:
            return profile.id == activeCodexProfileID
        }
    }

    private func activeProfileID(for kind: ProfileProviderKind) -> UUID? {
        switch kind {
        case .claude: return activeClaudeProfileID
        case .codex: return activeCodexProfileID
        }
    }

    private func setActiveProfileID(_ id: UUID?, for kind: ProfileProviderKind) {
        switch kind {
        case .claude: activeClaudeProfileID = id
        case .codex: activeCodexProfileID = id
        }
    }

    private func otherProviderActiveProfile(
        excluding kind: ProfileProviderKind
    ) -> Profile? {
        switch kind {
        case .claude: return activeCodexProfile
        case .codex: return activeClaudeProfile
        }
    }
    @Published var displayMode: ProfileDisplayMode = .single
    @Published var multiProfileConfig: MultiProfileDisplayConfig = .default
    /// Independent toggles, both off by default. See `providerBadgeStyle`
    /// for the combined value the renderer consumes.
    @Published var providerBadgeGlyphEnabled: Bool = false
    @Published var providerBadgeTintEnabled: Bool = false

    var providerBadgeStyle: ProviderBadgeStyle {
        ProviderBadgeStyle(
            glyphEnabled: providerBadgeGlyphEnabled,
            tintEnabled: providerBadgeTintEnabled
        )
    }
    @Published var isSwitchingProfile: Bool = false
    @Published private(set) var legacyMigrationPendingProfileID: UUID?

    /// Profiles whose credential is held in memory because secure storage
    /// refused it. These are lost at quit, so the UI has to say so — see the
    /// popover banner, the Settings status card, and the quit-time guard.
    @Published private(set) var sessionOnlyCredentialProfileIDs: Set<UUID> = []
    /// Browser credentials held only in memory. Unlike the aggregate set
    /// above, this drives only the browser-specific Settings warning.
    @Published private(set) var sessionOnlyClaudeAICredentialProfileIDs:
        Set<UUID> = []
    /// Whether the most recent profile load fully resolved every Claude
    /// credential locator and can safely commit the one-time 4.1 cohort.
    @Published private(set) var profileLoadIsAuthoritativeForUpgradeClassification = false
    /// The synchronous credential-state snapshot consumed by account UI.
    /// It changes in the same main-actor transaction as `profiles`, so a
    /// refresh captured before a repair cannot reintroduce stale setup UI.
    @Published private(set) var claudeSetupStateSnapshots:
        [UUID: ClaudeSetupState] = [:]

    private let profileStore: ProfileStore
    private let historyService: any ProfileHistoryDeleting
    private let activationClaudeEffects: ProfileActivationClaudeEffects
    private let activationCodexEffects: ProfileActivationCodexEffects
    private let codexHomeCanonicalizer: CodexHomeCanonicalizer
    private let lifecycleEventSink: ProfileLifecycleEventSink
    private let postClaudeCreationMigration: (UUID) throws -> Profile
    private let now: () -> Date
    private var classifyClaudeAccountsForUpgrade:
        (([Profile], Bool, Bool) -> Void)?
    private var startupMigrationsAllowUpgradeClassification = true
    private var profileLoadHasAuthoritativeIdentitySet = false

    private var switchingSemaphore = false

    init(
        profileStore: ProfileStore? = nil,
        cliSyncService: ClaudeCodeSyncService? = nil,
        historyService: (any ProfileHistoryDeleting)? = nil,
        activationClaudeEffects: ProfileActivationClaudeEffects? = nil,
        activationCodexEffects: ProfileActivationCodexEffects? = nil,
        codexHomeCanonicalizer: CodexHomeCanonicalizer? = nil,
        lifecycleEventSink: ProfileLifecycleEventSink? = nil,
        postClaudeCreationMigration: ((UUID) throws -> Profile)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.profileStore = profileStore ?? .shared
        let resolvedCLISyncService = cliSyncService ?? .shared
        self.historyService = historyService ?? UsageHistoryService.shared
        self.activationClaudeEffects =
            activationClaudeEffects
            ?? .live(cliSyncService: resolvedCLISyncService)
        self.activationCodexEffects = activationCodexEffects ?? .live
        self.codexHomeCanonicalizer =
            codexHomeCanonicalizer ?? CodexHomeCanonicalizer()
        self.lifecycleEventSink = lifecycleEventSink ?? .live
        self.postClaudeCreationMigration =
            postClaudeCreationMigration
            ?? {
                try ProfileMigrationService.shared
                    .migrateClaudeProfileIfNeeded(to: $0)
            }
        self.now = now

        let store = self.profileStore
        synchronizeSessionOnlyCredentialProfileIDs()
        store.sessionOnlySecretsDidChange = { [weak self] held, browserHeld in
            guard let self else { return }
            Task { @MainActor in
                self.sessionOnlyCredentialProfileIDs = held
                self.sessionOnlyClaudeAICredentialProfileIDs = browserHeld
            }
        }
    }

    private func loadProfilesFromStore() -> [Profile] {
        let outcome = profileStore.loadProfilesWithOutcome()
        profileLoadHasAuthoritativeIdentitySet =
            outcome.isProfileIdentitySetAuthoritative
        profileLoadIsAuthoritativeForUpgradeClassification =
            outcome.isAuthoritativeForUpgradeClassification
        return outcome.profiles
    }

    private func synchronizeSessionOnlyCredentialProfileIDs() {
        sessionOnlyCredentialProfileIDs =
            profileStore.profilesWithSessionOnlyCredentials
        sessionOnlyClaudeAICredentialProfileIDs =
            profileStore.profilesWithSessionOnlyClaudeAICredentials
    }

    func configureClaudeAccountUpgradeClassification(
        startupMigrationsSucceeded: Bool,
        classifier: @escaping ([Profile], Bool, Bool) -> Void
    ) {
        startupMigrationsAllowUpgradeClassification =
            startupMigrationsSucceeded
        classifyClaudeAccountsForUpgrade = classifier
    }

    private func classifyClaudeAccountsForUpgradeAfterLoad() {
        classifyClaudeAccountsForUpgrade?(
            profiles,
            profileLoadHasAuthoritativeIdentitySet,
            startupMigrationsAllowUpgradeClassification
                && profileLoadIsAuthoritativeForUpgradeClassification
        )
    }

    /// Re-attempts secure storage for held credentials. Returns true when
    /// nothing is left being held for the requested scope.
    @discardableResult
    func retrySessionOnlyCredentialSave(profileID: UUID? = nil) -> Bool {
        let browserTargets =
            profileStore.profilesWithSessionOnlyClaudeAICredentials
                .filter { profileID == nil || $0 == profileID }
        let cleared = profileStore.retrySessionOnlyPersistence(
            profileID: profileID
        )
        synchronizeSessionOnlyCredentialProfileIDs()
        let remainingBrowserTargets =
            profileStore.profilesWithSessionOnlyClaudeAICredentials
        for id in browserTargets where !remainingBrowserTargets.contains(id) {
            stampBrowserCredentialSavedAt(for: id)
        }
        return cleared
    }

    // MARK: - Initialization

    func loadProfiles() {
        profiles = loadProfilesFromStore()
        synchronizeClaudeSetupStateSnapshots()
        synchronizeSessionOnlyCredentialProfileIDs()
        classifyClaudeAccountsForUpgradeAfterLoad()

        // A pre-upgrade install has only the single legacy slot. Both
        // providers get a chance to claim it against their own candidates —
        // whichever provider actually owned that profile adopts it, and the
        // other provider falls back to its own first profile.
        let legacyActiveID = profileStore.loadLegacyActiveProfileId()

        activeClaudeProfileID = resolveActiveProfileID(
            stored: profileStore.loadActiveProfileId(for: .claude)
                ?? legacyActiveID,
            kind: .claude
        )
        activeCodexProfileID = resolveActiveProfileID(
            stored: profileStore.loadActiveProfileId(for: .codex)
                ?? legacyActiveID,
            kind: .codex
        )
        if let id = activeClaudeProfileID {
            profileStore.saveActiveProfileId(id, for: .claude)
        }
        if let id = activeCodexProfileID {
            profileStore.saveActiveProfileId(id, for: .codex)
        }

        // The focused/displayed profile preserves pre-upgrade behavior on
        // the very first post-upgrade load: whatever the single legacy slot
        // pointed at. That legacy slot is deleted after this first read (see
        // `saveActiveProfileId(_:for:)`), so every subsequent call in this
        // or a later session restores focus from `lastFocusedProfileId`
        // instead — a dedicated pointer kept in sync via `activeProfile`'s
        // `didSet`. Without it, any later `loadProfiles()` call would fall
        // through to the Claude-first tie-break below and silently discard
        // Codex focus.
        let lastFocusedID = profileStore.loadLastFocusedProfileId()
        if let legacyActiveID,
           let profile = profiles.first(where: {
               $0.id == legacyActiveID && !$0.deletionInProgress
           }) {
            activeProfile = profile
        } else if let lastFocusedID,
                  let profile = profiles.first(where: {
                      $0.id == lastFocusedID && !$0.deletionInProgress
                  }) {
            activeProfile = profile
        } else if let claudeID = activeClaudeProfileID {
            activeProfile = profiles.first(where: { $0.id == claudeID })
        } else if let codexID = activeCodexProfileID {
            activeProfile = profiles.first(where: { $0.id == codexID })
        } else {
            activeProfile = profiles.first(where: {
                !$0.deletionInProgress
            })
        }

        displayMode = profileStore.loadDisplayMode()
        multiProfileConfig = profileStore.loadMultiProfileConfig()
        providerBadgeGlyphEnabled = profileStore.loadProviderBadgeGlyphEnabled()
        providerBadgeTintEnabled = profileStore.loadProviderBadgeTintEnabled()

        LoggingService.shared.log("ProfileManager: Loaded \(profiles.count) profile(s), active: \(activeProfile?.name ?? "none")")
    }

    /// Re-applies the active Codex profile's persisted `linkedHome` to the
    /// live CODEX_HOME pointer + tmux env, after `loadProfiles()`.
    ///
    /// `CodexSwitchService.discardStaleHomeIfMissing()` runs at startup
    /// (before `loadProfiles()`, see `AppDelegate`) and is deliberately
    /// aggressive: it clears the persisted pointer + tmux env whenever the
    /// linked directory doesn't currently exist — e.g. an external or
    /// network volume that hasn't mounted yet — so a stale pointer never
    /// survives to hand a new terminal pane a broken CODEX_HOME. That
    /// self-heal only ever touches the *live* pointer, though. The user's
    /// actual selection is untouched the whole time: `linkedHome` lives on
    /// the profile itself, persisted durably via
    /// `ProfileStore.replaceCodexLinkedHome`, entirely separate from the
    /// pointer file.
    ///
    /// This is the counterpart: once profiles are loaded, if there's an
    /// active Codex profile with a linked home, put the live pointer back so
    /// a directory that was merely unmounted at launch costs at most one
    /// launch instead of being permanently forgotten. `activateProfile(_:)`
    /// can't repair this on its own — it early-returns when the profile is
    /// already recorded active, so re-clicking the already-active profile in
    /// the UI does nothing.
    ///
    /// Failure here is non-fatal and deliberately does NOT clear the
    /// pointer again (contrast `activateProfile`'s own failure handling
    /// below, which does clear on an actual provider switch): the startup
    /// self-heal already handled the "still missing" case, so re-clearing
    /// here would just re-introduce the bug this method exists to fix. If
    /// the directory is still unavailable, this is simply a no-op until the
    /// next launch or manual switch.
    func reapplyActiveCodexHome() {
        guard let linkedHome = activeCodexProfile?.providerConfiguration
            .codexConfiguration?.linkedHome else {
            return
        }
        do {
            try activationCodexEffects.switchToLinkedHome(linkedHome)
            LoggingService.shared.log(
                "✓ Re-applied CODEX_HOME to: \(linkedHome.path)"
            )
        } catch {
            LoggingService.shared.logError(
                "Failed to switch CODEX_HOME (non-fatal)",
                error: error
            )
        }
    }

    /// Resolves the active profile id for one provider: the stored/legacy id
    /// if it still names a live profile of that provider, else that
    /// provider's first live profile, else nil if it has none.
    private func resolveActiveProfileID(
        stored: UUID?,
        kind: ProfileProviderKind
    ) -> UUID? {
        let candidates = profiles.filter {
            $0.providerConfiguration.kind == kind && !$0.deletionInProgress
        }
        if let stored, candidates.contains(where: { $0.id == stored }) {
            return stored
        }
        return candidates.first?.id
    }

    // MARK: - Profile Operations

    @discardableResult
    func createInitialProfile(
        name: String? = nil,
        providerConfiguration: ProfileProviderConfiguration
    ) throws -> Profile {
        try createInitialProfile(
            name: name,
            providerConfiguration: providerConfiguration,
            allowInitiallyLinkedCodex: false
        )
    }

    @discardableResult
    func createInitialCodexProfile(
        name: String? = nil,
        linkedHomePath: String
    ) throws -> Profile {
        let home = try codexHomeCanonicalizer.canonicalize(
            linkedHomePath,
            existingProfiles: profiles
        )
        return try createInitialProfile(
            name: name,
            providerConfiguration: .codex(
                CodexProfileConfiguration(linkedHome: home)
            ),
            allowInitiallyLinkedCodex: true
        )
    }

    private func createInitialProfile(
        name: String?,
        providerConfiguration: ProfileProviderConfiguration,
        allowInitiallyLinkedCodex: Bool
    ) throws -> Profile {
        guard profiles.isEmpty else {
            throw ProfileProviderConfigurationError
                .initialProfileAlreadyExists
        }
        try validateCreationConfiguration(
            providerConfiguration,
            allowInitiallyLinkedCodex: allowInitiallyLinkedCodex
        )
        let profile = makeProfile(
            name: name,
            providerConfiguration: providerConfiguration,
            copySettingsFrom: nil
        )
        try profileStore.createInitialProfile(profile)
        profiles = [profile]
        activeProfile = profile
        setActiveProfileID(profile.id, for: profile.providerConfiguration.kind)
        profileStore.saveActiveProfileId(
            profile.id,
            for: profile.providerConfiguration.kind
        )
        guard profile.providerConfiguration.kind == .claude else {
            return profile
        }
        let migrated = attemptPostClaudeCreationMigration(profile)
        profiles = [migrated]
        activeProfile = migrated
        return migrated
    }

    func createProfile(
        name: String? = nil,
        copySettingsFrom: Profile? = nil
    ) -> Profile? {
        do {
            return try createProfileThrowing(
                name: name,
                providerConfiguration: .claude,
                copySettingsFrom: copySettingsFrom
            )
        } catch {
            LoggingService.shared.logError(
                "ProfileManager.createProfile: Create was not verified",
                error: error
            )
            return nil
        }
    }

    @discardableResult
    func createProfileThrowing(
        name: String? = nil,
        providerConfiguration: ProfileProviderConfiguration,
        copySettingsFrom: Profile? = nil
    ) throws -> Profile {
        try createProfileThrowing(
            name: name,
            providerConfiguration: providerConfiguration,
            copySettingsFrom: copySettingsFrom,
            allowInitiallyLinkedCodex: false
        )
    }

    @discardableResult
    func createCodexProfile(
        name: String? = nil,
        linkedHomePath: String,
        copySettingsFrom: Profile? = nil
    ) throws -> Profile {
        let home = try codexHomeCanonicalizer.canonicalize(
            linkedHomePath,
            existingProfiles: profiles
        )
        return try createProfileThrowing(
            name: name,
            providerConfiguration: .codex(
                CodexProfileConfiguration(linkedHome: home)
            ),
            copySettingsFrom: copySettingsFrom,
            allowInitiallyLinkedCodex: true
        )
    }

    /// Commits a setup draft only if the physical home still exactly matches
    /// the path and filesystem identity verified before account inspection.
    @discardableResult
    func createVerifiedCodexProfile(
        name: String? = nil,
        linkedHomePath: String,
        expectedPath: String,
        expectedIdentity: CodexHomeFilesystemIdentity
    ) throws -> Profile {
        let home = try codexHomeCanonicalizer.canonicalize(
            linkedHomePath,
            existingProfiles: profiles
        )
        guard home.path == expectedPath,
              home.filesystemIdentity == expectedIdentity else {
            throw CodexHomeCanonicalizationError
                .changedSinceVerification
        }
        if profiles.isEmpty {
            return try createInitialProfile(
                name: name,
                providerConfiguration: .codex(
                    .init(linkedHome: home)
                ),
                allowInitiallyLinkedCodex: true
            )
        }
        return try createProfileThrowing(
            name: name,
            providerConfiguration: .codex(
                .init(linkedHome: home)
            ),
            copySettingsFrom: nil,
            allowInitiallyLinkedCodex: true
        )
    }

    private func createProfileThrowing(
        name: String?,
        providerConfiguration: ProfileProviderConfiguration,
        copySettingsFrom: Profile?,
        allowInitiallyLinkedCodex: Bool
    ) throws -> Profile {
        try validateCreationConfiguration(
            providerConfiguration,
            allowInitiallyLinkedCodex: allowInitiallyLinkedCodex
        )
        let hadClaudeProfile = profiles.contains(where: {
            !$0.deletionInProgress
                && $0.providerConfiguration.kind == .claude
        })
        let newProfile = makeProfile(
            name: name,
            providerConfiguration: providerConfiguration,
            copySettingsFrom: copySettingsFrom
        )
        try profileStore.appendProfile(
            newProfile,
            expectedExistingIDs: Set(profiles.map(\.id))
        )
        profiles.append(newProfile)

        if providerConfiguration.kind == .claude && !hadClaudeProfile {
            let migrated = attemptPostClaudeCreationMigration(newProfile)
            if let index = profiles.firstIndex(where: {
                $0.id == newProfile.id
            }) {
                profiles[index] = migrated
            }
            LoggingService.shared.log("Created new profile: \(migrated.name)")
            return migrated
        }

        LoggingService.shared.log("Created new profile: \(newProfile.name)")
        return newProfile
    }

    @discardableResult
    func retryPendingLegacyMigration() throws -> Profile? {
        guard let profileID = legacyMigrationPendingProfileID else {
            return nil
        }
        let migrated = try postClaudeCreationMigration(profileID)
        if let index = profiles.firstIndex(where: { $0.id == profileID }) {
            profiles[index] = migrated
        }
        if activeProfile?.id == profileID {
            activeProfile = migrated
        }
        legacyMigrationPendingProfileID = nil
        return migrated
    }

    private func attemptPostClaudeCreationMigration(
        _ profile: Profile
    ) -> Profile {
        do {
            let migrated = try postClaudeCreationMigration(profile.id)
            legacyMigrationPendingProfileID = nil
            return migrated
        } catch {
            // Profile choice is already durably committed. Preserve it,
            // retain legacy sources, and expose an explicit retry signal.
            legacyMigrationPendingProfileID = profile.id
            LoggingService.shared.logError(
                "Post-create legacy migration remains pending",
                error: error
            )
            return profileStore.loadProfiles().first(where: {
                $0.id == profile.id
            }) ?? profile
        }
    }

    private func validateCreationConfiguration(
        _ configuration: ProfileProviderConfiguration,
        allowInitiallyLinkedCodex: Bool
    ) throws {
        if case .codex(let codex) = configuration,
           codex.linkedHome != nil,
           !allowInitiallyLinkedCodex {
            throw ProfileProviderConfigurationError
                .codexInitialHomeRequiresDedicatedCreation
        }
    }

    private func makeProfile(
        name: String?,
        providerConfiguration: ProfileProviderConfiguration,
        copySettingsFrom: Profile?
    ) -> Profile {
        let usedNames = profiles.map { $0.name }
        let profileName = name ?? FunnyNameGenerator.getRandomName(excluding: usedNames)
        let providerDefaultIconConfiguration:
            MenuBarIconConfiguration
        switch providerConfiguration.kind {
        case .claude:
            providerDefaultIconConfiguration = .default(for: .claude)
        case .codex:
            providerDefaultIconConfiguration = .default(for: .codex)
        }

        return Profile(
            id: UUID(),
            name: profileName,
            providerConfiguration: providerConfiguration,
            hasCliAccount: false,
            iconConfig:
                copySettingsFrom?.iconConfig
                ?? providerDefaultIconConfiguration,
            refreshInterval: copySettingsFrom?.refreshInterval ?? 30.0,
            autoStartSessionEnabled: copySettingsFrom?.autoStartSessionEnabled ?? false,
            checkOverageLimitEnabled: copySettingsFrom?.checkOverageLimitEnabled ?? true,
            notificationSettings: copySettingsFrom?.notificationSettings ?? NotificationSettings(),
            isSelectedForDisplay: true
        )
    }

    @discardableResult
    func linkCodexHome(_ path: String, for profileID: UUID) throws -> Profile {
        guard let profile = profiles.first(where: {
            $0.id == profileID
        }) else {
            throw ProfileStoreError.profileNotFound(profileID)
        }
        guard profile.providerConfiguration.kind == .codex else {
            throw ProfileProviderConfigurationError
                .codexProfileRequired(profileID)
        }
        if let existingHome = profile.providerConfiguration
            .codexConfiguration?.linkedHome,
           existingHome.path == path {
            do {
                let home = try codexHomeCanonicalizer.canonicalize(
                    path,
                    excludingProfileID: profileID,
                    existingProfiles: profiles
                )
                return try replaceCodexLinkedHome(home, for: profileID)
            } catch let error as CodexHomeCanonicalizationError {
                guard error == .missing,
                      existingHome.filesystemIdentity != nil else {
                    throw error
                }
                // Preserve an already-verified offline link. This keeps
                // unrelated metadata edits and pending-mutation recovery
                // available without allowing a legacy path-only link to
                // bypass explicit re-verification.
                return try replaceCodexLinkedHome(
                    existingHome,
                    for: profileID
                )
            }
        }
        let home = try codexHomeCanonicalizer.canonicalize(
            path,
            excludingProfileID: profileID,
            existingProfiles: profiles
        )
        return try replaceCodexLinkedHome(home, for: profileID)
    }

    @discardableResult
    func unlinkCodexHome(for profileID: UUID) throws -> Profile {
        try replaceCodexLinkedHome(nil, for: profileID)
    }

    private func replaceCodexLinkedHome(
        _ home: CanonicalCodexHome?,
        for profileID: UUID
    ) throws -> Profile {
        do {
            guard let previous = profiles.first(where: {
                $0.id == profileID
            }) else {
                throw ProfileStoreError.profileNotFound(profileID)
            }
            let updated = try profileStore.replaceCodexLinkedHome(
                home,
                for: profileID
            )
            guard let index = profiles.firstIndex(where: {
                $0.id == profileID
            }) else {
                throw ProfileStoreError.profileNotFound(profileID)
            }
            profiles[index] = updated
            if activeProfile?.id == profileID {
                activeProfile = updated
            }
            // Changing the currently-active Codex profile's linked home —
            // whether unlinking it or relinking it to a different path —
            // must update CODEX_HOME immediately, mirroring activation.
            // Otherwise terminals keep using the old directory until the
            // next activation.
            if updated.providerConfiguration.kind == .codex,
               activeProfileID(for: .codex) == profileID {
                if let home {
                    do {
                        try activationCodexEffects.switchToLinkedHome(home)
                    } catch {
                        LoggingService.shared.logError(
                            "Failed to switch CODEX_HOME after relink",
                            error: error
                        )
                        activationCodexEffects.clearHome()
                    }
                } else {
                    activationCodexEffects.clearHome()
                }
            }
            if previous.providerConfiguration
                    != updated.providerConfiguration
                || previous.providerRevision != updated.providerRevision {
                NotificationCenter.default.post(
                    name: .providerConfigurationChanged,
                    object: profileID,
                    userInfo: [
                        "profileID": profileID,
                        "providerRevision": updated.providerRevision
                    ]
                )
            }
            return updated
        } catch {
            // Rollback recovery may have completed forward on relaunch. Reload
            // the authoritative metadata before surfacing the failure.
            profiles = loadProfilesFromStore()
            if let activeID = activeProfile?.id {
                activeProfile = profiles.first(where: { $0.id == activeID })
            }
            throw error
        }
    }

    func updateProfile(_ profile: Profile) {
        do {
            try updateProfileThrowing(profile)
        } catch {
            LoggingService.shared.logError(
                "ProfileManager.updateProfile: Update was not verified",
                error: error
            )
        }
    }

    /// Credential-aware update for workflows that must not report success
    /// unless secure storage and profile metadata have both been verified.
    func updateProfileThrowing(
        _ profile: Profile,
        acceptingSessionOnly: Bool = false
    ) throws {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else {
            throw ProfileStoreError.profileNotFound(profile.id)
        }

        let previous = profiles[index]
        let claudeSecretChanged = previous.claudeSessionKey != profile.claudeSessionKey
        let apiSecretChanged = previous.apiSessionKey != profile.apiSessionKey
        let cliSecretChanged = previous.cliCredentialsJSON != profile.cliCredentialsJSON
        let changedComponent = credentialChangeComponent(
            claudeChanged:
                claudeSecretChanged
                || previous.organizationId != profile.organizationId
                || previous.checkOverageLimitEnabled
                    != profile.checkOverageLimitEnabled,
            apiChanged:
                apiSecretChanged
                || previous.apiOrganizationId != profile.apiOrganizationId,
            cliChanged: cliSecretChanged
        )

        if cliSecretChanged && !claudeSecretChanged && !apiSecretChanged {
            if acceptingSessionOnly {
                try profileStore.saveProfileUpdateAcceptingSessionOnly(profile)
            } else {
                try profileStore.saveCLIProfileUpdate(profile)
            }
        } else if claudeSecretChanged || apiSecretChanged || cliSecretChanged {
            if acceptingSessionOnly {
                try profileStore.saveProfileUpdateAcceptingSessionOnly(profile)
            } else {
                try profileStore.saveProfileUpdate(profile)
            }
        } else {
            var candidate = profiles
            candidate[index] = profile
            try profileStore.saveProfilesThrowing(candidate)
        }

        profiles[index] = profile
        synchronizeClaudeSetupStateSnapshot(for: profile)

        if activeProfile?.id == profile.id {
            activeProfile = profile
            LoggingService.shared.log(
                "ProfileManager.updateProfile: Updated active profile"
            )
        } else {
            LoggingService.shared.log("ProfileManager.updateProfile: Updated profile")
        }

        if let changedComponent {
            postCredentialChange(
                profileID: profile.id,
                component: changedComponent
            )
        }
    }

    func deleteProfile(_ id: UUID) throws {
        let profileName = profiles.first(where: { $0.id == id })?.name ?? "unknown"

        guard let deletionTarget = profiles.first(where: {
            $0.id == id
        }) else {
            throw ProfileStoreError.profileNotFound(id)
        }
        let usableProfileCount = profiles.filter {
            !$0.deletionInProgress
        }.count
        if !deletionTarget.deletionInProgress && usableProfileCount <= 1 {
            throw ProfileError.cannotDeleteLastProfile
        }

        // Atomically retain a scrubbed marker before any destructive cleanup.
        // On failure or relaunch, identity remains for retry without allowing
        // migration envelopes or surviving stores to rehydrate deleted data.
        let deletedKind = deletionTarget.providerConfiguration.kind
        let wasFocused = activeProfile?.id == id
        let wasProviderActive = activeProfileID(for: deletedKind) == id
        let scrubbedProfile = try profileStore.beginProfileDeletion(id)
        if let index = profiles.firstIndex(where: { $0.id == id }) {
            profiles[index] = scrubbedProfile
        }
        lifecycleEventSink.deletionStarted(scrubbedProfile)

        // Re-electing the active profile for the deleted profile's own
        // provider must never pull in a profile from the other provider —
        // that would silently deactivate a provider that was never touched.
        var providerSurvivor: Profile?
        if wasProviderActive {
            providerSurvivor = profiles.first(where: {
                $0.id != id
                    && !$0.deletionInProgress
                    && $0.providerConfiguration.kind == deletedKind
            })
            setActiveProfileID(providerSurvivor?.id, for: deletedKind)
            if let providerSurvivor {
                profileStore.saveActiveProfileId(
                    providerSurvivor.id,
                    for: deletedKind
                )
                applyPostDeletionActivationEffects(providerSurvivor)
            } else if deletedKind == .codex {
                // The last active Codex profile was deleted with no
                // same-provider survivor to switch to — CODEX_HOME must be
                // cleared rather than left pointing at the deleted profile.
                activationCodexEffects.clearHome()
            }
        }

        if wasFocused {
            // Prefer a same-provider survivor to keep the focused profile
            // stable; otherwise fall back to whichever other provider still
            // has an active profile, then to any remaining profile.
            if let providerSurvivor {
                activeProfile = providerSurvivor
            } else if let otherActive = otherProviderActiveProfile(
                excluding: deletedKind
            ) {
                activeProfile = otherActive
            } else {
                activeProfile = profiles.first(where: {
                    $0.id != id && !$0.deletionInProgress
                })
            }
        }

        if scrubbedProfile.providerConfiguration.kind == .claude {
            try profileStore.deleteProfileSecrets(for: id)
        }
        try historyService.deleteHistoryThrowing(for: id)
        try profileStore.deleteProfileUsageData(for: id)
        try lifecycleEventSink.deletionCleanup(
            scrubbedProfile
        )
        LoggingService.shared.log("Successfully deleted usage history for profile: \(profileName)")

        let remainingProfiles = profiles.filter { $0.id != id }
        try profileStore.finalizeProfileDeletion(
            id,
            expectedRemainingIDs: Set(remainingProfiles.map(\.id))
        )
        profiles = remainingProfiles

        lifecycleEventSink.deletionCompleted(scrubbedProfile)

        LoggingService.shared.log("Deleted profile: \(profileName)")
    }

    private func applyPostDeletionActivationEffects(_ profile: Profile) {
        guard profile.providerConfiguration.kind == .claude else {
            // Deleting the active Codex profile elects a same-provider
            // survivor above; that survivor's terminal state must follow
            // it, mirroring the Claude branch below.
            if profile.providerConfiguration.kind == .codex {
                if let linkedHome = profile.providerConfiguration
                    .codexConfiguration?.linkedHome {
                    do {
                        try activationCodexEffects
                            .switchToLinkedHome(linkedHome)
                    } catch {
                        LoggingService.shared.logError(
                            "Post-delete CODEX_HOME switch failed",
                            error: error
                        )
                        // Don't leave CODEX_HOME pointed at the deleted
                        // profile's (now-invalid) home just because the
                        // survivor's switch failed.
                        activationCodexEffects.clearHome()
                    }
                } else {
                    activationCodexEffects.clearHome()
                }
            }
            return
        }
        if profile.cliCredentialsJSON != nil {
            do {
                try activationClaudeEffects
                    .applyProfileCredentials(profile.id)
            } catch {
                LoggingService.shared.logError(
                    "Post-delete CLI credential activation failed",
                    error: error
                )
            }
        }
        if let accountName = profile.cliAccountName {
            do {
                try activationClaudeEffects
                    .switchAccountAndSync(accountName)
            } catch {
                LoggingService.shared.logError(
                    "Post-delete CLI account activation failed",
                    error: error
                )
            }
        }
    }

    func toggleProfileSelection(_ id: UUID) {
        // Use async to avoid "Publishing changes from within view updates" warning
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let index = self.profiles.firstIndex(where: { $0.id == id }) {
                self.profiles[index].isSelectedForDisplay.toggle()
                self.profileStore.saveProfiles(self.profiles)
            }
        }
    }

    func getSelectedProfiles() -> [Profile] {
        displayMode == .single
            ? [activeProfile].compactMap { $0 }
            : profiles.filter {
                $0.isSelectedForDisplay && !$0.deletionInProgress
            }
    }

    func updateDisplayMode(_ mode: ProfileDisplayMode) {
        // Use async to avoid "Publishing changes from within view updates" warning
        DispatchQueue.main.async { [weak self] in
            self?.displayMode = mode
            self?.profileStore.saveDisplayMode(mode)
            LoggingService.shared.log("Updated display mode to: \(mode.rawValue)")
        }
    }

    func updateMultiProfileConfig(_ config: MultiProfileDisplayConfig) {
        // Use async to avoid "Publishing changes from within view updates" warning
        DispatchQueue.main.async { [weak self] in
            self?.multiProfileConfig = config
            self?.profileStore.saveMultiProfileConfig(config)
            LoggingService.shared.log("Updated multi-profile config: style=\(config.iconStyle.rawValue), showWeek=\(config.showWeek)")
        }
    }

    func updateProviderBadgeGlyphEnabled(_ enabled: Bool) {
        // Use async to avoid "Publishing changes from within view updates" warning.
        // The menuBarIconConfigChanged notification is posted here, after the
        // deferred state update, so observers that redraw from providerBadgeStyle
        // never read the stale value.
        DispatchQueue.main.async { [weak self] in
            self?.providerBadgeGlyphEnabled = enabled
            self?.profileStore.saveProviderBadgeGlyphEnabled(enabled)
            LoggingService.shared.log("Updated provider badge glyph enabled: \(enabled)")
            NotificationCenter.default.post(name: .menuBarIconConfigChanged, object: nil)
        }
    }

    func updateProviderBadgeTintEnabled(_ enabled: Bool) {
        // Use async to avoid "Publishing changes from within view updates" warning.
        // The menuBarIconConfigChanged notification is posted here, after the
        // deferred state update, so observers that redraw from providerBadgeStyle
        // never read the stale value.
        DispatchQueue.main.async { [weak self] in
            self?.providerBadgeTintEnabled = enabled
            self?.profileStore.saveProviderBadgeTintEnabled(enabled)
            LoggingService.shared.log("Updated provider badge tint enabled: \(enabled)")
            NotificationCenter.default.post(name: .menuBarIconConfigChanged, object: nil)
        }
    }

    // MARK: - Profile Activation (Centralized)

    func activateProfile(_ id: UUID) async {
        guard !switchingSemaphore else {
            LoggingService.shared.log("Profile switch already in progress, ignoring")
            return
        }

        guard let profile = profiles.first(where: {
            $0.id == id && !$0.deletionInProgress
        }) else {
            LoggingService.shared.log("Profile not found: \(id)")
            return
        }

        if activeProfileID(for: profile.providerConfiguration.kind) == id {
            // Already active for its own provider — the other provider's
            // active profile is untouched, but focus still moves to it.
            LoggingService.shared.log("Profile already active: \(profile.name)")
            activeProfile = profile
            return
        }

        switchingSemaphore = true
        isSwitchingProfile = true
        defer {
            switchingSemaphore = false
            isSwitchingProfile = false
        }

        LoggingService.shared.log("Switching to profile: \(profile.name)")

        // The target provider selects the branch before any provider-specific
        // side effect. Activating one provider's profile never reads or
        // writes the other provider's active slot.
        if profile.providerConfiguration.kind == .codex {
            do {
                let updated = try profileStore.updateActivationMetadata(
                    for: id,
                    at: now()
                )
                if let index = profiles.firstIndex(where: { $0.id == id }) {
                    profiles[index] = updated
                }
                activeCodexProfileID = id
                profileStore.saveActiveProfileId(id, for: .codex)
                activeProfile = updated
                if let linkedHome = updated.providerConfiguration
                    .codexConfiguration?.linkedHome {
                    do {
                        try activationCodexEffects
                            .switchToLinkedHome(linkedHome)
                        LoggingService.shared.log(
                            "✓ Switched CODEX_HOME to: \(linkedHome.path)"
                        )
                    } catch {
                        LoggingService.shared.logError(
                            "Failed to switch CODEX_HOME (non-fatal)",
                            error: error
                        )
                        // If we cannot honor the newly activated profile's
                        // home, terminals must fall back to Codex's own
                        // ~/.codex default rather than keep pointing at the
                        // PREVIOUS profile's home. Mirrors the failure
                        // handling in replaceCodexLinkedHome below.
                        activationCodexEffects.clearHome()
                    }
                } else {
                    // Activating an unlinked profile must clear any
                    // CODEX_HOME left behind by a previously active linked
                    // profile — otherwise terminals keep pointing at the
                    // prior profile's home.
                    activationCodexEffects.clearHome()
                }
                LoggingService.shared.log(
                    "Successfully activated Codex profile: \(updated.name)"
                )
            } catch {
                LoggingService.shared.logError(
                    "Failed to activate Codex profile",
                    error: error
                )
            }
            return
        }

        // Re-sync the outgoing Claude profile before leaving (if CLI
        // credentials exist). This is scoped to the active *Claude* profile,
        // not whichever profile is merely focused/displayed.
        if let currentProfile = activeClaudeProfile, currentProfile.cliCredentialsJSON != nil {
            do {
                try activationClaudeEffects
                    .resyncBeforeSwitching(currentProfile.id)
                // Reload profiles to get the updated data in memory
                profiles = loadProfilesFromStore()
                LoggingService.shared.log("✓ Re-synced current profile before switching")
            } catch {
                LoggingService.shared.logError("Failed to re-sync current profile (non-fatal)", error: error)
            }
        }

        // Reload profiles from disk to get latest data (including any resyncs from other profiles)
        profiles = loadProfilesFromStore()

        // Get the updated target profile from the reloaded data
        guard let updatedProfile = profiles.first(where: { $0.id == id }) else {
            LoggingService.shared.log("Profile not found after reload: \(id)")
            return
        }

        // Apply new profile's CLI credentials (if available)
        LoggingService.shared.log("Checking CLI credentials for profile '\(updatedProfile.name)': hasJSON=\(updatedProfile.cliCredentialsJSON != nil)")

        if updatedProfile.cliCredentialsJSON != nil {
            do {
                try activationClaudeEffects
                    .applyProfileCredentials(updatedProfile.id)
                LoggingService.shared.log("✓ Applied CLI credentials for: \(updatedProfile.name)")
            } catch {
                LoggingService.shared.logError("Failed to apply CLI credentials (non-fatal)", error: error)
            }
        } else {
            LoggingService.shared.log("⚠️ Profile '\(updatedProfile.name)' has no CLI credentials JSON")
        }

        // Switch CLI account if profile has a mapped account name
        LoggingService.shared.log("CLI account check for '\(updatedProfile.name)': cliAccountName=\(updatedProfile.cliAccountName ?? "nil")")
        if let accountName = updatedProfile.cliAccountName {
            do {
                try activationClaudeEffects.switchAccountAndSync(accountName)
                LoggingService.shared.log("✓ Switched CLI account to: \(accountName)")
            } catch {
                LoggingService.shared.logError("Failed to switch CLI account (non-fatal)", error: error)
            }
        }

        // Update last used timestamp
        var updated = updatedProfile
        updated.lastUsedAt = now()

        if let index = profiles.firstIndex(where: { $0.id == updatedProfile.id }) {
            profiles[index] = updated
        }

        activeClaudeProfileID = id
        profileStore.saveActiveProfileId(id, for: .claude)
        activeProfile = updated
        profileStore.saveProfiles(profiles)

        LoggingService.shared.log("Successfully activated profile: \(updatedProfile.name)")
    }

    // MARK: - Credentials

    func loadCredentials(for profileId: UUID) throws -> ProfileCredentials {
        return try profileStore.loadProfileCredentials(profileId)
    }

    func saveCredentials(
        for profileId: UUID,
        credentials: ProfileCredentials,
        acceptingSessionOnly: Bool = false,
        browserCredentialSave: Bool = false
    ) throws {
        guard let index = profiles.firstIndex(where: { $0.id == profileId }) else {
            throw ProfileStoreError.profileNotFound(profileId)
        }
        let previous = profiles[index]
        let requestInputsChanged =
            previous.claudeSessionKey != credentials.claudeSessionKey
            || previous.organizationId != credentials.organizationId
            || previous.apiSessionKey != credentials.apiSessionKey
            || previous.apiOrganizationId != credentials.apiOrganizationId
            || previous.cliCredentialsJSON != credentials.cliCredentialsJSON

        let savedAt = browserCredentialSave && !acceptingSessionOnly
            ? now()
            : nil
        if let savedAt {
            var updated = profiles[index]
            updated.claudeSessionKey = credentials.claudeSessionKey
            updated.organizationId = credentials.organizationId
            updated.apiSessionKey = credentials.apiSessionKey
            updated.apiOrganizationId = credentials.apiOrganizationId
            updated.apiSessionKeyExpiry = credentials.apiSessionKeyExpiry
            updated.cliCredentialsJSON = credentials.cliCredentialsJSON
            updated.claudeBrowserCredentialSavedAt = savedAt
            try profileStore.saveProfileUpdate(updated)
        } else if acceptingSessionOnly {
            try profileStore.saveProfileCredentialsAcceptingSessionOnly(
                profileId,
                credentials: credentials
            )
        } else {
            try profileStore.saveProfileCredentials(
                profileId,
                credentials: credentials
            )
        }
        synchronizeSessionOnlyCredentialProfileIDs()

        profiles[index].claudeSessionKey = credentials.claudeSessionKey
        profiles[index].organizationId = credentials.organizationId
        profiles[index].apiSessionKey = credentials.apiSessionKey
        profiles[index].apiOrganizationId = credentials.apiOrganizationId
        profiles[index].apiSessionKeyExpiry = credentials.apiSessionKeyExpiry
        profiles[index].cliCredentialsJSON = credentials.cliCredentialsJSON
        if let savedAt {
            profiles[index].claudeBrowserCredentialSavedAt = savedAt
        } else if browserCredentialSave && acceptingSessionOnly {
            // The replacement now in use exists only in memory. Keeping the
            // previous durable credential's date here would label this new,
            // unsaved sign-in with a save that never happened. The ProfileStore
            // intentionally retains the old persisted metadata until Retry
            // Save succeeds, so a failed session-only attempt does not rewrite
            // durable history.
            profiles[index].claudeBrowserCredentialSavedAt = nil
        }

        if activeProfile?.id == profileId {
            activeProfile = profiles[index]
        }
        synchronizeClaudeSetupStateSnapshot(for: profiles[index])
        if requestInputsChanged {
            postCredentialChange(profileID: profileId, component: .all)
        }
    }

    private func stampBrowserCredentialSavedAt(for profileId: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == profileId })
        else { return }
        profiles[index].claudeBrowserCredentialSavedAt = now()
        if activeProfile?.id == profileId {
            activeProfile = profiles[index]
        }
        profileStore.saveProfiles(profiles)
    }

    /// Removes Claude.ai credentials for a profile
    func removeClaudeAICredentials(for profileId: UUID) throws {
        do {
            try profileStore.unlinkClaudeAI(for: profileId)
        } catch {
            if let storeError = error as? ProfileStoreError,
               case .credentialUsageUnlinkRollbackFailed = storeError {
                failCloseCredentialUsageRuntime(
                    for: profileId,
                    component: .claude
                )
                postCredentialChange(
                    profileID: profileId,
                    component: .claude
                )
            }
            throw error
        }
        failCloseCredentialUsageRuntime(
            for: profileId,
            component: .claude
        )

        LoggingService.shared.log("ProfileManager: Removed Claude.ai credentials for profile \(profileId)")
        postCredentialChange(profileID: profileId, component: .claude)
    }

    /// Removes API Console credentials for a profile
    func removeAPICredentials(for profileId: UUID) throws {
        do {
            try profileStore.unlinkAPIConsole(for: profileId)
        } catch {
            if let storeError = error as? ProfileStoreError,
               case .credentialUsageUnlinkRollbackFailed = storeError {
                failCloseCredentialUsageRuntime(
                    for: profileId,
                    component: .api
                )
                postCredentialChange(
                    profileID: profileId,
                    component: .api
                )
            }
            throw error
        }
        failCloseCredentialUsageRuntime(
            for: profileId,
            component: .api
        )

        LoggingService.shared.log("ProfileManager: Removed API credentials for profile \(profileId)")
        postCredentialChange(profileID: profileId, component: .api)
    }

    private enum CredentialUsageComponent: String {
        case claude
        case api
    }

    private enum CredentialChangeComponent: String {
        case claude
        case api
        case cli
        case all
    }

    private func failCloseCredentialUsageRuntime(
        for profileID: UUID,
        component: CredentialUsageComponent
    ) {
        guard let index = profiles.firstIndex(where: {
            $0.id == profileID
        }) else {
            return
        }

        let targetField: ProfileSecretField =
            component == .claude
                ? .claudeSessionKey
                : .apiSessionKey
        profiles[index].credentialMigrationRetry.setValue(
            nil,
            for: targetField
        )
        if var usageRetry =
            profiles[index].currentUsageMigrationRetry {
            if component == .claude {
                usageRetry.report = nil
                usageRetry.claudeUsage = nil
            } else {
                usageRetry.apiUsage = nil
            }
            profiles[index].currentUsageMigrationRetry =
                usageRetry.isEmpty ? nil : usageRetry
        }

        if component == .claude {
            profiles[index].claudeSessionKey = nil
            profiles[index].organizationId = nil
            profiles[index].claudeBrowserCredentialSavedAt = nil
            profiles[index].claudeUsage = nil
        } else {
            profiles[index].apiSessionKey = nil
            profiles[index].apiOrganizationId = nil
            profiles[index].apiSessionKeyExpiry = nil
            profiles[index].apiUsage = nil
        }

        if activeProfile?.id == profileID {
            activeProfile = profiles[index]
        }
        synchronizeClaudeSetupStateSnapshot(for: profiles[index])
    }

    func claudeSetupState(for profile: Profile) -> ClaudeSetupState? {
        guard profile.providerID == .claude else { return nil }
        return claudeSetupStateSnapshots[profile.id]
            ?? ClaudeSetupState.of(profile)
    }

    private func synchronizeClaudeSetupStateSnapshot(for profile: Profile) {
        if profile.providerID == .claude {
            claudeSetupStateSnapshots[profile.id] = ClaudeSetupState.of(profile)
        } else {
            claudeSetupStateSnapshots.removeValue(forKey: profile.id)
        }
    }

    private func synchronizeClaudeSetupStateSnapshots() {
        claudeSetupStateSnapshots = Dictionary(
            uniqueKeysWithValues: profiles.compactMap { profile in
                guard profile.providerID == .claude else { return nil }
                return (profile.id, ClaudeSetupState.of(profile))
            }
        )
    }

    private func postCredentialChange(
        profileID: UUID,
        component: CredentialChangeComponent
    ) {
        NotificationCenter.default.post(
            name: .credentialsChanged,
            object: profileID,
            userInfo: [
                "profileID": profileID,
                "component": component.rawValue
            ]
        )
    }

    private func credentialChangeComponent(
        claudeChanged: Bool,
        apiChanged: Bool,
        cliChanged: Bool
    ) -> CredentialChangeComponent? {
        let changes = [
            claudeChanged ? .claude : nil,
            apiChanged ? .api : nil,
            cliChanged ? .cli : nil
        ] as [CredentialChangeComponent?]
        let resolvedChanges = changes.compactMap { $0 }
        guard resolvedChanges.count == 1 else {
            return resolvedChanges.isEmpty ? nil : .all
        }
        return resolvedChanges[0]
    }

    // MARK: - Usage Data

    /// Installs one complete provider result and updates compatibility
    /// projections only after the provider/revision/deletion fence and exact
    /// durable readback succeed.
    @discardableResult
    func commitCurrentUsage(
        _ usage: ProfileCurrentUsage,
        for profileID: UUID,
        expectedProviderID: ProviderID,
        expectedProviderRevision: UInt64,
        publishToActiveProfile: Bool = true
    ) throws -> (
        previous: ProfileCurrentUsage?,
        current: ProfileCurrentUsage
    ) {
        guard let index = profiles.firstIndex(where: {
            $0.id == profileID
        }) else {
            throw ProfileStoreError.profileNotFound(profileID)
        }
        let profile = profiles[index]
        guard !profile.deletionInProgress else {
            throw ProfileStoreError.profileDeletionInProgress(profileID)
        }
        guard profile.providerID == expectedProviderID,
              profile.providerRevision == expectedProviderRevision else {
            throw ProfileCurrentUsageValidationError.identityMismatch(
                expectedProviderID: expectedProviderID,
                expectedProviderRevision: expectedProviderRevision,
                foundProviderID: profile.providerID,
                foundProviderRevision: profile.providerRevision
            )
        }

        let committed = try profileStore.commitCurrentUsage(
            usage,
            for: profileID,
            expectedProviderID: expectedProviderID,
            expectedProviderRevision: expectedProviderRevision
        )
        profiles[index].claudeUsage = committed.current.claudeUsage
        profiles[index].apiUsage = committed.current.apiUsage
        if publishToActiveProfile, activeProfile?.id == profileID {
            activeProfile = profiles[index]
        }
        return committed
    }

    func loadCurrentUsage(
        for profileID: UUID,
        expectedProviderID: ProviderID,
        expectedProviderRevision: UInt64
    ) throws -> ProfileCurrentUsage? {
        try profileStore.loadCurrentUsage(
            for: profileID,
            expectedProviderID: expectedProviderID,
            expectedProviderRevision: expectedProviderRevision
        )
    }

    /// Saves Claude usage data for a specific profile
    @discardableResult
    func saveClaudeUsage(
        _ usage: ClaudeUsage,
        for profileId: UUID,
        publishToActiveProfile: Bool = true
    ) -> Bool {
        guard let index = profiles.firstIndex(where: { $0.id == profileId }) else {
            LoggingService.shared.logError("saveClaudeUsage: Profile not found with ID: \(profileId)")
            return false
        }

        do {
            try profileStore.saveClaudeUsage(usage, for: profileId)
        } catch {
            LoggingService.shared.logStorageError("saveClaudeUsage", error: error)
            return false
        }

        profiles[index].claudeUsage = usage

        // Update activeProfile reference if it's the same profile
        if publishToActiveProfile, activeProfile?.id == profileId {
            activeProfile = profiles[index]
        }

        LoggingService.shared.log("Saved Claude usage for profile: \(profiles[index].name)")
        return true
    }

    /// Loads Claude usage data for a specific profile
    func loadClaudeUsage(for profileId: UUID) -> ClaudeUsage? {
        do {
            let usage = try profileStore.loadClaudeUsage(for: profileId)
            updateClaudeUsageInMemory(usage, for: profileId)
            return usage
        } catch {
            LoggingService.shared.logStorageError("loadClaudeUsage", error: error)
            return profiles.first(where: { $0.id == profileId })?.claudeUsage
        }
    }

    /// Saves API usage data for a specific profile
    @discardableResult
    func saveAPIUsage(
        _ usage: APIUsage,
        for profileId: UUID,
        publishToActiveProfile: Bool = true
    ) -> Bool {
        guard let index = profiles.firstIndex(where: { $0.id == profileId }) else {
            LoggingService.shared.logError("saveAPIUsage: Profile not found with ID: \(profileId)")
            return false
        }

        do {
            try profileStore.saveAPIUsage(usage, for: profileId)
        } catch {
            LoggingService.shared.logStorageError("saveAPIUsage", error: error)
            return false
        }

        profiles[index].apiUsage = usage

        // Update activeProfile reference if it's the same profile
        if publishToActiveProfile, activeProfile?.id == profileId {
            activeProfile = profiles[index]
        }

        LoggingService.shared.log("Saved API usage for profile: \(profiles[index].name)")
        return true
    }

    /// Loads API usage data for a specific profile
    func loadAPIUsage(for profileId: UUID) -> APIUsage? {
        do {
            let usage = try profileStore.loadAPIUsage(for: profileId)
            updateAPIUsageInMemory(usage, for: profileId)
            return usage
        } catch {
            LoggingService.shared.logStorageError("loadAPIUsage", error: error)
            return profiles.first(where: { $0.id == profileId })?.apiUsage
        }
    }

    // MARK: - Profile Settings

    /// Updates icon configuration for a profile
    func updateIconConfig(_ config: MenuBarIconConfiguration, for profileId: UUID) {
        if let index = profiles.firstIndex(where: { $0.id == profileId }) {
            profiles[index].iconConfig = config

            if activeProfile?.id == profileId {
                activeProfile = profiles[index]
            }

            profileStore.saveProfiles(profiles)
        }
    }

    /// Updates refresh interval for a profile
    func updateRefreshInterval(_ interval: TimeInterval, for profileId: UUID) {
        if let index = profiles.firstIndex(where: { $0.id == profileId }) {
            profiles[index].refreshInterval = interval

            if activeProfile?.id == profileId {
                activeProfile = profiles[index]
            }

            profileStore.saveProfiles(profiles)
        }
    }

    /// Updates auto-start session setting for a profile
    func updateAutoStartSessionEnabled(_ enabled: Bool, for profileId: UUID) {
        if let index = profiles.firstIndex(where: { $0.id == profileId }) {
            profiles[index].autoStartSessionEnabled = enabled

            if activeProfile?.id == profileId {
                activeProfile = profiles[index]
            }

            profileStore.saveProfiles(profiles)
        }
    }

    /// Updates check overage limit setting for a profile
    func updateCheckOverageLimitEnabled(_ enabled: Bool, for profileId: UUID) {
        guard var profile = profiles.first(where: { $0.id == profileId }) else {
            return
        }
        profile.checkOverageLimitEnabled = enabled
        updateProfile(profile)
    }

    /// Updates notification settings for a profile
    func updateNotificationSettings(_ settings: NotificationSettings, for profileId: UUID) {
        if let index = profiles.firstIndex(where: { $0.id == profileId }) {
            profiles[index].notificationSettings = settings

            if activeProfile?.id == profileId {
                activeProfile = profiles[index]
            }

            profileStore.saveProfiles(profiles)
        }
    }

    /// Updates organization ID for a profile
    func updateOrganizationId(_ orgId: String?, for profileId: UUID) {
        guard var profile = profiles.first(where: { $0.id == profileId }) else {
            return
        }
        profile.organizationId = orgId
        updateProfile(profile)
    }

    /// Updates the cached claude.ai organization name for a profile
    func updateOrganizationName(_ name: String?, for profileId: UUID) {
        guard var profile = profiles.first(where: { $0.id == profileId }) else {
            return
        }
        profile.organizationName = name
        updateProfile(profile)
    }

    /// Records whether a profile's claude.ai organization is a single-person
    /// organization. `nil` leaves the classification undetermined.
    func updateOrganizationIsPersonal(_ isPersonal: Bool?, for profileId: UUID) {
        guard var profile = profiles.first(where: { $0.id == profileId }) else {
            return
        }
        profile.organizationIsPersonal = isPersonal
        updateProfile(profile)
    }

    /// Records which Chrome profile the stored claude.ai session key was
    /// read from, or `nil` when the key did not come from Chrome.
    ///
    /// Always written alongside the key it describes, including the `nil`
    /// case: a key typed by hand must not inherit the Chrome origin of the
    /// key it replaced, or a later automatic re-read would overwrite it from
    /// a browser profile the user never pointed at this key.
    func updateChromeSessionKeySource(
        _ source: ProfileChromeSessionKeySource?,
        for profileId: UUID
    ) {
        guard var profile = profiles.first(where: { $0.id == profileId }),
              profile.providerID == .claude else {
            return
        }
        guard profile.chromeSessionKeySource != source else { return }
        profile.chromeSessionKeySource = source
        updateProfile(profile)
    }

    /// Caches the organization the profile's CLI credential belongs to.
    ///
    /// The CLI login can belong to a different organization than the
    /// claude.ai session key, so this is what member-scoped figures are
    /// checked against before they are shown under this profile.
    func updateCliOrganizationId(_ orgId: String?, for profileId: UUID) {
        guard var profile = profiles.first(where: { $0.id == profileId }) else {
            return
        }
        profile.cliOrganizationId = orgId
        updateProfile(profile)
    }

    /// Updates API organization ID for a profile
    func updateAPIOrganizationId(_ orgId: String?, for profileId: UUID) {
        guard var profile = profiles.first(where: { $0.id == profileId }) else {
            return
        }
        profile.apiOrganizationId = orgId
        updateProfile(profile)
    }

    // MARK: - Private Helpers

    private func updateClaudeUsageInMemory(_ usage: ClaudeUsage?, for profileID: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else {
            return
        }
        profiles[index].claudeUsage = usage
        if activeProfile?.id == profileID {
            activeProfile = profiles[index]
        }
    }

    private func updateAPIUsageInMemory(_ usage: APIUsage?, for profileID: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else {
            return
        }
        profiles[index].apiUsage = usage
        if activeProfile?.id == profileID {
            activeProfile = profiles[index]
        }
    }

}

// MARK: - ProfileError

enum ProfileError: LocalizedError, Equatable {
    case cannotDeleteLastProfile

    var errorDescription: String? {
        switch self {
        case .cannotDeleteLastProfile:
            return "Cannot delete the last profile. At least one profile is required."
        }
    }
}
