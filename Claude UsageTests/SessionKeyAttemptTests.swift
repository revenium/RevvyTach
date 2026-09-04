import Foundation
import XCTest
@testable import Claude_Usage

final class SessionKeyAttemptTests: XCTestCase {
    func testCompletionIsRejectedAfterKeyEditCancelOrProfileSwitch() {
        var attempt = SessionKeyAttempt()
        let generation = attempt.generation

        attempt.invalidate()
        XCTAssertFalse(SessionKeyAttemptPolicy.acceptsCompletion(
            generation: generation,
            currentGeneration: attempt.generation,
            keyMatches: true
        ))
        XCTAssertFalse(SessionKeyAttemptPolicy.acceptsCompletion(
            generation: attempt.generation,
            currentGeneration: attempt.generation,
            keyMatches: false
        ))
        XCTAssertFalse(SessionKeyAttemptPolicy.acceptsCompletion(
            generation: attempt.generation,
            currentGeneration: attempt.generation,
            keyMatches: true,
            targetMatches: false
        ))
    }

    func testChromeLaunchRequiresBothLocalNonceAndParentGeneration() {
        let generation = UUID()
        let launch = ChromeLaunchAttempt(
            nonce: UUID(),
            parentGeneration: generation
        )

        XCTAssertTrue(SessionKeyAttemptPolicy.acceptsChromeLaunch(
            launch,
            currentNonce: launch.nonce,
            currentGeneration: generation
        ))
        XCTAssertFalse(SessionKeyAttemptPolicy.acceptsChromeLaunch(
            launch,
            currentNonce: UUID(),
            currentGeneration: generation
        ))
        XCTAssertFalse(SessionKeyAttemptPolicy.acceptsChromeLaunch(
            launch,
            currentNonce: launch.nonce,
            currentGeneration: UUID()
        ))
    }

    func testFirstRunCompletionAcceptsOnlyTheCreatedActiveClaudeProfile() {
        let generation = UUID()
        let createdProfileID = UUID()

        XCTAssertTrue(SessionKeyAttemptPolicy.acceptsSetupCompletion(
            generation: generation,
            currentGeneration: generation,
            keyMatches: true,
            capturedTarget: .newProfile,
            completedProfileID: createdProfileID,
            completedProfileIsClaude: true,
            activeClaudeProfileID: createdProfileID
        ))
        XCTAssertFalse(SessionKeyAttemptPolicy.acceptsSetupCompletion(
            generation: generation,
            currentGeneration: generation,
            keyMatches: true,
            capturedTarget: .newProfile,
            completedProfileID: createdProfileID,
            completedProfileIsClaude: true,
            activeClaudeProfileID: UUID()
        ))
        XCTAssertFalse(SessionKeyAttemptPolicy.acceptsSetupCompletion(
            generation: generation,
            currentGeneration: UUID(),
            keyMatches: true,
            capturedTarget: .newProfile,
            completedProfileID: createdProfileID,
            completedProfileIsClaude: true,
            activeClaudeProfileID: createdProfileID
        ))
    }

    func testExistingCompletionRequiresTheCapturedProfileIdentity() {
        let generation = UUID()
        let capturedProfileID = UUID()

        XCTAssertTrue(SessionKeyAttemptPolicy.acceptsSetupCompletion(
            generation: generation,
            currentGeneration: generation,
            keyMatches: true,
            capturedTarget: .existing(capturedProfileID),
            completedProfileID: capturedProfileID,
            completedProfileIsClaude: true,
            activeClaudeProfileID: capturedProfileID
        ))
        XCTAssertFalse(SessionKeyAttemptPolicy.acceptsSetupCompletion(
            generation: generation,
            currentGeneration: generation,
            keyMatches: true,
            capturedTarget: .existing(capturedProfileID),
            completedProfileID: UUID(),
            completedProfileIsClaude: true,
            activeClaudeProfileID: capturedProfileID
        ))
    }

