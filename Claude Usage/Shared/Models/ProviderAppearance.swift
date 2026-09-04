import Foundation
import Combine
import UsageCore

/// Code-native, non-color identity for a usage provider.
struct ProviderAppearance: Equatable, Sendable {
    let providerID: ProviderID
    let displayName: String
    let compactBadge: String
    let symbolName: String

    static func forProvider(_ providerID: ProviderID) -> ProviderAppearance {
        switch providerID {
        case .claude:
            return ProviderAppearance(
                providerID: providerID,
                displayName: "Claude",
                compactBadge: "CL",
                symbolName: "sparkles"
            )
        case .codex:
            return ProviderAppearance(
                providerID: providerID,
                displayName: "Codex",
                compactBadge: "CX",
                symbolName: "chevron.left.forwardslash.chevron.right"
            )
        default:
            let safeName = providerID.rawValue
                .replacingOccurrences(of: "-", with: " ")
                .capitalized
            return ProviderAppearance(
                providerID: providerID,
                displayName: safeName,
                compactBadge: String(safeName.prefix(2)).uppercased(),
                symbolName: "gauge.with.dots.needle.67percent"
            )
        }
    }

    static func canonicalProviderOrder(
        _ lhs: ProviderID,
        _ rhs: ProviderID
    ) -> Bool {
        func rank(_ providerID: ProviderID) -> Int {
            switch providerID {
            case .claude: return 0
            case .codex: return 1
            default: return 2
            }
        }
        let lhsRank = rank(lhs)
        let rhsRank = rank(rhs)
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        return lhs.rawValue < rhs.rawValue
    }
}

/// User-selectable indicator that distinguishes a status item's provider
/// (Claude vs Codex) without requiring a click. Purely visual — it never
/// changes what data is fetched or how it is computed.
///
/// The settings UI and persistence expose this as two independent bools
/// ("Provider glyph" and "Provider background tint", both off by default —
/// turning both on is simply the combined look). This enum is an internal
/// convenience for the renderer, derived from those two bools rather than
/// stored directly.
enum ProviderBadgeStyle: Sendable, Equatable {
    /// Current behavior: no provider indicator.
    case none
    /// A small monochrome provider mark drawn left of the item's content.
    case glyph
    /// A low-opacity provider-colored pill behind the item's content.
    case tint
    /// Both the glyph and the background tint.
    case glyphAndTint

    init(glyphEnabled: Bool, tintEnabled: Bool) {
        switch (glyphEnabled, tintEnabled) {
        case (false, false): self = .none
        case (true, false): self = .glyph
        case (false, true): self = .tint
        case (true, true): self = .glyphAndTint
        }
    }

    var showsGlyph: Bool { self == .glyph || self == .glyphAndTint }
    var showsTint: Bool { self == .tint || self == .glyphAndTint }
}

enum ProviderMetricDisplayState: String, Equatable, Sendable {
    case ready
    case loading
    case stale
    case degraded
    case error
    case noData

    var accessibilityText: String {
        switch self {
        case .ready:
            return ProviderUILocalization.text(
                "menubar.accessibility.state.ready",
                fallback: "ready"
            )
        case .loading:
            return ProviderUILocalization.text(
                "menubar.accessibility.state.loading",
                fallback: "loading usage"
            )
        case .stale:
            return ProviderUILocalization.text(
                "menubar.accessibility.state.stale",
                fallback: "stale usage"
            )
        case .degraded:
            return ProviderUILocalization.text(
                "menubar.accessibility.state.degraded",
                fallback: "degraded; showing cached usage"
            )
        case .error:
            return ProviderUILocalization.text(
                "menubar.accessibility.state.error",
                fallback: "usage error"
            )
        case .noData:
            return ProviderUILocalization.text(
                "menubar.accessibility.state.no_data",
                fallback: "no usage data"
            )
        }
    }
}

struct ProviderMetricDescriptor: Equatable, Identifiable, Sendable {
    let id: MenuBarMetricID
    let providerID: ProviderID
    let groupName: String
    let metricName: String
    let resetAt: Date?
    let duration: TimeInterval?
    let usedPercentage: Double?
    let isUsable: Bool
    let unavailableReason: String?

    var accessibilityName: String {
        "\(ProviderAppearance.forProvider(providerID).displayName) "
            + "\(groupName), \(metricName)"
    }
}

