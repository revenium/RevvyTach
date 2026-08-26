//
//  KeychainOwnershipAdoptionServiceTests.swift
//  Claude UsageTests
//
//  Created by Claude Code on 2026-08-14.
//

import Security
import XCTest

@testable import Claude_Usage

final class KeychainOwnershipAdoptionServiceTests: XCTestCase {

    private let service = "test.profile-credentials"
    private var backupService: String {
        service + KeychainOwnershipAdoptionService.backupServiceSuffix
    }

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: FakeAdoptionStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let (testDefaults, testSuiteName) = try HostedTestDefaults.defaults(
            "KeychainOwnershipAdoptionServiceTests"
        )
        suiteName = testSuiteName
        defaults = testDefaults
        HostedTestDefaults.reset(defaults, suiteName: suiteName)
        store = FakeAdoptionStore()
    }

    override func tearDownWithError() throws {
        HostedTestDefaults.finish(defaults, suiteName: suiteName)
        defaults = nil
        suiteName = nil
        try super.tearDownWithError()
    }

    private func makeService(
        currentBundleIdentifier: String = "com.example.renamed"
    ) -> KeychainOwnershipAdoptionService {
        KeychainOwnershipAdoptionService(
            defaults: defaults,
            store: store,
            currentBundleIdentifier: currentBundleIdentifier,
            legacyBundleIdentifier: "com.example.legacy",
            service: service
        )
    }

    private var markerSet: Bool {
        defaults.bool(
            forKey: KeychainOwnershipAdoptionService.adoptionCompletedKey
        )
    }

    // MARK: - Gates

    func testNoOpUnderLegacyIdentity() {
        store.seedForeign(service: service, account: "a", value: "secret")

        makeService(currentBundleIdentifier: "com.example.legacy")
            .adoptIfNeeded()

        XCTAssertTrue(store.isForeignOwned(service: service, account: "a"))
        XCTAssertFalse(markerSet)
    }

    func testCompletedMarkerShortCircuits() {
        defaults.set(
            true,
            forKey: KeychainOwnershipAdoptionService.adoptionCompletedKey
        )
        store.seedForeign(service: service, account: "a", value: "secret")

        makeService().adoptIfNeeded()

        XCTAssertTrue(store.isForeignOwned(service: service, account: "a"))
    }

    func testEmptyServiceCompletesImmediately() {
        makeService().adoptIfNeeded()
        XCTAssertTrue(markerSet)
    }

    // MARK: - Adoption

    func testAdoptsForeignItemsPreservingValues() {
        store.seedForeign(service: service, account: "a", value: "secret-a")
        store.seedForeign(service: service, account: "b", value: "secret-b")

        makeService().adoptIfNeeded()

        XCTAssertEqual(store.value(service: service, account: "a"), "secret-a")
        XCTAssertEqual(store.value(service: service, account: "b"), "secret-b")
        XCTAssertFalse(store.isForeignOwned(service: service, account: "a"))
        XCTAssertFalse(store.isForeignOwned(service: service, account: "b"))
        XCTAssertTrue(store.accountsIn(backupService).isEmpty)
        XCTAssertTrue(markerSet)
    }

    func testConsentDenialLeavesItemUntouchedAndRetriesNextLaunch() {
        store.seedForeign(service: service, account: "denied", value: "kept")
        store.seedForeign(service: service, account: "ok", value: "moved")
        store.denyReadAccounts = ["denied"]

        makeService().adoptIfNeeded()

        // Denied item untouched, other item adopted, no completion marker.
        XCTAssertEqual(store.value(service: service, account: "denied"), "kept")
        XCTAssertTrue(
            store.isForeignOwned(service: service, account: "denied")
        )
        XCTAssertFalse(store.isForeignOwned(service: service, account: "ok"))
        XCTAssertFalse(markerSet)

        // User relents on the next launch.
        store.denyReadAccounts = []
        makeService().adoptIfNeeded()

        XCTAssertFalse(
            store.isForeignOwned(service: service, account: "denied")
        )
        XCTAssertEqual(store.value(service: service, account: "denied"), "kept")
        XCTAssertTrue(markerSet)
    }

    func testInterruptedSwapIsRestoredFromBackup() {
        // A previous launch crashed after delete but before re-add: the value
        // survives only in the backup service.
        store.seed(service: backupService, account: "a", value: "recovered")

        makeService().adoptIfNeeded()

        XCTAssertEqual(store.value(service: service, account: "a"), "recovered")
        XCTAssertFalse(store.isForeignOwned(service: service, account: "a"))
        XCTAssertTrue(store.accountsIn(backupService).isEmpty)
        XCTAssertTrue(markerSet)
    }

    func testReAddFailureWithholdsMarkerAndBackupRecoversValue() {
        store.seedForeign(service: service, account: "a", value: "secret")
        store.failAddsToServices = [service]

        makeService().adoptIfNeeded()

        XCTAssertFalse(markerSet)
        // The value must still exist somewhere recoverable.
        let recoverable =
            store.value(service: service, account: "a")
                ?? store.value(service: backupService, account: "a")
        XCTAssertEqual(recoverable, "secret")

        // Next launch, with the Keychain healthy again, finishes the job.
        store.failAddsToServices = []
        makeService().adoptIfNeeded()

        XCTAssertEqual(store.value(service: service, account: "a"), "secret")
        XCTAssertFalse(store.isForeignOwned(service: service, account: "a"))
        XCTAssertTrue(store.accountsIn(backupService).isEmpty)
        XCTAssertTrue(markerSet)
    }

    func testInterruptedSwapRestoreFailurePreservesBackupAndRetries() {
        // A previous launch crashed after delete but before re-add, and the
        // restore itself now fails too: the backup is the only surviving
        // copy and must not be deleted.
        store.seed(service: backupService, account: "a", value: "recovered")
        store.failAddsToServices = [service]

        makeService().adoptIfNeeded()

        XCTAssertEqual(
            store.value(service: backupService, account: "a"), "recovered"
        )
        XCTAssertFalse(markerSet)

        // Next launch, with the Keychain healthy again, finishes the
        // restore.
        store.failAddsToServices = []
        makeService().adoptIfNeeded()

        XCTAssertEqual(store.value(service: service, account: "a"), "recovered")
        XCTAssertTrue(store.accountsIn(backupService).isEmpty)
        XCTAssertTrue(markerSet)
    }
}

