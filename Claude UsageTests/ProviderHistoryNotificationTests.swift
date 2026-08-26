import Foundation
import UsageCore
import UserNotifications
import XCTest
@testable import Claude_Usage

@MainActor
final class ProviderHistoryNotificationTests: HostedAppTestCase {

    // MARK: - Cycle identity stability

    /// The master switch must not be built on top of the legacy
    /// single-profile `notificationsEnabled` key.
    ///
    /// `ProfileMigrationService` reads that key to seed a migrating
    /// installation's per-profile `NotificationSettings.enabled`, and the
    /// original single-profile toggle did write it before the multi-profile
    /// refactor. Flipping its missing-key default to `true` to serve the
    /// master switch would silently change migration from off-by-default to
    /// on-by-default for installs that never touched the old toggle. The two
    /// concerns therefore use two keys with two different defaults.
    func testMasterSwitchAndLegacyMigrationKeysHaveIndependentDefaults()
        throws {
        let (defaults, suiteName) = try HostedTestDefaults.defaults(
            "test.notification.keys"
        )
        defer { HostedTestDefaults.finish(defaults, suiteName: suiteName) }

        XCTAssertTrue(
            DataStore.masterSwitchEnabled(in: defaults),
            "An absent master-switch key must mean enabled, or every "
                + "upgrading user is silently muted"
        )
        XCTAssertFalse(
            defaults.bool(forKey: "notificationsEnabled"),
            "The legacy migration key must keep its original "
                + "off-by-default meaning"
        )

        defaults.set(false, forKey: "notificationsMasterSwitchEnabled")
        XCTAssertFalse(DataStore.masterSwitchEnabled(in: defaults))
        XCTAssertFalse(
            defaults.bool(forKey: "notificationsEnabled"),
            "Toggling the master switch must not touch the migration key"
        )
    }


    /// The legacy CSV-export path builds its own cycle identity, and until
    /// this PR it did so from a raw bit pattern while normalized rows used
    /// the quantized form — one file, two incompatible formats for the same
    /// concept. The export is exercised by other tests, but none assert the
    /// Cycle ID column's value, so a format divergence there would be
    /// invisible.
    ///
    /// Asserts the legacy path is quantized identically to the normalized
    /// path, using a jittered reset-time pair rather than a single value:
    /// equality alone would also hold if both sides were raw.
    func testLegacyExportCycleIDIsQuantizedLikeNormalizedWindows() throws {
        let jitteredPair = (807_826_200.293_999_910, 807_826_200.236_000_061)

        let first = NormalizedUsageSnapshot.resetCycleID(
            forResetTime: Date(
                timeIntervalSinceReferenceDate: jitteredPair.0
            )
        )
        let second = NormalizedUsageSnapshot.resetCycleID(
            forResetTime: Date(
                timeIntervalSinceReferenceDate: jitteredPair.1
            )
        )
        XCTAssertEqual(
            first,
            second,
            "Legacy export cycle IDs must absorb the same provider jitter "
                + "the normalized path does"
        )

        let normalizedWindow = try UsageWindow(
            id: UsageWindowID("session"),
            displayName: "Session",
            usedPercentage: 42,
            resetsAt: Date(
                timeIntervalSinceReferenceDate: jitteredPair.0
            )
        )
        XCTAssertEqual(
            first,
            NormalizedUsageSnapshot.cycleID(for: normalizedWindow),
            "A legacy row and a normalized row describing the same reset "
                + "instant must carry the same cycle identity in one export"
        )
    }


    /// Cycle identity must survive the sub-second jitter providers actually
    /// report, because identity is what downstream reset detection and
    /// history de-duplication both key on.
    ///
    /// The timestamps below are real values captured from a live machine,
    /// sampled 50 seconds apart. Each pair is the SAME reset instant reported
    /// with float noise. Hashing the raw `Double` bit pattern made every pair
    /// a distinct cycle, which manufactured a "session reset" on essentially
    /// every poll and simultaneously defeated the history recorder's
    /// same-cycle de-duplication.
    ///
    /// This asserts the quantization directly. The notification-level tests
    /// cannot: the material-usage-drop gate suppresses those false resets on
    /// its own, so they pass with or without quantization and therefore prove
    /// nothing about it.
    func testCycleIDAbsorbsRealObservedResetTimestampJitter() throws {
        let observedPairs: [(String, Double, Double)] = [
            ("claude session 138AC9E2", 807_826_200.293_999_910, 807_826_200.236_000_061),
            ("claude session 21B5073B", 807_823_200.532_000_065, 807_823_200.503_000_021),
            ("claude session C2F26850", 807_816_000.743_999_958, 807_816_000.786_000_013)
        ]

        for (label, first, second) in observedPairs {
            let a = try Self.cycleIDForWindow(resetsAt: first)
            let b = try Self.cycleIDForWindow(resetsAt: second)
            XCTAssertEqual(
                a,
                b,
                "\(label): \(abs(first - second) * 1000)ms of jitter changed the cycle identity"
            )
        }
    }

    /// The flip side: quantization must not blur genuinely different cycles
    /// together, or a real reset would go unnoticed.
    func testCycleIDStillDistinguishesGenuinelyDifferentCycles() throws {
        let base = 807_826_200.0
        let sameBucket = try Self.cycleIDForWindow(resetsAt: base)
        let nextBucket = try Self.cycleIDForWindow(resetsAt: base + 120)
        XCTAssertNotEqual(
            sameBucket,
            nextBucket,
            "Reset boundaries two minutes apart must be distinct cycles"
        )
    }

    private static func cycleIDForWindow(
        resetsAt: Double
    ) throws -> String {
        let window = try UsageWindow(
            id: UsageWindowID("session"),
            displayName: "Session",
            usedPercentage: 42,
            resetsAt: Date(timeIntervalSinceReferenceDate: resetsAt)
        )
        return NormalizedUsageSnapshot.cycleID(for: window)
    }
    func testLegacyHistoryDecodesWithoutNormalizedFieldAndRoundTrips() throws {
        let date = Date(timeIntervalSinceReferenceDate: 1_000)
        let legacy = UsageHistoryData(
            snapshots: [
                UsageSnapshot(
                    timestamp: date,
                    resetType: .sessionReset,
                    sessionTokensUsed: 10,
                    sessionPercentage: 25,
                    triggeringResetTime: date
                )
            ]
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(legacy)
            ) as? [String: Any]
        )
        object.removeValue(forKey: "normalizedSnapshots")
        let fixture = try JSONSerialization.data(
            withJSONObject: object
        )

