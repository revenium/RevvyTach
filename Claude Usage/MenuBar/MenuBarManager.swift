import Cocoa
import SwiftUI
import Combine
import UsageCore

@MainActor
enum ProviderPopoverDetachmentLifecycle {
    static func shouldDetach() -> Bool { true }

    static func makeWindow(
        contentViewController: NSViewController,
        delegate: NSWindowDelegate?
    ) -> NSPanel {
        let window = NSPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: PopoverDesign.width,
                height: 600
            ),
            styleMask: [
                .titled,
                .closable,
                .nonactivatingPanel,
                .hudWindow,
            ],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = contentViewController
        window.title = ""
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.setContentSize(
            NSSize(width: PopoverDesign.width, height: 600)
        )
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        window.isRestorable = false
        window.delegate = delegate
        window.backgroundColor = .clear
        return window
    }

    static func closedRetainedWindow(
        _ closingWindow: NSWindow?,
        retainedWindow: NSWindow?
    ) -> Bool {
        guard let closingWindow, let retainedWindow else {
            return false
        }
        return closingWindow === retainedWindow
    }

    static func shouldCloseDetachedWindow(
        target: ProviderStatusItemIdentity?,
        profiles: [Profile],
        activatedProfileID: UUID? = nil,
        changedProfileID: UUID? = nil,
        displayModeChanged: Bool = false,
        selectedProfileIDs: Set<UUID>? = nil
    ) -> Bool {
        guard let target else { return true }
        if displayModeChanged { return true }
        if let selectedProfileIDs,
           !selectedProfileIDs.contains(target.profileID) {
            return true
        }
        if let activatedProfileID,
           activatedProfileID != target.profileID {
            return true
        }
        if let changedProfileID,
           changedProfileID != target.profileID {
            return false
        }
        return !ProviderMenuPresentationBuilder.isStillCurrent(
            target,
            profiles: profiles
        )
    }
}

nonisolated struct RefreshTimingPolicy: Equatable, Sendable {
    struct TimerFire: Equatable, Sendable {
        let occurredAt: Date
        let trigger: UsageRefreshTrigger
    }

    static let networkDebounce: TimeInterval = 2
    static let wakeDebounce: TimeInterval = 10
    static let wakeDelay: TimeInterval = 3
    static let timerToleranceFraction = 0.1
    /// Multiplier applied to the refresh interval while Low Power Mode is
    /// on. Doubling the cadence roughly halves the wake-up/network-radio
    /// cost of automatic refresh without the user noticing a stale menu bar.
    static let lowPowerModeIntervalMultiplier: TimeInterval = 2

    let interval: TimeInterval
    let tolerance: TimeInterval

    init(interval: TimeInterval) {
        self.interval = interval
        tolerance = interval * Self.timerToleranceFraction
    }

    /// Decides whether the auto-refresh timer should run at all, and at
    /// what interval, given display and power state. Kept pure so the
    /// decision is directly testable without a real display sleep or a
    /// live Low Power Mode toggle.
    ///
    /// Returns `nil` while the display is asleep — there is no menu bar to
    /// update, so the timer should not run until the display wakes.
    static func autoRefreshTiming(
        baseInterval: TimeInterval,
        isDisplayAsleep: Bool,
        isLowPowerModeEnabled: Bool
    ) -> RefreshTimingPolicy? {
        guard !isDisplayAsleep else { return nil }
        let interval = isLowPowerModeEnabled
            ? baseInterval * lowPowerModeIntervalMultiplier
            : baseInterval
        return RefreshTimingPolicy(interval: interval)
    }

    static func shouldRefreshForNetworkAvailability(
        hasRefreshableProfile: Bool,
        elapsedSinceLastTrigger: TimeInterval
    ) -> Bool {
        hasRefreshableProfile
            && elapsedSinceLastTrigger > networkDebounce
    }

    static func shouldRefreshAfterWake(
        elapsedSinceLastAutomaticRefresh: TimeInterval
    ) -> Bool {
        elapsedSinceLastAutomaticRefresh > wakeDebounce
    }

    /// Whether a wake-triggered refresh that was deferred by `wakeDelay`
    /// should still fire once that delay elapses. Checked again at fire
    /// time rather than trusting the check made when the deferral was
    /// scheduled, because a system wake fires both
    /// `NSWorkspace.didWakeNotification` and
    /// `NSWorkspace.screensDidWakeNotification` — the latter refreshes
    /// immediately, with no delay — so `lastAutoRefreshTime` can advance
    /// during the deferral window. Re-checking here is what stops both
    /// paths from fetching for the same wake.
    ///
    /// `isDisplayAsleep` is re-read at fire time for the same reason: the
    /// display can go back to sleep during the deferral (a brief wake, or
    /// the lid closing again), and this deferred fetch is the one path that
    /// would otherwise bypass the "no refresh while the display is asleep"
    /// guarantee the periodic timer gets from `autoRefreshTiming`.
    static func shouldFireDeferredWakeRefresh(
        lastAutoRefreshTime: Date,
        at now: Date,
        isDisplayAsleep: Bool
    ) -> Bool {
        guard !isDisplayAsleep else { return false }
        return shouldRefreshAfterWake(
            elapsedSinceLastAutomaticRefresh:
                now.timeIntervalSince(lastAutoRefreshTime)
        )
    }

    /// A system wake unconditionally means the display is awake too,
    /// regardless of whatever `isDisplayAsleep` last observed. This is a
    /// deliberate recovery path — not merely an optimisation — for a
    /// `screensDidWakeNotification` that never arrives: without it, a
    /// missed display-wake notification would leave auto-refresh paused
    /// forever, showing a silently stale menu bar until the app restarts.
    static func isDisplayAsleepAfterSystemWake() -> Bool {
        false
    }

    static func timerFired(at date: Date) -> TimerFire {
        TimerFire(occurredAt: date, trigger: .timer)
    }
}

/// Gates the automatic timer's per-profile fan-out so a profile configured
/// with a longer `refreshInterval` than its neighbors isn't polled at the
/// shared timer's (shorter) cadence just because they're shown together in
/// multi-profile mode. This is a filter applied on top of the existing
/// timer, never a replacement for it: the timer still ticks at the active
/// profile's interval, and a profile whose own interval is shorter than the
/// timer's still can't refresh more often than the timer fires. Applies
/// only to `UsageRefreshTrigger.timer`; every other trigger (manual,
/// startup, wake, network-restored, profile activation, credential change,
/// display change) bypasses this policy entirely and always refreshes.
///
/// Every branch is deliberately biased toward refreshing rather than
/// skipping: no prior record, a non-positive/non-finite interval, a clock
/// that moved backwards, or an interval that no longer matches what was
/// last recorded (the user just changed it) all refresh immediately. The
/// only way to skip is the ordinary case — already refreshed this profile
/// at its current interval, and not enough time has passed yet — so a
/// profile can never be silently stuck: the worst case is one extra
/// refresh, never one fewer.
nonisolated struct PerProfileAutoRefreshPolicy: Equatable, Sendable {
    struct Record: Equatable, Sendable {
        let lastRefresh: Date
        let interval: TimeInterval
    }

    /// Whether a profile should be fetched on this pass.
    ///
    /// `trigger` is part of the decision rather than being checked at the
    /// call site so that "only the automatic timer is throttled" is a
    /// property of this function, and therefore directly testable. Every
    /// non-timer trigger — manual refresh, startup, profile activation,
    /// credential or provider changes, network restored, wake, display
    /// change, retry — bypasses the interval gate entirely. Throttling any
    /// of those would silently stale the menu bar at the exact moments a
    /// user is most likely to be looking at it.
    static func shouldRefreshProfile(
        now: Date,
        record: Record?,
        interval: TimeInterval,
        trigger: UsageRefreshTrigger
    ) -> Bool {
        guard trigger == .timer else { return true }

        guard let record, record.interval == interval else {
            return true
        }
        guard interval.isFinite, interval > 0 else {
            return true
        }
        let elapsed = now.timeIntervalSince(record.lastRefresh)
        return elapsed < 0 || elapsed >= interval
    }

    /// Drops records for profiles that no longer exist at all, so the
    /// per-profile store doesn't grow forever as profiles are deleted. A
    /// profile that merely isn't currently selected/eligible (deselected,
    /// missing credentials, provider disabled) is NOT pruned - only
    /// `existingProfileIDs` membership matters - so reselecting it later
    /// doesn't reset its cadence back to "never refreshed."
    static func pruned(
        _ records: [UUID: Record],
        keeping existingProfileIDs: Set<UUID>
    ) -> [UUID: Record] {
        records.filter { existingProfileIDs.contains($0.key) }
    }
}

@MainActor
class MenuBarManager: NSObject, ObservableObject {
    enum UsageProjectionTarget: Equatable {
        case primary
        case clickedProfile
    }

    final class RefreshSideEffectRouter {
        struct Hooks {
            let recordNormalized:
                (AcceptedUsageRefreshEvent, UsageReport) -> Void
            let recordClaude:
                (AcceptedUsageRefreshEvent, ClaudeUsage) -> Void
            let notifyNormalized:
                (AcceptedUsageRefreshEvent, UsageReport) -> Void
            let autoSwitch:
                (
                    AcceptedUsageRefreshEvent,
                    ClaudeUsage,
                    Profile
                ) -> Void
            let recordAPI:
                (AcceptedUsageRefreshEvent, APIUsage) -> Void
            let finalizeBatch: (UsageRefreshBatchResult) -> Void
            let recordBatchSuccess:
                (UsageRefreshBatchResult) -> Void
            let recordClaudeBatchSuccess:
                (UsageRefreshBatchResult) -> Void
            let showBatchSuccess:
                (UsageRefreshBatchResult) -> Void
            let autoSwitchBatch:
                (
                    UsageRefreshBatchResult,
                    ClaudeUsage,
                    Profile
                ) -> Void
            let logFailure:
                (UsageRefreshFailureEvent, AppError) -> Void
            let recordInteractiveFailure:
                (UsageRefreshFailureEvent, AppError) -> Void
            let showInteractiveFailure:
                (UsageRefreshFailureEvent, AppError) -> Void
        }

        private let hooks: Hooks

        init(hooks: Hooks) {
            self.hooks = hooks
        }

        func committed(_ event: AcceptedUsageRefreshEvent) {
            if event.acceptedComponents.contains(.providerUsage),
               event.capabilities.supports(.usageHistory),
               event.identity.providerID != .claude,
               let report = event.currentUsage.report,
               report.providerID == event.identity.providerID {
                hooks.recordNormalized(event, report)
            }
            if event.identity.providerID == .claude,
               event.acceptedComponents.contains(.providerUsage),
               let usage = event.currentUsage.claudeUsage {
                hooks.recordClaude(event, usage)
            }
            if event.identity.providerID == .claude,
               event.acceptedComponents.contains(.claudeAPI),
               let usage = event.currentUsage.apiUsage {
                hooks.recordAPI(event, usage)
            }
            if event.acceptedComponents.contains(.providerUsage),
               event.capabilities.supports(.usageNotifications),
               let report = event.currentUsage.report,
               report.providerID == event.identity.providerID {
                // Notifications are profile-scoped committed effects, not
                // presentation effects. Multi-profile refreshes intentionally
                // have no single interactive presentation target.
                hooks.notifyNormalized(event, report)
            }
        }

        func presented(
            _ event: AcceptedUsageRefreshEvent,
            currentContext: UsagePresentationContext,
            activeProfile: Profile?
        ) {
            guard event.acceptedComponents.contains(.providerUsage),
                  let activeProfile,
                  activeProfile.providerID
                    == event.identity.providerID,
                  activeProfile.providerRevision
                    == event.identity.providerRevision,
                  MenuBarManager
                    .shouldApplyInteractiveRefreshSideEffects(
                        eventContext: event.presentationContext,
                        currentContext: currentContext,
                        eventProfileID: event.identity.profileID,
                        activeProfileID: activeProfile.id
                    ) else {
                return
            }
            if event.identity.providerID == .claude,
               let usage = event.currentUsage.claudeUsage {
                if event.capabilities.supports(
                    .automaticProfileSwitch
                ) {
                    hooks.autoSwitch(
                        event,
                        usage,
                        activeProfile
                    )
                }
            }
        }

        func finished(
            _ result: UsageRefreshBatchResult,
            currentContext: UsagePresentationContext,
            latestInvocationOrder: UInt64,
            activeProfile: Profile?,
            activeSnapshot: PresentationSnapshot?
        ) {
            guard result.isLatestBatch,
                  result.invocationOrder == latestInvocationOrder,
                  result.presentationContext == currentContext else {
                return
            }
            hooks.finalizeBatch(result)
            guard result.outcomes.values.contains(where: {
                if case .accepted = $0 { return true }
                return false
            }) else {
                return
            }
            if result.presentationContext.mode == .single {
                guard let focusedProfileID =
                        result.presentationContext.focusedProfileID,
                      activeProfile?.id == focusedProfileID,
                      case .accepted =
                        result.outcomes[focusedProfileID],
                      let activeSnapshot,
                      activeSnapshot.profileID == focusedProfileID,
                      activeSnapshot.presentationEpoch
                        == result.presentationContext.epoch,
                      activeSnapshot.providerID
                        == activeProfile?.providerID,
                      activeSnapshot.providerRevision
                        == activeProfile?.providerRevision else {
                    return
                }
                hooks.recordBatchSuccess(result)
                if activeSnapshot.providerID == .claude {
                    hooks.recordClaudeBatchSuccess(result)
                }
                if result.trigger.isUserInitiated {
                    hooks.showBatchSuccess(result)
                }
                return
            }
            guard let activeProfile,
                  let outcome = result.outcomes[activeProfile.id],
                  case .accepted = outcome,
                  let activeSnapshot,
                  activeSnapshot.providerID == .claude,
                  activeSnapshot.capabilities.supports(
                      .automaticProfileSwitch
                  ),
                  let usage = activeSnapshot.claudeUsage else {
                return
            }
            hooks.autoSwitchBatch(
                result,
                usage,
                activeProfile
            )
        }

        func failed(
            _ event: UsageRefreshFailureEvent,
            error: AppError,
            currentContext: UsagePresentationContext,
            activeProfileID: UUID?
        ) {
            hooks.logFailure(event, error)
            guard event.component != .claudeAPI,
                  event.identity.providerID == .claude,
                  MenuBarManager
                    .shouldApplyInteractiveRefreshSideEffects(
                        eventContext: event.presentationContext,
                        currentContext: currentContext,
                        eventProfileID: event.identity.profileID,
                        activeProfileID: activeProfileID
                    ) else {
                return
            }
            hooks.recordInteractiveFailure(event, error)
            if event.trigger.isUserInitiated {
                hooks.showInteractiveFailure(event, error)
            }
        }
    }

    nonisolated enum PeriodicHistoryComponent: Hashable {
        case session
        case weekly
    }

    private var statusItem: NSStatusItem?  // Legacy - kept for backwards compatibility
    private var statusBarUIManager: StatusBarUIManager?
    private var refreshTimer: Timer?
    private var freshnessDeadlineTimer: Timer?
    @Published private(set) var profileUsagePresentations:
        [UUID: PresentationSnapshot] = [:]
    @Published private(set) var usage: ClaudeUsage = .empty
    @Published private(set) var status: ClaudeStatus = .unknown
    @Published private(set) var apiUsage: APIUsage?
    @Published private(set) var isRefreshing: Bool = false

    // Error tracking for stale data / credential banners
    @Published private(set) var hasCredentialError: Bool = false
    @Published private(set) var consecutiveRefreshFailures: Int = 0
    @Published private(set) var lastRefreshError: String? = nil
    // Type-safe sibling of `lastRefreshError`, kept in sync with it, so the
    // popover's refresh-failure banner can select a genuinely relevant
    // explanation instead of a generic "failed" message.
    @Published private(set) var lastRefreshFailureKind:
        ProviderRefreshFailureKind? = nil
    // The earliest time the engine will attempt another scheduled refresh
    // for the failing profile, derived from its backoff window and any
    // server `Retry-After` hint. `nil` when no failure is active or the
    // failure carried no such hint.
    @Published private(set) var lastRefreshFailureRetryAt: Date? = nil
    /// Sanitized technical detail for the current failure (HTTP status or
    /// URL error code/domain), when known. See `ProviderRefreshFailure.detail`.
    @Published private(set) var lastRefreshFailureDetail: String? = nil
    @Published private(set) var lastSuccessfulRefreshTime: Date? = nil

    // Multi-profile mode: track which profile's icon was clicked
    @Published private(set) var clickedProfileId: UUID?
    @Published private(set) var clickedProfileUsage: ClaudeUsage?
    @Published private(set) var clickedProfileAPIUsage: APIUsage?

    // Track when refresh was last triggered (for distinguishing user vs auto refresh)
    private var lastRefreshTriggerTime: Date = .distantPast

