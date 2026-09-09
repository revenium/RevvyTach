//
//  ChromeSessionKeyAutoReReadTests.swift
//  Claude UsageTests
//
//  The rules that keep an automatic re-read from Chrome safe: it only ever
//  runs for a profile that recorded a Chrome profile, it writes nothing and
//  says nothing when the key has not changed, it notifies exactly once when
//  it has, and it cannot run in a loop.
//
//  Nothing here touches the real Keychain, the real Chrome, real profile
//  storage, or the real notification centre. Every boundary is a closure.
//

import XCTest
@testable import Claude_Usage

final class ChromeSessionKeyAutoReReadTests: XCTestCase {
    private let profileID = UUID()
    private let deadKey = "sk-ant-sid01-dead00000000000000"
    private let freshKey = "sk-ant-sid01-fresh0000000000000"

    private let source = ProfileChromeSessionKeySource(
        directoryName: "Profile 19",
        label: "Work — Profile 19",
        recordedAt: Date(timeIntervalSince1970: 1_000)
    )

    // MARK: - Recorder

    /// Counts every boundary crossing so "exactly once" is assertable.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var readDirectories: [String] = []
        private(set) var savedKeys: [String] = []
        private(set) var notifications: [(String, String)] = []

        func recordRead(_ directoryName: String) {
            lock.lock()
            readDirectories.append(directoryName)
            lock.unlock()
        }

        func recordSave(_ key: String) {
            lock.lock()
            savedKeys.append(key)
            lock.unlock()
        }