        let decoded = try JSONDecoder().decode(
            UsageHistoryData.self,
            from: fixture
        )
        XCTAssertEqual(decoded, legacy)
        XCTAssertTrue(decoded.normalizedSnapshots.isEmpty)
        XCTAssertEqual(
            try JSONDecoder().decode(
                UsageHistoryData.self,
                from: JSONEncoder().encode(decoded)
            ),
            legacy
        )
    }

    func testCodexHistoryPreservesArbitraryGroupsWindowsAndNewCycles()
        throws
    {
        let environment = try makeEnvironment()
        let profileID = UUID()
        let firstDate = Date(timeIntervalSinceReferenceDate: 2_000)
        let service = retain(UsageHistoryService(
            defaults: environment.defaults,
            fileStore: ProfileUsageFileStore(
                baseURL: environment.rootURL
            ),
            now: { firstDate }
        ))
        let first = try report(
            providerID: .codex,
            fetchedAt: firstDate,
            windows: [
                ("future.group", "primary", 41, 3_000),
                ("future.group", "secondary", 72, 4_000),
                ("another.group", "rolling", 13, 5_000)
            ]
        )
        service.recordNormalizedReport(
            first,
            for: profileID,
            providerID: .codex,
            recordedAt: firstDate
        )

        // Same cycles inside the sampling interval are not duplicated.
        let nearby = try report(
            providerID: .codex,
            fetchedAt: firstDate.addingTimeInterval(30),
            windows: [
                ("future.group", "primary", 42, 3_000),
                ("future.group", "secondary", 73, 4_000),
                ("another.group", "rolling", 14, 5_000)
            ]
        )
        service.recordNormalizedReport(
            nearby,
            for: profileID,
            providerID: .codex,
            recordedAt: firstDate.addingTimeInterval(30)
        )

        // A cycle change records immediately even inside that interval.
        let reset = try report(
            providerID: .codex,
            fetchedAt: firstDate.addingTimeInterval(60),
            windows: [
                ("future.group", "primary", 1, 6_000),
                ("future.group", "secondary", 73, 4_000),
                ("another.group", "rolling", 14, 5_000)
            ]
        )
        service.recordNormalizedReport(
            reset,
            for: profileID,
            providerID: .codex,
            recordedAt: firstDate.addingTimeInterval(60)
        )

        let history = service.loadHistory(
            for: profileID,
            providerID: .codex
        )
        XCTAssertEqual(history.normalizedSnapshots.count, 4)
        XCTAssertEqual(
            Set(history.normalizedSnapshots.map(\.groupID.rawValue)),
            ["future.group", "another.group"]
        )
        XCTAssertEqual(
            Set(history.normalizedSnapshots.map(\.windowID.rawValue)),
            ["primary", "secondary", "rolling"]
        )
        XCTAssertEqual(
            history.normalizedSnapshots.filter {
                $0.windowID.rawValue == "primary"
            }.map(\.cycleID).count,
            2
        )
        XCTAssertTrue(history.snapshots.isEmpty)
    }

    func testNormalizedSnapshotRoundTripPreservesQuantityAndResetMetadata()
        throws
    {
        let profileID = UUID()
        let fetchedAt = Date(
            timeIntervalSinceReferenceDate: 7_000
        )
        let startedAt = fetchedAt.addingTimeInterval(-300)
        let resetsAt = fetchedAt.addingTimeInterval(300)
        let window = try UsageWindow(
            id: UsageWindowID("requests"),
            displayName: "Requests",
            quantity: UsageQuantity(
                used: 12,
                limit: 50,
                unit: .requests
            ),
            startedAt: startedAt,
            resetsAt: resetsAt,
            duration: 600
        )
        let group = try UsageLimitGroup(
            id: UsageLimitGroupID("future-quota"),
            displayName: "Future quota",
            windows: [window]
        )
        let report = try UsageReport(
            providerID: .codex,
            health: ProviderHealth(
                status: .healthy,
                checkedAt: fetchedAt
            ),
            limitGroups: [group],
            sourceUpdatedAt:
                fetchedAt.addingTimeInterval(-1),
            fetchedAt: fetchedAt,
            staleAt: fetchedAt.addingTimeInterval(300)
        )
        let snapshot = NormalizedUsageSnapshot(
            profileID: profileID,
            report: report,
            group: group,
            window: window
        )
        let decoded = try JSONDecoder().decode(
            NormalizedUsageSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )

        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.quantity?.used, 12)
        XCTAssertEqual(decoded.quantity?.limit, 50)
        XCTAssertEqual(decoded.quantity?.unit, .requests)
        XCTAssertEqual(decoded.usedPercentage, 24)
        XCTAssertEqual(decoded.startedAt, startedAt)
        XCTAssertEqual(decoded.resetsAt, resetsAt)
        XCTAssertEqual(decoded.duration, 600)
        XCTAssertEqual(
            decoded.sourceUpdatedAt,
            fetchedAt.addingTimeInterval(-1)
        )
        XCTAssertEqual(decoded.identity.profileID, profileID)
        XCTAssertEqual(decoded.identity.providerID, .codex)
        XCTAssertEqual(
            decoded.identity.groupID.rawValue,
            "future-quota"
        )
        XCTAssertEqual(
            decoded.identity.windowID.rawValue,
            "requests"
        )
    }

    func testNormalizedHistoryRetentionDropsOldestSnapshots()
        throws
    {
        let environment = try makeEnvironment()
        let profileID = UUID()
        let firstDate = Date(
            timeIntervalSinceReferenceDate: 8_000
        )
        let service = retain(UsageHistoryService(
            defaults: environment.defaults,
            fileStore: ProfileUsageFileStore(
                baseURL: environment.rootURL
            ),
            now: { firstDate },
            maxNormalizedSnapshots: 3
        ))

        // Each offset's resetsAt must land in a distinct whole-minute cycle
        // bucket (see NormalizedUsageSnapshot.cycleID quantization) so every
        // one of the 4 observations is recorded as a genuinely new cycle
        // rather than deduplicated as "the same cycle observed again within
        // sessionRecordingInterval" — this test is exercising retention
        // eviction, not cycle-identity dedup.
        for offset in 0..<4 {
            let fetchedAt = firstDate.addingTimeInterval(
                Double(offset)
            )
            service.recordNormalizedReport(
                try report(
                    providerID: .codex,
                    fetchedAt: fetchedAt,
                    windows: [
                        (
                            "group",
                            "window",
                            Double(offset),
                            12_000 + Double(offset) * 90
                        )
                    ]
                ),
                for: profileID,
                providerID: .codex,
                recordedAt: fetchedAt
            )
        }

        let snapshots = service.loadHistory(
            for: profileID,
            providerID: .codex
        ).normalizedSnapshots
        XCTAssertEqual(snapshots.count, 3)
        XCTAssertEqual(
            snapshots.map(\.timestamp).min(),
            firstDate.addingTimeInterval(1)
        )
    }

    func testNormalizedHistoryIsolatedByProfileAndProvider()
        throws
    {
        let environment = try makeEnvironment()
        let firstProfileID = UUID()
        let secondProfileID = UUID()
        let fetchedAt = Date(
            timeIntervalSinceReferenceDate: 8_500
        )
        let service = retain(UsageHistoryService(
            defaults: environment.defaults,
            fileStore: ProfileUsageFileStore(
                baseURL: environment.rootURL
            ),
            now: { fetchedAt }
        ))

        service.recordNormalizedReport(
            try report(
                providerID: .codex,
                fetchedAt: fetchedAt,
                windows: [
                    ("group", "window", 10, 13_000)
                ]
            ),
            for: firstProfileID,
            providerID: .codex,
            recordedAt: fetchedAt
        )
        service.recordNormalizedReport(
            try report(
                providerID: .codex,
                fetchedAt: fetchedAt,
                windows: [
                    ("group", "window", 90, 13_000)
                ]
            ),
            for: secondProfileID,
            providerID: .codex,
            recordedAt: fetchedAt
        )

        let first = service.loadHistory(
            for: firstProfileID,
            providerID: .codex
        )
        let second = service.loadHistory(
            for: secondProfileID,
            providerID: .codex
        )
        XCTAssertEqual(
            first.normalizedSnapshots.map(\.profileID),
            [firstProfileID]
        )
        XCTAssertEqual(
            first.normalizedSnapshots.map(\.usedPercentage),
            [10]
        )
        XCTAssertEqual(
            second.normalizedSnapshots.map(\.profileID),
            [secondProfileID]
        )
        XCTAssertEqual(
            second.normalizedSnapshots.map(\.usedPercentage),
            [90]
        )

        service.recordNormalizedReport(
            try report(
                providerID: .claude,
                fetchedAt: fetchedAt,
                windows: [
                    ("wrong", "provider", 100, 14_000)
                ]
            ),
            for: firstProfileID,
            providerID: .codex,
            recordedAt: fetchedAt
        )
        XCTAssertEqual(
            service.loadHistory(
                for: firstProfileID,
                providerID: .codex
            ).normalizedSnapshots.count,
            1
        )
    }

    func testVersionedMixedExportExcludesSecretsAuthAndCodexHome()
        throws
    {
        let environment = try makeEnvironment()
        let exportedAt = Date(
            timeIntervalSinceReferenceDate: 9_000.123_456
        )
        let service = retain(UsageHistoryService(
            defaults: environment.defaults,
            fileStore: ProfileUsageFileStore(
                baseURL: environment.rootURL
            ),
            now: { exportedAt }
        ))
        let secret = "EXPORT_SECRET_SENTINEL"
        let authJSON = "{\"tokens\":\"\(secret)\"}"
        let codexHome = "/Users/private/.codex-sensitive"
        let canonicalHome = try JSONDecoder().decode(
            CanonicalCodexHome.self,
            from: Data(
                "{\"path\":\"\(codexHome)\"}".utf8
            )
        )
        var claude = Profile(
            name: "Claude profile",
            claudeSessionKey: secret,
            cliCredentialsJSON: authJSON
        )
        claude.apiSessionKey = "API_\(secret)"
        let codex = Profile(
            name: "Codex profile",
            providerConfiguration: .codex(
                CodexProfileConfiguration(
                    linkedHome: canonicalHome
                )
            )
        )
        service.saveHistory(
            UsageHistoryData(
                snapshots: [
                    UsageSnapshot(
                        resetType: .weeklyReset,
                        weeklyPercentage: 30,
                        triggeringResetTime: exportedAt
                    )
                ]
            ),
            for: claude.id,
            providerID: .claude
        )
        service.recordNormalizedReport(
            try report(
                providerID: .codex,
                fetchedAt: exportedAt,
                windows: [
                    ("dynamic", "primary", 50, 10_000.654_321)
                ]
            ),
            for: codex.id,
            providerID: .codex,
            recordedAt: exportedAt
        )

        let json = try XCTUnwrap(
            service.exportContent(
                profiles: [claude, codex],
                exportedAt: exportedAt
            )
        )
        XCTAssertTrue(json.contains("\"schemaVersion\" : 3"))
        XCTAssertTrue(json.contains("\"claude\""))
        XCTAssertTrue(json.contains("\"codex\""))
        XCTAssertTrue(json.contains("\"dynamic\""))
        XCTAssertFalse(json.contains(secret))
        XCTAssertFalse(json.contains("auth.json"))
        XCTAssertFalse(json.contains(authJSON))
        XCTAssertFalse(json.contains(codexHome))
        XCTAssertFalse(json.contains("/Users/"))

        let decoded = try UsageHistoryExportDocument.decodedJSON(
            from: Data(json.utf8)
        )
        XCTAssertEqual(
            decoded,
            service.makeExport(
                profiles: [claude, codex],
                exportedAt: exportedAt
            )
        )
    }

    func testVersionedCSVPreservesLegacyClaudeAndNormalizedFields()
        throws
    {
        let environment = try makeEnvironment()
        let exportedAt = Date(timeIntervalSinceReferenceDate: 9_500)
        let service = retain(UsageHistoryService(
            defaults: environment.defaults,
            fileStore: ProfileUsageFileStore(
                baseURL: environment.rootURL
            ),
            now: { exportedAt }
        ))
        let dangerousNames = [
            "=HYPERLINK(\"bad\", \"Claude\")",
            "+SUM(1, 1)",
            "-10+20",
            "@SUM(1, 1)",
            "\t=1+1",
            "\r=1+1"
        ]
        let claudeProfiles = dangerousNames.map {
            Profile(name: $0)
        }
        let codex = Profile(
            name: "Codex profile",
            providerConfiguration: .codex(
                CodexProfileConfiguration()
            )
        )
        let legacyHistory = UsageHistoryData(
            snapshots: [
                UsageSnapshot(
                    resetType: .weeklyReset,
                    sessionTokensUsed: 123_456_789,
                    weeklyTokensUsed: 987_654_321,
                    opusWeeklyPercentage: 12.3,
                    sonnetWeeklyPercentage: 45.6,
                    fableWeeklyPercentage: 78.9,
                    apiSpendCents: 12_345,
                    apiPrepaidCreditsCents: 67_890,
                    apiCurrency: "=USD",
                    triggeringResetTime: exportedAt
                )
            ]
        )
        for profile in claudeProfiles {
            service.saveHistory(
                legacyHistory,
                for: profile.id
            )
        }
        service.saveHistory(
            UsageHistoryData(
                normalizedSnapshots: [
                    NormalizedUsageSnapshot(
                        timestamp: exportedAt,
                        profileID: codex.id,
                        providerID: .codex,
                        groupID: try UsageLimitGroupID(
                            "@future-group"
                        ),
                        windowID: try UsageWindowID(
                            "+future-window"
                        ),
                        cycleID: "-future-cycle",
                        usedPercentage: 37,
                        quantity: try UsageQuantity(
                            used: 37,
                            limit: 100,
                            unit: UsageUnit("=units")
                        ),
                        startedAt: nil,
                        resetsAt: exportedAt,
                        duration: nil,
                        sourceUpdatedAt: exportedAt,
                        fetchedAt: exportedAt
                    )
                ]
            ),
            for: codex.id,
            providerID: .codex
        )

        let csv = try XCTUnwrap(
            service.exportContent(
                profiles: claudeProfiles + [codex],
                format: .csv,
                exportedAt: exportedAt
            )
        )
        XCTAssertTrue(csv.contains("Schema Version"))
        XCTAssertTrue(csv.contains("Session Tokens"))
        XCTAssertTrue(csv.contains("API Prepaid Credits"))
        for dangerousName in dangerousNames {
            let neutralized = "'" + dangerousName
            let expected: String
            if neutralized.contains(",")
                || neutralized.contains("\"")
                || neutralized.contains("\n")
                || neutralized.contains("\r") {
                expected = "\""
                    + neutralized.replacingOccurrences(
                        of: "\"",
                        with: "\"\""
                    )
                    + "\""
            } else {
                expected = neutralized
            }
            XCTAssertTrue(
                csv.contains(expected),
                "Missing neutralized CSV value for \(dangerousName.debugDescription)"
            )
            XCTAssertFalse(csv.contains(",\(dangerousName)"))
        }
        XCTAssertTrue(csv.contains("123456789"))
        XCTAssertTrue(csv.contains("987654321"))
        XCTAssertTrue(csv.contains("123.45"))
        XCTAssertTrue(csv.contains("678.9"))
        XCTAssertTrue(csv.contains("'@future-group"))
        XCTAssertTrue(csv.contains("'+future-window"))
        XCTAssertTrue(csv.contains("'-future-cycle"))
        XCTAssertTrue(csv.contains("'=units"))
        XCTAssertTrue(csv.contains("'=USD"))
        XCTAssertTrue(csv.contains(",37.0,"))
        let rows = try parseCSV(csv)
        XCTAssertFalse(rows.isEmpty)
        XCTAssertTrue(rows.allSatisfy { $0.count == 22 })
        let fields = Set(rows.dropFirst().flatMap { $0 })
        for dangerousName in dangerousNames {
            XCTAssertTrue(fields.contains("'" + dangerousName))
        }
    }

    func testNotificationCrossingRetryAndNewCycleResetRealert()
        throws
    {
        let profileID = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 20_000)
        let settings = NotificationSettings()
        let initial = try report(
            providerID: .codex,
            fetchedAt: now,
            windows: [("group", "primary", 70, 30_000)]
        )

        let baseline = UsageNotificationPolicy.evaluate(
            report: initial,
            profileID: profileID,
            settings: settings,
            now: now,
            previousStates: [:]
        )
        XCTAssertTrue(baseline.events.isEmpty)

        let low = try report(
            providerID: .codex,
            fetchedAt: now.addingTimeInterval(1),
            windows: [("group", "primary", 70, 30_000)]
        )
        let lowered = UsageNotificationPolicy.evaluate(
            report: low,
            profileID: profileID,
            settings: settings,
            now: now.addingTimeInterval(1),
            previousStates: baseline.states
        )
        let crossingReport = try report(
            providerID: .codex,
            fetchedAt: now.addingTimeInterval(2),
            windows: [("group", "primary", 76, 30_000)]
        )
        let crossing = UsageNotificationPolicy.evaluate(
            report: crossingReport,
            profileID: profileID,
            settings: settings,
            now: now.addingTimeInterval(2),
            previousStates: lowered.states
        )
        XCTAssertEqual(crossing.events.map(\.threshold), [75])
        let duplicate = UsageNotificationPolicy.evaluate(
            report: crossingReport,
            profileID: profileID,
            settings: settings,
            now: now.addingTimeInterval(2),
            previousStates: crossing.states
        )
        // The pure policy keeps undelivered work pending. NotificationManager
        // owns in-flight suppression and marks it delivered on success.
        XCTAssertEqual(duplicate.events.map(\.threshold), [75])

        // The window's cycle identity changes (resetsAt moves from 30_000 to
        // 40_000) but usage went UP (76% -> 96%), not down. A cycle-identity
        // change alone must never be read as a reset — only a material usage
        // drop may. So this must fire the threshold crossing only, with no
        // `.reset` event, even though the cycle changed.
        let newCycle = try report(
            providerID: .codex,
            fetchedAt: now.addingTimeInterval(3),
            windows: [("group", "primary", 96, 40_000)]
        )
        let noReset = UsageNotificationPolicy.evaluate(
            report: newCycle,
            profileID: profileID,
            settings: settings,
            now: now.addingTimeInterval(3),
            previousStates: crossing.states
        )
        XCTAssertEqual(
            noReset.events.map(\.identity.kind),
            [.threshold]
        )
        XCTAssertEqual(noReset.events.last?.threshold, 95)
        XCTAssertEqual(
            Set(noReset.events.map {
                $0.identity.window.profileID
            }),
            [profileID]
        )

        // A subsequent cycle change that DOES coincide with a material usage
        // drop (96% -> 2%) is a genuine reset and must fire one.
        let genuineReset = try report(
            providerID: .codex,
            fetchedAt: now.addingTimeInterval(4),
            windows: [("group", "primary", 2, 50_000)]
        )
        let reset = UsageNotificationPolicy.evaluate(
            report: genuineReset,
            profileID: profileID,
            settings: settings,
            now: now.addingTimeInterval(4),
            previousStates: noReset.states
        )
        XCTAssertEqual(
            reset.events.map(\.identity.kind),
            [.reset]
        )
        XCTAssertEqual(
            Set(reset.events.map {
                $0.identity.window.profileID
            }),
            [profileID]
        )
    }

    /// Regression for a real bug: sub-second/second-level jitter in a
    /// provider's `resetsAt` between polls produced a brand-new cycle
    /// identity on every poll (the identity hashed the raw IEEE-754 bit
    /// pattern of the timestamp), which downstream reset detection read as a
    /// session reset — the reported symptom was ~14 false "your session has
    /// reset" notifications per minute. These are the exact jittered
    /// timestamp pairs captured from the failing session; the percentage is
    /// unchanged in every pair, so nothing should ever fire.
    func testResetsAtJitterAloneWithUnchangedUsageNeverResets() throws {
        let profileID = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 60_000)
        let jitteredResetsAtPairs: [(TimeInterval, TimeInterval)] = [
            (807_826_200.293_999_910, 807_826_200.236_000_061), // 58ms
            (807_823_200.532_000_065, 807_823_200.503_000_021), // 29ms
            (807_816_000.743_999_958, 807_816_000.786_000_013), // 42ms
            (807_855_145.000_000_000, 807_855_144.000_000_000)  // 1s
        ]
        for (firstResetsAt, secondResetsAt) in jitteredResetsAtPairs {
            let percentage = 42.0
            let initial = try report(
                providerID: .codex,
                fetchedAt: now,
                windows: [("group", "session", percentage, firstResetsAt)]
            )
            let baseline = UsageNotificationPolicy.evaluate(
                report: initial,
                profileID: profileID,
                settings: NotificationSettings(),
                now: now,
                previousStates: [:]
            )
            XCTAssertTrue(baseline.events.isEmpty)

            let jittered = try report(
                providerID: .codex,
                fetchedAt: now.addingTimeInterval(50),
                windows: [("group", "session", percentage, secondResetsAt)]
            )
            let result = UsageNotificationPolicy.evaluate(
                report: jittered,
                profileID: profileID,
                settings: NotificationSettings(),
                now: now.addingTimeInterval(50),
                previousStates: baseline.states
            )
            XCTAssertTrue(
                result.events.isEmpty,
                "resetsAt jitter of \(secondResetsAt - firstResetsAt)s "
                    + "with unchanged usage must never fire an event"
            )
        }
    }

    /// Regression: rolling windows advance `resetsAt` continuously by design
    /// (observed advancing 60s on every single poll for a real rolling
    /// window). No identity derived from `resetsAt` alone can ever be stable
    /// for them, so the material-usage-drop gate — not identity stability —
    /// is what must protect rolling windows: even though the cycle identity
    /// changes on every poll, an unchanged percentage must never read as a
    /// reset, across many consecutive polls.
    func testRollingWindowAdvancingResetsAtNeverResetsWithoutUsageDrop()
        throws
    {
        let profileID = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 61_000)
        var states:
            [UsageNotificationWindowKey: UsageNotificationWindowState] = [:]
        var resetsAtReference: TimeInterval = 808_416_258
        let percentage = 30.0
        for poll in 0..<20 {
            let pollTime = now.addingTimeInterval(TimeInterval(poll) * 30)
            let current = try report(
                providerID: .codex,
                fetchedAt: pollTime,
                windows: [
                    ("group", "primary", percentage, resetsAtReference)
                ]
            )
            let result = UsageNotificationPolicy.evaluate(
                report: current,
                profileID: profileID,
                settings: NotificationSettings(),
                now: pollTime,
                previousStates: states
            )
            XCTAssertTrue(
                result.events.isEmpty,
                "Poll \(poll) must not fire any event for an unchanged "
                    + "rolling-window percentage"
            )
            states = result.states
            resetsAtReference += 60
        }
    }

    /// Regression: a window sitting steadily AT the near-zero reset
    /// threshold (exactly `resetNearZeroPercentageThreshold`) must never be
    /// reported as a reset just because its cycle identity changes. The
    /// near-zero branch of the material-usage-drop gate previously fired
    /// whenever `percentage <= threshold`, regardless of what the previous
    /// percentage was — so a window parked at 5% forever (a real,
    /// observed shape: two live windows on the user's machine sit at
    /// exactly 5%) would satisfy `5 <= 5` on every cycle-identity change
    /// and flood "session reset" notifications with no usage having
    /// dropped at all. Usage must actually fall INTO near-zero FROM above
    /// the threshold for a reset to be reported.
    func testSteadyNearZeroUsageAcrossManyCycleChangesNeverResets() throws {
        let profileID = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 63_000)
        var states:
            [UsageNotificationWindowKey: UsageNotificationWindowState] = [:]
        var resetsAtReference: TimeInterval = 900_000_000
        let percentage = 5.0
        for poll in 0..<20 {
            let pollTime = now.addingTimeInterval(TimeInterval(poll) * 60)
            let current = try report(
                providerID: .codex,
                fetchedAt: pollTime,
                windows: [
                    ("group", "primary", percentage, resetsAtReference)
                ]
            )
            let result = UsageNotificationPolicy.evaluate(
                report: current,
                profileID: profileID,
                settings: NotificationSettings(),
                now: pollTime,
                previousStates: states
            )
            XCTAssertTrue(
                result.events.isEmpty,
                "Poll \(poll) must not fire any event for usage steady at "
                    + "the near-zero threshold"
            )
            states = result.states
            // Force a new cycle identity every poll, the same way a
            // rolling window's resetsAt advances continuously by design.
            resetsAtReference += 60
        }
    }

    /// A genuine reset (usage dropping to near zero) must still fire exactly
    /// one notification through the full `NotificationManager` path, and
    /// must not re-fire on a repeat observation of the same post-reset
    /// report.
    func testGenuineResetFiresExactlyOneNotification() throws {
        let environment = try makeEnvironment()
        var requests: [UNNotificationRequest] = []
        let manager = retain(NotificationManager(
            defaults: environment.defaults,
            notificationRequestAdder: { request, completion in
                requests.append(request)
                completion(nil)
            }
        ))
        let profileID = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 62_000)
        let settings = NotificationSettings(
            threshold75Enabled: false,
            threshold90Enabled: false,
            threshold95Enabled: false
        )
        let before = try report(
            providerID: .codex,
            fetchedAt: now,
            windows: [("group", "session", 85, 82_000)]
        )
        manager.checkAndNotify(
            report: before,
            profileID: profileID,
            profileName: "Codex",
            settings: settings,
            now: now
        )
        XCTAssertTrue(requests.isEmpty)

        let after = try report(
            providerID: .codex,
            fetchedAt: now.addingTimeInterval(1),
            windows: [("group", "session", 0, 92_000)]
        )
        manager.checkAndNotify(
            report: after,
            profileID: profileID,
            profileName: "Codex",
            settings: settings,
            now: now.addingTimeInterval(1)
        )
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].content.body, "Usage window reset.")

        // Re-observing the same post-reset report must not duplicate it.
        manager.checkAndNotify(
            report: after,
            profileID: profileID,
            profileName: "Codex",
            settings: settings,
            now: now.addingTimeInterval(2)
        )
        XCTAssertEqual(requests.count, 1)
    }

    /// A genuine reset that happened entirely while the app was closed must
    /// still be detected on the very first observation after relaunch, by
    /// seeding a baseline from the last-known `previousReport` rather than
    /// requiring an in-ledger prior observation.
    func testGenuineResetFiresAcrossAppRestartUsingPreviousReport() throws {
        let environment = try makeEnvironment()
        var requests: [UNNotificationRequest] = []
        let manager = retain(NotificationManager(
            defaults: environment.defaults,
            notificationRequestAdder: { request, completion in
                requests.append(request)
                completion(nil)
            }
        ))
        let profileID = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 63_000)
        let settings = NotificationSettings(
            threshold75Enabled: false,
            threshold90Enabled: false,
            threshold95Enabled: false
        )
        let beforeClose = try report(
            providerID: .codex,
            fetchedAt: now,
            windows: [("group", "session", 85, 83_000)]
        )
        let afterRelaunch = try report(
            providerID: .codex,
            fetchedAt: now.addingTimeInterval(600),
            windows: [("group", "session", 0, 93_000)]
        )
        manager.checkAndNotify(
            report: afterRelaunch,
            previousReport: beforeClose,
            profileID: profileID,
            profileName: "Codex",
            settings: settings,
            now: now.addingTimeInterval(600)
        )
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].content.body, "Usage window reset.")
    }

    /// The `previousReport` baseline path must obey the same material-drop
    /// gate as the normal path: a cycle change across the app-restart
    /// boundary with usage that went up, not down, must not be read as a
    /// reset.
    func testPreviousReportPathDoesNotResetWithoutUsageDrop() throws {
        let environment = try makeEnvironment()
        var requests: [UNNotificationRequest] = []
        let manager = retain(NotificationManager(
            defaults: environment.defaults,
            notificationRequestAdder: { request, completion in
                requests.append(request)
                completion(nil)
            }
        ))
        let profileID = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 64_000)
        let settings = NotificationSettings(
            threshold75Enabled: false,
            threshold90Enabled: false,
            threshold95Enabled: false
        )
        let beforeClose = try report(
            providerID: .codex,
            fetchedAt: now,
            windows: [("group", "session", 85, 84_000)]
        )
        let afterRelaunch = try report(
            providerID: .codex,
            fetchedAt: now.addingTimeInterval(600),
            windows: [("group", "session", 90, 94_000)]
        )
        manager.checkAndNotify(
            report: afterRelaunch,
            previousReport: beforeClose,
            profileID: profileID,
            profileName: "Codex",
            settings: settings,
            now: now.addingTimeInterval(600)
        )
        XCTAssertTrue(requests.isEmpty)
    }

    /// Regression: disabling notifications in the app left the user still
    /// receiving them, because the live normalized path only ever consulted
    /// the per-profile `NotificationSettings.enabled` flag and never the
    /// global master switch. With the master switch off, no profile —
    /// enabled or not — may deliver a notification.
    func testGlobalMasterSwitchOffSuppressesAllProfilesRegardlessOfPerProfileSetting()
        throws
    {
        let environment = try makeEnvironment()
        environment.defaults.set(false, forKey: "notificationsMasterSwitchEnabled")
        var requests: [UNNotificationRequest] = []
        let manager = retain(NotificationManager(
            defaults: environment.defaults,
            notificationRequestAdder: { request, completion in
                requests.append(request)
                completion(nil)
            }
        ))
        let now = Date(timeIntervalSinceReferenceDate: 65_000)
        for profileID in [UUID(), UUID()] {
            manager.checkAndNotify(
                report: try report(
                    providerID: .codex,
                    fetchedAt: now,
                    windows: [("group", "primary", 96, 85_000)]
                ),
                profileID: profileID,
                profileName: "Codex",
                settings: NotificationSettings(enabled: true),
                now: now
            )
        }
        XCTAssertTrue(requests.isEmpty)
    }

    /// With the master switch on, per-profile toggles keep working exactly
    /// as before: only the profile that disabled notifications stays silent.
    func testGlobalMasterSwitchOnLeavesPerProfileToggleInControl() throws {
        let environment = try makeEnvironment()
        environment.defaults.set(true, forKey: "notificationsMasterSwitchEnabled")
        var requests: [UNNotificationRequest] = []
        let manager = retain(NotificationManager(
            defaults: environment.defaults,
            notificationRequestAdder: { request, completion in
                requests.append(request)
                completion(nil)
            }
        ))
        let now = Date(timeIntervalSinceReferenceDate: 66_000)
        let enabledProfile = UUID()
        let disabledProfile = UUID()
        manager.checkAndNotify(
            report: try report(
                providerID: .codex,
                fetchedAt: now,
                windows: [("group", "primary", 96, 86_000)]
            ),
            profileID: disabledProfile,
            profileName: "Codex disabled",
            settings: NotificationSettings(enabled: false),
            now: now
        )
        XCTAssertTrue(requests.isEmpty)

        manager.checkAndNotify(
            report: try report(
                providerID: .codex,
                fetchedAt: now,
                windows: [("group", "primary", 96, 87_000)]
            ),
            profileID: enabledProfile,
            profileName: "Codex enabled",
            settings: NotificationSettings(enabled: true),
            now: now
        )
        XCTAssertEqual(requests.count, 1)
    }

    /// The master-switch key never existed before this feature, so on
    /// upgrade it is absent for every current user. Absence must be treated
    /// as enabled, or notifications silently break for the entire install
    /// base — not just for users who explicitly opted out.
    func testMissingMasterSwitchKeyIsTreatedAsEnabled() throws {
        let environment = try makeEnvironment()
        XCTAssertNil(
            environment.defaults.object(forKey: "notificationsMasterSwitchEnabled")
        )
        var requests: [UNNotificationRequest] = []
        let manager = retain(NotificationManager(
            defaults: environment.defaults,
            notificationRequestAdder: { request, completion in
                requests.append(request)
                completion(nil)
            }
        ))
        let now = Date(timeIntervalSinceReferenceDate: 67_000)
        manager.checkAndNotify(
            report: try report(
                providerID: .codex,
                fetchedAt: now,
                windows: [("group", "primary", 96, 88_000)]
            ),
            profileID: UUID(),
            profileName: "Codex",
            settings: NotificationSettings(enabled: true),
            now: now
        )
        XCTAssertEqual(requests.count, 1)
    }

    func testFirstHighObservationMatchesClaudePolicyForEveryProvider()
        throws
    {
        let now = Date(timeIntervalSinceReferenceDate: 40_000)
        for providerID in [ProviderID.claude, .codex] {
            let groupID =
                providerID == .claude ? "subscription" : "group"
            let windowID =
                providerID == .claude ? "session" : "primary"
            let high = try report(
                providerID: providerID,
                fetchedAt: now,
                windows: [(groupID, windowID, 96, 50_000)]
            )
            let result = UsageNotificationPolicy.evaluate(
                report: high,
                profileID: UUID(),
                settings: NotificationSettings(),
                now: now,
                previousStates: [:]
            )

            XCTAssertEqual(
                result.events.map(\.threshold),
                [95],
                "First-high parity failed for \(providerID.rawValue)"
            )
        }
    }

    func testClaudeNotificationsIgnoreWeeklyModelAndOverageWindows()
        throws
    {
        let profileID = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 45_000)
        let initial = try report(
            providerID: .claude,
            fetchedAt: now,
            windows: [
                ("subscription", "session", 10, 55_000),
                ("subscription", "weekly", 96, 65_000),
                ("opus", "weekly", 96, 65_000),
                ("extra-usage", "current", 96, 75_000)
            ]
        )
        let first = UsageNotificationPolicy.evaluate(
            report: initial,
            profileID: profileID,
            settings: NotificationSettings(),
            now: now,
            previousStates: [:]
        )
        XCTAssertTrue(first.events.isEmpty)
        XCTAssertEqual(
            Set(first.states.keys.map(\.windowID.rawValue)),
            ["session"]
        )

        let highSession = try report(
            providerID: .claude,
            fetchedAt: now.addingTimeInterval(1),
            windows: [
                ("subscription", "session", 96, 55_000),
                ("subscription", "weekly", 96, 65_000),
                ("opus", "weekly", 96, 65_000),
                ("extra-usage", "current", 96, 75_000)
            ]
        )
        let second = UsageNotificationPolicy.evaluate(
            report: highSession,
            profileID: profileID,
            settings: NotificationSettings(),
            now: now.addingTimeInterval(1),
            previousStates: first.states
        )
        XCTAssertEqual(second.events.count, 1)
        XCTAssertEqual(
            second.events.first?.identity.window.groupID.rawValue,
            "subscription"
        )
        XCTAssertEqual(
            second.events.first?.identity.window.windowID.rawValue,
            "session"
        )
        XCTAssertEqual(second.events.first?.threshold, 95)
    }

    func testFailedDeliveryRetriesWithoutLosingSuccessfulIdentity()
        throws
    {
        let environment = try makeEnvironment()
        var requests: [UNNotificationRequest] = []
        var completions: [(Error?) -> Void] = []
        let manager = retain(NotificationManager(
            defaults: environment.defaults,
            notificationRequestAdder: { request, completion in
                requests.append(request)
                completions.append(completion)
            }
        ))
        let profileID = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 47_000)
        let high = try report(
            providerID: .codex,
            fetchedAt: now,
            windows: [
                ("group", "primary", 96, 57_000),
                ("group", "secondary", 96, 67_000)
            ]
        )

        manager.checkAndNotify(
            report: high,
            profileID: profileID,
            profileName: "Codex",
            settings: NotificationSettings(),
            now: now
        )
        XCTAssertEqual(requests.count, 2)
        let failedIdentifier = requests[0].identifier
        let successfulIdentifier = requests[1].identifier
        completions[0](TestError.expected)
        completions[1](nil)

        manager.checkAndNotify(
            report: high,
            profileID: profileID,
            profileName: "Codex",
            settings: NotificationSettings(),
            now: now.addingTimeInterval(1)
        )
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests.last?.identifier, failedIdentifier)
        XCTAssertNotEqual(requests.last?.identifier, successfulIdentifier)
    }

    func testStaleCycleCannotMutateDeliveredThresholdState()
        throws
    {
        let environment = try makeEnvironment()
        var requests: [UNNotificationRequest] = []
        var completions: [(Error?) -> Void] = []
        let manager = retain(NotificationManager(
            defaults: environment.defaults,
            notificationRequestAdder: { request, completion in
                requests.append(request)
                completions.append(completion)
            }
        ))
        let profileID = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 48_000)
        let cycleA = try report(
            providerID: .codex,
            fetchedAt: now,
            windows: [("group", "primary", 96, 58_000)]
        )

        manager.checkAndNotify(
            report: cycleA,
            profileID: profileID,
            profileName: "Codex",
            settings: NotificationSettings(),
            now: now
        )
        XCTAssertEqual(requests.count, 1)
        completions.removeFirst()(nil)

        let staleCycleB = try report(
            providerID: .codex,
            fetchedAt: now.addingTimeInterval(1),
            staleAt: now.addingTimeInterval(1.5),
            windows: [("group", "primary", 96, 68_000)]
        )
        manager.checkAndNotify(
            report: staleCycleB,
            profileID: profileID,
            profileName: "Codex",
            settings: NotificationSettings(),
            now: now.addingTimeInterval(2)
        )
        manager.checkAndNotify(
            report: cycleA,
            profileID: profileID,
            profileName: "Codex",
            settings: NotificationSettings(),
            now: now.addingTimeInterval(3)
        )

        XCTAssertEqual(requests.count, 1)
    }

    func testFailedResetRetriesAcrossManagerRecreation()
        throws
    {
        let environment = try makeEnvironment()
        var requests: [UNNotificationRequest] = []
        var completions: [(Error?) -> Void] = []
        let capture:
            NotificationManager.NotificationRequestAdder = {
                request,
                completion in
                requests.append(request)
                completions.append(completion)
            }
        let settings = NotificationSettings(
            threshold75Enabled: false,
            threshold90Enabled: false,
            threshold95Enabled: false
        )
        let profileID = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 49_000)
        let cycleA = try report(
            providerID: .codex,
            fetchedAt: now,
            windows: [("group", "primary", 70, 59_000)]
        )
        let cycleB = try report(
            providerID: .codex,
            fetchedAt: now.addingTimeInterval(1),
            windows: [("group", "primary", 0, 69_000)]
        )
        let first = retain(NotificationManager(
            defaults: environment.defaults,
            notificationRequestAdder: capture
        ))
        first.checkAndNotify(
            report: cycleA,
            profileID: profileID,
            profileName: "Codex",
            settings: settings,
            now: now
        )
        first.checkAndNotify(
            report: cycleB,
            profileID: profileID,
            profileName: "Codex",
            settings: settings,
            now: now.addingTimeInterval(1)
        )
        XCTAssertEqual(requests.count, 1)
        let resetIdentifier = requests[0].identifier
        completions.removeFirst()(TestError.expected)

        let second = retain(NotificationManager(
            defaults: environment.defaults,
            notificationRequestAdder: capture
        ))
        second.checkAndNotify(
            report: cycleB,
            profileID: profileID,
            profileName: "Codex",
            settings: settings,
            now: now.addingTimeInterval(2)
        )
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].identifier, resetIdentifier)
        completions.removeFirst()(nil)

        let third = retain(NotificationManager(
            defaults: environment.defaults,
            notificationRequestAdder: capture
        ))
        third.checkAndNotify(
            report: cycleB,
            profileID: profileID,
            profileName: "Codex",
            settings: settings,
            now: now.addingTimeInterval(3)
        )
        XCTAssertEqual(requests.count, 2)
    }

    func testInFlightResetIsSubmittedOnlyOnce() throws {
        let environment = try makeEnvironment()
        var requests: [UNNotificationRequest] = []
        var completions: [(Error?) -> Void] = []
        let manager = retain(NotificationManager(
            defaults: environment.defaults,
            notificationRequestAdder: { request, completion in
                requests.append(request)
                completions.append(completion)
            }
        ))
        let settings = NotificationSettings(
            threshold75Enabled: false,
            threshold90Enabled: false,
            threshold95Enabled: false
        )
        let profileID = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 49_500)
        let firstCycle = try report(
            providerID: .codex,
            fetchedAt: now,
            windows: [("group", "primary", 70, 59_500)]
        )
        let nextCycle = try report(
            providerID: .codex,
            fetchedAt: now.addingTimeInterval(1),
            windows: [("group", "primary", 0, 69_500)]
        )
        manager.checkAndNotify(
            report: firstCycle,
            profileID: profileID,
            profileName: "Codex",
            settings: settings,
            now: now
        )
        manager.checkAndNotify(
            report: nextCycle,
            profileID: profileID,
            profileName: "Codex",
            settings: settings,
            now: now.addingTimeInterval(1)
        )
        manager.checkAndNotify(
            report: nextCycle,
            profileID: profileID,
            profileName: "Codex",
            settings: settings,
            now: now.addingTimeInterval(2)
        )
        XCTAssertEqual(requests.count, 1)
        completions.removeFirst()(TestError.expected)
        manager.checkAndNotify(
            report: nextCycle,
            profileID: profileID,
            profileName: "Codex",
            settings: settings,
            now: now.addingTimeInterval(3)
        )
        XCTAssertEqual(requests.count, 2)
    }

    func testInFlightThresholdIsSubmittedOnlyOnceAndRetriesAfterFailure()
        throws
    {
        let environment = try makeEnvironment()
        var requests: [UNNotificationRequest] = []
        var completions: [(Error?) -> Void] = []
        let manager = retain(NotificationManager(
            defaults: environment.defaults,
            notificationRequestAdder: { request, completion in
                requests.append(request)
                completions.append(completion)
            }
        ))
        let profileID = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 49_700)
        let high = try report(
            providerID: .codex,
            fetchedAt: now,
            windows: [("group", "primary", 96, 59_700)]
        )

        manager.checkAndNotify(
            report: high,
            profileID: profileID,
            profileName: "Codex",
            settings: NotificationSettings(),
            now: now
        )
        manager.checkAndNotify(
            report: high,
            profileID: profileID,
            profileName: "Codex",
            settings: NotificationSettings(),
            now: now.addingTimeInterval(1)
        )
        XCTAssertEqual(requests.count, 1)

        completions.removeFirst()(TestError.expected)
        manager.checkAndNotify(
            report: high,
            profileID: profileID,
            profileName: "Codex",
            settings: NotificationSettings(),
            now: now.addingTimeInterval(2)
        )
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].identifier, requests[1].identifier)
    }

    func testMissingWindowCannotEvictAnInFlightReservation()
        throws
    {
        let environment = try makeEnvironment()
        var requests: [UNNotificationRequest] = []
        var completions: [(Error?) -> Void] = []
        let manager = retain(NotificationManager(
            defaults: environment.defaults,
            missingWindowRetention: 0,
            maximumMissingWindowsPerScope: 0,
            notificationRequestAdder: { request, completion in
                requests.append(request)
                completions.append(completion)
            }
        ))
        let profileID = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 49_750)
        let high = try report(
            providerID: .codex,
            fetchedAt: now,
            windows: [("group", "primary", 96, 59_750)]
        )
        manager.checkAndNotify(
            report: high,
            profileID: profileID,
            profileName: "Codex",
            settings: NotificationSettings(),
            now: now
        )
        manager.checkAndNotify(
            report: try report(
                providerID: .codex,
                fetchedAt: now.addingTimeInterval(1),
                windows: [("group", "other", 10, 59_750)]
            ),
            profileID: profileID,
            profileName: "Codex",
            settings: NotificationSettings(),
            now: now.addingTimeInterval(1)
        )
        XCTAssertEqual(
            manager.normalizedNotificationStateCount(
                profileID: profileID,
                providerID: .codex
            ),
            2
        )
        manager.checkAndNotify(
            report: high,
            profileID: profileID,
            profileName: "Codex",
            settings: NotificationSettings(),
            now: now.addingTimeInterval(2)
        )
        XCTAssertEqual(requests.count, 1)

        completions.removeFirst()(TestError.expected)
        manager.checkAndNotify(
            report: high,
            profileID: profileID,
            profileName: "Codex",
            settings: NotificationSettings(),
            now: now.addingTimeInterval(3)
        )
        XCTAssertEqual(requests.count, 2)
    }

    func testOldCallbackCannotReleaseANewerReservationAfterProfileClear()
        throws
    {
        let environment = try makeEnvironment()
        var requests: [UNNotificationRequest] = []
        var completions: [(Error?) -> Void] = []
        let manager = retain(NotificationManager(
            defaults: environment.defaults,
            notificationRequestAdder: { request, completion in
                requests.append(request)
                completions.append(completion)
            }
        ))
        let profileID = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 49_775)
        let high = try report(
            providerID: .codex,
            fetchedAt: now,
            windows: [("group", "primary", 96, 59_775)]
        )
        manager.checkAndNotify(
            report: high,
            profileID: profileID,
            profileName: "Codex",
            settings: NotificationSettings(),
            now: now
        )
        try manager.clearNotificationsForProfile(
            profileID,
            providerID: .codex
        )
        manager.checkAndNotify(
            report: high,
            profileID: profileID,
            profileName: "Codex",
            settings: NotificationSettings(),
            now: now.addingTimeInterval(1)
        )
        XCTAssertEqual(requests.count, 2)

        completions[0](nil)
        manager.checkAndNotify(
            report: high,
            profileID: profileID,
            profileName: "Codex",
            settings: NotificationSettings(),
            now: now.addingTimeInterval(2)
        )
        XCTAssertEqual(requests.count, 2)

        completions[1](nil)
        manager.checkAndNotify(
            report: high,
            profileID: profileID,
            profileName: "Codex",
            settings: NotificationSettings(),
            now: now.addingTimeInterval(3)
        )
        XCTAssertEqual(requests.count, 2)
    }

    func testHigherDeliveredThresholdSuppressesLowerBackfill()
        throws
    {
        let environment = try makeEnvironment()
        var requests: [UNNotificationRequest] = []
        var completions: [(Error?) -> Void] = []
        let manager = retain(NotificationManager(
            defaults: environment.defaults,
            notificationRequestAdder: { request, completion in
                requests.append(request)
                completions.append(completion)
            }
        ))
        let profileID = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 49_800)
        for (offset, percentage) in [96.0, 92.0, 80.0]
            .enumerated() {
            let current = try report(
                providerID: .codex,
                fetchedAt:
                    now.addingTimeInterval(
                        TimeInterval(offset)
                    ),
                windows: [
                    ("group", "primary", percentage, 59_800)
                ]
            )
            manager.checkAndNotify(
                report: current,
                profileID: profileID,
                profileName: "Codex",
                settings: NotificationSettings(),
                now:
                    now.addingTimeInterval(
                        TimeInterval(offset)
                    )
            )
            if !completions.isEmpty {
                completions.removeFirst()(nil)
            }
        }

        XCTAssertEqual(requests.count, 1)
    }

    func testDisabledPendingThresholdIsNotRetriedAfterRestart()
        throws
    {
        let environment = try makeEnvironment()
        var requests: [UNNotificationRequest] = []
        var completions: [(Error?) -> Void] = []
        let capture:
            NotificationManager.NotificationRequestAdder = {
                request,
                completion in
                requests.append(request)
                completions.append(completion)
            }
        let profileID = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 49_850)
        let high = try report(
            providerID: .codex,
            fetchedAt: now,
            windows: [("group", "primary", 96, 59_850)]
        )
        let first = retain(NotificationManager(
            defaults: environment.defaults,
            notificationRequestAdder: capture
        ))
        first.checkAndNotify(
            report: high,
            profileID: profileID,
            profileName: "Codex",
            settings: NotificationSettings(),
            now: now
        )
        XCTAssertTrue(requests[0].identifier.hasSuffix("2:95"))
        completions.removeFirst()(TestError.expected)

        let second = retain(NotificationManager(
            defaults: environment.defaults,
            notificationRequestAdder: capture
        ))
        second.checkAndNotify(
            report: high,
            profileID: profileID,
            profileName: "Codex",
            settings: NotificationSettings(
                threshold75Enabled: true,
                threshold90Enabled: true,
                threshold95Enabled: false
            ),
            now: now.addingTimeInterval(1)
        )
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests[1].identifier.hasSuffix("2:90"))
        XCTAssertNotEqual(
            requests[0].identifier,
            requests[1].identifier
        )
    }

    func testMissingWindowRetentionIsBoundedAndExpires()
        throws
    {
        let environment = try makeEnvironment()
        let manager = retain(NotificationManager(
            defaults: environment.defaults,
            missingWindowRetention: 5,
            maximumMissingWindowsPerScope: 2,
            notificationRequestAdder: { _, completion in
                completion(nil)
            }
        ))
        let profileID = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 49_900)
        let observations: [[(
            group: String,
            window: String,
            percentage: Double,
            resetReferenceDate: TimeInterval
        )]] = [
            [
                ("group", "a", 10, 59_900),
                ("group", "b", 10, 59_900),
                ("group", "c", 10, 59_900)
            ],
            [
                ("group", "a", 10, 59_900),
                ("group", "b", 10, 59_900)
            ],
            [("group", "a", 10, 59_900)],
            [("group", "d", 10, 59_900)]
        ]
        for (offset, windows) in observations.enumerated() {
            let time = now.addingTimeInterval(
                TimeInterval(offset)
            )
            manager.checkAndNotify(
                report: try report(
                    providerID: .codex,
                    fetchedAt: time,
                    windows: windows
                ),
                profileID: profileID,
                profileName: "Codex",
                settings: NotificationSettings(),
                now: time
            )
        }
        XCTAssertEqual(
            manager.normalizedNotificationStateCount(
                profileID: profileID,
                providerID: .codex
            ),
            3
        )

        let afterGrace = now.addingTimeInterval(10)
        manager.checkAndNotify(
            report: try report(
                providerID: .codex,
                fetchedAt: afterGrace,
                windows: [("group", "d", 10, 59_900)]
            ),
            profileID: profileID,
            profileName: "Codex",
            settings: NotificationSettings(),
            now: afterGrace
        )
        XCTAssertEqual(
            manager.normalizedNotificationStateCount(
                profileID: profileID,
                providerID: .codex
            ),
            1
        )
    }

    func testProfileClearPersistsAndDoesNotDeleteOtherProfileState()
        throws
    {
        let environment = try makeEnvironment()
        let profileID = UUID()
        let otherProfileID = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 49_950)
        let settings = NotificationSettings(
            threshold75Enabled: false,
            threshold90Enabled: false,
            threshold95Enabled: false
        )
        let manager = retain(NotificationManager(
            defaults: environment.defaults,
            notificationRequestAdder: { _, completion in
                completion(nil)
            }
        ))
        manager.checkAndNotify(
            report: try report(
                providerID: .codex,
                fetchedAt: now,
                windows: [("group", "primary", 10, 59_950)]
            ),
            profileID: profileID,
            profileName: "Codex",
            settings: settings,
            now: now
        )
        manager.checkAndNotify(
            report: try report(
                providerID: .claude,
                fetchedAt: now,
                windows: [
                    ("subscription", "session", 10, 59_950)
                ]
            ),
            profileID: otherProfileID,
            profileName: "Claude",
            settings: settings,
            now: now
        )

        try manager.clearNotificationsForProfile(
            profileID,
            providerID: .codex
        )
        let reloaded = retain(NotificationManager(
            defaults: environment.defaults,
            notificationRequestAdder: { _, completion in
                completion(nil)
            }
        ))
        XCTAssertEqual(
            reloaded.normalizedNotificationStateCount(
                profileID: profileID,
                providerID: .codex
            ),
            0
        )
        XCTAssertEqual(
            reloaded.normalizedNotificationStateCount(
                profileID: profileID,
                providerID: .claude
            ),
            0
        )
        XCTAssertEqual(
            reloaded.normalizedNotificationStateCount(
                profileID: otherProfileID,
                providerID: .claude
            ),
            1
        )
    }

    func testInvalidAndFutureNotificationLedgersResetOnlyForDeletion()
        throws
    {
        let fixtures = [
            Data("{invalid".utf8),
            Data(
                """
                {"schemaVersion":999,"records":[]}
                """.utf8
            )
        ]
        for fixture in fixtures {
            let environment = try makeEnvironment()
            environment.defaults.set(
                fixture,
                forKey: "normalizedUsageNotificationLedger.v1"
            )
            var requests: [UNNotificationRequest] = []
            let manager = retain(NotificationManager(
                defaults: environment.defaults,
                notificationRequestAdder: {
                    request,
                    completion in
                    requests.append(request)
                    completion(nil)
                }
            ))
            let profileID = UUID()
            let now = Date(
                timeIntervalSinceReferenceDate: 49_975
            )
            manager.checkAndNotify(
                report: try report(
                    providerID: .codex,
                    fetchedAt: now,
                    windows: [
                        ("group", "primary", 96, 59_975)
                    ]
                ),
                profileID: profileID,
                profileName: "Codex",
                settings: NotificationSettings(),
                now: now
            )

            XCTAssertTrue(requests.isEmpty)
            XCTAssertEqual(
                environment.defaults.data(
                    forKey:
                        "normalizedUsageNotificationLedger.v1"
                ),
                fixture
            )
            try manager.clearNotificationsForProfile(
                profileID,
                providerID: .codex
            )
            let resetData = try XCTUnwrap(
                environment.defaults.data(
                    forKey:
                        "normalizedUsageNotificationLedger.v1"
                )
            )
            let resetObject = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: resetData
                ) as? [String: Any]
            )
            XCTAssertEqual(resetObject["schemaVersion"] as? Int, 1)
            XCTAssertEqual(
                (resetObject["records"] as? [Any])?.count,
                0
            )

            manager.checkAndNotify(
                report: try report(
                    providerID: .codex,
                    fetchedAt: now,
                    windows: [
                        ("group", "primary", 96, 59_975)
                    ]
                ),
                profileID: profileID,
                profileName: "Codex",
                settings: NotificationSettings(),
                now: now
            )
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testNotificationsRetainMissingWindowStateAndSeparateProfiles()
        throws
    {
        let firstProfile = UUID()
        let secondProfile = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 50_000)
        let initial = try report(
            providerID: .codex,
            fetchedAt: now,
            windows: [
                ("known", "primary", 70, 60_000),
                ("unknown.future", "burst", 20, 70_000)
            ]
        )
        let first = UsageNotificationPolicy.evaluate(
            report: initial,
            profileID: firstProfile,
            settings: NotificationSettings(),
            now: now,
            previousStates: [:]
        )
        let missingFuture = try report(
            providerID: .codex,
            fetchedAt: now.addingTimeInterval(1),
            windows: [
                ("known", "primary", 76, 60_000)
            ]
        )
        let next = UsageNotificationPolicy.evaluate(
            report: missingFuture,
            profileID: firstProfile,
            settings: NotificationSettings(),
            now: now.addingTimeInterval(1),
            previousStates: first.states
        )
        XCTAssertEqual(next.states.count, 2)
        XCTAssertEqual(next.events.map(\.threshold), [75])

        let second = UsageNotificationPolicy.evaluate(
            report: initial,
            profileID: secondProfile,
            settings: NotificationSettings(),
            now: now,
            previousStates: [:]
        )
        XCTAssertNotEqual(
            Set(first.states.keys.map(\.profileID)),
            Set(second.states.keys.map(\.profileID))
        )
    }

    func testStaleAndUnavailableReportsDoNotNotifyOrAdvanceState()
        throws
    {
        let profileID = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 80_000)
        let key = UsageNotificationWindowKey(
            profileID: profileID,
            providerID: .codex,
            groupID: try UsageLimitGroupID("group"),
            windowID: try UsageWindowID("window")
        )
        let existing = [
            key: UsageNotificationWindowState(
                cycleID: "existing",
                percentage: 70,
                lastSeenAt: now.addingTimeInterval(-1)
            )
        ]
        let stale = try report(
            providerID: .codex,
            fetchedAt: now.addingTimeInterval(-20),
            staleAt: now.addingTimeInterval(-1),
            windows: [("group", "window", 99, 90_000)]
        )
        let staleResult = UsageNotificationPolicy.evaluate(
            report: stale,
            profileID: profileID,
            settings: NotificationSettings(),
            now: now,
            previousStates: existing
        )
        XCTAssertTrue(staleResult.events.isEmpty)
        XCTAssertEqual(staleResult.states, existing)

        let unavailable = try report(
            providerID: .codex,
            health: .unavailable,
            fetchedAt: now,
            windows: [("group", "window", 99, 90_000)]
        )
        let unavailableResult =
            UsageNotificationPolicy.evaluate(
                report: unavailable,
                profileID: profileID,
                settings: NotificationSettings(),
                now: now,
                previousStates: existing
            )
        XCTAssertTrue(unavailableResult.events.isEmpty)
        XCTAssertEqual(unavailableResult.states, existing)

        let recovered = try report(
            providerID: .codex,
            fetchedAt: now.addingTimeInterval(1),
            windows: [("group", "window", 99, 90_000)]
        )
        let recoveredResult = UsageNotificationPolicy.evaluate(
            report: recovered,
            profileID: profileID,
            settings: NotificationSettings(),
            now: now.addingTimeInterval(1),
            previousStates: unavailableResult.states
        )
        XCTAssertEqual(
            recoveredResult.events.compactMap(\.threshold),
            [95]
        )
    }

    func testAutomationCapabilityMatrixIsExplicit() {
        let claude = ClaudeUsageProviderAdapter.capabilities
        let codex = CodexProviderFactory.capabilities
        for capability in [
            ProviderCapability.usageHistory,
            .usageNotifications,
            .automaticSessionStart,
            .automaticProfileSwitch,
            .cliAccountSync,
            .apiBilling
        ] {
            XCTAssertNotEqual(claude[capability], .unknown)
            XCTAssertNotEqual(codex[capability], .unknown)
        }
        let claudePolicy = ProviderFeatureSurfacePolicy(
            capabilities: claude
        )
        let codexPolicy = ProviderFeatureSurfacePolicy(
            capabilities: codex
        )
        let expectations: [
            ProviderFeatureSurface: (claude: Bool, codex: Bool)
        ] = [
            .history: (true, true),
            .notifications: (true, true),
            .automaticSessionStart: (true, false),
            .automaticProfileSwitch: (true, false),
            .cliAccountSync: (true, false),
            .apiBilling: (true, false),
            .genericRefresh: (true, true),
            .shortcuts: (true, true),
            .launchAtLogin: (true, true)
        ]
        XCTAssertEqual(
            Set(expectations.keys),
            Set(ProviderFeatureSurface.allCases)
        )
        for surface in ProviderFeatureSurface.allCases {
            let expected = expectations[surface]
            XCTAssertEqual(
                claudePolicy.supports(surface),
                expected?.claude,
                "Claude surface policy missing \(surface)"
            )
            XCTAssertEqual(
                codexPolicy.supports(surface),
                expected?.codex,
                "Codex surface policy missing \(surface)"
            )
        }
        XCTAssertEqual(
            Set(ShortcutAction.allCases),
            [.togglePopover, .refresh, .openSettings, .nextProfile]
        )
        XCTAssertTrue(
            AutoStartSessionService.isSupported(
                for: .claude,
                capabilities: claude
            )
        )
        XCTAssertFalse(
            AutoStartSessionService.isSupported(
                for: .codex,
                capabilities: codex
            )
        )
    }

    func testNormalizedHistorySeriesIdentityIncludesProfile() throws {
        let first = NormalizedHistorySeriesIdentity(
            profileID: UUID(),
            providerID: .codex,
            groupID: try UsageLimitGroupID("subscription"),
            windowID: try UsageWindowID("session")
        )
        let second = NormalizedHistorySeriesIdentity(
            profileID: UUID(),
            providerID: .codex,
            groupID: first.groupID,
            windowID: first.windowID
        )

        XCTAssertNotEqual(first, second)
    }

    /// Switching to a provider that lacks the selected section's capability
    /// must redirect to General rather than leave a section on screen that the
    /// sidebar no longer lists.
    ///
    /// Retargeted from `.claudeCode` to `.history` when the statusline was
    /// removed. The mechanism under test is `normalizeSection`, which is still
    /// live — the statusline section was only ever this test's *vehicle*, and
    /// `.history` is now the sole capability-gated section. Deleting the test
    /// along with the feature would have left the redirect with no coverage at
    /// all.
    func testProviderChangeRedirectsCapabilityHiddenSection() {
        let navigation = retain(SettingsNavigationModel())
        navigation.selectedSection = .history

        navigation.activeProviderDidChange(
            .codex,
            capabilities: ProviderCapabilities([
                .usageHistory: .unavailable
            ])
        )

        XCTAssertEqual(navigation.selectedSection, .general)
    }

    func testRouterGatesCodexHistoryAndNotificationsByCapabilityAndIdentity()
        throws
    {
        let profileID = UUID()
        let now = Date(timeIntervalSinceReferenceDate: 100_000)
        let context = UsagePresentationContext(
            epoch: 1,
            focusedProfileID: profileID,
            visibleProfileIDs: [profileID]
        )
        let report = try report(
            providerID: .codex,
            fetchedAt: now,
            windows: [("group", "primary", 50, 110_000)]
        )
        var calls: [String] = []
        let router = retain(MenuBarManager.RefreshSideEffectRouter(
            hooks: .init(
                recordNormalized: { _, _ in
                    calls.append("history")
                },
                recordClaude: { _, _ in
                    calls.append("legacy-history")
                },
                notifyNormalized: { _, _ in
                    calls.append("notify")
                },
                autoSwitch: { _, _, _ in
                    calls.append("auto-switch")
                },
                recordAPI: { _, _ in
                    calls.append("api-history")
                },
                finalizeBatch: { _ in },
                recordBatchSuccess: { _ in },
                recordClaudeBatchSuccess: { _ in },
                showBatchSuccess: { _ in },
                autoSwitchBatch: { _, _, _ in },
                logFailure: { _, _ in },
                recordInteractiveFailure: { _, _ in },
                showInteractiveFailure: { _, _ in }
            )
        ))
        let event = acceptedEvent(
            profileID: profileID,
            providerRevision: 2,
            context: context,
            report: report,
            capabilities: ProviderCapabilities([
                .usageHistory: .available,
                .usageNotifications: .available,
                .automaticSessionStart: .unavailable
            ]),
            committedAt: now
        )

        router.committed(event)
        router.presented(
            event,
            currentContext: context,
            activeProfile: Profile(
                id: profileID,
                name: "Codex",
                providerConfiguration: .codex(
                    CodexProfileConfiguration()
                ),
                providerRevision: 2
            )
        )
        XCTAssertEqual(calls, ["history", "notify"])

        calls.removeAll()
        router.presented(
            event,
            currentContext: context,
            activeProfile: Profile(
                id: profileID,
                name: "Changed identity",
                providerConfiguration: .codex(
                    CodexProfileConfiguration()
                ),
                providerRevision: 3
            )
        )
        XCTAssertTrue(calls.isEmpty)

        calls.removeAll()
        let claudeReport = try self.report(
            providerID: .claude,
            fetchedAt: now,
            windows: [("subscription", "session", 50, 110_000)]
        )
        let claude = acceptedEvent(
            profileID: profileID,
            providerRevision: 2,
            context: context,
            report: claudeReport,
            capabilities: ClaudeUsageProviderAdapter.capabilities,
            committedAt: now
        )
        router.committed(claude)
        XCTAssertFalse(
            calls.contains("history"),
            "Claude must not dual-write normalized and legacy history"
        )

        calls.removeAll()
        let unavailable = acceptedEvent(
            profileID: profileID,
            providerRevision: 2,
            context: context,
            report: report,
            capabilities: ProviderCapabilities([
                .usageHistory: .unavailable,
                .usageNotifications: .unavailable
            ]),
            committedAt: now
        )
        router.committed(unavailable)
        router.presented(
            unavailable,
            currentContext: context,
            activeProfile: Profile(
                id: profileID,
                name: "Codex",
                providerConfiguration: .codex(
                    CodexProfileConfiguration()
                ),
                providerRevision: 2
            )
        )
        XCTAssertTrue(calls.isEmpty)
    }

    private func acceptedEvent(
        profileID: UUID,
        providerRevision: UInt64,
        context: UsagePresentationContext,
        report: UsageReport,
        capabilities: ProviderCapabilities,
        committedAt: Date
    ) -> AcceptedUsageRefreshEvent {
        AcceptedUsageRefreshEvent(
            sequence: 1,
            identity: ProviderRefreshIdentity(
                profileID: profileID,
                providerID: report.providerID,
                providerRevision: providerRevision
            ),
            inputGeneration: 0,
            invocationOrder: 1,
            profileName: "Codex",
            notificationSettings: NotificationSettings(),
            trigger: .manual,
            presentationContext: context,
            capabilities: capabilities,
            previousUsage: nil,
            currentUsage: ProfileCurrentUsage(
                providerID: report.providerID,
                providerRevision: providerRevision,
                report: report
            ),
            acceptedComponents: [.providerUsage],
            committedAt: committedAt
        )
    }

    private func report(
        providerID: ProviderID,
        health: ProviderHealthStatus = .healthy,
        fetchedAt: Date,
        staleAt: Date? = nil,
        windows: [
            (
                group: String,
                window: String,
                percentage: Double,
                resetReferenceDate: TimeInterval
            )
        ]
    ) throws -> UsageReport {
        let grouped = Dictionary(grouping: windows, by: \.group)
        let groups = try grouped.map { groupID, members in
            try UsageLimitGroup(
                id: UsageLimitGroupID(groupID),
                displayName: "Display \(groupID)",
                windows: try members.map { member in
                    try UsageWindow(
                        id: UsageWindowID(member.window),
                        displayName: "Display \(member.window)",
                        usedPercentage: member.percentage,
                        resetsAt: Date(
                            timeIntervalSinceReferenceDate:
                                member.resetReferenceDate
                        )
                    )
                }
            )
        }
        return try UsageReport(
            providerID: providerID,
            health: ProviderHealth(
                status: health,
                checkedAt: fetchedAt
            ),
            limitGroups: groups,
            fetchedAt: fetchedAt,
            staleAt:
                staleAt
                ?? fetchedAt.addingTimeInterval(300)
        )
    }

    private enum TestError: Error {
        case expected
        case unterminatedCSVQuote
    }

    private func parseCSV(_ csv: String) throws -> [[String]] {
        let characters = Array(csv)
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                if inQuotes,
                   index + 1 < characters.count,
                   characters[index + 1] == "\"" {
                    field.append("\"")
                    index += 2
                    continue
                }
                inQuotes.toggle()
            } else if character == ",", !inQuotes {
                row.append(field)
                field = ""
            } else if (character == "\n" || character == "\r"),
                      !inQuotes {
                row.append(field)
                field = ""
                if !row.allSatisfy(\.isEmpty) {
                    rows.append(row)
                }
                row = []
                if character == "\r",
                   index + 1 < characters.count,
                   characters[index + 1] == "\n" {
                    index += 1
                }
            } else {
                field.append(character)
            }
            index += 1
        }

        guard !inQuotes else {
            throw TestError.unterminatedCSVQuote
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    private func makeEnvironment() throws -> (
        defaults: UserDefaults,
        rootURL: URL
    ) {
        let (defaults, suiteName) = try HostedTestDefaults.defaults(
            "ProviderHistoryNotificationTests"
        )
        HostedTestDefaults.reset(defaults, suiteName: suiteName)
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ProviderHistoryNotificationTests-"
                    + UUID().uuidString
            )
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
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