    // Track last known reset times for history recording
    private var lastKnownSessionResetTime: [UUID: Date] = [:]
    private var lastKnownWeeklyResetTime: [UUID: Date] = [:]
    private var lastKnownAPIResetTime: [UUID: Date] = [:]

    // Track if a reset was just recorded to prevent duplicate periodic snapshots
    private var resetJustRecorded: [UUID: (session: Bool, weekly: Bool)] = [:]

    // Popover for beautiful SwiftUI interface
    private var popover: NSPopover?

    // Separate, much smaller popover for the overflow item's profile list.
    // Kept apart from `popover` so opening it never disturbs that
    // popover's retained hosting controller / detached-window state.
    private var overflowPopover: NSPopover?

    // Event monitor for closing popover on outside click
    private var eventMonitor: Any?

    // Debounce the status-item click that also dismisses a transient popover.
    private var lastPopoverCloseDate: Date = .distantPast
    private weak var lastPopoverCloseButton: NSStatusBarButton?

    // Detached window reference (when popover is detached)
    private var detachedWindow: NSWindow?

    // Settings window reference
    private var settingsWindow: NSWindow?
    private var settingsController:
        SettingsWindowNavigationController?

    // GitHub star prompt window reference
    private var githubPromptWindow: NSWindow?

    // Feedback prompt window reference
    private var feedbackWindow: NSWindow?

    // Track which button is currently showing the popover
    private weak var currentPopoverButton: NSStatusBarButton?
    private var currentPopoverTarget:
        ProviderStatusItemIdentity?
    private var contextMenuTarget: ProviderStatusItemIdentity?

    private let dataStore = DataStore.shared
    private let networkMonitor = NetworkMonitor.shared
    private let profileManager: ProfileManager
    private let providerUIDependencies: ProviderUIDependencies
    private let autoStartService = AutoStartSessionService.shared
    private let refreshRuntime: UsageRefreshRuntime
    private var refreshEventObserver: UUID?
    private var refreshPresentedEventObserver: UUID?
    private var refreshFailureObserver: UUID?
    private var refreshBatchObserver: UUID?
    private var presentationEpoch: UInt64 = 0
    private var hasCleanedUpResources = false
    private lazy var refreshSideEffectRouter =
        RefreshSideEffectRouter(
            hooks: .init(
                recordNormalized: { event, report in
                    UsageHistoryService.shared
                        .recordNormalizedReport(
                            report,
                            for: event.identity.profileID,
                            providerID:
                                event.identity.providerID,
                            recordedAt: event.committedAt
                        )
                },
                recordClaude: { [weak self] event, usage in
                    self?.recordAcceptedClaude(
                        event,
                        usage: usage
                    )
                },
                notifyNormalized: { event, report in
                    NotificationManager.shared.checkAndNotify(
                        report: report,
                        previousReport:
                            event.previousUsage?.report,
                        profileID: event.identity.profileID,
                        profileName: event.profileName,
                        settings: event.notificationSettings,
                        now: Date()
                    )
                },
                autoSwitch: { [weak self] event, usage, profile in
                    self?.checkAutoSwitchIfNeeded(
                        usage: usage,
                        currentProfile: profile,
                        expectedProfileID:
                            event.identity.profileID,
                        expectedPresentationEpoch:
                            event.presentationContext.epoch
                    )
                },
                recordAPI: { [weak self] event, usage in
                    self?.recordAcceptedAPI(
                        event,
                        usage: usage
                    )
                },
                finalizeBatch: { [weak self] _ in
                    self?.updateAllStatusBarIcons()
                },
                recordBatchSuccess: { [weak self] _ in
                    self?.recordSuccessfulSingleBatch()
                },
                recordClaudeBatchSuccess: { _ in
                    ErrorRecovery.shared.recordSuccess(for: .api)
                },
                showBatchSuccess: { [weak self] _ in
                    self?.showSuccessNotification()
                },
                autoSwitchBatch: {
                    [weak self] result, usage, profile in
                    self?.checkAutoSwitchIfNeeded(
                        usage: usage,
                        currentProfile: profile,
                        expectedProfileID: profile.id,
                        expectedPresentationEpoch:
                            result.presentationContext.epoch
                    )
                },
                logFailure: { event, error in
                    Self.logRefreshFailure(event, error: error)
                },
                recordInteractiveFailure: { _, _ in
                    ErrorRecovery.shared.recordFailure(for: .api)
                },
                showInteractiveFailure: { _, error in
                    ErrorPresenter.shared.showAlert(for: error)
                }
            )
        )

    init(
        apiService: ClaudeAPIService,
        statusService: ClaudeStatusService,
        profileManager: ProfileManager,
        refreshRuntime: UsageRefreshRuntime? = nil,
        providerUIDependencies: ProviderUIDependencies
    ) {
        self.profileManager = profileManager
        self.providerUIDependencies = providerUIDependencies
        self.refreshRuntime = refreshRuntime
            ?? UsageRefreshRuntime.live(
                profileManager: profileManager,
                apiService: apiService,
                statusService: statusService
            )
        super.init()
        refreshEventObserver = self.refreshRuntime.eventHub.observe {
            [weak self] event in
            self?.handleCommittedRefresh(event)
        }
        refreshPresentedEventObserver =
            self.refreshRuntime.eventHub.observePresented {
                [weak self] event in
                self?.handlePresentedRefresh(event)
        }
        refreshFailureObserver =
            self.refreshRuntime.eventHub.observeFailures {
                [weak self] event in
                self?.handleFailedRefresh(event)
            }
        refreshBatchObserver =
            self.refreshRuntime.eventHub.observeBatches {
                [weak self] result in
                self?.handleCompletedRefreshBatch(result)
            }
        bindRefreshPresentation()
    }

    private func bindRefreshPresentation() {
        refreshRuntime.presentationStore.$snapshots
            .sink { [weak self] snapshots in
                guard let self else { return }
                self.profileUsagePresentations = snapshots
                ProviderMenuCatalogStore.shared.publish(
                    profiles: self.profileManager.profiles,
                    snapshots: snapshots
                )
                guard let snapshot =
                        Self.selectDisplayedUsagePresentation(
                            displayMode:
                                self.profileManager.displayMode,
                            clickedProfileID:
                                self.clickedProfileId,
                            activeProfileID:
                                self.profileManager.activeProfile?.id,
                            presentations: snapshots
                        ) else {
                    self.resetVisibleRefreshProjection()
                    return
                }
                if Self.usageProjectionTarget(
                    displayMode: self.profileManager.displayMode,
                    clickedProfileID: self.clickedProfileId,
                    snapshotProfileID: snapshot.profileID
                ) == .clickedProfile {
                    self.clickedProfileUsage =
                        snapshot.claudeUsage
                    self.clickedProfileAPIUsage =
                        snapshot.claudeAPIUsage
                } else {
                    self.usage = snapshot.claudeUsage ?? .empty
                    self.apiUsage = snapshot.claudeAPIUsage
                }
                self.applyBannerProjection(from: snapshot)
                self.updateAllStatusBarIcons()
            }
            .store(in: &cancellables)

        refreshRuntime.presentationStore.$claudeStatus
            .map(\.status)
            .sink { [weak self] in
                self?.status = $0
            }
            .store(in: &cancellables)

        refreshRuntime.presentationStore.$claudeStatus
            .compactMap {
                presentation
                    -> (UInt64, ProviderRefreshFailure)? in
                presentation.failure.map {
                    (presentation.presentationEpoch, $0)
                }
            }
            .removeDuplicates {
                $0.0 == $1.0 && $0.1 == $1.1
            }
            .sink { [weak self] epoch, failure in
                guard let self,
                      self.refreshRuntime.presentationContext.epoch
                        == epoch else {
                    return
                }
                let error = Self.appError(for: failure)
                ErrorLogger.shared.log(error, severity: .info)
                LoggingService.shared.log(
                    "MenuBarManager: Claude status refresh failed"
                )
            }
            .store(in: &cancellables)
    }

    private func applyBannerProjection(
        from snapshot: PresentationSnapshot?
    ) {
        isRefreshing = snapshot?.activity.isInFlight ?? false
        lastSuccessfulRefreshTime = snapshot?.lastSuccessfulAt
        consecutiveRefreshFailures =
            snapshot?.currentFailure?.consecutiveCount ?? 0
        hasCredentialError =
            snapshot?.currentFailure?.isCredentialFailure ?? false
        lastRefreshError = snapshot?.currentFailure.map {
            String(describing: $0.kind)
        }
        lastRefreshFailureKind = snapshot?.currentFailure?.kind
        lastRefreshFailureRetryAt =
            snapshot?.currentFailure?.presentedRetryAt
        lastRefreshFailureDetail = snapshot?.currentFailure?.detail
    }

    private func activateRefreshPresentation() {
        presentationEpoch &+= 1
        let visibleProfiles: [Profile]
        if profileManager.displayMode == .multi {
            var multi = profileManager.profiles.filter(
                \.isSelectedForDisplay
            )
            // Mirror the single-display rule below: a viewed (not
            // displayed) profile must stay in the visible set too, or
            // the epoch bump that follows any view switch immediately
            // clears `clickedProfileId` and snaps the popover back to
            // the active profile — the "selecting an account does
            // nothing" bug for profiles without their own menu bar item.
            if let clickedProfileId,
               !multi.contains(where: { $0.id == clickedProfileId }),
               let viewed = profileManager.profiles.first(
                   where: { $0.id == clickedProfileId }
               ) {
                multi.append(viewed)
            }
            visibleProfiles = multi
        } else {
            var single = [profileManager.activeProfile]
                .compactMap { $0 }
            // A viewed (not active) profile in single-display mode must
            // stay hydrated/scheduled too, or the popover shows a
            // permanently missing presentation for it — see
            // `setViewedProfile(_:)`.
            if let clickedProfileId,
               clickedProfileId != profileManager.activeProfile?.id,
               let viewed = profileManager.profiles.first(
                   where: { $0.id == clickedProfileId }
               ) {
                single.append(viewed)
            } else {
                clickedProfileId = nil
                clickedProfileUsage = nil
                clickedProfileAPIUsage = nil
            }
            visibleProfiles = single
        }
        let visibleProfileIDs = Set(visibleProfiles.map(\.id))
        if profileManager.displayMode == .multi,
           let clickedProfileId,
           !visibleProfileIDs.contains(clickedProfileId) {
            self.clickedProfileId = nil
            clickedProfileUsage = nil
            clickedProfileAPIUsage = nil
        }
        refreshRuntime.activate(
            profiles: profileManager.profiles,
            focusedProfileID:
                profileManager.displayMode == .multi
                    ? clickedProfileId
                        ?? profileManager.activeProfile?.id
                    : profileManager.activeProfile?.id,
            visibleProfileIDs: visibleProfileIDs,
            epoch: presentationEpoch,
            mode: profileManager.displayMode == .multi
                ? .multi
                : .single
        )
    }

    private func resetVisibleRefreshProjection() {
        if profileManager.displayMode == .multi,
           clickedProfileId != nil {
            clickedProfileUsage = nil
            clickedProfileAPIUsage = nil
        } else {
            usage = .empty
            apiUsage = nil
        }
        isRefreshing = false
        lastSuccessfulRefreshTime = nil
        clearFailureProjection()
    }

    private func canAttemptUsageRefresh(_ profile: Profile) -> Bool {
        switch profile.providerConfiguration {
        case .claude:
            return profile.hasUsageCredentials
        case .codex(let configuration):
            return configuration.linkedHome != nil
                && refreshRuntime.registry.isRefreshEnabled(
                    for: .codex
                )
        }
    }

    private func effectiveIconConfiguration(
        for profile: Profile
    ) -> MenuBarIconConfiguration {
        profile.iconConfig.adaptedForProvider(profile.providerID)
    }

    nonisolated static func usageProjectionTarget(
        displayMode: ProfileDisplayMode,
        clickedProfileID: UUID?,
        snapshotProfileID: UUID
    ) -> UsageProjectionTarget {
        displayMode == .multi
            && clickedProfileID == snapshotProfileID
            ? .clickedProfile
            : .primary
    }

    func usagePresentation(
        for profileID: UUID
    ) -> PresentationSnapshot? {
        profileUsagePresentations[profileID]
    }

    var displayedUsagePresentation: PresentationSnapshot? {
        Self.selectDisplayedUsagePresentation(
            displayMode: profileManager.displayMode,
            clickedProfileID: clickedProfileId,
            activeProfileID: profileManager.activeProfile?.id,
            presentations: profileUsagePresentations
        )
    }

    nonisolated static func selectDisplayedUsagePresentation(
        displayMode: ProfileDisplayMode,
        clickedProfileID: UUID?,
        activeProfileID: UUID?,
        presentations: [UUID: PresentationSnapshot]
    ) -> PresentationSnapshot? {
        // `displayMode` no longer changes this selection: viewing a
        // non-active profile via `setViewedProfile` must work identically
        // in single- and multi-profile display mode.
        if let clickedProfileID {
            return presentations[clickedProfileID]
        }
        guard let activeProfileID else { return nil }
        return presentations[activeProfileID]
    }

    /// Changes which profile's data the popover displays, without touching
    /// activation state for either provider. The header's profile switcher
    /// and the "Active accounts" chips both call this — selecting or
    /// tapping a profile there is a pure view change; the only way to
    /// change which profile is *active* for a provider remains the
    /// explicit "Make Active" affordance / context menu, which continues
    /// to call `ProfileManager.activateProfile(_:)` directly.
    func setViewedProfile(_ id: UUID) {
        guard let profile = profileManager.profiles.first(
            where: { $0.id == id }
        ) else {
            return
        }
        clickedProfileId = id
        let snapshot = refreshRuntime.presentationStore.snapshot(for: id)
        clickedProfileUsage = snapshot?.claudeUsage
        clickedProfileAPIUsage = snapshot?.claudeAPIUsage
        applyBannerProjection(from: snapshot)

        // The refresh runtime otherwise only hydrates/schedules the
        // active profile (single-display mode) or the profiles selected
        // for menu bar display (multi mode). Bring any other viewed
        // profile into the visible set and, if it has never been
        // fetched, kick off a one-off fetch — without this a valid,
        // non-active/non-displayed profile shows a permanently missing
        // presentation until separately activated.
        let needsHydration: Bool
        if profileManager.displayMode == .single {
            needsHydration = id != profileManager.activeProfile?.id
        } else {
            needsHydration = !profile.isSelectedForDisplay
        }
        if needsHydration {
            activateRefreshPresentation()
            if snapshot == nil, canAttemptUsageRefresh(profile) {
                refreshRuntime.refresh(
                    profiles: [profile],
                    trigger: .manual
                )
            }
        }
    }

    static func popoverUsage(
        clickedProfileID: UUID?,
        clickedProfileUsage: ClaudeUsage?,
        activeProfileUsage: ClaudeUsage
    ) -> ClaudeUsage {
        guard clickedProfileID != nil else {
            return activeProfileUsage
        }
        return clickedProfileUsage ?? .empty
    }

    static func popoverAPIUsage(
        clickedProfileID: UUID?,
        clickedProfileAPIUsage: APIUsage?,
        activeProfileAPIUsage: APIUsage?
    ) -> APIUsage? {
        guard clickedProfileID != nil else {
            return activeProfileAPIUsage
        }
        return clickedProfileAPIUsage
    }

    private var hasRefreshableVisibleProfile: Bool {
        if profileManager.displayMode == .multi {
            return profileManager.profiles.contains {
                $0.isSelectedForDisplay
                    && canAttemptUsageRefresh($0)
            }
        }
        return profileManager.activeProfile.map(
            canAttemptUsageRefresh
        ) ?? false
    }

    private func handleCommittedRefresh(
        _ event: AcceptedUsageRefreshEvent
    ) {
        refreshSideEffectRouter.committed(event)
    }

    private func handlePresentedRefresh(
        _ event: AcceptedUsageRefreshEvent
    ) {
        guard Self.isCurrentRefreshInput(
            eventInputGeneration: event.inputGeneration,
            eventInvocationOrder: event.invocationOrder,
            currentInputGeneration:
                refreshRuntime.inputLedger.generation(
                    for: event.identity.profileID
                ),
            currentInvocationOrder:
                refreshRuntime.inputLedger.invocationOrder(
                    for: event.identity.profileID
                )
        ) else {
            return
        }
        refreshSideEffectRouter.presented(
            event,
            currentContext: refreshRuntime.presentationContext,
            activeProfile: profileManager.activeProfile
        )
    }

    private func handleCompletedRefreshBatch(
        _ result: UsageRefreshBatchResult
    ) {
        let activeProfile = profileManager.activeProfile
        refreshSideEffectRouter.finished(
            result,
            currentContext: refreshRuntime.presentationContext,
            latestInvocationOrder:
                refreshRuntime.inputLedger.latestInvocationOrder,
            activeProfile: activeProfile,
            activeSnapshot: activeProfile.flatMap {
                refreshRuntime.presentationStore.snapshot(
                    for: $0.id
                )
            }
        )
    }

