import Foundation
import XCTest
@testable import Claude_Usage

final class UsageHistoryServiceTests: XCTestCase {
    func testMigratesLegacyHistoryOnlyAfterVerifiedFileRoundTrip() async throws {
        try await MainActor.run {
            try testMigratesLegacyHistoryOnlyAfterVerifiedFileRoundTripOnMainActor()
        }
    }

    @MainActor
    private func testMigratesLegacyHistoryOnlyAfterVerifiedFileRoundTripOnMainActor() throws {
        let environment = try makeEnvironment()
        let profileID = UUID()
        let history = makeHistory(percentage: 42)
        let key = "usageHistory_\(profileID.uuidString)"
        environment.defaults.set(try JSONEncoder().encode(history), forKey: key)

        let store = ProfileUsageFileStore(
            baseURL: environment.rootURL,
            now: { Date(timeIntervalSince1970: 500) }
        )
        let service = UsageHistoryService(
            defaults: environment.defaults,
            fileStore: store,
            now: { Date(timeIntervalSince1970: 500) }
        )

        XCTAssertNil(environment.defaults.data(forKey: key))
        XCTAssertEqual(service.loadHistory(for: profileID), history)
        XCTAssertEqual(
            try store.load(
                UsageHistoryData.self,
                for: profileID,
                providerID: "claude",
                kind: .history
            ),
            history
        )

        let fileURL = try store.fileURL(for: profileID, kind: .history)
        let envelope = try JSONDecoder().decode(
            ProfileUsageFileEnvelope<UsageHistoryData>.self,
            from: Data(contentsOf: fileURL)
        )
        XCTAssertEqual(envelope.recordKind, .history)
        XCTAssertEqual(envelope.providerID, "claude")
        XCTAssertEqual(envelope.profileID, profileID)
        XCTAssertEqual(envelope.writtenAt, Date(timeIntervalSince1970: 500))
    }

    func testMigrationIsFailureSafePerLegacyKey() async throws {
        try await MainActor.run {
            try testMigrationIsFailureSafePerLegacyKeyOnMainActor()
        }
    }

    @MainActor
    private func testMigrationIsFailureSafePerLegacyKeyOnMainActor() throws {
        let environment = try makeEnvironment()
        let validProfileID = UUID()
        let invalidProfileID = UUID()
        let validKey = "usageHistory_\(validProfileID.uuidString)"
        let invalidKey = "usageHistory_\(invalidProfileID.uuidString)"
        let history = makeHistory(percentage: 25)
        environment.defaults.set(try JSONEncoder().encode(history), forKey: validKey)
        environment.defaults.set(Data("not-json".utf8), forKey: invalidKey)

        let service = UsageHistoryService(
            defaults: environment.defaults,
            fileStore: ProfileUsageFileStore(baseURL: environment.rootURL)
        )

        XCTAssertNil(environment.defaults.data(forKey: validKey))
        XCTAssertNotNil(environment.defaults.data(forKey: invalidKey))
        XCTAssertEqual(service.loadHistory(for: validProfileID), history)
        XCTAssertTrue(service.loadHistory(for: invalidProfileID).isEmpty)
    }

    func testFailedFileMigrationRetainsLegacyDataAndLoadsFallback() async throws {
        try await MainActor.run {
            try testFailedFileMigrationRetainsLegacyDataAndLoadsFallbackOnMainActor()
        }
    }

    @MainActor
    private func testFailedFileMigrationRetainsLegacyDataAndLoadsFallbackOnMainActor() throws {
        let environment = try makeEnvironment()
        let profileID = UUID()
        let key = "usageHistory_\(profileID.uuidString)"
        let history = makeHistory(percentage: 70)
        environment.defaults.set(try JSONEncoder().encode(history), forKey: key)

        // A regular file cannot contain the per-profile directory, forcing the
        // durable write to fail without relying on process permissions.
        let blockedRootURL = environment.rootURL.appendingPathComponent("blocked")
        try Data("blocking-file".utf8).write(to: blockedRootURL)
        let service = UsageHistoryService(
            defaults: environment.defaults,
            fileStore: ProfileUsageFileStore(baseURL: blockedRootURL)
        )

        XCTAssertNotNil(environment.defaults.data(forKey: key))
        XCTAssertEqual(service.loadHistory(for: profileID), history)
    }

    func testSaveClearAndThrowingDeleteUseFileStorage() async throws {
        try await MainActor.run {
            try testSaveClearAndThrowingDeleteUseFileStorageOnMainActor()
        }
    }