struct ProviderMetricPresentation: Equatable, Identifiable, Sendable {
    let descriptor: ProviderMetricDescriptor
    let state: ProviderMetricDisplayState
    let usedPercentage: Double?
    let displayedPercentage: Double?
    let showRemaining: Bool
    let elapsedFraction: Double?
    let statusLevel: UsageStatusLevel
    let notice: String?

    var id: MenuBarMetricID { descriptor.id }

    var percentageText: String {
        guard let displayedPercentage else { return "—" }
        return "\(Int(displayedPercentage.rounded()))%"
    }

    var modeText: String {
        showRemaining
            ? ProviderUILocalization.text(
                "popover.normalized.value.remaining",
                fallback: "remaining"
            )
            : ProviderUILocalization.text(
                "popover.normalized.value.used",
                fallback: "used"
            )
    }

    var accessibilityLabel: String {
        let provider = ProviderAppearance.forProvider(
            descriptor.providerID
        )
        let stateSuffix = state == .ready
            ? ""
            : ", \(state.accessibilityText)"
        return "\(provider.displayName), \(descriptor.groupName), "
            + "\(descriptor.metricName), \(percentageText) \(modeText)"
            + stateSuffix
    }
}

struct ProviderStatusItemIdentity: Hashable, Sendable {
    let profileID: UUID
    let providerID: ProviderID
    let providerRevision: UInt64
    let metricID: MenuBarMetricID?
}

enum ProviderMenuActionKind: Equatable, Sendable {
    case openPopover
    case activate
    case refresh
    case settings(SettingsNavigationDestination)
    case quit
}

struct ProviderMenuAction: Equatable, Identifiable, Sendable {
    let title: String
    let target: ProviderStatusItemIdentity
    let kind: ProviderMenuActionKind

    var id: String {
        "\(target.profileID.uuidString):\(title):\(String(describing: kind))"
    }
}

struct ProviderMenuPresentation: Equatable, Identifiable, Sendable {
    let identity: ProviderStatusItemIdentity
    let profileName: String
    let appearance: ProviderAppearance
    let metrics: [ProviderMetricPresentation]
    let state: ProviderMetricDisplayState
    let actions: [ProviderMenuAction]
    let nextFreshnessDeadline: Date?

    var id: UUID { identity.profileID }
    var metric: ProviderMetricPresentation? { metrics.first }
}

struct ProviderStatusItemReconciliationEntry:
    Equatable,
    Sendable
{
    let statusMetricID: MenuBarMetricID
    let identity: ProviderStatusItemIdentity
}

/// Pure identity reconciliation shared by the native status-item adapter and
/// isolated UI automation. It is the single source of truth for the profile,
/// provider revision, and concrete metric captured by a rendered status item.
enum ProviderStatusItemReconciliation {
    static func resolvedIdentity(
        captured: ProviderStatusItemIdentity?,
        fallbackProfile: Profile?
    ) -> ProviderStatusItemIdentity? {
        if let captured { return captured }
        guard let fallbackProfile,
              !fallbackProfile.deletionInProgress else {
            return nil
        }
        return ProviderStatusItemIdentity(
            profileID: fallbackProfile.id,
            providerID: fallbackProfile.providerID,
            providerRevision: fallbackProfile.providerRevision,
            metricID: nil
        )
    }

    static func singleEntries(
        for presentation: ProviderMenuPresentation
    ) -> [ProviderStatusItemReconciliationEntry] {
        let metricIDs = presentation.metrics.map(\.id)
        let renderedIDs = metricIDs.isEmpty
            ? [
                MenuBarMetricID.providerPlaceholder(
                    presentation.identity.providerID
                )
            ]
            : metricIDs
        return renderedIDs.map { statusMetricID in
            ProviderStatusItemReconciliationEntry(
                statusMetricID: statusMetricID,
                identity: ProviderStatusItemIdentity(
                    profileID: presentation.identity.profileID,
                    providerID: presentation.identity.providerID,
                    providerRevision:
                        presentation.identity.providerRevision,
                    metricID: metricIDs.contains(statusMetricID)
                        ? statusMetricID
                        : nil
                )
            )
        }
    }

