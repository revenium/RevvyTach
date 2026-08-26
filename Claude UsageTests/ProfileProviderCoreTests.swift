import XCTest
import UsageCore
@testable import Claude_Usage

final class ProfileProviderCoreTests: HostedAppTestCase {
    @MainActor
    func testExpiredRefreshableTerminalLoginRemainsUsageEligible() {
        let profile = Profile(
            name: "Renewable terminal login",
            cliCredentialsJSON: #"{"claudeAiOauth":{"accessToken":"expired","refreshToken":"renew-me","expiresAt":1}}"#
        )

        XCTAssertFalse(profile.hasValidCLIOAuth)
        XCTAssertTrue(profile.hasRenewableCLILogin)
        XCTAssertTrue(profile.hasUsageCredentials)
        XCTAssertFalse(profile.hasImmediatelyUsableCredentials)
    }

    @MainActor
    func testExpiredTokenlessTerminalLoginIsNotUsageEligible() {
        let profile = Profile(
            name: "Dead terminal login",
            cliCredentialsJSON: #"{"claudeAiOauth":{"accessToken":"expired","expiresAt":1}}"#
        )

        XCTAssertFalse(profile.hasValidCLIOAuth)
        XCTAssertFalse(profile.hasRenewableCLILogin)
        XCTAssertFalse(profile.hasUsageCredentials)
        XCTAssertFalse(profile.hasImmediatelyUsableCredentials)
    }

    @MainActor
    func testLinkedTerminalAccountRemainsUsageEligibleForLiveLoginAdoption() {
        let profile = Profile(
            name: "Linked terminal account",
            cliAccountName: "linked-account"
        )

        XCTAssertTrue(profile.hasRenewableCLILogin)
        XCTAssertTrue(profile.hasUsageCredentials)
        XCTAssertFalse(profile.hasImmediatelyUsableCredentials)
    }

    @MainActor
    func testTokenlessBlobWithoutExpiryIsNotUsageEligible() {
        let profile = Profile(
            name: "Tokenless terminal blob",
            cliCredentialsJSON: #"{"claudeAiOauth":{"subscriptionType":"pro"}}"#
        )

        XCTAssertFalse(profile.hasValidCLIOAuth)
        XCTAssertFalse(profile.hasRenewableCLILogin)
        XCTAssertFalse(profile.hasUsageCredentials)
        XCTAssertFalse(profile.hasImmediatelyUsableCredentials)
    }

    @MainActor
    func testRefreshTokenOnlyBlobIsNotUsageEligible() {
        let profile = Profile(
            name: "Refresh metadata without a login",
            cliCredentialsJSON: #"{"claudeAiOauth":{"refreshToken":"orphaned-refresh-token","expiresAt":1}}"#
        )

        XCTAssertFalse(profile.hasValidCLIOAuth)
        XCTAssertFalse(profile.hasRenewableCLILogin)
        XCTAssertFalse(profile.hasUsageCredentials)
    }

    @MainActor
    func testBlankLinkedTerminalAccountIsNotUsageEligible() {
        let profile = Profile(
            name: "Blank linked account",
            cliAccountName: "  \n "
        )

        XCTAssertFalse(profile.hasRenewableCLILogin)
        XCTAssertFalse(profile.hasUsageCredentials)
    }

    @MainActor
    func testLegacyProfileDefaultsToClaudeAndRevisionZero() throws {
        let original = Profile(name: "Legacy")
        let encoded = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "provider")
        object.removeValue(forKey: "providerRevision")

