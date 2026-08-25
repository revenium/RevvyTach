import AppKit
import UsageCore
import XCTest
@testable import Claude_Usage

@MainActor
final class ProviderMenuPresentationTests: HostedAppTestCase {
    private final class MenuTarget: NSObject {
        @objc func activate() {}
        @objc func refresh() {}
        @objc func account() {}
        @objc func appearance() {}
        @objc func profiles() {}
        @objc func quit() {}
        @objc func toggle() {}
    }

    func testStableMetricIdentityRoundTripsArbitraryComponents()
        throws
    {
        let id = MenuBarMetricID(
            providerID: try ProviderID("future.provider"),
            groupID: try UsageLimitGroupID("group/with.dots"),
            windowID: try UsageWindowID("window + unicode-ß")
        )

        let encoded = try JSONEncoder().encode(id)
        let decoded = try JSONDecoder().decode(
            MenuBarMetricID.self,
            from: encoded
        )

        XCTAssertEqual(decoded, id)
        XCTAssertEqual(
            MenuBarMetricID(stableValue: id.stableValue),
            id
        )
        XCTAssertTrue(id.stableValue.hasPrefix("v1.window."))
        XCTAssertFalse(id.stableValue.contains("window + unicode"))
    }

    func testProviderPlaceholderIdentityIsDistinctAndStable() throws {
        let claude = MenuBarMetricID.providerPlaceholder(.claude)
        let codex = MenuBarMetricID.providerPlaceholder(.codex)

        XCTAssertNotEqual(claude, codex)
        XCTAssertNotEqual(codex, .claudeSession)
        XCTAssertEqual(
            try JSONDecoder().decode(
                MenuBarMetricID.self,
                from: JSONEncoder().encode(codex)
            ),
            codex
        )
    }

