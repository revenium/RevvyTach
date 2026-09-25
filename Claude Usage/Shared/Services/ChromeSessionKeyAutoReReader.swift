//
//  ChromeSessionKeyAutoReReader.swift
//  Claude Usage
//
//  Re-reads a refused claude.ai session key from its remembered Chrome profile,
//  or discovers an unclaimed Chrome profile for a legacy profile missing one.
//
//  Why this exists. Every `claude /login` performed inside a Chrome profile
//  makes claude.ai log that browser out and back in, which revokes the
//  `sessionKey` cookie RevvyTach copied out of it. The cookie sitting in
//  Chrome right now is fine; only our copy is stale. Before this, the app had
//  no way to notice that: it reported the browser sign-in as expired and
//  waited for someone to open Settings and press Read from Chrome again, per
//  profile and per Mac.
//
//  Three properties are load-bearing:
//
//  1. A remembered source is read directly. Without one, every unclaimed
//     Chrome profile must be checked conclusively, and exactly one must have
//     the profile's saved organization, before a source is recorded.
//  2. It cannot loop. One attempt per profile per hour, whatever the outcome,
//     and never two attempts for one profile at the same time. The hour is
//     remembered on disk, because a declined macOS prompt must not be raised
//     again simply because the app was quit and reopened.
//  3. A key that comes back unchanged writes nothing and says nothing. The
//     profile keeps today's expired state, which is exactly what it had.
//

import Foundation

/// What one automatic re-read did.
nonisolated enum ChromeSessionKeyReReadOutcome: Equatable, Sendable {
    /// A different, well-formed key was read and stored.
    case renewed(sessionKey: String)
    /// Chrome still holds the key claude.ai just refused.
    case unchanged
    /// No Chrome profile was ever recorded for this RevvyTach profile, or the
    /// recorded directory name is no longer one this app will open.
    case noRememberedProfile
    /// No discovered Chrome profile belongs to the saved organization.
    case noMatchingProfile
    /// Several discovered Chrome profiles belong to the saved organization.
    case ambiguousProfiles
    /// Chrome could not be read: the cookie database was busy, the macOS
    /// prompt was declined, the cookie is gone, or the format changed.
    case unreadable
    /// Something was read, but it does not have the shape of a session key.
    case malformed
    /// A key was read but secure storage refused to keep it.
    case saveFailed
    /// The profile's stored credential or its remembered Chrome profile
    /// changed while the read was still running, so what came back described a
    /// pairing the profile has already moved on from. The read result is
    /// discarded rather than written over whatever replaced it.
    case superseded
    /// An attempt for this profile ran less than the throttle window ago.
    case throttled
    /// An attempt for this profile is running right now.
    case alreadyRunning
}

/// What the saver did with a key an automatic re-read produced.
nonisolated enum ChromeSessionKeyReReadSaveResult: Equatable, Sendable {
    /// The key was written to the profile.
    case stored
    /// Storage refused the key.
    case failed
    /// The profile no longer matches the attempt this key belongs to, so the
    /// key was deliberately not written.
    case superseded
}

nonisolated struct ChromeSessionKeyReReadSaveAttempt: Sendable {
    let profileID: UUID
    let sessionKey: String
    let refusedSessionKey: String?
    let organizationID: String?
    let source: ProfileChromeSessionKeySource
    let previousSource: ProfileChromeSessionKeySource?
}

nonisolated enum ChromeSessionKeyCandidateReadOutcome: Sendable {
    case sessionKey(String)
    case absent
    case inconclusive
}

nonisolated struct ChromeSessionKeyCandidateRead: Sendable {
    let profile: ChromeProfile
    let outcome: ChromeSessionKeyCandidateReadOutcome
}

private nonisolated final class ChromePassphraseOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: Result<Data, Error>?

    func read() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        if cached == nil {
            cached = Result {
                try ChromeCookieSessionKeyReader.liveKeychainPassphrase()
            }
        }
        guard let cached else { throw ChromeCookieReadError.keychainItemMissing }
        return try cached.get()
    }

    deinit {
        if case .some(.success(var passphrase)) = cached {
            passphrase.resetBytes(in: 0..<passphrase.count)
        }
    }
}

