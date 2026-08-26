import Foundation
import UsageCore
import XCTest
@testable import Claude_Usage

final class ProfileCurrentUsageIntegrationTests: HostedAppTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let (testDefaults, testSuiteName) = try HostedTestDefaults.defaults(
            "ClaudeUsageTests.CurrentUsage"
        )
        suiteName = testSuiteName
        defaults = testDefaults
        HostedTestDefaults.reset(defaults, suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        HostedTestDefaults.finish(defaults, suiteName: suiteName)
        defaults = nil
        suiteName = nil
        try super.tearDownWithError()
    }

    @MainActor
    func testLegacyUsageMigratesToVerifiedFileAndScrubsProfileJSON() throws {
        let profileID = UUID()
        let claude = makeClaudeUsage(tokens: 41)
        let api = makeAPIUsage(spend: 205)
        seedLegacyUsageProfile(id: profileID, claude: claude, api: api)
        let usageFiles = MockCurrentUsageFileStore()
        let store = retain(makeStore(usageFiles: usageFiles))

        let loaded = try store.loadProfilesWithVerifiedMigration()

        XCTAssertEqual(loaded.first?.claudeUsage, claude)
        XCTAssertEqual(loaded.first?.apiUsage, api)
        XCTAssertEqual(
            usageFiles.values[profileID],
            ProfileCurrentUsage(claudeUsage: claude, apiUsage: api)
        )
        XCTAssertEqual(usageFiles.values[profileID]?.providerID, .claude)
        XCTAssertEqual(usageFiles.values[profileID]?.providerRevision, 0)
        XCTAssertNil(usageFiles.values[profileID]?.report)
        let persisted = try persistedProfileText()
        XCTAssertFalse(persisted.contains("\"claudeUsage\""))
        XCTAssertFalse(persisted.contains("\"apiUsage\""))
        XCTAssertFalse(persisted.contains("currentUsageMigrationRetry"))
        XCTAssertFalse(persisted.contains("claudeSessionKey"))

        let relaunched = retain(makeStore(usageFiles: usageFiles))
            .loadProfiles()
        XCTAssertEqual(relaunched.first?.claudeUsage, claude)
        XCTAssertEqual(relaunched.first?.apiUsage, api)
    }

    func testCurrentUsageIdentityDefaultsOnlyForWhollyLegacyPayloads()
        throws {
        let decoder = JSONDecoder()
        let legacy = try decoder.decode(
            ProfileCurrentUsage.self,
            from: Data(#"{"claudeUsage":null}"#.utf8)
        )
        XCTAssertEqual(legacy.providerID, .claude)
        XCTAssertEqual(legacy.providerRevision, 0)

        let tagged = try decoder.decode(
            ProfileCurrentUsage.self,
            from: Data(
                #"{"providerID":"codex","providerRevision":7}"#.utf8
            )
        )
        XCTAssertEqual(tagged.providerID, .codex)
        XCTAssertEqual(tagged.providerRevision, 7)

        let malformed = [
            #"{"providerID":"codex"}"#,
            #"{"providerRevision":7}"#,
            #"{"providerID":null,"providerRevision":7}"#,
            #"{"providerID":"codex","providerRevision":null}"#
        ]
        for json in malformed {
            XCTAssertThrowsError(
                try decoder.decode(
                    ProfileCurrentUsage.self,
                    from: Data(json.utf8)
                ),
                "Accepted partial or null identity: \(json)"
            )
        }
    }

    @MainActor
    func testCodexPayloadRejectsClaudeCompatibilityOnDecodeSaveAndLoad()
        throws {
        let incompatiblePayloads = [
            ProfileCurrentUsage(claudeUsage: makeClaudeUsage(tokens: 1)),
            ProfileCurrentUsage(apiUsage: makeAPIUsage(spend: 1))
        ]
        var invalidObjects: [[String: Any]] = []
        for payload in incompatiblePayloads {
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: JSONEncoder().encode(payload)
                ) as? [String: Any]
            )
            object["providerID"] = "codex"
            object["providerRevision"] = 0
            invalidObjects.append(object)
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    ProfileCurrentUsage.self,
                    from: try JSONSerialization.data(
                        withJSONObject: object
                    )
                )
            ) { error in
                XCTAssertTrue(
                    String(describing: error).contains(
                        "claudeCompatibilityOnCodex"
                    )
                        || error.localizedDescription.contains(
                            "compatibility"
                        )
                )
            }
        }

        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "CodexIsolation-\(UUID().uuidString)"
            )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: rootURL)
        }
        let profileID = UUID()
        let store = ProfileUsageFileStore(baseURL: rootURL)
        XCTAssertThrowsError(
            try store.saveCurrentUsage(
                ProfileCurrentUsage(
                    providerID: .codex,
                    claudeUsage: makeClaudeUsage(tokens: 2)
                ),
                for: profileID
            )
        )
        XCTAssertThrowsError(
            try store.saveCurrentUsage(
                ProfileCurrentUsage(
                    providerID: .codex,
                    apiUsage: makeAPIUsage(spend: 2)
                ),
                for: profileID
            )
        )

        let fileURL = try store.fileURL(
            for: profileID,
            kind: .currentUsage
        )
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "profileID": profileID.uuidString,
            "providerID": "codex",
            "recordKind": "current-usage",
            "writtenAt": 0,
            "updatedAt": 0,
            "payload": invalidObjects[0]
        ]).write(to: fileURL)
        XCTAssertThrowsError(
            try store.loadCurrentUsage(for: profileID)
        )
    }

    @MainActor
    func testCodexCurrentUsageUsesDynamicEnvelopeAndNormalizedReport()
        throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "CodexCurrentUsage-\(UUID().uuidString)"
            )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: rootURL)
        }
        let profileID = UUID()
        let store = ProfileUsageFileStore(baseURL: rootURL)
        let usage = ProfileCurrentUsage(
            providerID: .codex,
            providerRevision: 4,
            report: try makeReport(providerID: .codex, marker: 4)
        )

        try store.saveCurrentUsage(usage, for: profileID)

        XCTAssertEqual(try store.loadCurrentUsage(for: profileID), usage)
        let data = try Data(
            contentsOf: store.fileURL(
                for: profileID,
                kind: .currentUsage
            )
        )
        let envelope = try JSONDecoder().decode(
            ProfileUsageFileEnvelope<ProfileCurrentUsage>.self,
            from: data
        )
        XCTAssertEqual(envelope.providerID, "codex")
        XCTAssertEqual(envelope.payload.providerRevision, 4)
        XCTAssertEqual(envelope.payload.report, usage.report)
        XCTAssertNil(envelope.payload.claudeUsage)
        XCTAssertNil(envelope.payload.apiUsage)
    }

    @MainActor
    func testCommitFenceReturnsPreviousAndRejectsStaleOrDeletedIdentity()
        throws {
        let profileID = UUID()
        let usageFiles = MockCurrentUsageFileStore()
        let store = retain(makeStore(usageFiles: usageFiles))
        let profile = Profile(
            id: profileID,
            name: "Codex",
            providerConfiguration: .codex(.init()),
            providerRevision: 3
        )
        try seedProfilesForTesting([profile], in: store)
        let previous = ProfileCurrentUsage(
            providerID: .codex,
            providerRevision: 3,
            report: try makeReport(providerID: .codex, marker: 1)
        )
        usageFiles.values[profileID] = previous
        let candidate = ProfileCurrentUsage(
            providerID: .codex,
            providerRevision: 3,
            report: try makeReport(providerID: .codex, marker: 2)
        )

        let committed = try store.commitCurrentUsage(
            candidate,
            for: profileID,
            expectedProviderID: .codex,
            expectedProviderRevision: 3
        )
        XCTAssertEqual(committed.previous, previous)
        XCTAssertEqual(committed.current, candidate)
        XCTAssertEqual(usageFiles.values[profileID], candidate)

        XCTAssertThrowsError(
            try store.commitCurrentUsage(
                ProfileCurrentUsage(
                    providerID: .codex,
                    providerRevision: 2,
                    report: try makeReport(
                        providerID: .codex,
                        marker: 99
                    )
                ),
                for: profileID,
                expectedProviderID: .codex,
                expectedProviderRevision: 2
            )
        )
        XCTAssertEqual(usageFiles.values[profileID], candidate)

        _ = try store.beginProfileDeletion(profileID)
        XCTAssertThrowsError(
            try store.commitCurrentUsage(
                candidate,
                for: profileID,
                expectedProviderID: .codex,
                expectedProviderRevision: 3
            )
        ) { error in
            guard case ProfileStoreError.profileDeletionInProgress = error
            else {
                return XCTFail("Expected deletion fence, got \(error)")
            }
        }
        XCTAssertEqual(usageFiles.values[profileID], candidate)
    }

    @MainActor
    func testCommitRemovesItsInstalledValueWhenIdentityChangesAtReadback()
        throws {
        let profileID = UUID()
        let usageFiles = MockCurrentUsageFileStore()
        let store = retain(makeStore(usageFiles: usageFiles))
        let original = Profile(
            id: profileID,
            name: "Codex",
            providerConfiguration: .codex(.init()),
            providerRevision: 0
        )
        try seedProfilesForTesting([original], in: store)
        usageFiles.onSave = { [defaults] in
            var changed = original
            changed.providerRevision = 1
            defaults?.set(
                try! JSONEncoder().encode([changed]),
                forKey: "profiles_v3"
            )
        }
        let candidate = ProfileCurrentUsage(
            providerID: .codex,
            providerRevision: 0,
            report: try makeReport(providerID: .codex, marker: 1)
        )

        XCTAssertThrowsError(
            try store.commitCurrentUsage(
                candidate,
                for: profileID,
                expectedProviderID: .codex,
                expectedProviderRevision: 0
            )
        )
        XCTAssertNil(usageFiles.values[profileID])
    }

    @MainActor
    func testUnlinkComponentsPreserveOrClearNormalizedReportAtomically()
        throws {
        let profileID = UUID()
        let secrets = MockSecretStore()
        let usageFiles = MockCurrentUsageFileStore()
        let store = retain(
            makeStore(usageFiles: usageFiles, secrets: secrets)
        )
        let profile = Profile(
            id: profileID,
            name: "Claude",
            organizationId: "claude-org",
            apiOrganizationId: "api-org"
        )
        try seedProfilesForTesting([profile], in: store)
        secrets.values[
            ProfileSecretLocator(
                profileID: profileID,
                field: .claudeSessionKey
            )
        ] = "claude-session"
        secrets.values[
            ProfileSecretLocator(
                profileID: profileID,
                field: .apiSessionKey
            )
        ] = "api-session"
        let report = try makeReport(providerID: .claude, marker: 8)
        let claude = makeClaudeUsage(tokens: 8)
        usageFiles.values[profileID] = ProfileCurrentUsage(
            report: report,
            claudeUsage: claude,
            apiUsage: makeAPIUsage(spend: 8)
        )

        try store.unlinkAPIConsole(for: profileID)
        XCTAssertEqual(usageFiles.values[profileID]?.report, report)
        XCTAssertEqual(usageFiles.values[profileID]?.claudeUsage, claude)
        XCTAssertNil(usageFiles.values[profileID]?.apiUsage)

        try store.unlinkClaudeAI(for: profileID)
        XCTAssertNil(usageFiles.values[profileID]?.report)
        XCTAssertNil(usageFiles.values[profileID]?.claudeUsage)
        XCTAssertNil(usageFiles.values[profileID]?.apiUsage)
    }

    @MainActor
    func testFailedLegacyMigrationRetainsExplicitRetryUntilReadbackSucceeds() throws {
        let profileID = UUID()
        let claude = makeClaudeUsage(tokens: 72)
        let api = makeAPIUsage(spend: 900)
        seedLegacyUsageProfile(id: profileID, claude: claude, api: api)
        let usageFiles = MockCurrentUsageFileStore()
        usageFiles.saveError = TestFailure.expected
        let store = retain(makeStore(usageFiles: usageFiles))

        let firstLoad = try store.loadProfilesWithVerifiedMigration()

        XCTAssertEqual(firstLoad.first?.claudeUsage, claude)
        XCTAssertEqual(firstLoad.first?.apiUsage, api)
        XCTAssertTrue(try persistedProfileText().contains("currentUsageMigrationRetry"))

        usageFiles.saveError = nil
        let secondLoad = try store.loadProfilesWithVerifiedMigration()
        XCTAssertEqual(secondLoad.first?.claudeUsage, claude)
        XCTAssertEqual(secondLoad.first?.apiUsage, api)
        XCTAssertFalse(try persistedProfileText().contains("currentUsageMigrationRetry"))
        XCTAssertEqual(usageFiles.values[profileID]?.claudeUsage, claude)
    }

    @MainActor
    func testValidCurrentFileWinsOverStaleMigrationRetryEnvelope() throws {
        let profileID = UUID()
        let staleUsage = ProfileCurrentUsage(
            claudeUsage: makeClaudeUsage(tokens: 10),
            apiUsage: makeAPIUsage(spend: 10)
        )
        let currentUsage = ProfileCurrentUsage(
            claudeUsage: makeClaudeUsage(tokens: 90),
            apiUsage: makeAPIUsage(spend: 90)
        )
        let retryProfile = Profile(
            id: profileID,
            name: "Interrupted Migration",
            claudeUsage: staleUsage.claudeUsage,
            apiUsage: staleUsage.apiUsage,
            currentUsageMigrationRetry: staleUsage
        )
        defaults.set(
            try JSONEncoder().encode([retryProfile]),
            forKey: "profiles_v3"
        )
        let usageFiles = MockCurrentUsageFileStore()
        usageFiles.values[profileID] = currentUsage
        let store = retain(makeStore(usageFiles: usageFiles))

        let loaded = try store.loadProfilesWithVerifiedMigration()

        XCTAssertEqual(loaded.first?.claudeUsage, currentUsage.claudeUsage)
        XCTAssertEqual(loaded.first?.apiUsage, currentUsage.apiUsage)
        XCTAssertEqual(usageFiles.values[profileID], currentUsage)
        XCTAssertEqual(usageFiles.saveCount, 0)
        XCTAssertFalse(try persistedProfileText().contains("currentUsageMigrationRetry"))
    }

    @MainActor
    func testReadErrorStaysUnresolvedAndMetadataSaveIsUsageNeutral() throws {
        let profileID = UUID()
        let existing = ProfileCurrentUsage(
            claudeUsage: makeClaudeUsage(tokens: 19),
            apiUsage: makeAPIUsage(spend: 88)
        )
        let usageFiles = MockCurrentUsageFileStore()
        usageFiles.values[profileID] = existing
        let setupStore = retain(makeStore(usageFiles: usageFiles))
        try seedProfilesForTesting(
            [Profile(id: profileID, name: "Before")],
            in: setupStore
        )

        usageFiles.loadErrors[profileID] = TestFailure.expected
        let store = retain(makeStore(usageFiles: usageFiles))
        var profiles = store.loadProfiles()
        XCTAssertNil(profiles.first?.claudeUsage)
        profiles[0].name = "After"

        try store.saveProfilesThrowing(profiles)

        XCTAssertEqual(usageFiles.values[profileID], existing)
        XCTAssertEqual(usageFiles.updateCount, 0)
        XCTAssertEqual(usageFiles.deleteAllCount, 0)
        XCTAssertThrowsError(try store.loadClaudeUsage(for: profileID))
        XCTAssertEqual(store.loadProfiles().first?.name, "After")
    }

    @MainActor
    func testCorruptCurrentFileCannotBecomeImplicitAbsenceAfterQuarantine() throws {
        let profileID = UUID()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CurrentUsageCorruption-\(UUID().uuidString)")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: rootURL)
        }
        let usageFiles = ProfileUsageFileStore(baseURL: rootURL)
        let oldUsage = ProfileCurrentUsage(
            claudeUsage: makeClaudeUsage(tokens: 44)
        )
        try usageFiles.saveCurrentUsage(oldUsage, for: profileID)
        let currentURL = try usageFiles.fileURL(for: profileID, kind: .currentUsage)
        try Data("not-json".utf8).write(to: currentURL)
        let store = retain(
            makeIsolatedProfileStore(
                defaults: defaults,
                secretStore: MockSecretStore(),
                usageFileStore: usageFiles
            )
        )
        try seedProfilesForTesting(
            [Profile(id: profileID, name: "Before")],
            in: store
        )

        var loaded = store.loadProfiles()
        XCTAssertNil(loaded.first?.claudeUsage)
        loaded[0].name = "After"
        try store.saveProfilesThrowing(loaded)

        XCTAssertThrowsError(
            try store.saveClaudeUsage(makeClaudeUsage(tokens: 99), for: profileID)
        ) { error in
            guard case ProfileUsageFileStoreError.currentUsageReadUnresolved = error else {
                return XCTFail("Expected unresolved current usage, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: currentURL.path))
        XCTAssertEqual(store.loadProfiles().first?.name, "After")
    }

    @MainActor
    func testExplicitComponentUpdatesPreserveOtherComponentAndProfileIsolation() throws {
        let firstID = UUID()
        let secondID = UUID()
        let firstClaude = makeClaudeUsage(tokens: 11)
        let firstAPI = makeAPIUsage(spend: 22)
        let secondAPI = makeAPIUsage(spend: 33)
        let usageFiles = MockCurrentUsageFileStore()
        let store = retain(makeStore(usageFiles: usageFiles))
        try seedProfilesForTesting([
            Profile(id: firstID, name: "First"),
            Profile(id: secondID, name: "Second")
        ], in: store)

        try store.saveClaudeUsage(firstClaude, for: firstID)
        try store.saveAPIUsage(firstAPI, for: firstID)
        try store.saveAPIUsage(secondAPI, for: secondID)

        XCTAssertEqual(try store.loadClaudeUsage(for: firstID), firstClaude)
        XCTAssertEqual(try store.loadAPIUsage(for: firstID), firstAPI)
        XCTAssertEqual(try store.loadAPIUsage(for: secondID), secondAPI)
        XCTAssertNil(try store.loadClaudeUsage(for: secondID))

        try store.clearClaudeUsage(for: firstID)
        XCTAssertNil(try store.loadClaudeUsage(for: firstID))
        XCTAssertEqual(try store.loadAPIUsage(for: firstID), firstAPI)
        XCTAssertEqual(try store.loadAPIUsage(for: secondID), secondAPI)
        XCTAssertFalse(try persistedProfileText().contains("\"apiUsage\""))
    }

    @MainActor
    func testManagerPublishesUsageOnlyAfterVerifiedPersistence() throws {
        let profileID = UUID()
        let oldUsage = makeClaudeUsage(tokens: 1)
        let newUsage = makeClaudeUsage(tokens: 2)
        let oldAPIUsage = makeAPIUsage(spend: 1)
        let newAPIUsage = makeAPIUsage(spend: 2)
        let usageFiles = MockCurrentUsageFileStore()
        usageFiles.values[profileID] = ProfileCurrentUsage(
            claudeUsage: oldUsage,
            apiUsage: oldAPIUsage
        )
        let store = retain(makeStore(usageFiles: usageFiles))
        try seedProfilesForTesting(
            [Profile(id: profileID, name: "Profile")],
            in: store
        )
        let history = retain(MockHistoryDeleter())
        let manager = retain(
            ProfileManager(profileStore: store, historyService: history)
        )
        manager.profiles = [
            Profile(
                id: profileID,
                name: "Profile",
                claudeUsage: oldUsage,
                apiUsage: oldAPIUsage
            )
        ]
        manager.activeProfile = manager.profiles[0]
        usageFiles.updateError = TestFailure.expected

        XCTAssertFalse(
            manager.saveClaudeUsage(newUsage, for: profileID)
        )
        XCTAssertFalse(
            manager.saveAPIUsage(newAPIUsage, for: profileID)
        )

        XCTAssertEqual(manager.profiles.first?.claudeUsage, oldUsage)
        XCTAssertEqual(manager.profiles.first?.apiUsage, oldAPIUsage)
        XCTAssertEqual(manager.activeProfile?.claudeUsage, oldUsage)
        XCTAssertEqual(manager.activeProfile?.apiUsage, oldAPIUsage)
        XCTAssertEqual(usageFiles.values[profileID]?.claudeUsage, oldUsage)
        XCTAssertEqual(usageFiles.values[profileID]?.apiUsage, oldAPIUsage)

        usageFiles.updateError = nil
        XCTAssertTrue(
            manager.saveClaudeUsage(newUsage, for: profileID)
        )
        XCTAssertTrue(
            manager.saveAPIUsage(newAPIUsage, for: profileID)
        )
        XCTAssertEqual(manager.profiles.first?.claudeUsage, newUsage)
        XCTAssertEqual(manager.profiles.first?.apiUsage, newAPIUsage)
        XCTAssertEqual(manager.activeProfile?.claudeUsage, newUsage)
        XCTAssertEqual(manager.activeProfile?.apiUsage, newAPIUsage)
        XCTAssertEqual(
            usageFiles.values[profileID],
            ProfileCurrentUsage(
                claudeUsage: newUsage,
                apiUsage: newAPIUsage
            )
        )
        XCTAssertFalse(
            manager.saveClaudeUsage(newUsage, for: UUID())
        )
        XCTAssertFalse(
            manager.saveAPIUsage(newAPIUsage, for: UUID())
        )
    }

    @MainActor
    func testRefreshPersistenceCanSuppressActiveProfilePresentation() throws {
        let profileID = UUID()
        let oldClaude = makeClaudeUsage(tokens: 3)
        let newClaude = makeClaudeUsage(tokens: 4)
        let oldAPI = makeAPIUsage(spend: 30)
        let newAPI = makeAPIUsage(spend: 40)
        let usageFiles = MockCurrentUsageFileStore()
        usageFiles.values[profileID] = ProfileCurrentUsage(
            claudeUsage: oldClaude,
            apiUsage: oldAPI
        )
        let store = retain(makeStore(usageFiles: usageFiles))
        try seedProfilesForTesting([
            Profile(id: profileID, name: "Profile")
        ], in: store)
        let runtimeProfile = Profile(
            id: profileID,
            name: "Profile",
            claudeUsage: oldClaude,
            apiUsage: oldAPI
        )
        let manager = retain(
            ProfileManager(
                profileStore: store,
                historyService: retain(MockHistoryDeleter())
            )
        )
        manager.profiles = [runtimeProfile]
        manager.activeProfile = runtimeProfile

        manager.saveClaudeUsage(
            newClaude,
            for: profileID,
            publishToActiveProfile: false
        )
        manager.saveAPIUsage(
            newAPI,
            for: profileID,
            publishToActiveProfile: false
        )

        XCTAssertEqual(manager.profiles[0].claudeUsage, newClaude)
        XCTAssertEqual(manager.profiles[0].apiUsage, newAPI)
        XCTAssertEqual(manager.activeProfile?.claudeUsage, oldClaude)
        XCTAssertEqual(manager.activeProfile?.apiUsage, oldAPI)
        XCTAssertEqual(
            usageFiles.values[profileID],
            ProfileCurrentUsage(
                claudeUsage: newClaude,
                apiUsage: newAPI
            )
        )
    }

    @MainActor
    func testActiveProfileGenerationTracksIdentityTransitionsOnly() {
        let manager = retain(makeIsolatedProfileManager())
        let first = Profile(name: "First")
        let second = Profile(name: "Second")

        manager.activeProfile = first
        let firstGeneration = manager.activeProfileIdentityGeneration
        var sameIdentityUpdate = first
        sameIdentityUpdate.name = "Renamed"
        manager.activeProfile = sameIdentityUpdate
        XCTAssertEqual(
            manager.activeProfileIdentityGeneration,
            firstGeneration
        )

        manager.activeProfile = second
        XCTAssertEqual(
            manager.activeProfileIdentityGeneration,
            firstGeneration + 1
        )
        manager.activeProfile = first
        XCTAssertEqual(
            manager.activeProfileIdentityGeneration,
            firstGeneration + 2
        )
        manager.activeProfile = nil
        XCTAssertEqual(
            manager.activeProfileIdentityGeneration,
            firstGeneration + 3
        )
    }

    @MainActor
    func testClaudeAndAPIUnlinkCredentialReadFailuresPreserveDurableState() throws {
        for component in UnlinkComponent.allCases {
            try assertUnlinkFailurePreservesDurableState(
                component: component,
                failure: .credentialRead
            )
        }
    }

    @MainActor
    func testClaudeAndAPIUnlinkMetadataFailuresPreserveDurableState() throws {
        for component in UnlinkComponent.allCases {
            try assertUnlinkFailurePreservesDurableState(
                component: component,
                failure: .metadataWrite
            )
        }
    }

    @MainActor
    func testClaudeAndAPIUnlinkUsageCleanupFailuresRestoreDurableState() throws {
        for component in UnlinkComponent.allCases {
            try assertUnlinkFailurePreservesDurableState(
                component: component,
                failure: .usageCleanup
            )
        }
    }

    @MainActor
    func testSuccessfulUnlinkNotificationIdentifiesProfileAndComponent() throws {
        for component in UnlinkComponent.allCases {
            let profileID = UUID()
            let claudeUsage = makeClaudeUsage(tokens: 61)
            let apiUsage = makeAPIUsage(spend: 62)
            let backing = FaultingProfileDefaults()
            let secrets = MockSecretStore()
            let usageFiles = MockCurrentUsageFileStore()
            usageFiles.values[profileID] = ProfileCurrentUsage(
                claudeUsage: claudeUsage,
                apiUsage: apiUsage
            )
            let store = retain(
                makeIsolatedProfileStore(
                    defaults: backing,
                    secretStore: secrets,
                    usageFileStore: usageFiles
                )
            )
            try seedProfilesForTesting([
                Profile(
                    id: profileID,
                    name: "Notification",
                    organizationId: "claude-org",
                    apiOrganizationId: "api-org"
                )
            ], in: store)
            secrets.values[
                ProfileSecretLocator(
                    profileID: profileID,
                    field: .claudeSessionKey
                )
            ] = "claude-session"
            secrets.values[
                ProfileSecretLocator(
                    profileID: profileID,
                    field: .apiSessionKey
                )
            ] = "api-session"
            let runtimeProfile = Profile(
                id: profileID,
                name: "Notification",
                claudeSessionKey: "claude-session",
                organizationId: "claude-org",
                apiSessionKey: "api-session",
                apiOrganizationId: "api-org",
                claudeUsage: claudeUsage,
                apiUsage: apiUsage
            )
            let manager = retain(
                ProfileManager(
                    profileStore: store,
                    historyService: retain(MockHistoryDeleter())
                )
            )
            manager.profiles = [runtimeProfile]
            manager.activeProfile = runtimeProfile
            let recorder = CredentialChangeNotificationRecorder()
            let observer = NotificationCenter.default.addObserver(
                forName: .credentialsChanged,
                object: nil,
                queue: nil
            ) { notification in
                recorder.record(notification)
            }

            try component.unlink(using: manager)
            NotificationCenter.default.removeObserver(observer)

            XCTAssertEqual(
                recorder.snapshot(),
                [
                    CredentialChangeNotificationRecord(
                        objectProfileID: profileID,
                        userInfoProfileID: profileID,
                        component: component.markerValue
                    )
                ]
            )
        }
    }

    @MainActor
    func testUnlinkRollbackFailureRecoversCoherentStateAfterRelaunch() throws {
        for component in UnlinkComponent.allCases {
            let profileID = UUID()
            let claudeUsage = makeClaudeUsage(tokens: 64)
            let apiUsage = makeAPIUsage(spend: 305)
            // The transaction commit is the second profiles_v3 write: the
            // load-1 rewrite is the first, and load 2 no longer rewrites now
            // that a refused replay scrubs the retry instead of leaving it on
            // disk for another pass.
            let backing = SequencedProfileWriteFaultDefaults(
                corruptProfileWrite: 2
            )
            let secrets = MockSecretStore()
            var runtimeCredentialRetry =
                ProfileCredentialMigrationRetry()
            runtimeCredentialRetry.setValue(
                "runtime-target-retry",
                for: component.secretField
            )
            runtimeCredentialRetry.setValue(
                "runtime-unrelated-cli",
                for: .cliCredentialsJSON
            )
            backing.storage["profiles_v3"] =
                try legacyProfilesData([
                    (
                        Profile(
                            id: profileID,
                            name: "Profile",
                            organizationId: "claude-org",
                            apiOrganizationId: "api-org",
                            apiSessionKeyExpiry: Date(
                                timeIntervalSinceReferenceDate: 900
                            )
                        ),
                        runtimeCredentialRetry
                    )
                ])
            let usageFiles = MockCurrentUsageFileStore()
            usageFiles.values[profileID] = ProfileCurrentUsage(
                claudeUsage: claudeUsage,
                apiUsage: apiUsage
            )
            let store = retain(
                makeIsolatedProfileStore(
                    defaults: backing,
                    secretStore: secrets,
                    usageFileStore: usageFiles
                )
            )
            let claudeLocator = ProfileSecretLocator(
                profileID: profileID,
                field: .claudeSessionKey
            )
            let apiLocator = ProfileSecretLocator(
                profileID: profileID,
                field: .apiSessionKey
            )
            secrets.values[claudeLocator] = "claude-session"
            secrets.values[apiLocator] = "api-session"
            let runtimeUsageRetry = ProfileCurrentUsage(
                claudeUsage: claudeUsage,
                apiUsage: apiUsage
            )
            let runtimeProfile = Profile(
                id: profileID,
                name: "Profile",
                claudeSessionKey: "claude-session",
                organizationId: "claude-org",
                apiSessionKey: "api-session",
                apiOrganizationId: "api-org",
                apiSessionKeyExpiry: Date(
                    timeIntervalSinceReferenceDate: 900
                ),
                claudeUsage: claudeUsage,
                apiUsage: apiUsage,
                credentialMigrationRetry: runtimeCredentialRetry,
                currentUsageMigrationRetry: runtimeUsageRetry
            )
            let manager = retain(
                ProfileManager(
                    profileStore: store,
                    historyService: retain(MockHistoryDeleter())
                )
            )
            manager.profiles = [runtimeProfile]
            manager.activeProfile = runtimeProfile

            // Force metadata persistence to fail after the secure deletion,
            // the secure rollback write to fail once, and immediate usage
            // reconciliation to fail. The non-secret marker must survive.
            // One migration replay attempt and the subsequent secure
            // rollback both fail, leaving the marker authoritative. The
            // transaction's own mutation is a delete, which spends no write
            // budget.
            secrets.writeErrorCounts[component.secretField] = 2
            usageFiles.saveError = TestFailure.expected
            let notificationRecorder =
                CredentialChangeNotificationRecorder()
            let observer = NotificationCenter.default.addObserver(
                forName: .credentialsChanged,
                object: nil,
                queue: nil
            ) { notification in
                notificationRecorder.record(notification)
            }

            XCTAssertThrowsError(try component.unlink(using: manager)) { error in
                guard case ProfileStoreError
                    .credentialUsageUnlinkRollbackFailed = error else {
                    return XCTFail(
                        "Expected unresolved unlink rollback, got \(error)"
                    )
                }
            }
            NotificationCenter.default.removeObserver(observer)
            XCTAssertEqual(
                notificationRecorder.snapshot(),
                [
                    CredentialChangeNotificationRecord(
                        objectProfileID: profileID,
                        userInfoProfileID: profileID,
                        component: component.markerValue
                    )
                ]
            )
            XCTAssertNil(
                manager.profiles[0].credentialMigrationRetry.value(
                    for: component.secretField
                )
            )
            XCTAssertEqual(
                manager.profiles[0].credentialMigrationRetry
                    .cliCredentialsJSON,
                "runtime-unrelated-cli"
            )
            XCTAssertNil(
                manager.activeProfile?.credentialMigrationRetry.value(
                    for: component.secretField
                )
            )
            switch component {
            case .claude:
                XCTAssertNil(manager.profiles[0].claudeSessionKey)
                XCTAssertNil(manager.profiles[0].organizationId)
                XCTAssertNil(manager.profiles[0].claudeUsage)
                XCTAssertNil(manager.activeProfile?.claudeSessionKey)
                XCTAssertNil(manager.activeProfile?.organizationId)
                XCTAssertNil(manager.activeProfile?.claudeUsage)
                XCTAssertNil(
                    manager.profiles[0].currentUsageMigrationRetry?
                        .claudeUsage
                )
                XCTAssertEqual(
                    manager.profiles[0].apiSessionKey,
                    "api-session"
                )
                XCTAssertEqual(manager.profiles[0].apiUsage, apiUsage)
                XCTAssertEqual(
                    manager.profiles[0].currentUsageMigrationRetry?
                        .apiUsage,
                    apiUsage
                )
            case .api:
                XCTAssertNil(manager.profiles[0].apiSessionKey)
                XCTAssertNil(manager.profiles[0].apiOrganizationId)
                XCTAssertNil(manager.profiles[0].apiSessionKeyExpiry)
                XCTAssertNil(manager.profiles[0].apiUsage)
                XCTAssertNil(manager.activeProfile?.apiSessionKey)
                XCTAssertNil(manager.activeProfile?.apiOrganizationId)
                XCTAssertNil(manager.activeProfile?.apiSessionKeyExpiry)
                XCTAssertNil(manager.activeProfile?.apiUsage)
                XCTAssertNil(
                    manager.profiles[0].currentUsageMigrationRetry?
                        .apiUsage
                )
                XCTAssertEqual(
                    manager.profiles[0].claudeSessionKey,
                    "claude-session"
                )
                XCTAssertEqual(
                    manager.profiles[0].claudeUsage,
                    claudeUsage
                )
                XCTAssertEqual(
                    manager.profiles[0].currentUsageMigrationRetry?
                        .claudeUsage,
                    claudeUsage
                )
            }
            var attemptedWriteBack = manager.profiles
            attemptedWriteBack[0].name = "Must not write back"
            XCTAssertThrowsError(
                try store.saveProfilesThrowing(attemptedWriteBack)
            )
            XCTAssertNil(
                secrets.values[
                    ProfileSecretLocator(
                        profileID: profileID,
                        field: component.secretField
                    )
                ]
            )
            let markerData = try XCTUnwrap(
                backing.data(
                    forKey: "profileCredentialUsageUnlinks_v1"
                )
            )
            let markerText = try XCTUnwrap(
                String(data: markerData, encoding: .utf8)
            )
            XCTAssertFalse(markerText.contains("claude-session"))
            XCTAssertFalse(markerText.contains("api-session"))
            XCTAssertFalse(markerText.contains("previousUsage"))
            XCTAssertFalse(markerText.contains("claudeUsage"))
            XCTAssertFalse(markerText.contains("apiUsage"))

            usageFiles.saveError = nil
            let relaunchedStore = retain(
                makeIsolatedProfileStore(
                    defaults: backing,
                    secretStore: secrets,
                    usageFileStore: usageFiles
                )
            )
            let relaunched = try XCTUnwrap(
                relaunchedStore.loadProfiles().first(where: {
                    $0.id == profileID
                })
            )

            switch component {
            case .claude:
                XCTAssertNil(relaunched.claudeSessionKey)
                XCTAssertNil(relaunched.organizationId)
                XCTAssertNil(relaunched.claudeUsage)
                XCTAssertEqual(relaunched.apiSessionKey, "api-session")
                XCTAssertEqual(relaunched.apiUsage, apiUsage)
            case .api:
                XCTAssertNil(relaunched.apiSessionKey)
                XCTAssertNil(relaunched.apiOrganizationId)
                XCTAssertNil(relaunched.apiUsage)
                XCTAssertEqual(
                    relaunched.claudeSessionKey,
                    "claude-session"
                )
                XCTAssertEqual(relaunched.claudeUsage, claudeUsage)
            }
            XCTAssertNil(
                backing.data(
                    forKey: "profileCredentialUsageUnlinks_v1"
                )
            )
        }
    }

    @MainActor
    func testPendingUnlinkClearsTargetRetryWithoutResurrectingSecret() throws {
        for component in UnlinkComponent.allCases {
            let profileID = UUID()
            let retrySecret = "TARGET_RETRY_\(component.markerValue)"
            var retry = ProfileCredentialMigrationRetry()
            retry.setValue(retrySecret, for: component.secretField)
            let backing = FaultingProfileDefaults()
            backing.set(
                try legacyProfilesData([
                    (
                        Profile(
                            id: profileID,
                            name: "Retry-only target",
                            organizationId: "claude-org",
                            apiOrganizationId: "api-org"
                        ),
                        retry
                    )
                ]),
                forKey: "profiles_v3"
            )
            backing.set(
                try JSONSerialization.data(withJSONObject: [[
                    "profileID": profileID.uuidString,
                    "component": component.markerValue
                ]]),
                forKey: "profileCredentialUsageUnlinks_v1"
            )
            let claudeUsage = makeClaudeUsage(tokens: 31)
            let apiUsage = makeAPIUsage(spend: 32)
            let usageFiles = MockCurrentUsageFileStore()
            usageFiles.values[profileID] = ProfileCurrentUsage(
                claudeUsage: claudeUsage,
                apiUsage: apiUsage
            )
            let secrets = MockSecretStore()
            let store = retain(
                makeIsolatedProfileStore(
                    defaults: backing,
                    secretStore: secrets,
                    usageFileStore: usageFiles
                )
            )

            let loaded = try XCTUnwrap(
                store.loadProfilesWithVerifiedMigration().first
            )

            XCTAssertNil(secrets.values[
                ProfileSecretLocator(
                    profileID: profileID,
                    field: component.secretField
                )
            ])
            let persistedText = try XCTUnwrap(
                backing.data(forKey: "profiles_v3")
                    .flatMap { String(data: $0, encoding: .utf8) }
            )
            XCTAssertFalse(persistedText.contains(retrySecret))
            XCTAssertNil(
                backing.data(
                    forKey: "profileCredentialUsageUnlinks_v1"
                )
            )
            switch component {
            case .claude:
                XCTAssertNil(loaded.claudeSessionKey)
                XCTAssertNil(loaded.organizationId)
                XCTAssertNil(loaded.claudeUsage)
                XCTAssertEqual(loaded.apiUsage, apiUsage)
            case .api:
                XCTAssertNil(loaded.apiSessionKey)
                XCTAssertNil(loaded.apiOrganizationId)
                XCTAssertNil(loaded.apiUsage)
                XCTAssertEqual(loaded.claudeUsage, claudeUsage)
            }
        }
    }

    @MainActor
    func testPendingUnlinkFallbackMasksTargetUntilRecoveryCanPersist() throws {
        for component in UnlinkComponent.allCases {
            let profileID = UUID()
            let targetRetry =
                "TARGET_FALLBACK_\(component.markerValue)"
            let unrelatedRetry = "UNRELATED_FALLBACK_CLI"
            var credentialRetry = ProfileCredentialMigrationRetry()
            credentialRetry.setValue(
                targetRetry,
                for: component.secretField
            )
            credentialRetry.setValue(
                unrelatedRetry,
                for: .cliCredentialsJSON
            )
            let claudeUsage = makeClaudeUsage(tokens: 34)
            let apiUsage = makeAPIUsage(spend: 35)
            let usageRetry = ProfileCurrentUsage(
                claudeUsage: claudeUsage,
                apiUsage: apiUsage
            )
            let expiry = Date(
                timeIntervalSinceReferenceDate: 456_789
            )
            let backing = FaultingProfileDefaults()
            backing.set(
                try legacyProfilesData([
                    (
                        Profile(
                            id: profileID,
                            name: "Fallback identity",
                            organizationId: "claude-org",
                            apiOrganizationId: "api-org",
                            apiSessionKeyExpiry: expiry,
                            currentUsageMigrationRetry: usageRetry
                        ),
                        credentialRetry
                    )
                ]),
                forKey: "profiles_v3"
            )
            backing.set(
                try JSONSerialization.data(withJSONObject: [[
                    "profileID": profileID.uuidString,
                    "component": component.markerValue
                ]]),
                forKey: "profileCredentialUsageUnlinks_v1"
            )
            let usageFiles = MockCurrentUsageFileStore()
            usageFiles.values[profileID] = usageRetry
            let secrets = MockSecretStore()
            let store = retain(
                makeIsolatedProfileStore(
                    defaults: backing,
                    secretStore: secrets,
                    usageFileStore: usageFiles
                )
            )
            backing.corruptNextProfileWrite = true

            let masked = try XCTUnwrap(store.loadProfiles().first)

            XCTAssertEqual(masked.id, profileID)
            XCTAssertEqual(masked.name, "Fallback identity")
            XCTAssertNil(
                masked.credentialMigrationRetry.value(
                    for: component.secretField
                )
            )
            // Adoption at the decode boundary empties the envelope and moves
            // the value into the in-memory hold. Same intent as before — the
            // unrelated credential survives the masking — but it now survives
            // somewhere it is not plaintext on disk.
            XCTAssertNil(masked.credentialMigrationRetry.cliCredentialsJSON)
            XCTAssertTrue(
                store.profilesWithSessionOnlyCredentials.contains(profileID)
            )
            XCTAssertEqual(
                masked.cliCredentialsJSON,
                unrelatedRetry
            )
            switch component {
            case .claude:
                XCTAssertNil(masked.claudeSessionKey)
                XCTAssertNil(masked.organizationId)
                XCTAssertNil(masked.claudeUsage)
                XCTAssertNil(
                    masked.currentUsageMigrationRetry?.claudeUsage
                )
                XCTAssertEqual(masked.apiUsage, apiUsage)
                XCTAssertEqual(
                    masked.currentUsageMigrationRetry?.apiUsage,
                    apiUsage
                )
                XCTAssertEqual(masked.apiOrganizationId, "api-org")
                XCTAssertEqual(masked.apiSessionKeyExpiry, expiry)
            case .api:
                XCTAssertNil(masked.apiSessionKey)
                XCTAssertNil(masked.apiOrganizationId)
                XCTAssertNil(masked.apiSessionKeyExpiry)
                XCTAssertNil(masked.apiUsage)
                XCTAssertNil(
                    masked.currentUsageMigrationRetry?.apiUsage
                )
                XCTAssertEqual(masked.claudeUsage, claudeUsage)
                XCTAssertEqual(
                    masked.currentUsageMigrationRetry?.claudeUsage,
                    claudeUsage
                )
                XCTAssertEqual(masked.organizationId, "claude-org")
            }

            // The fallback is runtime-only. Durable state and the marker stay
            // available for a later verified recovery attempt.
            let retainedText = try XCTUnwrap(
                backing.data(forKey: "profiles_v3")
                    .flatMap { String(data: $0, encoding: .utf8) }
            )
            XCTAssertTrue(retainedText.contains(targetRetry))
            XCTAssertTrue(retainedText.contains(unrelatedRetry))
            XCTAssertNotNil(
                backing.data(
                    forKey: "profileCredentialUsageUnlinks_v1"
                )
            )

            // FaultingProfileDefaults fails one write. The next throwing load
            // must complete forward, retain unrelated state, and remove the
            // marker only after verified persistence.
            let recovered = try XCTUnwrap(
                store.loadProfilesWithVerifiedMigration().first
            )

            XCTAssertNil(
                recovered.credentialMigrationRetry.value(
                    for: component.secretField
                )
            )
            XCTAssertEqual(
                recovered.cliCredentialsJSON,
                unrelatedRetry
            )
            XCTAssertEqual(
                secrets.values[
                    ProfileSecretLocator(
                        profileID: profileID,
                        field: .cliCredentialsJSON
                    )
                ],
                unrelatedRetry
            )
            XCTAssertNil(
                backing.data(
                    forKey: "profileCredentialUsageUnlinks_v1"
                )
            )
            switch component {
            case .claude:
                XCTAssertNil(recovered.claudeSessionKey)
                XCTAssertNil(recovered.organizationId)
                XCTAssertNil(recovered.claudeUsage)
                XCTAssertEqual(recovered.apiUsage, apiUsage)
            case .api:
                XCTAssertNil(recovered.apiSessionKey)
                XCTAssertNil(recovered.apiOrganizationId)
                XCTAssertNil(recovered.apiSessionKeyExpiry)
                XCTAssertNil(recovered.apiUsage)
                XCTAssertEqual(recovered.claudeUsage, claudeUsage)
            }
        }
    }

    @MainActor
    func testForwardRecoveryScrubsTargetUsageRetryBeforeMarkerRemoval() throws {
        for component in UnlinkComponent.allCases {
            let profileID = UUID()
            let claudeUsage = makeClaudeUsage(tokens: 37)
            let apiUsage = makeAPIUsage(spend: 38)
            let usageRetry = ProfileCurrentUsage(
                claudeUsage: claudeUsage,
                apiUsage: apiUsage
            )
            var credentialRetry =
                ProfileCredentialMigrationRetry()
            credentialRetry.setValue(
                "TARGET_CREDENTIAL_RETRY_\(component.markerValue)",
                for: component.secretField
            )
            credentialRetry.setValue(
                "UNRELATED_CREDENTIAL_RETRY",
                for: .cliCredentialsJSON
            )
            let backing = SequencedProfileWriteFaultDefaults(
                corruptProfileWrite: 2
            )
            backing.storage["profiles_v3"] = try legacyProfilesData([
                (
                    Profile(
                        id: profileID,
                        name: "Recovery rewrite",
                        organizationId: "claude-org",
                        apiOrganizationId: "api-org",
                        currentUsageMigrationRetry: usageRetry
                    ),
                    credentialRetry
                )
            ])
            backing.storage[
                "profileCredentialUsageUnlinks_v1"
            ] = try JSONSerialization.data(withJSONObject: [[
                "profileID": profileID.uuidString,
                "component": component.markerValue
            ]])
            let usageFiles = MockCurrentUsageFileStore()
            usageFiles.values[profileID] = usageRetry
            let secrets = MockSecretStore()
            let store = retain(
                makeIsolatedProfileStore(
                    defaults: backing,
                    secretStore: secrets,
                    usageFileStore: usageFiles
                )
            )

            // Recovery profile write #1 succeeds and removes the marker.
            // Ordinary migration rewrite #2 fails and restores write #1.
            let fallback = try XCTUnwrap(store.loadProfiles().first)

            XCTAssertNil(
                backing.data(
                    forKey: "profileCredentialUsageUnlinks_v1"
                )
            )
            let persistedData = try XCTUnwrap(
                backing.data(forKey: "profiles_v3")
            )
            let persisted = try XCTUnwrap(
                JSONDecoder().decode(
                    [Profile].self,
                    from: persistedData
                ).first
            )
            XCTAssertEqual(persisted.id, profileID)
            XCTAssertNil(
                fallback.credentialMigrationRetry.value(
                    for: component.secretField
                )
            )
            XCTAssertNil(
                persisted.credentialMigrationRetry.value(
                    for: component.secretField
                )
            )
            // The unrelated credential is still preserved across recovery —
            // in secure storage now, with no plaintext left in the envelope.
            XCTAssertNil(fallback.credentialMigrationRetry.cliCredentialsJSON)
            XCTAssertNil(persisted.credentialMigrationRetry.cliCredentialsJSON)
            // Not asserted on the decoded models: a plain decode hydrates no
            // secrets, and once adoption has scrubbed the envelope there is
            // nothing plaintext left for it to carry. Secure storage is the
            // only place the value should now be.
            XCTAssertEqual(
                secrets.values[
                    ProfileSecretLocator(
                        profileID: profileID,
                        field: .cliCredentialsJSON
                    )
                ],
                "UNRELATED_CREDENTIAL_RETRY"
            )

            switch component {
            case .claude:
                XCTAssertNil(fallback.claudeSessionKey)
                XCTAssertNil(persisted.claudeSessionKey)
                XCTAssertNil(fallback.organizationId)
                XCTAssertNil(fallback.claudeUsage)
                XCTAssertNil(
                    fallback.currentUsageMigrationRetry?.claudeUsage
                )
                XCTAssertEqual(fallback.apiUsage, apiUsage)
                XCTAssertEqual(
                    fallback.currentUsageMigrationRetry?.apiUsage,
                    apiUsage
                )
                XCTAssertNil(
                    persisted.currentUsageMigrationRetry?.claudeUsage
                )
                XCTAssertEqual(
                    persisted.currentUsageMigrationRetry?.apiUsage,
                    apiUsage
                )
            case .api:
                XCTAssertNil(fallback.apiSessionKey)
                XCTAssertNil(persisted.apiSessionKey)
                XCTAssertNil(fallback.apiOrganizationId)
                XCTAssertNil(fallback.apiUsage)
                XCTAssertNil(
                    fallback.currentUsageMigrationRetry?.apiUsage
                )
                XCTAssertEqual(fallback.claudeUsage, claudeUsage)
                XCTAssertEqual(
                    fallback.currentUsageMigrationRetry?.claudeUsage,
                    claudeUsage
                )
                XCTAssertNil(
                    persisted.currentUsageMigrationRetry?.apiUsage
                )
                XCTAssertEqual(
                    persisted.currentUsageMigrationRetry?.claudeUsage,
                    claudeUsage
                )
            }

            let relaunched = retain(
                makeIsolatedProfileStore(
                    defaults: backing,
                    secretStore: secrets,
                    usageFileStore: usageFiles
                )
            )
            let recovered = try XCTUnwrap(
                relaunched.loadProfilesWithVerifiedMigration().first
            )

            XCTAssertNil(
                recovered.credentialMigrationRetry.value(
                    for: component.secretField
                )
            )
            XCTAssertEqual(
                recovered.cliCredentialsJSON,
                "UNRELATED_CREDENTIAL_RETRY"
            )
            XCTAssertEqual(
                secrets.values[
                    ProfileSecretLocator(
                        profileID: profileID,
                        field: .cliCredentialsJSON
                    )
                ],
                "UNRELATED_CREDENTIAL_RETRY"
            )
            XCTAssertNil(
                secrets.values[
                    ProfileSecretLocator(
                        profileID: profileID,
                        field: component.secretField
                    )
                ]
            )
            switch component {
            case .claude:
                XCTAssertNil(recovered.claudeSessionKey)
                XCTAssertNil(recovered.claudeUsage)
                XCTAssertEqual(recovered.apiUsage, apiUsage)
            case .api:
                XCTAssertNil(recovered.apiSessionKey)
                XCTAssertNil(recovered.apiUsage)
                XCTAssertEqual(recovered.claudeUsage, claudeUsage)
            }
        }
    }

    @MainActor
    func testUnlinkHoldsUnrelatedRefusedCredentialInMemoryNeverOnDisk() throws {
        for component in UnlinkComponent.allCases {
            let profileID = UUID()
            let targetSecret = "TARGET_\(component.markerValue)"
            let unrelatedRetry = "UNRELATED_CLI_RETRY"
            var retry = ProfileCredentialMigrationRetry()
            retry.setValue(
                unrelatedRetry,
                for: .cliCredentialsJSON
            )
            let backing = FaultingProfileDefaults()
            backing.set(
                try legacyProfilesData([
                    (
                        Profile(
                            id: profileID,
                            name: "Unrelated retry",
                            organizationId: "claude-org",
                            apiOrganizationId: "api-org"
                        ),
                        retry
                    )
                ]),
                forKey: "profiles_v3"
            )
            let secrets = MockSecretStore()
            let targetLocator = ProfileSecretLocator(
                profileID: profileID,
                field: component.secretField
            )
            secrets.values[targetLocator] = targetSecret
            // Sticky, not a budget. Adoption now runs at every decode, so a
            // counted budget makes "is it still refused?" depend on how many
            // times the flow happened to decode — the drift that made the
            // earlier counter-based fixtures wrong. The intent here is
            // "secure storage will not take this", so say exactly that.
            secrets.writeErrors[.cliCredentialsJSON] = TestFailure.expected
            let usageFiles = MockCurrentUsageFileStore()
            usageFiles.values[profileID] = ProfileCurrentUsage(
                claudeUsage: makeClaudeUsage(tokens: 41),
                apiUsage: makeAPIUsage(spend: 42)
            )
            let store = retain(
                makeIsolatedProfileStore(
                    defaults: backing,
                    secretStore: secrets,
                    usageFileStore: usageFiles
                )
            )

            try component.unlink(using: store, profileID: profileID)

            XCTAssertNil(secrets.values[targetLocator])
            let cliLocator = ProfileSecretLocator(
                profileID: profileID,
                field: .cliCredentialsJSON
            )
            let pendingText = try XCTUnwrap(
                backing.data(forKey: "profiles_v3")
                    .flatMap { String(data: $0, encoding: .utf8) }
            )
            // The core of the new contract: a credential secure storage
            // refused is never written to preferences.
            XCTAssertFalse(pendingText.contains(unrelatedRetry))
            XCTAssertNil(secrets.values[cliLocator])
            XCTAssertTrue(
                store.profilesWithSessionOnlyCredentials.contains(profileID),
                "Held in memory, usable now, and the UI has to be able to say so"
            )

            // Same process, next load: the self-heal writes it to secure
            // storage once the store stops refusing.
            secrets.writeErrors.removeValue(forKey: .cliCredentialsJSON)
            let healed = try XCTUnwrap(
                store.loadProfilesWithVerifiedMigration().first
            )
            XCTAssertEqual(healed.cliCredentialsJSON, unrelatedRetry)
            XCTAssertEqual(secrets.values[cliLocator], unrelatedRetry)
            XCTAssertFalse(
                store.profilesWithSessionOnlyCredentials.contains(profileID)
            )

            let relaunchedStore = retain(
                makeIsolatedProfileStore(
                    defaults: backing,
                    secretStore: secrets,
                    usageFileStore: usageFiles
                )
            )
            let relaunched = try XCTUnwrap(
                relaunchedStore.loadProfilesWithVerifiedMigration().first
            )

            // After a real relaunch the value is back from secure storage,
            // not from preferences.
            XCTAssertNil(secrets.values[targetLocator])
            XCTAssertEqual(
                relaunched.cliCredentialsJSON,
                unrelatedRetry
            )
            XCTAssertEqual(secrets.values[cliLocator], unrelatedRetry)
            let recoveredText = try XCTUnwrap(
                backing.data(forKey: "profiles_v3")
                    .flatMap { String(data: $0, encoding: .utf8) }
            )
            XCTAssertFalse(recoveredText.contains(unrelatedRetry))
        }
    }

    @MainActor
    func testProfileDeletionFailureRetainsIdentityAndSuccessRemovesAllData() throws {
        let deletedID = UUID()
        let retainedID = UUID()
        let claudeUsage = makeClaudeUsage(tokens: 80)
        let apiUsage = makeAPIUsage(spend: 80)
        let secrets = MockSecretStore()
        let usageFiles = MockCurrentUsageFileStore()
        usageFiles.values[deletedID] = ProfileCurrentUsage(
            claudeUsage: claudeUsage,
            apiUsage: apiUsage
        )
        let store = retain(makeStore(usageFiles: usageFiles, secrets: secrets))
        let initialProfiles = [
            Profile(
                id: deletedID,
                name: "Delete",
                claudeSessionKey: "claude-secret",
                apiSessionKey: "api-secret",
                cliCredentialsJSON: "cli-secret",
                claudeUsage: claudeUsage,
                apiUsage: apiUsage
            ),
            Profile(id: retainedID, name: "Keep")
        ]
        try seedProfilesForTesting(initialProfiles, in: store)
        let history = retain(MockHistoryDeleter())
        let manager = retain(
            ProfileManager(profileStore: store, historyService: history)
        )
        manager.profiles = initialProfiles
        manager.activeProfile = initialProfiles[0]
        usageFiles.deleteError = TestFailure.expected

        XCTAssertThrowsError(try manager.deleteProfile(deletedID))
        XCTAssertEqual(manager.profiles.map(\.id), initialProfiles.map(\.id))
        XCTAssertEqual(try persistedProfileIDs(), initialProfiles.map(\.id))
        XCTAssertNil(manager.profiles[0].claudeSessionKey)
        XCTAssertNil(manager.profiles[0].apiSessionKey)
        XCTAssertNil(manager.profiles[0].cliCredentialsJSON)
        XCTAssertNil(manager.activeProfile?.claudeSessionKey)
        XCTAssertNil(manager.profiles[0].claudeUsage)
        XCTAssertNil(manager.profiles[0].apiUsage)
        XCTAssertTrue(manager.profiles[0].deletionInProgress)
        XCTAssertNotNil(usageFiles.values[deletedID])

        usageFiles.deleteError = nil
        try manager.deleteProfile(deletedID)

        XCTAssertEqual(manager.profiles.map(\.id), [retainedID])
        XCTAssertEqual(try persistedProfileIDs(), [retainedID])
        XCTAssertNil(usageFiles.values[deletedID])
        XCTAssertTrue(history.deletedProfileIDs.contains(deletedID))
    }

    @MainActor
    func testHistoryDeletionFailureRetainsIdentityWithSecretsScrubbed() throws {
        let deletedID = UUID()
        let retainedID = UUID()
        let usage = makeClaudeUsage(tokens: 61)
        let secrets = MockSecretStore()
        let usageFiles = MockCurrentUsageFileStore()
        usageFiles.values[deletedID] = ProfileCurrentUsage(claudeUsage: usage)
        let store = retain(makeStore(usageFiles: usageFiles, secrets: secrets))
        let initialProfiles = [
            Profile(
                id: deletedID,
                name: "Delete",
                claudeSessionKey: "claude-secret",
                apiSessionKey: "api-secret",
                cliCredentialsJSON: "cli-secret",
                claudeUsage: usage
            ),
            Profile(id: retainedID, name: "Keep")
        ]
        try seedProfilesForTesting(initialProfiles, in: store)
        let history = retain(MockHistoryDeleter())
        history.deleteError = TestFailure.expected
        let manager = retain(
            ProfileManager(profileStore: store, historyService: history)
        )
        manager.profiles = initialProfiles
        manager.activeProfile = initialProfiles[0]

        XCTAssertThrowsError(try manager.deleteProfile(deletedID))

        XCTAssertEqual(manager.profiles.map(\.id), initialProfiles.map(\.id))
        XCTAssertNil(manager.profiles[0].claudeSessionKey)
        XCTAssertNil(manager.profiles[0].apiSessionKey)
        XCTAssertNil(manager.profiles[0].cliCredentialsJSON)
        XCTAssertNil(manager.activeProfile?.claudeSessionKey)
        XCTAssertNil(manager.profiles[0].claudeUsage)
        XCTAssertEqual(usageFiles.values[deletedID]?.claudeUsage, usage)
        XCTAssertEqual(usageFiles.deleteAllCount, 0)
        for field in ProfileSecretField.allCases {
            XCTAssertNil(
                secrets.values[ProfileSecretLocator(
                    profileID: deletedID,
                    field: field
                )]
            )
        }
    }

    @MainActor
    func testDeletionMarkerFailureDoesNotStartDestructiveCleanup() throws {
        let deletedID = UUID()
        let retainedID = UUID()
        let usage = makeClaudeUsage(tokens: 71)
        let backing = FaultingProfileDefaults()
        let secrets = MockSecretStore()
        let usageFiles = MockCurrentUsageFileStore()
        usageFiles.values[deletedID] = ProfileCurrentUsage(claudeUsage: usage)
        let store = retain(
            makeIsolatedProfileStore(
                defaults: backing,
                secretStore: secrets,
                usageFileStore: usageFiles
            )
        )
        let initialProfiles = [
            Profile(
                id: deletedID,
                name: "Delete",
                claudeSessionKey: "claude-secret",
                apiSessionKey: "api-secret",
                cliCredentialsJSON: "cli-secret",
                claudeUsage: usage
            ),
            Profile(id: retainedID, name: "Keep")
        ]
        try seedProfilesForTesting(initialProfiles, in: store)
        let history = retain(MockHistoryDeleter())
        let manager = retain(
            ProfileManager(profileStore: store, historyService: history)
        )
        manager.profiles = initialProfiles
        manager.activeProfile = initialProfiles[0]
        backing.corruptNextProfileWrite = true

        XCTAssertThrowsError(try manager.deleteProfile(deletedID))

        XCTAssertEqual(manager.profiles.map(\.id), initialProfiles.map(\.id))
        XCTAssertEqual(manager.profiles[0].claudeSessionKey, "claude-secret")
        XCTAssertEqual(manager.profiles[0].apiSessionKey, "api-secret")
        XCTAssertEqual(manager.profiles[0].cliCredentialsJSON, "cli-secret")
        XCTAssertEqual(manager.profiles[0].claudeUsage, usage)
        XCTAssertEqual(manager.activeProfile?.claudeUsage, usage)
        XCTAssertNotNil(usageFiles.values[deletedID])
        XCTAssertEqual(usageFiles.deleteAllCount, 0)
        XCTAssertTrue(history.deletedProfileIDs.isEmpty)
        let persistedData = try XCTUnwrap(backing.data(forKey: "profiles_v3"))
        XCTAssertEqual(
            try JSONDecoder().decode([Profile].self, from: persistedData).map(\.id),
            initialProfiles.map(\.id)
        )
    }

    @MainActor
    func testPartialDeletionCannotResurrectPersistedRetryEnvelopesAfterRelaunch() throws {
        let deletedID = UUID()
        let retainedID = UUID()
        let retryUsage = ProfileCurrentUsage(
            claudeUsage: makeClaudeUsage(tokens: 93),
            apiUsage: makeAPIUsage(spend: 93)
        )
        let retryProfile = Profile(
            id: deletedID,
            name: "Delete",
            claudeSessionKey: "RETRY_CLAUDE_FIXTURE",
            apiSessionKey: "RETRY_API_FIXTURE",
            cliCredentialsJSON: "RETRY_CLI_FIXTURE",
            claudeUsage: retryUsage.claudeUsage,
            apiUsage: retryUsage.apiUsage,
            credentialMigrationRetry: ProfileCredentialMigrationRetry(
                claudeSessionKey: "RETRY_CLAUDE_FIXTURE",
                apiSessionKey: "RETRY_API_FIXTURE",
                cliCredentialsJSON: "RETRY_CLI_FIXTURE"
            ),
            currentUsageMigrationRetry: retryUsage
        )
        defaults.set(
            try JSONEncoder().encode([
                retryProfile,
                Profile(id: retainedID, name: "Keep")
            ]),
            forKey: "profiles_v3"
        )

        let secrets = MockSecretStore()
        for field in ProfileSecretField.allCases {
            secrets.values[ProfileSecretLocator(
                profileID: deletedID,
                field: field
            )] = "BACKING_\(field.rawValue)"
        }
        secrets.deleteErrors[.apiSessionKey] = TestFailure.expected
        let usageFiles = MockCurrentUsageFileStore()
        let store = retain(makeStore(usageFiles: usageFiles, secrets: secrets))
        let history = retain(MockHistoryDeleter())
        let manager = retain(
            ProfileManager(profileStore: store, historyService: history)
        )
        manager.profiles = [retryProfile, Profile(id: retainedID, name: "Keep")]
        manager.activeProfile = retryProfile

        XCTAssertThrowsError(try manager.deleteProfile(deletedID))
        let retained = try XCTUnwrap(
            manager.profiles.first(where: { $0.id == deletedID })
        )
        XCTAssertTrue(retained.deletionInProgress)
        XCTAssertNil(retained.claudeSessionKey)
        XCTAssertNil(retained.apiSessionKey)
        XCTAssertNil(retained.cliCredentialsJSON)
        XCTAssertNil(retained.claudeUsage)
        XCTAssertNil(retained.apiUsage)

        let persisted = try persistedProfileText()
        XCTAssertTrue(persisted.contains("\"deletionInProgress\""))
        XCTAssertFalse(persisted.contains("credentialMigrationRetry"))
        XCTAssertFalse(persisted.contains("currentUsageMigrationRetry"))
        XCTAssertFalse(persisted.contains("RETRY_"))

        let writesBeforeRelaunch = secrets.writeCount
        let relaunchedStore = retain(
            makeStore(usageFiles: usageFiles, secrets: secrets)
        )
        let relaunched = relaunchedStore.loadProfiles()
        let relaunchedDeleted = try XCTUnwrap(
            relaunched.first(where: { $0.id == deletedID })
        )
        XCTAssertTrue(relaunchedDeleted.deletionInProgress)
        XCTAssertNil(relaunchedDeleted.claudeSessionKey)
        XCTAssertNil(relaunchedDeleted.apiSessionKey)
        XCTAssertNil(relaunchedDeleted.cliCredentialsJSON)
        XCTAssertNil(relaunchedDeleted.claudeUsage)
        XCTAssertNil(relaunchedDeleted.apiUsage)
        XCTAssertEqual(secrets.writeCount, writesBeforeRelaunch)
        XCTAssertEqual(usageFiles.saveCount, 0)

        secrets.deleteErrors.removeValue(forKey: .apiSessionKey)
        let relaunchedManager = retain(
            ProfileManager(
                profileStore: relaunchedStore,
                historyService: history
            )
        )
        relaunchedManager.profiles = relaunched
        relaunchedManager.activeProfile = relaunchedDeleted
        try relaunchedManager.deleteProfile(deletedID)

        XCTAssertEqual(relaunchedManager.profiles.map(\.id), [retainedID])
        for field in ProfileSecretField.allCases {
            XCTAssertNil(secrets.values[ProfileSecretLocator(
                profileID: deletedID,
                field: field
            )])
        }
    }

    @MainActor
    private func makeStore(
        usageFiles: MockCurrentUsageFileStore,
        secrets: MockSecretStore = MockSecretStore()
    ) -> ProfileStore {
        makeIsolatedProfileStore(
            defaults: defaults,
            secretStore: secrets,
            usageFileStore: usageFiles
        )
    }

    @MainActor
    private func seedLegacyUsageProfile(
        id: UUID,
        claude: ClaudeUsage,
        api: APIUsage
    ) {
        let legacy = LegacyUsageProfile(
            id: id,
            name: "Legacy",
            claudeUsage: claude,
            apiUsage: api
        )
        defaults.set(try! JSONEncoder().encode([legacy]), forKey: "profiles_v3")
    }

    private func persistedProfileText() throws -> String {
        let data = try XCTUnwrap(defaults.data(forKey: "profiles_v3"))
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func persistedProfileIDs() throws -> [UUID] {
        let data = try XCTUnwrap(defaults.data(forKey: "profiles_v3"))
        return try JSONDecoder().decode([Profile].self, from: data).map(\.id)
    }

    private func makeClaudeUsage(tokens: Int) -> ClaudeUsage {
        var usage = ClaudeUsage.empty
        usage.sessionTokensUsed = tokens
        usage.sessionPercentage = Double(tokens)
        usage.lastUpdated = Date(timeIntervalSinceReferenceDate: Double(tokens))
        return usage
    }

    private func makeAPIUsage(spend: Int) -> APIUsage {
        APIUsage(
            currentSpendCents: spend,
            resetsAt: Date(timeIntervalSinceReferenceDate: 500),
            prepaidCreditsCents: 1_000,
            currency: "USD",
            apiTokenCostCents: nil,
            apiCostByModel: nil,
            costBySource: nil,
            dailyCostCents: nil
        )
    }

    private func makeReport(
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

    @MainActor
    private func assertUnlinkFailurePreservesDurableState(
        component: UnlinkComponent,
        failure: UnlinkFailure
    ) throws {
        defaults.removePersistentDomain(forName: suiteName)
        let profileID = UUID()
        let claudeUsage = makeClaudeUsage(tokens: 54)
        let apiUsage = makeAPIUsage(spend: 205)
        let secrets = MockSecretStore()
        let usageFiles = MockCurrentUsageFileStore()
        usageFiles.values[profileID] = ProfileCurrentUsage(
            claudeUsage: claudeUsage,
            apiUsage: apiUsage
        )
        let faultingDefaults = failure == .metadataWrite
            ? FaultingProfileDefaults()
            : nil
        let profileDefaults: any ProfileDefaultsStore =
            faultingDefaults ?? defaults
        let store = retain(
            makeIsolatedProfileStore(
                defaults: profileDefaults,
                secretStore: secrets,
                usageFileStore: usageFiles
            )
        )
        try seedProfilesForTesting([
            Profile(
                id: profileID,
                name: "Profile",
                organizationId: "claude-org",
                apiOrganizationId: "api-org"
            )
        ], in: store)
        let claudeLocator = ProfileSecretLocator(
            profileID: profileID,
            field: .claudeSessionKey
        )
        let apiLocator = ProfileSecretLocator(
            profileID: profileID,
            field: .apiSessionKey
        )
        secrets.values[claudeLocator] = "claude-session"
        secrets.values[apiLocator] = "api-session"
        let runtimeProfile = Profile(
            id: profileID,
            name: "Profile",
            claudeSessionKey: "claude-session",
            organizationId: "claude-org",
            apiSessionKey: "api-session",
            apiOrganizationId: "api-org",
            claudeUsage: claudeUsage,
            apiUsage: apiUsage
        )
        let manager = retain(
            ProfileManager(
                profileStore: store,
                historyService: retain(MockHistoryDeleter())
            )
        )
        manager.profiles = [runtimeProfile]
        manager.activeProfile = runtimeProfile

        switch failure {
        case .credentialRead:
            secrets.readErrors[component.secretField] = TestFailure.expected
        case .metadataWrite:
            faultingDefaults?.corruptNextProfileWrite = true
        case .usageCleanup:
            usageFiles.updateError = TestFailure.expected
        }

        let notificationRecorder =
            CredentialChangeNotificationRecorder()
        let observer = NotificationCenter.default.addObserver(
            forName: .credentialsChanged,
            object: nil,
            queue: nil
        ) { notification in
            notificationRecorder.record(notification)
        }
        XCTAssertThrowsError(try component.unlink(using: manager))
        NotificationCenter.default.removeObserver(observer)
        XCTAssertTrue(notificationRecorder.snapshot().isEmpty)

        // Reopen the stores after removing only the injected fault. The
        // invariant is durable: no credential/usage half-state is accepted.
        secrets.readErrors.removeAll()
        usageFiles.updateError = nil
        let relaunchedStore = retain(
            makeIsolatedProfileStore(
                defaults: profileDefaults,
                secretStore: secrets,
                usageFileStore: usageFiles
            )
        )
        let relaunched = try XCTUnwrap(
            relaunchedStore.loadProfiles().first(where: { $0.id == profileID })
        )

        XCTAssertEqual(relaunched.claudeSessionKey, "claude-session")
        XCTAssertEqual(relaunched.organizationId, "claude-org")
        XCTAssertEqual(relaunched.apiSessionKey, "api-session")
        XCTAssertEqual(relaunched.apiOrganizationId, "api-org")
        XCTAssertEqual(relaunched.claudeUsage, claudeUsage)
        XCTAssertEqual(relaunched.apiUsage, apiUsage)
        XCTAssertEqual(manager.activeProfile?.claudeSessionKey, "claude-session")
        XCTAssertEqual(manager.activeProfile?.apiSessionKey, "api-session")
        XCTAssertEqual(manager.activeProfile?.claudeUsage, claudeUsage)
        XCTAssertEqual(manager.activeProfile?.apiUsage, apiUsage)
    }

}

private enum UnlinkComponent: CaseIterable {
    case claude
    case api

    var secretField: ProfileSecretField {
        switch self {
        case .claude:
            return .claudeSessionKey
        case .api:
            return .apiSessionKey
        }
    }

    var markerValue: String {
        switch self {
        case .claude:
            return "claude"
        case .api:
            return "api"
        }
    }

    func unlink(
        using store: ProfileStore,
        profileID: UUID
    ) throws {
        switch self {
        case .claude:
            try store.unlinkClaudeAI(for: profileID)
        case .api:
            try store.unlinkAPIConsole(for: profileID)
        }
    }

    @MainActor
    func unlink(using manager: ProfileManager) throws {
        switch self {
        case .claude:
            try manager.removeClaudeAICredentials(for: manager.profiles[0].id)
        case .api:
            try manager.removeAPICredentials(for: manager.profiles[0].id)
        }
    }
}

private enum UnlinkFailure {
    case credentialRead
    case metadataWrite
    case usageCleanup
}

private struct LegacyUsageProfile: Encodable {
    let id: UUID
    let name: String
    let claudeUsage: ClaudeUsage
    let apiUsage: APIUsage
}

private enum TestFailure: Error {
    case expected
}

private final class MockCurrentUsageFileStore: ProfileCurrentUsageFileStoring {
    var values: [UUID: ProfileCurrentUsage] = [:]
    var loadErrors: [UUID: Error] = [:]
    var saveError: Error?
    var updateError: Error?
    var deleteError: Error?
    var onSave: (() -> Void)?
    var updateCount = 0
    var deleteAllCount = 0
    var saveCount = 0

    func loadCurrentUsage(for profileID: UUID) throws -> ProfileCurrentUsage? {
        if let error = loadErrors[profileID] {
            throw error
        }
        return values[profileID]
    }

    func saveCurrentUsage(_ usage: ProfileCurrentUsage, for profileID: UUID) throws {
        saveCount += 1
        if let saveError {
            throw saveError
        }
        values[profileID] = usage
        let hook = onSave
        onSave = nil
        hook?()
        guard try loadCurrentUsage(for: profileID) == usage else {
            throw TestFailure.expected
        }
    }

    @discardableResult
    func updateCurrentUsage(
        for profileID: UUID,
        transform: (inout ProfileCurrentUsage) throws -> Void
    ) throws -> ProfileCurrentUsage {
        updateCount += 1
        if let updateError {
            throw updateError
        }
        var usage = try loadCurrentUsage(for: profileID) ?? ProfileCurrentUsage()
        try transform(&usage)
        values[profileID] = usage
        let hook = onSave
        onSave = nil
        hook?()
        return usage
    }

    func deleteCurrentUsage(for profileID: UUID) throws {
        if let deleteError {
            throw deleteError
        }
        values.removeValue(forKey: profileID)
    }

    func deleteAllData(for profileID: UUID) throws {
        deleteAllCount += 1
        if let deleteError {
            throw deleteError
        }
        values.removeValue(forKey: profileID)
    }
}

private final class MockSecretStore: ProfileSecretStore {
    var values: [ProfileSecretLocator: String] = [:]
    var readErrors: [ProfileSecretField: Error] = [:]
    var deleteErrors: [ProfileSecretField: Error] = [:]
    /// Sticky, unlike `writeErrorCounts`. Use this when the intent is
    /// "secure storage will not take this field" rather than "the next N
    /// attempts fail" — a counted budget makes assertions depend on how many
    /// times the flow happens to write, which drifts as call paths change.
    var writeErrors: [ProfileSecretField: Error] = [:]
    var writeErrorCounts: [ProfileSecretField: Int] = [:]
    var writeCount = 0

    func read(_ locator: ProfileSecretLocator) throws -> ProfileSecretReadResult {
        if let error = readErrors[locator.field] {
            throw error
        }
        return values[locator].map(ProfileSecretReadResult.value) ?? .absent
    }

    func write(_ value: String, to locator: ProfileSecretLocator) throws {
        if let error = writeErrors[locator.field] {
            throw error
        }
        if let count = writeErrorCounts[locator.field], count > 0 {
            writeErrorCounts[locator.field] = count - 1
            throw TestFailure.expected
        }
        writeCount += 1
        values[locator] = value
    }

    func delete(_ locator: ProfileSecretLocator) throws {
        if let error = deleteErrors[locator.field] {
            throw error
        }
        values.removeValue(forKey: locator)
    }
}

private final class SequencedProfileWriteFaultDefaults:
    ProfileDefaultsStore {
    var storage: [String: Any] = [:]
    private let corruptProfileWrite: Int
    private var profileWriteCount = 0

    init(corruptProfileWrite: Int) {
        self.corruptProfileWrite = corruptProfileWrite
    }

    func data(forKey defaultName: String) -> Data? {
        storage[defaultName] as? Data
    }

    func string(forKey defaultName: String) -> String? {
        storage[defaultName] as? String
    }

    func set(_ value: Any?, forKey defaultName: String) {
        if defaultName == "profiles_v3" {
            profileWriteCount += 1
            if profileWriteCount == corruptProfileWrite {
                storage[defaultName] = Data("corrupt".utf8)
                return
            }
        }
        storage[defaultName] = value
    }

    func removeObject(forKey defaultName: String) {
        storage.removeValue(forKey: defaultName)
    }
}

private struct CredentialChangeNotificationRecord: Equatable {
    let objectProfileID: UUID?
    let userInfoProfileID: UUID?
    let component: String?
}

private final class CredentialChangeNotificationRecorder:
    @unchecked Sendable {
    private let lock = NSLock()
    private var records: [CredentialChangeNotificationRecord] = []

    func record(_ notification: Notification) {
        let record = CredentialChangeNotificationRecord(
            objectProfileID: notification.object as? UUID,
            userInfoProfileID:
                notification.userInfo?["profileID"] as? UUID,
            component:
                notification.userInfo?["component"] as? String
        )
        lock.lock()
        records.append(record)
        lock.unlock()
    }

    func snapshot() -> [CredentialChangeNotificationRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }
}

@MainActor
private final class MockHistoryDeleter: ProfileHistoryDeleting {
    var deleteError: Error?
    var deletedProfileIDs: [UUID] = []

    func deleteHistoryThrowing(for profileId: UUID) throws {
        if let deleteError {
            throw deleteError
        }
        deletedProfileIDs.append(profileId)
    }
}