    private func handleFailedRefresh(
        _ event: UsageRefreshFailureEvent
    ) {
        guard Self.isCurrentRefreshInput(
            eventInputGeneration: event.inputGeneration,
            eventInvocationOrder: event.invocationOrder,
            currentInputGeneration:
                refreshRuntime.inputLedger.generation(
                    for: event.identity.profileID
                ),
            currentInvocationOrder:
                refreshRuntime.inputLedger.invocationOrder(
                    for: event.identity.profileID
                )
        ) else {
            return
        }
        let appError = Self.appError(
            for: event.failure,
            providerID: event.identity.providerID
        )
        refreshSideEffectRouter.failed(
            event,
            error: appError,
            currentContext: refreshRuntime.presentationContext,
            activeProfileID: profileManager.activeProfile?.id
        )
    }

    private func recordAcceptedClaude(
        _ event: AcceptedUsageRefreshEvent,
        usage newUsage: ClaudeUsage
    ) {
        let previous = event.previousUsage?.claudeUsage
        checkAndRecordSessionReset(
            profileId: event.identity.profileID,
            previousUsage: previous,
            newUsage: newUsage
        )
        checkAndRecordWeeklyReset(
            profileId: event.identity.profileID,
            previousUsage: previous,
            newUsage: newUsage
        )
        let resetFlags =
            resetJustRecorded[event.identity.profileID]
            ?? (session: false, weekly: false)
        let periodicComponents =
            Self.periodicHistoryComponents(
                sessionResetRecorded: resetFlags.session,
                weeklyResetRecorded: resetFlags.weekly
            )
        if periodicComponents.contains(.session) {
            UsageHistoryService.shared.recordSessionPeriodic(
                for: event.identity.profileID,
                usage: newUsage
            )
        }
        if periodicComponents.contains(.weekly) {
            UsageHistoryService.shared.recordWeeklyPeriodic(
                for: event.identity.profileID,
                usage: newUsage
            )
        }
        resetJustRecorded[event.identity.profileID] = (
            session: false,
            weekly: false
        )
    }

    private func recordAcceptedAPI(
        _ event: AcceptedUsageRefreshEvent,
        usage newUsage: APIUsage
    ) {
        checkAndRecordBillingCycleReset(
            profileId: event.identity.profileID,
            previousUsage: event.previousUsage?.apiUsage,
            newUsage: newUsage
        )
    }

    private func recordSuccessfulSingleBatch() {
        clearFailureProjection()
        lastSuccessfulRefreshTime = Date()
    }

    /// The failure-tracking fields shared by `applyBannerProjection`,
    /// reset here so `resetVisibleRefreshProjection` and
    /// `recordSuccessfulSingleBatch` can't drift from each other when a
    /// new field is added to the group.
    private func clearFailureProjection() {
        consecutiveRefreshFailures = 0
        hasCredentialError = false
        lastRefreshError = nil
        lastRefreshFailureKind = nil
        lastRefreshFailureRetryAt = nil
        lastRefreshFailureDetail = nil
    }

    private static func logRefreshFailure(
        _ event: UsageRefreshFailureEvent,
        error appError: AppError
    ) {
        switch event.component {
        case .claudeAPI:
            ErrorLogger.shared.log(appError, severity: .info)
            LoggingService.shared.log(
                "MenuBarManager: Claude API billing refresh failed"
            )
        case .providerUsage, .capture, .persistence:
            guard event.identity.providerID == .claude else {
                ErrorLogger.shared.log(appError, severity: .info)
                LoggingService.shared.log(
                    "MenuBarManager: Provider refresh failed (\(event.failure.kind))"
                )
                return
            }
            ErrorLogger.shared.log(appError, severity: .error)
            LoggingService.shared.logError(
                "MenuBarManager: Claude usage refresh failed (\(event.failure.kind))"
            )
        }
    }

    nonisolated static func isCurrentFailureEvent(
        _ event: UsageRefreshFailureEvent,
        presentationContext: UsagePresentationContext,
        activeProfileID: UUID?
    ) -> Bool {
        event.presentationContext == presentationContext
            && event.identity.profileID == activeProfileID
    }

    nonisolated static func isCurrentRefreshInput(
        eventInputGeneration: UInt64,
        eventInvocationOrder: UInt64,
        currentInputGeneration: UInt64,
        currentInvocationOrder: UInt64
    ) -> Bool {
        eventInputGeneration == currentInputGeneration
            && eventInvocationOrder == currentInvocationOrder
    }

    nonisolated static func
        shouldApplyInteractiveRefreshSideEffects(
            eventContext: UsagePresentationContext,
            currentContext: UsagePresentationContext,
            eventProfileID: UUID,
            activeProfileID: UUID?
        ) -> Bool {
        eventContext.mode == .single
            && eventContext == currentContext
            && eventProfileID == activeProfileID
    }

    nonisolated static func periodicHistoryComponents(
        sessionResetRecorded: Bool,
        weeklyResetRecorded: Bool
    ) -> Set<PeriodicHistoryComponent> {
        var components = Set<PeriodicHistoryComponent>()
        if !sessionResetRecorded {
            components.insert(.session)
        }
        if !weeklyResetRecorded {
            components.insert(.weekly)
        }
        return components
    }

    static func appError(
        for failure: ProviderRefreshFailure,
        providerID: ProviderID? = nil
    ) -> AppError {
        if providerID == .codex,
           let presentation =
            ProviderErrorMapper.presentation(for: failure) {
            return .provider(presentation)
        }
        let code: ErrorCode
        if let legacyErrorCode = failure.legacyErrorCode {
            code = legacyErrorCode
        } else {
            switch failure.kind {
            case .unauthenticated:
                code = .apiUnauthorized
            case .timedOut:
                code = .networkTimeout
            case .malformedResponse, .protocolMismatch:
                code = .apiInvalidResponse
            case .persistence:
                // Durable commit rejection is provider-neutral. Never
                // relabel it as a transient provider outage.
                return .storageWriteFailed()
            default:
                code = .apiGenericError
            }
        }
        switch code {
        case .sessionKeyNotFound:
            return .sessionKeyNotFound()
        case .sessionKeyInvalid:
            return .sessionKeyInvalid(
                reason: "Typed refresh credential validation failed"
            )
        case .sessionKeyExpired:
            return AppError(
                code: .sessionKeyExpired,
                message: "error.session_key_invalid".localized,
                technicalDetails:
                    "Typed refresh credential validation expired",
                isRecoverable: true,
                recoverySuggestion:
                    "error.session_key_not_found.suggestion".localized
            )
        case .apiUnauthorized:
            return .apiUnauthorized()
        case .apiRateLimited:
            return .apiRateLimited()
        case .apiServerError:
            // The typed refresh boundary deliberately discards raw HTTP
            // payloads. Use a canonical safe representative status.
            return .apiServerError(statusCode: 500)
        case .networkTimeout:
            return .networkTimeout()
        case .networkUnavailable:
            return .networkUnavailable()
        case .storageWriteFailed:
            return .storageWriteFailed()
        default:
            return AppError(
                code: code,
                message:
                    "Usage refresh failed (\(failure.kind))",
                isRecoverable: failure.isRecoverable
            )
        }
    }

    // Combine cancellables for profile observation
    private var cancellables = Set<AnyCancellable>()

    // Track if we've handled the first profile switch (to allow returning to initial profile)
    private var hasHandledFirstProfileSwitch = false

    // Track which profiles have already triggered auto-switch (prevents repeated firing)
    private var autoSwitchedProfileIds: Set<UUID> = []

    // Observer for refresh interval changes
    private var refreshIntervalObserver: NSKeyValueObservation?

    // Observer for icon style changes
    private var iconStyleObserver: NSObjectProtocol?

    // Observer for icon configuration changes
    private var iconConfigObserver: NSObjectProtocol?

    // Observer for credential changes (add, remove, update)
    private var credentialsObserver: NSObjectProtocol?

    // Observers for provider relinking and profile deletion fences
    private var providerConfigurationObserver: NSObjectProtocol?
    private var profileDeletionStartedObserver: NSObjectProtocol?
    private var profileDeletionCompletedObserver: NSObjectProtocol?

    // Observer for display mode changes (single/multi profile)
    private var displayModeObserver: NSObjectProtocol?

    // Observer for multi-profile selection and visual configuration changes
    private var multiProfileConfigObserver: NSObjectProtocol?

    // Observer for screen/display changes (headless mode support)
    private var screenObserver: NSObjectProtocol?

    // Observer for frontmost-application changes (automatic-mode overflow
    // depends on the frontmost app's menu bar boundary).
    private var frontmostAppObserver: NSObjectProtocol?

    // Debounces automatic-mode overflow recomputation triggered by screen
    // configuration, frontmost-application, or menu-bar-manager changes (see
    // `handleScreenChange()` / `handleFrontmostAppChange()` /
    // `handleMenuBarManagerActivityChange()`).
    private var overflowRecomputeDebounceTimer: Timer?

    // Observers for any application launching or quitting, so automatic-mode
    // overflow can react to a menu bar manager (Ice, Thaw, ...) appearing or
    // disappearing while the app is running. Two separate tokens because
    // launch and quit are two separate `NSWorkspace` notification names.
    private var menuBarManagerLaunchObserver: NSObjectProtocol?
    private var menuBarManagerTerminateObserver: NSObjectProtocol?

    // Filters the launch/quit flood above down to genuine transitions in
    // the detected manager (see `handleMenuBarManagerActivityChange()`).
    private let menuBarManagerTracker = MenuBarManagerTransitionTracker()

    // Observer for wake-from-sleep
    private var wakeObserver: NSObjectProtocol?
    private var lastAutoRefreshTime: Date = .distantPast

    // Observers for display sleep/wake. There is no menu bar to update
    // while the display is off, so auto-refresh is fully paused rather than
    // just debounced the way system wake is above.
    private var screenSleepObserver: NSObjectProtocol?
    private var screenWakeObserver: NSObjectProtocol?
    private var isDisplayAsleep = false

    // Observer for Low Power Mode transitions, backing off the refresh
    // cadence while it's on (see `RefreshTimingPolicy.autoRefreshTiming`).
    private var lowPowerModeObserver: NSObjectProtocol?
    private var isLowPowerModeEnabled =
        ProcessInfo.processInfo.isLowPowerModeEnabled

    // Per-profile record of the last automatic (timer-triggered) refresh
    // attempt, keyed by profile ID. Used only to gate the automatic
    // periodic fan-out in `refreshAllSelectedProfiles` via
    // `PerProfileAutoRefreshPolicy` — never consulted for manual or other
    // non-timer triggers. Recorded at attempt time (not success), so a
    // profile whose fetch keeps failing is retried at its own interval
    // rather than hammered on every shared-timer tick.
    private var lastAutomaticRefreshByProfile:
        [UUID: PerProfileAutoRefreshPolicy.Record] = [:]

    // MARK: - Image Caching (CPU Optimization)
    private var cachedImage: NSImage?
    private var cachedImageKey: String = ""
    private var updateDebounceTimer: Timer?
    private var cachedIsDarkMode: Bool = false

    func setup() {
        // Initialize cached appearance to avoid layout recursion
        cachedIsDarkMode = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        // Observe profile changes - CRITICAL: Set up before anything else
        observeProfileChanges()
        activateRefreshPresentation()

        // Initialize status bar UI manager
        statusBarUIManager = StatusBarUIManager()
        statusBarUIManager?.delegate = self

        // Check if we should use multi-profile mode
        if profileManager.displayMode == .multi {
            // Multi-profile mode - setup with selected profiles
            setupMultiProfileMode(refreshTrigger: nil)
        } else {
            // Single profile mode - setup with active profile's config
            if let profile = profileManager.activeProfile,
               profile.providerID != .claude {
                updateProviderSingleDisplay(
                    profile: profile,
                    config: effectiveIconConfiguration(for: profile)
                )
            } else {
                let config = profileManager.activeProfile.map {
                    effectiveIconConfiguration(for: $0)
                } ?? .default
                let canRefresh = profileManager.activeProfile.map(
                    canAttemptUsageRefresh
                ) ?? false

                // Preserve the characterized Claude placeholder and autosave
                // behavior when usage credentials are unavailable.
                let displayConfig: MenuBarIconConfiguration
                if !canRefresh {
                    displayConfig = MenuBarIconConfiguration(
                        colorMode: config.colorMode,
                        singleColorHex: config.singleColorHex,
                        showIconNames: config.showIconNames,
                        metrics: config.metrics.map { metric in
                            var updatedMetric = metric
                            updatedMetric.isEnabled = false
                            return updatedMetric
                        }
                    )
                } else {
                    displayConfig = config
                }

                statusBarUIManager?.setup(
                    target: self,
                    action: #selector(togglePopover),
                    config: displayConfig
                )
            }
        }

        // Setup popover
        setupPopover()

        // Load saved data from active profile first (provides immediate feedback)
        // BUT only if profile has usage credentials - CLI alone can't show usage
        if let profile = profileManager.activeProfile {
            if canAttemptUsageRefresh(profile) {
                // Profile has usage credentials - show saved usage data if available
                if let savedUsage = profile.claudeUsage {
                    usage = savedUsage
                }
                if let savedAPIUsage = profile.apiUsage {
                    apiUsage = savedAPIUsage
                }
            } else {
                // No usage credentials - clear any old usage data and show default logo
                usage = .empty
                apiUsage = nil
                LoggingService.shared.log("MenuBarManager: Profile has no usage credentials, showing default logo")
            }
            updateAllStatusBarIcons()
        }

        // Start network monitoring - fetch data when network is available
        networkMonitor.onNetworkAvailable = { [weak self] in
            // Only refresh if we haven't refreshed recently (avoid duplicate on startup)
            guard let self = self else { return }

            let elapsed = Date().timeIntervalSince(
                self.lastRefreshTriggerTime
            )
            let hasRefreshableProfile =
                self.hasRefreshableVisibleProfile
            guard RefreshTimingPolicy
                    .shouldRefreshForNetworkAvailability(
                        hasRefreshableProfile:
                            hasRefreshableProfile,
                        elapsedSinceLastTrigger: elapsed
                    ) else {
                if !hasRefreshableProfile {
                    LoggingService.shared.log(
                        "Skipping network-available refresh (no usage credentials)"
                    )
                } else {
                    LoggingService.shared.log(
                        "Skipping network-available refresh (too soon after last refresh)"
                    )
                }
                return
            }
            self.refreshUsage(trigger: .networkAvailable)
        }
        networkMonitor.startMonitoring()

        // Initial data fetch (with small delay for launch-at-login scenarios)
        // Only if profile has usage credentials (not just CLI)
        if hasRefreshableVisibleProfile {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.refreshUsage(trigger: .startup)
            }
        } else {
            LoggingService.shared.log("Skipping initial refresh (no usage credentials)")
        }

        // Start auto-refresh timer with active profile's interval
        startAutoRefresh()

        // Start auto-start session service (5-minute cycle for all profiles)
        autoStartService.start()

        // Observe icon configuration changes
        observeIconConfigChanges()

        // Observe session key updates
        observeCredentialChanges()
        observeProviderLifecycleChanges()

        // Observe display mode changes (single/multi profile)
        observeDisplayModeChanges()
        observeMultiProfileConfigChanges()

        // Setup headless mode observer if enabled (for Remote Desktop support)
        setupHeadlessModeObserver()

        // Setup menu-bar-manager launch/quit observer so automatic-mode
        // overflow reacts to Ice/Thaw/... appearing or disappearing
        setupMenuBarManagerObserver()

        // Setup wake-from-sleep observer for auto-refresh
        setupWakeObserver()

        // Setup display sleep/wake observer to pause auto-refresh while
        // there is no menu bar to update
        setupScreenSleepObserver()

        // Setup Low Power Mode observer to back off the refresh cadence
        setupLowPowerModeObserver()

