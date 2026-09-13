import Darwin
import XCTest
@testable import Claude_Usage

/// The cross-process lock Claude Code takes before it refreshes a token.
///
/// The rules are not ours to choose: Claude Code uses `proper-lockfile`, and
/// a lock that differs in any detail is a different lock, which excludes
/// nobody. So these assert the behaviour of that library rather than of an
/// idea of a lock — a directory made with `mkdir`, a modification time the
/// holder keeps current, and a staleness threshold past which anyone may
/// take it.
///
/// `HostedAppTestCase` and `retain` for the reason that type documents: the
/// app target uses main-actor default isolation, and releasing one of its
/// objects from the XCTest thunk trips a runtime allocator bug that aborts
/// the host.
/// A `FileManager` that lets a test slip a third process in at the one
/// moment `removeOnly` leaves the lock path empty.
///
/// `removeOnly` moves the directory aside, stamps it, and only then decides
/// whether to put it back. That stamp is the single call it makes through
/// the injected file manager while the canonical path is vacant, so running
/// the interloper from here reproduces the three-process window exactly,
/// with no threads and no timing to get lucky with.
private final class InterleavingFileManager: FileManager {
    /// Run once, after the next modification-time change.
    var duringModificationDateChange: (() -> Void)?

    override func setAttributes(
        _ attributes: [FileAttributeKey: Any],
        ofItemAtPath path: String
    ) throws {
        try super.setAttributes(attributes, ofItemAtPath: path)
        let interleave = duringModificationDateChange
        duringModificationDateChange = nil
        interleave?()
    }
}

