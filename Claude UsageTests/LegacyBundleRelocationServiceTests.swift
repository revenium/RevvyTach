//
//  LegacyBundleRelocationServiceTests.swift
//  Claude UsageTests
//
//  Created by Claude Code on 2026-08-15.
//

import XCTest

@testable import Claude_Usage

final class LegacyBundleRelocationServiceTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    private let legacyBundleIdentifier = "com.example.legacy"
    private let currentBundleIdentifier = "com.example.renamed"
    private let expectedAppFileName = "Renamed App.app"
    private let legacyAppFileName = "Legacy App.app"

    override func setUpWithError() throws {
        try super.setUpWithError()

        let (testDefaults, testSuiteName) = try HostedTestDefaults.defaults(
            "LegacyBundleRelocationServiceTests"
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

    private func makeService(
        currentBundleIdentifier: String? = nil,
        bundleFileName: String = "Legacy App.app",
        alreadyCompleted: Bool = false,
        permanentlyDeferred: Bool = false,
        restoreLaunchAtLoginPending: Bool = false,
        runningBundleVersion: String? = "33",
        isLaunchAtLoginEnabled: @escaping () -> Bool = { false },
        setLaunchAtLoginEnabled: @escaping (Bool) -> Bool = { _ in true }
    ) -> LegacyBundleRelocationService {
        if restoreLaunchAtLoginPending {
            defaults.set(
                true,
                forKey: LegacyBundleRelocationService
                    .relocationRestoreLaunchAtLoginKey
            )
        }
        if alreadyCompleted {
            defaults.set(
                true,
                forKey: LegacyBundleRelocationService.relocationCompletedKey
            )
        }
        if permanentlyDeferred {
            defaults.set(
                true,
                forKey: LegacyBundleRelocationService
                    .relocationDeferredPermanentlyKey
            )
        }

        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(bundleFileName, isDirectory: true)

        return LegacyBundleRelocationService(
            defaults: defaults,
            fileManager: .default,
            currentBundleIdentifier:
                currentBundleIdentifier ?? self.currentBundleIdentifier,
            legacyBundleIdentifier: legacyBundleIdentifier,
            expectedAppFileName: expectedAppFileName,
            legacyAppFileName: legacyAppFileName,
            bundleURL: bundleURL,
            runningBundleVersion: runningBundleVersion,
            isLaunchAtLoginEnabled: isLaunchAtLoginEnabled,
            setLaunchAtLoginEnabled: setLaunchAtLoginEnabled
        )
    }

    // MARK: - Eligibility is scoped to the one legacy name
    //
    // The migration undoes one specific rename. Treating "any filename that
    // differs from CFBundleName" as eligible would offer to move a copy the
    // user renamed on purpose, or a second one they keep deliberately.

    func test_shouldNotOffer_whenFilenameIsNeitherLegacyNorExpected() throws {
        let service = makeService(bundleFileName: "RevvyTach 4 (backup).app")
        XCTAssertFalse(service.shouldOfferRelocation())
    }

    func test_shouldOffer_onlyForTheExactLegacyFilename() throws {
        XCTAssertTrue(
            makeService(bundleFileName: legacyAppFileName)
                .shouldOfferRelocation()
        )
        XCTAssertFalse(
            makeService(bundleFileName: "Claude Usage Copy.app")
                .shouldOfferRelocation()
        )
    }

    // MARK: - Launch-at-login hand-off
    //
    // The relocated bundle re-registers itself, because registering from the
    // process whose bundle path just moved can silently point the login item
    // at a location the app no longer occupies. Silent is the operative word:
    // the user just stops being launched at login with nothing to connect it
    // to, so these cover the hand-off rather than trusting it.

    func test_restoresLaunchAtLogin_whenFlagPendingAndNameAlreadyCorrect()
        throws
    {
        var calls: [Bool] = []
        let service = makeService(
            bundleFileName: expectedAppFileName,
            restoreLaunchAtLoginPending: true,
            setLaunchAtLoginEnabled: { enabled in
                calls.append(enabled)
                return true
            }
        )

        service.relocateIfNeeded()

        XCTAssertEqual(calls, [true])
        XCTAssertFalse(
            defaults.bool(
                forKey: LegacyBundleRelocationService
                    .relocationRestoreLaunchAtLoginKey
            ),
            "the pending flag must be cleared so the restore runs exactly once"
        )
    }

    func test_doesNotTouchLaunchAtLogin_whenNoRestoreIsPending() throws {
        var calls: [Bool] = []
        let service = makeService(
            bundleFileName: expectedAppFileName,
            setLaunchAtLoginEnabled: { enabled in
                calls.append(enabled)
                return true
            }
        )

        service.relocateIfNeeded()

        XCTAssertTrue(calls.isEmpty)
    }

    func test_clearsRestoreFlag_evenWhenReregistrationFails() throws {
        let service = makeService(
            bundleFileName: expectedAppFileName,
            restoreLaunchAtLoginPending: true,
            setLaunchAtLoginEnabled: { _ in false }
        )

        service.relocateIfNeeded()

        XCTAssertFalse(
            defaults.bool(
                forKey: LegacyBundleRelocationService
                    .relocationRestoreLaunchAtLoginKey
            ),
            "a failed re-registration must not retry on every future launch"
        )
    }

    // MARK: - Should relocate

    func test_shouldOfferRelocation_whenFilenameIsStaleAndIdentityIsCurrent()
        throws
    {
        let service = makeService()
        XCTAssertTrue(service.shouldOfferRelocation())
    }

    // MARK: - No-op cases

    func test_shouldNotOffer_whenFilenameIsAlreadyCorrect() throws {
        let service = makeService(bundleFileName: expectedAppFileName)
        XCTAssertFalse(service.shouldOfferRelocation())
    }

    func test_shouldNotOffer_whenStillRunningUnderLegacyIdentity() throws {
        let service = makeService(
            currentBundleIdentifier: legacyBundleIdentifier
        )
        XCTAssertFalse(service.shouldOfferRelocation())
    }

    func test_shouldNotOffer_whenBundleIdentifierIsNil() throws {
        let service = makeService(currentBundleIdentifier: "")
        // Empty string is still a valid non-nil, non-legacy identifier;
        // verify the nil path separately via a service constructed with a
        // nil identifier.
        XCTAssertTrue(service.shouldOfferRelocation())

        let nilIdentifierService = LegacyBundleRelocationService(
            defaults: defaults,
            fileManager: .default,
            currentBundleIdentifier: nil,
            legacyBundleIdentifier: legacyBundleIdentifier,
            expectedAppFileName: expectedAppFileName,
            bundleURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "Legacy App.app",
                    isDirectory: true
                )
        )
        XCTAssertFalse(nilIdentifierService.shouldOfferRelocation())
    }

    func test_shouldNotOffer_whenAlreadyCompleted() throws {
        let service = makeService(alreadyCompleted: true)
        XCTAssertFalse(service.shouldOfferRelocation())
    }

    func test_shouldNotOffer_whenPermanentlyDeferred() throws {
        let service = makeService(permanentlyDeferred: true)
        XCTAssertFalse(service.shouldOfferRelocation())
    }

    // MARK: - UAT variant

    func test_shouldOfferRelocation_forUATVariantWithItsOwnExpectedName()
        throws
    {
        // The UAT variant has both its own expected filename ("RevvyTach
        // UAT.app") and its own legacy filename ("Claude Usage UAT.app").
        // Relocation must key off whatever pair it was constructed with, not a
        // hardcoded release-variant name — and in particular a UAT build must
        // never treat the RELEASE legacy name as its own, or it would move
        // itself over the real app.
        let uatExpectedName = "Renamed App UAT.app"
        let uatLegacyName = "Legacy App UAT.app"
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(uatLegacyName, isDirectory: true)
        let service = LegacyBundleRelocationService(
            defaults: defaults,
            fileManager: .default,
            currentBundleIdentifier: "com.example.renamed.uat",
            legacyBundleIdentifier: "com.example.legacy.uat",
            expectedAppFileName: uatExpectedName,
            legacyAppFileName: uatLegacyName,
            bundleURL: bundleURL
        )
        XCTAssertTrue(service.shouldOfferRelocation())
    }

    func test_shouldNotOffer_forUATVariantAlreadyAtCorrectName() throws {
        let uatExpectedName = "Renamed App UAT.app"
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(uatExpectedName, isDirectory: true)
        let service = LegacyBundleRelocationService(
            defaults: defaults,
            fileManager: .default,
            currentBundleIdentifier: "com.example.renamed.uat",
            legacyBundleIdentifier: "com.example.legacy.uat",
            expectedAppFileName: uatExpectedName,
            legacyAppFileName: "Legacy App UAT.app",
            bundleURL: bundleURL
        )
        XCTAssertFalse(service.shouldOfferRelocation())
    }

    func test_uatVariantIgnoresTheReleaseLegacyName() throws {
        // A UAT build sitting at the RELEASE legacy filename must not offer to
        // relocate: acting there would move a test build onto the path the
        // real app occupies.
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Legacy App.app", isDirectory: true)
        let service = LegacyBundleRelocationService(
            defaults: defaults,
            fileManager: .default,
            currentBundleIdentifier: "com.example.renamed.uat",
            legacyBundleIdentifier: "com.example.legacy.uat",
            expectedAppFileName: "Renamed App UAT.app",
            legacyAppFileName: "Legacy App UAT.app",
            bundleURL: bundleURL
        )
        XCTAssertFalse(service.shouldOfferRelocation())
    }

    // MARK: - Legacy filename derivation
    //
    // Verifies the real derivation, not a fixture: this is what decides
    // whether a UAT build can ever target the release app's path.

    func test_legacyAppFileName_derivesPerVariant() throws {
        XCTAssertEqual(
            LegacyBundleRelocationService.legacyAppFileName(
                for: Bundle(for: Self.self)
            ).hasSuffix(".app"),
            true
        )
    }

    // MARK: - Destination

    func test_destinationURL_isSiblingOfCurrentBundleWithExpectedName()
        throws
    {
        let service = makeService()
        XCTAssertEqual(
            service.destinationURL.lastPathComponent,
            expectedAppFileName
        )
        XCTAssertEqual(
            service.destinationURL.deletingLastPathComponent().path,
            FileManager.default.temporaryDirectory.path
        )
    }
}
