import XCTest
@testable import Claude_Usage

@MainActor
final class ProfileKeychainDomainMigrationServiceTests: HostedAppTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let (testDefaults, testSuiteName) = try HostedTestDefaults.defaults(
            "ProfileKeychainDomainMigrationServiceTests"
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

    private func makeStore(with profiles: [Profile]) throws -> ProfileStore {
        let store = retain(makeIsolatedProfileStore(
            defaults: FaultingProfileDefaults(),
            secretStore: IsolatedProfileSecrets(),
            usageFileStore: IsolatedProfileUsageFiles()
        ))
        try seedProfilesForTesting(profiles, in: store)
        return store
    }

    private func makeService(
        profiles: [Profile],
        domain: ProfileKeychainDomain,
        access: SpyDomainAccess,
        defaults: UserDefaults? = nil
    ) throws -> (ProfileKeychainDomainMigrationService, ProfileStore) {
        let store = try makeStore(with: profiles)
        let resolver = ProfileKeychainDomainResolver {
            domain == .dataProtection ? errSecSuccess : errSecMissingEntitlement
        }
        let service = retain(ProfileKeychainDomainMigrationService(
            resolver: resolver,
            domainAccess: access,
            profileStore: store,
            defaults: defaults ?? self.defaults
        ))
        return (service, store)
    }

    private func locator(for profile: Profile) -> ProfileSecretLocator {
        ProfileSecretLocator(profileID: profile.id, field: .claudeSessionKey)
    }

    private func account(for locator: ProfileSecretLocator) -> String {
        "\(locator.profileID.uuidString).\(locator.field.rawValue)"
    }

    func testCopiesAReadableLegacyItemAndLeavesTheLegacyCopyIntact() throws {
        let profile = Profile(name: "Migratable")
        let access = SpyDomainAccess()
        let account = account(for: locator(for: profile))
        access.store(
            Data("legacy-secret".utf8),
            domain: .file,
            service: KeychainService.profileSecretsService,
            account: account
        )
        let (service, _) = try makeService(
            profiles: [profile],
            domain: .dataProtection,
            access: access
        )

        service.migrateIfNeeded()

        XCTAssertEqual(
            access.value(
                domain: .dataProtection,
                service: KeychainService.profileSecretsService,
                account: account
            ),
            Data("legacy-secret".utf8),
            "The credential must be copied into the data-protection Keychain"
        )
        XCTAssertEqual(
            access.value(
                domain: .file,
                service: KeychainService.profileSecretsService,
                account: account
            ),
            Data("legacy-secret".utf8),
            "The legacy copy must not be deleted by this migration"
        )
    }

    func testDoesNotDestroyOrMarkCompleteAnUnreadableLegacyItem() throws {
        let profile = Profile(name: "Broken")
        let access = SpyDomainAccess()
        let account = account(for: locator(for: profile))
        access.store(
            Data("stranded".utf8),
            domain: .file,
            service: KeychainService.profileSecretsService,
            account: account
        )
        access.refuseFileReads = true
        let (service, _) = try makeService(
            profiles: [profile],
            domain: .dataProtection,
            access: access,
            defaults: defaults
        )

        service.migrateIfNeeded()

        XCTAssertNil(
            access.value(
                domain: .dataProtection,
                service: KeychainService.profileSecretsService,
                account: account
            ),
            "An item that could not be read must never be copied"
        )
        XCTAssertEqual(
            access.value(
                domain: .file,
                service: KeychainService.profileSecretsService,
                account: account
            ),
            Data("stranded".utf8),
            "The unreadable legacy item must be left exactly as found"
        )
        XCTAssertFalse(
            defaults.bool(
                forKey: "profileCredentialDataProtectionMigrationCompleted_v1"
            ),
            "A locator that failed must not let the migration mark itself complete"
        )
    }

    func testIdempotentAndDoesNotReRunOnceFlagged() throws {
        let profile = Profile(name: "Flagged")
        let access = SpyDomainAccess()
        let account = account(for: locator(for: profile))
        access.store(
            Data("legacy-secret".utf8),
            domain: .file,
            service: KeychainService.profileSecretsService,
            account: account
        )
        let (service, _) = try makeService(
            profiles: [profile],
            domain: .dataProtection,
            access: access,
            defaults: defaults
        )

        service.migrateIfNeeded()
        XCTAssertTrue(
            defaults.bool(
                forKey: "profileCredentialDataProtectionMigrationCompleted_v1"
            ),
            "A pass where every locator succeeded must mark itself complete"
        )

        access.readCount = 0
        service.migrateIfNeeded()

        XCTAssertEqual(
            access.readCount,
            0,
            "A flagged migration must return without touching the Keychain again"
        )
    }

    func testDoesNothingWhenTheResolvedDomainIsStillTheFileKeychain() throws {
        let profile = Profile(name: "Unentitled")
        let access = SpyDomainAccess()
        let account = account(for: locator(for: profile))
        access.store(
            Data("legacy-secret".utf8),
            domain: .file,
            service: KeychainService.profileSecretsService,
            account: account
        )
        let (service, _) = try makeService(
            profiles: [profile],
            domain: .file,
            access: access
        )

        service.migrateIfNeeded()

        XCTAssertNil(
            access.value(
                domain: .dataProtection,
                service: KeychainService.profileSecretsService,
                account: account
            ),
            "There is nothing usable to migrate into yet"
        )
        XCTAssertEqual(
            access.readCount,
            0,
            "An unentitled build must not probe the Keychain at all"
        )
    }

    func testALocatorWithNoLegacyItemIsNotAFailure() throws {
        let profile = Profile(name: "NothingToMigrate")
        let access = SpyDomainAccess()
        let (service, _) = try makeService(
            profiles: [profile],
            domain: .dataProtection,
            access: access,
            defaults: defaults
        )

        service.migrateIfNeeded()

        XCTAssertTrue(
            defaults.bool(
                forKey: "profileCredentialDataProtectionMigrationCompleted_v1"
            ),
            "An installation with nothing to migrate must still complete"
        )
    }

    func testDoesNotOverwriteAnExistingDataProtectionValue() throws {
        let profile = Profile(name: "AlreadyPresent")
        let access = SpyDomainAccess()
        let account = account(for: locator(for: profile))
        access.store(
            Data("legacy-secret".utf8),
            domain: .file,
            service: KeychainService.profileSecretsService,
            account: account
        )
        access.store(
            Data("re-entered-secret".utf8),
            domain: .dataProtection,
            service: KeychainService.profileSecretsService,
            account: account
        )
        let (service, _) = try makeService(
            profiles: [profile],
            domain: .dataProtection,
            access: access
        )

        service.migrateIfNeeded()

        XCTAssertEqual(
            access.value(
                domain: .dataProtection,
                service: KeychainService.profileSecretsService,
                account: account
            ),
            Data("re-entered-secret".utf8),
            "A value already in the destination must never be replaced"
        )
    }
}