    func testFailedFirstRunPromotesOnlyItsSoleActiveClaudeProfileForRetry() {
        let createdProfileID = UUID()

        XCTAssertEqual(
            SessionKeyAttemptPolicy.retryTargetAfterFailedSetup(
                capturedTarget: .newProfile,
                claudeProfileIDs: [createdProfileID]
            ),
            .createdProfile(createdProfileID)
        )
        XCTAssertEqual(
            SessionKeyAttemptPolicy.retryTargetAfterFailedSetup(
                capturedTarget: .newProfile,
                claudeProfileIDs: [createdProfileID, UUID()]
            ),
            .newProfile
        )
        XCTAssertEqual(
            SessionKeyAttemptPolicy.retryTargetAfterFailedSetup(
                capturedTarget: .existing(createdProfileID),
                claudeProfileIDs: [createdProfileID]
            ),
            .existing(createdProfileID)
        )
    }

    func testSaveRequiresExplicitOrganizationTargetAndChromeConfirmation() {
        XCTAssertFalse(SessionKeyAttemptPolicy.hasSelectableOrganization(0))
        XCTAssertTrue(SessionKeyAttemptPolicy.hasSelectableOrganization(1))
        XCTAssertFalse(SessionKeyAttemptPolicy.permitsSave(
            validationSucceeded: true,
            isSessionOnlyRetry: false,
            selectedOrganizationID: nil,
            chromeProfileLabel: nil,
            chromeContextConfirmed: false
        ))
        XCTAssertFalse(SessionKeyAttemptPolicy.permitsSave(
            validationSucceeded: true,
            isSessionOnlyRetry: false,
            selectedOrganizationID: "org",
            chromeProfileLabel: "Work — Profile 1",
            chromeContextConfirmed: false
        ))
        XCTAssertFalse(SessionKeyAttemptPolicy.permitsSave(
            validationSucceeded: true,
            isSessionOnlyRetry: false,
            selectedOrganizationID: "org",
            chromeProfileLabel: nil,
            chromeContextConfirmed: false,
            targetMatches: false
        ))
        XCTAssertTrue(SessionKeyAttemptPolicy.permitsSave(
            validationSucceeded: true,
            isSessionOnlyRetry: false,
            selectedOrganizationID: "org",
            chromeProfileLabel: "Work — Profile 1",
            chromeContextConfirmed: true
        ))
    }

    func testSessionOnlyRetryStillRequiresOrganizationAndChromeConfirmation() {
        XCTAssertFalse(SessionKeyAttemptPolicy.permitsSave(
            validationSucceeded: false,
            isSessionOnlyRetry: true,
            selectedOrganizationID: nil,
            chromeProfileLabel: nil,
            chromeContextConfirmed: false
        ))
        XCTAssertTrue(SessionKeyAttemptPolicy.permitsSave(
            validationSucceeded: false,
            isSessionOnlyRetry: true,
            selectedOrganizationID: "org",
            chromeProfileLabel: "Work — Profile 1",
            chromeContextConfirmed: true
        ))
    }

    // MARK: - Chrome read: the confirmation gate and the scope guard

    // `@MainActor` on these four: `SetupWizardState` and
    // `ChromeAssistedSessionKeyEntry` are main-actor-isolated by the app
    // target's default actor isolation, and the unit-test target sets no
    // such default.

    /// A key read from Chrome must not silently satisfy the step-4 "this is
    /// the account I meant" checkbox. The label survives so the checkbox
    /// keeps rendering; the confirmation itself is cleared, because a
    /// confirmation earned for a previous key is not consent for this one.
    @MainActor
    func testChromeReadKeepsTheChromeConfirmationGateArmed() {
        let profileID = UUID()
        var state = SetupWizardState()
        state.launchedChromeProfileLabel = "Work — Profile 3"
        state.hasConfirmedChromeContext = true
        state.claudeSetupTarget = .existing(profileID)
        state.targetProfileName = "Work"
        state.sessionKey = "sk-ant-sid01-EXISTING-0000000000000000"
        let before = state.attempt.generation

        state.retireAttempt(
            clearKey: false,
            clearChromeContext: false,
            clearTarget: false,
            rearmChromeConfirmation: true
        )

        XCTAssertEqual(state.launchedChromeProfileLabel, "Work — Profile 3")
        XCTAssertEqual(state.claudeSetupTarget, .existing(profileID))
        XCTAssertEqual(state.targetProfileName, "Work")
        XCTAssertEqual(state.sessionKey, "sk-ant-sid01-EXISTING-0000000000000000")
        XCTAssertFalse(state.hasConfirmedChromeContext)
        XCTAssertNotEqual(state.attempt.generation, before)

        // Save stays blocked until the user ticks the box again.
        XCTAssertFalse(SessionKeyAttemptPolicy.permitsSave(
            validationSucceeded: true,
            isSessionOnlyRetry: false,
            selectedOrganizationID: "org-1",
            chromeProfileLabel: state.launchedChromeProfileLabel,
            chromeContextConfirmed: state.hasConfirmedChromeContext
        ))
        state.hasConfirmedChromeContext = true
        XCTAssertTrue(SessionKeyAttemptPolicy.permitsSave(
            validationSucceeded: true,
            isSessionOnlyRetry: false,
            selectedOrganizationID: "org-1",
            chromeProfileLabel: state.launchedChromeProfileLabel,
            chromeContextConfirmed: state.hasConfirmedChromeContext
        ))
    }

