import Foundation
import UserNotifications
import AppKit
import UsageCore

struct UsageNotificationWindowKey:
    Codable,
    Hashable,
    Sendable
{
    let profileID: UUID
    let providerID: ProviderID
    let groupID: UsageLimitGroupID
    let windowID: UsageWindowID

    var persistencePrefix: String {
        [
            profileID.uuidString.lowercased(),
            providerID.rawValue,
            groupID.rawValue,
            windowID.rawValue
        ]
        .map { "\($0.utf8.count):\($0)" }
        .joined()
    }
}

struct UsageNotificationWindowState:
    Codable,
    Equatable,
    Sendable
{
    var cycleID: String
    var percentage: Double
    var highestDeliveredThreshold: Int?
    var pendingThreshold: Int?
    var pendingResetCycleID: String?
    var lastSeenAt: Date

    init(
        cycleID: String,
        percentage: Double,
        highestDeliveredThreshold: Int? = nil,
        pendingThreshold: Int? = nil,
        pendingResetCycleID: String? = nil,
        lastSeenAt: Date
    ) {
        self.cycleID = cycleID
        self.percentage = percentage
        self.highestDeliveredThreshold =
            highestDeliveredThreshold
        self.pendingThreshold = pendingThreshold
        self.pendingResetCycleID = pendingResetCycleID
        self.lastSeenAt = lastSeenAt
    }
}

enum UsageNotificationEventKind: String, Equatable, Sendable {
    case threshold
    case reset
}

struct UsageNotificationIdentity: Hashable, Sendable {
    let window: UsageNotificationWindowKey
    let cycleID: String
    let kind: UsageNotificationEventKind
    let threshold: Int?

    /// Injective, display-independent identity persisted across launches.
    var persistenceKey: String {
        window.persistencePrefix + [
            cycleID,
            kind.rawValue,
            threshold.map(String.init) ?? "-"
        ]
        .map { "\($0.utf8.count):\($0)" }
        .joined()
    }
}

struct UsageNotificationEvent: Equatable, Sendable {
    let identity: UsageNotificationIdentity
    let percentage: Double
    let threshold: Int?
    let resetTime: Date?
    let groupDisplayName: String?
    let windowDisplayName: String?
}

struct UsageNotificationEvaluation: Equatable, Sendable {
    let events: [UsageNotificationEvent]
    let states: [UsageNotificationWindowKey:
        UsageNotificationWindowState]
}

/// Pure threshold/reset policy used by NotificationManager and deterministic
/// tests. It consumes only normalized provider data and stable identities.
enum UsageNotificationPolicy {
    struct EligibleWindow {
        let groupID: UsageLimitGroupID
        let groupDisplayName: String?
        let window: UsageWindow
        let percentage: Double
    }

    /// Claude's established policy applies only to its effective subscription
    /// session. Provider-owned dynamic windows are otherwise all eligible.
    static func includes(
        providerID: ProviderID,
        groupID: UsageLimitGroupID,
        windowID: UsageWindowID
    ) -> Bool {
        providerID != .claude
            || (
                groupID.rawValue == "subscription"
                    && windowID.rawValue == "session"
            )
    }

    /// - Parameter globallyEnabled: The app-wide master switch
    ///   (`DataStore.loadNotificationsEnabled()`). Defaults to `true` so
    ///   existing pure-policy callers/tests that only care about
    ///   per-profile behavior are unaffected; `NotificationManager` always
    ///   passes the real value on the live path.
    static func isEligible(
        report: UsageReport,
        settings: NotificationSettings,
        now: Date,
        globallyEnabled: Bool = true
    ) -> Bool {
        globallyEnabled
            && settings.enabled
            && !report.isStale(at: now)
            && report.health.status != .unavailable
            && report.health.status != .unauthenticated
            && report.health.status != .unsupported
    }

    static func eligibleWindows(
        in report: UsageReport
    ) -> [EligibleWindow] {
        report.limitGroups.flatMap { group in
            group.windows.compactMap { window in
                guard includes(
                    providerID: report.providerID,
                    groupID: group.id,
                    windowID: window.id
                ),
                      let percentage = window.usedPercentage
                        ?? window.quantity?
                            .calculatedUsedPercentage,
                      percentage.isFinite else {
                    return nil
                }
                return EligibleWindow(
                    groupID: group.id,
                    groupDisplayName: group.displayName,
                    window: window,
                    percentage: percentage
                )
            }
        }
    }

    /// A window is considered to have genuinely reset only if its usage
    /// dropped materially, not merely because its cycle identity changed.
    ///
    /// Cycle identity is derived from a provider's `resetsAt`/`startedAt`
    /// timestamp (see `NormalizedUsageSnapshot.cycleID`), which is prone to
    /// sub-second jitter between polls and, for rolling windows, advances
    /// continuously by design. Either case manufactures a "new cycle" with
    /// no actual reset having occurred. Gating on the observed percentage
    /// falling to near zero, or dropping by a large amount, is what actually
    /// distinguishes "the provider reset this window" from "the identity
    /// wobbled" — a real reset drains a window; a jittering identity does
    /// not change how much of it is used.
    static let resetNearZeroPercentageThreshold: Double = 5
    static let resetMinimumUsageDropPercentagePoints: Double = 20

