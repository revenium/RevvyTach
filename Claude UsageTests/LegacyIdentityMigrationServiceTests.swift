//
//  LegacyIdentityMigrationServiceTests.swift
//  Claude UsageTests
//
//  Created by Claude Code on 2026-08-14.
//

import XCTest

@testable import Claude_Usage

final class LegacyIdentityMigrationServiceTests: XCTestCase {

    private var currentSuiteName: String!
    private var legacySuiteName: String!
    private var defaults: UserDefaults!
    private var legacyDefaults: UserDefaults!
    private var applicationSupportURL: URL!

    private let legacyFolderName = "Legacy App"
    private let currentFolderName = "Renamed App"

    override func setUpWithError() throws {
        try super.setUpWithError()

        let (currentDefaults, currentName) = try HostedTestDefaults.defaults(
            "LegacyIdentityMigrationServiceTests.current"
        )
        let (testLegacyDefaults, legacyName) = try HostedTestDefaults.defaults(
            "LegacyIdentityMigrationServiceTests.legacy"
        )
        currentSuiteName = currentName
        legacySuiteName = legacyName
        defaults = currentDefaults
        legacyDefaults = testLegacyDefaults
        HostedTestDefaults.reset(defaults, suiteName: currentSuiteName)
        HostedTestDefaults.reset(legacyDefaults, suiteName: legacySuiteName)

        applicationSupportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "LegacyIdentityMigrationServiceTests.\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: applicationSupportURL,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        HostedTestDefaults.finish(defaults, suiteName: currentSuiteName)
        HostedTestDefaults.finish(legacyDefaults, suiteName: legacySuiteName)
        defaults = nil
        legacyDefaults = nil
        currentSuiteName = nil
        legacySuiteName = nil
        try? FileManager.default.removeItem(at: applicationSupportURL)
        applicationSupportURL = nil

        try super.tearDownWithError()
    }

    private func makeService(
        currentBundleIdentifier: String = "com.example.renamed",
        legacyFolderName: String? = nil,
        fileManager: FileManager = .default
    ) -> LegacyIdentityMigrationService {
        LegacyIdentityMigrationService(
            defaults: defaults,
            fileManager: fileManager,
            currentBundleIdentifier: currentBundleIdentifier,
            currentDomainName: currentSuiteName,
            legacyBundleIdentifier: legacySuiteName,
            currentFolderName: currentFolderName,
            legacyFolderName: legacyFolderName ?? self.legacyFolderName,
            applicationSupportURL: applicationSupportURL
        )
    }

    private var legacyDirectory: URL {
        applicationSupportURL
            .appendingPathComponent(legacyFolderName, isDirectory: true)
    }

    private var currentDirectory: URL {
        applicationSupportURL
            .appendingPathComponent(currentFolderName, isDirectory: true)
    }