        let decoded = try JSONDecoder().decode(
            Profile.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.providerConfiguration, .claude)
        XCTAssertEqual(decoded.providerRevision, 0)
    }

    @MainActor
    func testProviderConfigurationUsesStrictClosedTaggedShape() throws {
        let codex = Profile(
            name: "Codex",
            providerConfiguration: .codex(.init())
        )
        let roundTrip = try JSONDecoder().decode(
            Profile.self,
            from: JSONEncoder().encode(codex)
        )
        XCTAssertEqual(roundTrip, codex)

        let invalidShapes = [
            #"{"kind":"claude","codex":{}}"#,
            #"{"kind":"codex"}"#,
            #"{"kind":"codex","codex":{},"unexpected":true}"#,
            #"{"kind":"future"}"#
        ]
        for shape in invalidShapes {
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    ProfileProviderConfiguration.self,
                    from: Data(shape.utf8)
                ),
                "Expected rejection for \(shape)"
            )
        }

        var codexObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(codex)
            ) as? [String: Any]
        )
        codexObject.removeValue(forKey: "providerRevision")
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                Profile.self,
                from: JSONSerialization.data(withJSONObject: codexObject)
            )
        )
        codexObject["providerRevision"] = NSNull()
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                Profile.self,
                from: JSONSerialization.data(withJSONObject: codexObject)
            )
        )
    }

    @MainActor
    func testExplicitNullProviderAndMixedClaudeStateAreRejected() throws {
        let encoded = try JSONEncoder().encode(Profile(name: "Invalid"))
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["provider"] = NSNull()
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                Profile.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        )

        let invalid = Profile(
            name: "Mixed",
            providerConfiguration: .codex(.init()),
            organizationId: "claude-org"
        )
        XCTAssertThrowsError(try JSONEncoder().encode(invalid)) { error in
            XCTAssertEqual(
                error as? ProfileProviderConfigurationError,
                .claudeStateOnCodexProfile(invalid.id)
            )
        }

        let usage = APIUsage(
            currentSpendCents: 1,
            resetsAt: Date(),
            prepaidCreditsCents: 2,
            currency: "USD",
            apiTokenCostCents: nil,
            apiCostByModel: nil,
            costBySource: nil,
            dailyCostCents: nil
        )
        let invalidRuntimeUsage = Profile(
            name: "Mixed Usage",
            providerConfiguration: .codex(.init()),
            apiUsage: usage
        )
        XCTAssertThrowsError(
            try JSONEncoder().encode(invalidRuntimeUsage)
        )

        let claudeWithLegacyUsage = Profile(
            name: "Decoded Mixed Usage",
            currentUsageMigrationRetry: .init(apiUsage: usage)
        )
        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(claudeWithLegacyUsage)
            ) as? [String: Any]
        )
        legacyObject["provider"] = [
            "kind": "codex",
            "codex": [:]
        ]
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                Profile.self,
                from: JSONSerialization.data(
                    withJSONObject: legacyObject
                )
            )
        )
    }

    @MainActor
    func testCanonicalizerExpandsTildeResolvesSymlinkAndDoesNotReadAuth() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let physical = root.appendingPathComponent("real", isDirectory: true)
        let link = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(
            at: physical,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: physical
        )
        let auth = physical.appendingPathComponent("auth.json")
        let sentinel = Data(#"{"sentinel":"do-not-touch"}"#.utf8)
        try sentinel.write(to: auth)
        let canonicalizer = CodexHomeCanonicalizer(homeDirectory: root)

        let tilde = try canonicalizer.canonicalize("~/real")
        let symlink = try canonicalizer.canonicalize(link.path)

        XCTAssertEqual(tilde.path, physical.path)
        XCTAssertEqual(symlink.path, physical.path)
        XCTAssertEqual(try Data(contentsOf: auth), sentinel)
    }

    @MainActor
    func testCanonicalizerRejectsUnsafeOrNonDirectoryInputs() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file")
        try Data("x".utf8).write(to: file)
        let canonicalizer = CodexHomeCanonicalizer(homeDirectory: root)

        let invalid = [
            "",
            "relative",
            "/",
            root.appendingPathComponent("missing").path,
            file.path,
            "\(root.path);touch bad",
            "\(root.path)/$(bad)",
            " \(root.path)"
        ]
        for path in invalid {
            XCTAssertThrowsError(
                try canonicalizer.canonicalize(path),
                "Expected rejection for \(path)"
            )
        }
    }

    @MainActor
    func testCanonicalizerPreventsExactAndSymlinkDuplicates() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let physical = root.appendingPathComponent("real", isDirectory: true)
        let link = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(
            at: physical,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: physical
        )
        let canonicalizer = CodexHomeCanonicalizer(homeDirectory: root)
        let home = try canonicalizer.canonicalize(physical.path)
        let owner = Profile(
            name: "Owner",
            providerConfiguration: .codex(
                CodexProfileConfiguration(linkedHome: home)
            )
        )

        XCTAssertThrowsError(
            try canonicalizer.canonicalize(
                physical.path,
                existingProfiles: [owner]
            )
        )
        XCTAssertThrowsError(
            try canonicalizer.canonicalize(
                link.path,
                existingProfiles: [owner]
            )
        )
        XCTAssertNoThrow(
            try canonicalizer.canonicalize(
                link.path,
                excludingProfileID: owner.id,
                existingProfiles: [owner]
            )
        )
    }

    @MainActor
    func testCanonicalizerAndProfileStoreAcceptDistinctPhysicalHomes()
        throws
    {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstURL = root.appendingPathComponent(
            "first-home",
            isDirectory: true
        )
        let secondURL = root.appendingPathComponent(
            "second-home",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: firstURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: secondURL,
            withIntermediateDirectories: true
        )
        let canonicalizer = CodexHomeCanonicalizer()
        let firstHome = try canonicalizer.canonicalize(firstURL.path)
        let firstProfile = Profile(
            name: "First",
            providerConfiguration: .codex(.init(linkedHome: firstHome))
        )
        let secondHome = try canonicalizer.canonicalize(
            secondURL.path,
            existingProfiles: [firstProfile]
        )
        let secondProfile = Profile(
            name: "Second",
            providerConfiguration: .codex(.init(linkedHome: secondHome))
        )
        let store = retain(makeIsolatedProfileStore(
            defaults: ProviderTestDefaults(),
            secretStore: ProviderSecretStore(),
            usageFileStore: ProviderUsageStore()
        ))

        try seedProfilesForTesting(
            [firstProfile, secondProfile],
            in: store
        )

        XCTAssertNotEqual(firstHome, secondHome)
        XCTAssertNotEqual(
            firstHome.filesystemIdentity,
            secondHome.filesystemIdentity
        )
        XCTAssertEqual(
            store.loadProfiles().map(\.id),
            [firstProfile.id, secondProfile.id]
        )
    }

    @MainActor
    func testCanonicalizerFollowsActualVolumeCaseIdentity() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let mixedCaseURL = root.appendingPathComponent(
            "CodexHome",
            isDirectory: true
        )
        let alternateCaseURL = root.appendingPathComponent(
            "codexhome",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: mixedCaseURL,
            withIntermediateDirectories: true
        )
        let canonicalizer = CodexHomeCanonicalizer()
        let mixedCaseHome = try canonicalizer.canonicalize(
            mixedCaseURL.path
        )
        let owner = Profile(
            name: "Owner",
            providerConfiguration: .codex(
                .init(linkedHome: mixedCaseHome)
            )
        )

        var alternateIsDirectory: ObjCBool = false
        let alternateAlreadyExists = FileManager.default.fileExists(
            atPath: alternateCaseURL.path,
            isDirectory: &alternateIsDirectory
        )
        if alternateAlreadyExists {
            XCTAssertTrue(alternateIsDirectory.boolValue)
            let alternateIdentity = try XCTUnwrap(
                CodexHomeFilesystemIdentity.read(from: alternateCaseURL)
            )
            XCTAssertEqual(
                alternateIdentity,
                mixedCaseHome.filesystemIdentity
            )
            XCTAssertThrowsError(
                try canonicalizer.canonicalize(
                    alternateCaseURL.path,
                    existingProfiles: [owner]
                )
            ) { error in
                XCTAssertEqual(
                    error as? ProfileProviderConfigurationError,
                    .duplicateCodexHome(owner.id)
                )
            }
        } else {
            try FileManager.default.createDirectory(
                at: alternateCaseURL,
                withIntermediateDirectories: true
            )
            let alternateHome = try canonicalizer.canonicalize(
                alternateCaseURL.path,
                existingProfiles: [owner]
            )
            XCTAssertNotEqual(
                alternateHome.filesystemIdentity,
                mixedCaseHome.filesystemIdentity
            )
            XCTAssertNotEqual(alternateHome, mixedCaseHome)
        }
    }

    @MainActor
    func testProviderIdentityHomeAndRevisionCannotChangeInOrdinarySave() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first", isDirectory: true)
        let second = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(
            at: first,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: second,
            withIntermediateDirectories: true
        )
        let canonicalizer = CodexHomeCanonicalizer()
        let firstHome = try canonicalizer.canonicalize(first.path)
        let secondHome = try canonicalizer.canonicalize(second.path)
        let defaults = ProviderTestDefaults()
        let store = retain(makeIsolatedProfileStore(
            defaults: defaults,
            secretStore: ProviderSecretStore(),
            usageFileStore: ProviderUsageStore()
        ))
        let profile = Profile(
            name: "Codex",
            providerConfiguration: .codex(.init(linkedHome: firstHome))
        )
        try seedProfilesForTesting([profile], in: store)

        var changedProvider = profile
        changedProvider.providerConfiguration = .claude
        XCTAssertThrowsError(try store.saveProfilesThrowing([changedProvider]))

        var changedHome = profile
        changedHome.providerConfiguration = .codex(
            .init(linkedHome: secondHome)
        )
        XCTAssertThrowsError(try store.saveProfilesThrowing([changedHome]))

        var changedRevision = profile
        changedRevision.providerRevision = 1
        XCTAssertThrowsError(try store.saveProfilesThrowing([changedRevision]))
        XCTAssertEqual(store.loadProfiles().first, profile)
    }

    @MainActor
    func testCredentialUpdateAPIsCannotMutateProviderIdentity() throws {
        let defaults = ProviderTestDefaults()
        let secrets = ProviderSecretStore()
        let store = retain(makeIsolatedProfileStore(
            defaults: defaults,
            secretStore: secrets,
            usageFileStore: ProviderUsageStore()
        ))
        let profile = Profile(
            name: "Claude",
            claudeSessionKey: "old-secret",
            cliCredentialsJSON: "old-cli"
        )
        try seedProfilesForTesting([profile], in: store)

        var providerAndRevisionChange = profile
        providerAndRevisionChange.providerConfiguration = .codex(.init())
        providerAndRevisionChange.providerRevision = 1
        providerAndRevisionChange.claudeSessionKey = "new-secret"
        secrets.reset()

        XCTAssertThrowsError(
            try store.saveProfileUpdate(providerAndRevisionChange)
        ) { error in
            XCTAssertEqual(
                error as? ProfileProviderConfigurationError,
                .providerChangeNotAllowed(profile.id)
            )
        }
        XCTAssertEqual(secrets.writeCount, 0)
        XCTAssertEqual(secrets.deleteCount, 0)

        var revisionAndCLIChange = profile
        revisionAndCLIChange.providerRevision = 1
        revisionAndCLIChange.cliCredentialsJSON = "new-cli"
        secrets.reset()

        XCTAssertThrowsError(
            try store.saveCLIProfileUpdate(revisionAndCLIChange)
        ) { error in
            XCTAssertEqual(
                error as? ProfileProviderConfigurationError,
                .providerRevisionChangeNotAllowed(profile.id)
            )
        }
        XCTAssertEqual(secrets.writeCount, 0)
        XCTAssertEqual(secrets.deleteCount, 0)
        XCTAssertEqual(store.loadProfiles().first?.providerRevision, 0)
    }

    @MainActor
    func testOrdinarySaveCannotAddOrRemoveProfileIdentities() throws {
        let defaults = ProviderTestDefaults()
        let store = retain(makeIsolatedProfileStore(
            defaults: defaults,
            secretStore: ProviderSecretStore(),
            usageFileStore: ProviderUsageStore()
        ))
        let first = Profile(
            name: "First",
            providerConfiguration: .codex(.init())
        )
        let second = Profile(
            name: "Second",
            providerConfiguration: .codex(.init())
        )
        let added = Profile(
            name: "Added",
            providerConfiguration: .codex(.init())
        )
        try seedProfilesForTesting([first, second], in: store)

        XCTAssertThrowsError(
            try store.saveProfilesThrowing([first])
        ) { error in
            XCTAssertEqual(
                error as? ProfileProviderConfigurationError,
                .profileSetChanged
            )
        }
        XCTAssertThrowsError(
            try store.saveProfilesThrowing([first, second, added])
        ) { error in
            XCTAssertEqual(
                error as? ProfileProviderConfigurationError,
                .profileSetChanged
            )
        }
        XCTAssertEqual(
            Set(store.loadProfiles().map(\.id)),
            Set([first.id, second.id])
        )
    }

    @MainActor
    func testInvalidAuthoritativeProfileSetsFailClosedWithoutOverwrite()
        throws {
        let defaults = ProviderTestDefaults()
        let store = retain(makeIsolatedProfileStore(
            defaults: defaults,
            secretStore: ProviderSecretStore(),
            usageFileStore: ProviderUsageStore()
        ))
        let duplicate = Profile(
            name: "Duplicate",
            providerConfiguration: .codex(.init())
        )
        let duplicateData = try JSONEncoder().encode([
            duplicate,
            duplicate
        ])
        defaults.set(duplicateData, forKey: "profiles_v3")

        XCTAssertThrowsError(
            try store.loadProfilesWithVerifiedMigration()
        ) { error in
            XCTAssertEqual(
                error as? ProfileProviderConfigurationError,
                .duplicateProfileID(duplicate.id)
            )
        }
        XCTAssertTrue(store.loadProfiles().isEmpty)
        XCTAssertEqual(
            defaults.data(forKey: "profiles_v3"),
            duplicateData
        )
        XCTAssertThrowsError(
            try store.createInitialProfile(
                Profile(
                    name: "Replacement",
                    providerConfiguration: .codex(.init())
                )
            )
        )

        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let homeURL = root.appendingPathComponent(
            "shared-home",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: homeURL,
            withIntermediateDirectories: true
        )
        let home = try CodexHomeCanonicalizer()
            .canonicalize(homeURL.path)
        let first = Profile(
            name: "First Home",
            providerConfiguration: .codex(.init(linkedHome: home))
        )
        let second = Profile(
            name: "Second Home",
            providerConfiguration: .codex(.init(linkedHome: home))
        )
        let duplicateHomeData = try JSONEncoder().encode([
            first,
            second
        ])
        defaults.set(duplicateHomeData, forKey: "profiles_v3")

        XCTAssertThrowsError(
            try store.loadProfilesWithVerifiedMigration()
        ) { error in
            XCTAssertEqual(
                error as? ProfileProviderConfigurationError,
                .duplicateCodexHome(first.id)
            )
        }
        XCTAssertEqual(
            defaults.data(forKey: "profiles_v3"),
            duplicateHomeData
        )
    }

    @MainActor
    func testGoldenLegacyMigrationPreservesDataAndSafeDiagnostics()
        throws
    {
        let (defaults, suite) = try HostedTestDefaults.defaults(
            "ProfileProviderCoreTests"
        )
        HostedTestDefaults.reset(defaults, suiteName: suite)
        let root = try makeTemporaryDirectory()
        defer {
            HostedTestDefaults.finish(defaults, suiteName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let profileFixture = try fixtureData(
            named: "legacy-profiles-v3-golden.json"
        )
        let historyFixture = try fixtureData(
            named: "legacy-profile-history-golden.json"
        )
        let legacyProfiles = try JSONDecoder().decode(
            [Profile].self,
            from: profileFixture
        )
        let historiesByID = try JSONDecoder().decode(
            [String: UsageHistoryData].self,
            from: historyFixture
        )
        let primaryID = try XCTUnwrap(
            UUID(
                uuidString:
                    "11111111-1111-4111-8111-111111111111"
            )
        )
        let secondaryID = try XCTUnwrap(
            UUID(
                uuidString:
                    "22222222-2222-4222-8222-222222222222"
            )
        )
        let profileIDs = [primaryID, secondaryID]
        let sensitiveValues = [
            "golden-claude-secret-primary",
            "golden-api-secret-primary",
            "golden-cli-secret-primary",
            "golden-claude-secret-secondary",
            "golden-api-secret-secondary"
        ]
        let displayConfiguration = MultiProfileDisplayConfig(
            iconStyle: .percentage,
            showWeek: false,
            showProfileLabel: true,
            useSystemColor: true,
            showTimeMarker: false,
            showPaceMarker: false,
            usePaceColoring: false,
            showRemainingPercentage: true
        )
        defaults.set(profileFixture, forKey: "profiles_v3")
        defaults.set(
            primaryID.uuidString,
            forKey: "activeProfileId"
        )
        defaults.set(
            ProfileDisplayMode.multi.rawValue,
            forKey: "profileDisplayMode"
        )
        defaults.set(
            try JSONEncoder().encode(displayConfiguration),
            forKey: "multiProfileDisplayConfig"
        )
        for profileID in profileIDs {
            let history = try XCTUnwrap(
                historiesByID[profileID.uuidString]
            )
            defaults.set(
                try JSONEncoder().encode(history),
                forKey: "usageHistory_\(profileID.uuidString)"
            )
        }

        XCTAssertEqual(legacyProfiles.map(\.id), profileIDs)
        XCTAssertEqual(
            legacyProfiles.map(\.name),
            ["Legacy Primary", "Legacy Secondary"]
        )
        XCTAssertTrue(
            legacyProfiles.allSatisfy {
                $0.providerConfiguration == .claude
                    && $0.providerRevision == 0
            }
        )
        XCTAssertEqual(
            legacyProfiles.map(\.isSelectedForDisplay),
            [true, false]
        )
        XCTAssertEqual(
            legacyProfiles.map(\.createdAt),
            [
                Date(timeIntervalSinceReferenceDate: 1000),
                Date(timeIntervalSinceReferenceDate: 3000)
            ]
        )
        XCTAssertEqual(
            legacyProfiles.map(\.lastUsedAt),
            [
                Date(timeIntervalSinceReferenceDate: 2000),
                Date(timeIntervalSinceReferenceDate: 4000)
            ]
        )

        let secrets = ProviderSecretStore()
        let usageStore = ProfileUsageFileStore(
            baseURL: root,
            now: {
                Date(timeIntervalSinceReferenceDate: 9000)
            }
        )
        let store = retain(makeIsolatedProfileStore(
            defaults: defaults,
            secretStore: secrets,
            usageFileStore: usageStore
        ))
        let firstLoad = try store.loadProfilesWithVerifiedMigration()
        var expectedRuntimeProfiles = legacyProfiles
        for index in expectedRuntimeProfiles.indices {
            expectedRuntimeProfiles[index].credentialMigrationRetry =
                .init()
            expectedRuntimeProfiles[index].currentUsageMigrationRetry =
                nil
        }

        XCTAssertEqual(firstLoad, expectedRuntimeProfiles)
        XCTAssertEqual(firstLoad[0].refreshInterval, 47)
        XCTAssertTrue(firstLoad[0].autoStartSessionEnabled)
        XCTAssertFalse(firstLoad[0].checkOverageLimitEnabled)
        XCTAssertEqual(
            firstLoad[0].notificationSettings.customThresholds,
            [82]
        )
        XCTAssertEqual(firstLoad[1].refreshInterval, 93)
        XCTAssertFalse(firstLoad[1].notificationSettings.enabled)
        XCTAssertEqual(store.loadLegacyActiveProfileId(), primaryID)
        XCTAssertEqual(store.loadDisplayMode(), .multi)
        XCTAssertEqual(
            store.loadMultiProfileConfig(),
            displayConfiguration
        )

        for profile in legacyProfiles {
            let expectedUsage = try XCTUnwrap(
                profile.currentUsageMigrationRetry
            )
            XCTAssertEqual(
                try usageStore.loadCurrentUsage(for: profile.id),
                expectedUsage
            )
            for field in ProfileSecretField.allCases {
                let expected = profile.credentialMigrationRetry.value(
                    for: field
                )
                XCTAssertEqual(
                    secrets.values[
                        ProfileSecretLocator(
                            profileID: profile.id,
                            field: field
                        )
                    ],
                    expected
                )
            }
        }

        let historyService = retain(UsageHistoryService(
            defaults: defaults,
            fileStore: usageStore,
            now: {
                Date(timeIntervalSinceReferenceDate: 9000)
            }
        ))
        for profileID in profileIDs {
            let expectedHistory = try XCTUnwrap(
                historiesByID[profileID.uuidString]
            )
            XCTAssertEqual(
                historyService.loadHistory(for: profileID),
                expectedHistory
            )
            XCTAssertEqual(
                try usageStore.load(
                    UsageHistoryData.self,
                    for: profileID,
                    providerID: "claude",
                    kind: .history
                ),
                expectedHistory
            )
            XCTAssertNil(
                defaults.data(
                    forKey: "usageHistory_\(profileID.uuidString)"
                )
            )
        }

        let migratedProfileData = try XCTUnwrap(
            defaults.data(forKey: "profiles_v3")
        )
        let migratedProfileText = try XCTUnwrap(
            String(data: migratedProfileData, encoding: .utf8)
        )
        let currentFileData = try Dictionary(
            uniqueKeysWithValues: profileIDs.map {
                (
                    $0,
                    try Data(
                        contentsOf: usageStore.fileURL(
                            for: $0,
                            kind: .currentUsage
                        )
                    )
                )
            }
        )
        let historyFileData = try Dictionary(
            uniqueKeysWithValues: profileIDs.map {
                (
                    $0,
                    try Data(
                        contentsOf: usageStore.fileURL(
                            for: $0,
                            kind: .history
                        )
                    )
                )
            }
        )
        for profileID in profileIDs {
            let currentEnvelope = try JSONDecoder().decode(
                ProfileUsageFileEnvelope<ProfileCurrentUsage>.self,
                from: try XCTUnwrap(currentFileData[profileID])
            )
            let historyEnvelope = try JSONDecoder().decode(
                ProfileUsageFileEnvelope<UsageHistoryData>.self,
                from: try XCTUnwrap(historyFileData[profileID])
            )
            XCTAssertEqual(currentEnvelope.profileID, profileID)
            XCTAssertEqual(currentEnvelope.providerID, "claude")
            XCTAssertEqual(
                currentEnvelope.recordKind,
                .currentUsage
            )
            XCTAssertEqual(historyEnvelope.profileID, profileID)
            XCTAssertEqual(historyEnvelope.providerID, "claude")
            XCTAssertEqual(historyEnvelope.recordKind, .history)
        }
        let firstMigrationWriteCount = secrets.writeCount
        let diagnosticAudit = secrets.auditEntries.joined(
            separator: "\n"
        )
        XCTAssertTrue(migratedProfileText.contains("\"provider\""))
        XCTAssertFalse(
            migratedProfileText.contains("credentialMigrationRetry")
        )
        XCTAssertFalse(
            migratedProfileText.contains("currentUsageMigrationRetry")
        )
        for value in sensitiveValues {
            XCTAssertFalse(migratedProfileText.contains(value))
            XCTAssertFalse(diagnosticAudit.contains(value))
            XCTAssertTrue(
                currentFileData.values.allSatisfy {
                    !String(decoding: $0, as: UTF8.self)
                        .contains(value)
                }
            )
            XCTAssertTrue(
                historyFileData.values.allSatisfy {
                    !String(decoding: $0, as: UTF8.self)
                        .contains(value)
                }
            )
        }
        XCTAssertEqual(firstMigrationWriteCount, 5)
        XCTAssertTrue(
            secrets.auditEntries.allSatisfy {
                $0.contains("profile ")
                    && $0.contains("field ")
            }
        )
        for profile in legacyProfiles {
            XCTAssertFalse(diagnosticAudit.contains(profile.name))
        }

        let secondLoad = try store.loadProfilesWithVerifiedMigration()
        _ = retain(UsageHistoryService(
            defaults: defaults,
            fileStore: usageStore,
            now: {
                Date(timeIntervalSinceReferenceDate: 9100)
            }
        ))

        XCTAssertEqual(secondLoad, firstLoad)
        XCTAssertEqual(secrets.writeCount, firstMigrationWriteCount)
        for value in sensitiveValues {
            XCTAssertFalse(
                secrets.auditEntries.joined(separator: "\n")
                    .contains(value)
            )
        }
        XCTAssertEqual(
            defaults.data(forKey: "profiles_v3"),
            migratedProfileData
        )
        for profileID in profileIDs {
            let expectedCurrentFileData = try XCTUnwrap(
                currentFileData[profileID]
            )
            let expectedHistoryFileData = try XCTUnwrap(
                historyFileData[profileID]
            )
            XCTAssertEqual(
                try Data(
                    contentsOf: usageStore.fileURL(
                        for: profileID,
                        kind: .currentUsage
                    )
                ),
                expectedCurrentFileData
            )
            XCTAssertEqual(
                try Data(
                    contentsOf: usageStore.fileURL(
                        for: profileID,
                        kind: .history
                    )
                ),
                expectedHistoryFileData
            )
        }
    }

    @MainActor
    func testUnchangedOfflineHomeAllowsMetadataEdit() throws {
        let root = try makeTemporaryDirectory()
        let linked = root.appendingPathComponent("offline", isDirectory: true)
        try FileManager.default.createDirectory(
            at: linked,
            withIntermediateDirectories: true
        )
        let home = try CodexHomeCanonicalizer().canonicalize(linked.path)
        let defaults = ProviderTestDefaults()
        let secrets = ProviderSecretStore()
        let store = retain(makeIsolatedProfileStore(
            defaults: defaults,
            secretStore: secrets,
            usageFileStore: ProviderUsageStore()
        ))
        var profile = Profile(
            name: "Before",
            providerConfiguration: .codex(.init(linkedHome: home))
        )
        try seedProfilesForTesting([profile], in: store)
        let manager = retain(ProfileManager(
            profileStore: store,
            activationClaudeEffects: .noOp
        ))
        manager.profiles = [profile]
        manager.activeProfile = profile
        try FileManager.default.removeItem(at: root)

        profile.name = "After"
        profile.refreshInterval = 75
        try store.saveProfilesThrowing([profile])

        XCTAssertEqual(store.loadProfiles().first?.name, "After")
        XCTAssertEqual(store.loadProfiles().first?.refreshInterval, 75)
        XCTAssertEqual(secrets.operationCount, 0)
        let offlineNoOp = try manager.linkCodexHome(
            home.path,
            for: profile.id
        )
        XCTAssertEqual(offlineNoOp.providerRevision, 0)
        XCTAssertEqual(
            offlineNoOp.providerConfiguration.codexConfiguration?.linkedHome,
            home
        )
    }

    @MainActor
    func testZeroProfileBootstrapAndExplicitInitialProviderChoice() throws {
        let defaults = ProviderTestDefaults()
        let secrets = ProviderSecretStore()
        let store = retain(makeIsolatedProfileStore(
            defaults: defaults,
            secretStore: secrets,
            usageFileStore: ProviderUsageStore()
        ))
        let manager = retain(ProfileManager(
            profileStore: store,
            activationClaudeEffects: .noOp
        ))

        manager.loadProfiles()
        XCTAssertTrue(manager.profiles.isEmpty)
        XCTAssertNil(manager.activeProfile)
        XCTAssertEqual(secrets.operationCount, 0)

        let initial = try manager.createInitialProfile(
            name: "Codex First",
            providerConfiguration: .codex(.init())
        )
        XCTAssertEqual(initial.providerConfiguration, .codex(.init()))
        XCTAssertEqual(manager.activeProfile?.id, initial.id)
        XCTAssertEqual(store.loadActiveProfileId(for: .codex), initial.id)
        XCTAssertThrowsError(
            try manager.createInitialProfile(
                providerConfiguration: .claude
            )
        )
    }

    @MainActor
    func testCreationUsesAuthoritativeCASAndDedicatedLinkedCodexPath() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let homeURL = root.appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createDirectory(
            at: homeURL,
            withIntermediateDirectories: true
        )
        let home = try CodexHomeCanonicalizer().canonicalize(homeURL.path)
        let defaults = ProviderTestDefaults()
        let store = retain(makeIsolatedProfileStore(
            defaults: defaults,
            secretStore: ProviderSecretStore(),
            usageFileStore: ProviderUsageStore()
        ))
        let manager = retain(ProfileManager(
            profileStore: store,
            activationClaudeEffects: .noOp
        ))

        XCTAssertThrowsError(
            try manager.createInitialProfile(
                providerConfiguration: .codex(
                    .init(linkedHome: home)
                )
            )
        )
        XCTAssertTrue(store.loadProfiles().isEmpty)

        let linked = try manager.createInitialCodexProfile(
            linkedHomePath: homeURL.path
        )
        XCTAssertEqual(linked.providerRevision, 0)
        XCTAssertEqual(
            linked.providerConfiguration.codexConfiguration?.linkedHome,
            home
        )

        let externallyAdded = Profile(name: "External")
        defaults.set(
            try JSONEncoder().encode([linked, externallyAdded]),
            forKey: "profiles_v3"
        )
        let staleInitialManager = retain(ProfileManager(
            profileStore: store,
            activationClaudeEffects: .noOp
        ))
        XCTAssertThrowsError(
            try staleInitialManager.createInitialProfile(
                providerConfiguration: .codex(.init())
            )
        )
        XCTAssertThrowsError(
            try manager.createProfileThrowing(
                name: "Stale Create",
                providerConfiguration: .codex(.init())
            )
        ) { error in
            XCTAssertEqual(
                error as? ProfileProviderConfigurationError,
                .profileSetChanged
            )
        }
        XCTAssertNil(manager.createProfile(name: "No Phantom"))
        XCTAssertEqual(manager.profiles.map(\.id), [linked.id])
        XCTAssertEqual(store.loadProfiles().count, 2)

        XCTAssertThrowsError(
            try store.saveProfilesThrowing([linked, linked])
        )
        let duplicateHome = Profile(
            name: "Duplicate Home",
            providerConfiguration: .codex(.init(linkedHome: home))
        )
        XCTAssertThrowsError(
            try store.saveProfilesThrowing([linked, duplicateHome])
        )
    }

    @MainActor
    func testCodexActivationRunsNoClaudeEffectsOrSecretOperations() async throws {
        let defaults = ProviderTestDefaults()
        let secrets = ProviderSecretStore()
        let store = retain(makeIsolatedProfileStore(
            defaults: defaults,
            secretStore: secrets,
            usageFileStore: ProviderUsageStore()
        ))
        let claude = Profile(
            name: "Claude",
            cliCredentialsJSON: "runtime-cli"
        )
        let codex = Profile(
            name: "Codex",
            providerConfiguration: .codex(.init())
        )
        try seedProfilesForTesting([claude, codex], in: store)
        let effects = ProviderEffectCounter()
        let timestamp = Date(timeIntervalSinceReferenceDate: 1234)
        let manager = retain(ProfileManager(
            profileStore: store,
            activationClaudeEffects: effects.effects,
            now: { timestamp }
        ))
        manager.profiles = [claude, codex]
        manager.activeProfile = claude
        secrets.reset()

        await manager.activateProfile(codex.id)

        XCTAssertEqual(effects.count, 0)
        XCTAssertEqual(secrets.operationCount, 0)
        XCTAssertEqual(manager.activeProfile?.id, codex.id)
        XCTAssertEqual(manager.activeProfile?.lastUsedAt, timestamp)
        XCTAssertEqual(manager.activeProfile?.providerRevision, 0)
        XCTAssertEqual(store.loadActiveProfileId(for: .codex), codex.id)
        XCTAssertEqual(manager.activeCodexProfile?.id, codex.id)
    }

    @MainActor
    func testCodexSetupDecisionNeverProbesClaudeCLI() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let linkedURL = root.appendingPathComponent(
            "linked",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: linkedURL,
            withIntermediateDirectories: true
        )
        let linkedHome = try CodexHomeCanonicalizer()
            .canonicalize(linkedURL.path)
        var probeCount = 0
        let linked = Profile(
            name: "Linked",
            providerConfiguration: .codex(
                .init(linkedHome: linkedHome)
            )
        )
        let unlinked = Profile(
            name: "Unlinked",
            providerConfiguration: .codex(.init())
        )

        XCTAssertFalse(SetupWizardDecision.shouldShow(
            hasShownWizardOnce: true,
            activeProfile: linked
        ) {
            probeCount += 1
            return true
        })
        XCTAssertFalse(SetupWizardDecision.shouldShow(
            hasShownWizardOnce: true,
            activeProfile: unlinked
        ) {
            probeCount += 1
            return true
        })
        XCTAssertFalse(SetupWizardDecision.shouldShow(
            hasShownWizardOnce: false,
            activeProfile: linked
        ) {
            probeCount += 1
            return true
        })
        XCTAssertFalse(SetupWizardDecision.shouldShow(
            hasShownWizardOnce: false,
            activeProfile: unlinked
        ) {
            probeCount += 1
            return true
        })
        XCTAssertEqual(probeCount, 0)

        // A credential-less Claude profile must not re-enter the wizard once
        // setup has been completed — it launches to the menu bar's
        // no-credential state instead. Before completion, the CLI probe
        // still decides.
        let credentialLessClaude = Profile(
            name: "Claude",
            providerConfiguration: .claude
        )
        XCTAssertFalse(SetupWizardDecision.shouldShow(
            hasShownWizardOnce: true,
            hasCompletedSetup: true,
            activeProfile: credentialLessClaude
        ) {
            probeCount += 1
            return false
        })
        XCTAssertEqual(probeCount, 0)
        XCTAssertTrue(SetupWizardDecision.shouldShow(
            hasShownWizardOnce: true,
            hasCompletedSetup: false,
            activeProfile: credentialLessClaude
        ) {
            probeCount += 1
            return false
        })
        XCTAssertEqual(probeCount, 1)

        XCTAssertFalse(
            SetupWizardDecision.canPresentLegacyWizard(
                activeProfile: linked
            )
        )
        XCTAssertFalse(
            SetupWizardDecision.canPresentLegacyWizard(
                activeProfile: unlinked
            )
        )
    }

    @MainActor
    func testLinkAndUnlinkIncrementRevisionAndClearUsageWithoutAuthAccess() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let homeURL = root.appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createDirectory(
            at: homeURL,
            withIntermediateDirectories: true
        )
        let authURL = homeURL.appendingPathComponent("auth.json")
        let authBytes = Data("unchanged-auth".utf8)
        try authBytes.write(to: authURL)
        let defaults = ProviderTestDefaults()
        let secrets = ProviderSecretStore()
        let usage = ProviderUsageStore()
        let store = retain(makeIsolatedProfileStore(
            defaults: defaults,
            secretStore: secrets,
            usageFileStore: usage
        ))
        let manager = retain(ProfileManager(
            profileStore: store,
            activationClaudeEffects: .noOp
        ))
        manager.loadProfiles()
        let profile = try manager.createInitialProfile(
            name: "Keep Me",
            providerConfiguration: .codex(.init())
        )
        usage.values[profile.id] = ProfileCurrentUsage(
            providerID: .codex,
            providerRevision: 0,
            report: try makeProviderReport(
                providerID: .codex,
                marker: 10
            )
        )

        let linked = try manager.linkCodexHome(
            homeURL.path,
            for: profile.id
        )
        XCTAssertEqual(linked.providerRevision, 1)
        XCTAssertEqual(
            linked.providerConfiguration.codexConfiguration?.linkedHome?.path,
            homeURL.path
        )
        XCTAssertNil(usage.values[profile.id])
        XCTAssertEqual(try Data(contentsOf: authURL), authBytes)

        usage.values[profile.id] = ProfileCurrentUsage(
            providerID: .codex,
            providerRevision: 1,
            report: try makeProviderReport(
                providerID: .codex,
                marker: 20
            )
        )
        let unlinked = try manager.unlinkCodexHome(for: profile.id)

        XCTAssertEqual(unlinked.id, profile.id)
        XCTAssertEqual(unlinked.name, "Keep Me")
        XCTAssertEqual(unlinked.providerRevision, 2)
        XCTAssertNil(
            unlinked.providerConfiguration.codexConfiguration?.linkedHome
        )
        XCTAssertNil(usage.values[profile.id])
        XCTAssertEqual(secrets.operationCount, 0)
        XCTAssertEqual(try Data(contentsOf: authURL), authBytes)
    }

    @MainActor
    func testIdenticalRelinkAndRepeatedUnlinkAreTrueNoOps() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let homeURL = root.appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createDirectory(
            at: homeURL,
            withIntermediateDirectories: true
        )
        let defaults = ProviderTestDefaults()
        let usage = ProviderUsageStore()
        let store = retain(makeIsolatedProfileStore(
            defaults: defaults,
            secretStore: ProviderSecretStore(),
            usageFileStore: usage
        ))
        let manager = retain(ProfileManager(
            profileStore: store,
            activationClaudeEffects: .noOp
        ))
        manager.loadProfiles()
        let profile = try manager.createInitialProfile(
            providerConfiguration: .codex(.init())
        )
        let sentinel = ProfileCurrentUsage(
            providerID: .codex,
            providerRevision: 0,
            report: try makeProviderReport(
                providerID: .codex,
                marker: 42
            )
        )
        usage.values[profile.id] = sentinel
        var eventCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .providerConfigurationChanged,
            object: nil,
            queue: nil
        ) { _ in
            eventCount += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let repeatedInitialUnlink = try manager.unlinkCodexHome(
            for: profile.id
        )
        XCTAssertEqual(repeatedInitialUnlink.providerRevision, 0)
        XCTAssertEqual(usage.values[profile.id], sentinel)
        XCTAssertEqual(eventCount, 0)

        let linked = try manager.linkCodexHome(
            homeURL.path,
            for: profile.id
        )
        XCTAssertEqual(linked.providerRevision, 1)
        XCTAssertEqual(eventCount, 1)
        let linkedSentinel = ProfileCurrentUsage(
            providerID: .codex,
            providerRevision: 1,
            report: try makeProviderReport(
                providerID: .codex,
                marker: 43
            )
        )
        usage.values[profile.id] = linkedSentinel

        let identicalRelink = try manager.linkCodexHome(
            homeURL.path,
            for: profile.id
        )
        XCTAssertEqual(identicalRelink.providerRevision, 1)
        XCTAssertEqual(usage.values[profile.id], linkedSentinel)
        XCTAssertEqual(eventCount, 1)

        let unlinked = try manager.unlinkCodexHome(for: profile.id)
        XCTAssertEqual(unlinked.providerRevision, 2)
        XCTAssertEqual(eventCount, 2)
        let unlinkedSentinel = ProfileCurrentUsage(
            providerID: .codex,
            providerRevision: 2,
            report: try makeProviderReport(
                providerID: .codex,
                marker: 44
            )
        )
        usage.values[profile.id] = unlinkedSentinel

        let repeatedUnlink = try manager.unlinkCodexHome(for: profile.id)
        XCTAssertEqual(repeatedUnlink.providerRevision, 2)
        XCTAssertEqual(usage.values[profile.id], unlinkedSentinel)
        XCTAssertEqual(eventCount, 2)
    }

    @MainActor
    func testExactPathRelinkUpgradesLegacyUnresolvedHome() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let homeURL = root.appendingPathComponent(
            "legacy-home",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: homeURL,
            withIntermediateDirectories: true
        )
        let legacyHome = try JSONDecoder().decode(
            CanonicalCodexHome.self,
            from: JSONSerialization.data(
                withJSONObject: ["path": homeURL.path]
            )
        )
        XCTAssertNil(legacyHome.filesystemIdentity)

        let store = retain(makeIsolatedProfileStore(
            defaults: ProviderTestDefaults(),
            secretStore: ProviderSecretStore(),
            usageFileStore: ProviderUsageStore()
        ))
        let profile = Profile(
            name: "Legacy Codex",
            providerConfiguration: .codex(
                .init(linkedHome: legacyHome)
            )
        )
        try seedProfilesForTesting([profile], in: store)
        let manager = retain(ProfileManager(
            profileStore: store,
            activationClaudeEffects: .noOp
        ))
        manager.loadProfiles()

        let relinked = try manager.linkCodexHome(
            homeURL.path,
            for: profile.id
        )

        XCTAssertEqual(relinked.providerRevision, 1)
        XCTAssertEqual(
            relinked.providerConfiguration.codexConfiguration?
                .linkedHome?.path,
            homeURL.path
        )
        XCTAssertNotNil(
            relinked.providerConfiguration.codexConfiguration?
                .linkedHome?.filesystemIdentity
        )
    }

    @MainActor
    func testExactPathRelinkCapturesReplacementDirectoryIdentity() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let homeURL = root.appendingPathComponent(
            "codex-home",
            isDirectory: true
        )
        let replacementURL = root.appendingPathComponent(
            "replacement",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: homeURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: replacementURL,
            withIntermediateDirectories: true
        )
        let originalHome = try CodexHomeCanonicalizer()
            .canonicalize(homeURL.path)
        let replacementIdentity = try XCTUnwrap(
            CodexHomeFilesystemIdentity.read(from: replacementURL)
        )
        XCTAssertNotEqual(
            originalHome.filesystemIdentity,
            replacementIdentity
        )

        let store = retain(makeIsolatedProfileStore(
            defaults: ProviderTestDefaults(),
            secretStore: ProviderSecretStore(),
            usageFileStore: ProviderUsageStore()
        ))
        let profile = Profile(
            name: "Replaced Codex",
            providerConfiguration: .codex(
                .init(linkedHome: originalHome)
            )
        )
        try seedProfilesForTesting([profile], in: store)
        let manager = retain(ProfileManager(
            profileStore: store,
            activationClaudeEffects: .noOp
        ))
        manager.loadProfiles()

        try FileManager.default.removeItem(at: homeURL)
        try FileManager.default.moveItem(
            at: replacementURL,
            to: homeURL
        )
        let relinked = try manager.linkCodexHome(
            homeURL.path,
            for: profile.id
        )

        XCTAssertEqual(relinked.providerRevision, 1)
        XCTAssertEqual(
            relinked.providerConfiguration.codexConfiguration?
                .linkedHome?.filesystemIdentity,
            replacementIdentity
        )
        XCTAssertNotEqual(
            relinked.providerConfiguration.codexConfiguration?
                .linkedHome?.filesystemIdentity,
            originalHome.filesystemIdentity
        )
    }

    @MainActor
    func testCodexMutationFailureRollsBackMetadataUsageAndRevision() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let homeURL = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(
            at: homeURL,
            withIntermediateDirectories: true
        )
        let home = try CodexHomeCanonicalizer().canonicalize(homeURL.path)
        let defaults = FaultingProfileDefaults()
        let secrets = ProviderSecretStore()
        let usage = ProviderUsageStore()
        let store = retain(makeIsolatedProfileStore(
            defaults: defaults,
            secretStore: secrets,
            usageFileStore: usage
        ))
        let profile = Profile(
            name: "Rollback",
            providerConfiguration: .codex(.init(linkedHome: home))
        )
        try seedProfilesForTesting([profile], in: store)
        let previousUsage = ProfileCurrentUsage(
            providerID: .codex,
            providerRevision: profile.providerRevision,
            report: try makeProviderReport(
                providerID: .codex,
                marker: 55
            )
        )
        usage.values[profile.id] = previousUsage
        XCTAssertNil(previousUsage.claudeUsage)
        XCTAssertNil(previousUsage.apiUsage)
        defaults.corruptNextProfileWrite = true

        XCTAssertThrowsError(
            try store.replaceCodexLinkedHome(nil, for: profile.id)
        ) { error in
            XCTAssertEqual(
                error as? ProfileProviderConfigurationError,
                .codexConfigurationMutationFailed(profile.id)
            )
        }
        XCTAssertEqual(store.loadProfiles().first, profile)
        XCTAssertEqual(usage.values[profile.id], previousUsage)
        XCTAssertEqual(secrets.operationCount, 0)
        XCTAssertNil(
            defaults.data(
                forKey: "profileCodexConfigurationMutations_v1"
            )
        )
    }

    @MainActor
    func testUnresolvedUsageRollbackKeepsMarkerAndRelaunchCompletesForward()
        throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let homeURL = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(
            at: homeURL,
            withIntermediateDirectories: true
        )
        let home = try CodexHomeCanonicalizer().canonicalize(homeURL.path)
        let defaults = FaultingProfileDefaults()
        let usage = ProviderUsageStore()
        let store = retain(makeIsolatedProfileStore(
            defaults: defaults,
            secretStore: ProviderSecretStore(),
            usageFileStore: usage
        ))
        let profile = Profile(
            name: "Recover",
            providerConfiguration: .codex(.init(linkedHome: home)),
            providerRevision: 4
        )
        try seedProfilesForTesting([profile], in: store)
        usage.values[profile.id] = ProfileCurrentUsage(
            providerID: .codex,
            providerRevision: profile.providerRevision,
            report: try makeProviderReport(
                providerID: .codex,
                marker: 77
            )
        )
        defaults.corruptNextProfileWrite = true
        usage.saveError = ProviderTestError.expected

        XCTAssertThrowsError(
            try store.replaceCodexLinkedHome(nil, for: profile.id)
        ) { error in
            XCTAssertEqual(
                error as? ProfileProviderConfigurationError,
                .codexConfigurationRollbackFailed(
                    profile.id,
                    metadata: false,
                    usage: true
                )
            )
        }
        let restored = try JSONDecoder().decode(
            [Profile].self,
            from: XCTUnwrap(defaults.data(forKey: "profiles_v3"))
        )
        XCTAssertEqual(restored.first, profile)
        XCTAssertNotNil(
            defaults.data(
                forKey: "profileCodexConfigurationMutations_v1"
            )
        )

        usage.saveError = nil
        let relaunched = retain(makeIsolatedProfileStore(
            defaults: defaults,
            secretStore: ProviderSecretStore(),
            usageFileStore: usage
        ))
        let recovered = try XCTUnwrap(
            relaunched.loadProfilesWithVerifiedMigration().first
        )

        XCTAssertEqual(recovered.providerRevision, 5)
        XCTAssertNil(
            recovered.providerConfiguration.codexConfiguration?.linkedHome
        )
        XCTAssertNil(usage.values[profile.id])
        XCTAssertNil(
            defaults.data(
                forKey: "profileCodexConfigurationMutations_v1"
            )
        )
    }

    @MainActor
    func testFailedRecoveryLoadProjectsDurableCodexTargetFailClosed()
        throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let homeURL = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(
            at: homeURL,
            withIntermediateDirectories: true
        )
        let home = try CodexHomeCanonicalizer().canonicalize(homeURL.path)
        let defaults = ProviderTestDefaults()
        let usage = ProviderUsageStore()
        let store = retain(makeIsolatedProfileStore(
            defaults: defaults,
            secretStore: ProviderSecretStore(),
            usageFileStore: usage
        ))
        let profile = Profile(
            name: "Pending",
            providerConfiguration: .codex(.init(linkedHome: home)),
            providerRevision: 7
        )
        try seedProfilesForTesting([profile], in: store)
        usage.values[profile.id] = ProfileCurrentUsage(
            providerID: .codex,
            providerRevision: profile.providerRevision,
            report: try makeProviderReport(
                providerID: .codex,
                marker: 99
            )
        )
        usage.deleteError = ProviderTestError.expected
        usage.saveError = ProviderTestError.expected
        XCTAssertThrowsError(
            try store.replaceCodexLinkedHome(nil, for: profile.id)
        )

        let projected = try XCTUnwrap(store.loadProfiles().first)

        XCTAssertEqual(projected.providerRevision, 8)
        XCTAssertNil(
            projected.providerConfiguration.codexConfiguration?.linkedHome
        )
        XCTAssertNil(projected.claudeUsage)
        XCTAssertNil(projected.apiUsage)
        XCTAssertNil(projected.currentUsageMigrationRetry)
        XCTAssertNotNil(
            defaults.data(
                forKey: "profileCodexConfigurationMutations_v1"
            )
        )
    }

    @MainActor
    func testOfflineExactRelinkStillVerifiesPendingRecovery() throws {
        let root = try makeTemporaryDirectory()
        let homeURL = root.appendingPathComponent(
            "pending-home",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: homeURL,
            withIntermediateDirectories: true
        )
        let home = try CodexHomeCanonicalizer()
            .canonicalize(homeURL.path)
        let defaults = FaultingProfileDefaults()
        let usage = ProviderUsageStore()
        let store = retain(makeIsolatedProfileStore(
            defaults: defaults,
            secretStore: ProviderSecretStore(),
            usageFileStore: usage
        ))
        let profile = Profile(
            name: "Pending Link",
            providerConfiguration: .codex(.init()),
            providerRevision: 7
        )
        try seedProfilesForTesting([profile], in: store)
        usage.values[profile.id] = ProfileCurrentUsage(
            providerID: .codex,
            providerRevision: profile.providerRevision
        )
        defaults.corruptNextProfileWrite = true
        usage.saveError = ProviderTestError.expected
        XCTAssertThrowsError(
            try store.replaceCodexLinkedHome(home, for: profile.id)
        )

        usage.saveError = nil
        usage.deleteError = ProviderTestError.expected
        let manager = retain(ProfileManager(
            profileStore: store,
            activationClaudeEffects: .noOp
        ))
        manager.loadProfiles()
        XCTAssertEqual(
            manager.profiles.first?.providerConfiguration
                .codexConfiguration?.linkedHome,
            home
        )
        try FileManager.default.removeItem(at: root)

        XCTAssertThrowsError(
            try manager.linkCodexHome(home.path, for: profile.id)
        )
        XCTAssertNotNil(
            defaults.data(
                forKey: "profileCodexConfigurationMutations_v1"
            )
        )

        usage.deleteError = nil
        let recovered = try manager.linkCodexHome(
            home.path,
            for: profile.id
        )
        XCTAssertEqual(recovered.providerRevision, 8)
        XCTAssertEqual(
            recovered.providerConfiguration.codexConfiguration?
                .linkedHome,
            home
        )
        XCTAssertNil(
            defaults.data(
                forKey: "profileCodexConfigurationMutations_v1"
            )
        )
    }

    @MainActor
    func testProviderRevisionOverflowFailsWithoutMutation() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let homeURL = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(
            at: homeURL,
            withIntermediateDirectories: true
        )
        let home = try CodexHomeCanonicalizer().canonicalize(homeURL.path)
        let defaults = ProviderTestDefaults()
        let usage = ProviderUsageStore()
        let store = retain(makeIsolatedProfileStore(
            defaults: defaults,
            secretStore: ProviderSecretStore(),
            usageFileStore: usage
        ))
        let profile = Profile(
            name: "Max",
            providerConfiguration: .codex(.init(linkedHome: home)),
            providerRevision: UInt64.max
        )
        try seedProfilesForTesting([profile], in: store)

        XCTAssertThrowsError(
            try store.replaceCodexLinkedHome(nil, for: profile.id)
        ) { error in
            XCTAssertEqual(
                error as? ProfileProviderConfigurationError,
                .providerRevisionExhausted(profile.id)
            )
        }
        XCTAssertEqual(store.loadProfiles().first, profile)
        XCTAssertEqual(usage.deleteCurrentCount, 0)
    }

    @MainActor
    func testDeletionLifecycleStartsSynchronouslyAndCompletesOnlyAfterRetry()
        throws {
        let defaults = ProviderTestDefaults()
        let store = retain(makeIsolatedProfileStore(
            defaults: defaults,
            secretStore: ProviderSecretStore(),
            usageFileStore: ProviderUsageStore()
        ))
        let target = Profile(
            name: "Delete",
            providerConfiguration: .codex(.init()),
            providerRevision: 9
        )
        let survivor = Profile(
            name: "Keep",
            providerConfiguration: .codex(.init())
        )
        try seedProfilesForTesting([target, survivor], in: store)
        let history = retain(ProviderHistoryDeleter())
        history.failuresRemaining = 1
        let lifecycle = ProviderLifecycleRecorder()
        let manager = retain(ProfileManager(
            profileStore: store,
            historyService: history,
            activationClaudeEffects: .noOp,
            lifecycleEventSink: lifecycle.sink
        ))
        manager.profiles = [target, survivor]
        manager.activeProfile = survivor

        XCTAssertThrowsError(try manager.deleteProfile(target.id))
        XCTAssertEqual(lifecycle.started.count, 1)
        XCTAssertTrue(lifecycle.cleaned.isEmpty)
        XCTAssertTrue(lifecycle.completed.isEmpty)
        XCTAssertEqual(lifecycle.started.first?.id, target.id)
        XCTAssertEqual(
            lifecycle.started.first?.providerConfiguration.kind,
            .codex
        )
        XCTAssertEqual(lifecycle.started.first?.providerRevision, 9)

        try manager.deleteProfile(target.id)

        XCTAssertEqual(lifecycle.started.count, 2)
        XCTAssertEqual(lifecycle.cleaned.map(\.id), [target.id])
        XCTAssertEqual(lifecycle.completed.map(\.id), [target.id])
        XCTAssertEqual(lifecycle.completed.first?.providerRevision, 9)
        XCTAssertFalse(manager.profiles.contains(where: {
            $0.id == target.id
        }))
    }

    @MainActor
    func testDeletionCleanupMustSucceedBeforeDurableFinalization()
        throws
    {
        let defaults = ProviderTestDefaults()
        let store = retain(makeIsolatedProfileStore(
            defaults: defaults,
            secretStore: ProviderSecretStore(),
            usageFileStore: ProviderUsageStore()
        ))
        let target = Profile(
            name: "Delete",
            providerConfiguration: .codex(.init())
        )
        let survivor = Profile(
            name: "Keep",
            providerConfiguration: .codex(.init())
        )
        try seedProfilesForTesting([target, survivor], in: store)
        let lifecycle = ProviderLifecycleRecorder()
        lifecycle.cleanupFailuresRemaining = 1
        let manager = retain(ProfileManager(
            profileStore: store,
            historyService: retain(ProviderHistoryDeleter()),
            activationClaudeEffects: .noOp,
            lifecycleEventSink: lifecycle.sink
        ))
        manager.profiles = [target, survivor]
        manager.activeProfile = survivor

        XCTAssertThrowsError(try manager.deleteProfile(target.id))
        XCTAssertEqual(lifecycle.cleaned.map(\.id), [target.id])
        XCTAssertTrue(lifecycle.completed.isEmpty)
        XCTAssertTrue(store.loadProfiles().contains(where: {
            $0.id == target.id && $0.deletionInProgress
        }))

        try manager.deleteProfile(target.id)

        XCTAssertEqual(
            lifecycle.cleaned.map(\.id),
            [target.id, target.id]
        )
        XCTAssertEqual(lifecycle.completed.map(\.id), [target.id])
        XCTAssertEqual(store.loadProfiles().map(\.id), [survivor.id])
    }

    @MainActor
    func testDeletionResolvesPendingProviderMutationBeforeCleanup()
        throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let homeURL = root.appendingPathComponent(
            "linked",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: homeURL,
            withIntermediateDirectories: true
        )
        let home = try CodexHomeCanonicalizer()
            .canonicalize(homeURL.path)
        let defaults = FaultingProfileDefaults()
        let usage = ProviderUsageStore()
        let store = retain(makeIsolatedProfileStore(
            defaults: defaults,
            secretStore: ProviderSecretStore(),
            usageFileStore: usage
        ))
        let target = Profile(
            name: "Pending Delete",
            providerConfiguration: .codex(.init(linkedHome: home)),
            providerRevision: 4
        )
        let survivor = Profile(
            name: "Survivor",
            providerConfiguration: .codex(.init())
        )
        try seedProfilesForTesting([target, survivor], in: store)
        usage.values[target.id] = ProfileCurrentUsage(
            providerID: .codex,
            providerRevision: target.providerRevision
        )
        defaults.corruptNextProfileWrite = true
        usage.saveError = ProviderTestError.expected
        XCTAssertThrowsError(
            try store.replaceCodexLinkedHome(nil, for: target.id)
        )
        XCTAssertNotNil(
            defaults.data(
                forKey: "profileCodexConfigurationMutations_v1"
            )
        )

        usage.saveError = nil
        let manager = retain(ProfileManager(
            profileStore: store,
            historyService: retain(ProviderHistoryDeleter()),
            activationClaudeEffects: .noOp
        ))
        manager.profiles = [target, survivor]
        manager.activeProfile = survivor

        try manager.deleteProfile(target.id)

        XCTAssertNil(
            defaults.data(
                forKey: "profileCodexConfigurationMutations_v1"
            )
        )
        XCTAssertEqual(store.loadProfiles().map(\.id), [survivor.id])
        XCTAssertNil(usage.values[target.id])
        XCTAssertEqual(usage.deleteAllCount, 1)
    }

    @MainActor
    func testCleanupFailureLeavesUsableSurvivorActive() throws {
        let defaults = ProviderTestDefaults()
        let store = retain(makeIsolatedProfileStore(
            defaults: defaults,
            secretStore: ProviderSecretStore(),
            usageFileStore: ProviderUsageStore()
        ))
        let target = Profile(
            name: "Delete Active",
            providerConfiguration: .codex(.init())
        )
        let survivor = Profile(
            name: "Claude Survivor",
            claudeSessionKey: "claude-session",
            organizationId: "org",
            cliCredentialsJSON: "cli-json",
            cliAccountName: "account"
        )
        try seedProfilesForTesting([target, survivor], in: store)
        store.saveActiveProfileId(target.id, for: .codex)
        let history = retain(ProviderHistoryDeleter())
        history.failuresRemaining = 1
        let lifecycle = ProviderLifecycleRecorder()
        let effects = ProviderEffectCounter()
        let manager = retain(ProfileManager(
            profileStore: store,
            historyService: history,
            activationClaudeEffects: effects.effects,
            lifecycleEventSink: lifecycle.sink
        ))
        manager.loadProfiles()
        effects.reset()

        XCTAssertThrowsError(try manager.deleteProfile(target.id))

        // No Codex profile survives, so the deleted profile's own provider
        // slot clears; focus falls back to the remaining Claude profile,
        // which was already independently active — no Claude CLI side
        // effects fire for it.
        XCTAssertNil(manager.activeCodexProfile)
        XCTAssertEqual(manager.activeProfile?.id, survivor.id)
        XCTAssertEqual(effects.count, 0)
        XCTAssertEqual(lifecycle.started.map(\.id), [target.id])
        XCTAssertTrue(lifecycle.completed.isEmpty)
        XCTAssertTrue(manager.profiles.contains(where: {
            $0.id == target.id && $0.deletionInProgress
        }))
    }

    @MainActor
    func testRelaunchDoesNotSelectRetainedDeletionMarker() async throws {
        let defaults = ProviderTestDefaults()
        let store = retain(makeIsolatedProfileStore(
            defaults: defaults,
            secretStore: ProviderSecretStore(),
            usageFileStore: ProviderUsageStore()
        ))
        let target = Profile(
            name: "Incomplete Delete",
            providerConfiguration: .codex(.init())
        )
        let survivor = Profile(
            name: "Survivor",
            providerConfiguration: .codex(.init())
        )
        try seedProfilesForTesting([target, survivor], in: store)
        store.saveActiveProfileId(target.id, for: .codex)
        _ = try store.beginProfileDeletion(target.id)
        let manager = retain(ProfileManager(
            profileStore: store,
            activationClaudeEffects: .noOp
        ))

        manager.loadProfiles()

        XCTAssertEqual(manager.activeProfile?.id, survivor.id)
        XCTAssertEqual(store.loadActiveProfileId(for: .codex), survivor.id)
        XCTAssertTrue(manager.profiles.contains(where: {
            $0.id == target.id && $0.deletionInProgress
        }))
        await manager.activateProfile(target.id)
        XCTAssertEqual(manager.activeProfile?.id, survivor.id)
    }

    @MainActor
    func testDeletionCompletionObservesSurvivorAsActive() throws {
        let defaults = ProviderTestDefaults()
        let store = retain(makeIsolatedProfileStore(
            defaults: defaults,
            secretStore: ProviderSecretStore(),
            usageFileStore: ProviderUsageStore()
        ))
        let target = Profile(
            name: "Active Delete",
            providerConfiguration: .codex(.init())
        )
        let survivor = Profile(
            name: "Survivor",
            providerConfiguration: .codex(.init())
        )
        try seedProfilesForTesting([target, survivor], in: store)
        store.saveActiveProfileId(target.id, for: .codex)
        var activeAtCompletion: UUID?
        let effects = ProviderEffectCounter()
        var manager: ProfileManager!
        manager = retain(ProfileManager(
            profileStore: store,
            historyService: retain(ProviderHistoryDeleter()),
            activationClaudeEffects: effects.effects,
            lifecycleEventSink: ProfileLifecycleEventSink(
                deletionStarted: { _ in },
                deletionCompleted: { _ in
                    activeAtCompletion = manager.activeProfile?.id
                }
            )
        ))
        manager.loadProfiles()

        try manager.deleteProfile(target.id)

        XCTAssertEqual(activeAtCompletion, survivor.id)
        XCTAssertEqual(manager.activeProfile?.id, survivor.id)
        XCTAssertEqual(store.loadActiveProfileId(for: .codex), survivor.id)
        XCTAssertEqual(effects.count, 0)
    }

    @MainActor
    func testDeletingActiveProfileAppliesClaudeSurvivorEffects() throws {
        let defaults = ProviderTestDefaults()
        let secrets = ProviderSecretStore()
        let store = retain(makeIsolatedProfileStore(
            defaults: defaults,
            secretStore: secrets,
            usageFileStore: ProviderUsageStore()
        ))
        let target = Profile(
            name: "Delete Codex",
            providerConfiguration: .codex(.init())
        )
        let survivor = Profile(
            name: "Claude Survivor",
            claudeSessionKey: "claude-session",
            organizationId: "org",
            cliCredentialsJSON: "cli-json",
            cliAccountName: "account"
        )
        try seedProfilesForTesting([target, survivor], in: store)
        store.saveActiveProfileId(target.id, for: .codex)
        let effects = ProviderEffectCounter()
        let manager = retain(ProfileManager(
            profileStore: store,
            historyService: retain(ProviderHistoryDeleter()),
            activationClaudeEffects: effects.effects
        ))
        manager.loadProfiles()
        effects.reset()

        try manager.deleteProfile(target.id)

        // No Codex profile survives, so focus falls back to the Claude
        // profile that was already independently active for its own
        // provider. It was never "reactivated" — no Claude CLI side effects
        // fire for a profile the deletion of an unrelated Codex profile
        // never touched.
        XCTAssertNil(manager.activeCodexProfile)
        XCTAssertEqual(manager.activeProfile?.id, survivor.id)
        XCTAssertEqual(effects.count, 0)
    }

    /// `testDeletingActiveProfileAppliesClaudeSurvivorEffects` above never
    /// actually exercises `deleteProfile`'s cross-provider `wasFocused`
    /// fallback (Tessie finding): the lone Claude profile there is
    /// auto-active by `resolveActiveProfileID`'s single-candidate fallback,
    /// so `activeProfile` is already the Claude survivor before deletion,
    /// making `wasFocused` false from the start. This test seeds explicit
    /// focus (via `lastFocusedProfileId`) onto the Codex profile being
    /// deleted, verifies that precondition, then confirms the cross-provider
    /// fallback in `deleteProfile` genuinely moves focus to the other
    /// provider's active profile when no same-provider survivor exists —
    /// and that CODEX_HOME is cleared in that no-survivor case.
    @MainActor
    func testDeletingFocusedActiveCodexProfileFallsBackToOtherProviderFocus()
        throws
    {
        let defaults = ProviderTestDefaults()
        let store = retain(makeIsolatedProfileStore(
            defaults: defaults,
            secretStore: ProviderSecretStore(),
            usageFileStore: ProviderUsageStore()
        ))
        let target = Profile(
            name: "Delete Codex",
            providerConfiguration: .codex(.init())
        )
        let claudeSurvivor = Profile(
            name: "Claude Survivor",
            claudeSessionKey: "claude-session",
            organizationId: "org",
            cliCredentialsJSON: "cli-json",
            cliAccountName: "account"
        )
        try seedProfilesForTesting([target, claudeSurvivor], in: store)
        store.saveActiveProfileId(target.id, for: .codex)
        store.saveActiveProfileId(claudeSurvivor.id, for: .claude)
        store.saveLastFocusedProfileId(target.id)
        let codexEffects = ProviderCodexEffectCounter()
        let manager = retain(ProfileManager(
            profileStore: store,
            historyService: retain(ProviderHistoryDeleter()),
            activationClaudeEffects: .noOp,
            activationCodexEffects: codexEffects.effects
        ))
        manager.loadProfiles()

        XCTAssertEqual(
            manager.activeProfile?.id, target.id,
            "Precondition: focus must genuinely start on the profile being deleted."
        )

        try manager.deleteProfile(target.id)

        XCTAssertNil(manager.activeCodexProfile)
        XCTAssertEqual(manager.activeProfile?.id, claudeSurvivor.id)
        XCTAssertEqual(codexEffects.clearCount, 1)
    }

    @MainActor
    func testTombstoneDoesNotCountAsUsableLastProfile() throws {
        let defaults = ProviderTestDefaults()
        let store = retain(makeIsolatedProfileStore(
            defaults: defaults,
            secretStore: ProviderSecretStore(),
            usageFileStore: ProviderUsageStore()
        ))
        let tombstone = Profile(
            name: "Tombstone",
            providerConfiguration: .codex(.init())
        )
        let usable = Profile(
            name: "Usable",
            providerConfiguration: .codex(.init())
        )
        try seedProfilesForTesting([tombstone, usable], in: store)
        let retained = try store.beginProfileDeletion(tombstone.id)
        let manager = retain(ProfileManager(
            profileStore: store,
            historyService: retain(ProviderHistoryDeleter()),
            activationClaudeEffects: .noOp
        ))
        manager.profiles = [retained, usable]
        manager.activeProfile = usable

        XCTAssertThrowsError(try manager.deleteProfile(usable.id)) {
            error in
            XCTAssertEqual(
                error as? ProfileError,
                .cannotDeleteLastProfile
            )
        }
        try manager.deleteProfile(tombstone.id)
        XCTAssertEqual(manager.profiles.map(\.id), [usable.id])
    }

    @MainActor
    func testTombstoneRejectsProviderActivationCredentialsAndUsage()
        async throws {
        let defaults = ProviderTestDefaults()
        let usage = ProviderUsageStore()
        let store = retain(makeIsolatedProfileStore(
            defaults: defaults,
            secretStore: ProviderSecretStore(),
            usageFileStore: usage
        ))
        let codex = Profile(
            name: "Codex Tombstone",
            providerConfiguration: .codex(.init())
        )
        let claude = Profile(name: "Claude Tombstone")
        let survivor = Profile(
            name: "Survivor",
            providerConfiguration: .codex(.init())
        )
        try seedProfilesForTesting(
            [codex, claude, survivor],
            in: store
        )
        let codexTombstone = try store.beginProfileDeletion(codex.id)
        let claudeTombstone = try store.beginProfileDeletion(claude.id)

        XCTAssertThrowsError(
            try store.replaceCodexLinkedHome(nil, for: codex.id)
        )
        XCTAssertThrowsError(
            try store.updateActivationMetadata(for: codex.id, at: Date())
        )
        XCTAssertThrowsError(try store.loadProfileCredentials(claude.id))
        XCTAssertThrowsError(
            try store.saveAPIUsage(
                APIUsage(
                    currentSpendCents: 1,
                    resetsAt: Date(),
                    prepaidCreditsCents: 1,
                    currency: "USD",
                    apiTokenCostCents: nil,
                    apiCostByModel: nil,
                    costBySource: nil,
                    dailyCostCents: nil
                ),
                for: claude.id
            )
        )
        XCTAssertEqual(usage.values.count, 0)

        let manager = retain(ProfileManager(
            profileStore: store,
            activationClaudeEffects: .noOp
        ))
        manager.profiles = [codexTombstone, claudeTombstone, survivor]
        manager.activeProfile = survivor
        await manager.activateProfile(codex.id)
        XCTAssertEqual(manager.activeProfile?.id, survivor.id)
    }

    @MainActor
    func testDeletionStateCannotBypassLifecycleAPIs() throws {
        let defaults = ProviderTestDefaults()
        let secrets = ProviderSecretStore()
        let store = retain(makeIsolatedProfileStore(
            defaults: defaults,
            secretStore: secrets,
            usageFileStore: ProviderUsageStore()
        ))
        let profile = Profile(
            name: "Claude",
            claudeSessionKey: "old-secret",
            cliCredentialsJSON: "old-cli"
        )
        try seedProfilesForTesting([profile], in: store)
        var tombstoneCandidate = profile
        tombstoneCandidate.deletionInProgress = true

        XCTAssertThrowsError(
            try store.saveProfilesThrowing([tombstoneCandidate])
        ) { error in
            XCTAssertEqual(
                error as? ProfileProviderConfigurationError,
                .deletionStateChangeRequiresLifecycle(profile.id)
            )
        }

        tombstoneCandidate.claudeSessionKey = "new-secret"
        secrets.reset()
        XCTAssertThrowsError(
            try store.saveProfileUpdate(tombstoneCandidate)
        )
        XCTAssertEqual(secrets.writeCount, 0)
        XCTAssertEqual(secrets.deleteCount, 0)

        tombstoneCandidate.claudeSessionKey = profile.claudeSessionKey
        tombstoneCandidate.cliCredentialsJSON = "new-cli"
        secrets.reset()
        XCTAssertThrowsError(
            try store.saveCLIProfileUpdate(tombstoneCandidate)
        )
        XCTAssertEqual(secrets.writeCount, 0)
        XCTAssertEqual(secrets.deleteCount, 0)
        XCTAssertFalse(try XCTUnwrap(store.loadProfiles().first)
            .deletionInProgress)
    }

    @MainActor
    func testCodexProfileCannotDeleteClaudeSecrets() throws {
        let defaults = ProviderTestDefaults()
        let secrets = ProviderSecretStore()
        let store = retain(makeIsolatedProfileStore(
            defaults: defaults,
            secretStore: secrets,
            usageFileStore: ProviderUsageStore()
        ))
        let codex = Profile(
            name: "Codex",
            providerConfiguration: .codex(.init())
        )
        try seedProfilesForTesting([codex], in: store)
        secrets.reset()

        XCTAssertThrowsError(
            try store.deleteProfileSecrets(for: codex.id)
        ) { error in
            XCTAssertEqual(
                error as? ProfileProviderConfigurationError,
                .claudeProfileRequired(codex.id)
            )
        }
        XCTAssertEqual(secrets.operationCount, 0)
    }

    @MainActor
    func testCorruptRecoveryMarkersCannotCrossProviderBoundaries()
        throws {
        let defaults = ProviderTestDefaults()
        let secrets = ProviderSecretStore()
        let store = retain(makeIsolatedProfileStore(
            defaults: defaults,
            secretStore: secrets,
            usageFileStore: ProviderUsageStore()
        ))
        let codex = Profile(
            name: "Codex",
            providerConfiguration: .codex(.init()),
            providerRevision: 3
        )
        try seedProfilesForTesting([codex], in: store)
        let invalidCodexMarker = Data(
            """
            [{"profileID":"\(codex.id.uuidString)",\
            "linkedHome":null,"targetRevision":99}]
            """.utf8
        )
        defaults.set(
            invalidCodexMarker,
            forKey: "profileCodexConfigurationMutations_v1"
        )

        XCTAssertThrowsError(
            try store.loadProfilesWithVerifiedMigration()
        ) { error in
            XCTAssertEqual(
                error as? ProfileProviderConfigurationError,
                .codexConfigurationMarkerVerificationFailed
            )
        }
        XCTAssertTrue(store.loadProfiles().isEmpty)
        XCTAssertEqual(
            defaults.data(
                forKey: "profileCodexConfigurationMutations_v1"
            ),
            invalidCodexMarker
        )

        defaults.removeObject(
            forKey: "profileCodexConfigurationMutations_v1"
        )
        let invalidCredentialMarker = Data(
            """
            [{"profileID":"\(codex.id.uuidString)",\
            "component":"claude"}]
            """.utf8
        )
        defaults.set(
            invalidCredentialMarker,
            forKey: "profileCredentialUsageUnlinks_v1"
        )
        secrets.reset()

        XCTAssertThrowsError(
            try store.loadProfilesWithVerifiedMigration()
        ) { error in
            XCTAssertEqual(
                error as? ProfileProviderConfigurationError,
                .claudeProfileRequired(codex.id)
            )
        }
        XCTAssertTrue(store.loadProfiles().isEmpty)
        XCTAssertEqual(secrets.operationCount, 0)
        XCTAssertEqual(
            defaults.data(
                forKey: "profileCredentialUsageUnlinks_v1"
            ),
            invalidCredentialMarker
        )
    }

    @MainActor
    func testTombstonedClaudeCannotConsumeLegacyMigration() throws {
        let (defaults, suite) = try HostedTestDefaults.defaults(
            "ProfileProviderCoreTests"
        )
        defer { HostedTestDefaults.finish(defaults, suiteName: suite) }
        HostedTestDefaults.reset(defaults, suiteName: suite)
        let secrets = ProviderSecretStore()
        let store = retain(makeIsolatedProfileStore(
            defaults: defaults,
            secretStore: secrets,
            usageFileStore: ProviderUsageStore()
        ))
        let oldClaude = Profile(name: "Deleting Claude")
        let codex = Profile(
            name: "Codex",
            providerConfiguration: .codex(.init())
        )
        try seedProfilesForTesting([oldClaude, codex], in: store)
        _ = try store.beginProfileDeletion(oldClaude.id)
        // Simulate a pre-upgrade single-slot install: the legacy key, not
        // either per-provider key, is what `ProfileMigrationService` reads.
        defaults.set(oldClaude.id.uuidString, forKey: "activeProfileId")
        let source = ProviderLegacySource(
            snapshot: .init(
                globalClaudeSessionKey: "new-owner-secret",
                fileClaudeSessionKey: nil,
                globalAPISessionKey: nil,
                defaultsAPISessionKey: nil
            )
        )
        let migration = retain(ProfileMigrationService(
            defaults: defaults,
            profileStore: store,
            credentialMigration: retain(KeychainMigrationService(
                source: source,
                defaults: defaults
            )),
            legacySettings: ProviderLegacySettings()
        ))

        try migration.migrateIfNeededThrowing()
        XCTAssertEqual(source.readCount, 0)
        XCTAssertThrowsError(
            try store.loadProfileCredentials(oldClaude.id)
        )

        let manager = retain(ProfileManager(
            profileStore: store,
            activationClaudeEffects: .noOp,
            postClaudeCreationMigration: {
                try migration.migrateClaudeProfileIfNeeded(to: $0)
            }
        ))
        manager.loadProfiles()
        let newClaude = try manager.createProfileThrowing(
            name: "New Owner",
            providerConfiguration: .claude
        )

        XCTAssertEqual(newClaude.claudeSessionKey, "new-owner-secret")
        XCTAssertTrue(source.cleaned)
        XCTAssertNil(
            secrets.values[
                ProfileSecretLocator(
                    profileID: oldClaude.id,
                    field: .claudeSessionKey
                )
            ]
        )
    }

    @MainActor
    func testLegacyMigrationTargetsClaudeWhenCodexIsActive() throws {
        let (defaults, suite) = try HostedTestDefaults.defaults(
            "ProfileProviderCoreTests"
        )
        defer { HostedTestDefaults.finish(defaults, suiteName: suite) }
        HostedTestDefaults.reset(defaults, suiteName: suite)
        let secrets = ProviderSecretStore()
        let store = retain(makeIsolatedProfileStore(
            defaults: defaults,
            secretStore: secrets,
            usageFileStore: ProviderUsageStore()
        ))
        let codex = Profile(
            name: "Codex",
            providerConfiguration: .codex(.init())
        )
        let claude = Profile(name: "Claude")
        try seedProfilesForTesting([codex, claude], in: store)
        defaults.set(codex.id.uuidString, forKey: "activeProfileId")
        let source = ProviderLegacySource(
            snapshot: .init(
                globalClaudeSessionKey: "legacy-claude",
                fileClaudeSessionKey: nil,
                globalAPISessionKey: nil,
                defaultsAPISessionKey: "legacy-api"
            )
        )
        let credentialMigration = retain(KeychainMigrationService(
            source: source,
            defaults: defaults
        ))
        let migration = retain(ProfileMigrationService(
            defaults: defaults,
            profileStore: store,
            credentialMigration: credentialMigration,
            legacySettings: ProviderLegacySettings()
        ))

        try migration.migrateIfNeededThrowing()

        let claudeCredentials = try store.loadProfileCredentials(claude.id)
        XCTAssertEqual(
            claudeCredentials.claudeSessionKey,
            "legacy-claude"
        )
        XCTAssertEqual(claudeCredentials.apiSessionKey, "legacy-api")
        XCTAssertTrue(source.cleaned)
        XCTAssertEqual(store.loadLegacyActiveProfileId(), codex.id)
        XCTAssertEqual(
            store.loadProfiles().first(where: { $0.id == codex.id })?
                .providerConfiguration.kind,
            .codex
        )
    }

    @MainActor
    func testChoosingClaudeImportsLegacySettingsAndCredentials() throws {
        let (defaults, suite) = try HostedTestDefaults.defaults(
            "ProfileProviderCoreTests"
        )
        defer { HostedTestDefaults.finish(defaults, suiteName: suite) }
        HostedTestDefaults.reset(defaults, suiteName: suite)
        let secrets = ProviderSecretStore()
        let store = retain(makeIsolatedProfileStore(
            defaults: defaults,
            secretStore: secrets,
            usageFileStore: ProviderUsageStore()
        ))
        let source = ProviderLegacySource(
            snapshot: .init(
                globalClaudeSessionKey: "legacy-claude",
                fileClaudeSessionKey: nil,
                globalAPISessionKey: nil,
                defaultsAPISessionKey: "legacy-api"
            )
        )
        let settings = ProviderLegacySettings()
        settings.refreshInterval = 61
        settings.autoStart = true
        settings.notifications = true
        let migration = retain(ProfileMigrationService(
            defaults: defaults,
            profileStore: store,
            credentialMigration: retain(KeychainMigrationService(
                source: source,
                defaults: defaults
            )),
            legacySettings: settings
        ))
        let manager = retain(ProfileManager(
            profileStore: store,
            activationClaudeEffects: .noOp,
            postClaudeCreationMigration: {
                try migration.migrateClaudeProfileIfNeeded(to: $0)
            }
        ))
        manager.loadProfiles()

        let profile = try manager.createInitialProfile(
            name: "Chosen Claude",
            providerConfiguration: .claude
        )

        XCTAssertEqual(profile.refreshInterval, 61)
        XCTAssertTrue(profile.autoStartSessionEnabled)
        XCTAssertTrue(profile.notificationSettings.enabled)
        XCTAssertEqual(profile.organizationId, "legacy-org")
        XCTAssertEqual(profile.apiOrganizationId, "legacy-api-org")
        XCTAssertEqual(profile.claudeSessionKey, "legacy-claude")
        XCTAssertEqual(profile.apiSessionKey, "legacy-api")
        XCTAssertTrue(source.cleaned)
        XCTAssertTrue(defaults.bool(forKey: "didMigrateToProfilesV3"))
    }

    @MainActor
    func testExistingV3MarkerSeedsMetadataMarkerWithoutClobberingSettings()
        throws {
        let (defaults, suite) = try HostedTestDefaults.defaults(
            "ProfileProviderCoreTests"
        )
        defer { HostedTestDefaults.finish(defaults, suiteName: suite) }
        HostedTestDefaults.reset(defaults, suiteName: suite)
        defaults.set(true, forKey: "didMigrateToProfilesV3")
        let store = retain(makeIsolatedProfileStore(
            defaults: defaults,
            secretStore: ProviderSecretStore(),
            usageFileStore: ProviderUsageStore()
        ))
        let profile = Profile(
            name: "Customized",
            refreshInterval: 91,
            autoStartSessionEnabled: true,
            notificationSettings: NotificationSettings(
                enabled: true,
                threshold75Enabled: false,
                threshold90Enabled: false,
                threshold95Enabled: false
            )
        )
        try seedProfilesForTesting([profile], in: store)
        let settings = ProviderLegacySettings()
        settings.refreshInterval = 12
        let migration = retain(ProfileMigrationService(
            defaults: defaults,
            profileStore: store,
            credentialMigration: retain(KeychainMigrationService(
                source: ProviderLegacySource(snapshot: .init()),
                defaults: defaults
            )),
            legacySettings: settings
        ))

        let migrated = try migration.migrateClaudeProfileIfNeeded(
            to: profile.id
        )

        XCTAssertEqual(settings.readCount, 0)
        XCTAssertEqual(migrated.refreshInterval, 91)
        XCTAssertTrue(migrated.autoStartSessionEnabled)
        XCTAssertTrue(migrated.notificationSettings.enabled)
        XCTAssertTrue(
            defaults.bool(
                forKey: "profileLegacyMetadataMigrationCompleted_v1"
            )
        )
    }

    @MainActor
    func testChoosingCodexThenAddingFirstClaudeImportsLegacyExactlyOnce()
        throws {
        let (defaults, suite) = try HostedTestDefaults.defaults(
            "ProfileProviderCoreTests"
        )
        defer { HostedTestDefaults.finish(defaults, suiteName: suite) }
        HostedTestDefaults.reset(defaults, suiteName: suite)
        let store = retain(makeIsolatedProfileStore(
            defaults: defaults,
            secretStore: ProviderSecretStore(),
            usageFileStore: ProviderUsageStore()
        ))
        let source = ProviderLegacySource(
            snapshot: .init(
                globalClaudeSessionKey: "later-claude",
                fileClaudeSessionKey: nil,
                globalAPISessionKey: nil,
                defaultsAPISessionKey: nil
            )
        )
        let settings = ProviderLegacySettings()
        let migration = retain(ProfileMigrationService(
            defaults: defaults,
            profileStore: store,
            credentialMigration: retain(KeychainMigrationService(
                source: source,
                defaults: defaults
            )),
            legacySettings: settings
        ))
        let manager = retain(ProfileManager(
            profileStore: store,
            activationClaudeEffects: .noOp,
            postClaudeCreationMigration: {
                try migration.migrateClaudeProfileIfNeeded(to: $0)
            }
        ))
        manager.loadProfiles()
        let codex = try manager.createInitialProfile(
            providerConfiguration: .codex(.init())
        )
        XCTAssertEqual(source.readCount, 0)
        XCTAssertEqual(settings.readCount, 0)

        let claude = try manager.createProfileThrowing(
            name: "Later Claude",
            providerConfiguration: .claude
        )
        XCTAssertEqual(claude.claudeSessionKey, "later-claude")
        XCTAssertEqual(source.readCount, 1)
        XCTAssertTrue(source.cleaned)
        XCTAssertEqual(manager.activeProfile?.id, codex.id)

        _ = try manager.createProfileThrowing(
            name: "Another Claude",
            providerConfiguration: .claude
        )
        XCTAssertEqual(source.readCount, 1)
        XCTAssertEqual(settings.readCount, 6)
    }

    @MainActor
    func testAddingSecondClaudeDoesNotRetargetUnresolvedLegacyMigration()
        throws {
        let (defaults, suite) = try HostedTestDefaults.defaults(
            "ProfileProviderCoreTests"
        )
        defer { HostedTestDefaults.finish(defaults, suiteName: suite) }
        HostedTestDefaults.reset(defaults, suiteName: suite)
        let store = retain(makeIsolatedProfileStore(
            defaults: defaults,
            secretStore: ProviderSecretStore(),
            usageFileStore: ProviderUsageStore()
        ))
        let existing = Profile(name: "Migration Owner")
        try seedProfilesForTesting([existing], in: store)
        let source = ProviderLegacySource(
            snapshot: .init(
                globalClaudeSessionKey: "unresolved-owner-source",
                fileClaudeSessionKey: nil,
                globalAPISessionKey: nil,
                defaultsAPISessionKey: nil
            )
        )
        let settings = ProviderLegacySettings()
        let migration = retain(ProfileMigrationService(
            defaults: defaults,
            profileStore: store,
            credentialMigration: retain(KeychainMigrationService(
                source: source,
                defaults: defaults
            )),
            legacySettings: settings
        ))
        let manager = retain(ProfileManager(
            profileStore: store,
            activationClaudeEffects: .noOp,
            postClaudeCreationMigration: {
                try migration.migrateClaudeProfileIfNeeded(to: $0)
            }
        ))
        manager.profiles = [existing]
        manager.activeProfile = existing

        let second = try manager.createProfileThrowing(
            name: "Second",
            providerConfiguration: .claude
        )

        XCTAssertEqual(second.name, "Second")
        XCTAssertEqual(source.readCount, 0)
        XCTAssertFalse(source.cleaned)
        XCTAssertEqual(settings.readCount, 0)
        XCTAssertFalse(defaults.bool(forKey: "didMigrateToProfilesV3"))
    }

    @MainActor
    func testFailedPostClaudeMigrationPreservesSourceAndRetries() throws {
        let (defaults, suite) = try HostedTestDefaults.defaults(
            "ProfileProviderCoreTests"
        )
        defer { HostedTestDefaults.finish(defaults, suiteName: suite) }
        HostedTestDefaults.reset(defaults, suiteName: suite)
        let secrets = ProviderSecretStore()
        secrets.writeError = ProviderTestError.expected
        let store = retain(makeIsolatedProfileStore(
            defaults: defaults,
            secretStore: secrets,
            usageFileStore: ProviderUsageStore()
        ))
        let source = ProviderLegacySource(
            snapshot: .init(
                globalClaudeSessionKey: "retry-claude",
                fileClaudeSessionKey: nil,
                globalAPISessionKey: nil,
                defaultsAPISessionKey: nil
            )
        )
        let migration = retain(ProfileMigrationService(
            defaults: defaults,
            profileStore: store,
            credentialMigration: retain(KeychainMigrationService(
                source: source,
                defaults: defaults
            )),
            legacySettings: ProviderLegacySettings()
        ))
        let manager = retain(ProfileManager(
            profileStore: store,
            activationClaudeEffects: .noOp,
            postClaudeCreationMigration: {
                try migration.migrateClaudeProfileIfNeeded(to: $0)
            }
        ))
        manager.loadProfiles()

        let created = try manager.createInitialProfile(
            providerConfiguration: .claude
        )
        let chosenID = created.id
        XCTAssertEqual(
            manager.legacyMigrationPendingProfileID,
            chosenID
        )
        XCTAssertFalse(source.cleaned)
        XCTAssertFalse(defaults.bool(forKey: "didMigrateToProfilesV3"))
        XCTAssertEqual(source.readCount, 1)

        var userEdited = try XCTUnwrap(
            store.loadProfiles().first(where: { $0.id == chosenID })
        )
        userEdited.refreshInterval = 88
        try store.saveProfilesThrowing([userEdited])
        secrets.writeError = nil
        let retried = try migration.migrateClaudeProfileIfNeeded(
            to: chosenID
        )
        XCTAssertEqual(retried.claudeSessionKey, "retry-claude")
        XCTAssertEqual(retried.refreshInterval, 88)
        XCTAssertTrue(source.cleaned)
        XCTAssertTrue(defaults.bool(forKey: "didMigrateToProfilesV3"))
    }

    @MainActor
    func testCodexOnlyMigrationPreservesLegacySourcesAndMarkers() throws {
        let (defaults, suite) = try HostedTestDefaults.defaults(
            "ProfileProviderCoreTests"
        )
        defer { HostedTestDefaults.finish(defaults, suiteName: suite) }
        HostedTestDefaults.reset(defaults, suiteName: suite)
        let store = retain(makeIsolatedProfileStore(
            defaults: defaults,
            secretStore: ProviderSecretStore(),
            usageFileStore: ProviderUsageStore()
        ))
        let codex = Profile(
            name: "Codex",
            providerConfiguration: .codex(.init())
        )
        try seedProfilesForTesting([codex], in: store)
        defaults.set(codex.id.uuidString, forKey: "activeProfileId")
        let source = ProviderLegacySource(
            snapshot: .init(
                globalClaudeSessionKey: "preserve",
                fileClaudeSessionKey: nil,
                globalAPISessionKey: nil,
                defaultsAPISessionKey: nil
            )
        )
        let migration = retain(ProfileMigrationService(
            defaults: defaults,
            profileStore: store,
            credentialMigration: retain(KeychainMigrationService(
                source: source,
                defaults: defaults
            )),
            legacySettings: ProviderLegacySettings()
        ))

        try migration.migrateIfNeededThrowing()

        XCTAssertEqual(source.readCount, 0)
        XCTAssertFalse(source.cleaned)
        XCTAssertFalse(defaults.bool(forKey: "didMigrateToProfilesV3"))
        XCTAssertEqual(store.loadLegacyActiveProfileId(), codex.id)
    }

    @MainActor
    func testClaudeAndCodexProfilesActivateIndependently() async throws {
        let defaults = ProviderTestDefaults()
        let store = retain(makeIsolatedProfileStore(
            defaults: defaults,
            secretStore: ProviderSecretStore(),
            usageFileStore: ProviderUsageStore()
        ))
        let claude = Profile(name: "Claude One")
        let claudeTwo = Profile(name: "Claude Two")
        let codex = Profile(
            name: "Codex One",
            providerConfiguration: .codex(.init())
        )
        let codexTwo = Profile(
            name: "Codex Two",
            providerConfiguration: .codex(.init())
        )
        try seedProfilesForTesting(
            [claude, claudeTwo, codex, codexTwo],
            in: store
        )
        let effects = ProviderEffectCounter()
        let manager = retain(ProfileManager(
            profileStore: store,
            activationClaudeEffects: effects.effects
        ))
        manager.loadProfiles()

        await manager.activateProfile(claudeTwo.id)
        await manager.activateProfile(codexTwo.id)

        // Each provider's own active slot moved independently; activating
        // Codex never touched the Claude slot and vice versa.
        XCTAssertEqual(manager.activeClaudeProfile?.id, claudeTwo.id)
        XCTAssertEqual(manager.activeCodexProfile?.id, codexTwo.id)
        XCTAssertEqual(
            store.loadActiveProfileId(for: .claude), claudeTwo.id
        )
        XCTAssertEqual(
            store.loadActiveProfileId(for: .codex), codexTwo.id
        )
        // Focus follows the most recently activated profile, regardless of
        // provider.
        XCTAssertEqual(manager.activeProfile?.id, codexTwo.id)
        XCTAssertTrue(manager.isActive(claudeTwo))
        XCTAssertFalse(manager.isActive(claude))
        XCTAssertTrue(manager.isActive(codexTwo))
        XCTAssertFalse(manager.isActive(codex))
    }

    @MainActor
    func testReactivatingAlreadyActiveProfileOnlyMovesFocus() async throws {
        let defaults = ProviderTestDefaults()
        let store = retain(makeIsolatedProfileStore(
            defaults: defaults,
            secretStore: ProviderSecretStore(),
            usageFileStore: ProviderUsageStore()
        ))
        let claude = Profile(name: "Claude")
        let codex = Profile(
            name: "Codex",
            providerConfiguration: .codex(.init())
        )
        try seedProfilesForTesting([claude, codex], in: store)
        let effects = ProviderEffectCounter()
        let manager = retain(ProfileManager(
            profileStore: store,
            activationClaudeEffects: effects.effects
        ))
        manager.loadProfiles()
        await manager.activateProfile(codex.id)
        effects.reset()

        // Claude is already the active Claude profile (it was elected as the
        // provider's first profile on load) — reactivating it must not rerun
        // Claude activation side effects, only move focus.
        await manager.activateProfile(claude.id)

        XCTAssertEqual(effects.count, 0)
        XCTAssertEqual(manager.activeProfile?.id, claude.id)
        XCTAssertEqual(manager.activeClaudeProfile?.id, claude.id)
        XCTAssertEqual(manager.activeCodexProfile?.id, codex.id)
    }

    @MainActor
    func testLegacySingleSlotMigratesToOwningProviderOnly() throws {
        let defaults = ProviderTestDefaults()
        let store = retain(makeIsolatedProfileStore(
            defaults: defaults,
            secretStore: ProviderSecretStore(),
            usageFileStore: ProviderUsageStore()
        ))
        let claude = Profile(name: "Claude")
        let codex = Profile(
            name: "Codex",
            providerConfiguration: .codex(.init())
        )
        try seedProfilesForTesting([claude, codex], in: store)
        // Simulate a pre-upgrade install: only the legacy single slot is
        // populated, pointing at the Codex profile.
        defaults.set(codex.id.uuidString, forKey: "activeProfileId")

        let manager = retain(ProfileManager(
            profileStore: store,
            activationClaudeEffects: .noOp
        ))
        manager.loadProfiles()

        // The legacy id is claimed only by the provider that actually owns
        // it; the other provider falls back to its own first profile.
        XCTAssertEqual(manager.activeCodexProfile?.id, codex.id)
        XCTAssertEqual(manager.activeClaudeProfile?.id, claude.id)
        XCTAssertEqual(manager.activeProfile?.id, codex.id)
        XCTAssertEqual(store.loadActiveProfileId(for: .codex), codex.id)
        XCTAssertEqual(store.loadActiveProfileId(for: .claude), claude.id)
    }

    @MainActor
    func testDeletingActiveCodexProfileNeverTouchesActiveClaudeProfile()
        throws
    {
        let defaults = ProviderTestDefaults()
        let store = retain(makeIsolatedProfileStore(
            defaults: defaults,
            secretStore: ProviderSecretStore(),
            usageFileStore: ProviderUsageStore()
        ))
        let claude = Profile(name: "Claude")
        let codex = Profile(
            name: "Codex",
            providerConfiguration: .codex(.init())
        )
        let codexSurvivor = Profile(
            name: "Codex Survivor",
            providerConfiguration: .codex(.init())
        )
        try seedProfilesForTesting(
            [claude, codex, codexSurvivor],
            in: store
        )
        let manager = retain(ProfileManager(
            profileStore: store,
            activationClaudeEffects: .noOp
        ))
        manager.loadProfiles()
        XCTAssertEqual(manager.activeCodexProfile?.id, codex.id)
        XCTAssertEqual(manager.activeClaudeProfile?.id, claude.id)

        try manager.deleteProfile(codex.id)

        XCTAssertEqual(manager.activeCodexProfile?.id, codexSurvivor.id)
        XCTAssertEqual(manager.activeClaudeProfile?.id, claude.id)
        XCTAssertEqual(
            store.loadActiveProfileId(for: .codex), codexSurvivor.id
        )
    }

    @MainActor
    func testActivatingLinkedCodexProfileSwitchesCodexHomeNotClaudeEffects()
        async throws
    {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let homeURL = root.appendingPathComponent(
            "codex-home", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: homeURL, withIntermediateDirectories: true
        )
        let linkedHome = try CodexHomeCanonicalizer()
            .canonicalize(homeURL.path)

        let defaults = ProviderTestDefaults()
        let store = retain(makeIsolatedProfileStore(
            defaults: defaults,
            secretStore: ProviderSecretStore(),
            usageFileStore: ProviderUsageStore()
        ))
        let codex = Profile(
            name: "Linked Codex",
            providerConfiguration: .codex(.init(linkedHome: linkedHome))
        )
        try seedProfilesForTesting([codex], in: store)
        let claudeEffects = ProviderEffectCounter()
        let codexEffects = ProviderCodexEffectCounter()
        let manager = retain(ProfileManager(
            profileStore: store,
            activationClaudeEffects: claudeEffects.effects,
            activationCodexEffects: codexEffects.effects
        ))
        manager.profiles = [codex]

        await manager.activateProfile(codex.id)

        XCTAssertEqual(claudeEffects.count, 0)
        XCTAssertEqual(codexEffects.switchedHomes, [linkedHome])
    }

    /// If activation cannot honor the newly activated profile's linked
    /// home — e.g. the directory was deleted since it was linked — the
    /// terminal must fall back to Codex's own `~/.codex` default rather
    /// than keep pointing at the PREVIOUS profile's home. That fallback is
    /// `activationCodexEffects.clearHome()`, mirrored from what
    /// `replaceCodexLinkedHome` already does on the same failure.
    @MainActor
    func testActivatingCodexProfileClearsHomeWhenSwitchFails() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let homeURL = root.appendingPathComponent(
            "codex-home", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: homeURL, withIntermediateDirectories: true
        )
        let linkedHome = try CodexHomeCanonicalizer()
            .canonicalize(homeURL.path)

        let defaults = ProviderTestDefaults()
        let store = retain(makeIsolatedProfileStore(
            defaults: defaults,
            secretStore: ProviderSecretStore(),
            usageFileStore: ProviderUsageStore()
        ))
        let codex = Profile(
            name: "Linked Codex",
            providerConfiguration: .codex(.init(linkedHome: linkedHome))
        )
        try seedProfilesForTesting([codex], in: store)
        let codexEffects = ProviderCodexEffectCounter()
        codexEffects.switchToLinkedHomeError = ProviderTestError.expected
        let manager = retain(ProfileManager(
            profileStore: store,
            activationClaudeEffects: .noOp,
            activationCodexEffects: codexEffects.effects
        ))
        manager.profiles = [codex]

        await manager.activateProfile(codex.id)

        XCTAssertTrue(codexEffects.switchedHomes.isEmpty)
        XCTAssertEqual(
            codexEffects.clearCount,
            1,
            "Activation must clear CODEX_HOME when it fails to switch to "
                + "the newly activated profile's linked home"
        )
    }

    /// `reapplyActiveCodexHome()` is the counterpart to the startup
    /// self-heal (`CodexSwitchService.discardStaleHomeIfMissing()`), which
    /// discards the live CODEX_HOME pointer whenever its directory doesn't
    /// currently exist (e.g. an unmounted external volume). The user's
    /// selection survives in `linkedHome` regardless, so once profiles are
    /// loaded this should put the live pointer back for whichever Codex
    /// profile is active — without going through `activateProfile(_:)`,
    /// which can't help here since it early-returns for an already-active
    /// profile.
    @MainActor
    func testReapplyActiveCodexHomeRestoresPointerForActiveLinkedProfile()
        throws
    {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let homeURL = root.appendingPathComponent(
            "codex-home", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: homeURL, withIntermediateDirectories: true
        )
        let linkedHome = try CodexHomeCanonicalizer()
            .canonicalize(homeURL.path)

        let defaults = ProviderTestDefaults()
        let store = retain(makeIsolatedProfileStore(
            defaults: defaults,
            secretStore: ProviderSecretStore(),
            usageFileStore: ProviderUsageStore()
        ))
        let codex = Profile(
            name: "Linked Codex",
            providerConfiguration: .codex(.init(linkedHome: linkedHome))
        )
        try seedProfilesForTesting([codex], in: store)
        let codexEffects = ProviderCodexEffectCounter()
        let manager = retain(ProfileManager(
            profileStore: store,
            activationClaudeEffects: .noOp,
            activationCodexEffects: codexEffects.effects
        ))

        manager.loadProfiles()
        manager.reapplyActiveCodexHome()

        XCTAssertEqual(codexEffects.switchedHomes, [linkedHome])
        XCTAssertEqual(codexEffects.clearCount, 0)
    }

    /// If the linked directory is still unavailable when this runs (e.g.
    /// the volume is still unmounted), the failure must be swallowed and
    /// must NOT clear the pointer again — the startup self-heal already
    /// handled the stale case, and clearing here would defeat the whole
    /// point of re-applying it.
    @MainActor
    func testReapplyActiveCodexHomeSwallowsFailureWithoutClearing() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = ProviderTestDefaults()
        let store = retain(makeIsolatedProfileStore(
            defaults: defaults,
            secretStore: ProviderSecretStore(),
            usageFileStore: ProviderUsageStore()
        ))
        let linkedHome = try CodexHomeCanonicalizer()
            .canonicalize(root.path)
        let codex = Profile(
            name: "Linked Codex",
            providerConfiguration: .codex(.init(linkedHome: linkedHome))
        )
        try seedProfilesForTesting([codex], in: store)
        let codexEffects = ProviderCodexEffectCounter()
        codexEffects.switchToLinkedHomeError = ProviderTestError.expected
        let manager = retain(ProfileManager(
            profileStore: store,
            activationClaudeEffects: .noOp,
            activationCodexEffects: codexEffects.effects
        ))

        manager.loadProfiles()
        manager.reapplyActiveCodexHome()

        XCTAssertTrue(codexEffects.switchedHomes.isEmpty)
        XCTAssertEqual(
            codexEffects.clearCount,
            0,
            "Re-applying must never clear CODEX_HOME on failure — that "
                + "would re-discard the pointer the startup self-heal "
                + "already handled"
        )
    }

    /// With no active Codex profile (or an active one with no linked
    /// home), re-applying must be inert — no switch, no clear.
    @MainActor
    func testReapplyActiveCodexHomeIsNoOpWithoutActiveLinkedProfile()
        throws
    {
        let defaults = ProviderTestDefaults()
        let store = retain(makeIsolatedProfileStore(
            defaults: defaults,
            secretStore: ProviderSecretStore(),
            usageFileStore: ProviderUsageStore()
        ))
        let codex = Profile(
            name: "Unlinked Codex",
            providerConfiguration: .codex(.init())
        )
        try seedProfilesForTesting([codex], in: store)
        let codexEffects = ProviderCodexEffectCounter()
        let manager = retain(ProfileManager(
            profileStore: store,
            activationClaudeEffects: .noOp,
            activationCodexEffects: codexEffects.effects
        ))

        manager.loadProfiles()
        manager.reapplyActiveCodexHome()

        XCTAssertTrue(codexEffects.switchedHomes.isEmpty)
        XCTAssertEqual(codexEffects.clearCount, 0)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "profile-provider-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    private func fixtureData(named name: String) throws -> Data {
        let fixturesURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
        return try Data(
            contentsOf: fixturesURL.appendingPathComponent(name)
        )
    }

    private func makeProviderReport(
        providerID: ProviderID,
        marker: TimeInterval
    ) throws -> UsageReport {
        let date = Date(timeIntervalSinceReferenceDate: marker)
        return try UsageReport(
            providerID: providerID,
            health: ProviderHealth(
                status: .healthy,
                checkedAt: date
            ),
            limitGroups: [],
            fetchedAt: date,
            staleAt: date.addingTimeInterval(60)
        )
    }
}