    private static func isMaterialUsageDrop(
        from previousPercentage: Double,
        to percentage: Double
    ) -> Bool {
        guard previousPercentage > 0 else { return false }
        if percentage <= resetNearZeroPercentageThreshold {
            // Near-zero only counts as a reset if usage actually fell INTO
            // it FROM above the threshold. A window already sitting at or
            // under the threshold (e.g. steady at 5%) would otherwise
            // satisfy `percentage <= threshold` on every cycle-identity
            // change — including harmless sub-second jitter or rolling-
            // window advances — with no usage having dropped at all,
            // flooding "session reset" notifications for a window that
            // never reset.
            return previousPercentage > resetNearZeroPercentageThreshold
        }
        return previousPercentage - percentage
            >= resetMinimumUsageDropPercentagePoints
    }

    static func baselineStates(
        report: UsageReport,
        profileID: UUID
    ) -> [UsageNotificationWindowKey:
        UsageNotificationWindowState] {
        var result: [UsageNotificationWindowKey:
            UsageNotificationWindowState] = [:]
        for eligible in eligibleWindows(in: report) {
            result[
                UsageNotificationWindowKey(
                    profileID: profileID,
                    providerID: report.providerID,
                    groupID: eligible.groupID,
                    windowID: eligible.window.id
                )
            ] = UsageNotificationWindowState(
                cycleID:
                    NormalizedUsageSnapshot.cycleID(
                        for: eligible.window
                    ),
                percentage: eligible.percentage,
                lastSeenAt: report.fetchedAt
            )
        }
        return result
    }

    static func evaluate(
        report: UsageReport,
        profileID: UUID,
        settings: NotificationSettings,
        now: Date,
        previousStates: [UsageNotificationWindowKey:
            UsageNotificationWindowState],
        globallyEnabled: Bool = true
    ) -> UsageNotificationEvaluation {
        guard isEligible(
            report: report,
            settings: settings,
            now: now,
            globallyEnabled: globallyEnabled
        ) else {
            return UsageNotificationEvaluation(
                events: [],
                states: previousStates
            )
        }

        var states = previousStates
        var events: [UsageNotificationEvent] = []
        let thresholds = settings.sortedThresholds.filter {
            threshold in
            (1...100).contains(threshold)
        }
        for eligible in eligibleWindows(in: report) {
            let window = eligible.window
            let percentage = eligible.percentage
            let key = UsageNotificationWindowKey(
                profileID: profileID,
                providerID: report.providerID,
                groupID: eligible.groupID,
                windowID: window.id
            )
            let cycleID =
                NormalizedUsageSnapshot.cycleID(for: window)
            let previous = previousStates[key]
            var state: UsageNotificationWindowState
            if let previous,
               previous.cycleID == cycleID {
                state = previous
                state.percentage = percentage
                state.lastSeenAt = now
            } else {
                let previousPercentage = previous?.percentage ?? 0
                state = UsageNotificationWindowState(
                    cycleID: cycleID,
                    percentage: percentage,
                    pendingResetCycleID:
                        isMaterialUsageDrop(
                            from: previousPercentage,
                            to: percentage
                        )
                        ? cycleID
                        : nil,
                    lastSeenAt: now
                )
            }

            if state.pendingResetCycleID == cycleID {
                let identity = UsageNotificationIdentity(
                    window: key,
                    cycleID: cycleID,
                    kind: .reset,
                    threshold: nil
                )
                events.append(
                    UsageNotificationEvent(
                        identity: identity,
                        percentage: percentage,
                        threshold: nil,
                        resetTime: window.resetsAt,
                        groupDisplayName:
                            eligible.groupDisplayName,
                        windowDisplayName:
                            window.displayName
                    )
                )
            }

            if let pendingThreshold =
                state.pendingThreshold,
               !thresholds.contains(pendingThreshold) {
                state.pendingThreshold = nil
            }

            if let reachedThreshold = thresholds
                .reversed()
                .first(where: {
                    percentage >= Double($0)
                }),
               reachedThreshold
                > (state.highestDeliveredThreshold ?? 0),
               reachedThreshold
                > (state.pendingThreshold ?? 0) {
                state.pendingThreshold = reachedThreshold
            }

            if let threshold = state.pendingThreshold,
               threshold
                > (state.highestDeliveredThreshold ?? 0) {
                let identity = UsageNotificationIdentity(
                    window: key,
                    cycleID: cycleID,
                    kind: .threshold,
                    threshold: threshold
                )
                events.append(
                    UsageNotificationEvent(
                        identity: identity,
                        percentage: max(
                            percentage,
                            Double(threshold)
                        ),
                        threshold: threshold,
                        resetTime: window.resetsAt,
                        groupDisplayName:
                            eligible.groupDisplayName,
                        windowDisplayName:
                            window.displayName
                    )
                )
            }

            states[key] = state
        }
        return UsageNotificationEvaluation(
            events: events,
            states: states
        )
    }
}

