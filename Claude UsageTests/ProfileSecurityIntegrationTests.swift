import XCTest
@testable import Claude_Usage

final class ProfileSecurityIntegrationTests: HostedAppTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let (testDefaults, testSuiteName) = try HostedTestDefaults.defaults(
            "ClaudeUsageTests.ProfileSecurity"
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
    func testProfileEncodingOmitsLegacySecretKeysAndPreservesMetadata() throws {
        let expiry = Date(timeIntervalSinceReferenceDate: 123_456)
        let profile = Profile(
            name: "Metadata",
            claudeSessionKey: "CLAUDE_FIXTURE_SECRET",
            organizationId: "org",
            apiSessionKey: "API_FIXTURE_SECRET",
            apiOrganizationId: "api-org",
            apiSessionKeyExpiry: expiry,
            cliCredentialsJSON: "CLI_FIXTURE_SECRET",
            hasCliAccount: true,
            cliAccountSyncedAt: expiry,
            cliAccountName: "linked-account"
        )

        let data = try JSONEncoder().encode(profile)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertNil(object["claudeSessionKey"])
        XCTAssertNil(object["apiSessionKey"])
        XCTAssertNil(object["cliCredentialsJSON"])
        XCTAssertNil(object["credentialMigrationRetry"])
        XCTAssertEqual(object["cliAccountName"] as? String, "linked-account")

        let decoded = try JSONDecoder().decode(Profile.self, from: data)
        XCTAssertEqual(decoded.apiSessionKeyExpiry, expiry)
        XCTAssertEqual(decoded.cliAccountName, "linked-account")
    }

    func testHostedUnitTestLaunchGuardIsActive() {
        XCTAssertTrue(AppDelegate.isRunningHostedUnitTests)
    }

    @MainActor
    /// Decoding a legacy record still recovers every secret — that is what
    /// makes an existing install rescuable — but re-encoding emits none of
    /// them, in any shape. The old contract re-emitted them as an explicit
    /// envelope, which is precisely the behaviour being retired.
    func testLegacyProfileDecodesEverySecretAndReencodesNone() throws {
        let id = UUID()
        let legacyObject: [[String: Any]] = [[
            "id": id.uuidString,
            "name": "Legacy",
            "claudeSessionKey": "LEGACY_CLAUDE_FIXTURE",
            "apiSessionKey": "LEGACY_API_FIXTURE",
            "cliCredentialsJSON": "LEGACY_CLI_FIXTURE",
            "cliAccountName": "legacy-link",
            "apiSessionKeyExpiry": 99.0
        ]]
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)

        let decoded = try JSONDecoder().decode([Profile].self, from: legacyData)
        XCTAssertEqual(decoded.first?.claudeSessionKey, "LEGACY_CLAUDE_FIXTURE")
        XCTAssertEqual(decoded.first?.apiSessionKey, "LEGACY_API_FIXTURE")
        XCTAssertEqual(decoded.first?.cliCredentialsJSON, "LEGACY_CLI_FIXTURE")

        let rewritten = try JSONEncoder().encode(decoded)
        let text = try XCTUnwrap(String(data: rewritten, encoding: .utf8))
        XCTAssertFalse(text.contains("\"claudeSessionKey\""))
        XCTAssertFalse(text.contains("\"apiSessionKey\""))
        XCTAssertFalse(text.contains("\"cliCredentialsJSON\""))
        XCTAssertFalse(text.contains("\"credentialMigrationRetry\""))
        // By value, not just by key: a secret must not survive a round trip
        // under any name.
        XCTAssertFalse(text.contains("LEGACY_CLAUDE_FIXTURE"))
        XCTAssertFalse(text.contains("LEGACY_API_FIXTURE"))
        XCTAssertFalse(text.contains("LEGACY_CLI_FIXTURE"))
    }

    func testSuccessfulLegacyMigrationScrubsAllPlaintext() throws {
        let profileID = UUID()
        seedLegacyProfile(
            id: profileID,
            claude: "SUCCESS_CLAUDE_FIXTURE",
            api: "SUCCESS_API_FIXTURE",
            cli: "SUCCESS_CLI_FIXTURE"
        )
        let secrets = MockProfileSecretStore()
        let store = retain(makeIsolatedProfileStore(defaults: defaults, secretStore: secrets))

        let profiles = try store.loadProfilesWithVerifiedMigration()

        XCTAssertEqual(profiles.first?.claudeSessionKey, "SUCCESS_CLAUDE_FIXTURE")
        XCTAssertEqual(profiles.first?.apiSessionKey, "SUCCESS_API_FIXTURE")
        XCTAssertEqual(profiles.first?.cliCredentialsJSON, "SUCCESS_CLI_FIXTURE")
        let persisted = try persistedProfileText()
        XCTAssertFalse(persisted.contains("SUCCESS_CLAUDE_FIXTURE"))
        XCTAssertFalse(persisted.contains("SUCCESS_API_FIXTURE"))
        XCTAssertFalse(persisted.contains("SUCCESS_CLI_FIXTURE"))
        XCTAssertFalse(persisted.contains("credentialMigrationRetry"))
    }

    /// A field the Keychain refuses is held in memory for the session. It used
    /// to be written back into preferences as plaintext, which is how live
    /// session keys ended up in `~/Library/Preferences`.
    func testRefusedMigrationHoldsFieldInMemoryAndNeverOnDisk() throws {
        let profileID = UUID()
        seedLegacyProfile(
            id: profileID,
            claude: "PARTIAL_CLAUDE_FIXTURE",
            api: "PARTIAL_API_FIXTURE",
            cli: "PARTIAL_CLI_FIXTURE"
        )
        let secrets = MockProfileSecretStore()
        secrets.writeErrors[.apiSessionKey] = TestError.expected
        let store = retain(makeIsolatedProfileStore(defaults: defaults, secretStore: secrets))

        let profiles = try store.loadProfilesWithVerifiedMigration()

        XCTAssertEqual(
            profiles.first?.apiSessionKey,
            "PARTIAL_API_FIXTURE",
            "The session must keep working with the credential in memory"
        )
        let persisted = try persistedProfileText()
        XCTAssertFalse(persisted.contains("PARTIAL_CLAUDE_FIXTURE"))
        XCTAssertFalse(
            persisted.contains("PARTIAL_API_FIXTURE"),
            "A refused credential must never be written to preferences"
        )
        XCTAssertFalse(persisted.contains("PARTIAL_CLI_FIXTURE"))
        XCTAssertFalse(persisted.contains("credentialMigrationRetry"))
        XCTAssertTrue(
            store.profilesWithSessionOnlyCredentials.contains(profileID),
            "The UI has to be able to warn that this will not survive a quit"
        )
    }

    /// A refusal is often transient — a locked Keychain that gets unlocked.
    /// The held value is retried, so the user does not lose it at quit.
    func testHeldCredentialIsWrittenOnceSecureStorageAcceptsItAgain() throws {
        let profileID = UUID()
        seedLegacyProfile(
            id: profileID,
            claude: "PARTIAL_CLAUDE_FIXTURE",
            api: "PARTIAL_API_FIXTURE",
            cli: "PARTIAL_CLI_FIXTURE"
        )
        let secrets = MockProfileSecretStore()
        secrets.writeErrors[.apiSessionKey] = TestError.expected
        let store = retain(makeIsolatedProfileStore(defaults: defaults, secretStore: secrets))
        _ = try store.loadProfilesWithVerifiedMigration()

        secrets.writeErrors.removeValue(forKey: .apiSessionKey)
        let profiles = try store.loadProfilesWithVerifiedMigration()

        XCTAssertEqual(profiles.first?.apiSessionKey, "PARTIAL_API_FIXTURE")
        XCTAssertEqual(
            secrets.values[locator(profileID, .apiSessionKey)],
            "PARTIAL_API_FIXTURE",
            "The credential belongs in secure storage once it is reachable"
        )
        XCTAssertTrue(store.profilesWithSessionOnlyCredentials.isEmpty)
        XCTAssertFalse(
            try persistedProfileText().contains("PARTIAL_API_FIXTURE")
        )
    }

    func testReadFailureIsUnresolvedAndMetadataSaveDoesNotDeleteSecret() throws {
        let profileID = UUID()
        let secrets = MockProfileSecretStore()
        secrets.values[locator(profileID, .claudeSessionKey)] = "READ_FAILURE_FIXTURE"
        let setupStore = retain(makeIsolatedProfileStore(defaults: defaults, secretStore: secrets))
        try seedProfilesForTesting(
            [Profile(id: profileID, name: "Before")],
            in: setupStore
        )

        secrets.readErrors[.claudeSessionKey] = TestError.expected
        let store = retain(makeIsolatedProfileStore(defaults: defaults, secretStore: secrets))
        var loaded = store.loadProfiles()
        XCTAssertNil(loaded.first?.claudeSessionKey)
        loaded[0].name = "After"

        try store.saveProfilesThrowing(loaded)

        XCTAssertEqual(
            secrets.values[locator(profileID, .claudeSessionKey)],
            "READ_FAILURE_FIXTURE"
        )
        XCTAssertFalse(secrets.deleted.contains(locator(profileID, .claudeSessionKey)))
        XCTAssertThrowsError(try store.loadProfileCredentials(profileID)) { error in
            guard case ProfileStoreError.credentialReadUnresolved = error else {
                return XCTFail("Expected unresolved read, got \(error)")
            }
        }
    }

    func testExplicitCredentialDeletionFailureRemainsRetryable() throws {
        let profileID = UUID()
        let secrets = MockProfileSecretStore()
        let store = retain(makeIsolatedProfileStore(defaults: defaults, secretStore: secrets))
        try seedProfilesForTesting(
            [Profile(id: profileID, name: "Delete")],
            in: store
        )
        try store.saveCLIProfileCredential("DELETE_FIXTURE", for: profileID)
        secrets.deleteErrors[.cliCredentialsJSON] = TestError.expected

        XCTAssertThrowsError(
            try store.saveCLIProfileCredential(nil, for: profileID)
        )
        XCTAssertEqual(
            secrets.values[locator(profileID, .cliCredentialsJSON)],
            "DELETE_FIXTURE"
        )
        XCTAssertNotNil(store.loadProfiles().first(where: { $0.id == profileID }))
    }

    func testProfileCredentialRoundTripPreservesAPIExpiryAndIsolation() throws {
        let firstID = UUID()
        let secondID = UUID()
        let expiry = Date(timeIntervalSinceReferenceDate: 654_321)
        let secrets = MockProfileSecretStore()
        let store = retain(makeIsolatedProfileStore(defaults: defaults, secretStore: secrets))
        try seedProfilesForTesting([
            Profile(id: firstID, name: "First", cliAccountName: "first-link"),
            Profile(id: secondID, name: "Second", cliAccountName: "second-link")
        ], in: store)

        try store.saveProfileCredentials(
            firstID,
            credentials: ProfileCredentials(
                claudeSessionKey: "FIRST_CLAUDE_FIXTURE",
                organizationId: "first-org",
                apiSessionKey: "FIRST_API_FIXTURE",
                apiOrganizationId: "first-api-org",
                apiSessionKeyExpiry: expiry,
                cliCredentialsJSON: "FIRST_CLI_FIXTURE"
            )
        )

        let first = try store.loadProfileCredentials(firstID)
        let second = try store.loadProfileCredentials(secondID)
        XCTAssertEqual(first.apiSessionKeyExpiry, expiry)
        XCTAssertEqual(first.apiSessionKey, "FIRST_API_FIXTURE")
        XCTAssertNil(second.claudeSessionKey)
        XCTAssertNil(second.apiSessionKey)
        XCTAssertNil(second.cliCredentialsJSON)
        XCTAssertEqual(store.loadProfiles()[0].cliAccountName, "first-link")
        XCTAssertFalse(try persistedProfileText().contains("FIRST_API_FIXTURE"))
    }

    @MainActor
    func testCredentialAndMetadataUpdatePersistsCompleteIncomingProfile() throws {
        let profileID = UUID()
        let secrets = MockProfileSecretStore()
        let store = retain(makeIsolatedProfileStore(defaults: defaults, secretStore: secrets))
        let original = Profile(
            id: profileID,
            name: "Before",
            claudeSessionKey: "OLD_CLAUDE",
            organizationId: "old-org",
            refreshInterval: 30,
            autoStartSessionEnabled: false
        )
        try seedProfilesForTesting([original], in: store)
        secrets.values[locator(profileID, .claudeSessionKey)] = "OLD_CLAUDE"
        let manager = retain(ProfileManager(profileStore: store))
        manager.profiles = [original]
        manager.activeProfile = original
        var updated = original
        updated.name = "After"
        updated.claudeSessionKey = "NEW_CLAUDE"
        updated.organizationId = "new-org"
        updated.refreshInterval = 75
        updated.autoStartSessionEnabled = true

        try manager.updateProfileThrowing(updated)

        let relaunchedStore = retain(
            makeIsolatedProfileStore(defaults: defaults, secretStore: secrets)
        )
        let reloaded = try XCTUnwrap(
            relaunchedStore.loadProfiles().first(where: { $0.id == profileID })
        )
        XCTAssertEqual(reloaded.name, "After")
        XCTAssertEqual(reloaded.claudeSessionKey, "NEW_CLAUDE")
        XCTAssertEqual(reloaded.organizationId, "new-org")
        XCTAssertEqual(reloaded.refreshInterval, 75)
        XCTAssertTrue(reloaded.autoStartSessionEnabled)
        XCTAssertFalse(try persistedProfileText().contains("NEW_CLAUDE"))
    }

    @MainActor
    func testCompleteProfileUpdateSupersedesStaleCredentialRetry() throws {
        let profileID = UUID()
        var retry = ProfileCredentialMigrationRetry()
        retry.setValue("OLD_RETRY", for: .claudeSessionKey)
        defaults.set(
            try legacyProfilesData([
                (
                    Profile(
                        id: profileID,
                        name: "Before",
                        organizationId: "old-org"
                    ),
                    retry
                )
            ]),
            forKey: "profiles_v3"
        )
        let secrets = MockProfileSecretStore()
        // The initial retry replay fails once. The explicit complete-set
        // transaction that follows must make NEW authoritative.
        secrets.writeErrorCounts[.claudeSessionKey] = 1
        let store = retain(
            makeIsolatedProfileStore(
                defaults: defaults,
                secretStore: secrets
            )
        )
        try store.saveProfileUpdate(
            Profile(
                id: profileID,
                name: "After",
                claudeSessionKey: "NEW_EXPLICIT",
                organizationId: "new-org"
            )
        )

        XCTAssertEqual(
            secrets.values[
                locator(profileID, .claudeSessionKey)
            ],
            "NEW_EXPLICIT"
        )
        let relaunched = retain(
            makeIsolatedProfileStore(
                defaults: defaults,
                secretStore: secrets
            )
        )
        let reloaded = try XCTUnwrap(
            relaunched.loadProfilesWithVerifiedMigration().first
        )

        XCTAssertEqual(reloaded.claudeSessionKey, "NEW_EXPLICIT")
        XCTAssertEqual(reloaded.organizationId, "new-org")
        let persisted = try persistedProfileText()
        XCTAssertFalse(persisted.contains("OLD_RETRY"))
        XCTAssertFalse(persisted.contains("NEW_EXPLICIT"))
        XCTAssertFalse(persisted.contains("credentialMigrationRetry"))
    }

    @MainActor
    func testCLIProfileUpdateNeverLeavesUnrelatedRetriesOnDisk() throws {
        let profileID = UUID()
        var retry = ProfileCredentialMigrationRetry()
        retry.setValue("OLD_CLI_RETRY", for: .cliCredentialsJSON)
        retry.setValue(
            "UNRELATED_CLAUDE_RETRY",
            for: .claudeSessionKey
        )
        retry.setValue(
            "UNRELATED_API_RETRY",
            for: .apiSessionKey
        )
        defaults.set(
            try legacyProfilesData([
                (Profile(id: profileID, name: "CLI retry"), retry)
            ]),
            forKey: "profiles_v3"
        )
        let secrets = MockProfileSecretStore()
        secrets.writeErrors[.claudeSessionKey] = TestError.expected
        secrets.writeErrors[.apiSessionKey] = TestError.expected
        // The old CLI retry replay fails once. The explicit NEW transaction
        // then succeeds and must remove only the stale CLI retry.
        secrets.writeErrorCounts[.cliCredentialsJSON] = 1
        let store = retain(
            makeIsolatedProfileStore(
                defaults: defaults,
                secretStore: secrets
            )
        )

        try store.saveCLIProfileUpdate(
            Profile(
                id: profileID,
                name: "CLI updated",
                cliCredentialsJSON: "NEW_CLI_EXPLICIT"
            )
        )

        XCTAssertEqual(
            secrets.values[
                locator(profileID, .cliCredentialsJSON)
            ],
            "NEW_CLI_EXPLICIT"
        )
        let persistedAfterUpdate = try persistedProfileText()
        XCTAssertFalse(persistedAfterUpdate.contains("OLD_CLI_RETRY"))
        XCTAssertFalse(
            persistedAfterUpdate.contains("NEW_CLI_EXPLICIT")
        )
        // These used to be left sitting in preferences as plaintext until
        // something happened to touch them. They are migrated instead.
        XCTAssertFalse(
            persistedAfterUpdate.contains(
                "UNRELATED_CLAUDE_RETRY"
            )
        )
        XCTAssertFalse(
            persistedAfterUpdate.contains("UNRELATED_API_RETRY")
        )
        // Secure storage refuses both fields in this fixture, so they are
        // held in memory for the session instead of being parked on disk.
        XCTAssertTrue(
            store.profilesWithSessionOnlyCredentials.contains(profileID)
        )

        let relaunched = retain(
            makeIsolatedProfileStore(
                defaults: defaults,
                secretStore: secrets
            )
        )
        let reloaded = try XCTUnwrap(
            relaunched.loadProfilesWithVerifiedMigration().first
        )

        XCTAssertEqual(
            reloaded.cliCredentialsJSON,
            "NEW_CLI_EXPLICIT"
        )
        // Fail closed: a credential secure storage would never accept does
        // not come back after a relaunch, and the user is asked to sign in
        // again. The alternative was leaving it in cleartext on disk.
        XCTAssertNil(reloaded.claudeSessionKey)
        XCTAssertNil(reloaded.apiSessionKey)
        XCTAssertTrue(
            reloaded.credentialMigrationRetry.isEmpty,
            "Nothing may be carried across a relaunch in preferences"
        )
    }

    func testCredentialReplacementRollsBackSecondAndThirdFieldFailures() throws {
        for failedField in [ProfileSecretField.apiSessionKey, .cliCredentialsJSON] {
            defaults.removePersistentDomain(forName: suiteName)
            let profileID = UUID()
            let secrets = MockProfileSecretStore()
            let store = retain(makeIsolatedProfileStore(defaults: defaults, secretStore: secrets))
            try seedProfilesForTesting([
                Profile(
                    id: profileID,
                    name: "Before",
                    organizationId: "old-org",
                    apiOrganizationId: "old-api-org"
                )
            ], in: store)
            for field in ProfileSecretField.allCases {
                secrets.values[locator(profileID, field)] = "OLD_\(field.rawValue)"
            }
            secrets.writeErrorCounts[failedField] = 1

            XCTAssertThrowsError(
                try store.saveProfileCredentials(
                    profileID,
                    credentials: ProfileCredentials(
                        claudeSessionKey: "NEW_CLAUDE",
                        organizationId: "new-org",
                        apiSessionKey: "NEW_API",
                        apiOrganizationId: "new-api-org",
                        apiSessionKeyExpiry: Date(timeIntervalSinceReferenceDate: 10),
                        cliCredentialsJSON: "NEW_CLI"
                    )
                )
            ) { error in
                guard case ProfileStoreError.credentialTransactionFailed = error else {
                    return XCTFail("Expected safe transaction failure, got \(error)")
                }
                XCTAssertFalse(error.localizedDescription.contains("NEW_"))
                XCTAssertFalse(error.localizedDescription.contains("OLD_"))
            }

            for field in ProfileSecretField.allCases {
                XCTAssertEqual(
                    secrets.values[locator(profileID, field)],
                    "OLD_\(field.rawValue)"
                )
            }
            let persisted = try XCTUnwrap(store.loadProfiles().first)
            XCTAssertEqual(persisted.organizationId, "old-org")
            XCTAssertEqual(persisted.apiOrganizationId, "old-api-org")
        }
    }

    func testCredentialReplacementRollsBackWhenMetadataPersistenceFails() throws {
        let backing = FaultingProfileDefaults()
        let profileID = UUID()
        let secrets = MockProfileSecretStore()
        let store = retain(makeIsolatedProfileStore(defaults: backing, secretStore: secrets))
        try seedProfilesForTesting([
            Profile(
                id: profileID,
                name: "Before",
                organizationId: "old-org",
                apiOrganizationId: "old-api-org"
            )
        ], in: store)
        let previousProfileData = backing.data(forKey: "profiles_v3")
        for field in ProfileSecretField.allCases {
            secrets.values[locator(profileID, field)] = "OLD_\(field.rawValue)"
        }
        backing.corruptNextProfileWrite = true

        XCTAssertThrowsError(
            try store.saveProfileCredentials(
                profileID,
                credentials: ProfileCredentials(
                    claudeSessionKey: "NEW_CLAUDE",
                    organizationId: "new-org",
                    apiSessionKey: "NEW_API",
                    apiOrganizationId: "new-api-org",
                    apiSessionKeyExpiry: Date(timeIntervalSinceReferenceDate: 20),
                    cliCredentialsJSON: "NEW_CLI"
                )
            )
        ) { error in
            guard case ProfileStoreError.credentialTransactionFailed = error else {
                return XCTFail("Expected safe transaction failure, got \(error)")
            }
        }

        XCTAssertEqual(backing.data(forKey: "profiles_v3"), previousProfileData)
        for field in ProfileSecretField.allCases {
            XCTAssertEqual(
                secrets.values[locator(profileID, field)],
                "OLD_\(field.rawValue)"
            )
        }
    }

    @MainActor
    func testThrowingCLIProfileUpdateDoesNotDeleteUnresolvedUnrelatedSecret() throws {
        let profileID = UUID()
        let secrets = MockProfileSecretStore()
        let setupStore = retain(makeIsolatedProfileStore(defaults: defaults, secretStore: secrets))
        try seedProfilesForTesting([
            Profile(id: profileID, name: "CLI")
        ], in: setupStore)
        secrets.values[locator(profileID, .claudeSessionKey)] = "UNRELATED_CLAUDE"
        secrets.values[locator(profileID, .apiSessionKey)] = "UNRELATED_API"
        secrets.values[locator(profileID, .cliCredentialsJSON)] = "OLD_CLI"
        secrets.readErrors[.claudeSessionKey] = TestError.expected

        let store = retain(makeIsolatedProfileStore(defaults: defaults, secretStore: secrets))
        let loaded = store.loadProfiles()
        let manager = retain(ProfileManager(profileStore: store))
        manager.profiles = loaded
        manager.activeProfile = loaded.first
        var updated = try XCTUnwrap(loaded.first)
        updated.cliCredentialsJSON = "NEW_CLI"
        updated.hasCliAccount = true
        updated.cliAccountSyncedAt = Date(timeIntervalSinceReferenceDate: 51)

        try manager.updateProfileThrowing(updated)

        XCTAssertEqual(
            secrets.values[locator(profileID, .claudeSessionKey)],
            "UNRELATED_CLAUDE"
        )
        XCTAssertEqual(
            secrets.values[locator(profileID, .apiSessionKey)],
            "UNRELATED_API"
        )
        XCTAssertEqual(
            secrets.values[locator(profileID, .cliCredentialsJSON)],
            "NEW_CLI"
        )
        XCTAssertFalse(secrets.deleted.contains(locator(profileID, .claudeSessionKey)))
        XCTAssertFalse(secrets.deleted.contains(locator(profileID, .apiSessionKey)))
        XCTAssertEqual(manager.activeProfile?.cliCredentialsJSON, "NEW_CLI")
    }

    @MainActor
    func testThrowingCLIProfileUpdateSurfacesCredentialWriteFailure() throws {
        let profileID = UUID()
        let secrets = MockProfileSecretStore()
        let store = retain(makeIsolatedProfileStore(defaults: defaults, secretStore: secrets))
        let original = Profile(
            id: profileID,
            name: "CLI",
            cliCredentialsJSON: "OLD_CLI",
            hasCliAccount: true
        )
        try seedProfilesForTesting([original], in: store)
        secrets.values[locator(profileID, .cliCredentialsJSON)] = "OLD_CLI"
        let manager = retain(ProfileManager(profileStore: store))
        manager.profiles = [original]
        manager.activeProfile = original
        secrets.writeErrors[.cliCredentialsJSON] = TestError.expected
        var updated = original
        updated.cliCredentialsJSON = "NEW_CLI"
        updated.cliAccountSyncedAt = Date(timeIntervalSinceReferenceDate: 52)

        let notifications = try credentialChanges {
            XCTAssertThrowsError(try manager.updateProfileThrowing(updated))
        }

        XCTAssertTrue(notifications.isEmpty)
        XCTAssertEqual(
            secrets.values[locator(profileID, .cliCredentialsJSON)],
            "OLD_CLI"
        )
        XCTAssertEqual(manager.activeProfile?.cliCredentialsJSON, "OLD_CLI")
        XCTAssertNil(manager.activeProfile?.cliAccountSyncedAt)
    }

    @MainActor
    func testThrowingCLIProfileUpdateSurfacesCredentialDeletionFailure() throws {
        let profileID = UUID()
        let secrets = MockProfileSecretStore()
        let store = retain(makeIsolatedProfileStore(defaults: defaults, secretStore: secrets))
        let original = Profile(
            id: profileID,
            name: "CLI",
            cliCredentialsJSON: "OLD_CLI",
            hasCliAccount: true,
            cliAccountName: "linked"
        )
        try seedProfilesForTesting([original], in: store)
        secrets.values[locator(profileID, .cliCredentialsJSON)] = "OLD_CLI"
        let manager = retain(ProfileManager(profileStore: store))
        manager.profiles = [original]
        manager.activeProfile = original
        secrets.deleteErrors[.cliCredentialsJSON] = TestError.expected
        var updated = original
        updated.cliCredentialsJSON = nil
        updated.hasCliAccount = false
        updated.cliAccountName = nil

        let notifications = try credentialChanges {
            XCTAssertThrowsError(try manager.updateProfileThrowing(updated))
        }

        XCTAssertTrue(notifications.isEmpty)
        XCTAssertEqual(
            secrets.values[locator(profileID, .cliCredentialsJSON)],
            "OLD_CLI"
        )
        XCTAssertEqual(manager.activeProfile?.cliCredentialsJSON, "OLD_CLI")
        XCTAssertEqual(manager.activeProfile?.cliAccountName, "linked")
        XCTAssertTrue(manager.activeProfile?.hasCliAccount == true)
    }

    @MainActor
    func testThrowingCLILinkMetadataUpdateSurfacesPersistenceFailure() throws {
        let backing = FaultingProfileDefaults()
        let profileID = UUID()
        let store = retain(
            makeIsolatedProfileStore(
                defaults: backing,
                secretStore: MockProfileSecretStore()
            )
        )
        let original = Profile(id: profileID, name: "CLI")
        try seedProfilesForTesting([original], in: store)
        let manager = retain(ProfileManager(profileStore: store))
        manager.profiles = [original]
        manager.activeProfile = original
        backing.corruptNextProfileWrite = true
        var updated = original
        updated.cliAccountName = "planned-link"

        XCTAssertThrowsError(try manager.updateProfileThrowing(updated))

        XCTAssertNil(manager.activeProfile?.cliAccountName)
        XCTAssertEqual(store.loadProfiles().first?.cliAccountName, nil)
    }

    @MainActor
    func testProfileManagerInvalidatesEveryChangedRequestInputExactlyOnce() throws {
        let profileID = UUID()
        let secrets = MockProfileSecretStore()
        let store = retain(makeIsolatedProfileStore(defaults: defaults, secretStore: secrets))
        let original = Profile(
            id: profileID,
            name: "Requests",
            claudeSessionKey: "CLAUDE",
            organizationId: "claude-org",
            apiSessionKey: "API",
            apiOrganizationId: "api-org",
            cliCredentialsJSON: nil,
            checkOverageLimitEnabled: true
        )
        try seedProfilesForTesting([original], in: store)
        secrets.values[locator(profileID, .claudeSessionKey)] = "CLAUDE"
        secrets.values[locator(profileID, .apiSessionKey)] = "API"
        let manager = retain(ProfileManager(profileStore: store))
        manager.profiles = [original]
        manager.activeProfile = original

        XCTAssertEqual(
            try credentialChanges {
                manager.updateOrganizationId("new-claude-org", for: profileID)
            },
            [expectedCredentialChange(profileID, component: "claude")]
        )
        XCTAssertEqual(
            try credentialChanges {
                manager.updateCheckOverageLimitEnabled(false, for: profileID)
            },
            [expectedCredentialChange(profileID, component: "claude")]
        )
        XCTAssertEqual(
            try credentialChanges {
                manager.updateAPIOrganizationId("new-api-org", for: profileID)
            },
            [expectedCredentialChange(profileID, component: "api")]
        )

        var linked = try XCTUnwrap(manager.activeProfile)
        linked.cliCredentialsJSON = "CLI"
        XCTAssertEqual(
            try credentialChanges {
                try manager.updateProfileThrowing(linked)
            },
            [expectedCredentialChange(profileID, component: "cli")]
        )
        var unlinked = try XCTUnwrap(manager.activeProfile)
        unlinked.cliCredentialsJSON = nil
        XCTAssertEqual(
            try credentialChanges {
                try manager.updateProfileThrowing(unlinked)
            },
            [expectedCredentialChange(profileID, component: "cli")]
        )

        var metadataOnly = try XCTUnwrap(manager.activeProfile)
        metadataOnly.name = "Metadata only"
        XCTAssertTrue(
            try credentialChanges {
                try manager.updateProfileThrowing(metadataOnly)
            }.isEmpty
        )
    }

    @MainActor
    func testFailedOrganizationAndOverageMutationsDoNotInvalidate() throws {
        let backing = FaultingProfileDefaults()
        let profileID = UUID()
        let store = retain(
            makeIsolatedProfileStore(
                defaults: backing,
                secretStore: MockProfileSecretStore()
            )
        )
        let original = Profile(
            id: profileID,
            name: "Request settings",
            organizationId: "old-org",
            checkOverageLimitEnabled: true
        )
        try seedProfilesForTesting([original], in: store)
        let manager = retain(ProfileManager(profileStore: store))
        manager.profiles = [original]
        manager.activeProfile = original

        backing.corruptNextProfileWrite = true
        XCTAssertTrue(
            try credentialChanges {
                manager.updateOrganizationId("new-org", for: profileID)
            }.isEmpty
        )
        XCTAssertEqual(manager.activeProfile?.organizationId, "old-org")

        backing.corruptNextProfileWrite = true
        XCTAssertTrue(
            try credentialChanges {
                manager.updateCheckOverageLimitEnabled(false, for: profileID)
            }.isEmpty
        )
        XCTAssertTrue(manager.activeProfile?.checkOverageLimitEnabled == true)
    }

    @MainActor
    func testCompleteCredentialSaveInvalidatesAllOnceAndFailureDoesNotInvalidate()
        throws {
        let profileID = UUID()
        let secrets = MockProfileSecretStore()
        let store = retain(makeIsolatedProfileStore(defaults: defaults, secretStore: secrets))
        let original = Profile(
            id: profileID,
            name: "Complete set",
            claudeSessionKey: "OLD_CLAUDE",
            organizationId: "old-claude-org",
            apiSessionKey: "OLD_API",
            apiOrganizationId: "old-api-org",
            cliCredentialsJSON: "OLD_CLI"
        )
        try seedProfilesForTesting([original], in: store)
        for field in ProfileSecretField.allCases {
            secrets.values[locator(profileID, field)] = "OLD_\(field.rawValue)"
        }
        let manager = retain(ProfileManager(profileStore: store))
        manager.profiles = [original]
        manager.activeProfile = original
        let replacement = ProfileCredentials(
            claudeSessionKey: "NEW_CLAUDE",
            organizationId: "new-claude-org",
            apiSessionKey: "NEW_API",
            apiOrganizationId: "new-api-org",
            apiSessionKeyExpiry: Date(timeIntervalSinceReferenceDate: 80),
            cliCredentialsJSON: "NEW_CLI"
        )

        XCTAssertEqual(
            try credentialChanges {
                try manager.saveCredentials(
                    for: profileID,
                    credentials: replacement
                )
            },
            [expectedCredentialChange(profileID, component: "all")]
        )

        var expiryOnly = replacement
        expiryOnly.apiSessionKeyExpiry =
            Date(timeIntervalSinceReferenceDate: 81)
        XCTAssertTrue(
            try credentialChanges {
                try manager.saveCredentials(
                    for: profileID,
                    credentials: expiryOnly
                )
            }.isEmpty
        )

        var failedReplacement = expiryOnly
        failedReplacement.claudeSessionKey = "FAILED_CLAUDE"
        failedReplacement.apiSessionKey = "FAILED_API"
        secrets.writeErrors[.apiSessionKey] = TestError.expected
        XCTAssertTrue(
            try credentialChanges {
                XCTAssertThrowsError(
                    try manager.saveCredentials(
                        for: profileID,
                        credentials: failedReplacement
                    )
                )
            }.isEmpty
        )
        XCTAssertEqual(manager.activeProfile?.claudeSessionKey, "NEW_CLAUDE")
        XCTAssertEqual(manager.activeProfile?.apiSessionKey, "NEW_API")
    }

    @MainActor
    func testDirectCLISyncWritersInvalidateOnlyChangedSuccessfulMutations() throws {
        let profileID = UUID()
        let secrets = MockProfileSecretStore()
        let store = retain(makeIsolatedProfileStore(defaults: defaults, secretStore: secrets))
        try seedProfilesForTesting([
            Profile(id: profileID, name: "Direct CLI")
        ], in: store)
        var systemCredentials =
            #"{"claudeAiOauth":{"accessToken":"FIRST"}}"#
        let service = retain(
            ClaudeCodeSyncService(
                profileStore: store,
                systemCredentialsReader: { systemCredentials }
            )
        )

        XCTAssertEqual(
            try credentialChanges {
                try service.syncToProfile(profileID)
            },
            [expectedCredentialChange(profileID, component: "cli")]
        )
        XCTAssertTrue(
            try credentialChanges {
                try service.syncToProfile(profileID)
            }.isEmpty
        )

        systemCredentials =
            #"{"claudeAiOauth":{"accessToken":"SECOND"}}"#
        XCTAssertEqual(
            try credentialChanges {
                try service.resyncBeforeSwitching(for: profileID)
            },
            [expectedCredentialChange(profileID, component: "cli")]
        )
        XCTAssertEqual(
            try credentialChanges {
                try service.removeFromProfile(profileID)
            },
            [expectedCredentialChange(profileID, component: "cli")]
        )
        XCTAssertTrue(
            try credentialChanges {
                try service.removeFromProfile(profileID)
            }.isEmpty
        )
    }

    @MainActor
    func testFailedDirectCLISyncAndRemovalDoNotInvalidate() throws {
        let profileID = UUID()
        let secrets = MockProfileSecretStore()
        let store = retain(makeIsolatedProfileStore(defaults: defaults, secretStore: secrets))
        try seedProfilesForTesting([
            Profile(id: profileID, name: "Direct CLI")
        ], in: store)
        let service = retain(
            ClaudeCodeSyncService(
                profileStore: store,
                systemCredentialsReader: {
                    #"{"claudeAiOauth":{"accessToken":"SYNC"}}"#
                }
            )
        )

        secrets.readErrors[.cliCredentialsJSON] = TestError.expected
        XCTAssertTrue(
            try credentialChanges {
                XCTAssertThrowsError(try service.syncToProfile(profileID))
            }.isEmpty
        )
        XCTAssertNil(secrets.values[locator(profileID, .cliCredentialsJSON)])
        XCTAssertFalse(
            secrets.deleted.contains(
                locator(profileID, .cliCredentialsJSON)
            )
        )
        secrets.readErrors.removeAll()

        secrets.writeErrors[.cliCredentialsJSON] = TestError.expected
        XCTAssertTrue(
            try credentialChanges {
                XCTAssertThrowsError(try service.syncToProfile(profileID))
            }.isEmpty
        )
        secrets.writeErrors.removeAll()
        try service.syncToProfile(profileID)

        let deletionsBeforeReadFailure = secrets.deleted
        secrets.readErrors[.cliCredentialsJSON] = TestError.expected
        XCTAssertTrue(
            try credentialChanges {
                XCTAssertThrowsError(try service.removeFromProfile(profileID))
            }.isEmpty
        )
        XCTAssertEqual(
            secrets.values[locator(profileID, .cliCredentialsJSON)],
            #"{"claudeAiOauth":{"accessToken":"SYNC"}}"#
        )
        XCTAssertEqual(secrets.deleted, deletionsBeforeReadFailure)
        secrets.readErrors.removeAll()

        secrets.deleteErrors[.cliCredentialsJSON] = TestError.expected
        XCTAssertTrue(
            try credentialChanges {
                XCTAssertThrowsError(try service.removeFromProfile(profileID))
            }.isEmpty
        )
    }

    @MainActor
    func testSessionKeyReplacementClearsOrganizationAndInvalidatesExactlyOnce()
        throws {
        let profileID = UUID()
        let secrets = MockProfileSecretStore()
        let store = retain(makeIsolatedProfileStore(defaults: defaults, secretStore: secrets))
        let original = Profile(
            id: profileID,
            name: "Claude",
            claudeSessionKey: "sk-ant-sid01-existing-session-key-value",
            organizationId: "existing-org"
        )
        try seedProfilesForTesting([original], in: store)
        secrets.values[locator(profileID, .claudeSessionKey)] =
            "sk-ant-sid01-existing-session-key-value"
        store.saveActiveProfileId(profileID, for: .claude)
        let manager = retain(ProfileManager(profileStore: store))
        manager.loadProfiles()
        let service = retain(ClaudeAPIService(profileManager: manager))

        XCTAssertEqual(
            try credentialChanges {
                try service.saveSessionKey(
                    "sk-ant-sid01-replacement-session-key-value"
                )
            },
            [expectedCredentialChange(profileID, component: "all")]
        )
        XCTAssertEqual(
            manager.activeProfile?.claudeSessionKey,
            "sk-ant-sid01-replacement-session-key-value"
        )
        XCTAssertNil(manager.activeProfile?.organizationId)
        let reloaded = try XCTUnwrap(
            store.loadProfiles().first(where: { $0.id == profileID })
        )
        XCTAssertEqual(
            reloaded.claudeSessionKey,
            "sk-ant-sid01-replacement-session-key-value"
        )
        XCTAssertNil(reloaded.organizationId)
    }

    @MainActor
    func testSessionKeyReplacementPropagatesCredentialReadFailure() throws {
        let profileID = UUID()
        let secrets = MockProfileSecretStore()
        let setupStore = retain(makeIsolatedProfileStore(defaults: defaults, secretStore: secrets))
        try seedProfilesForTesting([
            Profile(
                id: profileID,
                name: "Claude",
                organizationId: "existing-org",
                apiOrganizationId: "existing-api-org"
            )
        ], in: setupStore)
        secrets.values[locator(profileID, .claudeSessionKey)] =
            "sk-ant-sid01-existing-session-key-value"
        secrets.values[locator(profileID, .apiSessionKey)] = "UNRELATED_API"
        secrets.values[locator(profileID, .cliCredentialsJSON)] = "UNRELATED_CLI"
        secrets.readErrors[.apiSessionKey] = TestError.expected

        let store = retain(makeIsolatedProfileStore(defaults: defaults, secretStore: secrets))
        let loaded = store.loadProfiles()
        let manager = retain(ProfileManager(profileStore: store))
        manager.profiles = loaded
        manager.activeProfile = loaded.first
        let service = retain(ClaudeAPIService(profileManager: manager))

        let notifications = try credentialChanges {
            XCTAssertThrowsError(
                try service.saveSessionKey(
                    "sk-ant-sid01-replacement-session-key-value"
                )
            )
        }

        XCTAssertTrue(notifications.isEmpty)

        XCTAssertEqual(
            secrets.values[locator(profileID, .claudeSessionKey)],
            "sk-ant-sid01-existing-session-key-value"
        )
        XCTAssertEqual(
            secrets.values[locator(profileID, .apiSessionKey)],
            "UNRELATED_API"
        )
        XCTAssertEqual(
            secrets.values[locator(profileID, .cliCredentialsJSON)],
            "UNRELATED_CLI"
        )
        XCTAssertFalse(secrets.deleted.contains(locator(profileID, .apiSessionKey)))
        XCTAssertFalse(secrets.deleted.contains(locator(profileID, .cliCredentialsJSON)))
    }

    func testCLIUpdateRollsBackSecretWhenMetadataPersistenceFails() throws {
        let backing = FaultingProfileDefaults()
        let profileID = UUID()
        let oldSyncDate = Date(timeIntervalSinceReferenceDate: 30)
        let secrets = MockProfileSecretStore()
        let store = retain(makeIsolatedProfileStore(defaults: backing, secretStore: secrets))
        try seedProfilesForTesting([
            Profile(
                id: profileID,
                name: "CLI",
                cliAccountSyncedAt: oldSyncDate
            )
        ], in: store)
        let previousProfileData = backing.data(forKey: "profiles_v3")
        secrets.values[locator(profileID, .cliCredentialsJSON)] = "OLD_CLI"
        backing.corruptNextProfileWrite = true

        XCTAssertThrowsError(
            try store.saveCLIProfileCredential(
                "NEW_CLI",
                for: profileID,
                syncedAt: Date(timeIntervalSinceReferenceDate: 40)
            )
        ) { error in
            guard case ProfileStoreError.credentialTransactionFailed = error else {
                return XCTFail("Expected safe transaction failure, got \(error)")
            }
        }

        XCTAssertEqual(
            secrets.values[locator(profileID, .cliCredentialsJSON)],
            "OLD_CLI"
        )
        XCTAssertEqual(backing.data(forKey: "profiles_v3"), previousProfileData)
    }

    func testFailedProfileReadbackRestoresPreviousBlob() throws {
        let backing = FaultingProfileDefaults()
        let secrets = MockProfileSecretStore()
        let store = retain(makeIsolatedProfileStore(defaults: backing, secretStore: secrets))
        try seedProfilesForTesting(
            [Profile(name: "Before")],
            in: store
        )
        let previous = backing.data(forKey: "profiles_v3")
        var profile = try XCTUnwrap(store.loadProfiles().first)
        profile.name = "After"
        backing.corruptNextProfileWrite = true

        XCTAssertThrowsError(try store.saveProfilesThrowing([profile]))
        XCTAssertEqual(backing.data(forKey: "profiles_v3"), previous)
        XCTAssertEqual(store.loadProfiles().first?.name, "Before")
    }

    func testLegacySourceCleanupWaitsForVerifiedTargetAndMigrationIsIdempotent() throws {
        let profileID = UUID()
        let secrets = MockProfileSecretStore()
        let store = retain(makeIsolatedProfileStore(defaults: defaults, secretStore: secrets))
        try seedProfilesForTesting(
            [Profile(id: profileID, name: "Migration")],
            in: store
        )

        let source = MockLegacyCredentialSource(
            snapshot: LegacyCredentialSnapshot(
                globalClaudeSessionKey: "MIGRATION_CLAUDE_FIXTURE",
                fileClaudeSessionKey: nil,
                globalAPISessionKey: nil,
                defaultsAPISessionKey: "MIGRATION_API_FIXTURE"
            )
        )
        source.cleanupError = TestError.expected
        let migration = retain(
            KeychainMigrationService(source: source, defaults: defaults)
        )

        XCTAssertThrowsError(try migration.migrateIfNeeded(to: profileID, profileStore: store))
        XCTAssertFalse(source.cleaned)
        XCTAssertEqual(
            try store.loadProfileCredentials(profileID).apiSessionKey,
            "MIGRATION_API_FIXTURE"
        )

        source.cleanupError = nil
        try migration.migrateIfNeeded(to: profileID, profileStore: store)
        XCTAssertTrue(source.cleaned)
        let readsAfterCompletion = source.readCount
        try migration.migrateIfNeeded(to: profileID, profileStore: store)
        XCTAssertEqual(source.readCount, readsAfterCompletion)
    }

    func testExistingV3MarkerStillMigratesFileAndGlobalLegacySources() throws {
        let profileID = UUID()
        let secrets = MockProfileSecretStore()
        let store = retain(makeIsolatedProfileStore(defaults: defaults, secretStore: secrets))
        try seedProfilesForTesting(
            [Profile(id: profileID, name: "Existing")],
            in: store
        )
        store.saveActiveProfileId(profileID, for: .claude)
        defaults.set(true, forKey: "didMigrateToProfilesV3")

        let source = MockLegacyCredentialSource(
            snapshot: LegacyCredentialSnapshot(
                globalClaudeSessionKey: nil,
                fileClaudeSessionKey: "FILE_CLAUDE_FIXTURE",
                globalAPISessionKey: "GLOBAL_API_FIXTURE",
                defaultsAPISessionKey: nil
            )
        )
        let credentialMigration = retain(
            KeychainMigrationService(source: source, defaults: defaults)
        )
        let migration = retain(
            ProfileMigrationService(
                defaults: defaults,
                profileStore: store,
                credentialMigration: credentialMigration,
                legacySettings: MockLegacyProfileSettings()
            )
        )

        try migration.migrateIfNeededThrowing()

        let credentials = try store.loadProfileCredentials(profileID)
        XCTAssertEqual(credentials.claudeSessionKey, "FILE_CLAUDE_FIXTURE")
        XCTAssertEqual(credentials.apiSessionKey, "GLOBAL_API_FIXTURE")
        XCTAssertTrue(source.cleaned)
        let persisted = try persistedProfileText()
        XCTAssertFalse(persisted.contains("FILE_CLAUDE_FIXTURE"))
        XCTAssertFalse(persisted.contains("GLOBAL_API_FIXTURE"))
    }

    func testVerifiedProfileDeletionIsolatedAndStopsOnFailure() throws {
        let firstID = UUID()
        let secondID = UUID()
        let secrets = MockProfileSecretStore()
        for field in ProfileSecretField.allCases {
            secrets.values[locator(firstID, field)] = "FIRST_\(field.rawValue)"
            secrets.values[locator(secondID, field)] = "SECOND_\(field.rawValue)"
        }
        secrets.deleteErrors[.apiSessionKey] = TestError.expected
        let store = retain(makeIsolatedProfileStore(defaults: defaults, secretStore: secrets))

        XCTAssertThrowsError(try store.deleteProfileSecrets(for: firstID))
        XCTAssertNotNil(secrets.values[locator(firstID, .apiSessionKey)])
        for field in ProfileSecretField.allCases {
            XCTAssertNotNil(secrets.values[locator(secondID, field)])
        }
    }

    private func seedLegacyProfile(
        id: UUID,
        claude: String,
        api: String,
        cli: String
    ) {
        let object: [[String: Any]] = [[
            "id": id.uuidString,
            "name": "Legacy",
            "claudeSessionKey": claude,
            "apiSessionKey": api,
            "cliCredentialsJSON": cli,
            "cliAccountName": "preserved-link",
            "apiSessionKeyExpiry": 123.0
        ]]
        defaults.set(
            try! JSONSerialization.data(withJSONObject: object),
            forKey: "profiles_v3"
        )
    }

    // MARK: - Adoption debt lifecycle

    /// (c) The whole cycle: adopt at decode, record the debt, let the
    /// migration loop secure the value, rewrite the plist, clear the debt.
    @MainActor
    func testAdoptionSecuresTheValueAndScrubsTheStoredPlaintext() throws {
        let profileID = UUID()
        seedLegacyProfile(
            id: profileID,
            claude: "LIFECYCLE_CLAUDE",
            api: "LIFECYCLE_API",
            cli: "LIFECYCLE_CLI"
        )
        let secrets = MockProfileSecretStore()
        let store = retain(
            makeIsolatedProfileStore(defaults: defaults, secretStore: secrets)
        )

        let profiles = try store.loadProfilesWithVerifiedMigration()

        XCTAssertEqual(profiles.first?.claudeSessionKey, "LIFECYCLE_CLAUDE")
        XCTAssertEqual(
            secrets.values[locator(profileID, .claudeSessionKey)],
            "LIFECYCLE_CLAUDE"
        )
        let persisted = try persistedProfileText()
        XCTAssertFalse(persisted.contains("LIFECYCLE_CLAUDE"))
        XCTAssertFalse(persisted.contains("LIFECYCLE_API"))
        XCTAssertFalse(persisted.contains("LIFECYCLE_CLI"))
        XCTAssertTrue(
            store.profilesWithSessionOnlyCredentials.isEmpty,
            "Secured, so nothing should still be held"
        )
    }

    /// (b) A value carried by the adoption debt must light the same Phase 0
    /// machinery a refused write does — verified, not assumed, since the
    /// banner and quit guard are the only things standing between the user
    /// and silent loss.
    @MainActor
    func testDebtHeldValueDrivesTheSessionOnlyMachinery() throws {
        let profileID = UUID()
        seedLegacyProfile(
            id: profileID,
            claude: "MACHINERY_CLAUDE",
            api: "MACHINERY_API",
            cli: "MACHINERY_CLI"
        )
        let secrets = MockProfileSecretStore()
        secrets.writeErrors[.claudeSessionKey] = TestError.expected
        let store = retain(
            makeIsolatedProfileStore(defaults: defaults, secretStore: secrets)
        )

        _ = try store.loadProfilesWithVerifiedMigration()

        XCTAssertTrue(
            store.profilesWithSessionOnlyCredentials.contains(profileID),
            "The banner reads off exactly this set"
        )
        XCTAssertEqual(
            QuitCredentialGuard.outcome(
                remaining: store.profilesWithSessionOnlyCredentials,
                orderedProfiles: [(id: profileID, name: "Legacy")]
            ),
            .confirm(accountNames: ["Legacy"]),
            "Quitting must warn about a legacy value that never got secured"
        )
    }

    /// (a) The crash window: adopted, but the launch died before the value
    /// was secured or the plist rewritten. The plaintext is still on disk, so
    /// the next launch must adopt it identically rather than lose it.
    @MainActor
    func testInterruptedAdoptionIsRepeatedIdenticallyOnTheNextLaunch() throws {
        let profileID = UUID()
        seedLegacyProfile(
            id: profileID,
            claude: "CRASH_CLAUDE",
            api: "CRASH_API",
            cli: "CRASH_CLI"
        )
        let secrets = MockProfileSecretStore()
        secrets.writeErrors[.claudeSessionKey] = TestError.expected
        secrets.writeErrors[.apiSessionKey] = TestError.expected
        secrets.writeErrors[.cliCredentialsJSON] = TestError.expected
        let backing = FaultingProfileDefaults()
        backing.storage["profiles_v3"] = defaults.data(forKey: "profiles_v3")
        backing.corruptNextProfileWrite = true
        let interrupted = retain(
            makeIsolatedProfileStore(defaults: backing, secretStore: secrets)
        )

        // The rewrite is corrupted, so the launch cannot complete.
        _ = try? interrupted.loadProfilesWithVerifiedMigration()

        // Nothing was secured and nothing was scrubbed, so the value must
        // still be recoverable from disk.
        let stillStored = try XCTUnwrap(
            backing.data(forKey: "profiles_v3")
                .flatMap { String(data: $0, encoding: .utf8) }
        )
        XCTAssertTrue(stillStored.contains("CRASH_CLAUDE"))

        // Next launch, with secure storage working again.
        secrets.writeErrors.removeAll()
        let relaunched = retain(
            makeIsolatedProfileStore(defaults: backing, secretStore: secrets)
        )
        let recovered = try XCTUnwrap(
            relaunched.loadProfilesWithVerifiedMigration().first
        )

        XCTAssertEqual(recovered.claudeSessionKey, "CRASH_CLAUDE")
        XCTAssertEqual(
            secrets.values[locator(profileID, .claudeSessionKey)],
            "CRASH_CLAUDE",
            "Zero loss across the crash window"
        )
        XCTAssertTrue(relaunched.profilesWithSessionOnlyCredentials.isEmpty)
    }

    /// Any verified persist settles the debt, not just the load path's own
    /// rewrite. Several public methods decode (adopting the plaintext) and
    /// persist that same record directly; if only the load path cleared the
    /// debt, they would leave it set and the next load would force a rewrite
    /// nothing needs — one that can fail verification and turn a clean read
    /// into a hard error.
    @MainActor
    func testAnyVerifiedPersistSettlesTheAdoptionDebt() throws {
        let profileID = UUID()
        seedLegacyProfile(
            id: profileID,
            claude: "DEBT_CLAUDE",
            api: "DEBT_API",
            cli: "DEBT_CLI"
        )
        let secrets = MockProfileSecretStore()
        let backing = FaultingProfileDefaults()
        backing.storage["profiles_v3"] = defaults.data(forKey: "profiles_v3")
        let store = retain(
            makeIsolatedProfileStore(defaults: backing, secretStore: secrets)
        )

        // Decoded here, not via the store: calling loadProfiles first would
        // run the verified load, which clears the debt itself and would hide
        // exactly the bypass this test is about.
        let seeded = try JSONDecoder().decode(
            [Profile].self,
            from: try XCTUnwrap(backing.data(forKey: "profiles_v3"))
        )
        try store.saveProfilesThrowing(seeded)
        XCTAssertFalse(
            try XCTUnwrap(
                backing.data(forKey: "profiles_v3")
                    .flatMap { String(data: $0, encoding: .utf8) }
            ).contains("DEBT_CLAUDE"),
            "That persist already scrubbed the plaintext"
        )

        // Armed only now: with the debt settled there is nothing left to
        // rewrite, so this load must not write at all.
        backing.corruptNextProfileWrite = true
        XCTAssertNoThrow(
            try store.loadProfilesWithVerifiedMigration(),
            "A clean read must not be turned into a hard error by a rewrite "
                + "that nothing needs"
        )
    }

    // MARK: - Opt-in session-only save (setup wizard's explicit choice)

    /// The default save path fails closed and loud. This one exists only for
    /// a user who has been told the consequence and chosen it anyway.
    @MainActor
    func testOptInSaveCompletesAndHoldsTheRefusedCredential() throws {
        let profileID = UUID()
        let secrets = MockProfileSecretStore()
        let store = retain(
            makeIsolatedProfileStore(defaults: defaults, secretStore: secrets)
        )
        try seedProfilesForTesting(
            [Profile(id: profileID, name: "Wizard")],
            in: store
        )
        secrets.writeErrors[.claudeSessionKey] = TestError.expected

        var credentials = ProfileCredentials()
        credentials.claudeSessionKey = "OPTIN_SESSION_ONLY"
        credentials.organizationId = "org"

        XCTAssertNoThrow(
            try store.saveProfileCredentialsAcceptingSessionOnly(
                profileID,
                credentials: credentials
            )
        )

        XCTAssertTrue(
            store.profilesWithSessionOnlyCredentials.contains(profileID)
        )
        XCTAssertNil(secrets.values[locator(profileID, .claudeSessionKey)])
        XCTAssertFalse(
            try persistedProfileText().contains("OPTIN_SESSION_ONLY"),
            "Opting in must not put the secret on disk — that is the whole point"
        )
    }

    /// "Cannot read the prior state" is not "there was no prior state".
    /// Swallowing it would roll back to the wrong thing later.
    @MainActor
    func testOptInSaveSurfacesAnUnreadablePriorState() throws {
        let profileID = UUID()
        let secrets = MockProfileSecretStore()
        let store = retain(
            makeIsolatedProfileStore(defaults: defaults, secretStore: secrets)
        )
        try seedProfilesForTesting(
            [Profile(id: profileID, name: "Unreadable")],
            in: store
        )
        secrets.readErrors[.claudeSessionKey] = TestError.expected

        var credentials = ProfileCredentials()
        credentials.claudeSessionKey = "VALUE"
        credentials.organizationId = "org"

        XCTAssertThrowsError(
            try store.saveProfileCredentialsAcceptingSessionOnly(
                profileID,
                credentials: credentials
            )
        ) { error in
            guard case ProfileStoreError.credentialReadUnresolved = error else {
                return XCTFail(
                    "Expected credentialReadUnresolved, got \(error)"
                )
            }
        }
    }

    /// A hold is only durable if the profile it belongs to is.
    @MainActor
    func testOptInSaveClearsTheHoldWhenMetadataPersistFails() throws {
        let profileID = UUID()
        let secrets = MockProfileSecretStore()
        let backing = FaultingProfileDefaults()
        let store = retain(
            makeIsolatedProfileStore(defaults: backing, secretStore: secrets)
        )
        try seedProfilesForTesting(
            [Profile(id: profileID, name: "Wizard")],
            in: store
        )
        secrets.writeErrors[.claudeSessionKey] = TestError.expected
        backing.corruptNextProfileWrite = true

        var credentials = ProfileCredentials()
        credentials.claudeSessionKey = "OPTIN_METADATA_FAILURE"
        credentials.organizationId = "org"

        XCTAssertThrowsError(
            try store.saveProfileCredentialsAcceptingSessionOnly(
                profileID,
                credentials: credentials
            )
        )
        XCTAssertTrue(
            store.profilesWithSessionOnlyCredentials.isEmpty,
            "Never keep a secret for a profile that failed to persist"
        )
    }

    /// Opting in converts storage refusals, nothing else.
    @MainActor
    func testOptInSaveStillThrowsForNonStorageFailures() throws {
        let secrets = MockProfileSecretStore()
        let store = retain(
            makeIsolatedProfileStore(defaults: defaults, secretStore: secrets)
        )
        try seedProfilesForTesting([], in: store)

        var credentials = ProfileCredentials()
        credentials.claudeSessionKey = "UNKNOWN_PROFILE"

        XCTAssertThrowsError(
            try store.saveProfileCredentialsAcceptingSessionOnly(
                UUID(),
                credentials: credentials
            )
        ) { error in
            guard case ProfileStoreError.profileNotFound = error else {
                return XCTFail("Expected profileNotFound, got \(error)")
            }
        }
        XCTAssertTrue(store.profilesWithSessionOnlyCredentials.isEmpty)
    }

    /// A replacement whose write was refused must not be reverted to the old
    /// value still sitting in the Keychain.
    ///
    /// Reached through the ordinary save path, which is what actually
    /// produces this state: a changed field whose write fails is held, while
    /// the Keychain keeps the previous value.
    @MainActor
    func testHeldReplacementWinsOverTheStaleStoredValue() throws {
        let profileID = UUID()
        let secrets = MockProfileSecretStore()
        let store = retain(
            makeIsolatedProfileStore(defaults: defaults, secretStore: secrets)
        )
        var profile = Profile(id: profileID, name: "Replace")
        profile.claudeSessionKey = "OLD_VALUE"
        profile.organizationId = "org"
        try seedProfilesForTesting([profile], in: store)
        secrets.values[locator(profileID, .claudeSessionKey)] = "OLD_VALUE"

        // The replacement is refused, so the Keychain still returns OLD_VALUE.
        secrets.writeErrors[.claudeSessionKey] = TestError.expected
        var updated = profile
        updated.claudeSessionKey = "NEW_VALUE"
        try store.saveProfilesThrowing([updated])

        XCTAssertTrue(
            store.profilesWithSessionOnlyCredentials.contains(profileID)
        )
        let reloaded = try XCTUnwrap(
            store.loadProfilesWithVerifiedMigration().first
        )
        XCTAssertEqual(
            reloaded.claudeSessionKey,
            "NEW_VALUE",
            "The user's update must not be silently reverted mid-session"
        )
    }

    /// Every other writer in this file rolls back its secrets when the
    /// trailing metadata persist fails; this path must too, or the caller is
    /// told nothing saved while part of the set is durably in the Keychain.
    @MainActor
    func testOptInSaveRollsBackWrittenSecretsWhenMetadataFails() throws {
        let profileID = UUID()
        let secrets = MockProfileSecretStore()
        let backing = FaultingProfileDefaults()
        let store = retain(
            makeIsolatedProfileStore(defaults: backing, secretStore: secrets)
        )
        try seedProfilesForTesting(
            [Profile(id: profileID, name: "Rollback")],
            in: store
        )
        secrets.values[locator(profileID, .apiSessionKey)] = "OLD_API"
        // claude is refused (so the opt-in path engages), api writes fine.
        secrets.writeErrors[.claudeSessionKey] = TestError.expected
        backing.corruptNextProfileWrite = true

        var credentials = ProfileCredentials()
        credentials.claudeSessionKey = "NEW_CLAUDE"
        credentials.apiSessionKey = "NEW_API"
        credentials.organizationId = "org"

        XCTAssertThrowsError(
            try store.saveProfileCredentialsAcceptingSessionOnly(
                profileID,
                credentials: credentials
            )
        )
        XCTAssertEqual(
            secrets.values[locator(profileID, .apiSessionKey)],
            "OLD_API",
            "A secret must not stay written against metadata that never landed"
        )
        XCTAssertTrue(store.profilesWithSessionOnlyCredentials.isEmpty)
    }

    /// A rollback that cannot complete must say so, not quietly assert a
    /// baseline it did not achieve — a later ordinary save consults that
    /// baseline and would skip rewriting a diverged value.
    @MainActor
    func testOptInSaveSurfacesAFailedRollback() throws {
        let profileID = UUID()
        let secrets = MockProfileSecretStore()
        let backing = FaultingProfileDefaults()
        let store = retain(
            makeIsolatedProfileStore(defaults: backing, secretStore: secrets)
        )
        try seedProfilesForTesting(
            [Profile(id: profileID, name: "Rollback")],
            in: store
        )
        secrets.writeErrors[.claudeSessionKey] = TestError.expected
        backing.corruptNextProfileWrite = true
        // api had no prior value, so rolling it back means deleting it — and
        // that delete fails, leaving the new secret durably written against
        // metadata that never landed.
        secrets.deleteErrors[.apiSessionKey] = TestError.expected

        var credentials = ProfileCredentials()
        credentials.claudeSessionKey = "NEW_CLAUDE"
        credentials.apiSessionKey = "NEW_API"
        credentials.organizationId = "org"

        XCTAssertThrowsError(
            try store.saveProfileCredentialsAcceptingSessionOnly(
                profileID,
                credentials: credentials
            )
        ) { error in
            guard case ProfileStoreError.credentialRollbackFailed(
                _,
                let fields,
                let metadata
            ) = error else {
                return XCTFail("Expected credentialRollbackFailed, got \(error)")
            }
            XCTAssertEqual(fields, [.apiSessionKey])
            // Observed, not assumed: this fixture's metadata does revert.
            XCTAssertFalse(metadata)
        }
    }

    // MARK: - A removal must not be undone by a held credential

    /// The load path overlays held values when secure storage reports
    /// absent, so a hold that outlives its deletion resurrects exactly what
    /// the user removed.
    @MainActor
    func testUnlinkDiscardsTheHeldCredentialItRemoved() throws {
        let profileID = UUID()
        let secrets = MockProfileSecretStore()
        let store = retain(
            makeIsolatedProfileStore(defaults: defaults, secretStore: secrets)
        )
        try seedProfilesForTesting(
            [Profile(id: profileID, name: "Held")],
            in: store
        )
        secrets.writeErrors[.claudeSessionKey] = TestError.expected
        var credentials = ProfileCredentials()
        credentials.claudeSessionKey = "HELD_THEN_UNLINKED"
        credentials.organizationId = "org"
        try store.saveProfileCredentialsAcceptingSessionOnly(
            profileID,
            credentials: credentials
        )
        XCTAssertTrue(
            store.profilesWithSessionOnlyCredentials.contains(profileID)
        )

        secrets.writeErrors.removeValue(forKey: .claudeSessionKey)
        try store.unlinkClaudeAI(for: profileID)

        XCTAssertTrue(
            store.profilesWithSessionOnlyCredentials.isEmpty,
            "The hold must not outlive the credential it belongs to"
        )
        let reloaded = try XCTUnwrap(
            store.loadProfilesWithVerifiedMigration().first
        )
        XCTAssertNil(
            reloaded.claudeSessionKey,
            "A later load must not resurrect what the user removed"
        )
        XCTAssertNil(secrets.values[locator(profileID, .claudeSessionKey)])
    }

    /// The inline unlink path. A session-only credential is never in
    /// storage, so removing it is not a "change" and the transaction never
    /// calls `replaceSecret` — which was the only place dropping the hold.
    @MainActor
    func testInlineUnlinkDiscardsAHoldStorageNeverReceived() throws {
        let profileID = UUID()
        let secrets = MockProfileSecretStore()
        let store = retain(
            makeIsolatedProfileStore(defaults: defaults, secretStore: secrets)
        )
        var profile = Profile(id: profileID, name: "Held")
        profile.organizationId = "org"
        try seedProfilesForTesting([profile], in: store)

        // Refused, so it is held and storage stays empty for this field.
        secrets.writeErrors[.claudeSessionKey] = TestError.expected
        var credentials = ProfileCredentials()
        credentials.claudeSessionKey = "HELD_NEVER_STORED"
        credentials.organizationId = "org"
        try store.saveProfileCredentialsAcceptingSessionOnly(
            profileID,
            credentials: credentials
        )
        XCTAssertTrue(
            store.profilesWithSessionOnlyCredentials.contains(profileID)
        )
        XCTAssertNil(secrets.values[locator(profileID, .claudeSessionKey)])

        try store.unlinkClaudeAI(for: profileID)

        XCTAssertTrue(
            store.profilesWithSessionOnlyCredentials.isEmpty,
            "An explicit unlink must not leave the credential held"
        )
        let reloaded = try XCTUnwrap(
            store.loadProfilesWithVerifiedMigration().first
        )
        XCTAssertNil(
            reloaded.claudeSessionKey,
            "A later load must not overlay the unlinked credential"
        )
    }

    /// The recovery path, which the inline test cannot reach. Forcing the
    /// transaction's metadata write to fail sends the unlink through
    /// `recoverPendingCredentialUsageUnlink`, whose forward-completion
    /// branch is the second place the hold has to be dropped.
    @MainActor
    func testUnlinkRecoveryDiscardsAHoldStorageNeverReceived() throws {
        let profileID = UUID()
        let secrets = MockProfileSecretStore()
        let backing = FaultingProfileDefaults()
        let store = retain(
            makeIsolatedProfileStore(defaults: backing, secretStore: secrets)
        )
        var profile = Profile(id: profileID, name: "Held")
        profile.organizationId = "org"
        try seedProfilesForTesting([profile], in: store)

        secrets.writeErrors[.claudeSessionKey] = TestError.expected
        var credentials = ProfileCredentials()
        credentials.claudeSessionKey = "HELD_THEN_RECOVERED"
        credentials.organizationId = "org"
        try store.saveProfileCredentialsAcceptingSessionOnly(
            profileID,
            credentials: credentials
        )
        XCTAssertTrue(
            store.profilesWithSessionOnlyCredentials.contains(profileID)
        )

        // Fail the transaction's metadata write so the catch path runs.
        backing.corruptNextProfileWrite = true
        _ = try? store.unlinkClaudeAI(for: profileID)

        XCTAssertTrue(
            store.profilesWithSessionOnlyCredentials.isEmpty,
            "Forward completion is the removal intent; the hold must go"
        )
        XCTAssertNil(
            backing.data(forKey: "profileCredentialUsageUnlinks_v1"),
            "The marker must not outlive a completed unlink"
        )
    }

    /// Deleting the profile must leave no banner or quit warning behind.
    @MainActor
    func testDeletingSecretsDiscardsHeldCredentials() throws {
        let profileID = UUID()
        let secrets = MockProfileSecretStore()
        let store = retain(
            makeIsolatedProfileStore(defaults: defaults, secretStore: secrets)
        )
        try seedProfilesForTesting(
            [Profile(id: profileID, name: "Held")],
            in: store
        )
        secrets.writeErrors[.claudeSessionKey] = TestError.expected
        var credentials = ProfileCredentials()
        credentials.claudeSessionKey = "HELD_THEN_DELETED"
        credentials.organizationId = "org"
        try store.saveProfileCredentialsAcceptingSessionOnly(
            profileID,
            credentials: credentials
        )

        secrets.writeErrors.removeValue(forKey: .claudeSessionKey)
        try store.deleteProfileSecrets(for: profileID)

        XCTAssertTrue(store.profilesWithSessionOnlyCredentials.isEmpty)
        let reloaded = try XCTUnwrap(
            store.loadProfilesWithVerifiedMigration().first
        )
        XCTAssertNil(reloaded.claudeSessionKey)
    }

    private func persistedProfileText() throws -> String {
        let data = try XCTUnwrap(defaults.data(forKey: "profiles_v3"))
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func locator(_ id: UUID, _ field: ProfileSecretField) -> ProfileSecretLocator {
        ProfileSecretLocator(profileID: id, field: field)
    }

    private func credentialChanges(
        during operation: () throws -> Void
    ) throws -> [SecurityCredentialChangeRecord] {
        let recorder = SecurityCredentialChangeRecorder()
        let observer = NotificationCenter.default.addObserver(
            forName: .credentialsChanged,
            object: nil,
            queue: nil
        ) { notification in
            recorder.record(notification)
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
        }
        try operation()
        return recorder.snapshot()
    }

    private func expectedCredentialChange(
        _ profileID: UUID,
        component: String
    ) -> SecurityCredentialChangeRecord {
        SecurityCredentialChangeRecord(
            objectProfileID: profileID,
            userInfoProfileID: profileID,
            component: component
        )
    }

}

