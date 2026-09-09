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
        saveSucceeds: Bool = true,
        now: @escaping @Sendable () -> Date = Date.init,
        minimumInterval: TimeInterval = ChromeSessionKeyAutoReReader
            .defaultMinimumInterval
    ) -> ChromeSessionKeyAutoReReader {
        ChromeSessionKeyAutoReReader(
            readSessionKey: { directoryName in
                recorder.recordRead(directoryName)
                return try read(directoryName)
            },
            saveSessionKey: { _, key in
                guard saveSucceeds else { return false }
                recorder.recordSave(key)
                return true
            },
            notify: { profileName, chromeLabel in
                recorder.recordNotification(profileName, chromeLabel)
            },
            now: now,
            minimumInterval: minimumInterval
        )
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
            saveSucceeds: false
        )

        let outcome = await refuseOnce(with: reader)

        XCTAssertEqual(outcome, .saveFailed)
        XCTAssertTrue(recorder.notifications.isEmpty)
    }

    // MARK: - Helpers

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