    private func writeLegacyFile(
        _ relativePath: String,
        contents: String
    ) throws {
        let url = legacyDirectory.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Gate conditions

    func testNoOpWhileRunningUnderLegacyIdentity() throws {
        legacyDefaults.set("value", forKey: "legacyKey")
        try writeLegacyFile("profile-data/usage.json", contents: "{}")

        // The current bundle identifier IS the legacy identifier — the
        // rename has not shipped, so nothing may happen.
        makeService(currentBundleIdentifier: legacySuiteName)
            .migrateIfNeeded()

        XCTAssertNil(defaults.object(forKey: "legacyKey"))
        XCTAssertFalse(
            defaults.bool(
                forKey: LegacyIdentityMigrationService.migrationCompletedKey
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: currentDirectory.path)
        )
    }

    func testFreshInstallWithNoLegacyDataCompletesImmediately() {
        makeService().migrateIfNeeded()

        XCTAssertTrue(
            defaults.bool(
                forKey: LegacyIdentityMigrationService.migrationCompletedKey
            )
        )
    }

    // MARK: - Preferences

    func testImportsLegacyPreferencesWithoutClobberingCurrentValues() {
        legacyDefaults.set("legacy-only", forKey: "importedKey")
        legacyDefaults.set("legacy-loses", forKey: "contestedKey")
        legacyDefaults.set(42, forKey: "importedNumber")
        defaults.set("current-wins", forKey: "contestedKey")

        makeService().migrateIfNeeded()

        XCTAssertEqual(
            defaults.string(forKey: "importedKey"), "legacy-only"
        )
        XCTAssertEqual(
            defaults.string(forKey: "contestedKey"), "current-wins"
        )
        XCTAssertEqual(defaults.integer(forKey: "importedNumber"), 42)
        XCTAssertTrue(
            defaults.bool(
                forKey: LegacyIdentityMigrationService.migrationCompletedKey
            )
        )
    }

    // MARK: - Files

    func testCopiesLegacyFilesToFreshDestination() throws {
        try writeLegacyFile("profile-data/usage.json", contents: "usage")
        try writeLegacyFile("profile-data/nested/deep.json", contents: "deep")
        try writeLegacyFile("network_logs.json", contents: "logs")

        makeService().migrateIfNeeded()

        XCTAssertEqual(
            try String(
                contentsOf: currentDirectory
                    .appendingPathComponent("profile-data/usage.json"),
                encoding: .utf8
            ),
            "usage"
        )
        XCTAssertEqual(
            try String(
                contentsOf: currentDirectory
                    .appendingPathComponent("profile-data/nested/deep.json"),
                encoding: .utf8
            ),
            "deep"
        )
        XCTAssertEqual(
            try String(
                contentsOf: currentDirectory
                    .appendingPathComponent("network_logs.json"),
                encoding: .utf8
            ),
            "logs"
        )
        // Legacy data stays in place.
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: legacyDirectory
                    .appendingPathComponent("profile-data/usage.json").path
            )
        )
        XCTAssertTrue(
            defaults.bool(
                forKey: LegacyIdentityMigrationService.migrationCompletedKey
            )
        )
    }

    func testMergeDoesNotOverwriteExistingDestinationFiles() throws {
        try writeLegacyFile("profile-data/usage.json", contents: "legacy")
        try writeLegacyFile("profile-data/other.json", contents: "other")

        let existing = currentDirectory
            .appendingPathComponent("profile-data/usage.json")
        try FileManager.default.createDirectory(
            at: existing.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "current".write(to: existing, atomically: true, encoding: .utf8)

        makeService().migrateIfNeeded()

        XCTAssertEqual(
            try String(contentsOf: existing, encoding: .utf8), "current"
        )
        XCTAssertEqual(
            try String(
                contentsOf: currentDirectory
                    .appendingPathComponent("profile-data/other.json"),
                encoding: .utf8
            ),
            "other"
        )
        XCTAssertTrue(
            defaults.bool(
                forKey: LegacyIdentityMigrationService.migrationCompletedKey
            )
        )
    }

    /// The opposite orientation of the conflict below, and the one that
    /// actually regressed: before the shared kind-aware walk, a legacy
    /// *directory* shadowed by a destination *file* made `mergeCopy` descend
    /// into the legacy folder and try to copy its children underneath a file
    /// path. That throws, so the completion marker was withheld and the
    /// migration retried — and failed again — on every single launch.
    func testLegacyDirectoryShadowedByDestinationFileCompletesWithoutRetrying()
        throws
    {
        try writeLegacyFile("profile-data/usage.json", contents: "legacy")
        try writeLegacyFile("network_logs.json", contents: "logs")

        // A file sits where the legacy migration expects a directory.
        let conflictDestination = currentDirectory
            .appendingPathComponent("profile-data")
        try FileManager.default.createDirectory(
            at: currentDirectory,
            withIntermediateDirectories: true
        )
        try "occupied".write(
            to: conflictDestination, atomically: true, encoding: .utf8
        )

        makeService().migrateIfNeeded()

        // The destination file is kept as-is, never replaced by the folder.
        var isDirectory: ObjCBool = true
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: conflictDestination.path,
                isDirectory: &isDirectory
            )
        )
        XCTAssertFalse(isDirectory.boolValue)
        XCTAssertEqual(
            try String(contentsOf: conflictDestination, encoding: .utf8),
            "occupied"
        )

        // The conflict is settled, not fatal: the marker is written so the
        // migration does not re-run and re-fail on every launch.
        XCTAssertTrue(
            defaults.bool(
                forKey: LegacyIdentityMigrationService.migrationCompletedKey
            )
        )

        // Siblings outside the conflicting subtree were still adopted.
        XCTAssertEqual(
            try String(
                contentsOf: currentDirectory
                    .appendingPathComponent("network_logs.json"),
                encoding: .utf8
            ),
            "logs"
        )
    }

    func testLegacyFileShadowedByDestinationDirectoryCompletesWithoutClobbering()
        throws
    {
        try writeLegacyFile("profile-data/usage.json", contents: "legacy")
        try writeLegacyFile("network_logs.json", contents: "logs")

        // A directory sits where the legacy migration expects a file.
        let conflictDestination = currentDirectory
            .appendingPathComponent("profile-data/usage.json")
        try FileManager.default.createDirectory(
            at: conflictDestination,
            withIntermediateDirectories: true
        )
        let sentinel = conflictDestination
            .appendingPathComponent("sentinel.txt")
        try "sentinel".write(
            to: sentinel, atomically: true, encoding: .utf8
        )

        makeService().migrateIfNeeded()

        // The destination directory and its contents are untouched.
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: conflictDestination.path,
                isDirectory: &isDirectory
            )
        )
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(
            try String(contentsOf: sentinel, encoding: .utf8), "sentinel"
        )

        // A kind conflict is a settled, verified outcome — the migration
        // completes and does not retry forever.
        XCTAssertTrue(
            defaults.bool(
                forKey: LegacyIdentityMigrationService.migrationCompletedKey
            )
        )

        // Other, non-conflicting legacy files were still adopted.
        XCTAssertEqual(
            try String(
                contentsOf: currentDirectory
                    .appendingPathComponent("network_logs.json"),
                encoding: .utf8
            ),
            "logs"
        )
    }

    func testIdenticalFolderNamesSkipFileMigration() {
        legacyDefaults.set("value", forKey: "importedKey")

        makeService(legacyFolderName: currentFolderName).migrateIfNeeded()

        XCTAssertEqual(defaults.string(forKey: "importedKey"), "value")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: currentDirectory.path)
        )
        XCTAssertTrue(
            defaults.bool(
                forKey: LegacyIdentityMigrationService.migrationCompletedKey
            )
        )
    }

    // MARK: - Idempotence and retry

    func testSecondRunRespectsCompletionMarker() throws {
        legacyDefaults.set("value", forKey: "importedKey")
        try writeLegacyFile("profile-data/usage.json", contents: "usage")

        makeService().migrateIfNeeded()
        XCTAssertTrue(
            defaults.bool(
                forKey: LegacyIdentityMigrationService.migrationCompletedKey
            )
        )

        // Data appearing in the legacy locations after completion must be
        // ignored forever.
        legacyDefaults.set("late", forKey: "lateKey")
        try writeLegacyFile("profile-data/late.json", contents: "late")

        makeService().migrateIfNeeded()

        XCTAssertNil(defaults.object(forKey: "lateKey"))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: currentDirectory
                    .appendingPathComponent("profile-data/late.json").path
            )
        )
    }

    func testFailedCopyWithholdsMarkerAndRetrySucceeds() throws {
        legacyDefaults.set("value", forKey: "importedKey")
        try writeLegacyFile("profile-data/usage.json", contents: "usage")

        makeService(fileManager: CopyRefusingFileManager())
            .migrateIfNeeded()

        // Preferences may have been imported, but completion must not be
        // recorded while any file is missing.
        XCTAssertFalse(
            defaults.bool(
                forKey: LegacyIdentityMigrationService.migrationCompletedKey
            )
        )

        // Next launch with a working file manager finishes the job.
        makeService().migrateIfNeeded()

        XCTAssertEqual(
            try String(
                contentsOf: currentDirectory
                    .appendingPathComponent("profile-data/usage.json"),
                encoding: .utf8
            ),
            "usage"
        )
        XCTAssertTrue(
            defaults.bool(
                forKey: LegacyIdentityMigrationService.migrationCompletedKey
            )
        )
    }
}

/// FileManager whose `copyItem` always fails, simulating a full disk or
/// permission error mid-migration. `nonisolated` matches its superclass —
/// a MainActor-isolated subclass of a nonisolated ObjC class crashes in
/// the synthesized deinit under this target's isolation default.
private nonisolated final class CopyRefusingFileManager: FileManager {
    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}