private struct SecurityCredentialChangeRecord: Equatable {
    let objectProfileID: UUID?
    let userInfoProfileID: UUID?
    let component: String?
}

private final class SecurityCredentialChangeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [SecurityCredentialChangeRecord] = []

    func record(_ notification: Notification) {
        let record = SecurityCredentialChangeRecord(
            objectProfileID: notification.object as? UUID,
            userInfoProfileID: notification.userInfo?["profileID"] as? UUID,
            component: notification.userInfo?["component"] as? String
        )
        lock.lock()
        records.append(record)
        lock.unlock()
    }

    func snapshot() -> [SecurityCredentialChangeRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }
}

private enum TestError: Error {
    case expected
}

private final class MockProfileSecretStore: ProfileSecretStore {
    var values: [ProfileSecretLocator: String] = [:]
    var writeErrors: [ProfileSecretField: Error] = [:]
    var writeErrorCounts: [ProfileSecretField: Int] = [:]
    var readErrors: [ProfileSecretField: Error] = [:]
    var deleteErrors: [ProfileSecretField: Error] = [:]
    var deleted: Set<ProfileSecretLocator> = []

    func read(_ locator: ProfileSecretLocator) throws -> ProfileSecretReadResult {
        if let error = readErrors[locator.field] {
            throw error
        }
        return values[locator].map(ProfileSecretReadResult.value) ?? .absent
    }