        // Setup global keyboard shortcuts
        setupShortcuts()
    }

    private func setupShortcuts() {
        let shortcutManager = ShortcutManager.shared
        shortcutManager.onTogglePopover = { [weak self] in
            self?.togglePopover(nil)
        }
        shortcutManager.onRefresh = { [weak self] in
            self?.refreshUsage(trigger: .manual)
        }
        shortcutManager.onOpenSettings = { [weak self] in
            self?.preferencesClicked()
        }
        shortcutManager.onNextProfile = { [weak self] in
            self?.switchToNextProfile()
        }
        shortcutManager.startListening()
    }

    func cleanup() {
        cleanupResources()
        refreshRuntime.shutdown(profiles: profileManager.profiles)
    }

    func cleanupAndWaitForTermination() async {
        cleanupResources()
        await refreshRuntime.shutdownAndWait(
            profiles: profileManager.profiles
        )
    }

    private func cleanupResources() {
        guard !hasCleanedUpResources else { return }
        hasCleanedUpResources = true
        ShortcutManager.shared.stopListening()
        refreshTimer?.invalidate()
        refreshTimer = nil
        freshnessDeadlineTimer?.invalidate()
        freshnessDeadlineTimer = nil
        overflowRecomputeDebounceTimer?.invalidate()
        overflowRecomputeDebounceTimer = nil
        networkMonitor.stopMonitoring()
        autoStartService.stop()
        profileUsagePresentations.removeAll()
        cancellables.removeAll()  // Clean up Combine subscriptions
        refreshIntervalObserver?.invalidate()
        refreshIntervalObserver = nil
        if let iconStyleObserver = iconStyleObserver {
            NotificationCenter.default.removeObserver(iconStyleObserver)
            self.iconStyleObserver = nil
        }
        if let iconConfigObserver = iconConfigObserver {
            NotificationCenter.default.removeObserver(iconConfigObserver)
            self.iconConfigObserver = nil
        }
        if let credentialsObserver = credentialsObserver {
            NotificationCenter.default.removeObserver(credentialsObserver)
            self.credentialsObserver = nil
        }
        if let providerConfigurationObserver {
            NotificationCenter.default.removeObserver(
                providerConfigurationObserver
            )
            self.providerConfigurationObserver = nil
        }
        if let profileDeletionStartedObserver {
            NotificationCenter.default.removeObserver(
                profileDeletionStartedObserver
            )
            self.profileDeletionStartedObserver = nil
        }
        if let profileDeletionCompletedObserver {
            NotificationCenter.default.removeObserver(
                profileDeletionCompletedObserver
            )
            self.profileDeletionCompletedObserver = nil
        }
        if let displayModeObserver = displayModeObserver {
            NotificationCenter.default.removeObserver(displayModeObserver)
            self.displayModeObserver = nil
        }
        if let multiProfileConfigObserver = multiProfileConfigObserver {
            NotificationCenter.default.removeObserver(multiProfileConfigObserver)
            self.multiProfileConfigObserver = nil
        }
        if let screenObserver = screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        if let frontmostAppObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(
                frontmostAppObserver
            )
            self.frontmostAppObserver = nil
        }
        if let menuBarManagerLaunchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(
                menuBarManagerLaunchObserver
            )
            self.menuBarManagerLaunchObserver = nil
        }
        if let menuBarManagerTerminateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(
                menuBarManagerTerminateObserver
            )
            self.menuBarManagerTerminateObserver = nil
        }
        if let wakeObserver = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        if let screenSleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(
                screenSleepObserver
            )
            self.screenSleepObserver = nil
        }
        if let screenWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(
                screenWakeObserver
            )
            self.screenWakeObserver = nil
        }
        if let lowPowerModeObserver {
            NotificationCenter.default.removeObserver(lowPowerModeObserver)
            self.lowPowerModeObserver = nil
        }
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        detachedWindow?.close()
        detachedWindow = nil
        settingsController?.window.close()
        settingsController = nil
        settingsWindow = nil
        statusItem = nil
        // `cleanupResources()` only ever runs on the application-termination
        // path (from `cleanup()`/`cleanupAndWaitForTermination()`, called
        // from `applicationShouldTerminate`/`applicationWillTerminate`), so
        // this is the one call site that must NOT discard AppKit's
        // persisted menu bar positions — see the doc comment on
        // `StatusBarUIManager.cleanup(isApplicationTerminating:)`.
        statusBarUIManager?.cleanup(isApplicationTerminating: true)
        statusBarUIManager = nil
        contextMenuTarget = nil
        currentPopoverTarget = nil

        // Clean up history tracking dictionaries to prevent memory leaks
        lastKnownSessionResetTime.removeAll()
        lastKnownWeeklyResetTime.removeAll()
        lastKnownAPIResetTime.removeAll()
        resetJustRecorded.removeAll()
        if let refreshEventObserver {
            refreshRuntime.eventHub.removeObserver(refreshEventObserver)
            self.refreshEventObserver = nil
        }
        if let refreshPresentedEventObserver {
            refreshRuntime.eventHub.removeObserver(
                refreshPresentedEventObserver
            )
            self.refreshPresentedEventObserver = nil
        }
        if let refreshFailureObserver {
            refreshRuntime.eventHub.removeObserver(
                refreshFailureObserver
            )
            self.refreshFailureObserver = nil
        }
        if let refreshBatchObserver {
            refreshRuntime.eventHub.removeObserver(
                refreshBatchObserver
            )
            self.refreshBatchObserver = nil
        }
    }

    /// Cleans up tracking data for a specific profile (called when profile is deleted)
    func cleanupProfile(_ profileId: UUID) {
        lastKnownSessionResetTime.removeValue(forKey: profileId)
        lastKnownWeeklyResetTime.removeValue(forKey: profileId)
        lastKnownAPIResetTime.removeValue(forKey: profileId)
        resetJustRecorded.removeValue(forKey: profileId)
        autoSwitchedProfileIds.remove(profileId)
    }

    // MARK: - Profile Observation

    private func observeProfileChanges() {
        // Store the initial profile ID to skip only the very first startup update
        let initialProfileId = profileManager.activeProfile?.id

        // Observe active profile changes
        profileManager.$activeProfile
            .removeDuplicates { oldProfile, newProfile in
                // Only trigger if the profile ID actually changed
                let result = oldProfile?.id == newProfile?.id
                if !result {
                    LoggingService.shared.log("MenuBarManager: Profile ID changed from \(oldProfile?.id.uuidString ?? "nil") to \(newProfile?.id.uuidString ?? "nil")")
                }
                return result
            }
            .dropFirst()  // Skip the initial value
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newProfile in
                guard let self else { return }
                self.activateRefreshPresentation()
                guard let profile = newProfile else { return }

                // Skip ONLY if this is the startup profile AND we haven't switched yet
                if !self.hasHandledFirstProfileSwitch && profile.id == initialProfileId {
                    LoggingService.shared.log("MenuBarManager: Skipping initial startup profile update to: \(profile.name)")
                    self.hasHandledFirstProfileSwitch = true
                    return
                }

                // Mark that we've handled at least one profile switch
                self.hasHandledFirstProfileSwitch = true

                self.handleProfileSwitch(to: profile)
            }
            .store(in: &cancellables)

        LoggingService.shared.log("MenuBarManager: Observing profile changes (initial: \(initialProfileId?.uuidString ?? "nil"))")
    }

    private func handleProfileSwitch(to profile: Profile) {
        LoggingService.shared.log("MenuBarManager: Handling profile switch to: \(profile.name)")
        closeDetachedWindowIfInvalidated(
            activatedProfileID: profile.id
        )

        // 1. Load saved data from new profile (for immediate display)
        if let savedUsage = profile.claudeUsage {
            usage = savedUsage
        } else {
            usage = .empty
        }

        if let savedAPIUsage = profile.apiUsage {
            apiUsage = savedAPIUsage
        } else {
            apiUsage = nil
        }

        // 2. Update refresh interval with profile's setting
        restartAutoRefreshWithInterval(profile.refreshInterval)

        // 3. Update menu bar based on current display mode
        if profileManager.displayMode == .multi {
            // Multi-profile mode: update button images in-place — do NOT call setupMultiProfileMode()
            // here because that tears down and recreates all NSStatusItems, which causes macOS to
            // assign new internal window IDs even when autosaveNames are identical.  Tools like
            // Bartender / Ice track items by those IDs, so rebuilding defeats the static-ID goal.
            // The set of displayed profiles hasn't changed; only the data needs refreshing.
            updateAllStatusBarIcons()
        } else {
            // Single profile mode - update menu bar configuration
            updateMenuBarDisplay(
                with: effectiveIconConfiguration(for: profile)
            )
        }

        // 4. Recreate popover with new profile data
        recreatePopover()

        // 5. Trigger immediate refresh ONLY if profile has usage credentials
        if canAttemptUsageRefresh(profile) {
            self.lastRefreshTriggerTime = Date()
            refreshUsage(trigger: .profileActivation)
        } else {
            LoggingService.shared.log("MenuBarManager: Skipping refresh for profile without usage credentials")
        }
    }

    private func recreatePopover() {
        // Close existing popover if open
        if popover?.isShown == true {
            closePopover()
        }

        // Recreate popover with fresh content
        let newPopover = NSPopover()
        newPopover.contentSize = Constants.WindowSizes.popoverSize
        newPopover.behavior = .semitransient
        // Native animated resizing recurses indefinitely with preferredContentSize
        // on macOS 26/27. PopoverContentView provides a fixed-size content animation.
        newPopover.animates = false
        newPopover.delegate = self
        newPopover.contentViewController = createContentViewController()

        self.popover = newPopover

        LoggingService.shared.log("MenuBarManager: Popover recreated for profile switch")
    }

    private func closeDetachedWindowIfInvalidated(
        activatedProfileID: UUID? = nil,
        changedProfileID: UUID? = nil,
        displayModeChanged: Bool = false,
        selectedProfileIDs: Set<UUID>? = nil
    ) {
        let hasPresentedSurface =
            detachedWindow != nil || popover?.isShown == true
        guard hasPresentedSurface,
              ProviderPopoverDetachmentLifecycle
                .shouldCloseDetachedWindow(
                    target: currentPopoverTarget,
                    profiles: profileManager.profiles,
                    activatedProfileID: activatedProfileID,
                    changedProfileID: changedProfileID,
                    displayModeChanged: displayModeChanged,
                    selectedProfileIDs: selectedProfileIDs
                ) else {
            return
        }
        if popover?.isShown == true {
            closePopover()
        }
        if let detachedWindow {
            detachedWindow.close()
            self.detachedWindow = nil
        }
        currentPopoverTarget = nil
    }

    private func updateMenuBarDisplay(with config: MenuBarIconConfiguration) {
        // Skip if in multi-profile mode - this method is for single profile mode only
        guard profileManager.displayMode == .single else {
            LoggingService.shared.log("MenuBarManager: Skipping updateMenuBarDisplay (in multi-profile mode)")
            return
        }

        if let profile = profileManager.activeProfile,
           profile.providerID != .claude {
            updateProviderSingleDisplay(
                profile: profile,
                config: config.adaptedForProvider(profile.providerID)
            )
            return
        }

        // Check if active profile has usage credentials (not just CLI)
        let canRefresh = profileManager.activeProfile.map(
            canAttemptUsageRefresh
        ) ?? false

        // If no usage credentials, use an empty config (will show default logo)
        let displayConfig: MenuBarIconConfiguration
        if !canRefresh {
            // Create config with no enabled metrics (will trigger default logo)
            displayConfig = MenuBarIconConfiguration(
                colorMode: config.colorMode,
                singleColorHex: config.singleColorHex,
                showIconNames: config.showIconNames,
                metrics: config.metrics.map { metric in
                    var updatedMetric = metric
                    updatedMetric.isEnabled = false
                    return updatedMetric
                }
            )
        } else {
            displayConfig = config
        }

        statusBarUIManager?.updateConfiguration(
            target: self,
            action: #selector(togglePopover),
            config: displayConfig
        )
        if let activeProfile = profileManager.activeProfile,
           activeProfile.providerID == .claude {
            // Retained legacy buttons must capture the newly active identity
            // before the next run-loop turn can accept a click.
            statusBarUIManager?.bindLegacySingleProfile(activeProfile)
        }

        // Defer icon update to next run loop iteration to let NSStatusBar finalize layout
        DispatchQueue.main.async { [weak self] in
            self?.updateAllStatusBarIcons()
        }
    }

    private func updateProviderSingleDisplay(
        profile: Profile,
        config: MenuBarIconConfiguration
    ) {
        let now = Date()
        let presentation =
            ProviderMenuPresentationBuilder.presentation(
                profile: profile,
                snapshot: profileUsagePresentations[profile.id],
                now: now,
                isActive: true
            )
        statusBarUIManager?.updateProviderSingle(
            presentation: presentation,
            target: self,
            action: #selector(togglePopover),
            config: config
        )
        scheduleFreshnessDeadline(for: [presentation], now: now)
    }

    private func restartAutoRefreshWithInterval(_ interval: TimeInterval) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        scheduleAutoRefreshTimer(baseInterval: interval)
    }

    private func setupPopover() {
        let popover = NSPopover()
        popover.contentSize = Constants.WindowSizes.popoverSize
        popover.behavior = .semitransient  // Changed to allow detaching
        popover.animates = false
        popover.delegate = self

        popover.contentViewController = createContentViewController()
        self.popover = popover
    }

    private func createContentViewController() -> NSHostingController<PopoverContentView> {
        // Create SwiftUI content view
        let contentView = PopoverContentView(
            manager: self,
            profileManager: profileManager,
            onRefresh: { [weak self] in
                guard let self else { return }
                self.refreshPopover(
                    target: self.popoverActionTarget()
                )
            },
            onManageProfiles: { [weak self] in
                guard let self else { return }
                self.openPopoverManageProfiles(
                    target: self.popoverActionTarget()
                )
            },
            onPreferences: { [weak self] in
                guard let self else { return }
                self.openPopoverSettings(
                    target: self.popoverActionTarget()
                )
            },
            onCLIAccount: { [weak self] in
                guard let self else { return }
                self.openPopoverCLIAccount(
                    target: self.popoverActionTarget()
                )
            },
            onClaudeAIAccount: { [weak self] in
                guard let self else { return }
                self.openPopoverClaudeAIAccount(
                    target: self.popoverActionTarget()
                )
            }
        )

        let hostingController = NSHostingController(rootView: contentView)
        hostingController.preferredContentSize = Constants.WindowSizes.popoverSize
        hostingController.sizingOptions = .preferredContentSize
        return hostingController
    }

    /// Uses the clicked status item's display rather than `NSScreen.main`,
    /// because menu bar items can be presented on any attached screen. The
    /// preferred 720pt height handles the common subscription layout without
    /// scrolling, while the visible-frame cap keeps the popover reachable on
    /// compact or scaled laptop displays.
    func sizePopover(
        _ popover: NSPopover,
        relativeTo button: NSStatusBarButton
    ) {
        let size = Constants.WindowSizes.popoverSize(
            forVisibleScreenHeight: button.window?.screen?.visibleFrame.height
        )
        popover.contentSize = size
        popover.contentViewController?.preferredContentSize = size
    }

    private func popoverActionTarget() -> ProviderStatusItemIdentity? {
        if let currentPopoverTarget {
            return currentPopoverTarget
        }
        let profileID = profileManager.displayMode == .multi
            ? clickedProfileId ?? profileManager.activeProfile?.id
            : profileManager.activeProfile?.id
        guard let profileID,
              let profile = profileManager.profiles.first(
                where: { $0.id == profileID }
              ) else {
            return nil
        }
        return ProviderStatusItemIdentity(
            profileID: profile.id,
            providerID: profile.providerID,
            providerRevision: profile.providerRevision,
            metricID: nil
        )
    }

    private func refreshPopover(
        target: ProviderStatusItemIdentity?
    ) {
        guard let target else { return }
        capturedTargetRouter().route(.refresh, target: target)
    }

    private func openPopoverSettings(
        target: ProviderStatusItemIdentity?
    ) {
        guard let target else { return }
        capturedTargetRouter().route(
            .popoverSettings,
            target: target
        )
    }

    private func openPopoverCLIAccount(
        target: ProviderStatusItemIdentity?
    ) {
        guard let target else { return }
        capturedTargetRouter().route(
            .cliAccount,
            target: target
        )
    }

    /// Settings → Claude.ai. Routes through the generic `.providerAccount`
    /// action, which `SettingsCoordinator.navigate` resolves to the
    /// `.claudeAI` section for a Claude profile — the remedy for
    /// `.claudeAccountUnresolved`, which is about the claude.ai link rather
    /// than the Claude Code one that `.cliAccount` opens.
    private func openPopoverClaudeAIAccount(
        target: ProviderStatusItemIdentity?
    ) {
        guard let target else { return }
        capturedTargetRouter().route(
            .providerAccount,
            target: target
        )
    }

    private func openPopoverManageProfiles(
        target: ProviderStatusItemIdentity?
    ) {
        guard let target else { return }
        capturedTargetRouter().route(
            .manageProfiles,
            target: target
        )
    }

    nonisolated static func popoverSettingsDestination(
        for target: ProviderStatusItemIdentity
    ) -> SettingsNavigationDestination {
        ProviderCapturedTargetActionRouter
            .popoverSettingsDestination(for: target)
    }

    @objc private func togglePopover(_ sender: Any?) {
        if Self.isContextMenuEvent(NSApp.currentEvent?.type) {
            showContextMenu(for: sender as? NSStatusBarButton)
            return
        }

        // The overflow item ("+N") represents multiple profiles, not one —
        // it needs its own list popover rather than the normal
        // single-profile detail popover.
        if let overflowButton = sender as? NSStatusBarButton,
           statusBarUIManager?.isOverflowButton(overflowButton) == true {
            toggleOverflowPopover(from: overflowButton)
            return
        }

        // Determine which button was clicked
        let clickedButton: NSStatusBarButton?
        if let button = sender as? NSStatusBarButton {
            clickedButton = button
        } else if statusBarUIManager?.isInMultiProfileMode == true,
                  let activeId = profileManager.activeProfile?.id,
                  let activeButton = statusBarUIManager?.button(for: activeId) {
            // Multi-profile mode: use the active profile's button
            clickedButton = activeButton
        } else {
            // Single profile mode: fallback to primary button
            clickedButton = statusBarUIManager?.primaryButton
        }

        guard let button = clickedButton else { return }
        guard let identity =
                ProviderStatusItemReconciliation.resolvedIdentity(
                    captured:
                        statusBarUIManager?.statusIdentity(for: button),
                    fallbackProfile: profileManager.activeProfile
                ) else {
            return
        }
        let routed = capturedTargetRouter(
            openPopover: { [weak self] target, profile in
                self?.toggleValidatedPopover(
                    from: button,
                    target: target,
                    profile: profile
                )
            }
        ).route(.openPopover, target: identity)
        if !routed {
            LoggingService.shared.logWarning(
                "Ignored status-item action for stale provider identity"
            )
        }
    }

    private func toggleValidatedPopover(
        from button: NSStatusBarButton,
        target: ProviderStatusItemIdentity,
        profile: Profile
    ) {
        // In multi-profile mode, determine which profile was clicked
        if statusBarUIManager?.isInMultiProfileMode == true,
           profileManager.profiles.contains(where: {
               $0.id == profile.id
           }) {
            clickedProfileId = profile.id
            let snapshot = refreshRuntime.presentationStore.snapshot(
                for: profile.id
            )
            clickedProfileUsage = snapshot?.claudeUsage
            clickedProfileAPIUsage = snapshot?.claudeAPIUsage
            applyBannerProjection(from: snapshot)
            LoggingService.shared.log("Multi-profile popover: showing data for '\(profile.name)'")
        } else {
            // Single profile mode - use active profile
            clickedProfileId = nil
            clickedProfileUsage = nil
            clickedProfileAPIUsage = nil
        }

        // If there's a detached window, close it
        if let window = detachedWindow {
            window.close()
            detachedWindow = nil
            currentPopoverButton = nil
            currentPopoverTarget = nil
            return
        }

        // Otherwise toggle the popover
        if let popover = popover {
            if popover.isShown {
                // Check if clicking the same button or a different one
                if currentPopoverButton === button {
                    // Same button - close the popover
                    closePopover()
                } else {
                    // Different button - close current and show at new position
                    // Close synchronously. Replacing the hosting controller while an
                    // asynchronous close is in progress can trigger BAD_ACCESS.
                    popover.close()
                    stopMonitoringForOutsideClicks()
                    // Rebuild the content for the newly clicked profile.
                    // Re-showing the retained hosting controller displays
                    // its stale render (the previously viewed profile) for
                    // a frame before SwiftUI catches up with the published
                    // clickedProfileId change — the "shows the old account
                    // first, then flips" flash.
                    popover.contentViewController = createContentViewController()
                    sizePopover(popover, relativeTo: button)
                    NSApp.activate(ignoringOtherApps: true)
                    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                    currentPopoverButton = button
                    currentPopoverTarget = target
                    startMonitoringForOutsideClicks()
                }
            } else {
                // Treat the status-item click that dismissed this same popover as
                // a close, rather than immediately bouncing the popover open again.
                if Self.shouldSuppressPopoverOpen(
                    button: button,
                    lastButton: lastPopoverCloseButton,
                    lastCloseDate: lastPopoverCloseDate
                ) {
                    return
                }

                // Stop any existing monitor first
                stopMonitoringForOutsideClicks()
                // Update content view controller for current profile data
                popover.contentViewController = createContentViewController()
                sizePopover(popover, relativeTo: button)
                NSApp.activate(ignoringOtherApps: true)
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                currentPopoverButton = button
                currentPopoverTarget = target
                startMonitoringForOutsideClicks()
            }
        }
    }

    /// Builds the rows for the overflow profile list popover, in the same
    /// order the overflow item represents them. Pulled out as a static,
    /// non-UI function so the "which profile shows which percentage" logic
    /// is testable without a live `MenuBarManager`/`NSStatusItem`.
    static func overflowProfileRows(
        profileIDs: [UUID],
        profiles: [Profile],
        snapshots: [UUID: PresentationSnapshot],
        activeProfileID: UUID?,
        now: Date = Date()
    ) -> [OverflowProfileRow] {
        profileIDs.compactMap { id in
            guard let profile = profiles.first(where: { $0.id == id })
            else {
                return nil
            }
            let presentation = ProviderMenuPresentationBuilder.presentation(
                profile: profile,
                snapshot: snapshots[id],
                now: now,
                isActive: id == activeProfileID
            )
            return OverflowProfileRow(
                id: id,
                name: profile.name,
                percentageText: presentation.metric?.percentageText ?? "—"
            )
        }
    }

    /// Shows (or, on a repeat click, hides) the overflow item's profile
    /// list popover. Kept entirely separate from the main `popover` so
    /// this never disturbs its retained hosting controller or
    /// detached-window state.
    private func toggleOverflowPopover(from button: NSStatusBarButton) {
        if let overflowPopover, overflowPopover.isShown {
            overflowPopover.performClose(nil)
            return
        }

        // Never show two content popovers/windows at once.
        closePopoverOrWindow()

        let rows = Self.overflowProfileRows(
            profileIDs: statusBarUIManager?.overflowProfileIDs ?? [],
            profiles: profileManager.profiles,
            snapshots: profileUsagePresentations,
            activeProfileID: profileManager.activeProfile?.id
        )
        let view = OverflowProfileListView(rows: rows) {
            [weak self] profileID in
            self?.overflowPopover?.performClose(nil)
            self?.selectOverflowProfile(profileID)
        }
        let hostingController = NSHostingController(rootView: view)
        hostingController.sizingOptions = .preferredContentSize

        let newPopover = NSPopover()
        newPopover.behavior = .transient
        newPopover.animates = false
        newPopover.contentViewController = hostingController
        NSApp.activate(ignoringOtherApps: true)
        newPopover.show(
            relativeTo: button.bounds,
            of: button,
            preferredEdge: .minY
        )
        overflowPopover = newPopover
    }

    /// Opens the normal profile detail popover for a profile picked from
    /// the overflow list — the same destination clicking that profile's
    /// own status item would reach, anchored to the overflow item's
    /// button since that profile has no status item of its own.
    private func selectOverflowProfile(_ profileID: UUID) {
        guard let profile = profileManager.profiles.first(where: {
            $0.id == profileID
        }), let overflowButton = statusBarUIManager?.overflowButton else {
            return
        }
        let identity = ProviderStatusItemIdentity(
            profileID: profile.id,
            providerID: profile.providerID,
            providerRevision: profile.providerRevision,
            metricID: nil
        )
        toggleValidatedPopover(
            from: overflowButton,
            target: identity,
            profile: profile
        )
    }

    nonisolated static func isContextMenuEvent(
        _ eventType: NSEvent.EventType?
    ) -> Bool {
        eventType == .rightMouseUp
    }

    static func shouldSuppressPopoverOpen(
        button: AnyObject,
        lastButton: AnyObject?,
        lastCloseDate: Date,
        now: Date = Date()
    ) -> Bool {
        guard let lastButton, button === lastButton else { return false }
        return now.timeIntervalSince(lastCloseDate) < 0.25
    }

    static func makeContextMenu(
        target: AnyObject,
        refreshAction: Selector,
        settingsAction: Selector,
        quitAction: Selector
    ) -> NSMenu {
        let menu = NSMenu()

        let refreshItem = NSMenuItem(
            title: "common.refresh".localized,
            action: refreshAction,
            keyEquivalent: ""
        )
        refreshItem.target = target
        menu.addItem(refreshItem)
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "common.settings".localized,
            action: settingsAction,
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = .command
        settingsItem.target = target
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(
            title: "common.quit".localized,
            action: quitAction,
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = .command
        quitItem.target = target
        menu.addItem(quitItem)

        return menu
    }

    static func makeProviderContextMenu(
        presentation: ProviderMenuPresentation,
        target: AnyObject,
        activateAction: Selector,
        refreshAction: Selector,
        accountSettingsAction: Selector,
        appearanceAction: Selector,
        manageProfilesAction: Selector,
        quitAction: Selector
    ) -> NSMenu {
        let menu = NSMenu()
        let heading = NSMenuItem(
            title: "\(presentation.appearance.displayName) — "
                + presentation.profileName,
            action: nil,
            keyEquivalent: ""
        )
        heading.isEnabled = false
        menu.addItem(heading)
        if presentation.actions.contains(where: {
            $0.kind == .activate
        }) {
            let activate = NSMenuItem(
                title: "menu.provider.make_active".localized,
                action: activateAction,
                keyEquivalent: ""
            )
            activate.target = target
            menu.addItem(activate)
        }
        let refresh = NSMenuItem(
            title: "common.refresh".localized,
            action: refreshAction,
            keyEquivalent: ""
        )
        refresh.target = target
        menu.addItem(refresh)
        menu.addItem(.separator())

        let account = NSMenuItem(
            title: String(
                format: "menu.provider.account".localized,
                presentation.appearance.displayName
            ),
            action: accountSettingsAction,
            keyEquivalent: ""
        )
        account.target = target
        menu.addItem(account)
        let appearance = NSMenuItem(
            title: "menu.provider.appearance".localized,
            action: appearanceAction,
            keyEquivalent: ""
        )
        appearance.target = target
        menu.addItem(appearance)
        let profiles = NSMenuItem(
            title: "menu.provider.manage_profiles".localized,
            action: manageProfilesAction,
            keyEquivalent: ""
        )
        profiles.target = target
        menu.addItem(profiles)
        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: "common.quit".localized,
            action: quitAction,
            keyEquivalent: "q"
        )
        quit.keyEquivalentModifierMask = .command
        quit.target = target
        menu.addItem(quit)
        return menu
    }

    nonisolated static func usesLegacyContextMenu(
        for providerID: ProviderID
    ) -> Bool {
        providerID == .claude
    }

    private func showContextMenu(for button: NSStatusBarButton?) {
        guard let button, let window = button.window else { return }
        let identity =
            ProviderStatusItemReconciliation.resolvedIdentity(
                captured:
                    statusBarUIManager?.statusIdentity(for: button),
                fallbackProfile: profileManager.activeProfile
            )
        guard let identity,
              let profile = currentProfile(for: identity) else {
            return
        }
        contextMenuTarget = identity
        let presentation =
            ProviderMenuPresentationBuilder.presentation(
                profile: profile,
                snapshot: profileUsagePresentations[profile.id],
                now: Date(),
                isActive: profileManager.isActive(profile)
            )
        let menu: NSMenu
        if Self.usesLegacyContextMenu(for: profile.providerID) {
            menu = Self.makeContextMenu(
                target: self,
                refreshAction: #selector(contextMenuRefresh),
                settingsAction: #selector(contextMenuLegacySettings),
                quitAction: #selector(contextMenuQuit)
            )
        } else {
            menu = Self.makeProviderContextMenu(
                presentation: presentation,
                target: self,
                activateAction: #selector(contextMenuActivate),
                refreshAction: #selector(contextMenuRefresh),
                accountSettingsAction:
                    #selector(contextMenuProviderSettings),
                appearanceAction: #selector(contextMenuAppearance),
                manageProfilesAction:
                    #selector(contextMenuManageProfiles),
                quitAction: #selector(contextMenuQuit)
            )
        }
        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = window.convertToScreen(buttonRect)
        menu.popUp(positioning: nil, at: screenRect.origin, in: nil)
    }

    @objc private func contextMenuRefresh() {
        guard let target = contextMenuTarget else { return }
        capturedTargetRouter().route(.refresh, target: target)
    }

    @objc private func contextMenuActivate() {
        guard let target = contextMenuTarget else { return }
        capturedTargetRouter().route(.activate, target: target)
    }

    @objc private func contextMenuProviderSettings() {
        guard let target = contextMenuTarget else { return }
        capturedTargetRouter().route(
            .providerAccount,
            target: target
        )
    }

    @objc private func contextMenuLegacySettings() {
        guard let target = contextMenuTarget else { return }
        capturedTargetRouter().route(
            .legacySettings,
            target: target
        )
    }

    @objc private func contextMenuAppearance() {
        guard let target = contextMenuTarget else { return }
        capturedTargetRouter().route(
            .appearance,
            target: target
        )
    }

    @objc private func contextMenuManageProfiles() {
        guard let target = contextMenuTarget else { return }
        capturedTargetRouter().route(
            .manageProfiles,
            target: target
        )
    }

    @objc private func contextMenuQuit() {
        Self.performContextMenuQuit {
            NSApplication.shared.terminate(nil)
        }
    }

    nonisolated static func performContextMenuQuit(
        terminate: () -> Void
    ) {
        terminate()
    }

    private func currentProfile(
        for target: ProviderStatusItemIdentity
    ) -> Profile? {
        capturedTargetRouter().currentProfile(for: target)
    }

    private func capturedTargetRouter(
        openPopover:
            ProviderCapturedTargetActionRouter.TargetSink? = nil,
        detachPopover:
            ProviderCapturedTargetActionRouter.TargetSink? = nil
    ) -> ProviderCapturedTargetActionRouter {
        ProviderCapturedTargetActionRouter(
            profiles: { [weak self] in
                guard let self else { return [] }
                return Self.capturedActionProfiles(
                    displayMode: self.profileManager.displayMode,
                    activeProfile:
                        self.profileManager.activeProfile,
                    profiles: self.profileManager.profiles
                )
            },
            sinks: .init(
                openPopover: openPopover ?? { _, _ in },
                detachPopover: detachPopover ?? { _, _ in },
                refresh: { [weak self] _, profile in
                    guard let self else { return }
                    self.lastRefreshTriggerTime = Date()
                    ProviderManualRefreshDispatcher {
                        [weak self] profiles, trigger in
                        self?.refreshRuntime.refresh(
                            profiles: profiles,
                            trigger: trigger
                        )
                    }.dispatch(profile: profile)
                },
                activate: { [weak self] target, _ in
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.capturedTargetRouter()
                                .currentProfile(for: target) != nil else {
                            return
                        }
                        await self.profileManager.activateProfile(
                            target.profileID
                        )
                    }
                },
                settings: {
                    [weak self] destination, _, _ in
                    self?.navigateToSettings(destination)
                },
                quit: { _, _ in
                    NSApp.terminate(nil)
                }
            )
        )
    }

    static func capturedActionProfiles(
        displayMode: ProfileDisplayMode,
        activeProfile: Profile?,
        profiles: [Profile]
    ) -> [Profile] {
        switch displayMode {
        case .single:
            guard let activeProfile,
                  !activeProfile.deletionInProgress else {
                return []
            }
            return [activeProfile]
        case .multi:
            let selectedProfiles = profiles.filter {
                $0.isSelectedForDisplay && !$0.deletionInProgress
            }
            if selectedProfiles.isEmpty,
               let activeProfile,
               !activeProfile.deletionInProgress {
                return [activeProfile]
            }
            return selectedProfiles
        }
    }

    private func navigateToSettings(
        _ destination: SettingsNavigationDestination
    ) {
        showSettings(destination: destination)
    }

    private func closePopover() {
        popover?.performClose(nil)
        stopMonitoringForOutsideClicks()
        lastPopoverCloseButton = currentPopoverButton
        currentPopoverButton = nil
        currentPopoverTarget = nil
        lastPopoverCloseDate = Date()
    }

    private func startMonitoringForOutsideClicks() {
        // Only monitor when popover is shown (not detached)
        // Stop monitoring if popover gets detached
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self,
                  let popover = self.popover,
                  popover.isShown,
                  self.detachedWindow == nil else { return }
            self.closePopover()
        }
    }

    private func stopMonitoringForOutsideClicks() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private func closePopoverOrWindow() {
        if let window = detachedWindow {
            window.close()
            detachedWindow = nil
        } else {
            popover?.performClose(nil)
        }
    }

    // MARK: - Status Bar Icon Updates

    /// Updates all enabled status bar icons
    private func updateAllStatusBarIcons() {
        let now = Date()
        if profileManager.displayMode == .multi {
            let visible = profileManager.profiles.filter(
                \.isSelectedForDisplay
            )
            let presentations =
                ProviderMenuPresentationBuilder.presentations(
                    profiles: visible,
                    snapshots: profileUsagePresentations,
                    now: now,
                    isActive: profileManager.isActive
                )
            let config = profileManager.multiProfileConfig
            statusBarUIManager?.updateProviderMultiProfileButtons(
                presentations: presentations,
                profiles: profileManager.profiles,
                config: config,
                activeClaudeProfileID: profileManager.activeClaudeProfileID,
                isActive: profileManager.isActive
            )
            scheduleFreshnessDeadline(for: presentations, now: now)
        } else {
            guard let profile = profileManager.activeProfile else {
                freshnessDeadlineTimer?.invalidate()
                freshnessDeadlineTimer = nil
                return
            }
            let presentation =
                ProviderMenuPresentationBuilder.presentation(
                    profile: profile,
                    snapshot: profileUsagePresentations[profile.id],
                    now: now,
                    isActive: true
                )
            if profile.providerID == .claude {
                statusBarUIManager?.updateAllButtons(
                    usage: usage,
                    apiUsage: apiUsage
                )
                statusBarUIManager?.bindLegacySingleProfile(profile)
            } else {
                statusBarUIManager?.updateProviderSingle(
                    presentation: presentation,
                    target: self,
                    action: #selector(togglePopover),
                    config: effectiveIconConfiguration(for: profile)
                )
            }
            scheduleFreshnessDeadline(
                for: [presentation],
                now: now
            )
        }
    }

    private func scheduleFreshnessDeadline(
        for presentations: [ProviderMenuPresentation],
        now: Date
    ) {
        freshnessDeadlineTimer?.invalidate()
        freshnessDeadlineTimer = nil
        guard let deadline =
                ProviderMenuPresentationBuilder.nextFreshnessDeadline(
                    presentations: presentations
                ) else {
            return
        }
        let interval = max(0.01, deadline.timeIntervalSince(now))
        freshnessDeadlineTimer = Timer.scheduledTimer(
            withTimeInterval: interval,
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateAllStatusBarIcons()
            }
        }
        freshnessDeadlineTimer?.tolerance = min(1, interval * 0.05)
    }

    /// Updates a specific metric's status bar icon
    private func updateStatusBarIcon(for metricType: MenuBarMetricType) {
        statusBarUIManager?.updateButton(
            for: metricType,
            usage: usage,
            apiUsage: apiUsage
        )
    }

    // Legacy method kept for backwards compatibility (now uses new system)
    private func updateStatusButton(_ button: NSStatusBarButton, usage: ClaudeUsage) {
        // This method is deprecated but kept for any remaining references
        // The new system handles updates through updateAllStatusBarIcons()
        updateAllStatusBarIcons()
    }

    // MARK: - Icon Style: Battery (Classic)

    private func startAutoRefresh() {
        let baseInterval = profileManager.activeProfile?.refreshInterval ?? 30.0
        scheduleAutoRefreshTimer(baseInterval: baseInterval)
    }

    /// Builds and installs the auto-refresh timer for `baseInterval`,
    /// honoring the current display-sleep/Low-Power-Mode state. Shared by
    /// `startAutoRefresh()` and `restartAutoRefreshWithInterval(_:)` so both
    /// paths apply the same adaptation instead of drifting apart.
    private func scheduleAutoRefreshTimer(baseInterval: TimeInterval) {
        guard let timing = RefreshTimingPolicy.autoRefreshTiming(
            baseInterval: baseInterval,
            isDisplayAsleep: isDisplayAsleep,
            isLowPowerModeEnabled: isLowPowerModeEnabled
        ) else {
            LoggingService.shared.log(
                "MenuBarManager: Withholding auto-refresh timer while display is asleep"
            )
            return
        }
        refreshTimer = Timer.scheduledTimer(
            withTimeInterval: timing.interval,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleAutomaticTimerFire()
            }
        }
        refreshTimer?.tolerance = timing.tolerance
        LoggingService.shared.log(
            "Started auto-refresh with interval: \(timing.interval)s (base \(baseInterval)s)"
        )
    }

    private func handleAutomaticTimerFire(at date: Date = Date()) {
        let fire = RefreshTimingPolicy.timerFired(at: date)
        lastAutoRefreshTime = fire.occurredAt
        refreshUsage(trigger: fire.trigger)
    }

    private func setupWakeObserver() {
        // Mirrors `setupHeadlessModeObserver()`'s re-entrancy guard: `setup()`
        // can run again (e.g. the headless retry path in
        // `handleScreenChange()`), and re-registering here would leak a
        // duplicate observer that fires its handler once per surviving copy —
        // meaning one extra wake refresh per leaked copy, forever.
        guard wakeObserver == nil else { return }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }

                // A system wake implies the display is coming back too.
                // Force `isDisplayAsleep` false and restart the timer here
                // — independently of `setupScreenSleepObserver()`'s own
                // wake handler — as a recovery path in case
                // `screensDidWakeNotification` is ever missed. Without
                // this, a missed display-wake notification would leave
                // auto-refresh permanently paused.
                self.isDisplayAsleep =
                    RefreshTimingPolicy.isDisplayAsleepAfterSystemWake()
                self.restartAutoRefresh()

                let timeSinceLastRefresh =
                    Date().timeIntervalSince(
                        self.lastAutoRefreshTime
                    )
                guard RefreshTimingPolicy.shouldRefreshAfterWake(
                    elapsedSinceLastAutomaticRefresh:
                        timeSinceLastRefresh
                ) else {
                    LoggingService.shared.log(
                        "MenuBarManager: Skipping wake refresh (debounce)"
                    )
                    return
                }
                LoggingService.shared.log(
                    "MenuBarManager: Wake from sleep detected, refreshing after delay"
                )
                DispatchQueue.main.asyncAfter(
                    deadline: .now()
                        + RefreshTimingPolicy.wakeDelay
                ) { [weak self] in
                    guard let self else { return }
                    // Re-check right before firing: `screensDidWakeNotification`
                    // fetches immediately (no delay), so if it lands first it
                    // will have stamped `lastAutoRefreshTime` after this block
                    // was already scheduled. See
                    // `shouldFireDeferredWakeRefresh`'s doc comment.
                    guard RefreshTimingPolicy.shouldFireDeferredWakeRefresh(
                        lastAutoRefreshTime: self.lastAutoRefreshTime,
                        at: Date(),
                        isDisplayAsleep: self.isDisplayAsleep
                    ) else {
                        LoggingService.shared.log(
                            "MenuBarManager: Skipping deferred wake refresh"
                                + " (already refreshed, or display asleep again)"
                        )
                        return
                    }
                    self.lastAutoRefreshTime = Date()
                    self.refreshUsage(trigger: .wake)
                }
            }
        }
    }

    /// Pauses auto-refresh while the display is asleep and resumes it (with
    /// an immediate catch-up fetch) on wake. Mirrors `setupWakeObserver()`'s
    /// structure and teardown discipline, but the display going dark — not
    /// the whole system sleeping — doesn't touch networking, so there's no
    /// need for `wakeDelay`'s reconnect grace period: the catch-up fetch
    /// fires right away rather than after a delay.
    private func setupScreenSleepObserver() {
        // Same re-entrancy guard as `setupHeadlessModeObserver()`. Both the
        // sleep and wake observers below are registered together and removed
        // together in `cleanupResources()`, so testing one is sufficient. A
        // leaked duplicate here would pause and resume auto-refresh once per
        // surviving copy, and each leaked wake copy would fire its own
        // catch-up fetch.
        guard screenSleepObserver == nil else { return }

        screenSleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isDisplayAsleep = true
                self.refreshTimer?.invalidate()
                self.refreshTimer = nil
                LoggingService.shared.log(
                    "MenuBarManager: Display slept, pausing auto-refresh"
                )
            }
        }
        screenWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isDisplayAsleep = false
                LoggingService.shared.log(
                    "MenuBarManager: Display woke, resuming auto-refresh"
                )
                self.restartAutoRefresh()

                // This debounce isn't just a defensive nicety: a *system*
                // wake fires both `didWakeNotification` (handled in
                // `setupWakeObserver()`) and this `screensDidWakeNotification`
                // together. Without it, every system wake would fan out two
                // refreshes instead of one — exactly the waste this whole
                // change exists to remove. Do not delete it.
                let timeSinceLastRefresh = Date().timeIntervalSince(
                    self.lastAutoRefreshTime
                )
                guard RefreshTimingPolicy.shouldRefreshAfterWake(
                    elapsedSinceLastAutomaticRefresh: timeSinceLastRefresh
                ) else {
                    LoggingService.shared.log(
                        "MenuBarManager: Skipping display-wake catch-up refresh (debounce)"
                    )
                    return
                }
                self.lastAutoRefreshTime = Date()
                self.refreshUsage(trigger: .wake)
            }
        }
    }

    /// Observes Low Power Mode transitions and reschedules the auto-refresh
    /// timer so it immediately picks up the doubled interval from
    /// `RefreshTimingPolicy.autoRefreshTiming`, restoring the normal
    /// cadence just as immediately when Low Power Mode turns back off.
    private func setupLowPowerModeObserver() {
        // Same re-entrancy guard as `setupHeadlessModeObserver()`: a leaked
        // duplicate would rebuild the refresh timer once per surviving copy on
        // every Low Power Mode transition.
        guard lowPowerModeObserver == nil else { return }

        lowPowerModeObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let isEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
                guard isEnabled != self.isLowPowerModeEnabled else { return }
                self.isLowPowerModeEnabled = isEnabled
                LoggingService.shared.log(
                    "MenuBarManager: Low Power Mode \(isEnabled ? "enabled" : "disabled"), adjusting auto-refresh cadence"
                )
                self.restartAutoRefresh()
            }
        }
    }

    private func restartAutoRefresh() {
        // Invalidate existing timer
        refreshTimer?.invalidate()
        refreshTimer = nil

        // Start new timer with updated interval
        startAutoRefresh()
    }

    private func observeRefreshIntervalChanges() {
        // Observe the same UserDefaults instance that DataStore uses
        refreshIntervalObserver = dataStore.userDefaults.observe(\.refreshInterval, options: [.new]) { [weak self] _, change in
            if let newValue = change.newValue, newValue > 0 {
                DispatchQueue.main.async {
                    self?.restartAutoRefresh()
                }
            }
        }
    }

    private func observeIconStyleChanges() {
        // Observe icon style changes from settings (now consolidated with menuBarIconConfigChanged)
        iconStyleObserver = NotificationCenter.default.addObserver(
            forName: .menuBarIconConfigChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.cachedImageKey = ""
                self.updateAllStatusBarIcons()
            }
        }
    }

    private func observeCredentialChanges() {
        // Observe credential changes (add, remove, or update)
        credentialsObserver = NotificationCenter.default.addObserver(
            forName: .credentialsChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            let changedProfileID = Self.credentialChangeProfileID(
                from: notification
            )

            // The observer is explicitly delivered on the main queue. Keep
            // invalidation synchronous with the notification so an already
            // completed fetch cannot win a later actor scheduling race.
            let routing = MainActor.assumeIsolated {
                let routing = Self.credentialChangeRouting(
                    changedProfileID: changedProfileID,
                    activeProfileID: self.profileManager.activeClaudeProfile?.id,
                    selectedProfileIDs: Set(
                        self.profileManager.profiles.lazy
                            .filter(\.isSelectedForDisplay)
                            .map(\.id)
                    ),
                    isMultiProfileMode:
                        self.profileManager.displayMode == .multi
                )
                switch routing.invalidation {
                case .profile(let profileID):
                    self.refreshRuntime.invalidate(profileID: profileID)
                case .allCapturedProfiles:
                    self.refreshRuntime.invalidateAll(
                        profiles: self.profileManager.profiles
                    )
                }
                self.activateRefreshPresentation()
                return routing
            }

            guard routing.shouldRefreshVisibleProfiles else {
                MainActor.assumeIsolated {
                    LoggingService.shared.logInfo(
                        "Credentials changed for an inactive profile - captured work invalidated without refreshing visible profiles"
                    )
                }
                return
            }

            Task { @MainActor in
                let selectedProfileIDs = Set(
                    self.profileManager.profiles.lazy
                        .filter(\.isSelectedForDisplay)
                        .map(\.id)
                )
                guard Self.shouldExecuteCredentialRefresh(
                    routing,
                    activeProfileID: self.profileManager.activeClaudeProfile?.id,
                    selectedProfileIDs: selectedProfileIDs,
                    isMultiProfileMode:
                        self.profileManager.displayMode == .multi
                ) else {
                    LoggingService.shared.logInfo(
                        "Credential refresh became stale before execution - skipping visible profile work"
                    )
                    return
                }

            if self.profileManager.displayMode == .multi {
                    LoggingService.shared.logInfo(
                        "Credentials changed for a visible profile - refreshing selected profiles"
                    )
                    self.updateMultiProfileDisplay()
                    self.lastRefreshTriggerTime = Date()
                    self.refreshUsage(trigger: .credentialsChanged)
                    return
                }

                // Check if active profile has usage credentials
                guard let profile = self.profileManager.activeProfile,
                      self.canAttemptUsageRefresh(profile) else {
                    LoggingService.shared.logInfo("Credentials changed but no usage credentials - showing default logo")

                    // Reconfigure menu bar to show default logo
                    let config = self.profileManager.activeProfile.map {
                        self.effectiveIconConfiguration(for: $0)
                    } ?? .default
                    self.updateMenuBarDisplay(with: config)
                    return
                }

                LoggingService.shared.logInfo("Credentials changed - triggering immediate refresh")

                // Reconfigure menu bar to show metrics (in case we were showing default logo)
                let config = self.effectiveIconConfiguration(for: profile)
                self.updateMenuBarDisplay(with: config)

                // Mark this as user-triggered
                self.lastRefreshTriggerTime = Date()

                self.refreshUsage(trigger: .credentialsChanged)
            }
        }
    }

    private func observeProviderLifecycleChanges() {
        providerConfigurationObserver =
            NotificationCenter.default.addObserver(
                forName: .providerConfigurationChanged,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let profileID = Self.credentialChangeProfileID(
                    from: notification
                )
                MainActor.assumeIsolated {
                    guard let self, let profileID else {
                        return
                    }
                    self.closeDetachedWindowIfInvalidated(
                        changedProfileID: profileID
                    )
                    ProviderMenuCatalogStore.shared.publish(
                        profiles: self.profileManager.profiles,
                        snapshots: self.profileUsagePresentations
                    )
                    self.refreshRuntime.invalidate(
                        profileID: profileID
                    )
                    self.refreshRuntime.presentationStore.purge(
                        profileID: profileID
                    )
                    self.activateRefreshPresentation()

                    let isVisible =
                        self.profileManager.displayMode == .multi
                            ? self.profileManager.profiles.contains {
                                $0.id == profileID
                                    && $0.isSelectedForDisplay
                            }
                            : self.profileManager.activeProfile?.id
                                == profileID
                    guard isVisible else { return }
                    self.refreshUsage(
                        trigger:
                            .providerConfigurationChanged
                    )
                }
            }

        profileDeletionStartedObserver =
            NotificationCenter.default.addObserver(
                forName: .profileDeletionStarted,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let profileID = Self.credentialChangeProfileID(
                    from: notification
                )
                MainActor.assumeIsolated {
                    guard let self, let profileID else {
                        return
                    }
                    self.closeDetachedWindowIfInvalidated(
                        changedProfileID: profileID
                    )
                    ProviderMenuCatalogStore.shared.invalidate(
                        profileID: profileID
                    )
                    self.refreshRuntime.beginDeletion(
                        profileID: profileID
                    )
                    self.cleanupProfile(profileID)
                    if self.profileManager.displayMode == .multi {
                        self.updateMultiProfileDisplay()
                    }
                }
            }

        profileDeletionCompletedObserver =
            NotificationCenter.default.addObserver(
                forName: .profileDeletionCompleted,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let profileID = Self.credentialChangeProfileID(
                    from: notification
                )
                MainActor.assumeIsolated {
                    guard let self, let profileID else {
                        return
                    }
                    ProviderMenuCatalogStore.shared.invalidate(
                        profileID: profileID
                    )
                    self.refreshRuntime.completeDeletion(
                        profileID: profileID
                    )
                    self.activateRefreshPresentation()
                    if self.profileManager.displayMode == .multi {
                        self.updateMultiProfileDisplay()
                    }
                }
            }
    }

    nonisolated struct CredentialChangeRouting: Equatable, Sendable {
        enum Invalidation: Equatable, Sendable {
            case profile(UUID)
            case allCapturedProfiles
        }

        enum RefreshScope: Equatable, Sendable {
            case none
            case activeProfile(UUID)
            case selectedProfile(UUID)
            case conservative
        }

        let invalidation: Invalidation
        let refreshScope: RefreshScope

        nonisolated var shouldRefreshVisibleProfiles: Bool {
            refreshScope != .none
        }
    }

    static func credentialChangeRouting(
        changedProfileID: UUID?,
        activeProfileID: UUID?,
        selectedProfileIDs: Set<UUID>,
        isMultiProfileMode: Bool
    ) -> CredentialChangeRouting {
        guard let changedProfileID else {
            return CredentialChangeRouting(
                invalidation: .allCapturedProfiles,
                refreshScope: .conservative
            )
        }

        let refreshScope: CredentialChangeRouting.RefreshScope
        if isMultiProfileMode {
            refreshScope =
                selectedProfileIDs.contains(changedProfileID)
                ? .selectedProfile(changedProfileID)
                : .none
        } else {
            refreshScope =
                activeProfileID == changedProfileID
                ? .activeProfile(changedProfileID)
                : .none
        }
        return CredentialChangeRouting(
            invalidation: .profile(changedProfileID),
            refreshScope: refreshScope
        )
    }

    static func shouldExecuteCredentialRefresh(
        _ routing: CredentialChangeRouting,
        activeProfileID: UUID?,
        selectedProfileIDs: Set<UUID>,
        isMultiProfileMode: Bool
    ) -> Bool {
        switch routing.refreshScope {
        case .none:
            return false
        case .activeProfile(let profileID):
            return !isMultiProfileMode && activeProfileID == profileID
        case .selectedProfile(let profileID):
            return isMultiProfileMode
                && selectedProfileIDs.contains(profileID)
        case .conservative:
            return true
        }
    }

    nonisolated static func credentialChangeProfileID(
        from notification: Notification
    ) -> UUID? {
        if let profileID = notification.object as? UUID {
            return profileID
        }
        for key in ["profileID", "profileId"] {
            if let profileID = notification.userInfo?[key] as? UUID {
                return profileID
            }
            if let value = notification.userInfo?[key] as? String,
               let profileID = UUID(uuidString: value) {
                return profileID
            }
        }
        return nil
    }

    private func observeIconConfigChanges() {
        // Observe configuration changes (metrics enabled/disabled, order changes, etc.)
        iconConfigObserver = NotificationCenter.default.addObserver(
            forName: .menuBarIconConfigChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }

            // Reload configuration from active profile (already on main queue)
            Task { @MainActor in
                // Handle differently based on display mode
                if self.profileManager.displayMode == .multi {
                    self.updateMultiProfileDisplay()
                } else {
                    // Single profile mode
                    let newConfig = self.profileManager.activeProfile.map {
                        self.effectiveIconConfiguration(for: $0)
                    } ?? .default
                    self.updateMenuBarDisplay(with: newConfig)
                }
            }
        }
    }

    private func observeMultiProfileConfigChanges() {
        multiProfileConfigObserver = NotificationCenter.default.addObserver(
            forName: .multiProfileConfigChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.closeDetachedWindowIfInvalidated(
                    selectedProfileIDs: Set(
                        self.profileManager.getSelectedProfiles()
                            .map(\.id)
                    )
                )
                self.activateRefreshPresentation()
                self.updateMultiProfileDisplay()
                self.refreshUsage(trigger: .displayChanged)
            }
        }
    }

    private func observeDisplayModeChanges() {
        // Observe display mode changes (single/multi profile)
        displayModeObserver = NotificationCenter.default.addObserver(
            forName: .displayModeChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }

            Task { @MainActor in
                self.handleDisplayModeChange()
            }
        }
    }

    private func handleDisplayModeChange() {
        let displayMode = profileManager.displayMode

        LoggingService.shared.log("MenuBarManager: Display mode changed to \(displayMode.rawValue)")
        closeDetachedWindowIfInvalidated(
            displayModeChanged: true
        )
        activateRefreshPresentation()

        if displayMode == .multi {
            // Switch to multi-profile mode
            setupMultiProfileMode()
        } else {
            // Switch back to single profile mode
            setupSingleProfileMode()
            refreshUsage(trigger: .displayChanged)
        }
    }

    // MARK: - Headless Mode (Remote Desktop Support)

    private func setupHeadlessModeObserver() {
        // `handleScreenChange()` re-invokes `setup()` (and therefore this
        // function) on its headless/Remote-Desktop reconnect retry path.
        // Both observers below are registered together here and are never
        // removed outside of `cleanupResources()`, so if one is already
        // present, re-registering would leak a duplicate that fires its
        // handler once per surviving copy on every future event.
        guard screenObserver == nil else { return }

        // Always observe screen changes to support headless Mac setups (Remote Desktop)
        LoggingService.shared.log("MenuBarManager: Setting up screen change observer for headless support")

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleScreenChange()
            }
        }

        // Automatic-mode overflow depends on which app is frontmost (its
        // menu bar boundary is one of the two measured numbers), so a
        // change of frontmost app is exactly as significant to the layout
        // as a screen reconfiguration. This also fires when the user
        // returns from System Settings after granting Accessibility
        // access, which is what lets automatic mode start measuring
        // immediately rather than waiting for some unrelated event.
        frontmostAppObserver = NSWorkspace.shared.notificationCenter
            .addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleFrontmostAppChange()
                }
            }
    }

    private func handleFrontmostAppChange() {
        guard profileManager.displayMode == .multi else { return }
        scheduleOverflowRecompute()
    }

    /// Observes any application launching or quitting, so `.automatic`
    /// overflow reacts to a menu bar manager (Ice, Thaw, Bartender, ...)
    /// appearing or disappearing while this app keeps running, rather than
    /// waiting for an unrelated replan trigger (frontmost-app change,
    /// screen change, ...) to happen to fire first. Without this, launching
    /// Thaw left profiles collapsed and quitting it left them uncollapsed
    /// until something else nudged a recompute — while the Settings notice
    /// (`DetectedMenuBarManagerHint`) already refreshes on
    /// `didBecomeActiveNotification`, so the UI could say "Thaw is managing
    /// your menu bar" while the profiles on screen were still collapsed.
    ///
    /// `NSWorkspace`'s launch/terminate notifications fire for every
    /// application on the system, so `handleMenuBarManagerActivityChange()`
    /// filters that down to genuine transitions via
    /// `menuBarManagerTracker` before ever considering a replan.
    ///
    /// This cannot loop back into itself: recomputing the overflow plan
    /// neither launches nor quits an application, so it can never
    /// re-trigger the very notification that led to it — unlike a prior bug
    /// in this file where a recompute trigger was wired to the *paint* path
    /// (`updateMultiProfileDisplay()` -> `updateAllStatusBarIcons()` ->
    /// `scheduleFreshnessDeadline`, which re-arms and calls back into
    /// `updateAllStatusBarIcons()`), which had no data-driven stop. This
    /// trigger is driven by real external process launches/quits the app
    /// itself never causes, so there is no such cycle to close.
    ///
    /// Each notification also carries the launched/quit app's own
    /// `NSRunningApplication` under `NSWorkspace.applicationUserInfoKey`.
    /// That bundle identifier is threaded down to
    /// `handleMenuBarManagerActivityChange(launched:terminated:)`, which
    /// reconciles it against the resampled process list — see
    /// `MenuBarManagerActivityReconciler` for why a resample alone isn't
    /// enough.
    private func setupMenuBarManagerObserver() {
        // Mirrors `setupHeadlessModeObserver()`'s re-entrancy guard: `setup()`
        // can run again (e.g. the headless retry path in
        // `handleScreenChange()`), and re-registering here would leak a
        // duplicate observer that fires its handler once per surviving copy.
        guard menuBarManagerLaunchObserver == nil else { return }

        // Seed the tracker with the actual current process list so the
        // first real launch/quit notification is compared against reality,
        // not an empty default — a manager already running at setup time is
        // already accounted for by the initial overflow plan, so it must
        // not read as a spurious "transition" the first time this fires.
        menuBarManagerTracker.update(
            runningBundleIdentifiers:
                NSWorkspaceRunningApplications().runningBundleIdentifiers
        )

        menuBarManagerLaunchObserver = NSWorkspace.shared.notificationCenter
            .addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    let launched = (notification.userInfo?[
                        NSWorkspace.applicationUserInfoKey
                    ] as? NSRunningApplication)?.bundleIdentifier
                    self?.handleMenuBarManagerActivityChange(
                        launched: launched,
                        terminated: nil
                    )
                }
            }
        menuBarManagerTerminateObserver = NSWorkspace.shared
            .notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    let terminated = (notification.userInfo?[
                        NSWorkspace.applicationUserInfoKey
                    ] as? NSRunningApplication)?.bundleIdentifier
                    self?.handleMenuBarManagerActivityChange(
                        launched: nil,
                        terminated: terminated
                    )
                }
            }
    }

    /// - Parameters:
    ///   - launched: The bundle identifier of the app that just launched,
    ///     from the triggering `didLaunchApplicationNotification`'s
    ///     payload, or `nil` when this call originates from a termination.
    ///   - terminated: The mirror of `launched`, from a
    ///     `didTerminateApplicationNotification`.
    ///
    /// Reconciles those against a fresh process-list sample via
    /// `MenuBarManagerActivityReconciler` before handing the result to
    /// `menuBarManagerTracker` — a plain resample can lag the notification
    /// that triggered it (the just-launched app not yet listed, or the
    /// just-quit app not yet removed), which would otherwise leave menu bar
    /// profiles stuck in the wrong state until an unrelated event happened
    /// to trigger a later recompute.
    private func handleMenuBarManagerActivityChange(
        launched: String?,
        terminated: String?
    ) {
        let reconciledBundleIdentifiers = MenuBarManagerActivityReconciler
            .reconciled(
                sample: NSWorkspaceRunningApplications()
                    .runningBundleIdentifiers,
                launched: launched,
                terminated: terminated
            )
        let changed = menuBarManagerTracker.update(
            runningBundleIdentifiers: reconciledBundleIdentifiers
        )
        guard changed else { return }
        // `.never` and `.afterCount` never consult the detected manager
        // (see `overflowPlan`'s `.automatic`-only guard), so a replan on
        // their behalf would just repeat the same manager-independent plan
        // for no reason — skip it rather than do that pointless work.
        guard profileManager.displayMode == .multi,
              case .automatic = DataStore.shared.loadMenuBarOverflowMode()
        else { return }
        scheduleOverflowRecompute()
    }

    private func handleScreenChange() {
        // Only proceed if we have screens now
        guard !NSScreen.screens.isEmpty else { return }

        // Check if status bar needs retry (button is nil means it failed on headless startup)
        guard let uiManager = statusBarUIManager else { return }

        if !uiManager.hasValidStatusBar {
            LoggingService.shared.log("MenuBarManager: Headless mode - display connected, retrying status bar setup (screens: \(NSScreen.screens.count))")
            setup()
            return
        }

        // A display reconfiguration (monitor added/removed/resized) can
        // change how much menu bar space is actually free, which only
        // matters to automatic-mode overflow. Debounced: a single physical
        // reconfiguration can fire this notification several times in
        // quick succession, and recomputing on every one of them would
        // thrash status items in and out.
        guard profileManager.displayMode == .multi else { return }
        scheduleOverflowRecompute()
    }

    /// Debounces automatic-mode overflow recomputation triggered by screen
    /// configuration or frontmost-application changes (see
    /// `handleScreenChange()` / `handleFrontmostAppChange()`).
    private func scheduleOverflowRecompute() {
        overflowRecomputeDebounceTimer?.invalidate()
        overflowRecomputeDebounceTimer = Timer.scheduledTimer(
            withTimeInterval: 0.2,
            repeats: false
        ) { [weak self] _ in
            self?.updateMultiProfileDisplay()
        }
    }

    /// Returns whether the status bar has at least one valid button
    func hasValidStatusBar() -> Bool {
        return statusBarUIManager?.hasValidStatusBar ?? false
    }

    private func setupMultiProfileMode(
        refreshTrigger: UsageRefreshTrigger? = .displayChanged
    ) {
        let selectedProfiles = profileManager.getSelectedProfiles()
        let config = profileManager.multiProfileConfig
        statusBarUIManager?.overflowMode =
            DataStore.shared.loadMenuBarOverflowMode()
        statusBarUIManager?.setupMultiProfile(
            profiles: selectedProfiles,
            target: self,
            action: #selector(togglePopover)
        )

        // Defer icon update to next run loop iteration to let NSStatusBar finalize layout
        DispatchQueue.main.async { [weak self] in
            self?.updateAllStatusBarIcons()
        }

        LoggingService.shared.log("MenuBarManager: Multi-profile mode enabled with \(selectedProfiles.count) profiles, style=\(config.iconStyle.rawValue)")

        if let refreshTrigger {
            refreshAllSelectedProfiles(trigger: refreshTrigger)
        }
    }

    /// Applies multi-profile selection and visual changes without recreating
    /// retained NSStatusItems, preserving their macOS and third-party ordering.
    private func updateMultiProfileDisplay() {
        statusBarUIManager?.overflowMode =
            DataStore.shared.loadMenuBarOverflowMode()
        statusBarUIManager?.updateMultiProfileConfiguration(
            profiles: profileManager.profiles,
            target: self,
            action: #selector(togglePopover)
        )

        DispatchQueue.main.async { [weak self] in
            self?.updateAllStatusBarIcons()
        }

        LoggingService.shared.log("MenuBarManager: Multi-profile display updated incrementally")
    }

    /// Refreshes usage data for all profiles selected for multi-profile display
    private func refreshAllSelectedProfiles(
        trigger: UsageRefreshTrigger
    ) {
        let now = Date()
        let isAutomaticTick = trigger == .timer
        let eligibleProfiles = profileManager.profiles.filter {
            $0.isSelectedForDisplay && canAttemptUsageRefresh($0)
        }

        // Drop records for profiles that no longer exist at all (deleted),
        // so this store doesn't grow forever. Pruned against every profile
        // still known to the manager, not just `eligibleProfiles` - a
        // deselected or momentarily credential-less profile must keep its
        // record.
        lastAutomaticRefreshByProfile = PerProfileAutoRefreshPolicy.pruned(
            lastAutomaticRefreshByProfile,
            keeping: Set(profileManager.profiles.map(\.id))
        )

        guard !eligibleProfiles.isEmpty else {
            LoggingService.shared.log("MenuBarManager: No selected profiles with usage credentials to refresh")
            updateAllStatusBarIcons()
            return
        }

        let selectedProfiles = eligibleProfiles.filter { profile in
            PerProfileAutoRefreshPolicy.shouldRefreshProfile(
                now: now,
                record: lastAutomaticRefreshByProfile[profile.id],
                interval: profile.refreshInterval,
                trigger: trigger
            )
        }

        guard !selectedProfiles.isEmpty else {
            LoggingService.shared.log("MenuBarManager: All \(eligibleProfiles.count) eligible profiles are within their own refresh interval; skipping this automatic tick")
            updateAllStatusBarIcons()
            return
        }

        if isAutomaticTick {
            for profile in selectedProfiles {
                lastAutomaticRefreshByProfile[profile.id] =
                    PerProfileAutoRefreshPolicy.Record(
                        lastRefresh: now,
                        interval: profile.refreshInterval
                    )
            }
        }

        LoggingService.shared.log("MenuBarManager: Refreshing \(selectedProfiles.count) selected profiles for multi-profile mode")
        refreshRuntime.refresh(
            profiles: selectedProfiles,
            trigger: trigger
        )
    }

    private func setupSingleProfileMode() {
        guard let profile = profileManager.activeProfile else { return }

        let canRefresh = canAttemptUsageRefresh(profile)
        let config = effectiveIconConfiguration(for: profile)

        if profile.providerID != .claude {
            updateProviderSingleDisplay(
                profile: profile,
                config: config
            )
            LoggingService.shared.log(
                "MenuBarManager: Provider single profile mode enabled"
            )
            return
        }

        // If no usage credentials, create empty config to show default logo
        let displayConfig: MenuBarIconConfiguration
        if !canRefresh {
            displayConfig = MenuBarIconConfiguration(
                colorMode: config.colorMode,
                singleColorHex: config.singleColorHex,
                showIconNames: config.showIconNames,
                metrics: config.metrics.map { metric in
                    var updatedMetric = metric
                    updatedMetric.isEnabled = false
                    return updatedMetric
                }
            )
        } else {
            displayConfig = config
        }

        statusBarUIManager?.setup(target: self, action: #selector(togglePopover), config: displayConfig)

        // Defer icon update to next run loop iteration to let NSStatusBar finalize layout
        DispatchQueue.main.async { [weak self] in
            self?.updateAllStatusBarIcons()
        }

        LoggingService.shared.log("MenuBarManager: Single profile mode enabled")
    }

    func refreshUsage(
        trigger: UsageRefreshTrigger = .manual
    ) {
        // In multi-profile mode, refresh ALL selected profiles
        if profileManager.displayMode == .multi {
            refreshAllSelectedProfiles(trigger: trigger)
            return
        }

        // Single profile mode - refresh only active profile
        guard let profile = profileManager.activeProfile else {
            LoggingService.shared.log("MenuBarManager.refreshUsage: No active profile")
            return
        }

        // Detailed logging
        LoggingService.shared.log("MenuBarManager.refreshUsage called:")
        LoggingService.shared.log("  - Profile: '\(profile.name)'")
        LoggingService.shared.log(
            "  - canAttemptUsageRefresh: \(canAttemptUsageRefresh(profile))"
        )

        // Check for usage credentials (Claude.ai or API Console, not just CLI)
        guard canAttemptUsageRefresh(profile) else {
            LoggingService.shared.log("MenuBarManager: Skipping refresh - no usage credentials")
            // Update icons to show default logo if needed
            updateAllStatusBarIcons()
            return
        }

        LoggingService.shared.log("MenuBarManager: Proceeding with refresh")
        refreshRuntime.refresh(
            profiles: [profile],
            trigger: trigger
        )
    }

    /// Shows a brief success notification for user-triggered refreshes
    private func showSuccessNotification() {
        NotificationManager.shared.sendSuccessNotification()
    }

    // MARK: - Auto-Switch Profile on Session Limit

    /// Checks if the current profile hit 100% and switches to the next available one
    private func checkAutoSwitchIfNeeded(
        usage: ClaudeUsage,
        currentProfile: Profile,
        expectedProfileID: UUID,
        expectedPresentationEpoch: UInt64
    ) {
        guard profileManager.activeClaudeProfile?.id == expectedProfileID,
              currentProfile.id == expectedProfileID,
              refreshRuntime.presentationContext.epoch
                == expectedPresentationEpoch else {
            return
        }

        // Guard: feature must be enabled
        guard SharedDataStore.shared.loadAutoSwitchProfileEnabled() else { return }
        guard providerUIDependencies.capabilities(
            for: currentProfile.providerID
        ).supports(.automaticProfileSwitch) else {
            return
        }

        // Guard: need more than 1 profile
        let profiles = profileManager.profiles
        guard profiles.count > 1 else { return }

        let profileId = currentProfile.id

        // If usage dropped below 100%, clear the flag (session reset)
        if usage.effectiveSessionPercentage < 100.0 {
            autoSwitchedProfileIds.remove(profileId)
            return
        }

        // Guard: usage must be >= 100%
        guard usage.effectiveSessionPercentage >= 100.0 else { return }

        // Guard: don't re-trigger for this profile
        guard !autoSwitchedProfileIds.contains(profileId) else { return }

        // Mark as triggered
        autoSwitchedProfileIds.insert(profileId)

        // Find the next available profile
        guard let nextProfile = findNextAvailableProfile(after: currentProfile) else {
            LoggingService.shared.log("AutoSwitch: All profiles at 100% or unavailable, staying on '\(currentProfile.name)'")
            return
        }

        LoggingService.shared.log("AutoSwitch: Switching from '\(currentProfile.name)' to '\(nextProfile.name)'")

        // Activate the next profile
        let fromName = currentProfile.name
        let toName = nextProfile.name
        Task { @MainActor [weak self] in
            guard let self,
                  self.profileManager.activeProfile?.id
                    == expectedProfileID,
                  self.refreshRuntime.presentationContext.epoch
                    == expectedPresentationEpoch else {
                self?.autoSwitchedProfileIds.remove(profileId)
                return
            }
            await profileManager.activateProfile(nextProfile.id)

            await MainActor.run {
                // Send notification
                NotificationManager.shared.sendAutoSwitchNotification(fromProfile: fromName, toProfile: toName)

                // Post notification for UI reactivity
                NotificationCenter.default.post(name: .autoSwitchProfileTriggered, object: nil)
            }
        }
    }

    /// Finds the next profile with available session capacity, wrapping around
    private func findNextAvailableProfile(after currentProfile: Profile) -> Profile? {
        let profiles = profileManager.profiles
        guard let currentIndex = profiles.firstIndex(where: { $0.id == currentProfile.id }) else { return nil }

        let count = profiles.count
        for offset in 1..<count {
            let index = (currentIndex + offset) % count
            let candidate = profiles[index]

            // Must support this automation and have compatible usage data.
            guard providerUIDependencies.capabilities(
                for: candidate.providerID
            ).supports(.automaticProfileSwitch),
                  candidate.providerID == .claude,
                  candidate.hasUsageCredentials else {
                continue
            }

            // If no saved usage data, treat as available
            guard let candidateUsage = candidate.claudeUsage else { return candidate }

            // Must be below 100%
            if candidateUsage.effectiveSessionPercentage < 100.0 {
                return candidate
            }
        }

        return nil
    }

    // MARK: - Reset Detection for History Recording

    /// Normalizes a date to minute precision for comparison (ignores seconds)
    private func normalizeToMinute(_ date: Date) -> Date {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return calendar.date(from: components) ?? date
    }

    /// Checks if a session reset occurred and records a snapshot if so
    private func checkAndRecordSessionReset(
        profileId: UUID,
        previousUsage: ClaudeUsage?,
        newUsage: ClaudeUsage
    ) {
        let lastKnown = lastKnownSessionResetTime[profileId]
        let newResetTime = normalizeToMinute(newUsage.sessionResetTime)

        // First time seeing this profile - just record the reset time
        if lastKnown == nil {
            lastKnownSessionResetTime[profileId] = newResetTime
            return
        }

        // Normalize the last known time for comparison
        let normalizedLastKnown = normalizeToMinute(lastKnown!)

        // Check if reset time changed (indicates a reset occurred)
        // Use != instead of > to handle clock changes and backward time jumps
        if newResetTime != normalizedLastKnown {
            // Reset detected! Record snapshot of the previous usage
            LoggingService.shared.log("History: Session reset detected for profile \(profileId.uuidString.prefix(8)). Old: \(normalizedLastKnown), New: \(newResetTime)")
            if let prevUsage = previousUsage {
                UsageHistoryService.shared.recordSessionReset(
                    for: profileId,
                    previousUsage: prevUsage,
                    resetTime: prevUsage.sessionResetTime
                )
            }

            // Mark that session reset was just recorded to prevent duplicate periodic snapshot
            var flags = resetJustRecorded[profileId] ?? (session: false, weekly: false)
            flags.session = true
            resetJustRecorded[profileId] = flags
        }

        // Update the last known reset time
        lastKnownSessionResetTime[profileId] = newResetTime
    }

    /// Checks if a weekly reset occurred and records a snapshot if so
    private func checkAndRecordWeeklyReset(
        profileId: UUID,
        previousUsage: ClaudeUsage?,
        newUsage: ClaudeUsage
    ) {
        let lastKnown = lastKnownWeeklyResetTime[profileId]
        let newResetTime = normalizeToMinute(newUsage.weeklyResetTime)

        // First time seeing this profile - just record the reset time
        if lastKnown == nil {
            lastKnownWeeklyResetTime[profileId] = newResetTime
            LoggingService.shared.log("History: Initial weekly reset time for profile \(profileId.uuidString.prefix(8)): \(newResetTime)")
            return
        }

        // Normalize the last known time for comparison
        let normalizedLastKnown = normalizeToMinute(lastKnown!)

        // Check if reset time changed (indicates a reset occurred)
        // Use != instead of > to handle clock changes and backward time jumps
        if newResetTime != normalizedLastKnown {
            // Reset detected! Record snapshot of the previous usage
            LoggingService.shared.log("History: Weekly reset detected for profile \(profileId.uuidString.prefix(8)). Old: \(normalizedLastKnown), New: \(newResetTime)")
            if let prevUsage = previousUsage {
                UsageHistoryService.shared.recordWeeklyReset(
                    for: profileId,
                    previousUsage: prevUsage,
                    resetTime: prevUsage.weeklyResetTime
                )
            }

            // Mark that weekly reset was just recorded to prevent duplicate periodic snapshot
            var flags = resetJustRecorded[profileId] ?? (session: false, weekly: false)
            flags.weekly = true
            resetJustRecorded[profileId] = flags
        }

        // Update the last known reset time
        lastKnownWeeklyResetTime[profileId] = newResetTime
    }

    /// Checks if a billing cycle reset occurred and records a snapshot if so
    private func checkAndRecordBillingCycleReset(
        profileId: UUID,
        previousUsage: APIUsage?,
        newUsage: APIUsage
    ) {
        let lastKnown = lastKnownAPIResetTime[profileId]
        let newResetTime = normalizeToMinute(newUsage.resetsAt)

        // First time seeing this profile - just record the reset time
        if lastKnown == nil {
            lastKnownAPIResetTime[profileId] = newResetTime
            LoggingService.shared.log("History: Initial API reset time for profile \(profileId.uuidString.prefix(8)): \(newResetTime)")
            return
        }

        // Normalize the last known time for comparison
        let normalizedLastKnown = normalizeToMinute(lastKnown!)

        // Check if reset time changed (indicates a reset occurred)
        // Use != instead of > to handle clock changes and backward time jumps
        if newResetTime != normalizedLastKnown {
            // Reset detected! Record snapshot of the previous usage
            LoggingService.shared.log("History: Billing cycle reset detected for profile \(profileId.uuidString.prefix(8)). Old: \(normalizedLastKnown), New: \(newResetTime)")
            if let prevUsage = previousUsage {
                UsageHistoryService.shared.recordBillingCycleReset(
                    for: profileId,
                    previousUsage: prevUsage,
                    resetTime: prevUsage.resetsAt
                )
            }
        }

        // Update the last known reset time
        lastKnownAPIResetTime[profileId] = newResetTime
    }

    @objc private func preferencesClicked() {
        showSettings(destination: .defaultView)
    }

    private func showSettings(
        destination: SettingsNavigationDestination
    ) {
        closePopoverOrWindow()

        if let settingsController {
            settingsController.navigate(to: destination)
            let existingWindow = settingsController.window
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        NSApp.setActivationPolicy(.regular)
        let controller = SettingsWindowBuilder.makeController(
            size: Constants.WindowSizes.settingsWindow,
            dependencies: providerUIDependencies,
            destination: destination
        )
        let window = controller.window
        window.title = "app.window.settings".localized
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self

        settingsController = controller
        settingsWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func switchToNextProfile() {
        let profiles = profileManager.profiles
        guard profiles.count > 1,
              let currentId = profileManager.activeProfile?.id,
              let currentIndex = profiles.firstIndex(where: { $0.id == currentId }) else {
            return
        }

        let nextIndex = (profiles.index(after: currentIndex)) % profiles.count
        let nextProfile = profiles[nextIndex]

        Task {
            await profileManager.activateProfile(nextProfile.id)
        }
    }

    @objc private func quitClicked() {
        NSApplication.shared.terminate(nil)
    }

    /// Shows the GitHub star prompt window
    func showGitHubStarPrompt() {
        // If window already exists, just bring it to front
        if let existingWindow = githubPromptWindow, existingWindow.isVisible {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Temporarily show dock icon for the prompt window
        NSApp.setActivationPolicy(.regular)

        // Create the GitHub star prompt view
        let promptView = GitHubStarPromptView(
            onStar: { [weak self] in
                self?.handleGitHubStarClick()
            },
            onMaybeLater: { [weak self] in
                self?.handleMaybeLaterClick()
            },
            onDontAskAgain: { [weak self] in
                self?.handleDontAskAgainClick()
            }
        )

        let hostingController = NSHostingController(rootView: promptView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = ""
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.setContentSize(NSSize(width: 300, height: 145))
        window.center()
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.level = .floating
        window.delegate = self

        // Store reference
        githubPromptWindow = window

        // Mark that we've shown the prompt
        dataStore.saveLastGitHubStarPromptDate(Date())

        // Show the window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func handleGitHubStarClick() {
        // Open GitHub repository
        if let url = URL(string: Constants.githubRepoURL) {
            NSWorkspace.shared.open(url)
        }

        // Mark as starred
        dataStore.saveHasStarredGitHub(true)

        // Close the prompt window
        githubPromptWindow?.close()
        githubPromptWindow = nil

        // Hide dock icon
        NSApp.setActivationPolicy(.accessory)
    }

    private func handleMaybeLaterClick() {
        // Just close the window - the prompt will show again after the reminder interval
        githubPromptWindow?.close()
        githubPromptWindow = nil

        // Hide dock icon
        NSApp.setActivationPolicy(.accessory)
    }

    private func handleDontAskAgainClick() {
        // Mark to never show again
        dataStore.saveNeverShowGitHubPrompt(true)

        // Close the prompt window
        githubPromptWindow?.close()
        githubPromptWindow = nil

        // Hide dock icon
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - Feedback Prompt

    /// Shows the feedback collection prompt window
    func showFeedbackPrompt() {
        if let existingWindow = feedbackWindow, existingWindow.isVisible {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        NSApp.setActivationPolicy(.regular)

        let promptView = FeedbackPromptView(
            onSubmit: { [weak self] _, _, _, _ in
                SharedDataStore.shared.saveHasSubmittedFeedback(true)
                // Close after a brief delay to show the thanks state
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    self?.closeFeedbackWindow()
                }
            },
            onRemindLater: { [weak self] in
                SharedDataStore.shared.saveLastFeedbackPromptDate(Date())
                self?.closeFeedbackWindow()
            },
            onDontAskAgain: { [weak self] in
                SharedDataStore.shared.saveNeverShowFeedbackPrompt(true)
                self?.closeFeedbackWindow()
            }
        )

        let hostingController = NSHostingController(rootView: promptView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = ""
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.setContentSize(NSSize(width: 380, height: 420))
        window.center()
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.level = .floating
        window.delegate = self

        feedbackWindow = window
        SharedDataStore.shared.saveLastFeedbackPromptDate(Date())

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closeFeedbackWindow() {
        feedbackWindow?.close()
        feedbackWindow = nil
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - NSPopoverDelegate
extension MenuBarManager: NSPopoverDelegate {
    func popoverShouldDetach(_ popover: NSPopover) -> Bool {
        ProviderPopoverDetachmentLifecycle.shouldDetach()
    }

    func popoverDidClose(_ notification: Notification) {
        lastPopoverCloseDate = Date()
        lastPopoverCloseButton = currentPopoverButton
    }

    func detachableWindow(for popover: NSPopover) -> NSWindow? {
        guard let target = popoverActionTarget() else { return nil }
        var createdWindow: NSPanel?
        capturedTargetRouter(
            detachPopover: { [weak self] _, _ in
                guard let self else { return }
                self.stopMonitoringForOutsideClicks()

                // A detached panel owns a fresh controller without popover
                // preferred-size constraints.
                let contentView = PopoverContentView(
                    manager: self,
                    profileManager: self.profileManager,
                    onRefresh: { [weak self] in
                        self?.refreshPopover(target: target)
                    },
                    onManageProfiles: { [weak self] in
                        self?.openPopoverManageProfiles(target: target)
                    },
                    onPreferences: { [weak self] in
                        self?.openPopoverSettings(target: target)
                    },
                    onCLIAccount: { [weak self] in
                        self?.openPopoverCLIAccount(target: target)
                    },
                    onClaudeAIAccount: { [weak self] in
                        self?.openPopoverClaudeAIAccount(target: target)
                    }
                )
                let hostingController = NSHostingController(
                    rootView: contentView
                )
                let window = Self.makeDetachedPopoverWindow(
                    contentViewController: hostingController,
                    delegate: self
                )
                self.detachedWindow = window
                createdWindow = window
            }
        ).route(.detachPopover, target: target)
        return createdWindow
    }

    static func makeDetachedPopoverWindow(
        contentViewController: NSViewController,
        delegate: NSWindowDelegate?
    ) -> NSPanel {
        ProviderPopoverDetachmentLifecycle.makeWindow(
            contentViewController: contentViewController,
            delegate: delegate
        )
    }
}

// MARK: - StatusBarUIManagerDelegate
extension MenuBarManager: StatusBarUIManagerDelegate {
    func statusBarAppearanceDidChange() {
        // Safe from infinite loops: StatusBarUIManager's observer deduplicates by
        // appearance name, and setButtonImage() only assigns button.image when the
        // rendered CGImage data actually changes — so even if setting button.image
        // triggers effectiveAppearance KVO, the cycle stops immediately.
        cachedIsDarkMode = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        cachedImageKey = ""
        updateAllStatusBarIcons()
    }
}

// MARK: - NSWindowDelegate
extension MenuBarManager: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            if window == settingsWindow {
                // Hide dock icon again when settings window closes
                NSApp.setActivationPolicy(.accessory)
                settingsController = nil
                settingsWindow = nil
            } else if ProviderPopoverDetachmentLifecycle
                .closedRetainedWindow(
                    window,
                    retainedWindow: detachedWindow
                ) {
                // Clear detached window reference when closed
                detachedWindow = nil
                currentPopoverTarget = nil
            } else if window == githubPromptWindow {
                // Hide dock icon again when GitHub prompt window closes
                NSApp.setActivationPolicy(.accessory)
                githubPromptWindow = nil
            }
        }
    }
}