    static func multiIdentity(
        for presentation: ProviderMenuPresentation
    ) -> ProviderStatusItemIdentity {
        let metricID = presentation.metrics.first?.id
        return ProviderStatusItemIdentity(
            profileID: presentation.identity.profileID,
            providerID: presentation.identity.providerID,
            providerRevision: presentation.identity.providerRevision,
            metricID: metricID
        )
    }
}

/// Validates a captured status/menu identity immediately before dispatch and
/// routes every provider-sensitive action to injected production adapters.
/// This closes the menu-open/action-select race without coupling the pure
/// routing policy to AppKit, refresh runtimes, or application termination.
@MainActor
struct ProviderCapturedTargetActionRouter {
    enum Action: Equatable {
        case openPopover
        case detachPopover
        case refresh
        case activate
        case providerAccount
        case appearance
        case claudeAccount
        case manageProfiles
        case legacySettings
        case popoverSettings
        case quit
    }

    typealias TargetSink =
        @MainActor (ProviderStatusItemIdentity, Profile) -> Void
    typealias SettingsSink =
        @MainActor (
            SettingsNavigationDestination,
            ProviderStatusItemIdentity,
            Profile
        ) -> Void

    struct Sinks {
        let openPopover: TargetSink
        let detachPopover: TargetSink
        let refresh: TargetSink
        let activate: TargetSink
        let settings: SettingsSink
        let quit: TargetSink
    }

    let profiles: @MainActor () -> [Profile]
    let sinks: Sinks

    nonisolated static func popoverSettingsDestination(
        for target: ProviderStatusItemIdentity
    ) -> SettingsNavigationDestination {
        target.providerID == .claude
            ? .claudeAccount(profileID: target.profileID)
            : .providerAccount(profileID: target.profileID)
    }

    func currentProfile(
        for target: ProviderStatusItemIdentity
    ) -> Profile? {
        profiles().first {
            $0.id == target.profileID
                && $0.providerID == target.providerID
                && $0.providerRevision == target.providerRevision
                && !$0.deletionInProgress
        }
    }

    @discardableResult
    func route(
        _ action: Action,
        target: ProviderStatusItemIdentity
    ) -> Bool {
        guard let profile = currentProfile(for: target) else {
            return false
        }
        switch action {
        case .openPopover:
            sinks.openPopover(target, profile)
        case .detachPopover:
            sinks.detachPopover(target, profile)
        case .refresh:
            sinks.refresh(target, profile)
        case .activate:
            sinks.activate(target, profile)
        case .providerAccount:
            sinks.settings(
                .providerAccount(profileID: target.profileID),
                target,
                profile
            )
        case .appearance:
            sinks.settings(
                .appearance(profileID: target.profileID),
                target,
                profile
            )
        case .claudeAccount:
            sinks.settings(
                .claudeAccount(profileID: target.profileID),
                target,
                profile
            )
        case .manageProfiles:
            sinks.settings(.manageProfiles, target, profile)
        case .legacySettings:
            sinks.settings(.defaultView, target, profile)
        case .popoverSettings:
            sinks.settings(
                Self.popoverSettingsDestination(for: target),
                target,
                profile
            )
        case .quit:
            sinks.quit(target, profile)
        }
        return true
    }
}

@MainActor
struct ProviderManualRefreshDispatcher {
    let dispatch:
        @MainActor ([Profile], UsageRefreshTrigger) -> Void

    func dispatch(profile: Profile) {
        dispatch([profile], .manual)
    }
}

/// Retains the last known provider catalog for settings. A transient missing,
/// stale, or failed snapshot must not make saved controls disappear while the
/// settings window is open.
@MainActor
final class ProviderMenuCatalogStore: ObservableObject {
    static let shared = ProviderMenuCatalogStore()

    @Published private(set) var catalogs:
        [UUID: [ProviderMetricDescriptor]] = [:]
    private var catalogProviders: [UUID: ProviderID] = [:]
    private var catalogRevisions: [UUID: UInt64] = [:]