final class ClaudeCodeStoreLockTests: HostedAppTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    private var lockURL: URL {
        directory.appendingPathComponent(".oauth_refresh.lock")
    }

    @MainActor
    private func acquire(
        staleAfter: TimeInterval = 60
    ) throws -> ClaudeCodeStoreLock {
        retain(
            try ClaudeCodeStoreLock.acquire(
                at: lockURL,
                staleAfter: staleAfter,
                refreshEvery: 5,
                startsHeartbeat: false
            )
        )
    }

    /// Which directory the path names, rather than merely that something is
    /// there. The lock tells its own directory from a replacement by the
    /// `(device, inode)` pair, so the tests have to talk about the same
    /// thing.
    private func identity(
        of url: URL
    ) throws -> (device: dev_t, inode: ino_t) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return (info.st_dev, info.st_ino)
    }

    /// Everything sitting beside the lock. Reclaiming moves a directory
    /// aside before deleting it, and a move that was never finished would
    /// leave that half-done state here.
    private func entriesBesideTheLock() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .sorted()
    }

    private func modificationDate(of url: URL) throws -> Date {
        try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[
                .modificationDate
            ] as? Date
        )
    }

    /// The lock is a directory, not a file. `mkdir(2)` is what makes taking
    /// it atomic: it either creates it or fails, with no gap between asking
    /// whether it exists and creating it.
    @MainActor
    func testTakingTheLockCreatesADirectory() throws {
        let lock = try acquire()

        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: lockURL.path,
                isDirectory: &isDirectory
            )
        )
        XCTAssertTrue(isDirectory.boolValue, "A file would not be atomic")
        XCTAssertFalse(lock.isCompromised)
    }

    /// The whole point. While someone holds it, nobody else gets it — and
    /// this app does not wait, because whoever holds it is refreshing the
    /// very token this tick wanted.
    @MainActor
    func testASecondTakerIsRefusedWhileTheLockIsHeld() throws {
        let held = try acquire()
        defer { held.release() }

        XCTAssertThrowsError(try acquire()) { error in
            XCTAssertEqual(
                error as? ClaudeCodeStoreLock.AcquisitionFailure,
                .heldByAnotherProcess
            )
        }
    }

    /// Releasing removes the directory, so the next taker gets it.
    @MainActor
    func testReleasingGivesTheLockBack() throws {
        try acquire().release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL.path))
        XCTAssertNoThrow(try acquire())
    }

    /// A process that dies holding the lock stops touching the modification
    /// time. Sixty seconds later its lock is abandoned and anyone may take
    /// it — otherwise one crash would stop this account refreshing forever.
    @MainActor
    func testALockNobodyHasTouchedForSixtySecondsIsReclaimed() throws {
        try FileManager.default.createDirectory(
            at: lockURL,
            withIntermediateDirectories: false
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-61)],
            ofItemAtPath: lockURL.path
        )

        let reclaimed = try acquire()
        XCTAssertFalse(reclaimed.isCompromised)
        XCTAssertGreaterThan(
            try modificationDate(of: lockURL),
            Date().addingTimeInterval(-5),
            "Taking it must stamp it as ours"
        )
    }

    /// Fifty-nine seconds is not sixty. A holder that is merely slow still
    /// holds it.
    @MainActor
    func testALockTouchedWithinTheThresholdIsStillHeld() throws {
        try FileManager.default.createDirectory(
            at: lockURL,
            withIntermediateDirectories: false
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-59)],
            ofItemAtPath: lockURL.path
        )

        XCTAssertThrowsError(try acquire()) { error in
            XCTAssertEqual(
                error as? ClaudeCodeStoreLock.AcquisitionFailure,
                .heldByAnotherProcess
            )
        }
    }

    /// The store-write lock goes stale in fifteen seconds rather than sixty,
    /// because it is held across one Keychain write rather than a whole
    /// network round trip.
    @MainActor
    func testTheStaleThresholdIsWhateverTheCallerAsksFor() throws {
        try FileManager.default.createDirectory(
            at: lockURL,
            withIntermediateDirectories: false
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-20)],
            ofItemAtPath: lockURL.path
        )

        XCTAssertThrowsError(try acquire(staleAfter: 60))
        XCTAssertNoThrow(try acquire(staleAfter: 15))
    }

    /// A modification time this holder did not write is somebody else at
    /// the lock, and the holder has to notice rather than carry on. `touch()`
    /// refuses and the lock is marked compromised, which is what later stops
    /// it deleting a directory that is no longer its own.
    @MainActor
    func testATamperedModificationTimeIsDetectedAsTheft() throws {
        let lock = try acquire()
        defer { lock.release() }
        let before = try modificationDate(of: lockURL)

        try FileManager.default.setAttributes(
            [.modificationDate: before.addingTimeInterval(-30)],
            ofItemAtPath: lockURL.path
        )
        // The holder recorded the mtime it set, so it has to re-record the
        // one just written behind its back before the touch can succeed —
        // which is the same thing a real heartbeat does on its next tick.
        XCTAssertFalse(lock.touch(), "An mtime we did not write is a theft")
        XCTAssertTrue(lock.isCompromised)
    }

    /// The heartbeat is what keeps the lock from being taken as abandoned
    /// while it is genuinely held. A refresh that outlives the threshold
    /// without touching it would have the lock stolen mid-flight.
    @MainActor
    func testAHeldLockTouchesItselfWithoutBecomingCompromised() throws {
        let lock = try acquire()
        defer { lock.release() }
        let before = try modificationDate(of: lockURL)

        Thread.sleep(forTimeInterval: 0.02)
        XCTAssertTrue(lock.touch())
        XCTAssertFalse(lock.isCompromised)
        XCTAssertGreaterThan(try modificationDate(of: lockURL), before)
    }

    /// A holder whose lock was reclaimed must never delete the directory on
    /// release: that directory is somebody else's lock now, and removing it
    /// would hand the account to a third process.
    @MainActor
    func testACompromisedLockIsAbandonedRatherThanDeleted() throws {
        let lock = try acquire()

        // Another process decides ours is stale, removes it, and makes its
        // own in the same place.
        try FileManager.default.removeItem(at: lockURL)
        try FileManager.default.createDirectory(
            at: lockURL,
            withIntermediateDirectories: false
        )

        XCTAssertFalse(lock.touch())
        XCTAssertTrue(lock.isCompromised)

        lock.release()
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: lockURL.path),
            "Releasing a stolen lock must not delete the new holder's"
        )
    }

    /// Two processes can look at the same stale lock at the same moment. The
    /// slower one must not delete the fresh directory the faster one has
    /// already put at that path: the lock it judged stale is gone, so there
    /// is nothing left for it to reclaim and it has to be refused. Deleting
    /// it would leave both processes believing they held the lock, and both
    /// spending the same single-use refresh token.
    @MainActor
    func testReclaimingRefusesWhenTheStaleLockHasAlreadyBeenReplaced() throws {
        try FileManager.default.createDirectory(
            at: lockURL,
            withIntermediateDirectories: false
        )
        let stale = try identity(of: lockURL)

        // The faster process gets there first: same path, new directory.
        try FileManager.default.removeItem(at: lockURL)
        try FileManager.default.createDirectory(
            at: lockURL,
            withIntermediateDirectories: false
        )
        let live = try identity(of: lockURL)

        XCTAssertThrowsError(
            try ClaudeCodeStoreLock.removeOnly(
                stale,
                at: lockURL,
                fileManager: .default
            )
        ) { error in
            XCTAssertEqual(
                error as? ClaudeCodeStoreLock.AcquisitionFailure,
                .heldByAnotherProcess
            )
        }

        let survivor = try identity(of: lockURL)
        XCTAssertEqual(survivor.device, live.device)
        XCTAssertEqual(
            survivor.inode,
            live.inode,
            "The other process's lock must be the same directory it was"
        )
        XCTAssertEqual(try entriesBesideTheLock(), [".oauth_refresh.lock"])
    }

    /// The same race with a third process in it, which is the part that was
    /// ours to fix.
    ///
    /// A replacement holder's lock is moved aside, and before it can be put
    /// back a third process finds the vacant path and takes it. The restore
    /// is refused, correctly — overwriting the third process's lock would
    /// be the same wrong in the other direction — and the displaced
    /// directory is then still a live lock with a holder that has noticed
    /// nothing. Deleting it there left that holder and the third process
    /// both believing they held the lock, and both free to spend the same
    /// single-use refresh token. So it stays where it landed, under its
    /// reclaim name, and the abandoned-reclaim sweep clears it once the
    /// stale window has passed.
    @MainActor
    func testADisplacedLockIsKeptWhenItCannotBePutBack() throws {
        try FileManager.default.createDirectory(
            at: lockURL,
            withIntermediateDirectories: false
        )
        let stale = try identity(of: lockURL)

        // The directory this caller judged stale is already gone; what sits
        // at the path now is the replacement holder's live lock.
        try FileManager.default.removeItem(at: lockURL)
        try FileManager.default.createDirectory(
            at: lockURL,
            withIntermediateDirectories: false
        )
        let live = try identity(of: lockURL)

        let path = lockURL
        let fileManager = InterleavingFileManager()
        fileManager.duringModificationDateChange = {
            // The third process, arriving while the path is empty.
            try? FileManager.default.createDirectory(
                at: path,
                withIntermediateDirectories: false
            )
        }

        XCTAssertThrowsError(
            try ClaudeCodeStoreLock.removeOnly(
                stale,
                at: lockURL,
                fileManager: fileManager
            )
        ) { error in
            XCTAssertEqual(
                error as? ClaudeCodeStoreLock.AcquisitionFailure,
                .heldByAnotherProcess
            )
        }

        let entries = try entriesBesideTheLock()
        XCTAssertTrue(
            entries.contains(".oauth_refresh.lock"),
            "The third process's lock must be left alone: \(entries)"
        )
        let displaced = try XCTUnwrap(
            entries.first { $0.hasPrefix(".oauth_refresh.lock.reclaim-") },
            "The displaced live lock must still be there: \(entries)"
        )
        XCTAssertEqual(
            try identity(
                of: directory.appendingPathComponent(displaced)
            ).inode,
            live.inode,
            "What survived must be the very directory that was moved aside"
        )
    }

    /// The lock that really is stale is still reclaimed, and reclaiming it
    /// leaves nothing behind: the directory that went away is gone, and the
    /// one the new holder made is the only thing at the path.
    @MainActor
    func testReclaimingAStaleLockLeavesOnlyTheNewHoldersDirectory() throws {
        try FileManager.default.createDirectory(
            at: lockURL,
            withIntermediateDirectories: false
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-61)],
            ofItemAtPath: lockURL.path
        )
        let abandoned = try identity(of: lockURL)

        let reclaimed = try acquire()
        defer { reclaimed.release() }

        XCTAssertFalse(reclaimed.isCompromised)
        XCTAssertNotEqual(
            try identity(of: lockURL).inode,
            abandoned.inode,
            "Taking it must make a new directory, not adopt the dead one"
        )
        XCTAssertEqual(try entriesBesideTheLock(), [".oauth_refresh.lock"])
    }

    /// A holder only learns its lock was stolen when the heartbeat fires, so
    /// for up to five seconds it still thinks the lock is its own. Releasing
    /// in that window must not delete the directory the new holder made —
    /// which is exactly the logout this lock exists to prevent.
    @MainActor
    func testReleasingDoesNotRemoveADirectoryAnotherProcessPutThere() throws {
        let lock = try acquire()

        // Another process reclaims it as stale. No `touch()` here on
        // purpose: this is the gap between two heartbeats.
        try FileManager.default.removeItem(at: lockURL)
        try FileManager.default.createDirectory(
            at: lockURL,
            withIntermediateDirectories: false
        )
        let replacement = try identity(of: lockURL)
        XCTAssertFalse(lock.isCompromised, "Nothing has noticed yet")

        lock.release()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: lockURL.path),
            "Releasing must not delete a lock that is no longer ours"
        )
        XCTAssertEqual(try identity(of: lockURL).inode, replacement.inode)
        XCTAssertEqual(try entriesBesideTheLock(), [".oauth_refresh.lock"])
    }

    /// Reclaiming moves the dead holder's directory aside before deleting
    /// it, so a process killed between those two steps leaves the moved
    /// directory behind — and quitting is one of the moments that can
    /// happen. Nothing else would ever clear it, so taking the lock clears
    /// the ones nobody can still be working on.
    @MainActor
    func testTakingTheLockClearsLeftoversFromAnInterruptedReclaim() throws {
        let abandoned = directory.appendingPathComponent(
            ".oauth_refresh.lock.reclaim-\(UUID().uuidString)"
        )
        let inProgress = directory.appendingPathComponent(
            ".oauth_refresh.lock.reclaim-\(UUID().uuidString)"
        )
        for leftover in [abandoned, inProgress] {
            try FileManager.default.createDirectory(
                at: leftover,
                withIntermediateDirectories: false
            )
        }
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-61)],
            ofItemAtPath: abandoned.path
        )

        let lock = try acquire()
        defer { lock.release() }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: abandoned.path),
            "A reclaim interrupted a minute ago is never coming back"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: inProgress.path),
            "A reclaim another process is doing right now must survive"
        )
    }

    @MainActor
    func testReleasingTwiceIsHarmless() throws {
        let lock = try acquire()
        lock.release()
        lock.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL.path))
    }
}