        func recordNotification(_ profile: String, _ chrome: String) {
            lock.lock()
            notifications.append((profile, chrome))
            lock.unlock()
        }
    }

    private func makeReader(
        recorder: Recorder,
        read: @escaping @Sendable (String) throws -> String,
        saveResult: ChromeSessionKeyReReadSaveResult = .stored,
        now: @escaping @Sendable () -> Date = Date.init,
        minimumInterval: TimeInterval = ChromeSessionKeyAutoReReader
            .defaultMinimumInterval,
        attemptLog: AttemptLog = AttemptLog()
    ) -> ChromeSessionKeyAutoReReader {
        ChromeSessionKeyAutoReReader(
            readSessionKey: { directoryName in
                recorder.recordRead(directoryName)
                return try read(directoryName)
            },
            saveSessionKey: { _, key, _, _ in
                guard saveResult == .stored else { return saveResult }
                recorder.recordSave(key)
                return .stored
            },
            notify: { profileName, chromeLabel in
                recorder.recordNotification(profileName, chromeLabel)
            },
            now: now,
            minimumInterval: minimumInterval,
            readAttemptLog: { attemptLog.value },
            writeAttemptLog: { attemptLog.value = $0 }
        )
    }

    /// Stands in for the persisted last-attempt times, so the throttle can be
    /// tested across two re-reader instances without touching `UserDefaults`.
    private final class AttemptLog: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: Date] = [:]

        var value: [String: Date] {
            get {
                lock.lock()
                defer { lock.unlock() }
                return storage
            }
            set {
                lock.lock()
                storage = newValue
                lock.unlock()
            }
        }
    }

    // MARK: - The remembered Chrome profile survives a round trip

    func testProfileRoundTripsTheRememberedChromeProfile() throws {
        var profile = Profile(name: "Work")
        profile.chromeSessionKeySource = source

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(Profile.self, from: data)

        XCTAssertEqual(decoded.chromeSessionKeySource?.directoryName,
                       "Profile 19")
        XCTAssertEqual(decoded.chromeSessionKeySource?.label,
                       "Work — Profile 19")
        XCTAssertEqual(decoded.chromeSessionKeySource, source)
    }

    /// A profile written before this field existed has to decode, and has to
    /// decode as "no Chrome profile remembered" rather than as a failure.
    func testLegacyProfileDecodesWithNoRememberedChromeProfile() throws {
        let legacy = """
        {
            "id": "\(UUID().uuidString)",
            "name": "Legacy",
            "hasCliAccount": false,
            "refreshInterval": 30,
            "autoStartSessionEnabled": false,
            "checkOverageLimitEnabled": true,
            "isSelectedForDisplay": true
        }
        """

        let decoded = try JSONDecoder().decode(
            Profile.self,
            from: Data(legacy.utf8)
        )

        XCTAssertNil(decoded.chromeSessionKeySource)
    }

    /// A directory name that no longer passes the path policy is treated as
    /// nothing remembered, so a malformed stored value can never be handed to
    /// the cookie reader.
    func testUnusableDirectoryNameIsNotRead() async {
        let recorder = Recorder()
        let reader = makeReader(recorder: recorder, read: { _ in "unused" })

        let outcome = await reader.reReadAfterRefusal(
            profileID: profileID,
            profileName: "Work",
            source: ProfileChromeSessionKeySource(
                directoryName: "../Profile 19",
                label: "Escaped"
            ),
            currentSessionKey: deadKey
        )

        XCTAssertEqual(outcome, .noRememberedProfile)
        XCTAssertTrue(recorder.readDirectories.isEmpty)
    }

    // MARK: - A refusal re-reads once, and only with a remembered profile

    func testRefusalReadsTheRememberedChromeProfileExactlyOnce() async {
        let recorder = Recorder()
        let reader = makeReader(
            recorder: recorder,
            read: { [freshKey] _ in freshKey }
        )

        let outcome = await refuseOnce(with: reader)

        XCTAssertEqual(outcome, .renewed(sessionKey: freshKey))
        XCTAssertEqual(recorder.readDirectories, ["Profile 19"])
    }

    func testRefusalReadsNothingWhenNoChromeProfileWasRecorded() async {
        let recorder = Recorder()
        let reader = makeReader(
            recorder: recorder,
            read: { [freshKey] _ in freshKey }
        )

        let outcome = await reader.reReadAfterRefusal(
            profileID: profileID,
            profileName: "Work",
            source: nil,
            currentSessionKey: deadKey
        )

        XCTAssertEqual(outcome, .noRememberedProfile)
        XCTAssertTrue(recorder.readDirectories.isEmpty)
        XCTAssertTrue(recorder.savedKeys.isEmpty)
        XCTAssertTrue(recorder.notifications.isEmpty)
    }

    // MARK: - The same dead key changes nothing

    func testUnchangedKeyIsNeitherSavedNorAnnounced() async {
        let recorder = Recorder()
        let reader = makeReader(
            recorder: recorder,
            read: { [deadKey] _ in deadKey }
        )

        let outcome = await refuseOnce(with: reader)

        XCTAssertEqual(outcome, .unchanged)
        XCTAssertEqual(recorder.readDirectories, ["Profile 19"])
        XCTAssertTrue(recorder.savedKeys.isEmpty)
        XCTAssertTrue(recorder.notifications.isEmpty)
    }

    /// The reading that arrived with the refusal keeps its expired verdict
    /// when nothing was renewed, and no retry is spent.
    func testUnchangedKeyKeepsTheExpiredReadingAndDoesNotRetry() async throws {
        var retries = 0
        let usage = try await ClaudeBrowserSignInRecovery.fetch(
            initialFetch: { self.usage(browserSignInIssue: .expired) },
            reRead: { .unchanged },
            retryFetch: { _ in
                retries += 1
                return self.usage(browserSignInIssue: nil)
            }
        )

        XCTAssertEqual(usage.browserSignInIssue, .expired)
        XCTAssertEqual(retries, 0)
    }

    // MARK: - A new key is saved, announced once, and refreshed once

    func testNewKeyIsSavedAndAnnouncedExactlyOnce() async {
        let recorder = Recorder()
        let reader = makeReader(
            recorder: recorder,
            read: { [freshKey] _ in freshKey }
        )

        let outcome = await refuseOnce(with: reader)

        XCTAssertEqual(outcome, .renewed(sessionKey: freshKey))
        XCTAssertEqual(recorder.savedKeys, [freshKey])
        XCTAssertEqual(recorder.notifications.count, 1)
        XCTAssertEqual(recorder.notifications.first?.0, "Work")
        XCTAssertEqual(recorder.notifications.first?.1, "Work — Profile 19")
    }

    func testARenewedKeyDrivesExactlyOneRetry() async throws {
        var retriedWith: [String] = []
        let usage = try await ClaudeBrowserSignInRecovery.fetch(
            initialFetch: { self.usage(browserSignInIssue: .expired) },
            reRead: { .renewed(sessionKey: self.freshKey) },
            retryFetch: { key in
                retriedWith.append(key)
                return self.usage(browserSignInIssue: nil)
            }
        )

        XCTAssertEqual(retriedWith, [freshKey])
        XCTAssertNil(usage.browserSignInIssue)
    }

    /// The refusal that arrives as a thrown error is the same refusal.
    func testAThrownRefusalIsRecoveredAndRetried() async throws {
        var retriedWith: [String] = []
        let usage = try await ClaudeBrowserSignInRecovery.fetch(
            initialFetch: {
                throw AppError.claudeAISessionExpired(statusDetail: "403")
            },
            reRead: { .renewed(sessionKey: self.freshKey) },
            retryFetch: { key in
                retriedWith.append(key)
                return self.usage(browserSignInIssue: nil)
            }
        )

        XCTAssertEqual(retriedWith, [freshKey])
        XCTAssertNil(usage.browserSignInIssue)
    }

    /// An error that is not a browser-session refusal must pass straight
    /// through, untouched and un-re-read.
    func testANonRefusalErrorIsRethrownWithoutAReRead() async {
        var reReads = 0
        do {
            _ = try await ClaudeBrowserSignInRecovery.fetch(
                initialFetch: { throw AppError.apiForbidden() },
                reRead: {
                    reReads += 1
                    return .renewed(sessionKey: self.freshKey)
                },
                retryFetch: { _ in self.usage(browserSignInIssue: nil) }
            )
            XCTFail("A non-refusal error must not be swallowed")
        } catch {
            XCTAssertEqual((error as? AppError)?.code, .apiForbidden)
        }
        XCTAssertEqual(reReads, 0)
    }

    // MARK: - It cannot loop

    func testASecondRefusalWithinAnHourDoesNotReadAgain() async {
        let recorder = Recorder()
        let clock = MutableClock(Date(timeIntervalSince1970: 10_000))
        let reader = makeReader(
            recorder: recorder,
            read: { [deadKey] _ in deadKey },
            now: { clock.value }
        )

        _ = await refuseOnce(with: reader)
        clock.value = clock.value.addingTimeInterval(59 * 60)
        let second = await refuseOnce(with: reader)

        XCTAssertEqual(second, .throttled)
        XCTAssertEqual(recorder.readDirectories, ["Profile 19"])
    }

    func testAnAttemptIsAllowedAgainOnceTheHourHasPassed() async {
        let recorder = Recorder()
        let clock = MutableClock(Date(timeIntervalSince1970: 10_000))
        let reader = makeReader(
            recorder: recorder,
            read: { [deadKey] _ in deadKey },
            now: { clock.value }
        )

        _ = await refuseOnce(with: reader)
        clock.value = clock.value.addingTimeInterval(60 * 60 + 1)
        let second = await refuseOnce(with: reader)

        XCTAssertEqual(second, .unchanged)
        XCTAssertEqual(
            recorder.readDirectories,
            ["Profile 19", "Profile 19"]
        )
    }

    /// A Chrome that cannot be read still spends the hour. Otherwise a
    /// declined macOS prompt would be re-raised on every single refresh.
    func testAFailedReadStillSpendsTheThrottleWindow() async {
        let recorder = Recorder()
        let clock = MutableClock(Date(timeIntervalSince1970: 10_000))
        let reader = makeReader(
            recorder: recorder,
            read: { _ in throw ChromeCookieReadError.keychainAccessDenied },
            now: { clock.value }
        )

        let first = await refuseOnce(with: reader)
        let second = await refuseOnce(with: reader)

        XCTAssertEqual(first, .unreadable)
        XCTAssertEqual(second, .throttled)
        XCTAssertEqual(recorder.readDirectories, ["Profile 19"])
    }

    /// Two profiles are throttled independently.
    func testTheThrottleIsPerProfile() async {
        let recorder = Recorder()
        let reader = makeReader(
            recorder: recorder,
            read: { [deadKey] _ in deadKey }
        )

        _ = await refuseOnce(with: reader)
        let other = await reader.reReadAfterRefusal(
            profileID: UUID(),
            profileName: "Personal",
            source: source,
            currentSessionKey: deadKey
        )

        XCTAssertEqual(other, .unchanged)
        XCTAssertEqual(
            recorder.readDirectories,
            ["Profile 19", "Profile 19"]
        )
    }

    /// Something that is not shaped like a session key is never stored, and
    /// never announced.
    func testAMalformedReadIsNeverStored() async {
        let recorder = Recorder()
        let reader = makeReader(
            recorder: recorder,
            read: { _ in "not-a-session-key" }
        )

        let outcome = await refuseOnce(with: reader)

        XCTAssertEqual(outcome, .malformed)
        XCTAssertTrue(recorder.savedKeys.isEmpty)
        XCTAssertTrue(recorder.notifications.isEmpty)
    }

    /// Secure storage refusing the key is not a renewal, so nothing is
    /// announced and the refresh is not retried.
    func testARefusedSaveIsNotAnnounced() async {
        let recorder = Recorder()
        let reader = makeReader(
            recorder: recorder,
            read: { [freshKey] _ in freshKey },
            saveResult: .failed
        )

        let outcome = await refuseOnce(with: reader)

        XCTAssertEqual(outcome, .saveFailed)
        XCTAssertTrue(recorder.notifications.isEmpty)
    }

    // MARK: - A profile that moved on keeps what it has

    /// The macOS password prompt can sit on screen for minutes, and Settings
    /// stays usable while it does. A key the user stored in the meantime is
    /// the newer one, so the read result is dropped rather than written over
    /// it.
    func testANewerStoredKeyIsNotOverwrittenByTheReadResult() async {
        let recorder = Recorder()
        let profile = SavedProfile(sessionKey: deadKey, source: source)
        let typedKey = "sk-ant-sid01-typed0000000000000"
        let reader = makeCompareAndSetReader(
            recorder: recorder,
            profile: profile,
            read: { [freshKey] _ in
                // Stands in for the user replacing the credential in Settings
                // while the prompt is still up.
                profile.sessionKey = typedKey
                return freshKey
            }
        )

        let outcome = await refuseOnce(with: reader)

        XCTAssertEqual(outcome, .superseded)
        XCTAssertEqual(profile.sessionKey, typedKey)
        XCTAssertTrue(recorder.savedKeys.isEmpty)
        XCTAssertTrue(recorder.notifications.isEmpty)
    }

    /// A key must never be paired with a Chrome profile it did not come from,
    /// so a remembered profile that changed mid-read discards the result too.
    func testAChangedRememberedChromeProfileDiscardsTheReadResult() async {
        let recorder = Recorder()
        let profile = SavedProfile(sessionKey: deadKey, source: source)
        let reader = makeCompareAndSetReader(
            recorder: recorder,
            profile: profile,
            read: { [freshKey] _ in
                profile.source = ProfileChromeSessionKeySource(
                    directoryName: "Profile 4",
                    label: "Personal — Profile 4"
                )
                return freshKey
            }
        )

        let outcome = await refuseOnce(with: reader)

        XCTAssertEqual(outcome, .superseded)
        XCTAssertEqual(profile.sessionKey, deadKey)
        XCTAssertTrue(recorder.savedKeys.isEmpty)
        XCTAssertTrue(recorder.notifications.isEmpty)
    }

    // MARK: - The hour survives a relaunch

    /// Quitting and reopening the app must not buy another macOS password
    /// prompt, so a brand new re-reader honours the hour the previous one
    /// spent.
    func testAFreshReReaderHonoursTheHourFromPersistedState() async {
        let attemptLog = AttemptLog()
        let clock = MutableClock(Date(timeIntervalSince1970: 10_000))
        let first = makeReader(
            recorder: Recorder(),
            read: { [deadKey] _ in deadKey },
            now: { clock.value },
            attemptLog: attemptLog
        )

        _ = await refuseOnce(with: first)

        clock.value = clock.value.addingTimeInterval(59 * 60)
        let restartRecorder = Recorder()
        let afterRestart = makeReader(
            recorder: restartRecorder,
            read: { [deadKey] _ in deadKey },
            now: { clock.value },
            attemptLog: attemptLog
        )

        let outcome = await refuseOnce(with: afterRestart)

        XCTAssertEqual(outcome, .throttled)
        XCTAssertTrue(restartRecorder.readDirectories.isEmpty)
        XCTAssertEqual(attemptLog.value.count, 1)
        XCTAssertNotNil(attemptLog.value[profileID.uuidString])
    }

    /// The persisted log keeps only what the throttle window still covers, so
    /// a long-lived install cannot accumulate an entry per profile forever.
    func testExpiredEntriesArePrunedFromThePersistedLog() async {
        let attemptLog = AttemptLog()
        attemptLog.value = [
            UUID().uuidString: Date(timeIntervalSince1970: 0)
        ]
        let clock = MutableClock(Date(timeIntervalSince1970: 10_000))
        let reader = makeReader(
            recorder: Recorder(),
            read: { [deadKey] _ in deadKey },
            now: { clock.value },
            attemptLog: attemptLog
        )

        _ = await refuseOnce(with: reader)

        XCTAssertEqual(
            Array(attemptLog.value.keys),
            [profileID.uuidString]
        )
    }

    // MARK: - Helpers

    /// The two pieces of a profile the saver has to re-check: the stored key
    /// and the Chrome profile it is remembered as coming from.
    private final class SavedProfile: @unchecked Sendable {
        private let lock = NSLock()
        private var storedKey: String?
        private var storedSource: ProfileChromeSessionKeySource?

        init(sessionKey: String?, source: ProfileChromeSessionKeySource?) {
            storedKey = sessionKey
            storedSource = source
        }

        var sessionKey: String? {
            get {
                lock.lock()
                defer { lock.unlock() }
                return storedKey
            }
            set {
                lock.lock()
                storedKey = newValue
                lock.unlock()
            }
        }

        var source: ProfileChromeSessionKeySource? {
            get {
                lock.lock()
                defer { lock.unlock() }
                return storedSource
            }
            set {
                lock.lock()
                storedSource = newValue
                lock.unlock()
            }
        }
    }

    /// A re-reader whose saver applies the same compare-and-set the real one
    /// does: it writes only when the stored key is still the refused key and
    /// the remembered Chrome profile is still the one that was read.
    private func makeCompareAndSetReader(
        recorder: Recorder,
        profile: SavedProfile,
        read: @escaping @Sendable (String) throws -> String
    ) -> ChromeSessionKeyAutoReReader {
        let attemptLog = AttemptLog()
        return ChromeSessionKeyAutoReReader(
            readSessionKey: { directoryName in
                recorder.recordRead(directoryName)
                return try read(directoryName)
            },
            saveSessionKey: { _, key, refusedKey, readSource in
                guard profile.sessionKey == refusedKey,
                      profile.source?.directoryName
                        == readSource.directoryName else {
                    return .superseded
                }
                profile.sessionKey = key
                recorder.recordSave(key)
                return .stored
            },
            notify: { profileName, chromeLabel in
                recorder.recordNotification(profileName, chromeLabel)
            },
            readAttemptLog: { attemptLog.value },
            writeAttemptLog: { attemptLog.value = $0 }
        )
    }

    private final class MutableClock: @unchecked Sendable {
        var value: Date
        init(_ value: Date) { self.value = value }
    }

    private func refuseOnce(
        with reader: ChromeSessionKeyAutoReReader
    ) async -> ChromeSessionKeyReReadOutcome {
        await reader.reReadAfterRefusal(
            profileID: profileID,
            profileName: "Work",
            source: source,
            currentSessionKey: deadKey
        )
    }

    private func usage(
        browserSignInIssue: ClaudeUsage.BrowserSignInIssue?
    ) -> ClaudeUsage {
        let now = Date(timeIntervalSince1970: 100_000)
        return ClaudeUsage(
            sessionTokensUsed: 0,
            sessionLimit: 100,
            sessionPercentage: 10,
            sessionResetTime: now.addingTimeInterval(3_600),
            weeklyTokensUsed: 0,
            weeklyLimit: 100,
            weeklyPercentage: 10,
            weeklyResetTime: now.addingTimeInterval(604_800),
            opusWeeklyTokensUsed: 0,
            opusWeeklyPercentage: 0,
            sonnetWeeklyTokensUsed: 0,
            sonnetWeeklyPercentage: 0,
            sonnetWeeklyResetTime: now.addingTimeInterval(604_800),
            fableWeeklyTokensUsed: 0,
            fableWeeklyPercentage: 0,
            fableWeeklyResetTime: now.addingTimeInterval(604_800),
            costUsed: nil,
            costLimit: nil,
            costCurrency: nil,
            browserSignInIssue: browserSignInIssue,
            lastUpdated: now,
            userTimezone: TimeZone(secondsFromGMT: 0)!
        )
    }
}