private final class ProviderTestDefaults: ProfileDefaultsStore {
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

private final class ProviderSecretStore: ProfileSecretStore {
    var values: [ProfileSecretLocator: String] = [:]
    var writeError: Error?
    private(set) var readCount = 0
    private(set) var writeCount = 0
    private(set) var deleteCount = 0
    private(set) var auditEntries: [String] = []

    var operationCount: Int { readCount + writeCount + deleteCount }

    func read(_ locator: ProfileSecretLocator) throws
        -> ProfileSecretReadResult {
        readCount += 1
        auditEntries.append("read \(locator.safeDescription)")
        return values[locator].map(ProfileSecretReadResult.value) ?? .absent
    }

    func write(_ value: String, to locator: ProfileSecretLocator) throws {
        writeCount += 1
        auditEntries.append("write \(locator.safeDescription)")
        if let writeError {
            throw writeError
        }
        values[locator] = value
    }

    func delete(_ locator: ProfileSecretLocator) throws {
        deleteCount += 1
        auditEntries.append("delete \(locator.safeDescription)")
        values.removeValue(forKey: locator)
    }

    func reset() {
        readCount = 0
        writeCount = 0
        deleteCount = 0
        auditEntries.removeAll()
    }
}

private final class ProviderUsageStore: ProfileCurrentUsageFileStoring {
    var values: [UUID: ProfileCurrentUsage] = [:]
    var saveError: Error?
    var deleteError: Error?
    private(set) var deleteCurrentCount = 0
    private(set) var deleteAllCount = 0

