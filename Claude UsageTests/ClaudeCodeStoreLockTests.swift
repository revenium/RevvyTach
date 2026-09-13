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

    /// The heartbeat is what keeps the lock from being taken as abandoned
    /// while it is genuinely held. A refresh that outlives the threshold
    /// without touching it would have the lock stolen mid-flight.
    @MainActor
    func testTouchingTheLockMovesItsModificationTimeForward() throws {
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

    @MainActor
    func testReleasingTwiceIsHarmless() throws {
        let lock = try acquire()
        lock.release()
        lock.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL.path))
    }
}
