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
/// `<configDir>/.storage-write.lock` before it writes its credential store,
/// both through the `proper-lockfile` npm package. A lock that differs in any
/// detail is not the same lock, and two programs holding two different locks
/// exclude nothing — including two that differ only by a suffix.
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
    /// stale is simply held, and a stale one is moved out of the way and the
    /// `mkdir` tried exactly once more. That "once more" matters — looping
    /// would let two processes that both saw the same stale lock take turns
    /// removing each other's fresh one. Moving the stale directory aside
    /// rather than deleting whatever is at the path is what stops the same
    /// two processes from doing it even once; see `removeOnly`.
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

        // Stale: the holder died. Take away the directory we just looked at,
        // and only that one — by now another process may have reclaimed it
        // and be holding a brand new directory at the same path.
        if let staleIdentity = identity(of: url) {
            try removeOnly(
                staleIdentity,
                at: url,
                fileManager: fileManager
            )
        }
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
        // Taking the lock is the one moment this folder is already being
        // looked at, so it is where the leftovers get tidied.
        sweepAbandonedReclaims(
            beside: url,
            staleAfter: staleAfter,
            fileManager: fileManager
        )
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

    /// Removes the directory at a path, but only if it is still the one the
    /// caller means — the one whose `(device, inode)` it was given.
    ///
    /// Deleting by path is the whole bug this avoids. Two processes can both
    /// decide the same lock is stale; if each simply deleted the path, the
    /// slower one would delete the fresh directory the faster one had already
    /// made, make its own, and both would go on believing they held the lock.
    /// The same thing happens on release, where "is this still mine" is only
    /// as current as the last heartbeat.
    ///
    /// So the directory is moved rather than deleted. `rename(2)` happens in
    /// one step, so of two processes racing for the same directory exactly
    /// one moves it; the other finds it has moved something else, puts it
    /// straight back, and gives up. `RENAME_EXCL` on the way back refuses to
    /// overwrite, so a third directory that appeared at the path in the
    /// meantime survives — and so does the one we should never have
    /// touched, left where it landed under its reclaim name for the
    /// abandoned-reclaim sweep to clear once the stale window has passed.
    /// Deleting it instead would cost exactly what deleting by path costs:
    /// its holder goes on believing it holds the lock, the third process
    /// believes the same, and both spend the same single-use refresh token.
    ///
    /// Throws `heldByAnotherProcess` when the path holds somebody else's
    /// directory. A path with nothing at it is not a failure: there is
    /// nothing left to remove.
    static func removeOnly(
        _ identity: (device: dev_t, inode: ino_t),
        at url: URL,
        fileManager: FileManager
    ) throws {
        let movedPath = "\(url.path).reclaim-\(UUID().uuidString)"
        guard rename(url.path, movedPath) == 0 else {
            let failure = errno
            if failure == ENOENT { return }
            throw AcquisitionFailure.heldByAnotherProcess
        }

        let moved = URL(fileURLWithPath: movedPath)
        // A moved directory keeps the modification time it had, and a stale
        // lock's is old by definition — which is exactly what the leftover
        // sweep looks for. Stamping it as of now is how a reclaim happening
        // this instant is told apart from one that was interrupted.
        setModificationDate(Date(), of: moved, fileManager: fileManager)
        guard let movedIdentity = self.identity(of: moved),
              movedIdentity == identity else {
            // Somebody else's lock, and it may well be live. Put it back
            // when the path is still vacant; when a third process has
            // already taken the path, leave the displaced directory exactly
            // where it landed rather than delete it. A live lock that is
            // deleted is the whole failure this function exists to avoid —
            // its holder would keep believing it held the lock, the third
            // process would believe the same, and both would spend the same
            // single-use refresh token. Under its reclaim name it is out of
            // everyone's way and the sweep above clears it once it is stale.
            _ = renamex_np(movedPath, url.path, UInt32(RENAME_EXCL))
            throw AcquisitionFailure.heldByAnotherProcess
        }

        try? fileManager.removeItem(at: moved)
    }

    /// Clears away the directories an interrupted reclaim left behind.
    ///
    /// Taking a lock from a dead holder moves its directory aside and then
    /// deletes it. A process killed between those two steps — and release
    /// runs from `deinit`, so quitting is one of the moments this can happen
    /// — leaves the moved directory sitting in the credential folder with
    /// nobody left to delete it, and every such death would leave one more.
    ///
    /// Only directories beside this lock, named after it, and untouched for
    /// longer than the stale window are cleared: a reclaim that is happening
    /// right now stamps what it moved, so nothing another process is in the
    /// middle of can look this old. Every failure is ignored, because a
    /// folder that cannot be tidied is no reason to refuse a lock.
    private static func sweepAbandonedReclaims(
        beside url: URL,
        staleAfter: TimeInterval,
        fileManager: FileManager
    ) {
        let folder = url.deletingLastPathComponent()
        let prefix = "\(url.lastPathComponent).reclaim-"
        guard let names = try? fileManager.contentsOfDirectory(
            atPath: folder.path
        ) else { return }
        for name in names where name.hasPrefix(prefix) {
            let leftover = folder.appendingPathComponent(name)
            guard let modified = modificationDate(
                of: leftover,
                fileManager: fileManager
            ), Date().timeIntervalSince(modified) > staleAfter else { continue }
            try? fileManager.removeItem(at: leftover)
        }
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
    ///
    /// Being compromised is only ever noticed on a heartbeat, though, so
    /// between two beats the flag still says "ours" about a lock somebody
    /// else reclaimed seconds ago. That is why the directory itself is
    /// checked here rather than trusted: what comes away has to be the very
    /// directory this lock made, and anything else goes back untouched. A
    /// lock that never learned which directory it made removes nothing.
    func release() {
        mutex.lock()
        let timer = heartbeat
        heartbeat = nil
        let shouldRemove = !released && !compromisedFlag
        released = true
        mutex.unlock()

        timer?.cancel()
        guard shouldRemove, let identity else { return }
        try? Self.removeOnly(identity, at: url, fileManager: fileManager)
    }

    deinit {
        // Defence in depth: every call site releases through a `defer`, but a
        // lock that were ever dropped without one would keep its directory
        // and block Claude Code for the whole stale window — sixty seconds
        // for a refresh.
        release()
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