    /// The same transition with its default arguments still clears the Chrome
    /// context, so moving it onto `SetupWizardState` changed nothing for the
    /// callers that were already there.
    @MainActor
    func testDefaultRetirementStillClearsTheChromeContext() {
        var state = SetupWizardState()
        state.launchedChromeProfileLabel = "Work — Profile 3"
        state.hasConfirmedChromeContext = true
        state.claudeSetupTarget = .existing(UUID())
        state.targetProfileName = "Work"
        state.sessionKey = "sk-ant-sid01-EXISTING-0000000000000000"
        state.selectedOrgId = "org-1"

        state.retireAttempt(clearKey: true)

        XCTAssertNil(state.launchedChromeProfileLabel)
        XCTAssertFalse(state.hasConfirmedChromeContext)
        XCTAssertNil(state.claudeSetupTarget)
        XCTAssertNil(state.targetProfileName)
        XCTAssertNil(state.selectedOrgId)
        XCTAssertEqual(state.sessionKey, "")
    }

    /// Launch profile A, then fail to launch profile B: nothing is
    /// addressable afterwards. The read must never target the profile from
    /// the attempt before the one the user just made.
    func testFailedLaunchLeavesNoAddressableChromeProfile() {
        let profileA = ChromeProfile(name: "Work", directoryName: "Profile 3")
        let profileB = ChromeProfile(name: "Personal", directoryName: "Default")

        let launched = ChromeLaunchBookkeeping.result(
            didLaunch: true, profile: profileA
        )
        XCTAssertEqual(launched?.directoryName, "Profile 3")
        XCTAssertEqual(launched?.label, "Work — Profile 3")

        let afterFailure = ChromeLaunchBookkeeping.result(
            didLaunch: false, profile: profileB
        )
        XCTAssertNil(afterFailure)
        XCTAssertFalse(ChromeReadAvailabilityPolicy.permitsRead(
            launchedProfile: afterFailure,
            isLaunching: false,
            isReading: false,
            isValidating: false
        ))
    }

    /// The default-off contract.
    func testReadIsUnavailableUntilAProfileLaunches() {
        let launched = LaunchedChromeProfile(
            label: "Work — Profile 3", directoryName: "Profile 3"
        )

        XCTAssertFalse(ChromeReadAvailabilityPolicy.permitsRead(
            launchedProfile: nil,
            isLaunching: false,
            isReading: false,
            isValidating: false
        ))
        XCTAssertFalse(ChromeReadAvailabilityPolicy.permitsRead(
            launchedProfile: launched,
            isLaunching: true,
            isReading: false,
            isValidating: false
        ))
        XCTAssertFalse(ChromeReadAvailabilityPolicy.permitsRead(
            launchedProfile: launched,
            isLaunching: false,
            isReading: true,
            isValidating: false
        ))
        XCTAssertFalse(ChromeReadAvailabilityPolicy.permitsRead(
            launchedProfile: launched,
            isLaunching: false,
            isReading: false,
            isValidating: true
        ))
        XCTAssertTrue(ChromeReadAvailabilityPolicy.permitsRead(
            launchedProfile: launched,
            isLaunching: false,
            isReading: false,
            isValidating: false
        ))
    }