    func write(_ value: String, to locator: ProfileSecretLocator) throws {
        if let count = writeErrorCounts[locator.field], count > 0 {
            writeErrorCounts[locator.field] = count - 1
            throw TestError.expected
        }
        if let error = writeErrors[locator.field] {
            throw error
        }
        values[locator] = value
    }

    func delete(_ locator: ProfileSecretLocator) throws {
        if let error = deleteErrors[locator.field] {
            throw error
        }
        values.removeValue(forKey: locator)
        deleted.insert(locator)
    }
}

private final class MockLegacyCredentialSource: LegacyCredentialSource {
    let snapshot: LegacyCredentialSnapshot
    var cleanupError: Error?
    var cleaned = false
    var readCount = 0

    init(snapshot: LegacyCredentialSnapshot) {
        self.snapshot = snapshot
    }

    func readSnapshot() throws -> LegacyCredentialSnapshot {
        readCount += 1
        return snapshot
    }

    func removeVerifiedSources(from snapshot: LegacyCredentialSnapshot) throws {
        if let cleanupError {
            throw cleanupError
        }
        cleaned = true
    }
}

private struct MockLegacyProfileSettings: LegacyProfileSettingsSource {
    func loadMenuBarIconConfiguration() -> MenuBarIconConfiguration { .default }
    func loadRefreshInterval() -> TimeInterval { 30 }
    func loadNotificationsEnabled() -> Bool { false }
    func loadAutoStartSessionEnabled() -> Bool { false }
    func loadOrganizationId() -> String? { nil }
    func loadAPIOrganizationId() -> String? { nil }
}