    func loadCurrentUsage(for profileID: UUID) throws
        -> ProfileCurrentUsage? {
        values[profileID]
    }

    func saveCurrentUsage(
        _ usage: ProfileCurrentUsage,
        for profileID: UUID
    ) throws {
        if let saveError {
            throw saveError
        }
        values[profileID] = usage
    }

    func updateCurrentUsage(
        for profileID: UUID,
        transform: (inout ProfileCurrentUsage) throws -> Void
    ) throws -> ProfileCurrentUsage {
        var usage = values[profileID] ?? ProfileCurrentUsage()
        try transform(&usage)
        values[profileID] = usage
        return usage
    }

    func deleteCurrentUsage(for profileID: UUID) throws {
        deleteCurrentCount += 1
        if let deleteError {
            throw deleteError
        }
        values.removeValue(forKey: profileID)
    }

    func deleteAllData(for profileID: UUID) throws {
        deleteAllCount += 1
        values.removeValue(forKey: profileID)
    }
}

private enum ProviderTestError: Error {
    case expected
}

@MainActor
private final class ProviderHistoryDeleter: ProfileHistoryDeleting {
    var failuresRemaining = 0

    func deleteHistoryThrowing(for profileId: UUID) throws {
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw ProviderTestError.expected
        }
    }
}