    func testEveryLegacyMetricFixtureDecodesLosslessly() throws {
        let fixtures: [(String, MenuBarMetricID, MenuBarIconStyle)] = [
            (
                """
                {"metricType":"session","isEnabled":true,"iconStyle":"battery","order":0,"weekDisplayMode":"percentage","apiDisplayMode":"remaining","showNextSessionTime":true}
                """,
                .claudeSession,
                .battery
            ),
            (
                """
                {"metricType":"week","isEnabled":true,"iconStyle":"progressBar","order":1}
                """,
                .claudeWeek,
                .progressBar
            ),
            (
                """
                {"metricType":"api","isEnabled":false,"iconStyle":"compact","order":2,"apiDisplayMode":"both"}
                """,
                .claudeAPI,
                .compact
            )
        ]

        for (json, expectedID, expectedStyle) in fixtures {
            let decoded = try JSONDecoder().decode(
                MetricIconConfig.self,
                from: Data(json.utf8)
            )
            XCTAssertEqual(decoded.metricID, expectedID)
            XCTAssertEqual(decoded.iconStyle, expectedStyle)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: JSONEncoder().encode(decoded)
                ) as? [String: Any]
            )
            XCTAssertNotNil(object["metricID"])
            XCTAssertNotNil(object["metricType"])
        }
    }

    func testLegacyConfigurationKeysAndDefaultsStillDecode() throws {
        let data = Data(
            """
            {
              "monochromeMode": true,
              "showIconNames": false,
              "metrics": [
                {"metricType":"session","isEnabled":true,"iconStyle":"battery","order":0}
              ]
            }
            """.utf8
        )

        let decoded = try JSONDecoder().decode(
            MenuBarIconConfiguration.self,
            from: data
        )

        XCTAssertEqual(decoded.colorMode, .monochrome)
        XCTAssertFalse(decoded.showIconNames)
        XCTAssertEqual(decoded.metricSelectionMode, .custom)
        XCTAssertEqual(decoded.enabledMetrics.map(\.metricID), [
            .claudeSession
        ])
    }

    func testMalformedDuplicateMetricConfigurationUsesFirstOccurrence()
        throws
    {
        let data = Data(
            """
            {
              "colorMode":"multiColor",
              "showIconNames":true,
              "metrics":[
                {"metricType":"session","isEnabled":false,"iconStyle":"battery","order":7},
                {"metricType":"session","isEnabled":true,"iconStyle":"compact","order":0}
              ]
            }
            """.utf8
        )

        let decoded = try JSONDecoder().decode(
            MenuBarIconConfiguration.self,
            from: data
        )

        XCTAssertEqual(decoded.metrics.count, 1)
        XCTAssertFalse(decoded.metrics[0].isEnabled)
        XCTAssertEqual(decoded.metrics[0].iconStyle, .battery)
        XCTAssertTrue(decoded.enabledMetrics.isEmpty)
    }

    func testEnabledMetricOrderingUsesPersistedOrderThenArrayOrder()
        throws
    {
        let descriptors = makeDescriptorCatalog(count: 3)
        let config = MenuBarIconConfiguration(
            metricSelectionMode: .custom,
            metrics: [
                MetricIconConfig(
                    metricID: descriptors[2].id,
                    isEnabled: true,
                    order: 1
                ),
                MetricIconConfig(
                    metricID: descriptors[0].id,
                    isEnabled: true,
                    order: 0
                ),
                MetricIconConfig(
                    metricID: descriptors[1].id,
                    isEnabled: true,
                    order: 1
                )
            ]
        )

        XCTAssertEqual(config.enabledMetrics.map(\.metricID), [
            descriptors[0].id,
            descriptors[2].id,
            descriptors[1].id
        ])
    }

    func testExactLegacyAutosaveNamesRemainUnchanged() {
        XCTAssertEqual(
            StatusBarUIManager.autosaveName(for: .claudeSession),
            "claude-usage-tracker.session"
        )
        XCTAssertEqual(
            StatusBarUIManager.autosaveName(for: .claudeWeek),
            "claude-usage-tracker.week"
        )
        XCTAssertEqual(
            StatusBarUIManager.autosaveName(for: .claudeAPI),
            "claude-usage-tracker.api"
        )
        XCTAssertEqual(
            StatusBarUIManager.autosaveName(
                for: .claudeSession,
                isLegacyPlaceholder: true
            ),
            "claude-usage-tracker.session"
        )
    }

    func testDynamicAutosaveNameUsesStableIdentity() throws {
        let id = MenuBarMetricID(
            providerID: .codex,
            groupID: try UsageLimitGroupID("codex.group"),
            windowID: try UsageWindowID("codex.window")
        )
        XCTAssertEqual(
            StatusBarUIManager.autosaveName(for: id),
            "claude-usage-tracker.metric.\(id.stableValue)"
        )
    }

    func testClaudeDefaultAndExplicitAllDisabledAreUnchanged() {
        XCTAssertEqual(
            MenuBarIconConfiguration.default.metricSelectionMode,
            .custom
        )
        XCTAssertEqual(
            MenuBarIconConfiguration.default.enabledMetrics.map(\.metricID),
            [.claudeSession]
        )
        var disabled = MenuBarIconConfiguration.default
        disabled.metrics = disabled.metrics.map {
            var value = $0
            value.isEnabled = false
            return value
        }
        let catalog = makeDescriptorCatalog(count: 2)
        XCTAssertTrue(disabled.resolvedMetrics(catalog: catalog).isEmpty)
        XCTAssertEqual(disabled.metricSelectionMode, .custom)
    }

    func testCodexAutomaticSelectsFirstUsableCanonicalWindow() {
        var catalog = makeDescriptorCatalog(count: 4)
        catalog[0] = ProviderMetricDescriptor(
            id: catalog[0].id,
            providerID: catalog[0].providerID,
            groupName: catalog[0].groupName,
            metricName: catalog[0].metricName,
            resetAt: nil,
            duration: nil,
            usedPercentage: nil,
            isUsable: false,
            unavailableReason: "Unavailable"
        )
        let config = MenuBarIconConfiguration.default(for: .codex)

        XCTAssertEqual(
            config.resolvedMetrics(catalog: catalog).map(\.metricID),
            [catalog[1].id]
        )
    }

    func testDynamicCatalogSupportsMoreThanTwoGroupsAndWindows()
        throws
    {
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        let profile = codexProfile()
        let report = try makeReport(
            fetchedAt: now,
            staleAt: now.addingTimeInterval(60),
            groupCount: 3,
            windowsPerGroup: 3
        )
        let snapshot = makeSnapshot(
            profile: profile,
            report: report
        )

        let catalog = ProviderMenuPresentationBuilder.catalog(
            profile: profile,
            snapshot: snapshot
        )

        XCTAssertEqual(catalog.count, 9)
        XCTAssertEqual(Set(catalog.map(\.id)).count, 9)
        XCTAssertEqual(catalog.first?.groupName, "Group 0")
        XCTAssertEqual(catalog.last?.metricName, "Window 2")
    }

    func testVanishedAutomaticMetricFallsForwardButCustomDoesNot()
        throws
    {
        let catalog = makeDescriptorCatalog(count: 3)
        let vanished = MenuBarMetricID(
            providerID: .codex,
            groupID: try UsageLimitGroupID("vanished"),
            windowID: try UsageWindowID("vanished")
        )
        let automatic = MenuBarIconConfiguration.default(for: .codex)
        let custom = MenuBarIconConfiguration(
            metricSelectionMode: .custom,
            metrics: [
                MetricIconConfig(
                    metricID: vanished,
                    isEnabled: true
                )
            ]
        )

        XCTAssertEqual(
            automatic.resolvedMetrics(catalog: catalog).first?.metricID,
            catalog.first?.id
        )
        XCTAssertTrue(custom.resolvedMetrics(catalog: catalog).isEmpty)
        XCTAssertEqual(custom.metrics.first?.metricID, vanished)
    }

    func testMixedProviderOrderingIsCanonicalAndStable() {
        let claudeB = Profile(name: "Zulu")
        let claudeA = Profile(name: "Alpha")
        let codex = codexProfile(name: "Alpha")
        let values = ProviderMenuPresentationBuilder.presentations(
            profiles: [codex, claudeB, claudeA],
            snapshots: [:],
            now: .distantPast,
            isActive: { _ in false }
        )

        XCTAssertEqual(values.map(\.identity.providerID), [
            .claude, .claude, .codex
        ])
        XCTAssertEqual(values.map(\.profileName), [
            "Alpha", "Zulu", "Alpha"
        ])
    }

    func testPresentationStatesCoverLoadingStaleDegradedErrorAndNoData()
        throws
    {
        let now = Date(timeIntervalSinceReferenceDate: 20_000)
        let profile = codexProfile()
        let freshReport = try makeReport(
            fetchedAt: now.addingTimeInterval(-20),
            staleAt: now.addingTimeInterval(20)
        )
        let staleReport = try makeReport(
            fetchedAt: now.addingTimeInterval(-20),
            staleAt: now.addingTimeInterval(-1)
        )
        let requestID = UUID()

        XCTAssertEqual(
            presentation(
                profile,
                snapshot: makeSnapshot(
                    profile: profile,
                    activity: .refreshing(
                        requestID: requestID,
                        trigger: .manual,
                        startedAt: now
                    )
                ),
                now: now
            ).metric?.state,
            nil
        )
        let loadingSnapshot = makeSnapshot(
            profile: profile,
            activity: .refreshing(
                requestID: requestID,
                trigger: .manual,
                startedAt: now
            )
        )
        let loadingPresentation =
            ProviderMenuPresentationBuilder.presentation(
                profile: profile,
                snapshot: loadingSnapshot,
                now: now,
                isActive: true
            )
        XCTAssertTrue(loadingPresentation.metrics.isEmpty)
        XCTAssertEqual(loadingPresentation.state, .loading)

        XCTAssertEqual(
            presentation(
                profile,
                snapshot: makeSnapshot(
                    profile: profile,
                    report: staleReport
                ),
                now: now
            ).metric?.state,
            .stale
        )
        XCTAssertEqual(
            presentation(
                profile,
                snapshot: makeSnapshot(
                    profile: profile,
                    report: freshReport,
                    failure: failure(at: now)
                ),
                now: now
            ).metric?.state,
            .degraded
        )
        let errorSnapshot = makeSnapshot(
            profile: profile,
            configurationState: .dependencyMissing,
            failure: failure(at: now)
        )
        let errorPresentation =
            ProviderMenuPresentationBuilder.presentation(
                profile: profile,
                snapshot: errorSnapshot,
                now: now,
                isActive: true
            )
        XCTAssertTrue(errorPresentation.metrics.isEmpty)
        XCTAssertEqual(errorPresentation.state, .error)
        let noDataPresentation =
            ProviderMenuPresentationBuilder.presentation(
                profile: profile,
                snapshot: nil,
                now: now,
                isActive: true
            )
        XCTAssertTrue(noDataPresentation.metrics.isEmpty)
        XCTAssertEqual(noDataPresentation.state, .noData)
    }

    func testCachedMetricSurvivesLoadingAndDegradedNotices() throws {
        let now = Date(timeIntervalSinceReferenceDate: 30_000)
        let profile = codexProfile()
        let report = try makeReport(
            fetchedAt: now,
            staleAt: now.addingTimeInterval(60),
            usedPercentage: 42
        )
        let degraded = presentation(
            profile,
            snapshot: makeSnapshot(
                profile: profile,
                report: report,
                failure: failure(at: now)
            ),
            now: now
        )
        let loading = presentation(
            profile,
            snapshot: makeSnapshot(
                profile: profile,
                report: report,
                activity: .refreshing(
                    requestID: UUID(),
                    trigger: .manual,
                    startedAt: now
                )
            ),
            now: now
        )

        XCTAssertEqual(degraded.metric?.usedPercentage, 42)
        XCTAssertEqual(degraded.metric?.state, .degraded)
        XCTAssertNotNil(degraded.metric?.notice)
        XCTAssertEqual(loading.metric?.usedPercentage, 42)
        XCTAssertEqual(loading.metric?.state, .loading)
    }

    func testUsedRemainingZeroHundredAndThresholdBoundaries()
        throws
    {
        let now = Date(timeIntervalSinceReferenceDate: 40_000)
        for (used, expectedStatus) in [
            (0.0, UsageStatusLevel.safe),
            (49.999, .safe),
            (50.0, .moderate),
            (79.999, .moderate),
            (80.0, .critical),
            (100.0, .critical)
        ] {
            let profile = codexProfile(
                config: .default(for: .codex)
            )
            let value = presentation(
                profile,
                snapshot: makeSnapshot(
                    profile: profile,
                    report: try makeReport(
                        fetchedAt: now,
                        staleAt: now.addingTimeInterval(60),
                        usedPercentage: used
                    )
                ),
                now: now
            ).metric
            XCTAssertEqual(value?.displayedPercentage, used)
            XCTAssertEqual(value?.statusLevel, expectedStatus)
        }

        var remainingConfig = MenuBarIconConfiguration.default(for: .codex)
        remainingConfig.showRemainingPercentage = true
        let profile = codexProfile(config: remainingConfig)
        let remaining = presentation(
            profile,
            snapshot: makeSnapshot(
                profile: profile,
                report: try makeReport(
                    fetchedAt: now,
                    staleAt: now.addingTimeInterval(60),
                    usedPercentage: 100
                )
            ),
            now: now
        ).metric
        XCTAssertEqual(remaining?.displayedPercentage, 0)
        XCTAssertEqual(remaining?.modeText, "remaining")
    }

    func testFreshnessDeadlineIsBoundedAndTransitionsAtDeadline()
        throws
    {
        let now = Date(timeIntervalSinceReferenceDate: 50_000)
        let staleAt = now.addingTimeInterval(30)
        let profile = codexProfile()
        let snapshot = makeSnapshot(
            profile: profile,
            report: try makeReport(
                fetchedAt: now,
                staleAt: staleAt
            )
        )
        let before = presentation(profile, snapshot: snapshot, now: now)
        let after = presentation(
            profile,
            snapshot: snapshot,
            now: staleAt
        )

        XCTAssertEqual(before.nextFreshnessDeadline, staleAt)
        XCTAssertEqual(
            ProviderMenuPresentationBuilder.nextFreshnessDeadline(
                presentations: [before]
            ),
            staleAt
        )
        XCTAssertEqual(before.metric?.state, .ready)
        XCTAssertEqual(after.metric?.state, .stale)
        XCTAssertNil(after.nextFreshnessDeadline)
    }

    func testProviderIdentityAndAccessibilityDoNotRelyOnColor()
        throws
    {
        let now = Date(timeIntervalSinceReferenceDate: 60_000)
        let codex = codexProfile(name: "Team")
        let value = presentation(
            codex,
            snapshot: makeSnapshot(
                profile: codex,
                report: try makeReport(
                    fetchedAt: now,
                    staleAt: now.addingTimeInterval(30)
                )
            ),
            now: now
        )

        XCTAssertEqual(
            ProviderAppearance.forProvider(.claude).compactBadge,
            "CL"
        )
        XCTAssertEqual(value.appearance.compactBadge, "CX")
        XCTAssertNotEqual(
            value.appearance.symbolName,
            ProviderAppearance.forProvider(.claude).symbolName
        )
        XCTAssertTrue(
            value.metric?.accessibilityLabel.contains("Codex") == true
        )
        XCTAssertTrue(
            value.metric?.accessibilityLabel.contains("used") == true
        )
    }

    func testDynamicVisualLabelsIdentifyProviderAndSelectedWindow()
        throws
    {
        let profile = codexProfile()
        let descriptors = makeDescriptorCatalog(count: 2)
        let metrics = descriptors.map {
            ProviderMetricPresentation(
                descriptor: $0,
                state: .ready,
                usedPercentage: 42,
                displayedPercentage: 42,
                showRemaining: false,
                elapsedFraction: 0.5,
                statusLevel: .safe,
                notice: nil
            )
        }
        let value = ProviderMenuPresentation(
            identity: ProviderStatusItemIdentity(
                profileID: profile.id,
                providerID: .codex,
                providerRevision: profile.providerRevision,
                metricID: descriptors.first?.id
            ),
            profileName: profile.name,
            appearance: .forProvider(.codex),
            metrics: metrics,
            state: .ready,
            actions: [],
            nextFreshnessDeadline: nil
        )

        let first = StatusBarUIManager.providerMetricVisualLabel(
            for: metrics[0],
            in: value,
            showLongProviderName: false
        )
        let second = StatusBarUIManager.providerMetricVisualLabel(
            for: metrics[1],
            in: value,
            showLongProviderName: false
        )

        XCTAssertEqual(first, "CX·Window 0")
        XCTAssertEqual(second, "CX·Window 1")
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.contains("CX"))
        XCTAssertTrue(first.contains(metrics[0].descriptor.metricName))
    }

    func testSingleHiddenNameDynamicItemStillHasProviderAndMetricLabel()
    {
        let profile = codexProfile()
        let descriptor = makeDescriptorCatalog(count: 1)[0]
        let metric = ProviderMetricPresentation(
            descriptor: descriptor,
            state: .ready,
            usedPercentage: 42,
            displayedPercentage: 42,
            showRemaining: false,
            elapsedFraction: nil,
            statusLevel: .safe,
            notice: nil
        )
        let value = ProviderMenuPresentation(
            identity: ProviderStatusItemIdentity(
                profileID: profile.id,
                providerID: .codex,
                providerRevision: profile.providerRevision,
                metricID: descriptor.id
            ),
            profileName: profile.name,
            appearance: .forProvider(.codex),
            metrics: [metric],
            state: .ready,
            actions: [],
            nextFreshnessDeadline: nil
        )

        XCTAssertEqual(
            StatusBarUIManager.providerMetricVisualLabel(
                for: metric,
                in: value,
                showLongProviderName: false
            ),
            "CX·Window 0"
        )
    }

    func testActionsCaptureClickedProfileAndRejectRelinkOrDeletion() {
        let profile = codexProfile()
        let value = presentation(
            profile,
            snapshot: nil,
            now: .distantPast
        )
        XCTAssertTrue(value.actions.allSatisfy {
            $0.target.profileID == profile.id
                && $0.target.providerRevision
                    == profile.providerRevision
        })
        XCTAssertTrue(
            ProviderMenuPresentationBuilder.isStillCurrent(
                value.identity,
                profiles: [profile]
            )
        )
        var relinked = profile
        relinked.providerRevision += 1
        XCTAssertFalse(
            ProviderMenuPresentationBuilder.isStillCurrent(
                value.identity,
                profiles: [relinked]
            )
        )
        var deleting = profile
        deleting.deletionInProgress = true
        XCTAssertFalse(
            ProviderMenuPresentationBuilder.isStillCurrent(
                value.identity,
                profiles: [deleting]
            )
        )
    }

    func testProviderContextMenuTargetsCapturedPresentation() {
        let target = MenuTarget()
        let profile = codexProfile(name: "Clicked")
        let value = presentation(
            profile,
            snapshot: nil,
            now: .distantPast
        )
        let menu = MenuBarManager.makeProviderContextMenu(
            presentation: value,
            target: target,
            activateAction: #selector(MenuTarget.activate),
            refreshAction: #selector(MenuTarget.refresh),
            accountSettingsAction: #selector(MenuTarget.account),
            appearanceAction: #selector(MenuTarget.appearance),
            manageProfilesAction: #selector(MenuTarget.profiles),
            quitAction: #selector(MenuTarget.quit)
        )

        XCTAssertEqual(menu.items[0].title, "Codex — Clicked")
        XCTAssertEqual(menu.items[1].action, #selector(MenuTarget.activate))
        XCTAssertEqual(menu.items[2].action, #selector(MenuTarget.refresh))
        XCTAssertTrue(
            menu.items.contains {
                $0.action == #selector(MenuTarget.account)
            }
        )
        XCTAssertTrue(
            menu.items.contains {
                $0.action == #selector(MenuTarget.appearance)
            }
        )
        XCTAssertTrue(
            menu.items.contains {
                $0.action == #selector(MenuTarget.profiles)
                    && $0.title
                        == "menu.provider.manage_profiles".localized
            }
        )
        XCTAssertTrue(
            menu.items.contains {
                $0.action == #selector(MenuTarget.quit)
                    && $0.title == "common.quit".localized
            }
        )

        let activeValue =
            ProviderMenuPresentationBuilder.presentation(
                profile: profile,
                snapshot: nil,
                now: .distantPast,
                isActive: true
            )
        let activeMenu = MenuBarManager.makeProviderContextMenu(
            presentation: activeValue,
            target: target,
            activateAction: #selector(MenuTarget.activate),
            refreshAction: #selector(MenuTarget.refresh),
            accountSettingsAction: #selector(MenuTarget.account),
            appearanceAction: #selector(MenuTarget.appearance),
            manageProfilesAction: #selector(MenuTarget.profiles),
            quitAction: #selector(MenuTarget.quit)
        )
        XCTAssertFalse(
            activeMenu.items.contains {
                $0.action == #selector(MenuTarget.activate)
            }
        )
    }

    func testStatusReconciliationCapturesExactDuplicateProviderMetrics()
        throws
    {
        let first = Profile(
            id: UUID(
                uuidString:
                    "00000000-0000-0000-0000-000000000101"
            )!,
            name: "First",
            providerConfiguration: .codex(.init())
        )
        let second = Profile(
            id: UUID(
                uuidString:
                    "00000000-0000-0000-0000-000000000102"
            )!,
            name: "Second",
            providerConfiguration: .codex(.init())
        )
        let now = Date(timeIntervalSinceReferenceDate: 70_000)
        let report = try makeReport(
            fetchedAt: now,
            staleAt: now.addingTimeInterval(60)
        )
        let firstPresentation = presentation(
            first,
            snapshot: makeSnapshot(profile: first, report: report),
            now: now
        )
        let secondPresentation = presentation(
            second,
            snapshot: makeSnapshot(profile: second, report: report),
            now: now
        )

        let single = try XCTUnwrap(
            ProviderStatusItemReconciliation.singleEntries(
                for: firstPresentation
            ).first
        )
        let firstMulti =
            ProviderStatusItemReconciliation.multiIdentity(
                for: firstPresentation
            )
        let secondMulti =
            ProviderStatusItemReconciliation.multiIdentity(
                for: secondPresentation
            )

        XCTAssertEqual(single.identity.profileID, first.id)
        XCTAssertEqual(single.identity.providerID, .codex)
        XCTAssertEqual(single.identity.providerRevision, 0)
        XCTAssertEqual(
            single.identity.metricID,
            single.statusMetricID
        )
        XCTAssertNotNil(firstMulti.metricID)
        XCTAssertEqual(firstMulti.profileID, first.id)
        XCTAssertEqual(secondMulti.profileID, second.id)
        XCTAssertNotEqual(firstMulti.profileID, secondMulti.profileID)
        XCTAssertEqual(firstMulti.providerID, secondMulti.providerID)
        XCTAssertEqual(firstMulti.metricID, secondMulti.metricID)

        XCTAssertEqual(
            ProviderStatusItemReconciliation.resolvedIdentity(
                captured: nil,
                fallbackProfile: first
            )?.profileID,
            first.id
        )
        XCTAssertNil(
            ProviderStatusItemReconciliation.resolvedIdentity(
                captured: nil,
                fallbackProfile: nil
            )
        )
    }

    func testCapturedTargetRouterRoutesAndRejectsRevisionDeletionRaces()
    {
        let original = codexProfile()
        var profiles = [original]
        var routed: [String] = []
        var settings: [SettingsNavigationDestination] = []
        let router = ProviderCapturedTargetActionRouter(
            profiles: { profiles },
            sinks: .init(
                openPopover: { _, _ in routed.append("open") },
                detachPopover: { _, _ in routed.append("detach") },
                refresh: { _, _ in routed.append("refresh") },
                activate: { _, _ in routed.append("activate") },
                settings: { destination, _, _ in
                    settings.append(destination)
                },
                quit: { _, _ in routed.append("quit") }
            )
        )
        let target = ProviderStatusItemIdentity(
            profileID: original.id,
            providerID: original.providerID,
            providerRevision: original.providerRevision,
            metricID: .providerPlaceholder(.codex)
        )

        XCTAssertTrue(router.route(.openPopover, target: target))
        XCTAssertTrue(router.route(.refresh, target: target))
        XCTAssertTrue(router.route(.activate, target: target))
        XCTAssertTrue(router.route(.detachPopover, target: target))
        XCTAssertTrue(router.route(.providerAccount, target: target))
        XCTAssertTrue(router.route(.appearance, target: target))
        XCTAssertTrue(router.route(.manageProfiles, target: target))
        XCTAssertTrue(router.route(.popoverSettings, target: target))
        XCTAssertTrue(router.route(.quit, target: target))
        XCTAssertEqual(
            routed,
            ["open", "refresh", "activate", "detach", "quit"]
        )
        XCTAssertEqual(settings, [
            .providerAccount(profileID: original.id),
            .appearance(profileID: original.id),
            .manageProfiles,
            .providerAccount(profileID: original.id),
        ])

        var relinked = original
        relinked.providerRevision += 1
        profiles = [relinked]
        XCTAssertFalse(router.route(.refresh, target: target))
        XCTAssertFalse(router.route(.manageProfiles, target: target))
        XCTAssertFalse(router.route(.detachPopover, target: target))
        XCTAssertEqual(routed.count, 5)
        XCTAssertEqual(settings.count, 4)

        profiles = []
        XCTAssertFalse(router.route(.quit, target: target))
        XCTAssertEqual(routed.count, 5)
    }

    func testManualRefreshDispatcherUsesExactProfileAndManualTrigger()
    {
        let profile = codexProfile()
        var receivedProfiles: [Profile] = []
        var receivedTrigger: UsageRefreshTrigger?
        ProviderManualRefreshDispatcher { profiles, trigger in
            receivedProfiles = profiles
            receivedTrigger = trigger
        }.dispatch(profile: profile)

        XCTAssertEqual(receivedProfiles.map(\.id), [profile.id])
        XCTAssertEqual(receivedTrigger, .manual)
    }

    func testCapturedActionEligibilityRejectsOldSingleAndUnselectedMulti()
    {
        let first = codexProfile(name: "A")
        var second = codexProfile(name: "B")
        second.isSelectedForDisplay = false
        let firstTarget = ProviderStatusItemIdentity(
            profileID: first.id,
            providerID: first.providerID,
            providerRevision: first.providerRevision,
            metricID: .providerPlaceholder(.codex)
        )

        let singleEligible = MenuBarManager.capturedActionProfiles(
            displayMode: .single,
            activeProfile: second,
            profiles: [first, second]
        )
        XCTAssertEqual(singleEligible.map(\.id), [second.id])
        let singleRouter = ProviderCapturedTargetActionRouter(
            profiles: { singleEligible },
            sinks: .init(
                openPopover: { _, _ in },
                detachPopover: { _, _ in },
                refresh: { _, _ in },
                activate: { _, _ in },
                settings: { _, _, _ in },
                quit: { _, _ in }
            )
        )
        XCTAssertFalse(
            singleRouter.route(.refresh, target: firstTarget)
        )

        let multiEligible = MenuBarManager.capturedActionProfiles(
            displayMode: .multi,
            activeProfile: first,
            profiles: [first, second]
        )
        XCTAssertEqual(multiEligible.map(\.id), [first.id])

        var unselectedFirst = first
        unselectedFirst.isSelectedForDisplay = false
        let multiFallback = MenuBarManager.capturedActionProfiles(
            displayMode: .multi,
            activeProfile: unselectedFirst,
            profiles: [unselectedFirst, second]
        )
        XCTAssertEqual(
            multiFallback.map(\.id),
            [unselectedFirst.id],
            "The default multi-profile placeholder must retain its active-profile route."
        )
    }

    func testClaudeKeepsLegacyContextMenuRouting() {
        XCTAssertTrue(
            MenuBarManager.usesLegacyContextMenu(for: .claude)
        )
        XCTAssertFalse(
            MenuBarManager.usesLegacyContextMenu(for: .codex)
        )
    }

    func testPopoverSettingsPreserveClaudeAndDeepLinkCodex() {
        let profileID = UUID()
        let claude = ProviderStatusItemIdentity(
            profileID: profileID,
            providerID: .claude,
            providerRevision: 0,
            metricID: nil
        )
        let codex = ProviderStatusItemIdentity(
            profileID: profileID,
            providerID: .codex,
            providerRevision: 0,
            metricID: nil
        )

        XCTAssertEqual(
            MenuBarManager.popoverSettingsDestination(for: claude),
            .defaultView
        )
        XCTAssertEqual(
            MenuBarManager.popoverSettingsDestination(for: codex),
            .providerAccount(profileID: profileID)
        )
    }

    func testMissingClickedSnapshotNeverFallsBackForMenuPresentation() {
        let active = Profile(name: "Active")
        let clicked = codexProfile(name: "Clicked")
        let activeSnapshot = makeSnapshot(profile: active)
        let selected = MenuBarManager.selectDisplayedUsagePresentation(
            displayMode: .multi,
            clickedProfileID: clicked.id,
            activeProfileID: active.id,
            presentations: [active.id: activeSnapshot]
        )
        XCTAssertNil(selected)
    }

    func testProviderPlaceholderDataTransitionsReconcileDistinctIDs()
        throws
    {
        let now = Date(timeIntervalSinceReferenceDate: 70_000)
        let claude = Profile(name: "Claude")
        let codex = codexProfile()
        let codexNoData = presentation(
            codex,
            snapshot: nil,
            now: now
        )
        let codexData = presentation(
            codex,
            snapshot: makeSnapshot(
                profile: codex,
                report: try makeReport(
                    fetchedAt: now,
                    staleAt: now.addingTimeInterval(30)
                )
            ),
            now: now
        )
        let claudeNoData = presentation(
            claude,
            snapshot: nil,
            now: now
        )

        let codexPlaceholder =
            StatusBarUIManager.desiredProviderMetricIDs(
                for: codexNoData
            )
        let codexMetric =
            StatusBarUIManager.desiredProviderMetricIDs(
                for: codexData
            )
        let claudePlaceholder =
            StatusBarUIManager.desiredProviderMetricIDs(
                for: claudeNoData
            )
        XCTAssertEqual(codexPlaceholder, [
            .providerPlaceholder(.codex)
        ])
        XCTAssertNotEqual(codexPlaceholder, codexMetric)
        XCTAssertNotEqual(codexPlaceholder, claudePlaceholder)
        XCTAssertEqual(codexData.identity.profileID, codex.id)
    }

    func testLiveCatalogRetainsLastKnownAndSavedUnknownChoices()
        throws
    {
        let store = ProviderMenuCatalogStore.shared
        store.resetForTesting()
        let now = Date(timeIntervalSinceReferenceDate: 75_000)
        let profile = codexProfile()
        let snapshot = makeSnapshot(
            profile: profile,
            report: try makeReport(
                fetchedAt: now,
                staleAt: now.addingTimeInterval(30),
                groupCount: 2,
                windowsPerGroup: 2
            )
        )
        store.publish(
            profiles: [profile],
            snapshots: [profile.id: snapshot]
        )
        XCTAssertEqual(store.catalogs[profile.id]?.count, 4)

        // An in-flight refresh activates a context before it has a report.
        // The open settings view must retain the last known controls.
        store.publish(profiles: [profile], snapshots: [:])
        XCTAssertEqual(store.catalogs[profile.id]?.count, 4)

        var relinked = profile
        relinked.providerRevision += 1
        store.publish(profiles: [relinked], snapshots: [:])
        XCTAssertNil(store.catalogs[profile.id])

        // Restore the original identity to exercise synthesized saved choices.
        store.publish(
            profiles: [profile],
            snapshots: [profile.id: snapshot]
        )

        let unknownID = MenuBarMetricID(
            providerID: .codex,
            groupID: try UsageLimitGroupID("saved-group"),
            windowID: try UsageWindowID("saved-window")
        )
        let config = MenuBarIconConfiguration(
            metricSelectionMode: .custom,
            metrics: [
                MetricIconConfig(
                    metricID: unknownID,
                    isEnabled: true
                )
            ]
        )
        let settingsCatalog = store.catalog(
            for: profile,
            configuration: config
        )
        XCTAssertEqual(settingsCatalog.count, 5)
        XCTAssertEqual(settingsCatalog.last?.id, unknownID)
        XCTAssertFalse(settingsCatalog.last?.isUsable ?? true)

        var deleting = profile
        deleting.deletionInProgress = true
        store.publish(
            profiles: [deleting],
            snapshots: [deleting.id: snapshot]
        )
        XCTAssertNil(store.catalogs[profile.id])

        store.publish(profiles: [], snapshots: [:])
        XCTAssertNil(store.catalogs[profile.id])
    }

    func testSnapshotIdentityAndReportProviderMustMatchExactly()
        throws
    {
        let now = Date(timeIntervalSinceReferenceDate: 76_000)
        let profile = codexProfile()
        let report = try makeReport(
            fetchedAt: now,
            staleAt: now.addingTimeInterval(30)
        )
        let valid = makeSnapshot(profile: profile, report: report)
        XCTAssertTrue(
            ProviderMenuPresentationBuilder.snapshotMatches(
                profile: profile,
                snapshot: valid
            )
        )

        var relinked = profile
        relinked.providerRevision += 1
        XCTAssertTrue(
            ProviderMenuPresentationBuilder.catalog(
                profile: relinked,
                snapshot: valid
            ).isEmpty
        )
        let relinkedPresentation =
            ProviderMenuPresentationBuilder.presentation(
                profile: relinked,
                snapshot: valid,
                now: now,
                isActive: true
            )
        XCTAssertTrue(relinkedPresentation.metrics.isEmpty)
        XCTAssertNil(relinkedPresentation.nextFreshnessDeadline)

        let other = codexProfile(name: "Other")
        XCTAssertTrue(
            ProviderMenuPresentationBuilder.catalog(
                profile: other,
                snapshot: valid
            ).isEmpty
        )

        let wrongReport = try UsageReport(
            providerID: .claude,
            health: ProviderHealth(
                status: .healthy,
                checkedAt: now
            ),
            limitGroups: report.limitGroups,
            fetchedAt: now,
            staleAt: now.addingTimeInterval(30)
        )
        XCTAssertTrue(
            ProviderMenuPresentationBuilder.catalog(
                profile: profile,
                snapshot: makeSnapshot(
                    profile: profile,
                    report: wrongReport
                )
            ).isEmpty
        )

        var deleting = profile
        deleting.deletionInProgress = true
        XCTAssertTrue(
            ProviderMenuPresentationBuilder.catalog(
                profile: deleting,
                snapshot: nil
            ).isEmpty
        )
    }

    func testStatusItemsReconcileInMetricOrderAndRetargetPlaceholders()
        throws
    {
        let manager = retain(StatusBarUIManager())
        defer { manager.cleanup() }
        let target = MenuTarget()
        let now = Date(timeIntervalSinceReferenceDate: 77_000)
        let profileA = codexProfile(name: "A")
        let profileB = codexProfile(name: "B")
        let noDataA = presentation(
            profileA,
            snapshot: nil,
            now: now
        )
        let noDataB = presentation(
            profileB,
            snapshot: nil,
            now: now
        )

        manager.updateProviderSingle(
            presentation: noDataA,
            target: target,
            action: #selector(MenuTarget.toggle),
            config: profileA.iconConfig
        )
        let placeholderA = try XCTUnwrap(
            manager.orderedSingleButtonsForTesting.first
        )
        XCTAssertEqual(
            manager.statusIdentity(for: placeholderA)?.profileID,
            profileA.id
        )
        XCTAssertTrue(
            try XCTUnwrap(manager.autosaveName(for: placeholderA))
                .contains(profileA.id.uuidString)
        )

        manager.updateProviderSingle(
            presentation: noDataB,
            target: target,
            action: #selector(MenuTarget.toggle),
            config: profileB.iconConfig
        )
        let placeholderB = try XCTUnwrap(
            manager.orderedSingleButtonsForTesting.first
        )
        XCTAssertTrue(placeholderA === placeholderB)
        XCTAssertEqual(
            manager.statusIdentity(for: placeholderB)?.profileID,
            profileB.id
        )
        XCTAssertTrue(
            try XCTUnwrap(manager.autosaveName(for: placeholderB))
                .contains(profileB.id.uuidString)
        )

        let loadingB = ProviderMenuPresentationBuilder.presentation(
            profile: profileB,
            snapshot: makeSnapshot(
                profile: profileB,
                activity: .refreshing(
                    requestID: UUID(),
                    trigger: .manual,
                    startedAt: now
                )
            ),
            now: now,
            isActive: true
        )
        manager.updateProviderSingle(
            presentation: loadingB,
            target: target,
            action: #selector(MenuTarget.toggle),
            config: profileB.iconConfig
        )
        let loadingButton = try XCTUnwrap(
            manager.orderedSingleButtonsForTesting.first
        )
        XCTAssertTrue(
            loadingButton.accessibilityLabel()?
                .contains("loading usage") == true
        )

        let report = try makeReport(
            fetchedAt: now,
            staleAt: now.addingTimeInterval(30),
            groupCount: 1,
            windowsPerGroup: 3
        )
        var custom = MenuBarIconConfiguration(
            metricSelectionMode: .custom,
            metrics: []
        )
        let catalog = ProviderMenuPresentationBuilder.catalog(
            profile: profileB,
            snapshot: makeSnapshot(profile: profileB, report: report)
        )
        custom.metrics = catalog.enumerated().map {
            MetricIconConfig(
                metricID: $0.element.id,
                isEnabled: true,
                order: $0.offset
            )
        }
        var configuredB = profileB
        configuredB.iconConfig = custom
        let dataB = presentation(
            configuredB,
            snapshot: makeSnapshot(
                profile: configuredB,
                report: report
            ),
            now: now
        )
        manager.updateProviderSingle(
            presentation: dataB,
            target: target,
            action: #selector(MenuTarget.toggle),
            config: custom
        )
        let dataButtons = manager.orderedSingleButtonsForTesting
        XCTAssertEqual(dataButtons.count, 3)
        XCTAssertEqual(
            dataButtons.compactMap {
                manager.statusIdentity(for: $0)?.metricID
            },
            catalog.map(\.id)
        )
        XCTAssertFalse(dataButtons.contains { $0 === placeholderB })

        manager.updateConfiguration(
            target: target,
            action: #selector(MenuTarget.toggle),
            config: .default
        )
        XCTAssertTrue(
            dataButtons.allSatisfy {
                manager.statusIdentity(for: $0) == nil
            }
        )

        manager.updateProviderSingle(
            presentation: noDataB,
            target: target,
            action: #selector(MenuTarget.toggle),
            config: profileB.iconConfig
        )
        let returnedPlaceholder = try XCTUnwrap(
            manager.orderedSingleButtonsForTesting.first
        )
        XCTAssertFalse(returnedPlaceholder === dataButtons[0])
        XCTAssertEqual(
            manager.statusIdentity(for: returnedPlaceholder)?.profileID,
            profileB.id
        )
    }

    func testMultiProfileConfigControlsDynamicMetricPresentation()
        throws
    {
        let descriptor = makeDescriptorCatalog(count: 1)[0]
        let metric = ProviderMetricPresentation(
            descriptor: descriptor,
            state: .ready,
            usedPercentage: 25,
            displayedPercentage: 25,
            showRemaining: false,
            elapsedFraction: 0.25,
            statusLevel: .safe,
            notice: nil
        )
        let remaining = ProviderMenuPresentationBuilder.metric(
            metric,
            applying: MultiProfileDisplayConfig(
                iconStyle: .percentage,
                showWeek: false,
                showProfileLabel: false,
                useSystemColor: true,
                showTimeMarker: false,
                showPaceMarker: false,
                usePaceColoring: false,
                showRemainingPercentage: true
            )
        )
        XCTAssertEqual(remaining?.displayedPercentage, 75)
        XCTAssertTrue(remaining?.showRemaining == true)
        XCTAssertEqual(remaining?.elapsedFraction, 0.25)

        let paceSensitive = ProviderMetricPresentation(
            descriptor: descriptor,
            state: .ready,
            usedPercentage: 60,
            displayedPercentage: 60,
            showRemaining: false,
            elapsedFraction: 0.9,
            statusLevel: .moderate,
            notice: nil
        )
        let withoutPace = ProviderMenuPresentationBuilder.metric(
            paceSensitive,
            applying: MultiProfileDisplayConfig(
                iconStyle: .percentage,
                showWeek: false,
                showProfileLabel: false,
                useSystemColor: false,
                showTimeMarker: true,
                showPaceMarker: false,
                usePaceColoring: false,
                showRemainingPercentage: false
            )
        )
        let withPace = ProviderMenuPresentationBuilder.metric(
            paceSensitive,
            applying: MultiProfileDisplayConfig(
                iconStyle: .percentage,
                showWeek: false,
                showProfileLabel: false,
                useSystemColor: false,
                showTimeMarker: true,
                showPaceMarker: false,
                usePaceColoring: true,
                showRemainingPercentage: false
            )
        )
        XCTAssertEqual(withoutPace?.statusLevel, .moderate)
        XCTAssertEqual(withPace?.statusLevel, .safe)
        XCTAssertEqual(withPace?.elapsedFraction, 0.9)
    }

    /// The compact two-row percentage icon packs up to two windows (e.g.
    /// session + weekly) into one image, but its accessibility label was
    /// built from only the primary metric -- silently dropping the second
    /// window from VoiceOver. Both windows must be described when the icon
    /// actually renders both, and the secondary window must drop out when
    /// `showWeek` is off (matching what the icon itself renders).
    func testCompactPercentageAccessibilityLabelDescribesBothWindows()
        throws
    {
        let descriptors = makeDescriptorCatalog(count: 2)
        let metrics = descriptors.map { descriptor in
            ProviderMetricPresentation(
                descriptor: descriptor,
                state: .ready,
                usedPercentage: descriptor.usedPercentage,
                displayedPercentage: descriptor.usedPercentage,
                showRemaining: false,
                elapsedFraction: nil,
                statusLevel: .safe,
                notice: nil
            )
        }
        let presentation = ProviderMenuPresentation(
            identity: ProviderStatusItemIdentity(
                profileID: UUID(),
                providerID: .codex,
                providerRevision: 0,
                metricID: nil
            ),
            profileName: "Work",
            appearance: .forProvider(.codex),
            metrics: metrics,
            state: .ready,
            actions: [],
            nextFreshnessDeadline: nil
        )

        let bothWindowsConfig = MultiProfileDisplayConfig(
            iconStyle: .percentage,
            showWeek: true,
            showProfileLabel: false,
            useSystemColor: false,
            showTimeMarker: false,
            showPaceMarker: false,
            usePaceColoring: false,
            showRemainingPercentage: false
        )
        let bothWindowsLabel =
            StatusBarUIManager.compactPercentageAccessibilityLabel(
                presentation: presentation,
                config: bothWindowsConfig
            )
        XCTAssertTrue(
            bothWindowsLabel.contains(descriptors[0].metricName)
        )
        XCTAssertTrue(
            bothWindowsLabel.contains(descriptors[1].metricName)
        )
        XCTAssertTrue(bothWindowsLabel.contains("42%"))

        let sessionOnlyConfig = MultiProfileDisplayConfig(
            iconStyle: .percentage,
            showWeek: false,
            showProfileLabel: false,
            useSystemColor: false,
            showTimeMarker: false,
            showPaceMarker: false,
            usePaceColoring: false,
            showRemainingPercentage: false
        )
        let sessionOnlyLabel =
            StatusBarUIManager.compactPercentageAccessibilityLabel(
                presentation: presentation,
                config: sessionOnlyConfig
            )
        XCTAssertTrue(
            sessionOnlyLabel.contains(descriptors[0].metricName)
        )
        XCTAssertFalse(
            sessionOnlyLabel.contains(descriptors[1].metricName)
        )
    }

    /// Composites a compact percentage icon onto the black background a dark
    /// menu bar draws it against, then counts the two pixel populations the
    /// readability fix is about: digits in the menu-bar foreground colour
    /// (white) and the red critical signal. Filling the bitmap with opaque
    /// black first sidesteps premultiplied-alpha ambiguity, and the
    /// 0.4-alpha separator lands at mid-grey, below the foreground
    /// threshold.
    private func compactPercentagePixelCounts(
        _ image: NSImage
    ) throws -> (foreground: Int, red: Int) {
        let width = Int(image.size.width.rounded())
        let height = Int(image.size.height.rounded())
        let rep = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        let bounds = NSRect(x: 0, y: 0, width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.black.setFill()
        bounds.fill()
        image.draw(in: bounds)
        NSGraphicsContext.restoreGraphicsState()

        var foreground = 0
        var red = 0
        for y in 0..<height {
            for x in 0..<width {
                guard let pixel = rep.colorAt(x: x, y: y)?
                    .usingColorSpace(.deviceRGB) else { continue }
                let r = pixel.redComponent
                let g = pixel.greenComponent
                let b = pixel.blueComponent
                if r > 0.7, g > 0.7, b > 0.7 { foreground += 1 }
                if r > 0.5, g < 0.35, b < 0.35 { red += 1 }
            }
        }
        return (foreground, red)
    }

    func testCriticalCompactPercentageKeepsDimensionsAndChangesUnderlineOnly()
        throws
    {
        let renderer = MenuBarIconRenderer()
        let render: (
            UsageStatusLevel,
            UsageStatusLevel,
            String?
        ) -> NSImage = {
            sessionStatus,
            weekStatus,
            profileName in
            renderer.createMultiProfilePercentage(
                sessionPercentage: 3,
                weekPercentage: 85,
                sessionStatus: sessionStatus,
                weekStatus: weekStatus,
                profileName: profileName,
                monochromeMode: false,
                isDarkMode: true
            )
        }
        let fingerprint: (NSImage) -> Data = {
            StatusBarUIManager.imageFingerprint($0) ?? Data()
        }

        let healthy = render(.safe, .safe, "j@")
        let criticalWeek = render(.safe, .critical, "j@")
        let criticalSession = render(.critical, .safe, "j@")
        let unlabeledHealthy = render(.safe, .safe, nil)
        let unlabeledCritical = render(.safe, .critical, nil)

        XCTAssertEqual(criticalWeek.size, healthy.size)
        XCTAssertEqual(criticalSession.size, healthy.size)
        XCTAssertNotEqual(fingerprint(criticalWeek), fingerprint(healthy))
        XCTAssertNotEqual(fingerprint(criticalSession), fingerprint(healthy))
        XCTAssertEqual(unlabeledCritical.size, unlabeledHealthy.size)
        XCTAssertNotEqual(
            fingerprint(unlabeledCritical),
            fingerprint(unlabeledHealthy)
        )
        XCTAssertNotEqual(unlabeledCritical.size, .zero)

        // The unlabelled icons carry no profile label, so every
        // foreground-coloured pixel below is a digit. A healthy icon draws
        // both digits in their status colours (green), so it has none; the
        // critical icon must have some, which is exactly what the old
        // all-red critical text did not produce.
        let healthyPixels = try compactPercentagePixelCounts(unlabeledHealthy)
        let criticalPixels = try compactPercentagePixelCounts(
            unlabeledCritical
        )
        XCTAssertEqual(
            healthyPixels.foreground,
            0,
            "Healthy digits should stay in their status colour"
        )
        XCTAssertEqual(
            healthyPixels.red,
            0,
            "A healthy icon should carry no red signal"
        )
        XCTAssertGreaterThan(
            criticalPixels.foreground,
            0,
            "Critical digits must render in the menu-bar foreground colour"
        )
        XCTAssertGreaterThan(
            criticalPixels.red,
            0,
            "The red underline must still mark the critical window"
        )
    }

    /// `updateProviderMultiProfileButtons` chooses between the compact
    /// two-window percentage label and the legacy single-metric label via a
    /// ternary on `config.iconStyle`. `compactPercentageAccessibilityLabel`
    /// itself is well covered elsewhere, but that call site -- the branch
    /// condition -- was not: a regression there (inverted ternary, wrong
    /// config flag) would slip past that unit test. Drive the real button
    /// through both branches and assert on the rendered
    /// `NSStatusBarButton.accessibilityLabel()`.
    func testUpdateProviderMultiProfileButtonsSelectsAccessibilityLabelBranch()
        throws
    {
        let descriptors = makeDescriptorCatalog(count: 2)
        let metrics = descriptors.map { descriptor in
            ProviderMetricPresentation(
                descriptor: descriptor,
                state: .ready,
                usedPercentage: descriptor.usedPercentage,
                displayedPercentage: descriptor.usedPercentage,
                showRemaining: false,
                elapsedFraction: nil,
                statusLevel: .safe,
                notice: nil
            )
        }
        let profile = codexProfile(name: "Codex Multi")
        let presentation = ProviderMenuPresentation(
            identity: ProviderStatusItemIdentity(
                profileID: profile.id,
                providerID: .codex,
                providerRevision: profile.providerRevision,
                metricID: nil
            ),
            profileName: profile.name,
            appearance: .forProvider(.codex),
            metrics: metrics,
            state: .ready,
            actions: [],
            nextFreshnessDeadline: nil
        )

        let manager = retain(StatusBarUIManager())
        defer { manager.cleanup() }
        let target = MenuTarget()
        manager.setupMultiProfile(
            profiles: [profile],
            target: target,
            action: #selector(MenuTarget.toggle)
        )

        let percentageConfig = MultiProfileDisplayConfig(
            iconStyle: .percentage,
            showWeek: true,
            showProfileLabel: false,
            useSystemColor: false,
            showTimeMarker: false,
            showPaceMarker: false,
            usePaceColoring: false,
            showRemainingPercentage: false
        )
        manager.updateProviderMultiProfileButtons(
            presentations: [presentation],
            profiles: [profile],
            config: percentageConfig,
            activeClaudeProfileID: nil,
            isActive: { _ in false }
        )
        let compactButton = try XCTUnwrap(manager.button(for: profile.id))
        let compactLabel = try XCTUnwrap(compactButton.accessibilityLabel())
        // Compact branch: both windows' metric names are present...
        XCTAssertTrue(compactLabel.contains(descriptors[0].metricName))
        XCTAssertTrue(compactLabel.contains(descriptors[1].metricName))
        // ...and the legacy label's group-name framing is not, proving this
        // took `compactPercentageAccessibilityLabel`, not the legacy path.
        XCTAssertFalse(compactLabel.contains(descriptors[0].groupName))

        let legacyConfig = MultiProfileDisplayConfig(
            iconStyle: .concentric,
            showWeek: true,
            showProfileLabel: false,
            useSystemColor: false,
            showTimeMarker: false,
            showPaceMarker: false,
            usePaceColoring: false,
            showRemainingPercentage: false
        )
        manager.updateProviderMultiProfileButtons(
            presentations: [presentation],
            profiles: [profile],
            config: legacyConfig,
            activeClaudeProfileID: nil,
            isActive: { _ in false }
        )
        let legacyButton = try XCTUnwrap(manager.button(for: profile.id))
        let legacyLabel = try XCTUnwrap(legacyButton.accessibilityLabel())
        // Legacy branch: only the primary metric (`metrics.first`) is
        // described, and it carries the legacy label's group-name framing.
        XCTAssertTrue(legacyLabel.contains(descriptors[0].metricName))
        XCTAssertTrue(legacyLabel.contains(descriptors[0].groupName))
        XCTAssertFalse(legacyLabel.contains(descriptors[1].metricName))
    }

    func testMultiProfileReconciliationRemovesDeletingGhostStatusItem()
        throws
    {
        let manager = retain(StatusBarUIManager())
        defer { manager.cleanup() }
        let target = MenuTarget()
        let first = codexProfile(name: "First")
        let second = codexProfile(name: "Second")
        manager.setupMultiProfile(
            profiles: [first, second],
            target: target,
            action: #selector(MenuTarget.toggle)
        )
        XCTAssertNotNil(manager.button(for: first.id))
        XCTAssertNotNil(manager.button(for: second.id))

        var deleting = first
        deleting.deletionInProgress = true
        manager.updateMultiProfileConfiguration(
            profiles: [deleting, second],
            target: target,
            action: #selector(MenuTarget.toggle)
        )

        XCTAssertNil(manager.button(for: first.id))
        XCTAssertNotNil(manager.button(for: second.id))
    }

    func testGenericRendererSupportsEveryStyleAndStateFingerprints()
        throws
    {
        let descriptor = makeDescriptorCatalog(count: 1)[0]
        let presentation = ProviderMetricPresentation(
            descriptor: descriptor,
            state: .ready,
            usedPercentage: 42,
            displayedPercentage: 42,
            showRemaining: false,
            elapsedFraction: 0.5,
            statusLevel: .safe,
            notice: nil
        )
        let renderer = MenuBarIconRenderer()
        var fingerprints = Set<Data>()
        for style in MenuBarIconStyle.allCases {
            let result: (NSSize, Data) = try autoreleasepool {
                let image = renderer.createProviderMetricImage(
                    presentation,
                    appearance: .forProvider(.codex),
                    metricConfig: MetricIconConfig(
                        metricID: descriptor.id,
                        isEnabled: true,
                        iconStyle: style
                    ),
                    globalConfig: MenuBarIconConfiguration(
                        colorMode: .monochrome,
                        showTimeMarker: true,
                        showPaceMarker: true,
                        usePaceColoring: true,
                        metricSelectionMode: .custom,
                        metrics: []
                    ),
                    isDarkMode: false,
                    showProviderLabel: true,
                    visualLabel: "CX·Window 0"
                )
                return (
                    image.size,
                    try XCTUnwrap(
                        StatusBarUIManager.imageFingerprint(image)
                    )
                )
            }
            XCTAssertGreaterThan(result.0.width, 0)
            XCTAssertGreaterThan(result.0.height, 0)
            fingerprints.insert(result.1)
        }
        XCTAssertEqual(fingerprints.count, MenuBarIconStyle.allCases.count)
    }

    func testGenericRendererDistinguishesEveryPlaceholderState()
        throws
    {
        let renderer = MenuBarIconRenderer()
        let descriptor = makeDescriptorCatalog(count: 1)[0]
        var fingerprints = Set<Data>()

        for state in [
            ProviderMetricDisplayState.loading,
            .stale,
            .degraded,
            .error,
            .noData
        ] {
            let fingerprint: Data = try autoreleasepool {
                let image = renderer.createProviderMetricImage(
                    nil,
                    appearance: .forProvider(.codex),
                    metricConfig: MetricIconConfig(
                        metricID: descriptor.id,
                        isEnabled: true,
                        iconStyle: .percentageOnly
                    ),
                    globalConfig: .default(for: .codex),
                    isDarkMode: false,
                    showProviderLabel: true,
                    visualLabel: "CX",
                    placeholderState: state
                )
                return try XCTUnwrap(
                    StatusBarUIManager.imageFingerprint(image)
                )
            }
            fingerprints.insert(fingerprint)
        }

        XCTAssertEqual(fingerprints.count, 5)
    }

    /// Regression for a real crash: `NSFont.monospacedSystemFont` is typed
    /// non-optional but returned `nil` in production
    /// (`NSInvalidArgumentException` — "attempt to insert nil object from
    /// objects[0]" — inserting it into a `.font` attributes dictionary
    /// aborted the whole app). Injecting a resolver that always returns nil
    /// reproduces that exact failure mode — both the preferred font AND the
    /// system-font fallback unavailable — without depending on the real
    /// font-matching service ever actually failing.
    func testNilFontResolverSkipsGlyphInsteadOfCrashing() throws {
        let nilFontRenderer = MenuBarIconRenderer { _, _ in nil }
        let baseImage = NSImage(size: NSSize(width: 18, height: 18))

        // applyProviderBadge -> drawProviderGlyph -> drawTerminalGlyph is
        // the exact call chain from the crash report
        // (StatusBarUIManager.updateProviderMultiProfileButtons ->
        // applyProviderBadge -> drawTerminalGlyph).
        let badged: NSImage = try autoreleasepool {
            nilFontRenderer.applyProviderBadge(
                to: baseImage,
                providerID: .codex,
                style: .glyphAndTint,
                isDarkMode: false
            )
        }
        XCTAssertGreaterThan(badged.size.width, 0)
        XCTAssertGreaterThan(badged.size.height, 0)

        // The Claude glyph path (drawSparkGlyph) shares no font-attributed
        // text, but exercise it too since it is reached by the same
        // applyProviderBadge entry point.
        let claudeBadged: NSImage = try autoreleasepool {
            nilFontRenderer.applyProviderBadge(
                to: baseImage,
                providerID: .claude,
                style: .glyphAndTint,
                isDarkMode: false
            )
        }
        XCTAssertGreaterThan(claudeBadged.size.width, 0)
        XCTAssertGreaterThan(claudeBadged.size.height, 0)

        // The normal (non-nil) path must remain visually unchanged.
        let normalRenderer = MenuBarIconRenderer()
        let normalBadged = normalRenderer.applyProviderBadge(
            to: baseImage,
            providerID: .codex,
            style: .glyphAndTint,
            isDarkMode: false
        )
        XCTAssertEqual(normalBadged.size, badged.size)
    }

    func testRingStyleSizesForAndRendersDistinctWindowLabels()
        throws
    {
        let renderer = MenuBarIconRenderer()
        let descriptors = makeDescriptorCatalog(count: 2)
        var outputs: [(NSSize, Data)] = []
        for descriptor in descriptors {
            let metric = ProviderMetricPresentation(
                descriptor: descriptor,
                state: .ready,
                usedPercentage: 42,
                displayedPercentage: 42,
                showRemaining: false,
                elapsedFraction: nil,
                statusLevel: .safe,
                notice: nil
            )
            let output: (NSSize, Data) = try autoreleasepool {
                let image = renderer.createProviderMetricImage(
                    metric,
                    appearance: .forProvider(.codex),
                    metricConfig: MetricIconConfig(
                        metricID: descriptor.id,
                        isEnabled: true,
                        iconStyle: .icon
                    ),
                    globalConfig: .default(for: .codex),
                    isDarkMode: false,
                    showProviderLabel: true,
                    visualLabel: "CX·\(descriptor.metricName)"
                )
                return (
                    image.size,
                    try XCTUnwrap(
                        StatusBarUIManager.imageFingerprint(image)
                    )
                )
            }
            outputs.append(output)
        }

        XCTAssertTrue(outputs.allSatisfy { $0.0.width > 35 })
        XCTAssertNotEqual(outputs[0].1, outputs[1].1)
    }

    func testImageFingerprintOwnsBytesAfterImageRelease() throws {
        let fingerprint: Data = try autoreleasepool {
            let image = NSImage(size: NSSize(width: 4, height: 4))
            image.lockFocus()
            NSColor.systemBlue.setFill()
            NSBezierPath(
                rect: NSRect(x: 0, y: 0, width: 4, height: 4)
            ).fill()
            image.unlockFocus()
            return try XCTUnwrap(
                StatusBarUIManager.imageFingerprint(image)
            )
        }

        // Force the NSImage/CGImage/provider autorelease pool to drain before
        // reading the retained fingerprint.
        XCTAssertFalse(fingerprint.isEmpty)
        XCTAssertGreaterThan(fingerprint.reduce(0) { $0 + Int($1) }, 0)
    }

    func testLegacyClaudeRendererRemainsPixelStableWithinCharacterization()
    {
        let renderer = MenuBarIconRenderer()
        var usage = ClaudeUsage.empty
        usage.sessionPercentage = 42
        let first: (NSSize, Data?) = autoreleasepool {
            let image = renderer.createImage(
                for: .session,
                config: .sessionDefault,
                globalConfig: .default,
                usage: usage,
                apiUsage: nil,
                isDarkMode: false,
                colorMode: .multiColor,
                singleColorHex: "#00BFFF",
                showIconName: true,
                showNextSessionTime: false
            )
            return (
                image.size,
                StatusBarUIManager.imageFingerprint(image)
            )
        }
        let second: (NSSize, Data?) = autoreleasepool {
            let image = renderer.createImage(
                for: .session,
                config: .sessionDefault,
                globalConfig: .default,
                usage: usage,
                apiUsage: nil,
                isDarkMode: false,
                colorMode: .multiColor,
                singleColorHex: "#00BFFF",
                showIconName: true,
                showNextSessionTime: false
            )
            return (
                image.size,
                StatusBarUIManager.imageFingerprint(image)
            )
        }
        XCTAssertEqual(first.1, second.1)
        XCTAssertEqual(first.0, NSSize(width: 42, height: 28))
    }

    func testRawCodexDefaultNeverShowsLegacyClaudeMetricBadge() {
        let profile = Profile(
            name: "New Codex",
            providerConfiguration: .codex(.init())
        )
        let catalog = makeDescriptorCatalog(count: 2)

        XCTAssertTrue(
            ProfileSelectionRow.displayedMetrics(
                for: profile,
                catalog: []
            ).isEmpty
        )
        XCTAssertEqual(
            ProfileSelectionRow.displayedMetrics(
                for: profile,
                catalog: catalog
            ).map(\.metricID),
            [catalog[0].id]
        )
    }

    func testBindingLegacyClaudeIdentityDoesNotChangePresentation() {
        let manager = retain(StatusBarUIManager())
        defer { manager.cleanup() }
        let target = MenuTarget()
        manager.setup(
            target: target,
            action: #selector(MenuTarget.toggle),
            config: .default
        )
        let button = manager.orderedSingleButtonsForTesting.first
        let autosaveBefore = manager.autosaveName(for: button)
        let accessibilityBefore = button?.accessibilityLabel()
        let tooltipBefore = button?.toolTip

        let first = Profile(name: "Claude A")
        var second = Profile(name: "Claude B")
        second.providerRevision = 2
        manager.bindLegacySingleProfile(first)
        XCTAssertEqual(
            manager.statusIdentity(for: button)?.profileID,
            first.id
        )
        manager.bindLegacySingleProfile(second)

        XCTAssertEqual(manager.autosaveName(for: button), autosaveBefore)
        XCTAssertEqual(button?.accessibilityLabel(), accessibilityBefore)
        XCTAssertEqual(button?.toolTip, tooltipBefore)
        let rebound = manager.statusIdentity(for: button)
        XCTAssertEqual(rebound?.profileID, second.id)
        XCTAssertEqual(rebound?.providerID, .claude)
        XCTAssertEqual(rebound?.providerRevision, 2)
        XCTAssertEqual(rebound?.metricID, .claudeSession)
    }

    private func codexProfile(
        name: String = "Codex",
        config: MenuBarIconConfiguration? = nil
    ) -> Profile {
        Profile(
            name: name,
            providerConfiguration: .codex(.init()),
            iconConfig: config ?? .default(for: .codex)
        )
    }

    private func presentation(
        _ profile: Profile,
        snapshot: PresentationSnapshot?,
        now: Date
    ) -> ProviderMenuPresentation {
        ProviderMenuPresentationBuilder.presentation(
            profile: profile,
            snapshot: snapshot,
            now: now,
            isActive: false
        )
    }

    private func makeSnapshot(
        profile: Profile,
        report: UsageReport? = nil,
        configurationState: ProviderConfigurationState = .ready,
        activity: UsageRefreshActivity = .idle,
        failure: ProviderRefreshFailure? = nil
    ) -> PresentationSnapshot {
        PresentationSnapshot(
            profileID: profile.id,
            profileName: profile.name,
            providerID: profile.providerID,
            providerRevision: profile.providerRevision,
            presentationEpoch: 1,
            capabilities: ProviderCapabilities([
                .usageLimits: .available
            ]),
            configurationState: configurationState,
            report: report,
            claudeUsage: profile.claudeUsage,
            claudeAPIUsage: profile.apiUsage,
            activity: activity,
            lastSuccessfulAt: report?.fetchedAt,
            currentFailure: failure
        )
    }

    private func makeReport(
        fetchedAt: Date,
        staleAt: Date,
        groupCount: Int = 1,
        windowsPerGroup: Int = 1,
        usedPercentage: Double = 42
    ) throws -> UsageReport {
        let groups = try (0..<groupCount).map { groupIndex in
            try UsageLimitGroup(
                id: UsageLimitGroupID("group-\(groupIndex)"),
                displayName: "Group \(groupIndex)",
                windows: try (0..<windowsPerGroup).map { windowIndex in
                    try UsageWindow(
                        id: UsageWindowID(
                            "group-\(groupIndex).window-\(windowIndex)"
                        ),
                        displayName: "Window \(windowIndex)",
                        usedPercentage: usedPercentage,
                        resetsAt: fetchedAt.addingTimeInterval(300),
                        duration: 600
                    )
                }
            )
        }
        return try UsageReport(
            providerID: .codex,
            health: ProviderHealth(
                status: .healthy,
                checkedAt: fetchedAt
            ),
            limitGroups: groups,
            fetchedAt: fetchedAt,
            staleAt: staleAt
        )
    }

    private func makeDescriptorCatalog(
        count: Int
    ) -> [ProviderMetricDescriptor] {
        (0..<count).map { index in
            ProviderMetricDescriptor(
                id: MenuBarMetricID(
                    providerID: .codex,
                    groupID: try! UsageLimitGroupID("group-\(index / 2)"),
                    windowID: try! UsageWindowID("window-\(index)")
                ),
                providerID: .codex,
                groupName: "Group \(index / 2)",
                metricName: "Window \(index)",
                resetAt: nil,
                duration: nil,
                usedPercentage: 42,
                isUsable: true,
                unavailableReason: nil
            )
        }
    }

    private func failure(at date: Date) -> ProviderRefreshFailure {
        ProviderRefreshFailure(
            kind: .transport,
            occurredAt: date,
            isRecoverable: true,
            consecutiveCount: 1
        )
    }
}