    func publish(
        profiles: [Profile],
        snapshots: [UUID: PresentationSnapshot]
    ) {
        let liveProfileIDs = Set(profiles.map(\.id))
        catalogs = catalogs.filter {
            liveProfileIDs.contains($0.key)
        }
        catalogProviders = catalogProviders.filter {
            liveProfileIDs.contains($0.key)
        }
        catalogRevisions = catalogRevisions.filter {
            liveProfileIDs.contains($0.key)
        }
        for profile in profiles {
            if profile.deletionInProgress {
                invalidate(profileID: profile.id)
                continue
            }
            if catalogProviders[profile.id] != profile.providerID
                || catalogRevisions[profile.id]
                    != profile.providerRevision {
                catalogs.removeValue(forKey: profile.id)
            }
            catalogProviders[profile.id] = profile.providerID
            catalogRevisions[profile.id] = profile.providerRevision
            let discovered = ProviderMenuPresentationBuilder.catalog(
                profile: profile,
                snapshot: snapshots[profile.id]
            )
            // Claude compatibility metrics are statically known. For dynamic
            // providers retain the previous nonempty catalog through loading,
            // stale, error, and temporary no-snapshot states.
            if !discovered.isEmpty || profile.providerID == .claude {
                catalogs[profile.id] = discovered
            }
        }
    }

    func invalidate(profileID: UUID) {
        catalogs.removeValue(forKey: profileID)
        catalogProviders.removeValue(forKey: profileID)
        catalogRevisions.removeValue(forKey: profileID)
    }

    func catalog(
        for profile: Profile,
        configuration: MenuBarIconConfiguration
    ) -> [ProviderMetricDescriptor] {
        var result = catalogs[profile.id] ?? []
        var known = Set(result.map(\.id))
        for saved in configuration.metrics
        where saved.metricID.providerID == profile.providerID
            && known.insert(saved.metricID).inserted {
            guard let descriptor = Self.savedDescriptor(
                for: saved.metricID,
                providerID: profile.providerID
            ) else {
                continue
            }
            result.append(descriptor)
        }
        return result
    }

    func resetForTesting() {
        catalogs.removeAll()
        catalogProviders.removeAll()
        catalogRevisions.removeAll()
    }

    private static func savedDescriptor(
        for metricID: MenuBarMetricID,
        providerID: ProviderID
    ) -> ProviderMetricDescriptor? {
        if metricID == .claudeAPI {
            return ProviderMetricDescriptor(
                id: metricID,
                providerID: .claude,
                groupName: ProviderUILocalization.text(
                    "appearance.metric.group.api",
                    fallback: "API"
                ),
                metricName: ProviderUILocalization.text(
                    "appearance.metric.name.credits",
                    fallback: "Credits"
                ),
                resetAt: nil,
                duration: nil,
                usedPercentage: nil,
                isUsable: false,
                unavailableReason:
                    ProviderUILocalization.text(
                        "appearance.metric.saved_unavailable",
                        fallback:
                            "Saved metric is not in the latest provider response."
                    )
            )
        }
        guard let components = metricID.usageWindowComponents,
              components.providerID == providerID else {
            return nil
        }
        return ProviderMetricDescriptor(
            id: metricID,
            providerID: providerID,
            groupName: components.groupID.rawValue,
            metricName: components.windowID.rawValue,
            resetAt: nil,
            duration: nil,
            usedPercentage: nil,
            isUsable: false,
            unavailableReason:
                ProviderUILocalization.text(
                    "appearance.metric.saved_unavailable",
                    fallback:
                        "Saved metric is not in the latest provider response."
                )
        )
    }
}

/// Pure provider-neutral catalog and presentation construction.
///
/// It intentionally has no provider construction, process launch, fetching,
/// storage, or global singleton access. The menu layer passes an immutable
/// profile/snapshot pair and an explicit clock value.
enum ProviderMenuPresentationBuilder {
    static func catalog(
        profile: Profile,
        snapshot: PresentationSnapshot?
    ) -> [ProviderMetricDescriptor] {
        guard !profile.deletionInProgress else { return [] }
        if let snapshot,
           !snapshotMatches(profile: profile, snapshot: snapshot) {
            return []
        }
        if profile.providerID == .claude {
            return claudeCatalog(profile: profile, snapshot: snapshot)
        }
        return reportCatalog(
            providerID: profile.providerID,
            snapshot: snapshot
        )
    }

    static func snapshotMatches(
        profile: Profile,
        snapshot: PresentationSnapshot
    ) -> Bool {
        guard !profile.deletionInProgress,
              snapshot.profileID == profile.id,
              snapshot.providerID == profile.providerID,
              snapshot.providerRevision == profile.providerRevision else {
            return false
        }
        if let report = snapshot.report,
           report.providerID != profile.providerID {
            return false
        }
        return true
    }