private final class ProviderLifecycleRecorder {
    private(set) var started: [Profile] = []
    private(set) var cleaned: [Profile] = []
    private(set) var completed: [Profile] = []
    var cleanupFailuresRemaining = 0

    var sink: ProfileLifecycleEventSink {
        ProfileLifecycleEventSink(
            deletionStarted: { [weak self] in
                self?.started.append($0)
            },
            deletionCleanup: { [weak self] profile in
                guard let self else { return }
                cleaned.append(profile)
                if cleanupFailuresRemaining > 0 {
                    cleanupFailuresRemaining -= 1
                    throw ProviderTestError.expected
                }
            },
            deletionCompleted: { [weak self] in
                self?.completed.append($0)
            }
        )
    }
}

private final class ProviderEffectCounter {
    private(set) var count = 0

    func reset() {
        count = 0
    }

    var effects: ProfileActivationClaudeEffects {
        ProfileActivationClaudeEffects(
            resyncBeforeSwitching: { [weak self] _ in self?.count += 1 },
            applyProfileCredentials: { [weak self] _ in self?.count += 1 },
            switchAccountAndSync: { [weak self] _ in self?.count += 1 }
        )
    }
}

private final class ProviderCodexEffectCounter {
    private(set) var switchedHomes: [CanonicalCodexHome] = []
    private(set) var clearCount = 0
    /// Set to make `switchToLinkedHome` throw instead of recording, for
    /// tests that assert on the failure path (e.g. that activation falls
    /// back to clearing the home when it cannot honor the new one).
    var switchToLinkedHomeError: Error?

