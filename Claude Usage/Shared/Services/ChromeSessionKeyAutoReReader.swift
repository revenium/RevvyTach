//
//  ChromeSessionKeyAutoReReader.swift
//  Claude Usage
//
//  Re-reads the claude.ai session key from the Chrome profile it originally
//  came from, once claude.ai says the copy is no longer accepted.
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
//  1. It only ever reads the exact Chrome profile a previous Read from Chrome
//     recorded on this RevvyTach profile. A profile with nothing recorded is
//     never read, and nothing here discovers or chooses a Chrome profile.
//  2. It cannot loop. One attempt per profile per hour, whatever the outcome,
//     and never two attempts for one profile at the same time.
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
    /// Chrome could not be read: the cookie database was busy, the macOS
    /// prompt was declined, the cookie is gone, or the format changed.
    case unreadable
    /// Something was read, but it does not have the shape of a session key.
    case malformed
    /// A key was read but secure storage refused to keep it.
    case saveFailed
    /// An attempt for this profile ran less than the throttle window ago.
    case throttled
    /// An attempt for this profile is running right now.
    case alreadyRunning
}

/// Re-reads a revoked claude.ai session key from the remembered Chrome
/// profile.
///
/// Every boundary is injected so tests never touch the real Keychain, the
/// real Chrome, real profile storage, or the real notification centre.
nonisolated final class ChromeSessionKeyAutoReReader: @unchecked Sendable {
    /// Reads the claude.ai session key out of one Chrome profile directory.
    /// Blocking, and blocking on the macOS password prompt at that, so it is
    /// always called off the main thread.
    typealias SessionKeyReader = @Sendable (String) throws -> String
    /// Stores a renewed key on one profile. `false` means nothing was stored.
    typealias CredentialSaver = @Sendable (UUID, String) async -> Bool
    /// Tells the user once, naming the RevvyTach profile and the Chrome
    /// profile in that order.
    typealias Notifier = @Sendable (String, String) async -> Void

    /// At most one attempt per profile per hour. The window is deliberately
    /// long: a refusal repeats on every refresh, and the failure modes here
    /// are a macOS password prompt and a Chrome database read.
    static let defaultMinimumInterval: TimeInterval = 60 * 60

    private let readSessionKey: SessionKeyReader
    private let saveSessionKey: CredentialSaver
    private let notify: Notifier
    private let validator: SessionKeyValidator
    private let now: @Sendable () -> Date
    private let minimumInterval: TimeInterval

    private let lock = NSLock()
    private var lastAttemptAt: [UUID: Date] = [:]
    private var inFlight: Set<UUID> = []

    init(
        readSessionKey: @escaping SessionKeyReader,
        saveSessionKey: @escaping CredentialSaver,
        notify: @escaping Notifier,
        validator: SessionKeyValidator = SessionKeyValidator(),
        now: @escaping @Sendable () -> Date = Date.init,
        minimumInterval: TimeInterval = ChromeSessionKeyAutoReReader
            .defaultMinimumInterval
    ) {
        self.readSessionKey = readSessionKey
        self.saveSessionKey = saveSessionKey
        self.notify = notify
        self.validator = validator
        self.now = now
        self.minimumInterval = minimumInterval
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
        saveSessionKey: { profileID, sessionKey in
            await MainActor.run {
                do {
                    var credentials = try ProfileManager.shared
                        .loadCredentials(for: profileID)
                    credentials.claudeSessionKey = sessionKey
                    try ProfileManager.shared.saveCredentials(
                        for: profileID,
                        credentials: credentials,
                        browserCredentialSave: true
                    )
                    return true
                } catch {
                    LoggingService.shared.logWarning(
                        "A session key re-read from Chrome could not be "
                        + "stored; the profile keeps its expired state."
                    )
                    return false
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
        currentSessionKey: String?
    ) async -> ChromeSessionKeyReReadOutcome {
        guard let source, source.isUsable else {
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
        guard await saveSessionKey(profileID, candidate) else {
            return .saveFailed
        }

        await notify(profileName, source.label)
        return .renewed(sessionKey: candidate)
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
    /// an hour rather than on every refresh.
    private func claimAttempt(for profileID: UUID) -> AttemptClaim {
        lock.lock()
        defer { lock.unlock() }
        guard !inFlight.contains(profileID) else { return .alreadyRunning }
        if let last = lastAttemptAt[profileID],
           now().timeIntervalSince(last) < minimumInterval {
            return .throttled
        }
        lastAttemptAt[profileID] = now()
        inFlight.insert(profileID)
        return .proceed
    }

    private func releaseAttempt(for profileID: UUID) {
        lock.lock()
        inFlight.remove(profileID)
        lock.unlock()
    }
}