private struct PersistedUsageNotificationLedger: Codable {
    let schemaVersion: Int
    let records: [PersistedUsageNotificationRecord]
}

private struct PersistedUsageNotificationRecord: Codable {
    let window: UsageNotificationWindowKey
    let state: UsageNotificationWindowState
}

private enum NormalizedNotificationLedgerLoad {
    case absent
    case valid(
        [UsageNotificationWindowKey:
            UsageNotificationWindowState]
    )
    case invalidOrFuture
}

private struct NormalizedNotificationReservation {
    let token: UUID
    let window: UsageNotificationWindowKey
}

private enum NotificationStatePersistenceError:
    LocalizedError
{
    case normalizedLedgerWriteFailed
    case legacyStateWriteFailed

    var errorDescription: String? {
        switch self {
        case .normalizedLedgerWriteFailed,
             .legacyStateWriteFailed:
            return "Notification state could not be saved."
        }
    }
}

/// Manages user notifications for usage threshold alerts
class NotificationManager: NotificationServiceProtocol {
    typealias NotificationRequestAdder = (
        UNNotificationRequest,
        @escaping (Error?) -> Void
    ) -> Void

    static let shared = NotificationManager()

    private let stateLock = NSLock()
    private let defaults: UserDefaults
    private let notificationRequestAdder: NotificationRequestAdder
    private let missingWindowRetention: TimeInterval
    private let maximumMissingWindowsPerScope: Int
    private var normalizedLedgerIsUsable: Bool
    private static let normalizedLedgerKey =
        "normalizedUsageNotificationLedger.v1"
    private static let normalizedLedgerSchemaVersion = 1

    // Track previous session percentage per profile to detect resets
    private var previousSessionPercentages: [String: Double] = [:]
    private var normalizedWindowStates:
        [UsageNotificationWindowKey:
            UsageNotificationWindowState] = [:]
    private var normalizedInFlightReservations:
        [String: NormalizedNotificationReservation] = [:]

    // Legacy notification identities retain their established persistence.
    // Normalized provider notifications use the versioned per-window ledger.
    private var sentNotificationIdentities: Set<String>

    init(
        defaults: UserDefaults = .standard,
        missingWindowRetention: TimeInterval = 15 * 60,
        maximumMissingWindowsPerScope: Int = 64,
        notificationRequestAdder:
            @escaping NotificationRequestAdder = {
                request,
                completion in
                UNUserNotificationCenter.current().add(
                    request,
                    withCompletionHandler: completion
                )
            }
    ) {
        self.defaults = defaults
        self.missingWindowRetention =
            max(0, missingWindowRetention)
        self.maximumMissingWindowsPerScope =
            max(0, maximumMissingWindowsPerScope)
        self.notificationRequestAdder = notificationRequestAdder
        sentNotificationIdentities = Set(
            defaults.array(forKey: "sentNotifications")
                as? [String] ?? []
        )
        switch Self.loadNormalizedLedger(from: defaults) {
        case .absent:
            normalizedLedgerIsUsable = true
        case .valid(let states):
            normalizedLedgerIsUsable = true
            normalizedWindowStates = states
        case .invalidOrFuture:
            normalizedLedgerIsUsable = false
        }
    }

    private static func loadNormalizedLedger(
        from defaults: UserDefaults
    ) -> NormalizedNotificationLedgerLoad {
        guard let data = defaults.data(
            forKey: normalizedLedgerKey
        ) else {
            return .absent
        }
        guard let ledger = try? JSONDecoder().decode(
            PersistedUsageNotificationLedger.self,
            from: data
        ),
              ledger.schemaVersion
                == normalizedLedgerSchemaVersion else {
            return .invalidOrFuture
        }
        return .valid(
            Dictionary(
                ledger.records.map {
                    ($0.window, $0.state)
                },
                uniquingKeysWith: { _, latest in latest }
            )
        )
    }

    @discardableResult
    private func persistNormalizedLedgerLocked() -> Bool {
        guard normalizedLedgerIsUsable else {
            return false
        }
        let records = normalizedWindowStates
            .map {
                PersistedUsageNotificationRecord(
                    window: $0.key,
                    state: $0.value
                )
            }
            .sorted {
                $0.window.persistencePrefix
                    < $1.window.persistencePrefix
            }
        let ledger = PersistedUsageNotificationLedger(
            schemaVersion:
                Self.normalizedLedgerSchemaVersion,
            records: records
        )
        guard let data = try? JSONEncoder().encode(ledger) else {
            return false
        }
        defaults.set(data, forKey: Self.normalizedLedgerKey)
        return defaults.data(forKey: Self.normalizedLedgerKey)
            == data
    }

    @discardableResult
    private func persistSentNotificationsLocked() -> Bool {
        defaults.set(
            Array(sentNotificationIdentities),
            forKey: "sentNotifications"
        )
        return Set(
            defaults.array(forKey: "sentNotifications")
                as? [String] ?? []
        ) == sentNotificationIdentities
    }

