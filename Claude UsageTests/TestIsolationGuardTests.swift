import XCTest
@testable import Claude_Usage

/// Isolation is a property that stops holding silently.
///
/// `makeIsolatedProfileStore()` resolves to `UserDefaults.standard` and
/// `KeychainService.shared`, and `ProfileManager()` resolves to the shared
/// store. Nothing at those call sites looks wrong, which is why a test in
/// this suite once built `ProfileManager()` on the shared store and came one
/// step from writing six live session keys into the developer's Keychain and
/// rewriting their preferences file.
///
/// The helpers in `HostedTestSupport` prevent that. These assert the helpers
/// actually do, so removing the injection fails here instead of quietly
/// reaching real user storage again.
/// Subclasses `HostedAppTestCase` and retains the stores it builds: releasing
/// an injected actor-isolated service from the Objective-C test thunk trips a
/// runtime allocator bug on the current macOS XCTest, which shows up as
/// `pointer being freed was not allocated` rather than as a test failure.
final class TestIsolationGuardTests: HostedAppTestCase {
    private static let profilesKey = "profiles_v3"

    /// Deliberately read-only: it seeds the *injected* defaults and checks the
    /// store reads them back. If the helper stopped injecting, the store would
    /// return the developer's real profiles and this fails — without having
    /// written anything anywhere.
    @MainActor
    func testTheIsolatedStoreReadsInjectedDefaultsNotTheRealOnes() throws {
        let defaults = IsolatedProfileDefaults()
        let marker = "Isolated-\(UUID().uuidString)"
        defaults.set(
            try JSONEncoder().encode([Profile(name: marker)]),
            forKey: Self.profilesKey
        )
        let store = retain(makeIsolatedProfileStore(defaults: defaults))

        let profiles = try store.loadProfilesWithVerifiedMigration()

        XCTAssertEqual(
            profiles.map(\.name),
            [marker],
            "The store read something other than the injected defaults — "
                + "isolation is not in effect"
        )
    }

    /// The real preferences domain must be untouched by the above.
    @MainActor
    func testTheIsolatedStoreDoesNotWriteToRealDefaults() throws {
        let before = UserDefaults.standard.data(forKey: Self.profilesKey)
        let defaults = IsolatedProfileDefaults()
        defaults.set(
            try JSONEncoder().encode([Profile(name: "Isolated")]),
            forKey: Self.profilesKey
        )

        _ = try retain(makeIsolatedProfileStore(defaults: defaults))
            .loadProfilesWithVerifiedMigration()

        XCTAssertEqual(
            UserDefaults.standard.data(forKey: Self.profilesKey),
            before,
            "A test mutated the real preferences domain"
        )
    }

    /// Secrets go to memory, never the login Keychain.
    func testTheIsolatedSecretStoreKeepsSecretsInMemory() throws {
        let secrets = retain(IsolatedProfileSecrets())
        let locator = ProfileSecretLocator(
            profileID: UUID(),
            field: .claudeSessionKey
        )

        try secrets.write("sk-ant-sid01-ISOLATION-CHECK", to: locator)

        XCTAssertEqual(
            try secrets.read(locator),
            .value("sk-ant-sid01-ISOLATION-CHECK")
        )
        // A missing item is absent, not an error — the same distinction the
        // real store makes, and the one whose absence caused the original
        // rollback bug.
        XCTAssertEqual(
            try secrets.read(
                ProfileSecretLocator(profileID: UUID(), field: .apiSessionKey)
            ),
            .absent
        )
    }

    /// A manager from the helper must read the store it was given.
    ///
    /// Asserted with a seeded marker rather than by checking the list is
    /// empty. "Empty" passes vacuously on CI and on any fresh machine even
    /// with the injection removed, so it would have been a guard that cannot
    /// fail exactly where it runs most — the tautology trap in different
    /// clothes. Requiring a specific profile fails everywhere.
    @MainActor
    func testTheIsolatedManagerReadsTheInjectedStore() throws {
        let defaults = IsolatedProfileDefaults()
        let marker = "Isolated-\(UUID().uuidString)"
        defaults.set(
            try JSONEncoder().encode([Profile(name: marker)]),
            forKey: Self.profilesKey
        )
        let manager = retain(
            ProfileManager(
                profileStore: retain(
                    makeIsolatedProfileStore(defaults: defaults)
                )
            )
        )

        // The manager does not load at init — which is why the earlier
        // `profiles.isEmpty` version of this test passed no matter what store
        // it was given. Drive the load explicitly.
        manager.loadProfiles()

        XCTAssertEqual(
            manager.profiles.map(\.name),
            [marker],
            "The manager read profiles from somewhere other than the injected "
                + "store"
        )
    }

    /// The usage files are the third dependency, and the one that was missed:
    /// `ProfileStore` resolves it to the real Application Support directory
    /// when un-injected, so isolation covered the defaults and the Keychain
    /// but not the disk.
    @MainActor
    func testTheIsolatedUsageFileStoreKeepsUsageInMemory() throws {
        let usageFiles = retain(IsolatedProfileUsageFiles())
        let profileID = UUID()

        _ = try usageFiles.updateCurrentUsage(for: profileID) { usage in
            usage.providerRevision = 7
        }

        XCTAssertNotNil(try usageFiles.loadCurrentUsage(for: profileID))
        XCTAssertNil(
            try usageFiles.loadCurrentUsage(for: UUID()),
            "An unknown profile must have no usage, not someone else's"
        )
    }

