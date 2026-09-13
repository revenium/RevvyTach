//
//  ClaudeCodeStoreLock.swift
//  Claude Usage
//
//  The cross-process lock Claude Code takes before it refreshes a token,
//  built to the same rules so that taking it actually excludes Claude Code.
//

import Darwin
import Foundation

/// A cross-process lock with `proper-lockfile` semantics.
///
/// This is not a lock of our own design. Claude Code takes
/// `<configDir>/.oauth_refresh.lock` before it refreshes an OAuth token and
/// `<configDir>/.storage-write` before it writes its credential store, both
/// through the `proper-lockfile` npm package. A lock that differs in any
/// detail is not the same lock, and two programs holding two different locks
/// exclude nothing.
///
/// The lock **is a directory**. `mkdir(2)` either creates it or fails with
/// `EEXIST`, in one syscall with no window between asking and taking — which
/// is the whole reason a directory is used rather than a file plus an
/// existence check.
///
/// A holder keeps the directory's modification time current. A lock whose
/// mtime is older than `staleAfter` belonged to a process that died holding
/// it, and any other process may remove it and take it. That is what the
/// heartbeat is for: stop touching the directory and, `staleAfter` later,
/// it stops being yours.
///
/// If the mtime changes to something this holder did not write, another
/// process has reclaimed the lock as stale and now owns it. The lock is then
/// *compromised*: it must not be released, because releasing it would delete
/// a directory that is now someone else's lock.
/// Deliberately `nonisolated`: the heartbeat fires on a background queue,
/// and a lock that could only be touched from the main actor would go stale
/// every time the main actor was busy — which, during a token refresh, it
/// always is.
nonisolated final class ClaudeCodeStoreLock: @unchecked Sendable {
    enum AcquisitionFailure: Error, Equatable {
        /// Another live process holds it. Claude Code waits and retries here;
        /// this app deliberately does not — a refresh it skips is a refresh
        /// the other process is already performing, and its result is
        /// readable on the next tick.
        case heldByAnotherProcess
        /// The lock directory could not be created for some reason other
        /// than its already existing.
        case filesystem(String)
    }

    let url: URL
    private let staleAfter: TimeInterval
    private let fileManager: FileManager
    private let mutex = NSLock()
    private var recordedModificationDate: Date
    /// Which directory this is, not merely which path. A lock reclaimed as
    /// stale is removed and made again, so the path stays the same and the
    /// inode does not — and an inode is exact, where "is the modification
    /// time the one I wrote" depends on how fast the other process was.
    private let identity: (device: dev_t, inode: ino_t)?
    private var released = false
    private var compromisedFlag = false
    private var heartbeat: DispatchSourceTimer?

    /// Whether another process has taken this lock out from under us.
    var isCompromised: Bool {
        mutex.lock()
        defer { mutex.unlock() }
        return compromisedFlag
    }

    private init(
        url: URL,
        staleAfter: TimeInterval,
        modificationDate: Date,
        identity: (device: dev_t, inode: ino_t)?,
        fileManager: FileManager
    ) {
        self.url = url
        self.staleAfter = staleAfter
        self.recordedModificationDate = modificationDate
        self.identity = identity
        self.fileManager = fileManager
    }

    /// Takes the lock, or says who has it.
    ///
    /// One `mkdir`. On `EEXIST`, one look at the mtime: a lock that is not
    /// stale is simply held, and a stale one is removed and the `mkdir`
    /// tried exactly once more. That "once more" matters — looping would let
    /// two processes that both saw the same stale lock take turns removing
    /// each other's fresh one.
    ///
    /// - Parameters:
    ///   - staleAfter: how old the mtime must be before the lock counts as
    ///     abandoned. 60 seconds for the refresh lock, 15 for the store
    ///     write, matching Claude Code.
    ///   - refreshEvery: how often the holder touches the mtime.
    ///   - startsHeartbeat: tests drive `touch()` themselves rather than
    ///     waiting on a timer.
    static func acquire(
        at url: URL,
        staleAfter: TimeInterval,
        refreshEvery: TimeInterval,
        startsHeartbeat: Bool = true,
        fileManager: FileManager = .default
    ) throws -> ClaudeCodeStoreLock {
        if let lock = try make(at: url, staleAfter: staleAfter, fileManager: fileManager) {
            lock.startHeartbeatIfNeeded(startsHeartbeat, every: refreshEvery)
            return lock
        }

        guard let existingModification = modificationDate(
            of: url,
            fileManager: fileManager
        ) else {
            // It vanished between the `mkdir` and the `stat`: whoever held it
            // released it. One more try, and no further — a lock that keeps
            // disappearing is a lock someone else is actively cycling.
            guard let lock = try make(
                at: url,
                staleAfter: staleAfter,
                fileManager: fileManager
            ) else { throw AcquisitionFailure.heldByAnotherProcess }
            lock.startHeartbeatIfNeeded(startsHeartbeat, every: refreshEvery)
            return lock
        }

        guard Date().timeIntervalSince(existingModification) > staleAfter else {
            throw AcquisitionFailure.heldByAnotherProcess
        }

        // Stale: the holder died. Remove it and take it.
        try? fileManager.removeItem(at: url)
        guard let lock = try make(
            at: url,
            staleAfter: staleAfter,
            fileManager: fileManager
        ) else { throw AcquisitionFailure.heldByAnotherProcess }
        lock.startHeartbeatIfNeeded(startsHeartbeat, every: refreshEvery)
        return lock
    }

    /// `nil` when the directory already exists; throws for any other failure.
    private static func make(
        at url: URL,
        staleAfter: TimeInterval,
        fileManager: FileManager
    ) throws -> ClaudeCodeStoreLock? {
        // 0o700: a lock in a credential directory has no business being
        // readable by anyone else, and its mere presence says which account
        // is being refreshed.
        guard mkdir(url.path, S_IRWXU) == 0 else {
            let failure = errno
            if failure == EEXIST { return nil }
            throw AcquisitionFailure.filesystem(
                "mkdir \(url.lastPathComponent) failed with errno \(failure)"
            )
        }
        let stamp = Date()
        setModificationDate(stamp, of: url, fileManager: fileManager)
        return ClaudeCodeStoreLock(
            url: url,
            staleAfter: staleAfter,
            modificationDate: modificationDate(
                of: url,
                fileManager: fileManager
            ) ?? stamp,
            identity: identity(of: url),
            fileManager: fileManager
        )
    }

    private func startHeartbeatIfNeeded(
        _ shouldStart: Bool,
        every interval: TimeInterval
    ) {
        guard shouldStart else { return }
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(
                label: "com.claudeusage.claudecodestorelock.heartbeat"
            )
        )
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.touch()
        }
        timer.resume()
        mutex.lock()
        heartbeat = timer
        mutex.unlock()
    }

    /// Says "still here" by moving the mtime forward.
    ///
    /// Also the moment a stolen lock is noticed: an mtime this holder did not
    /// write means another process decided the lock was stale, removed it and
    /// made its own.
    @discardableResult
    func touch() -> Bool {
        mutex.lock()
        defer { mutex.unlock() }
        guard !released, !compromisedFlag else { return false }

        // A different directory at the same path means another process
        // decided this lock was stale, removed it and made its own.
        guard let currentIdentity = Self.identity(of: url),
              let identity,
              currentIdentity == identity else {
            compromisedFlag = true
            return false
        }

        guard let current = Self.modificationDate(
            of: url,
            fileManager: fileManager
        ) else {
            compromisedFlag = true
            return false
        }
        // A filesystem may store mtimes at second or nanosecond precision, so
        // this is "did it move", not "is it bit-identical".
        guard abs(current.timeIntervalSince(recordedModificationDate)) < 0.001
        else {
            compromisedFlag = true
            return false
        }

        let stamp = Date()
        Self.setModificationDate(stamp, of: url, fileManager: fileManager)
        recordedModificationDate = Self.modificationDate(
            of: url,
            fileManager: fileManager
        ) ?? stamp
        return true
    }

    /// Gives the lock up. Idempotent.
    ///
    /// A compromised lock is abandoned rather than removed: the directory at
    /// that path is another process's lock now, and deleting it would hand
    /// the account to a third.
    func release() {
        mutex.lock()
        let timer = heartbeat
        heartbeat = nil
        let shouldRemove = !released && !compromisedFlag
        released = true
        mutex.unlock()

        timer?.cancel()
        guard shouldRemove else { return }
        try? fileManager.removeItem(at: url)
    }

    deinit {
        heartbeat?.cancel()
    }

    /// `(device, inode)` — which directory this path currently names.
    private static func identity(
        of url: URL
    ) -> (device: dev_t, inode: ino_t)? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return (info.st_dev, info.st_ino)
    }

    private static func modificationDate(
        of url: URL,
        fileManager: FileManager
    ) -> Date? {
        try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate]
            as? Date
    }

    private static func setModificationDate(
        _ date: Date,
        of url: URL,
        fileManager: FileManager
    ) {
        try? fileManager.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: url.path
        )
    }
}