    /// A read that finished after the user launched a different profile must
    /// not be adopted: its key belongs to the profile they moved on from,
    /// while the screen and the save gate both name the new one.
    func testReadIsAdoptedOnlyForTheProfileItWasScopedTo() {
        let scoped = LaunchedChromeProfile(
            label: "Work — Profile 3", directoryName: "Profile 3"
        )

        XCTAssertTrue(ChromeReadAdoptionPolicy.permitsAdoption(
            readProfile: scoped,
            launchedProfile: LaunchedChromeProfile(
                label: "Work — Profile 3", directoryName: "Profile 3"
            )
        ))
        XCTAssertFalse(ChromeReadAdoptionPolicy.permitsAdoption(
            readProfile: scoped,
            launchedProfile: LaunchedChromeProfile(
                label: "Work — Profile 3", directoryName: "Default"
            )
        ))
        XCTAssertFalse(ChromeReadAdoptionPolicy.permitsAdoption(
            readProfile: scoped,
            launchedProfile: LaunchedChromeProfile(
                label: "Personal — Profile 3", directoryName: "Profile 3"
            )
        ))
        XCTAssertFalse(ChromeReadAdoptionPolicy.permitsAdoption(
            readProfile: scoped,
            launchedProfile: nil
        ))
    }

    /// The concrete race: read profile A, launch profile B mid-read, and A's
    /// key is discarded rather than adopted under B's name. A failed launch of
    /// B leaves nothing addressable, which is also not adoptable.
    func testProfileSwitchDuringReadDiscardsTheInFlightResult() {
        let profileA = ChromeProfile(name: "Work", directoryName: "Profile 3")
        let profileB = ChromeProfile(name: "Personal", directoryName: "Default")

        guard let scoped = ChromeLaunchBookkeeping.result(
            didLaunch: true, profile: profileA
        ) else {
            return XCTFail("A successful launch must yield a profile")
        }

        let switched = ChromeLaunchBookkeeping.result(
            didLaunch: true, profile: profileB
        )
        XCTAssertFalse(ChromeReadAdoptionPolicy.permitsAdoption(
            readProfile: scoped,
            launchedProfile: switched
        ))

        let failedSwitch = ChromeLaunchBookkeeping.result(
            didLaunch: false, profile: profileB
        )
        XCTAssertFalse(ChromeReadAdoptionPolicy.permitsAdoption(
            readProfile: scoped,
            launchedProfile: failedSwitch
        ))
    }

    /// Every failure the user can hit maps to a fixed sentence. Nothing here
    /// may interpolate a value, a path, or an OSStatus.
    @MainActor
    func testChromeReadFailuresMapToFixedLocalizedSentences() {
        let cases: [(ChromeCookieReadError, String)] = [
            (.keychainAccessDenied, "chrome_assisted.read_failed_denied"),
            (.databaseLocked, "chrome_assisted.read_failed_locked"),
            (.sessionCookieMissing, "chrome_assisted.read_failed_missing"),
            (.keychainItemMissing, "chrome_assisted.read_failed_missing"),
            (.unknownEncryptionVersion, "chrome_assisted.read_failed_version"),
            (.cookieDatabaseMissing, "chrome_assisted.read_failed_generic"),
            (.databaseUnreadable, "chrome_assisted.read_failed_generic"),
            (.decryptFailed, "chrome_assisted.read_failed_generic"),
            (.tempCopyFailed, "chrome_assisted.read_failed_generic"),
            (.invalidProfile, "chrome_assisted.read_failed_generic"),
            (.keychainReadFailed(-25300), "chrome_assisted.read_failed_generic"),
        ]

        for (error, key) in cases {
            let message = ChromeAssistedSessionKeyEntry.message(for: error)
            XCTAssertEqual(message, key.localized, "\(error)")
            XCTAssertNotEqual(message, key, "\(key) has no translation")
            XCTAssertFalse(message.contains("25300"))
        }

        // A non-ChromeCookieReadError still degrades to manual paste rather
        // than showing its own text.
        struct Surprise: Error { let detail = "sk-ant-should-never-render" }
        let message = ChromeAssistedSessionKeyEntry.message(for: Surprise())
        XCTAssertEqual(message, "chrome_assisted.read_failed_generic".localized)
        XCTAssertFalse(message.contains("sk-ant"))
    }
}