    /// `isActive` is resolved per-profile rather than against one shared id:
    /// this builds status items across every profile regardless of
    /// provider, and each provider has its own independent active slot —
    /// pass `ProfileManager.isActive(_:)`.
    static func presentations(
        profiles: [Profile],
        snapshots: [UUID: PresentationSnapshot],
        now: Date,
        isActive: (Profile) -> Bool
    ) -> [ProviderMenuPresentation] {
        profiles
            .sorted {
                if $0.providerID != $1.providerID {
                    return ProviderAppearance.canonicalProviderOrder(
                        $0.providerID,
                        $1.providerID
                    )
                }
                return $0.name.localizedStandardCompare($1.name)
                    == .orderedAscending
            }
            .map {
                presentation(
                    profile: $0,
                    snapshot: snapshots[$0.id],
                    now: now,
                    isActive: isActive($0)
                )
            }
    }

    static func presentation(
        profile: Profile,
        snapshot: PresentationSnapshot?,
        now: Date,
        isActive: Bool
    ) -> ProviderMenuPresentation {
        let validSnapshot = snapshot.flatMap {
            snapshotMatches(profile: profile, snapshot: $0)
                ? $0
                : nil
        }
        let catalog = catalog(
            profile: profile,
            snapshot: validSnapshot
        )
        let configuration = profile.iconConfig.adaptedForProvider(
            profile.providerID
        )
        let selected = configuration.resolvedMetrics(catalog: catalog)
        let descriptors = selected.compactMap { selected in
            catalog.first { $0.id == selected.metricID }
        }
        let state = displayState(snapshot: validSnapshot, now: now)
        let metrics = descriptors.map {
            metricPresentation(
                descriptor: $0,
                state: state,
                showRemaining: configuration.showRemainingPercentage,
                snapshot: validSnapshot,
                now: now
            )
        }
        let identity = ProviderStatusItemIdentity(
            profileID: profile.id,
            providerID: profile.providerID,
            providerRevision: profile.providerRevision,
            metricID: descriptors.first?.id
        )
        var actions: [ProviderMenuAction] = [
            ProviderMenuAction(
                title: String(
                    format: ProviderUILocalization.text(
                        "menu.provider.open_profile",
                        fallback: "Open %@"
                    ),
                    profile.name
                ),
                target: identity,
                kind: .openPopover
            )
        ]
        if !isActive {
            actions.append(
                ProviderMenuAction(
                    title: ProviderUILocalization.text(
                        "menu.provider.make_active",
                        fallback: "Make Active"
                    ),
                    target: identity,
                    kind: .activate
                )
            )
        }
        actions.append(
            ProviderMenuAction(
                title: ProviderUILocalization.text(
                    "common.refresh",
                    fallback: "Refresh"
                ),
                target: identity,
                kind: .refresh
            )
        )
        actions.append(
            ProviderMenuAction(
                title: String(
                    format: ProviderUILocalization.text(
                        "menu.provider.account",
                        fallback: "%@ Account…"
                    ),
                    ProviderAppearance.forProvider(
                        profile.providerID
                    ).displayName
                ),
                target: identity,
                kind: .settings(.providerAccount(profileID: profile.id))
            )
        )
        actions.append(
            ProviderMenuAction(
                title: ProviderUILocalization.text(
                    "menu.provider.appearance",
                    fallback: "Appearance…"
                ),
                target: identity,
                kind: .settings(.appearance(profileID: profile.id))
            )
        )
        actions.append(
            ProviderMenuAction(
                title: ProviderUILocalization.text(
                    "menu.provider.manage_profiles",
                    fallback: "Manage Profiles…"
                ),
                target: identity,
                kind: .settings(.manageProfiles)
            )
        )
        actions.append(
            ProviderMenuAction(
                title: ProviderUILocalization.text(
                    "common.quit",
                    fallback: "Quit"
                ),
                target: identity,
                kind: .quit
            )
        )
        return ProviderMenuPresentation(
            identity: identity,
            profileName: profile.name,
            appearance: .forProvider(profile.providerID),
            metrics: metrics,
            state: state,
            actions: actions,
            nextFreshnessDeadline: futureFreshnessDeadline(
                snapshot: validSnapshot,
                now: now
            )
        )
    }