    @discardableResult
    private func reserveNotification(_ identifier: String) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard sentNotificationIdentities.insert(identifier).inserted else {
            return false
        }
        persistSentNotificationsLocked()
        return true
    }

    private func releaseNotification(_ identifier: String) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard sentNotificationIdentities.remove(identifier) != nil else {
            return
        }
        persistSentNotificationsLocked()
    }

    /// The app-wide notification master switch.
    ///
    /// Delegates to `DataStore.masterSwitchEnabled(in:)` so the
    /// missing-key-means-enabled rule has exactly one definition; a second
    /// copy here is precisely the "two flags that silently disagree" failure
    /// this switch exists to end.
    ///
    /// Reads `self.defaults` rather than `DataStore.shared` so this stays
    /// testable with the injected UserDefaults suite, matching how the rest
    /// of this class avoids the app-wide singleton.
    private func loadGlobalNotificationsEnabled() -> Bool {
        DataStore.masterSwitchEnabled(in: defaults)
    }

    /// Applies the profile's notification policy to every normalized usage
    /// window. Callers must pass the accepted report for the exact profile.
    func checkAndNotify(
        report: UsageReport,
        previousReport: UsageReport? = nil,
        profileID: UUID,
        profileName: String,
        settings: NotificationSettings,
        now: Date = Date()
    ) {
        let globallyEnabled = loadGlobalNotificationsEnabled()
        guard UsageNotificationPolicy.isEligible(
            report: report,
            settings: settings,
            now: now,
            globallyEnabled: globallyEnabled
        ) else {
            return
        }

        let reservedEvents: [(
            event: UsageNotificationEvent,
            token: UUID
        )] = {
            stateLock.lock()
            defer { stateLock.unlock() }
            guard normalizedLedgerIsUsable else {
                return []
            }
            var priorStates = normalizedWindowStates
            if let previousReport,
               previousReport.providerID == report.providerID {
                let persistedBaseline =
                    UsageNotificationPolicy.baselineStates(
                        report: previousReport,
                        profileID: profileID
                    )
                for (key, state) in persistedBaseline
                where priorStates[key] == nil {
                    priorStates[key] = state
                }
            }
            let evaluation = UsageNotificationPolicy.evaluate(
                report: report,
                profileID: profileID,
                settings: settings,
                now: now,
                previousStates: priorStates,
                globallyEnabled: globallyEnabled
            )
            normalizedWindowStates = evaluation.states
            let activeKeys = activeWindowKeys(
                report: report,
                profileID: profileID
            )
            applyMissingWindowRetentionLocked(
                profileID: profileID,
                providerID: report.providerID,
                activeKeys: activeKeys,
                now: now
            )
            guard persistNormalizedLedgerLocked() else {
                return []
            }
            var reservations: [(
                event: UsageNotificationEvent,
                token: UUID
            )] = []
            for event in evaluation.events {
                let identifier = event.identity.persistenceKey
                guard normalizedInFlightReservations[
                    identifier
                ] == nil else {
                    continue
                }
                let token = UUID()
                normalizedInFlightReservations[identifier] =
                    NormalizedNotificationReservation(
                        token: token,
                        window: event.identity.window
                    )
                reservations.append((event, token))
            }
            return reservations
        }()
        for reservation in reservedEvents {
            sendNormalizedAlert(
                reservation.event,
                reservationToken: reservation.token,
                profileName: profileName,
                soundName: settings.soundName
            )
        }
    }

    private func sendNormalizedAlert(
        _ event: UsageNotificationEvent,
        reservationToken: UUID,
        profileName: String,
        soundName: String
    ) {
        let identifier = event.identity.persistenceKey

        let content = UNMutableNotificationContent()
        let groupLabel = event.groupDisplayName
            ?? event.identity.window.groupID.rawValue
        let windowLabel = event.windowDisplayName
            ?? event.identity.window.windowID.rawValue
        let label =
            groupLabel == windowLabel
            ? windowLabel
            : "\(groupLabel) – \(windowLabel)"
        let titleFormat = ProviderUILocalization.text(
            "notification.provider_usage.title",
            fallback: "%@ – %@"
        )
        content.title = String(
            format: titleFormat,
            profileName,
            label
        )
        if let threshold = event.threshold {
            let reset = event.resetTime.map {
                let resetFormat = ProviderUILocalization.text(
                    "notification.provider_usage.reset_suffix",
                    fallback: " Resets %@."
                )
                return String(
                    format: resetFormat,
                    FormatterHelper.timeUntilReset(from: $0)
                )
            } ?? ""
            let bodyFormat = ProviderUILocalization.text(
                "notification.provider_usage.threshold",
                fallback: "Usage crossed %d%% (%.1f%%).%@"
            )
            content.body = String(
                format: bodyFormat,
                threshold,
                event.percentage,
                reset
            )
        } else {
            content.body = ProviderUILocalization.text(
                "notification.provider_usage.reset",
                fallback: "Usage window reset."
            )
        }
        content.categoryIdentifier = "USAGE_ALERT"

        let customSoundName: String?
        switch soundName {
        case "none":
            customSoundName = nil
        case "default":
            content.sound = .default
            customSoundName = nil
        default:
            customSoundName = soundName
        }

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        notificationRequestAdder(request) {
            [weak self] error in
            if let error {
                self?.completeNormalizedNotification(
                    event,
                    reservationToken: reservationToken,
                    succeeded: false
                )
                LoggingService.shared.logError(
                    "Failed to send usage notification",
                    error: error
                )
                return
            }
            self?.completeNormalizedNotification(
                event,
                reservationToken: reservationToken,
                succeeded: true
            )
            if let customSoundName {
                DispatchQueue.main.async {
                    NSSound(
                        named: NSSound.Name(customSoundName)
                    )?.play()
                }
            }
        }
    }

    private func completeNormalizedNotification(
        _ event: UsageNotificationEvent,
        reservationToken: UUID,
        succeeded: Bool
    ) {
        let identifier = event.identity.persistenceKey
        stateLock.lock()
        defer { stateLock.unlock() }
        guard normalizedInFlightReservations[identifier]?
                .token == reservationToken else {
            return
        }
        normalizedInFlightReservations.removeValue(
            forKey: identifier
        )
        guard succeeded,
              var state =
                normalizedWindowStates[
                    event.identity.window
                ],
              state.cycleID == event.identity.cycleID else {
            return
        }
        switch event.identity.kind {
        case .reset:
            if state.pendingResetCycleID
                == event.identity.cycleID {
                state.pendingResetCycleID = nil
            }
        case .threshold:
            guard let threshold = event.threshold else {
                return
            }
            state.highestDeliveredThreshold = max(
                state.highestDeliveredThreshold ?? 0,
                threshold
            )
            if state.pendingThreshold == threshold {
                state.pendingThreshold = nil
            }
        }
        normalizedWindowStates[event.identity.window] =
            state
        persistNormalizedLedgerLocked()
    }

    private func activeWindowKeys(
        report: UsageReport,
        profileID: UUID
    ) -> Set<UsageNotificationWindowKey> {
        Set(
            UsageNotificationPolicy.eligibleWindows(
                in: report
            ).map {
                UsageNotificationWindowKey(
                    profileID: profileID,
                    providerID: report.providerID,
                    groupID: $0.groupID,
                    windowID: $0.window.id
                )
            }
        )
    }

    private func applyMissingWindowRetentionLocked(
        profileID: UUID,
        providerID: ProviderID,
        activeKeys: Set<UsageNotificationWindowKey>,
        now: Date
    ) {
        let scoped = normalizedWindowStates.filter {
            $0.key.profileID == profileID
                && $0.key.providerID == providerID
        }
        let cutoff = now.addingTimeInterval(
            -missingWindowRetention
        )
        let retainedMissing = scoped
            .filter {
                !activeKeys.contains($0.key)
                    && $0.value.lastSeenAt >= cutoff
            }
            .sorted {
                if $0.value.lastSeenAt
                    != $1.value.lastSeenAt {
                    return $0.value.lastSeenAt
                        > $1.value.lastSeenAt
                }
                return $0.key.persistencePrefix
                    < $1.key.persistencePrefix
            }
            .prefix(maximumMissingWindowsPerScope)
        let retainedKeys =
            activeKeys
                .union(retainedMissing.map(\.key))
                .union(
                    normalizedInFlightReservations.values
                        .compactMap {
                            reservation in
                            let key = reservation.window
                            return key.profileID == profileID
                                && key.providerID == providerID
                                ? key
                                : nil
                        }
                )
        let removedKeys = Set(scoped.keys).subtracting(
            retainedKeys
        )
        guard !removedKeys.isEmpty else {
            return
        }
        normalizedWindowStates = normalizedWindowStates
            .filter { !removedKeys.contains($0.key) }
    }

    func normalizedNotificationStateCount(
        profileID: UUID,
        providerID: ProviderID
    ) -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return normalizedWindowStates.keys.filter {
            $0.profileID == profileID
                && $0.providerID == providerID
        }.count
    }

    /// Sends a notification when approaching usage limits (legacy method)
    func sendUsageAlert(type: AlertType, percentage: Double, resetTime: Date?) {
        // Check if notifications are enabled in preferences
        guard DataStore.shared.loadNotificationsMasterSwitchEnabled() else {
            return
        }

        // Map percentage to threshold level to prevent duplicate notifications
        let thresholdLevel: Int
        if percentage >= 95 {
            thresholdLevel = 95
        } else if percentage >= 90 {
            thresholdLevel = 90
        } else if percentage >= 75 {
            thresholdLevel = 75
        } else {
            return // Below all thresholds
        }

        // Create unique identifier based on threshold level, not actual percentage
        let identifier = "\(type.rawValue)_\(thresholdLevel)"

        guard reserveNotification(identifier) else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = type.title
        content.body = type.message(percentage: percentage, resetTime: resetTime)
        content.sound = .default
        content.categoryIdentifier = "USAGE_ALERT"

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil // Show immediately
        )

        notificationRequestAdder(request) { [weak self] error in
            if let error {
                self?.releaseNotification(identifier)
                LoggingService.shared.logError(
                    "Failed to send legacy usage notification",
                    error: error
                )
            }
        }
    }

    /// Sends a simple notification (for non-usage alerts)
    func sendSimpleAlert(type: AlertType) {
        let content = UNMutableNotificationContent()
        content.title = type.title
        content.body = type.message(percentage: 0, resetTime: nil)
        content.sound = .default
        content.categoryIdentifier = "INFO_ALERT"

        let request = UNNotificationRequest(
            identifier: type.rawValue,
            content: content,
            trigger: nil // Show immediately
        )

        notificationRequestAdder(request) { _ in
            // Notification sent
        }
    }

    /// Sends a brief success notification for user-triggered refreshes
    func sendSuccessNotification() {
        let center = UNUserNotificationCenter.current()

        // Create notification content
        let content = UNMutableNotificationContent()
        content.title = "RevvyTach Updated"
        content.body = "Successfully loaded usage data"
        // Silent notification (no sound)
        content.categoryIdentifier = "SUCCESS_ALERT"

        // Create a trigger to deliver immediately
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)

        // Create the request with a unique identifier
        let identifier = "usage_refresh_success_\(UUID().uuidString)"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        // Add the notification request
        notificationRequestAdder(request) { error in
            if let error = error {
                LoggingService.shared.logError("Failed to show success notification: \(error)")
            }
        }

        // Auto-remove after 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            center.removeDeliveredNotifications(withIdentifiers: [identifier])
        }
    }

    /// Checks usage and sends appropriate alerts (profile-aware)
    func checkAndNotify(usage: ClaudeUsage, profileName: String, settings: NotificationSettings) {
        // Check if notifications are enabled for this profile
        guard settings.enabled else {
            return
        }

        let sessionPercentage = usage.effectiveSessionPercentage
        stateLock.lock()
        let previousPercentage =
            previousSessionPercentages[profileName] ?? 0.0
        let didReset =
            previousPercentage > 0.0 && sessionPercentage == 0.0
        if didReset {
            sentNotificationIdentities =
                Set(sentNotificationIdentities.filter {
                    !$0.hasPrefix(profileName)
                })
            persistSentNotificationsLocked()
        }
        previousSessionPercentages[profileName] = sessionPercentage
        stateLock.unlock()

        // Check for session reset (went from >0% to 0%)
        if didReset {
            sendProfileAlert(
                profileName: profileName,
                type: .sessionReset,
                percentage: sessionPercentage,
                resetTime: usage.sessionResetTime,
                soundName: settings.soundName
            )

            // Note: Auto-start session is handled per-profile but called from elsewhere
        }

        // Check thresholds (highest first) - includes both built-in and custom
        let thresholds = settings.sortedThresholds
        for threshold in thresholds.reversed() {
            if sessionPercentage >= Double(threshold) {
                let alertType: AlertType
                switch threshold {
                case 95...:
                    alertType = .sessionCritical
                case 90..<95:
                    alertType = .sessionWarning
                default:
                    alertType = .sessionInfo
                }
                sendProfileAlert(
                    profileName: profileName,
                    type: alertType,
                    percentage: sessionPercentage,
                    thresholdLevel: threshold,
                    resetTime: usage.sessionResetTime,
                    soundName: settings.soundName
                )
                break
            }
        }
    }

    /// Checks usage and sends appropriate alerts (legacy, for backwards compatibility)
    func checkAndNotify(usage: ClaudeUsage) {
        // Fallback to old behavior if called without profile
        guard DataStore.shared.loadNotificationsMasterSwitchEnabled() else {
            return
        }

        let settings = NotificationSettings(
            enabled: true,
            threshold75Enabled: true,
            threshold90Enabled: true,
            threshold95Enabled: true
        )

        checkAndNotify(usage: usage, profileName: "Default", settings: settings)
    }

    /// Sends a profile-specific usage alert
    private func sendProfileAlert(profileName: String, type: AlertType, percentage: Double, thresholdLevel: Int? = nil, resetTime: Date?, soundName: String = "default") {
        // Use the configured threshold level (not current percentage) to prevent duplicate notifications
        let level = thresholdLevel ?? Int(percentage)

        // Create unique identifier based on alert type and threshold level
        let identifier = "\(profileName)_\(type.rawValue)_\(level)"

        guard reserveNotification(identifier) else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "\(profileName) - \(type.title)"
        content.body = type.message(percentage: percentage, resetTime: resetTime)
        content.categoryIdentifier = "USAGE_ALERT"

        // Apply sound setting
        // Note: UNNotificationSound(named:) only finds sounds bundled in the app,
        // not system sounds from /System/Library/Sounds/. For custom system sounds,
        // we play via NSSound after the notification is delivered.
        let customSoundName: String? = {
            switch soundName {
            case "none":
                return nil
            case "default":
                content.sound = .default
                return nil
            default:
                return soundName
            }
        }()

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil // Show immediately
        )

        notificationRequestAdder(request) { [weak self] error in
            if let error {
                self?.releaseNotification(identifier)
                LoggingService.shared.logError(
                    "Failed to send profile usage notification",
                    error: error
                )
            } else {
                // Play custom system sound after notification is delivered
                if let name = customSoundName {
                    DispatchQueue.main.async {
                        if let sound = NSSound(named: NSSound.Name(name)) {
                            sound.play()
                        } else {
                            NSSound.beep()
                        }
                    }
                }

            }
        }
    }

    /// Sends auto-start session notification
    func sendAutoStartNotification(profileName: String, success: Bool, error: String?) {
        let content = UNMutableNotificationContent()

        if success {
            content.title = "\(profileName) - \(AlertType.sessionAutoStarted.title)"
            content.body = AlertType.sessionAutoStarted.message(percentage: 0, resetTime: nil)
            content.sound = .default
            content.categoryIdentifier = "INFO_ALERT"
        } else {
            content.title = "\(profileName) - \(AlertType.sessionAutoStartFailed.title)"
            var message = AlertType.sessionAutoStartFailed.message(percentage: 0, resetTime: nil)
            if let error = error {
                message += " Error: \(error)"
            }
            content.body = message
            content.sound = .default
            content.categoryIdentifier = "ERROR_ALERT"
        }

        let identifier = success ? "auto_start_\(profileName)_success" : "auto_start_\(profileName)_failed_\(Date().timeIntervalSince1970)"
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil // Show immediately
        )

        notificationRequestAdder(request) { error in
            if let error = error {
                LoggingService.shared.logError("Failed to send auto-start notification: \(error)")
            }
        }
    }

    /// Sends a notification when auto-switching profiles due to session limit
    func sendAutoSwitchNotification(fromProfile: String, toProfile: String) {
        let content = UNMutableNotificationContent()
        content.title = "notification.profile_auto_switched.title".localized
        content.body = "notification.profile_auto_switched.message".localized(with: fromProfile, toProfile)
        content.sound = .default
        content.categoryIdentifier = "INFO_ALERT"

        let identifier = "auto_switch_\(Date().timeIntervalSince1970)"
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )

        notificationRequestAdder(request) { error in
            if let error = error {
                LoggingService.shared.logError("Failed to send auto-switch notification: \(error)")
            }
        }
    }

    /// Says that one profile's claude.ai sign-in was refreshed from Chrome.
    ///
    /// Sent once per successful automatic re-read, and only then: an
    /// unchanged key, a Chrome that could not be read, and a refusal on a
    /// profile with no remembered Chrome profile all stay silent, because
    /// none of them changed anything. Ungated by the usage-alert master
    /// switch for the same reason the auto-start and auto-switch notices are
    /// — it reports something the app did to a credential on the user's
    /// behalf, not a usage threshold.
    func sendChromeSessionKeyRefreshedNotification(
        profileName: String,
        chromeProfileLabel: String
    ) {
        let content = UNMutableNotificationContent()
        content.title = "notification.chrome_key_refreshed.title".localized
        content.body = "notification.chrome_key_refreshed.message"
            .localized(with: profileName, chromeProfileLabel)
        content.sound = .default
        content.categoryIdentifier = "INFO_ALERT"

        let request = UNNotificationRequest(
            identifier: "chrome_key_refreshed_"
                + "\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )

        notificationRequestAdder(request) { error in
            if let error {
                LoggingService.shared.logError(
                    "Failed to send Chrome session key refresh "
                    + "notification: \(error)"
                )
            }
        }
    }

    /// Clears notification tracking state for a specific profile
    func clearNotificationsForProfile(_ profileName: String) {
        stateLock.lock()
        previousSessionPercentages.removeValue(forKey: profileName)
        let filtered = sentNotificationIdentities.filter {
            !$0.hasPrefix(profileName)
        }
        if filtered.count != sentNotificationIdentities.count {
            sentNotificationIdentities = Set(filtered)
            persistSentNotificationsLocked()
        }
        stateLock.unlock()
    }

    func clearNotificationsForProfile(
        _ profileID: UUID,
        providerID: ProviderID
    ) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        if !normalizedLedgerIsUsable {
            // An unreadable or future-schema ledger cannot be edited
            // selectively. Explicit profile deletion must still complete and
            // must not retain unknown data for the deleted profile, so reset
            // the whole notification-only ledger with readback verification.
            defaults.removeObject(
                forKey: Self.normalizedLedgerKey
            )
            guard defaults.data(
                forKey: Self.normalizedLedgerKey
            ) == nil else {
                throw NotificationStatePersistenceError
                    .normalizedLedgerWriteFailed
            }
            normalizedWindowStates.removeAll()
            normalizedInFlightReservations.removeAll()
            normalizedLedgerIsUsable = true
        }
        normalizedWindowStates = normalizedWindowStates.filter {
            $0.key.profileID != profileID
                || $0.key.providerID != providerID
        }
        normalizedInFlightReservations =
            normalizedInFlightReservations.filter {
                let window = $0.value.window
                return window.profileID != profileID
                    || window.providerID != providerID
            }
        let component = profileID.uuidString.lowercased()
        let profilePrefix = "\(component.utf8.count):\(component)"
        let filtered = sentNotificationIdentities.filter {
            !$0.hasPrefix(profilePrefix)
        }
        sentNotificationIdentities = Set(filtered)
        guard persistSentNotificationsLocked() else {
            throw NotificationStatePersistenceError
                .legacyStateWriteFailed
        }
        guard persistNormalizedLedgerLocked() else {
            throw NotificationStatePersistenceError
                .normalizedLedgerWriteFailed
        }
    }

    /// Schedules a notification 24 hours before the session key expires
    func scheduleSessionKeyExpiryNotification(expiryDate: Date) {
        let center = UNUserNotificationCenter.current()
        let identifier = "api_session_key_expiry"

        // Remove any existing expiry notification
        center.removePendingNotificationRequests(withIdentifiers: [identifier])

        // Schedule 24 hours before expiry
        let triggerDate = expiryDate.addingTimeInterval(-24 * 60 * 60)
        guard triggerDate > Date() else {
            // Already within 24 hours of expiry — send immediately
            sendSimpleAlert(type: .sessionKeyExpiring)
            return
        }

        let content = UNMutableNotificationContent()
        content.title = AlertType.sessionKeyExpiring.title
        content.body = AlertType.sessionKeyExpiring.message(percentage: 0, resetTime: expiryDate)
        content.sound = .default
        content.categoryIdentifier = "INFO_ALERT"

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: triggerDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        notificationRequestAdder(request) { error in
            if let error = error {
                LoggingService.shared.logError("Failed to schedule session key expiry notification: \(error)")
            }
        }
    }

    /// Clears all pending notifications
    func clearAllNotifications() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }
}