/// Repairs a revoked claude.ai session key from a remembered or uniquely
/// matching Chrome profile.
///
/// Every boundary is injected so tests never touch the real Keychain, the
/// real Chrome, real profile storage, or the real notification centre.
nonisolated final class ChromeSessionKeyAutoReReader: @unchecked Sendable {
    /// Reads the claude.ai session key out of one Chrome profile directory.
    /// Blocking, and blocking on the macOS password prompt at that, so it is
    /// always called off the main thread.
    typealias SessionKeyReader = @Sendable (String) throws -> String
    /// Stores a renewed key on one profile.
    ///
    /// It is handed the whole attempt, not just the new key: the profile, the
    /// renewed key, the key claude.ai refused when the attempt started, and
    /// the Chrome profile the key was read from. A macOS password prompt can
    /// sit on screen for minutes, and the user is free to replace the
    /// credential in Settings while it does, so the saver has to be able to
    /// check that both of those are still what it started from before it
    /// writes anything.
    typealias CredentialSaver = @Sendable (
        ChromeSessionKeyReReadSaveAttempt
    ) async -> ChromeSessionKeyReReadSaveResult
    typealias ProfileDiscoverer = @Sendable () -> [ChromeProfile]
    typealias CandidateReader = @Sendable (
        [ChromeProfile]
    ) -> [ChromeSessionKeyCandidateRead]
    typealias ClaimedDirectories = @MainActor @Sendable (UUID) -> Set<String>
    typealias OrganizationLookup = @MainActor @Sendable (
        String
    ) async throws -> Set<String>
    /// Tells the user once, naming the RevvyTach profile and the Chrome
    /// profile in that order.
    typealias Notifier = @Sendable (String, String) async -> Void
    /// Reads the persisted last-attempt times, keyed by profile UUID string.
    /// Only those two things are ever kept; no key and nothing secret.
    typealias AttemptLogReader = @Sendable () -> [String: Date]
    /// Replaces the persisted last-attempt times.
    typealias AttemptLogWriter = @Sendable ([String: Date]) -> Void

    /// At most one attempt per profile per hour. The window is deliberately
    /// long: a refusal repeats on every refresh, and the failure modes here
    /// are a macOS password prompt and a Chrome database read.
    static let defaultMinimumInterval: TimeInterval = 60 * 60

    /// Where the hour lives between launches. The value is a dictionary of
    /// profile UUID string to the time that profile was last attempted.
    static let attemptLogDefaultsKey = "chromeSessionKeyAutoReReadLastAttempts"

    private let readSessionKey: SessionKeyReader
    private let discoverProfiles: ProfileDiscoverer
    private let readCandidates: CandidateReader
    private let claimedDirectories: ClaimedDirectories
    private let lookupOrganizations: OrganizationLookup
    private let saveSessionKey: CredentialSaver
    private let notify: Notifier
    private let validator: SessionKeyValidator
    private let now: @Sendable () -> Date
    private let minimumInterval: TimeInterval
    private let readAttemptLog: AttemptLogReader
    private let writeAttemptLog: AttemptLogWriter

    private let lock = NSLock()
    private var lastAttemptAt: [UUID: Date] = [:]
    private var consultedAttemptLog: Set<UUID> = []
    private var inFlight: Set<UUID> = []

    init(
        readSessionKey: @escaping SessionKeyReader,
        saveSessionKey: @escaping CredentialSaver,
        notify: @escaping Notifier,
        discoverProfiles: @escaping ProfileDiscoverer = { [] },
        readCandidates: @escaping CandidateReader = { _ in [] },
        claimedDirectories: @escaping ClaimedDirectories = { _ in [] },
        lookupOrganizations: @escaping OrganizationLookup = { _ in [] },
        validator: SessionKeyValidator = SessionKeyValidator(),
        now: @escaping @Sendable () -> Date = Date.init,
        minimumInterval: TimeInterval = ChromeSessionKeyAutoReReader
            .defaultMinimumInterval,
        readAttemptLog: @escaping AttemptLogReader = {
            ChromeSessionKeyAutoReReader.attemptLogFromStandardDefaults()
        },
        writeAttemptLog: @escaping AttemptLogWriter = { log in
            ChromeSessionKeyAutoReReader.writeAttemptLogToStandardDefaults(log)
        }
    ) {
        self.readSessionKey = readSessionKey
        self.discoverProfiles = discoverProfiles
        self.readCandidates = readCandidates
        self.claimedDirectories = claimedDirectories
        self.lookupOrganizations = lookupOrganizations
        self.saveSessionKey = saveSessionKey
        self.notify = notify
        self.validator = validator
        self.now = now
        self.minimumInterval = minimumInterval
        self.readAttemptLog = readAttemptLog
        self.writeAttemptLog = writeAttemptLog
    }

    private static func attemptLogFromStandardDefaults() -> [String: Date] {
        let stored = UserDefaults.standard
            .dictionary(forKey: attemptLogDefaultsKey) ?? [:]
        return stored.compactMapValues { $0 as? Date }
    }

    private static func writeAttemptLogToStandardDefaults(
        _ log: [String: Date]
    ) {
        UserDefaults.standard.set(log, forKey: attemptLogDefaultsKey)
    }

    /// The instance production uses.
    ///
    /// The read runs on a global queue because it blocks; the save and the
    /// notification hop to the main actor because the services that own them
    /// live there.
    static let shared = ChromeSessionKeyAutoReReader(
        readSessionKey: { directoryName in
            try ChromeCookieSessionKeyReader().readSessionKey(
                profileDirectoryName: directoryName
            )
        },
        saveSessionKey: { attempt in
            // The check and the write share one main-actor hop, so nothing can
            // change the profile in between them.
            await MainActor.run { () -> ChromeSessionKeyReReadSaveResult in
                do {
                    var credentials = try ProfileManager.shared
                        .loadCredentials(for: attempt.profileID)
                    guard credentials.claudeSessionKey
                        == attempt.refusedSessionKey
                    else {
                        LoggingService.shared.logWarning(
                            "The profile's claude.ai session key changed while "
                            + "an automatic re-read from Chrome was running. "
                            + "The newer key was kept and the re-read result "
                            + "discarded."
                        )
                        return .superseded
                    }
                    guard let profile = ProfileManager.shared.profiles
                        .first(where: { $0.id == attempt.profileID }),
                        profile.organizationId == attempt.organizationID,
                        profile.chromeSessionKeySource?.directoryName
                            == attempt.previousSource?.directoryName
                    else {
                        LoggingService.shared.logWarning(
                            "The Chrome profile remembered for this profile "
                            + "changed while an automatic re-read was running. "
                            + "The re-read result was discarded rather than "
                            + "paired with a different browser profile."
                        )
                        return .superseded
                    }
                    if attempt.previousSource == nil,
                        ProfileManager.shared.profiles.contains(where: {
                            $0.id != attempt.profileID
                                && $0.chromeSessionKeySource?.directoryName
                                    == attempt.source.directoryName
                        }) {
                        return .superseded
                    }
                    credentials.claudeSessionKey = attempt.sessionKey
                    try ProfileManager.shared.saveCredentials(
                        for: attempt.profileID,
                        credentials: credentials,
                        browserCredentialSave: true,
                        chromeSessionKeySource: .set(attempt.source)
                    )
                    return .stored
                } catch {
                    LoggingService.shared.logWarning(
                        "A session key re-read from Chrome could not be "
                        + "stored; the profile keeps its expired state."
                    )
                    return .failed
                }
            }
        },
        notify: { profileName, chromeProfileLabel in
            await MainActor.run {
                NotificationManager.shared
                    .sendChromeSessionKeyRefreshedNotification(
                        profileName: profileName,
                        chromeProfileLabel: chromeProfileLabel
                    )
            }
        },
        discoverProfiles: {
            ChromeProfileDiscoverer().discoverProfiles()
        },
        readCandidates: { profiles in
            let passphrase = ChromePassphraseOnce()
            let reader = ChromeCookieSessionKeyReader(
                readKeychainPassphrase: { try passphrase.read() }
            )
            return profiles.map { profile in
                let outcome: ChromeSessionKeyCandidateReadOutcome
                do {
                    outcome = .sessionKey(try reader.readSessionKey(
                        profileDirectoryName: profile.directoryName
                    ))
                } catch ChromeCookieReadError.cookieDatabaseMissing,
                        ChromeCookieReadError.sessionCookieMissing {
                    outcome = .absent
                } catch {
                    outcome = .inconclusive
                }
                return ChromeSessionKeyCandidateRead(
                    profile: profile,
                    outcome: outcome
                )
            }
        },
        claimedDirectories: { profileID in
            Set(ProfileManager.shared.profiles.compactMap { profile in
                profile.id == profileID
                    ? nil : profile.chromeSessionKeySource?.directoryName
            })
        },
        lookupOrganizations: { sessionKey in
            Set(try await ClaudeAPIService()
                .testSessionKey(sessionKey).map(\.uuid))
        }
    )

    /// Attempts one re-read for a profile claude.ai has just refused.
    ///
    /// - Parameters:
    ///   - profileID: the RevvyTach profile whose credential was refused.
    ///   - profileName: shown in the notification, never used to match.
    ///   - source: the Chrome profile a previous Read from Chrome recorded.
    ///   - currentSessionKey: the key claude.ai refused, so an unchanged read
    ///     can be recognised and dropped without a write or a notification.
    @discardableResult
    func reReadAfterRefusal(
        profileID: UUID,
        profileName: String,
        source: ProfileChromeSessionKeySource?,
        currentSessionKey: String?,
        organizationID: String? = nil
    ) async -> ChromeSessionKeyReReadOutcome {
        guard source?.isUsable != false else {
            return .noRememberedProfile
        }
        guard source != nil || organizationID != nil else {
            return .noRememberedProfile
        }
        switch claimAttempt(for: profileID) {
        case .throttled:
            return .throttled
        case .alreadyRunning:
            return .alreadyRunning
        case .proceed:
            break
        }
        defer { releaseAttempt(for: profileID) }

        if let source {
            return await reReadRemembered(
                profileID: profileID,
                profileName: profileName,
                source: source,
                currentSessionKey: currentSessionKey,
                organizationID: organizationID
            )
        }

        guard let organizationID else { return .noRememberedProfile }
        return await discoverAndPair(
            profileID: profileID,
            profileName: profileName,
            currentSessionKey: currentSessionKey,
            organizationID: organizationID
        )
    }

    private func reReadRemembered(
        profileID: UUID,
        profileName: String,
        source: ProfileChromeSessionKeySource,
        currentSessionKey: String?,
        organizationID: String?
    ) async -> ChromeSessionKeyReReadOutcome {
        let directoryName = source.directoryName
        let read: Result<String, Error> = await withCheckedContinuation {
            continuation in
            DispatchQueue.global(qos: .utility).async { [readSessionKey] in
                continuation.resume(
                    returning: Result { try readSessionKey(directoryName) }
                )
            }
        }

        guard let candidate = try? read.get() else {
            // Nothing here names the failure to the user. A read they did not
            // ask for must not raise a complaint about a browser they may not
            // even have open; the profile keeps the expired state it already
            // had, and Settings still explains it.
            LoggingService.shared.log(
                "An automatic session key re-read from the remembered Chrome "
                + "profile did not produce a key. The profile keeps its "
                + "expired browser sign-in."
            )
            return .unreadable
        }

        guard validator.isValid(candidate) else { return .malformed }
        guard candidate != currentSessionKey else { return .unchanged }
        switch await saveSessionKey(ChromeSessionKeyReReadSaveAttempt(
            profileID: profileID,
            sessionKey: candidate,
            refusedSessionKey: currentSessionKey,
            organizationID: organizationID,
            source: source,
            previousSource: source
        )) {
        case .stored:
            break
        case .failed:
            return .saveFailed
        case .superseded:
            return .superseded
        }

        await notify(profileName, source.label)
        return .renewed(sessionKey: candidate)
    }

    private func discoverAndPair(
        profileID: UUID,
        profileName: String,
        currentSessionKey: String?,
        organizationID: String
    ) async -> ChromeSessionKeyReReadOutcome {
        let claimed = await claimedDirectories(profileID)
        let discovered: (
            profiles: [ChromeProfile],
            reads: [ChromeSessionKeyCandidateRead]
        ) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                [discoverProfiles, readCandidates] in
                let profiles = discoverProfiles().filter {
                    !claimed.contains($0.directoryName)
                }
                continuation.resume(returning: (
                    profiles: profiles,
                    reads: readCandidates(profiles)
                ))
            }
        }

        let expected = Set(discovered.profiles.map(\.directoryName))
        let received = Set(discovered.reads.map {
            $0.profile.directoryName
        })
        guard expected.count == discovered.profiles.count,
            received == expected,
            discovered.reads.count == discovered.profiles.count else {
            LoggingService.shared.logWarning(
                "Chrome profile discovery did not yield one result per "
                    + "eligible profile; automatic pairing was skipped."
            )
            return .unreadable
        }

        var matches: [(ChromeProfile, String)] = []
        for read in discovered.reads {
            switch read.outcome {
            case .absent:
                continue
            case .inconclusive:
                LoggingService.shared.log(
                    "A Chrome profile could not be checked conclusively; "
                        + "automatic pairing was skipped."
                )
                return .unreadable
            case .sessionKey(let candidate):
                guard validator.isValid(candidate) else {
                    return .malformed
                }
                guard let organizations = try? await lookupOrganizations(
                    candidate
                ) else {
                    LoggingService.shared.log(
                        "A Chrome account's organizations could not be "
                            + "checked; automatic pairing was skipped."
                    )
                    return .unreadable
                }
                if organizations.contains(organizationID) {
                    matches.append((read.profile, candidate))
                }
            }
        }

        guard matches.count == 1 else {
            LoggingService.shared.log(
                "Automatic Chrome pairing found \(matches.count) matching "
                    + "profiles; the expired sign-in was kept."
            )
            return matches.isEmpty ? .noMatchingProfile : .ambiguousProfiles
        }
        let (chromeProfile, candidate) = matches[0]
        guard candidate != currentSessionKey else { return .unchanged }
        let source = ProfileChromeSessionKeySource(
            directoryName: chromeProfile.directoryName,
            label: chromeProfile.label
        )
        switch await saveSessionKey(ChromeSessionKeyReReadSaveAttempt(
            profileID: profileID,
            sessionKey: candidate,
            refusedSessionKey: currentSessionKey,
            organizationID: organizationID,
            source: source,
            previousSource: nil
        )) {
        case .stored:
            await notify(profileName, source.label)
            return .renewed(sessionKey: candidate)
        case .failed:
            return .saveFailed
        case .superseded:
            return .superseded
        }
    }

    // MARK: - Throttle

    private enum AttemptClaim: Equatable {
        case proceed
        case throttled
        case alreadyRunning
    }

    /// Records an attempt and reports whether it may run.
    ///
    /// The timestamp is written for every attempt that starts, not only for
    /// the ones that succeed, so a Chrome that cannot be read is retried once
    /// an hour rather than on every refresh. It is also written to disk: the
    /// startup refresh is exactly when a re-read is attempted, so an hour that
    /// only lived in memory would be spent again by every relaunch, and a
    /// declined macOS prompt would come back with it.
    private func claimAttempt(for profileID: UUID) -> AttemptClaim {
        lock.lock()
        defer { lock.unlock() }
        guard !inFlight.contains(profileID) else { return .alreadyRunning }
        if !consultedAttemptLog.contains(profileID) {
            consultedAttemptLog.insert(profileID)
            if lastAttemptAt[profileID] == nil,
               let persisted = readAttemptLog()[profileID.uuidString] {
                lastAttemptAt[profileID] = persisted
            }
        }
        if let last = lastAttemptAt[profileID],
           now().timeIntervalSince(last) < minimumInterval {
            return .throttled
        }
        let attemptedAt = now()
        lastAttemptAt[profileID] = attemptedAt
        persistAttempt(at: attemptedAt, for: profileID)
        inFlight.insert(profileID)
        return .proceed
    }

    /// Records this attempt on disk, dropping every entry the throttle window
    /// has already expired so a Mac with many profiles cannot grow the stored
    /// dictionary without bound.
    private func persistAttempt(at attemptedAt: Date, for profileID: UUID) {
        var log = readAttemptLog().filter { _, recordedAt in
            attemptedAt.timeIntervalSince(recordedAt) < minimumInterval
        }
        log[profileID.uuidString] = attemptedAt
        writeAttemptLog(log)
    }

    private func releaseAttempt(for profileID: UUID) {
        lock.lock()
        inFlight.remove(profileID)
        lock.unlock()
    }
}