    /// Presentations for the windows of a profile's leading limit group,
    /// regardless of which metrics the user configured for the menu bar.
    ///
    /// `presentation(profile:snapshot:now:isActive:)` returns
    /// `configuration.resolvedMetrics(catalog:)` — what the *icon* is set to
    /// show, which for a default Claude profile is the session window alone
    /// (`MetricIconConfig.weekDefault` ships disabled). A surface that must
    /// state a profile's whole position, rather than mirror its icon, needs
    /// the catalog directly — and must not rebuild used/remaining formatting
    /// for itself, so it still goes through `metricPresentation`.
    ///
    /// "Leading limit group" rather than "first two catalog entries": it
    /// drops Claude's API Credits window (a billing figure in the `API`
    /// group, not a subscription window) without naming Claude, and it stops
    /// a provider whose first group has one window from pairing it with an
    /// identically named window from the next group. Two at most, matching
    /// the pair `StatusBarUIManager.compactPercentageMetrics` already packs
    /// into a single status item.
    ///
    /// `showRemaining` is a parameter rather than something read off the
    /// profile, because which polarity setting governs depends on the
    /// caller's surface: `MenuBarIconConfiguration.showRemainingPercentage`
    /// governs single-profile mode, and the global
    /// `MultiProfileDisplayConfig.showRemainingPercentage` governs
    /// multi-profile mode (the same re-pointing `metric(_:applying:)`
    /// performs for the non-Claude multi-profile status items).
    ///
    /// `now` governs freshness and staleness only. Session-window expiry
    /// inside `ClaudeUsage.effectiveSessionPercentage` compares against
    /// `Date()` at call time, so this is not deterministic against a fixed
    /// "as of" instant, and a fixture must put its session reset in the
    /// real future.
    static func leadingWindowPresentations(
        profile: Profile,
        snapshot: PresentationSnapshot?,
        showRemaining: Bool,
        now: Date
    ) -> [ProviderMetricPresentation] {
        let validSnapshot = snapshot.flatMap {
            snapshotMatches(profile: profile, snapshot: $0)
                ? $0
                : nil
        }
        let catalog = catalog(profile: profile, snapshot: validSnapshot)
        guard let leadingGroup =
            catalog.first?.id.usageWindowComponents?.groupID
        else {
            return []
        }
        let state = displayState(snapshot: validSnapshot, now: now)
        return catalog
            .filter { $0.id.usageWindowComponents?.groupID == leadingGroup }
            .prefix(2)
            .map {
                metricPresentation(
                    descriptor: $0,
                    state: state,
                    showRemaining: showRemaining,
                    snapshot: validSnapshot,
                    now: now
                )
            }
    }

    static func isStillCurrent(
        _ target: ProviderStatusItemIdentity,
        profiles: [Profile]
    ) -> Bool {
        profiles.contains {
            $0.id == target.profileID
                && $0.providerID == target.providerID
                && $0.providerRevision == target.providerRevision
                && !$0.deletionInProgress
        }
    }

    static func nextFreshnessDeadline(
        presentations: [ProviderMenuPresentation]
    ) -> Date? {
        presentations.compactMap(\.nextFreshnessDeadline).min()
    }

    static func metric(
        _ metric: ProviderMetricPresentation?,
        applying config: MultiProfileDisplayConfig
    ) -> ProviderMetricPresentation? {
        guard let metric else { return nil }
        let displayed = metric.usedPercentage.map {
            config.showRemainingPercentage ? max(0, 100 - $0) : $0
        }
        let elapsedForStatus = config.usePaceColoring
            ? metric.elapsedFraction
            : nil
        return ProviderMetricPresentation(
            descriptor: metric.descriptor,
            state: metric.state,
            usedPercentage: metric.usedPercentage,
            displayedPercentage: displayed,
            showRemaining: config.showRemainingPercentage,
            elapsedFraction: metric.elapsedFraction,
            statusLevel: UsageStatusCalculator.calculateStatus(
                usedPercentage: metric.usedPercentage ?? 0,
                showRemaining: config.showRemainingPercentage,
                elapsedFraction: elapsedForStatus
            ),
            notice: metric.notice
        )
    }