    var effects: ProfileActivationCodexEffects {
        ProfileActivationCodexEffects(
            switchToLinkedHome: { [weak self] home in
                if let error = self?.switchToLinkedHomeError {
                    throw error
                }
                self?.switchedHomes.append(home)
            },
            clearHome: { [weak self] in
                self?.clearCount += 1
            }
        )
    }
}

private extension ProfileActivationClaudeEffects {
    static var noOp: ProfileActivationClaudeEffects {
        ProfileActivationClaudeEffects(
            resyncBeforeSwitching: { _ in },
            applyProfileCredentials: { _ in },
            switchAccountAndSync: { _ in }
        )
    }
}

private final class ProviderLegacySource: LegacyCredentialSource {
    let snapshot: LegacyCredentialSnapshot
    private(set) var readCount = 0
    private(set) var cleaned = false

    init(snapshot: LegacyCredentialSnapshot) {
        self.snapshot = snapshot
    }

    func readSnapshot() throws -> LegacyCredentialSnapshot {
        readCount += 1
        return snapshot
    }

    func removeVerifiedSources(
        from snapshot: LegacyCredentialSnapshot
    ) throws {
        cleaned = true
    }
}

private final class ProviderLegacySettings: LegacyProfileSettingsSource {
    var refreshInterval: TimeInterval = 30
    var notifications = false
    var autoStart = false
    private(set) var readCount = 0

    func loadMenuBarIconConfiguration() -> MenuBarIconConfiguration {
        readCount += 1
        return .default
    }
    func loadRefreshInterval() -> TimeInterval {
        readCount += 1
        return refreshInterval
    }
    func loadNotificationsEnabled() -> Bool {
        readCount += 1
        return notifications
    }
    func loadAutoStartSessionEnabled() -> Bool {
        readCount += 1
        return autoStart
    }
    func loadOrganizationId() -> String? {
        readCount += 1
        return "legacy-org"
    }
    func loadAPIOrganizationId() -> String? {
        readCount += 1
        return "legacy-api-org"
    }
}