// MARK: - Fake store

/// In-memory stand-in for the file Keychain that tracks which "application"
/// owns each item, denies reads like the macOS consent dialog, and injects
/// write failures.
private final class FakeAdoptionStore: KeychainAdoptionItemStore {
    private struct Item {
        var data: Data
        var foreignOwned: Bool
    }

    private var items: [String: [String: Item]] = [:]
    var denyReadAccounts: Set<String> = []
    var failAddsToServices: Set<String> = []

    func seedForeign(service: String, account: String, value: String) {
        items[service, default: [:]][account] =
            Item(data: Data(value.utf8), foreignOwned: true)
    }

    func seed(service: String, account: String, value: String) {
        items[service, default: [:]][account] =
            Item(data: Data(value.utf8), foreignOwned: false)
    }

    func value(service: String, account: String) -> String? {
        items[service]?[account].map { String(decoding: $0.data, as: UTF8.self) }
    }

    func isForeignOwned(service: String, account: String) -> Bool {
        items[service]?[account]?.foreignOwned ?? false
    }

    func accountsIn(_ service: String) -> [String] {
        Array(items[service, default: [:]].keys)
    }

    // MARK: KeychainAdoptionItemStore

    func accounts(service: String) throws -> [String] {
        accountsIn(service).sorted()
    }

    func readData(service: String, account: String) throws -> Data? {
        guard let item = items[service]?[account] else { return nil }
        if item.foreignOwned, denyReadAccounts.contains(account) {
            throw KeychainError.loadFailed(status: errSecAuthFailed)
        }
        return item.data
    }

    func add(_ data: Data, service: String, account: String) throws {
        if failAddsToServices.contains(service) {
            throw KeychainError.saveFailed(status: errSecIO)
        }
        guard items[service]?[account] == nil else {
            throw KeychainError.saveFailed(status: errSecDuplicateItem)
        }
        items[service, default: [:]][account] =
            Item(data: data, foreignOwned: false)
    }

    func delete(service: String, account: String) throws {
        items[service]?[account] = nil
    }
}