    @MainActor
    private func testSaveClearAndThrowingDeleteUseFileStorageOnMainActor() throws {
        let environment = try makeEnvironment()
        let profileID = UUID()
        let history = UsageHistoryData(
            snapshots: [
                makeSnapshot(type: .sessionReset, percentage: 10),
                makeSnapshot(type: .weeklyReset, percentage: 20)
            ]
        )
        let store = ProfileUsageFileStore(baseURL: environment.rootURL)
        let service = UsageHistoryService(defaults: environment.defaults, fileStore: store)

        service.saveHistory(history, for: profileID)
        XCTAssertEqual(service.loadHistory(for: profileID), history)
        XCTAssertNil(
            environment.defaults.data(forKey: "usageHistory_\(profileID.uuidString)")
        )

        service.clearHistory(for: profileID, resetType: .sessionReset)
        XCTAssertEqual(service.loadHistory(for: profileID).snapshots.count, 1)
        XCTAssertEqual(service.loadHistory(for: profileID).snapshots.first?.resetType, .weeklyReset)

        let legacyKey = "usageHistory_\(profileID.uuidString)"
        let sessionTimestampKey = "lastSessionRecordTime_\(profileID.uuidString)"
        let weeklyTimestampKey = "lastWeeklyRecordTime_\(profileID.uuidString)"
        environment.defaults.set(try JSONEncoder().encode(history), forKey: legacyKey)
        environment.defaults.set(Date(), forKey: sessionTimestampKey)
        environment.defaults.set(Date(), forKey: weeklyTimestampKey)
        try service.deleteHistoryThrowing(for: profileID)
        XCTAssertTrue(service.loadHistory(for: profileID).isEmpty)
        XCTAssertNil(environment.defaults.object(forKey: legacyKey))
        XCTAssertNil(environment.defaults.object(forKey: sessionTimestampKey))
        XCTAssertNil(environment.defaults.object(forKey: weeklyTimestampKey))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: try store.fileURL(for: profileID, kind: .history).path
            )
        )
    }

    func testVerifiedExistingFileWinsOverStaleLegacyKey() async throws {
        try await MainActor.run {
            try testVerifiedExistingFileWinsOverStaleLegacyKeyOnMainActor()
        }
    }

    @MainActor
    private func testVerifiedExistingFileWinsOverStaleLegacyKeyOnMainActor() throws {
        let environment = try makeEnvironment()
        let profileID = UUID()
        let key = "usageHistory_\(profileID.uuidString)"
        let staleHistory = makeHistory(percentage: 5)
        let currentHistory = makeHistory(percentage: 95)
        environment.defaults.set(try JSONEncoder().encode(staleHistory), forKey: key)

        let store = ProfileUsageFileStore(baseURL: environment.rootURL)
        try store.save(
            currentHistory,
            for: profileID,
            providerID: "claude",
            kind: .history
        )
        let service = UsageHistoryService(defaults: environment.defaults, fileStore: store)

        XCTAssertNil(environment.defaults.data(forKey: key))
        XCTAssertEqual(service.loadHistory(for: profileID), currentHistory)
    }

    func testRecordSessionResetRejectsSnapshotWithFutureTriggeringResetTime() async throws {
        try await MainActor.run {
            try testRecordSessionResetRejectsSnapshotWithFutureTriggeringResetTimeOnMainActor()
        }
    }

    /// Reproduces the false-positive reset mechanism directly: Claude's
    /// session window can advance without an actual reset, so
    /// `checkAndRecordSessionReset` sometimes calls `recordSessionReset` with
    /// a `resetTime` that has not happened yet. Before admission, that
    /// snapshot was written and then hidden forever by the display filter.
    ///
    /// `UsageSnapshot.fromSessionReset` stamps `timestamp` from the real
    /// wall clock (not the service's injectable `now`), so `resetTime` is
    /// anchored to `Date.distantFuture` here rather than an offset from an
    /// injected clock, to stay correct regardless of when the test runs.
    @MainActor
    private func testRecordSessionResetRejectsSnapshotWithFutureTriggeringResetTimeOnMainActor() throws {
        let environment = try makeEnvironment()
        let profileID = UUID()
        let service = UsageHistoryService(
            defaults: environment.defaults,
            fileStore: ProfileUsageFileStore(baseURL: environment.rootURL)
        )
        let usage = makeClaudeUsage(sessionPercentage: 55, sessionResetTime: Date())

        service.recordSessionReset(
            for: profileID,
            previousUsage: usage,
            resetTime: .distantFuture
        )

        let history = service.loadHistory(for: profileID)
        XCTAssertTrue(history.snapshots.isEmpty)
        XCTAssertTrue(history.sessionSnapshots.isEmpty)
    }

    func testRecordWeeklyResetRejectsSnapshotWithFutureTriggeringResetTime() async throws {
        try await MainActor.run {
            try testRecordWeeklyResetRejectsSnapshotWithFutureTriggeringResetTimeOnMainActor()
        }
    }

    /// The weekly path builds its snapshot through a different factory
    /// (`fromWeeklyReset`) with a different `resetType`, so admission has to
    /// be verified here too rather than assumed from the session path.
    @MainActor
    private func testRecordWeeklyResetRejectsSnapshotWithFutureTriggeringResetTimeOnMainActor() throws {
        let environment = try makeEnvironment()
        let profileID = UUID()
        let service = UsageHistoryService(
            defaults: environment.defaults,
            fileStore: ProfileUsageFileStore(baseURL: environment.rootURL)
        )
        // Weekly usage must be non-zero, or `recordWeeklyReset` returns
        // early on its "no usage to record" guard and the test would pass
        // without admission ever being consulted.
        let usage = makeClaudeUsage(
            sessionPercentage: 10,
            sessionResetTime: Date(),
            weeklyPercentage: 61
        )

        service.recordWeeklyReset(
            for: profileID,
            previousUsage: usage,
            resetTime: .distantFuture
        )

        let history = service.loadHistory(for: profileID)
        XCTAssertTrue(history.snapshots.isEmpty)
        XCTAssertTrue(history.weeklySnapshots.isEmpty)
    }

    func testPeriodicRecordingIsAdmittedBecauseItsResetTimeIsNeverAhead() async throws {
        try await MainActor.run {
            try testPeriodicRecordingIsAdmittedBecauseItsResetTimeIsNeverAheadOnMainActor()
        }
    }

    /// The two periodic paths differ from the reset paths in a way that
    /// matters for admission: they stamp `triggeringResetTime` from the
    /// injected `now()`, the same clock as `timestamp`, so they are always
    /// admissible and must not be caught by the new rejection. This guards
    /// against an over-eager admission rule silently dropping the periodic
    /// snapshots that make up most of the genuinely useful history.
    @MainActor
    private func testPeriodicRecordingIsAdmittedBecauseItsResetTimeIsNeverAheadOnMainActor() throws {
        let environment = try makeEnvironment()
        let profileID = UUID()
        let now = Date(timeIntervalSince1970: 20_000)
        let service = UsageHistoryService(
            defaults: environment.defaults,
            fileStore: ProfileUsageFileStore(baseURL: environment.rootURL, now: { now }),
            now: { now }
        )

        service.recordSessionPeriodic(
            for: profileID,
            usage: makeClaudeUsage(sessionPercentage: 33, sessionResetTime: now)
        )

        let history = service.loadHistory(for: profileID)
        XCTAssertEqual(history.snapshots.count, 1)
        XCTAssertEqual(history.sessionSnapshots.count, 1)
        XCTAssertEqual(history.sessionSnapshots.first?.sessionPercentage, 33)
    }

    func testNoOpTransformSkipsFileWrite() async throws {
        try await MainActor.run {
            try testNoOpTransformSkipsFileWriteOnMainActor()
        }
    }

    /// `recordSessionReset` with a rejected (future-dated) snapshot is a
    /// no-op transform on the stored history. Confirms `ProfileUsageFileStore
    /// .update` skips the save in that case by asserting the file on disk is
    /// byte-for-byte unchanged, rather than merely asserting the resulting
    /// value is equal.
    @MainActor
    private func testNoOpTransformSkipsFileWriteOnMainActor() throws {
        let environment = try makeEnvironment()
        let profileID = UUID()
        let now = Date(timeIntervalSince1970: 10_000)
        let store = ProfileUsageFileStore(baseURL: environment.rootURL, now: { now })
        let service = UsageHistoryService(
            defaults: environment.defaults,
            fileStore: store,
            now: { now }
        )
        let usage = makeClaudeUsage(sessionPercentage: 30, sessionResetTime: now)
        service.recordSessionReset(
            for: profileID,
            previousUsage: usage,
            resetTime: Date(timeIntervalSince1970: 0)
        )

        // The first write to a brand-new profile has no on-disk primary to
        // archive, so the one-time retention repair is deliberately
        // deferred and the version left unstamped. A second write finds a
        // primary, archives it, repairs, and stamps the version — so it is
        // legitimately not a no-op. Get that out of the way before
        // measuring, or this test would be asserting against the repair
        // rather than against the transform.
        service.recordSessionReset(
            for: profileID,
            previousUsage: usage,
            resetTime: Date(timeIntervalSince1970: 1)
        )

        let fileURL = try store.fileURL(for: profileID, kind: .history)
        let before = try Data(contentsOf: fileURL)

        // Rejected by admission: mutates nothing, so the transform is a
        // true no-op on the stored payload.
        service.recordSessionReset(
            for: profileID,
            previousUsage: usage,
            resetTime: .distantFuture
        )

        let after = try Data(contentsOf: fileURL)
        XCTAssertEqual(before, after)
    }

    // MARK: - HistoryRetentionPolicy

    func testNeedsRepairReflectsRetentionVersion() async throws {
        try await MainActor.run {
            try testNeedsRepairReflectsRetentionVersionOnMainActor()
        }
    }

    @MainActor
    private func testNeedsRepairReflectsRetentionVersionOnMainActor() throws {
        XCTAssertTrue(HistoryRetentionPolicy.needsRepair(UsageHistoryData()))
        XCTAssertTrue(
            HistoryRetentionPolicy.needsRepair(
                UsageHistoryData(retentionVersion: 0)
            )
        )
        XCTAssertFalse(
            HistoryRetentionPolicy.needsRepair(
                UsageHistoryData(retentionVersion: HistoryRetentionPolicy.currentVersion)
            )
        )
    }

    func testPrunedKeepsNewestWithinEachTypeCapAndDropsOldest() async throws {
        try await MainActor.run {
            try testPrunedKeepsNewestWithinEachTypeCapAndDropsOldestOnMainActor()
        }
    }

    @MainActor
    private func testPrunedKeepsNewestWithinEachTypeCapAndDropsOldestOnMainActor() throws {
        let cap = HistoryRetentionPolicy.maxWeeklySnapshots
        let snapshots = (0..<(cap + 10)).map { index in
            makeRawSnapshot(
                type: .weeklyReset,
                timestamp: Date(timeIntervalSince1970: Double(index))
            )
        }

        let pruned = HistoryRetentionPolicy.pruned(snapshots)

        XCTAssertEqual(pruned.count, cap)
        let keptTimestamps = Set(pruned.map(\.timestamp))
        // The newest `cap` records are indices 10..<(cap+10); the oldest 10
        // (indices 0..<10) must be gone.
        for index in 0..<10 {
            XCTAssertFalse(keptTimestamps.contains(Date(timeIntervalSince1970: Double(index))))
        }
        for index in 10..<(cap + 10) {
            XCTAssertTrue(keptTimestamps.contains(Date(timeIntervalSince1970: Double(index))))
        }
    }

    /// The decisive regression test for the danger this policy has to avoid:
    /// measured against real profile data, inadmissible records vastly
    /// outnumber admissible ones and are written no less recently. A pruner
    /// that capped by raw timestamp alone — "keep the newest N regardless of
    /// reachability" — would let that recent garbage crowd out older,
    /// currently-displayed legitimate records: on real files this left as
    /// few as 20 of 500 currently-visible weekly records. This test
    /// reproduces that shape directly: every inadmissible record here is
    /// timestamped *after* every admissible one, so a raw-timestamp cap
    /// would keep only inadmissible records. `pruned` must still surface
    /// every admissible record and none of the inadmissible ones.
    func testPrunedEvictsInadmissibleRecordsRegardlessOfRecency() async throws {
        try await MainActor.run {
            try testPrunedEvictsInadmissibleRecordsRegardlessOfRecencyOnMainActor()
        }
    }

    @MainActor
    private func testPrunedEvictsInadmissibleRecordsRegardlessOfRecencyOnMainActor() throws {
        let admissibleCount = HistoryRetentionPolicy.maxWeeklySnapshots - 5
        let admissible = (0..<admissibleCount).map { index in
            makeRawSnapshot(
                type: .weeklyReset,
                timestamp: Date(timeIntervalSince1970: Double(index))
            )
        }
        // Every inadmissible record is newer than every admissible one, and
        // there are far more of them — exactly the shape measured on real
        // profiles (garbage outnumbers legitimate records and is at least
        // as recent).
        let inadmissible = (0..<10_000).map { index in
            makeRawSnapshot(
                type: .weeklyReset,
                timestamp: Date(timeIntervalSince1970: Double(admissibleCount + index)),
                triggeringResetTime: .distantFuture
            )
        }

        let pruned = HistoryRetentionPolicy.pruned(admissible + inadmissible)

        XCTAssertEqual(pruned.count, admissibleCount)
        XCTAssertEqual(Set(pruned.map(\.id)), Set(admissible.map(\.id)))
    }

    func testPrunedIsIdempotent() async throws {
        try await MainActor.run {
            try testPrunedIsIdempotentOnMainActor()
        }
    }

    @MainActor
    private func testPrunedIsIdempotentOnMainActor() throws {
        let snapshots = (0..<(HistoryRetentionPolicy.maxSessionSnapshots + 50)).map { index in
            makeRawSnapshot(
                type: .sessionReset,
                timestamp: Date(timeIntervalSince1970: Double(index)),
                triggeringResetTime: index.isMultiple(of: 7) ? .distantFuture : Date(timeIntervalSince1970: Double(index))
            )
        }

        let oncePruned = HistoryRetentionPolicy.pruned(snapshots)
        let twicePruned = HistoryRetentionPolicy.pruned(oncePruned)

        XCTAssertEqual(oncePruned.map(\.id), twicePruned.map(\.id))
    }

    func testPrunedOnEmptyArrayIsEmpty() async throws {
        try await MainActor.run {
            XCTAssertTrue(HistoryRetentionPolicy.pruned([]).isEmpty)
        }
    }

    func testRepairedIfNeededIsNoOpWhenAlreadyAtCurrentVersion() async throws {
        try await MainActor.run {
            try testRepairedIfNeededIsNoOpWhenAlreadyAtCurrentVersionOnMainActor()
        }
    }

    @MainActor
    private func testRepairedIfNeededIsNoOpWhenAlreadyAtCurrentVersionOnMainActor() throws {
        let history = UsageHistoryData(
            snapshots: [makeRawSnapshot(type: .sessionReset, triggeringResetTime: .distantFuture)],
            retentionVersion: HistoryRetentionPolicy.currentVersion
        )
        XCTAssertEqual(HistoryRetentionPolicy.repairedIfNeeded(history), history)
    }

    /// Reproduces the leak's real shape at scale — tens of thousands of
    /// inadmissible records outnumbering a small admissible set, as measured
    /// on Jason's live profiles (85,590 stored, 1,500 reachable) — without
    /// committing a multi-megabyte fixture. `pruned` must still converge to
    /// exactly the admissible set.
    func testRegressionFixtureReproducingTheLeakIsFullyRepaired() async throws {
        try await MainActor.run {
            try testRegressionFixtureReproducingTheLeakIsFullyRepairedOnMainActor()
        }
    }

    @MainActor
    private func testRegressionFixtureReproducingTheLeakIsFullyRepairedOnMainActor() throws {
        let admissibleSession = (0..<1000).map { index in
            makeRawSnapshot(
                type: .sessionReset,
                timestamp: Date(timeIntervalSince1970: Double(index) * 600)
            )
        }
        let admissibleWeekly = (0..<500).map { index in
            makeRawSnapshot(
                type: .weeklyReset,
                timestamp: Date(timeIntervalSince1970: Double(index) * 7_200)
            )
        }
        let inadmissible = (0..<85_000).map { index -> UsageSnapshot in
            makeRawSnapshot(
                type: index.isMultiple(of: 2) ? .sessionReset : .weeklyReset,
                timestamp: Date(timeIntervalSince1970: Double(index) * 300),
                triggeringResetTime: .distantFuture
            )
        }
        let raw = admissibleSession + admissibleWeekly + inadmissible
        XCTAssertEqual(raw.count, 86_500)

        let pruned = HistoryRetentionPolicy.pruned(raw)

        XCTAssertEqual(pruned.count, 1_500)
        XCTAssertEqual(
            Set(pruned.map(\.id)),
            Set((admissibleSession + admissibleWeekly).map(\.id))
        )
    }

    // MARK: - Repair archive and interruption safety

    /// The single most important ordering guarantee of this change: the
    /// very first write to a profile whose history predates
    /// `HistoryRetentionPolicy` must archive the pre-repair file before any
    /// record is evicted, and the resulting live file must contain exactly
    /// the admissible records — unaffected by the presence of the far more
    /// numerous inadmissible ones alongside them.
    func testFirstWriteToUnrepairedHistoryArchivesBeforeEvictingUnreachableRecords() async throws {
        try await MainActor.run {
            try testFirstWriteToUnrepairedHistoryArchivesBeforeEvictingUnreachableRecordsOnMainActor()
        }
    }

    @MainActor
    private func testFirstWriteToUnrepairedHistoryArchivesBeforeEvictingUnreachableRecordsOnMainActor() throws {
        let environment = try makeEnvironment()
        let profileID = UUID()
        let now = Date(timeIntervalSince1970: 50_000)
        let store = ProfileUsageFileStore(baseURL: environment.rootURL, now: { now })

        let admissible = makeRawSnapshot(
            type: .sessionReset,
            timestamp: Date(timeIntervalSince1970: 100)
        )
        let inadmissible = (0..<20).map { index in
            makeRawSnapshot(
                type: .sessionReset,
                timestamp: Date(timeIntervalSince1970: 200 + Double(index)),
                triggeringResetTime: .distantFuture
            )
        }
        let preRepair = UsageHistoryData(snapshots: [admissible] + inadmissible)
        try store.save(preRepair, for: profileID, providerID: "claude", kind: .history)

        let service = UsageHistoryService(
            defaults: environment.defaults,
            fileStore: store,
            now: { now }
        )
        service.recordSessionPeriodic(
            for: profileID,
            usage: makeClaudeUsage(sessionPercentage: 40, sessionResetTime: now)
        )

        let historyURL = try store.fileURL(for: profileID, kind: .history)
        let siblingNames = try FileManager.default.contentsOfDirectory(
            atPath: historyURL.deletingLastPathComponent().path
        )
        let archiveName = try XCTUnwrap(
            siblingNames.first { $0.contains(".archive-") }
        )
        let archivedEnvelope = try JSONDecoder().decode(
            ProfileUsageFileEnvelope<UsageHistoryData>.self,
            from: Data(
                contentsOf: historyURL.deletingLastPathComponent()
                    .appendingPathComponent(archiveName)
            )
        )
        // The archive holds every pre-repair record, including the ones
        // about to be evicted.
        XCTAssertEqual(archivedEnvelope.payload.snapshots.count, preRepair.snapshots.count)

        let repaired = service.loadHistory(for: profileID)
        XCTAssertEqual(repaired.retentionVersion, HistoryRetentionPolicy.currentVersion)
        // Exactly the pre-existing admissible record plus the new one just
        // recorded — none of the 20 inadmissible ones survive.
        XCTAssertEqual(repaired.snapshots.count, 2)
        XCTAssertTrue(repaired.snapshots.allSatisfy(HistorySnapshotAdmission.isAdmissible))
        XCTAssertTrue(repaired.snapshots.contains { $0.id == admissible.id })
    }

    func testSecondWriteAfterRepairDoesNotCreateAnotherArchive() async throws {
        try await MainActor.run {
            try testSecondWriteAfterRepairDoesNotCreateAnotherArchiveOnMainActor()
        }
    }

    @MainActor
    private func testSecondWriteAfterRepairDoesNotCreateAnotherArchiveOnMainActor() throws {
        let environment = try makeEnvironment()
        let profileID = UUID()
        let now = Date(timeIntervalSince1970: 60_000)
        let store = ProfileUsageFileStore(baseURL: environment.rootURL, now: { now })

        // Seed data that actually needs repairing, so the first write is
        // guaranteed to archive — otherwise "no second archive" would be
        // true only because no archive was ever needed at all.
        let inadmissible = makeRawSnapshot(
            type: .sessionReset,
            timestamp: Date(timeIntervalSince1970: 100),
            triggeringResetTime: .distantFuture
        )
        try store.save(
            UsageHistoryData(snapshots: [inadmissible]),
            for: profileID,
            providerID: "claude",
            kind: .history
        )

        let service = UsageHistoryService(
            defaults: environment.defaults,
            fileStore: store,
            now: { now }
        )
        let usage = makeClaudeUsage(sessionPercentage: 10, sessionResetTime: now)
        service.recordSessionPeriodic(for: profileID, usage: usage)

        let historyURL = try store.fileURL(for: profileID, kind: .history)
        let siblingDirectory = historyURL.deletingLastPathComponent()
        let archiveCountAfterFirstWrite = try FileManager.default
            .contentsOfDirectory(atPath: siblingDirectory.path)
            .filter { $0.contains(".archive-") }
            .count
        XCTAssertEqual(archiveCountAfterFirstWrite, 1)

        // Already repaired by the first write, so a second write — even one
        // that itself changes nothing prunable — must not archive again.
        service.recordWeeklyPeriodic(for: profileID, usage: usage)
        let archiveCountAfterSecondWrite = try FileManager.default
            .contentsOfDirectory(atPath: siblingDirectory.path)
            .filter { $0.contains(".archive-") }
            .count

        XCTAssertEqual(archiveCountAfterSecondWrite, archiveCountAfterFirstWrite)
    }

    /// Billing cycle history had no cap or repair at all before this
    /// change — `recordBillingCycleReset` called `updateHistory` with no
    /// prune of any kind.
    func testRecordBillingCycleResetIsNowCapped() async throws {
        try await MainActor.run {
            try testRecordBillingCycleResetIsNowCappedOnMainActor()
        }
    }

    @MainActor
    private func testRecordBillingCycleResetIsNowCappedOnMainActor() throws {
        let environment = try makeEnvironment()
        let profileID = UUID()
        let now = Date(timeIntervalSince1970: 70_000)
        let store = ProfileUsageFileStore(baseURL: environment.rootURL, now: { now })

        let existing = (0..<HistoryRetentionPolicy.maxBillingCycleSnapshots).map { index in
            makeRawSnapshot(
                type: .billingCycle,
                timestamp: Date(timeIntervalSince1970: Double(index))
            )
        }
        try store.save(
            UsageHistoryData(snapshots: existing),
            for: profileID,
            providerID: "claude",
            kind: .history
        )

        let service = UsageHistoryService(
            defaults: environment.defaults,
            fileStore: store,
            now: { now }
        )
        let usage = APIUsage(
            currentSpendCents: 500,
            resetsAt: now,
            prepaidCreditsCents: 100,
            currency: "USD",
            apiTokenCostCents: nil,
            apiCostByModel: nil,
            costBySource: nil,
            dailyCostCents: nil
        )
        service.recordBillingCycleReset(for: profileID, previousUsage: usage, resetTime: .distantPast)

        let result = service.loadHistory(for: profileID)
        XCTAssertEqual(result.billingCycleSnapshots.count, HistoryRetentionPolicy.maxBillingCycleSnapshots)
    }

    /// Reproduces an interruption exactly where it is most dangerous: the
    /// archive has already been written, but the process dies before the
    /// corrected (destructive) rewrite lands. The original file must be
    /// completely untouched and still flagged as needing repair, and a
    /// later retry must still succeed.
    func testInterruptedRepairRewriteLeavesOriginalIntactAndStillNeedingRepair() async throws {
        try await MainActor.run {
            try testInterruptedRepairRewriteLeavesOriginalIntactAndStillNeedingRepairOnMainActor()
        }
    }

    @MainActor
    private func testInterruptedRepairRewriteLeavesOriginalIntactAndStillNeedingRepairOnMainActor() throws {
        let environment = try makeEnvironment()
        let profileID = UUID()
        let now = Date(timeIntervalSince1970: 80_000)

        let seedingStore = ProfileUsageFileStore(baseURL: environment.rootURL, now: { now })
        let admissible = makeRawSnapshot(
            type: .sessionReset,
            timestamp: Date(timeIntervalSince1970: 100)
        )
        let inadmissible = makeRawSnapshot(
            type: .sessionReset,
            timestamp: Date(timeIntervalSince1970: 200),
            triggeringResetTime: .distantFuture
        )
        let preRepair = UsageHistoryData(snapshots: [admissible, inadmissible])
        try seedingStore.save(preRepair, for: profileID, providerID: "claude", kind: .history)
        let historyURL = try seedingStore.fileURL(for: profileID, kind: .history)
        let originalBytes = try Data(contentsOf: historyURL)

        // Fails only the primary's install rename (target ends in
        // "history-v1.json", not ".bak"), leaving `.bak` maintenance
        // untouched — the same technique
        // `AtomicJSONFileStoreTests.testTargetRenameFailureLeavesValidPrimaryOnline`
        // uses. The archive step uses `copyItem`, not a rename, so it is
        // unaffected and still completes before this injected failure is
        // ever reached.
        let failingAtomicStore = AtomicJSONFileStore(
            baseURL: environment.rootURL,
            now: { now },
            renameOperation: { source, target in
                guard target.pathExtension == "bak" else {
                    throw InjectedInterruption.expected
                }
                guard Darwin.rename(source.path, target.path) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        )
        let failingStore = ProfileUsageFileStore(atomicStore: failingAtomicStore, now: { now })
        let failingService = UsageHistoryService(
            defaults: environment.defaults,
            fileStore: failingStore,
            now: { now }
        )

        failingService.recordSessionPeriodic(
            for: profileID,
            usage: makeClaudeUsage(sessionPercentage: 5, sessionResetTime: now)
        )

        // The archive succeeded (copyItem is unaffected by renameOperation)
        // but the rewrite's install failed, so the primary is untouched.
        let siblingNames = try FileManager.default.contentsOfDirectory(
            atPath: historyURL.deletingLastPathComponent().path
        )
        XCTAssertTrue(siblingNames.contains { $0.contains(".archive-") })
        XCTAssertEqual(try Data(contentsOf: historyURL), originalBytes)

        let stillUnrepaired = try XCTUnwrap(
            try seedingStore.load(
                UsageHistoryData.self,
                for: profileID,
                providerID: "claude",
                kind: .history
            )
        )
        XCTAssertNil(stillUnrepaired.retentionVersion)

        // A retry through a working store must still succeed. A fresh store
        // with an advanced clock avoids colliding with the archive the
        // failed attempt already wrote — `seedingStore`'s fixed `now`
        // closure would otherwise produce the same
        // `.archive-<epoch-ms>` name twice.
        let retryNow = now.addingTimeInterval(1)
        let retryStore = ProfileUsageFileStore(baseURL: environment.rootURL, now: { retryNow })
        let retryService = UsageHistoryService(
            defaults: environment.defaults,
            fileStore: retryStore,
            now: { retryNow }
        )
        retryService.recordSessionPeriodic(
            for: profileID,
            usage: makeClaudeUsage(sessionPercentage: 5, sessionResetTime: retryNow)
        )
        let repaired = retryService.loadHistory(for: profileID)
        XCTAssertEqual(repaired.retentionVersion, HistoryRetentionPolicy.currentVersion)
        XCTAssertTrue(repaired.snapshots.allSatisfy(HistorySnapshotAdmission.isAdmissible))
    }

    nonisolated private enum InjectedInterruption: Error {
        case expected
    }

    @MainActor
    private func makeRawSnapshot(
        type: ResetType,
        timestamp: Date = Date(timeIntervalSince1970: 1_000),
        triggeringResetTime: Date? = nil
    ) -> UsageSnapshot {
        UsageSnapshot(
            id: UUID(),
            timestamp: timestamp,
            resetType: type,
            triggeringResetTime: triggeringResetTime ?? timestamp
        )
    }

    @MainActor
    private func makeClaudeUsage(
        sessionPercentage: Double,
        sessionResetTime: Date,
        weeklyPercentage: Double = 0
    ) -> ClaudeUsage {
        ClaudeUsage(
            sessionTokensUsed: 1,
            sessionLimit: 100,
            sessionPercentage: sessionPercentage,
            sessionResetTime: sessionResetTime,
            weeklyTokensUsed: weeklyPercentage > 0 ? 1 : 0,
            weeklyLimit: 100,
            weeklyPercentage: weeklyPercentage,
            weeklyResetTime: sessionResetTime,
            opusWeeklyTokensUsed: 0,
            opusWeeklyPercentage: 0,
            sonnetWeeklyTokensUsed: 0,
            sonnetWeeklyPercentage: 0,
            sonnetWeeklyResetTime: nil,
            fableWeeklyTokensUsed: 0,
            fableWeeklyPercentage: 0,
            fableWeeklyResetTime: nil,
            costUsed: nil,
            costLimit: nil,
            costCurrency: nil,
            lastUpdated: sessionResetTime,
            userTimezone: .current
        )
    }

    @MainActor
    private func makeEnvironment() throws -> (
        defaults: UserDefaults,
        rootURL: URL
    ) {
        let (defaults, suiteName) = try HostedTestDefaults.defaults(
            "UsageHistoryServiceTests"
        )
        HostedTestDefaults.reset(defaults, suiteName: suiteName)
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageHistoryServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            HostedTestDefaults.finish(defaults, suiteName: suiteName)
            try? FileManager.default.removeItem(at: rootURL)
        }
        return (defaults, rootURL)
    }

    @MainActor
    private func makeHistory(percentage: Double) -> UsageHistoryData {
        UsageHistoryData(
            snapshots: [
                makeSnapshot(type: .sessionReset, percentage: percentage)
            ]
        )
    }

    @MainActor
    private func makeSnapshot(type: ResetType, percentage: Double) -> UsageSnapshot {
        let date = Date(timeIntervalSince1970: 1_000)
        return UsageSnapshot(
            id: UUID(),
            timestamp: date,
            resetType: type,
            sessionTokensUsed: type == .sessionReset ? 100 : nil,
            sessionPercentage: type == .sessionReset ? percentage : nil,
            weeklyTokensUsed: type == .weeklyReset ? 200 : nil,
            weeklyPercentage: type == .weeklyReset ? percentage : nil,
            triggeringResetTime: date
        )
    }
}