// MARK: - Alert Types

extension NotificationManager {
    enum AlertType: String {
        case sessionInfo = "session_info"  // 75% threshold
        case sessionWarning = "session_warning"  // 90% threshold
        case sessionCritical = "session_critical"  // 95% threshold
        case sessionReset = "session_reset"
        case sessionAutoStarted = "session_auto_started"
        case sessionAutoStartFailed = "session_auto_start_failed"
        case weeklyWarning = "weekly_warning"
        case weeklyCritical = "weekly_critical"
        case opusWarning = "opus_warning"
        case opusCritical = "opus_critical"
        case sessionKeyExpiring = "session_key_expiring"
        case notificationsEnabled = "notifications_enabled"

        var title: String {
            switch self {
            case .sessionInfo:
                return "Usage Info"
            case .sessionWarning:
                return "notification.session_warning.title".localized
            case .sessionCritical:
                return "notification.session_critical.title".localized
            case .sessionReset:
                return "notification.session_reset.title".localized
            case .sessionAutoStarted:
                return "notification.session_auto_started.title".localized
            case .sessionAutoStartFailed:
                return "notification.session_auto_start_failed.title".localized
            case .weeklyWarning:
                return "notification.weekly_warning.title".localized
            case .weeklyCritical:
                return "notification.weekly_critical.title".localized
            case .opusWarning:
                return "notification.opus_warning.title".localized
            case .opusCritical:
                return "notification.opus_critical.title".localized
            case .sessionKeyExpiring:
                return "API Session Expiring"
            case .notificationsEnabled:
                return "notification.enabled.title".localized
            }
        }