    private static func claudeCatalog(
        profile: Profile,
        snapshot: PresentationSnapshot?
    ) -> [ProviderMetricDescriptor] {
        let usage = snapshot?.claudeUsage ?? profile.claudeUsage
        let apiUsage = snapshot?.claudeAPIUsage ?? profile.apiUsage
        return [
            ProviderMetricDescriptor(
                id: .claudeSession,
                providerID: .claude,
                groupName: ProviderUILocalization.text(
                    "appearance.metric.group.subscription",
                    fallback: "Subscription"
                ),
                metricName: ProviderUILocalization.text(
                    "appearance.metric.name.session",
                    fallback: "Session"
                ),
                resetAt: usage?.sessionResetTime,
                duration: Constants.sessionWindow,
                // `readable…`, not `effective…`: a response that omitted the
                // 5-hour window lands in the model as a plain `0`, and a
                // descriptor carrying that zero is a confident number nobody
                // ever received. `isUsable` deliberately stays
                // `usage != nil`, so which metrics `resolvedMetrics` selects
                // — and therefore which status items exist — is unchanged.
                usedPercentage: sanitize(
                    usage?.readableSessionPercentage
                ),
                isUsable: usage != nil,
                unavailableReason: usage == nil
                    ? ProviderUILocalization.text(
                        "appearance.metric.claude_session_unavailable",
                        fallback: "Session usage is not available yet."
                    )
                    : nil
            ),
            ProviderMetricDescriptor(
                id: .claudeWeek,
                providerID: .claude,
                groupName: ProviderUILocalization.text(
                    "appearance.metric.group.subscription",
                    fallback: "Subscription"
                ),
                metricName: ProviderUILocalization.text(
                    "appearance.metric.name.week",
                    fallback: "Week"
                ),
                resetAt: usage?.weeklyResetTime,
                duration: Constants.weeklyWindow,
                // Same distinction as the session window above.
                usedPercentage: sanitize(usage?.readableWeeklyPercentage),
                isUsable: usage != nil,
                unavailableReason: usage == nil
                    ? ProviderUILocalization.text(
                        "appearance.metric.claude_week_unavailable",
                        fallback: "Weekly usage is not available yet."
                    )
                    : nil
            ),
            ProviderMetricDescriptor(
                id: .claudeAPI,
                providerID: .claude,
                groupName: ProviderUILocalization.text(
                    "appearance.metric.group.api",
                    fallback: "API"
                ),
                metricName: ProviderUILocalization.text(
                    "appearance.metric.name.credits",
                    fallback: "Credits"
                ),
                resetAt: apiUsage?.resetsAt,
                duration: nil,
                usedPercentage: sanitize(apiUsage?.usagePercentage),
                isUsable: apiUsage != nil,
                unavailableReason: apiUsage == nil
                    ? ProviderUILocalization.text(
                        "appearance.metric.claude_api_unavailable",
                        fallback:
                            "API billing is not linked for this profile."
                    )
                    : nil
            )
        ]
    }

    private static func reportCatalog(
        providerID: ProviderID,
        snapshot: PresentationSnapshot?
    ) -> [ProviderMetricDescriptor] {
        guard let report = snapshot?.report else { return [] }
        return report.limitGroups.flatMap { group in
            group.windows.map { window in
                let used = sanitize(
                    window.usedPercentage
                        ?? window.quantity?.calculatedUsedPercentage
                )
                return ProviderMetricDescriptor(
                    id: MenuBarMetricID(
                        providerID: providerID,
                        groupID: group.id,
                        windowID: window.id
                    ),
                    providerID: providerID,
                    groupName: nonempty(
                        group.displayName,
                        fallback: group.id.rawValue
                    ),
                    metricName: nonempty(
                        window.displayName,
                        fallback: window.id.rawValue
                    ),
                    resetAt: window.resetsAt,
                    duration: window.duration,
                    usedPercentage: used,
                    isUsable: used != nil,
                    unavailableReason: used == nil
                        ? ProviderUILocalization.text(
                            "appearance.metric.provider_no_value",
                            fallback:
                                "This limit has no percentage or finite quantity."
                        )
                        : nil
                )
            }
        }
    }