    /// Testing the fake is not the same as testing that the store was handed
    /// it. Without this, dropping `usageFileStore:` from the helper would put
    /// every isolated store back on the real Application Support directory
    /// and nothing would fail — a guard that cannot fail, which is the
    /// mistake this whole file exists to stop repeating.
    ///
    /// Same marker technique as the defaults and manager guards: seed the
    /// injected fake, then require the store to serve that exact value back.
    @MainActor
    func testTheIsolatedStoreIsActuallyWiredToTheInjectedUsageFiles() throws {
        let profile = Profile(name: "Wiring")
        let defaults = IsolatedProfileDefaults()
        defaults.set(
            try JSONEncoder().encode([profile]),
            forKey: Self.profilesKey
        )
        let usageFiles = retain(IsolatedProfileUsageFiles())
        // The revision has to match the profile's, or the store's identity
        // fence rejects the record before the wiring question is reached.
        try usageFiles.saveCurrentUsage(
            ProfileCurrentUsage(
                providerID: .claude,
                providerRevision: profile.providerRevision,
                claudeUsage: nil
            ),
            for: profile.id
        )
        let store = retain(
            makeIsolatedProfileStore(defaults: defaults, usageFiles: usageFiles)
        )

        let loaded = try store.loadCurrentUsage(
            for: profile.id,
            expectedProviderID: .claude,
            expectedProviderRevision: profile.providerRevision
        )

        // Presence is the signal: this profile ID is freshly generated, so the
        // real Application Support directory has no record for it and an
        // un-injected store returns nil.
        XCTAssertNotNil(
            loaded,
            "The store did not read the injected usage-file store — it is "
                + "still pointed at real Application Support"
        )
    }

    /// The overload used to convert direct test-side `ProfileStore(...)`
    /// calls must carry every seam too. It deliberately uses credentials and
    /// usage that exist only in the injected doubles: falling back to either
    /// `.shared` singleton or the real Application Support directory makes
    /// one of these marker reads fail.
    @MainActor
    func testTheDirectConstructionHelperKeepsCredentialsAndFilesIsolated()
        throws {
        let profile = Profile(name: "Direct-construction isolation")
        let defaults = IsolatedProfileDefaults()
        let secrets = IsolatedProfileSecrets()
        let usageFiles = IsolatedProfileUsageFiles()
        defaults.set(
            try JSONEncoder().encode([profile]),
            forKey: Self.profilesKey
        )
        try secrets.write(
            "isolated-secret",
            to: ProfileSecretLocator(
                profileID: profile.id,
                field: .claudeSessionKey
            )
        )
        try usageFiles.saveCurrentUsage(
            ProfileCurrentUsage(
                providerID: .claude,
                providerRevision: profile.providerRevision
            ),
            for: profile.id
        )

        let store = retain(makeIsolatedProfileStore(
            defaults: defaults,
            secretStore: secrets,
            usageFileStore: usageFiles
        ))

        XCTAssertEqual(
            try store.loadProfileCredentials(profile.id).claudeSessionKey,
            "isolated-secret",
            "The direct-construction helper fell back to KeychainService.shared"
        )
        XCTAssertNotNil(
            try store.loadCurrentUsage(
                for: profile.id,
                expectedProviderID: .claude,
                expectedProviderRevision: profile.providerRevision
            ),
            "The direct-construction helper fell back to real Application Support"
        )
    }

    /// This is the test that would have caught the original bug. A hosted
    /// test that reaches `ProfileManager.linkCodexHome`/`activateProfile`
    /// through one of the ~65 `ProfileManager(...)` call sites that don't
    /// inject `activationCodexEffects` falls through to `.live`, which
    /// calls `CodexSwitchService.shared` — and that singleton used to write
    /// the developer's REAL `~/.claude-tokens/.last-codex-home` pointer
    /// file and mutate their real tmux server. It's now inert under hosted
    /// unit tests (see `AppDelegate.isRunningHostedUnitTests` and
    /// `CodexSwitchService.shared`'s init), so this calls the singleton
    /// directly and requires the real pointer file to be byte-identical (or
    /// still absent) before and after.
    ///
    /// Deliberately does not redirect `HOME` the way `CodexSwitchServiceTests`
    /// does: redirecting it would point this test at an isolated file
    /// instead of the one the original bug actually corrupted. The whole
    /// point is that `CodexSwitchService.shared` protects the real path on
    /// its own, unconditionally, during hosted tests — this only reads the
    /// real path, both before and after.
    ///
    /// Non-destructive even if the backstop has regressed: the calls below
    /// are made against the real path on purpose (that's what makes this
    /// the test that would have caught the original bug), so if inertness
    /// ever breaks, they really do write through. A `defer` restores the
    /// captured `before` bytes unconditionally — including when the
    /// assertion fails — so a regression is reported, not silently
    /// re-poisoned into the developer's real pointer file the way the
    /// original bug did.
    func testCodexSwitchServiceSharedNeverWritesTheRealPointerFileDuringHostedTests() throws {
        let realPointerFile = Constants.ClaudePaths.homeDirectory
            .appendingPathComponent(".claude-tokens")
            .appendingPathComponent(".last-codex-home")
        let before = try? Data(contentsOf: realPointerFile)
        defer {
            if let before {
                try? before.write(to: realPointerFile)
            } else {
                try? FileManager.default.removeItem(at: realPointerFile)
            }
        }

        let tempHomeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "isolation-guard-codex-home-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: tempHomeURL, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempHomeURL) }
        let home = try CodexHomeCanonicalizer().canonicalize(tempHomeURL.path)

        try CodexSwitchService.shared.switchToHome(home)
        CodexSwitchService.shared.clearHome()

        let after = try? Data(contentsOf: realPointerFile)
        XCTAssertEqual(
            before,
            after,
            "CodexSwitchService.shared wrote to the developer's real "
                + "~/.claude-tokens/.last-codex-home pointer file during a "
                + "hosted unit test run — the inertness backstop regressed"
        )
    }
}