/// Records every domain-scoped Keychain call the migration makes and can
/// refuse legacy reads the way a broken ACL is refused.
private final class SpyDomainAccess: ProfileKeychainDomainAccess {
    private struct ItemKey: Hashable {
        let domain: ProfileKeychainDomain
        let service: String
        let account: String
    }

    var refuseFileReads = false
    var readCount = 0
    private var items: [ItemKey: Data] = [:]

    func store(
        _ data: Data,
        domain: ProfileKeychainDomain,
        service: String,
        account: String
    ) {
        items[ItemKey(domain: domain, service: service, account: account)] =
            data
    }

    func value(
        domain: ProfileKeychainDomain,
        service: String,
        account: String
    ) -> Data? {
        items[ItemKey(domain: domain, service: service, account: account)]
    }

    func read(
        service: String,
        account: String,
        domain: ProfileKeychainDomain
    ) throws -> Data? {
        readCount += 1
        if domain == .file, refuseFileReads {
            throw KeychainError.loadFailed(status: errSecInteractionNotAllowed)
        }
        return items[ItemKey(domain: domain, service: service, account: account)]
    }

    func write(
        _ data: Data,
        service: String,
        account: String,
        domain: ProfileKeychainDomain
    ) throws {
        items[ItemKey(domain: domain, service: service, account: account)] =
            data
    }
}