        func message(percentage: Double, resetTime: Date?) -> String {
            let percentStr = String(format: "%.1f%%", percentage)
            let resetStr = resetTime.map { "Resets \(FormatterHelper.timeUntilReset(from: $0))" } ?? ""

            switch self {
            case .sessionInfo:
                return "You've used \(percentStr) of your session limit. \(resetStr)"
            case .sessionWarning:
                return "notification.session_warning.message".localized(with: percentStr, resetStr)
            case .sessionCritical:
                return "notification.session_critical.message".localized(with: percentStr, resetStr)
            case .sessionReset:
                return "notification.session_reset.message".localized
            case .sessionAutoStarted:
                return "notification.session_auto_started.message".localized
            case .sessionAutoStartFailed:
                return "notification.session_auto_start_failed.message".localized
            case .weeklyWarning:
                return "notification.weekly_warning.message".localized(with: percentStr, resetStr)
            case .weeklyCritical:
                return "notification.weekly_critical.message".localized(with: percentStr, resetStr)
            case .opusWarning:
                return "notification.opus_warning.message".localized(with: percentStr, resetStr)
            case .opusCritical:
                return "notification.opus_critical.message".localized(with: percentStr, resetStr)
            case .sessionKeyExpiring:
                if let resetTime = resetTime {
                    let formatter = RelativeDateTimeFormatter()
                    formatter.unitsStyle = .full
                    let relative = formatter.localizedString(for: resetTime, relativeTo: Date())
                    return "Your API session key expires \(relative). Please re-authenticate to avoid interruption."
                }
                return "Your API session key expires soon. Please re-authenticate to avoid interruption."
            case .notificationsEnabled:
                return "notification.enabled.message".localized
            }
        }
    }
}