    private static func displayState(
        snapshot: PresentationSnapshot?,
        now: Date
    ) -> ProviderMetricDisplayState {
        guard let snapshot else { return .noData }
        let hasCachedData = snapshot.report != nil
            || snapshot.claudeUsage != nil
            || snapshot.claudeAPIUsage != nil
        if snapshot.activity.isInFlight && !hasCachedData {
            return .loading
        }
        if snapshot.currentFailure != nil {
            return hasCachedData ? .degraded : .error
        }
        switch snapshot.configurationState {
        case .ready:
            break
        case .disabled, .unlinked, .dependencyMissing, .unauthenticated,
             .unsupported, .invalid, .deleting:
            return hasCachedData ? .degraded : .error
        }
        if let report = snapshot.report {
            if report.isStale(at: now) { return .stale }
            switch report.health.status {
            case .healthy:
                break
            case .degraded:
                return .degraded
            case .unavailable, .unauthenticated, .unsupported:
                return hasCachedData ? .degraded : .error
            }
        }
        if snapshot.activity.isInFlight { return .loading }
        return hasCachedData ? .ready : .noData
    }

    private static func metricPresentation(
        descriptor: ProviderMetricDescriptor,
        state: ProviderMetricDisplayState,
        showRemaining: Bool,
        snapshot: PresentationSnapshot?,
        now: Date
    ) -> ProviderMetricPresentation {
        let used = sanitize(descriptor.usedPercentage)
        let displayed = used.map {
            showRemaining ? max(0, 100 - $0) : $0
        }
        let status = UsageStatusCalculator.calculateStatus(
            usedPercentage: used ?? 0,
            showRemaining: showRemaining,
            elapsedFraction: nil
        )
        let notice: String?
        switch state {
        case .ready:
            notice = nil
        case .loading:
            notice = used == nil
                ? ProviderUILocalization.text(
                    "menubar.notice.loading",
                    fallback: "Loading usage."
                )
                : ProviderUILocalization.text(
                    "menubar.notice.refreshing_cached",
                    fallback: "Refreshing; showing the last value."
                )
        case .stale:
            notice = ProviderUILocalization.text(
                "menubar.notice.stale",
                fallback: "Showing stale usage."
            )
        case .degraded:
            notice = used == nil
                ? ProviderUILocalization.text(
                    "menubar.notice.unavailable",
                    fallback: "Usage is temporarily unavailable."
                )
                : ProviderUILocalization.text(
                    "menubar.notice.degraded_cached",
                    fallback: "Provider degraded; showing the last value."
                )
        case .error:
            notice = snapshot?.currentFailure.map {
                String(
                    format: ProviderUILocalization.text(
                        "menubar.notice.error_format",
                        fallback: "Usage error: %@."
                    ),
                    String(describing: $0.kind)
                )
            } ?? ProviderUILocalization.text(
                "menubar.notice.unavailable",
                fallback: "Usage is temporarily unavailable."
            )
        case .noData:
            notice = descriptor.unavailableReason
                ?? ProviderUILocalization.text(
                    "menubar.notice.no_data",
                    fallback: "No usage data."
                )
        }
        return ProviderMetricPresentation(
            descriptor: descriptor,
            state: state,
            usedPercentage: used,
            displayedPercentage: displayed,
            showRemaining: showRemaining,
            elapsedFraction: elapsedFraction(
                descriptor: descriptor,
                now: now
            ),
            statusLevel: status,
            notice: notice
        )
    }

    private static func futureFreshnessDeadline(
        snapshot: PresentationSnapshot?,
        now: Date
    ) -> Date? {
        guard let staleAt = snapshot?.report?.staleAt,
              staleAt > now else {
            return nil
        }
        return staleAt
    }

    private static func elapsedFraction(
        descriptor: ProviderMetricDescriptor,
        now: Date
    ) -> Double? {
        guard let resetAt = descriptor.resetAt,
              let duration = descriptor.duration,
              duration.isFinite,
              duration > 0 else {
            return nil
        }
        if resetAt <= now { return 1 }
        return min(
            max((duration - resetAt.timeIntervalSince(now)) / duration, 0),
            1
        )
    }

    private static func sanitize(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return min(value, 100)
    }

    private static func nonempty(
        _ value: String?,
        fallback: String
    ) -> String {
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty else {
            return fallback
        }
        return value
    }
}
