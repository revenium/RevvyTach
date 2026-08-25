//
//  StatusBarUIManager.swift
//  Claude Usage
//
//  Created by Claude Code on 2025-12-27.
//

import Cocoa
import Combine
import UsageCore

/// Manages multiple menu bar status items for different metrics
final class StatusBarUIManager {
    // Fixed UUID used as the dictionary key for the "no profiles selected" placeholder item.
    // Using a constant instead of UUID() prevents a new random key on every call to setupMultiProfile.
    private static let multiProfileDefaultPlaceholderID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    /// Above this many selected profiles, individual status items collapse
    /// into one overflow item so the menu bar doesn't fill up. At exactly
    /// this count every profile still gets its own item.
    static let overflowThreshold = 4

    /// Stable identifier so menu-bar managers (Bartender, Ice, ...) can
    /// track the overflow item the same way they track every other item.
    static let overflowAutosaveName = "claude-usage-tracker.overflow"

    /// Splits `profiles` (already filtered to those selected for display)
    /// into the ones that get their own status item and the ones that
    /// collapse into the single overflow item, using the app's original
    /// fixed threshold. Equivalent to
    /// `splitForOverflow(profiles, threshold: overflowThreshold)`; kept as
    /// its own overload because it's still the shape most call sites and
    /// tests want.
    static func splitForOverflow(
        _ profiles: [Profile]
    ) -> (individual: [Profile], overflow: [Profile]) {
        splitForOverflow(profiles, threshold: overflowThreshold)
    }

    /// Splits `profiles` using an arbitrary threshold — the pure logic
    /// behind `MenuBarOverflowMode.afterCount(_:)`. Above `threshold`
    /// selected profiles, individual status items collapse into one
    /// overflow item; the number that keep their own item scales with the
    /// threshold the same way the original fixed `4`/`3` pair did (one
    /// fewer than the threshold), so a user-configured threshold behaves
    /// exactly like the built-in default did at `4`.
    static func splitForOverflow(
        _ profiles: [Profile],
        threshold: Int
    ) -> (individual: [Profile], overflow: [Profile]) {
        guard profiles.count > threshold else {
            return (profiles, [])
        }
        let individualLimit = max(threshold - 1, 0)
        return (
            Array(profiles.prefix(individualLimit)),
            Array(profiles.dropFirst(individualLimit))
        )
    }

    /// Splits `profiles` according to `mode`, the single entry point every
    /// production call site should use. `.automatic` needs `spaceInput` (a
    /// measurement of real menu bar space) and `currentCollapsedCount` (for
    /// hysteresis, see `MenuBarSpaceCalculator`); both are ignored by the
    /// other two modes. A `nil` `spaceInput` in `.automatic` mode (no screen
    /// available to measure against) falls back to never collapsing, rather
    /// than guessing — the manual modes exist for exactly this situation.
    ///
    /// `runningBundleIdentifiers` guards `.automatic` the same way: when it
    /// contains a known menu bar manager (Ice, Thaw, Bartender, ...) per
    /// `MenuBarManagerDetection`, every profile keeps its own item
    /// regardless of `spaceInput`. A manager already reserves an expandable
    /// region for exactly this overflow problem — the free-space
    /// measurement being near zero is correct, not a bug, and collapsing on
    /// top of it would consume the space the manager set aside. Defaults to
    /// empty so every existing call site (and the `never`/`afterCount`
    /// modes that never touch it) is unaffected.
    static func overflowPlan(
        for profiles: [Profile],
        mode: MenuBarOverflowMode,
        currentCollapsedCount: Int,
        spaceInput: MenuBarLayoutInput?,
        runningBundleIdentifiers: [String] = []
    ) -> (individual: [Profile], overflow: [Profile]) {
        switch mode {
        case .never:
            return (profiles, [])
        case .afterCount(let threshold):
            return splitForOverflow(profiles, threshold: threshold)
        case .automatic:
            guard
                MenuBarManagerDetection.detectedManager(
                    runningBundleIdentifiers: runningBundleIdentifiers
                ) == nil
            else {
                return (profiles, [])
            }
            guard let spaceInput else {
                return (profiles, [])
            }
            let collapsedCount = MenuBarSpaceCalculator.collapsedCount(
                for: spaceInput,
                currentCollapsedCount: currentCollapsedCount
            )
            let individualCount = max(
                profiles.count - collapsedCount,
                0
            )
            return (
                Array(profiles.prefix(individualCount)),
                Array(profiles.dropFirst(individualCount))
            )
        }
    }

    // Stable provider-neutral metric identity prevents dynamic windows from
    // colliding with the legacy Claude session/week buckets.
    private var statusItems: [MenuBarMetricID: NSStatusItem] = [:]
    private var singleMetricOrder: [MenuBarMetricID] = []
    private var statusItemIdentities:
        [ObjectIdentifier: ProviderStatusItemIdentity] = [:]

    // Dictionary to hold status items keyed by profile ID (multi-profile mode)
    private var multiProfileStatusItems: [UUID: NSStatusItem] = [:]

    // Once more than `overflowThreshold` profiles are selected for
    // multi-profile display, `splitForOverflow` keeps only the first
    // `overflowThreshold - 1` individual (one fewer profile than the
    // threshold, so the "+N" item itself effectively takes the last slot);
    // the rest collapse into this single overflow item so the menu bar
    // doesn't fill up with one item per profile.
    private var overflowStatusItem: NSStatusItem?
    private(set) var overflowProfileIDs: [UUID] = []

    /// Governs how (and whether) excess profiles collapse into the overflow
    /// item. Defaults to the pre-existing fixed-threshold behavior so
    /// nothing changes for a caller (or a test) that never sets this
    /// explicitly; `MenuBarManager` is the production caller that reads the
    /// persisted user setting — which itself defaults to `.automatic` — and
    /// assigns it here before every layout recompute.
    var overflowMode: MenuBarOverflowMode = .afterCount(
        StatusBarUIManager.overflowThreshold
    )

    /// Supplies live screen/foreign-item measurements for `.automatic`
    /// mode. Injectable so tests can supply a fake without touching real
    /// AppKit or window-server state.
    var spaceProbe: MenuBarSpaceProbing = MenuBarSpaceProbe()

    /// Supplies the running-application bundle identifiers `.automatic`
    /// mode checks against `MenuBarManagerDetection.knownManagers`.
    /// Injectable for the same reason as `spaceProbe`: a test must be able
    /// to simulate "Ice is running" without any real process actually
    /// running.
    var runningApplicationsProvider:
        RunningApplicationBundleIdentifiersProviding =
            NSWorkspaceRunningApplications()

    /// Estimated width for a profile item that has no `NSStatusItem` yet
    /// (e.g. a profile just added to the selection), so `.automatic` mode
    /// has *something* to measure before the item's real window exists.
    /// Sized to this app's typical rendered icon width.
    static let estimatedProfileItemWidth: CGFloat = 40

    /// Fallback difference between a status item's window width and its
    /// image width, used only before `calibratedButtonPadding()` has ever
    /// found a real item to measure (e.g. the very first cold layout pass).
    static let fallbackButtonPadding: CGFloat = 6

    /// Last padding value `calibratedButtonPadding()` measured from a real
    /// status item, kept around so a later cold pass (no item currently has
    /// both a window and an image) can still use a real measurement instead
    /// of falling all the way back to `fallbackButtonPadding`.
    private var lastKnownButtonPadding: CGFloat?

    // Current display mode
    private var isMultiProfileMode: Bool = false

    private var appearanceObservers: [NSKeyValueObservation] = []
    private var appearanceDebounceTimer: Timer?

    // Image cache to avoid redundant button.image assignments (which trigger KVO)
    private var lastImageData: [ObjectIdentifier: Data] = [:]

    // Icon renderer for creating menu bar images
    private let renderer = MenuBarIconRenderer()

    weak var delegate: StatusBarUIManagerDelegate?

    // MARK: - Initialization

    init() {}

    /// Applies the exact left/right action wiring shared by every production
    /// status item. Keeping this in one place also lets the isolated native UI
    /// suite exercise the same AppKit event contract without creating a
    /// second menu implementation.
    static func configureActionButton(
        _ button: NSButton,
        target: AnyObject,
        action: Selector
    ) {
        button.action = action
        button.target = target
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// `attention` appends the same credential-specific fact the popover
    /// header verdict states (`popover.normalized.health.claude_ai_sign_in_
    /// problem` / `…claude_code_sign_in_problem`), so the wording names the
    /// problem rather than the dot that represents it — the one thing
    /// VoiceOver and a tooltip have in common with the visual marker is what
    /// they must say, not how they say it.
    ///
    /// It names WHICH credential even though the marker now draws two
    /// different shapes, because the shape reaches nobody who arrives here
    /// through a tooltip or VoiceOver. For them the words ARE the marker,
    /// and "sign-in needs attention" on its own sends half of them to the
    /// wrong Settings screen.
    static func profileAccessibilityLabel(
        _ baseLabel: String,
        isActive: Bool,
        attention: MenuBarAttentionSignal.Credential? = nil
    ) -> String {
        let label = String(
            format: ProviderUILocalization.text(
                isActive
                    ? "menubar.accessibility.profile.active"
                    : "menubar.accessibility.profile.inactive",
                fallback: isActive
                    ? "%@, active profile"
                    : "%@, inactive profile"
            ),
            baseLabel
        )
        guard let attention else { return label }
        return label + ", " + attentionStateText(attention)
    }

    /// The spoken and hovered form of the marker, single-sourced so the
    /// tooltip and the accessibility label cannot drift apart.
    static func attentionStateText(
        _ credential: MenuBarAttentionSignal.Credential
    ) -> String {
        switch credential {
        case .claudeAI:
            return ProviderUILocalization.text(
                "menubar.accessibility.state.claude_ai_sign_in_attention",
                fallback: "Claude.ai sign-in needs attention"
            )
        case .claudeCode:
            return ProviderUILocalization.text(
                "menubar.accessibility.state.claude_code_sign_in_attention",
                fallback: "Claude Code sign-in needs attention"
            )
        }
    }

    /// What the label says about the session figure. A dash on screen and a
    /// spoken "0% used" would be the same lie told twice, so the unknown
    /// state is stated in words rather than rounded into a number.
    static func sessionAccessibilityValue(
        for render: ProfileMenuBarRender
    ) -> String {
        if render.unknownWindows.contains(.session) {
            // Reuses the existing no-data vocabulary rather than inventing a
            // ninth translation of the same sentence.
            return ProviderUILocalization.text(
                "menubar.accessibility.state.no_data",
                fallback: "no usage data"
            )
        }
        return "\(Int(render.sessionDisplay.rounded()))% "
            + usageModeText(showRemaining: render.showRemaining)
    }

    static func usageModeText(showRemaining: Bool) -> String {
        ProviderUILocalization.text(
            showRemaining
                ? "popover.normalized.value.remaining"
                : "popover.normalized.value.used",
            fallback: showRemaining ? "remaining" : "used"
        )
    }

    /// The name of one of the three metrics a single-profile menu bar can
    /// show, taken from the catalogue the provider-neutral path already
    /// speaks (`ProviderAppearance.claudeCatalog` builds its descriptors from
    /// these same three keys, and the single non-Claude status item says them
    /// through `providerMetricVisualLabel`).
    ///
    /// Single-profile mode puts up to three status items on screen at once,
    /// one per enabled metric. Without the name all three would announce the
    /// same sentence and identify none of them, which is worse than the
    /// silence it replaces. Borrowing the existing names rather than adding a
    /// fourth vocabulary also keeps someone from hearing "Session" for a
    /// figure in one mode and a different word for the same figure in the
    /// other.
    static func legacyMetricName(
        for metricType: MenuBarMetricType
    ) -> String {
        switch metricType {
        case .session:
            return ProviderUILocalization.text(
                "appearance.metric.name.session",
                fallback: "Session"
            )
        case .week:
            return ProviderUILocalization.text(
                "appearance.metric.name.week",
                fallback: "Week"
            )
        case .api:
            return ProviderUILocalization.text(
                "appearance.metric.name.credits",
                fallback: "Credits"
            )
        }
    }

    /// What the single-profile label says about one metric's figure.
    ///
    /// A percentage for all three, credits included, where the icon itself
    /// draws a currency amount: three items read in a row are comparable by
    /// ear only if they answer the same question, and the percentage is the
    /// figure the rest of the app already attributes to this metric
    /// (`ProviderAppearance.claudeCatalog` reports `usagePercentage` for it).
    ///
    /// A window with no reading behind it is stated in words, the same
    /// judgement `sessionAccessibilityValue` makes: a fabricated "0% used"
    /// is a claim about an account nobody measured. Note that the legacy
    /// single-profile ICON does still draw `0%` there —
    /// `MenuBarIconRenderer.getMetricData` has no unknown-window handling,
    /// unlike the multi-profile renderers — so for that one case the spoken
    /// label is more honest than the picture beside it. Correcting the
    /// picture means changing what is drawn, which is a separate change;
    /// repeating its mistake here would only have made the defect harder to
    /// find.
    static func legacyMetricAccessibilityValue(
        for metricType: MenuBarMetricType,
        usage: ClaudeUsage,
        apiUsage: APIUsage?,
        showRemaining: Bool
    ) -> String {
        let usedPercentage: Double?
        switch metricType {
        case .session:
            usedPercentage = usage.readableSessionPercentage
        case .week:
            usedPercentage = usage.readableWeeklyPercentage
        case .api:
            // No API reading at all is the one unknown the icon also
            // refuses: it draws "N/A" rather than a number.
            usedPercentage = apiUsage?.usagePercentage
        }
        guard let usedPercentage else {
            return ProviderUILocalization.text(
                "menubar.accessibility.state.no_data",
                fallback: "no usage data"
            )
        }
        let display = UsageStatusCalculator.getDisplayPercentage(
            usedPercentage: usedPercentage,
            showRemaining: showRemaining
        )
        return "\(Int(display.rounded()))% "
            + usageModeText(showRemaining: showRemaining)
    }

    /// The whole label and tooltip for one single-profile Claude status item.
    ///
    /// These items had neither, and never have: `updateAllButtons` and
    /// `updateButton` set an image and stopped. Every other status item in
    /// the app names itself, so a person running one Claude profile — the
    /// common case — saw the attention dot and had nothing anywhere telling
    /// them which of the profile's two credentials it was about. Hovering
    /// said nothing and VoiceOver said nothing, which for that person is the
    /// same as the feature not existing — the mark's own shape says which
    /// credential failed, and a shape reaches neither of them.
    ///
    /// Assembled in the multi-profile label's order — provider, profile,
    /// figure, then state — so the two modes read alike, with the metric
    /// name inserted before the figure because this mode shows up to three
    /// items at once.
    static func legacyMetricAccessibilityLabel(
        for metricType: MenuBarMetricType,
        profileName: String?,
        usage: ClaudeUsage,
        apiUsage: APIUsage?,
        showRemaining: Bool,
        attention: MenuBarAttentionSignal.Credential?
    ) -> String {
        let base = legacyLabelPrefix(profileName: profileName)
            + legacyMetricName(for: metricType) + ", "
            + legacyMetricAccessibilityValue(
                for: metricType,
                usage: usage,
                apiUsage: apiUsage,
                showRemaining: showRemaining
            )
        return profileAccessibilityLabel(
            base,
            isActive: true,
            attention: attention
        )
    }

    /// The label for the default-logo item, which stands in when the profile
    /// has no usage credentials or every metric is switched off.
    ///
    /// It gets a name for the same reason the metric items do — an
    /// unlabelled status item is announced as nothing at all — and this is
    /// the one item a person meets before the app has any data, which is
    /// exactly when they are trying to work out what it is.
    ///
    /// It never carries the attention wording, and takes no credential to
    /// carry. That branch returns before `marked` and so draws no dot; a
    /// spoken complaint with no visible counterpart would be this surface
    /// making a claim the icon does not.
    static func legacyDefaultLogoAccessibilityLabel(
        profileName: String?
    ) -> String {
        let base = legacyLabelPrefix(profileName: profileName)
            + ProviderUILocalization.text(
                "menubar.accessibility.state.no_data",
                fallback: "no usage data"
            )
        return profileAccessibilityLabel(base, isActive: true)
    }

    /// "Claude, Work, " — the provider and, when there is one, the profile.
    /// The name is omitted rather than replaced when no profile is loaded,
    /// so the label degrades to "Claude, …" instead of announcing an empty
    /// clause.
    private static func legacyLabelPrefix(profileName: String?) -> String {
        let provider = ProviderAppearance.forProvider(.claude).displayName
        guard let profileName, !profileName.isEmpty else {
            return "\(provider), "
        }
        return "\(provider), \(profileName), "
    }

    static func autosaveName(
        for metricID: MenuBarMetricID,
        isLegacyPlaceholder: Bool = false
    ) -> String {
        if isLegacyPlaceholder {
            return "claude-usage-tracker.session"
        }
        if let legacy = metricID.legacyMetricType {
            return "claude-usage-tracker.\(legacy.rawValue)"
        }
        return "claude-usage-tracker.metric.\(metricID.stableValue)"
    }

    static func desiredProviderMetricIDs(
        for presentation: ProviderMenuPresentation
    ) -> [MenuBarMetricID] {
        ProviderStatusItemReconciliation.singleEntries(
            for: presentation
        ).map(\.statusMetricID)
    }

    /// A dynamic status item must remain identifiable without relying on
    /// color or the optional long-name setting. Include the provider and
    /// selected window; qualify duplicate window names with their group.
    static func providerMetricVisualLabel(
        for metric: ProviderMetricPresentation?,
        in presentation: ProviderMenuPresentation,
        showLongProviderName: Bool
    ) -> String {
        let provider = showLongProviderName
            ? presentation.appearance.displayName
            : presentation.appearance.compactBadge
        guard let metric else { return provider }
        let hasDuplicateWindowName = presentation.metrics.contains {
            $0.id != metric.id
                && $0.descriptor.metricName
                    == metric.descriptor.metricName
        }
        let window = hasDuplicateWindowName
            ? "\(metric.descriptor.groupName)/"
                + metric.descriptor.metricName
            : metric.descriptor.metricName
        return "\(provider)·\(window)"
    }

    // MARK: - Setup

    /// Sets up status bar items based on configuration
    func setup(target: AnyObject, action: Selector, config: MenuBarIconConfiguration) {
        // Remove all existing items first
        cleanup()

        // Check if there are any enabled metrics
        if config.enabledMetrics.isEmpty {
            // No credentials/metrics - show default app logo
            let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            // Stable identifier so Bartender and similar tools can reliably track this item
            statusItem.autosaveName = Self.autosaveName(
                for: .claudeSession,
                isLegacyPlaceholder: true
            )
            // Override a persisted hidden state from a prior Command-drag.
            statusItem.isVisible = true

            if let button = statusItem.button {
                Self.configureActionButton(
                    button,
                    target: target,
                    action: action
                )
                // Set a temporary placeholder - will be updated with actual logo
                button.title = ""
            } else {
                LoggingService.shared.logWarning("Status bar button is nil - screens: \(NSScreen.screens.count)")
            }

            // Use a special key to identify the default icon
            statusItems[.claudeSession] = statusItem
            LoggingService.shared.logUIEvent("Status bar initialized with default app logo (no credentials)")
        } else {
            // Create status items for enabled metrics
            for metricConfig in config.enabledMetrics {
                let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                // Stable identifier so Bartender and similar tools can reliably track this item
                statusItem.autosaveName = Self.autosaveName(
                    for: metricConfig.metricID
                )
                statusItem.isVisible = true

                if let button = statusItem.button {
                    Self.configureActionButton(
                        button,
                        target: target,
                        action: action
                    )
                } else {
                    LoggingService.shared.logWarning(
                        "Status bar button is nil for "
                            + "\(metricConfig.metricID.stableValue) - "
                            + "screens: \(NSScreen.screens.count)"
                    )
                }

                statusItems[metricConfig.metricID] = statusItem
            }

            LoggingService.shared.logUIEvent("Status bar initialized with \(config.enabledMetrics.count) metrics")
        }
        singleMetricOrder = config.enabledMetrics.isEmpty
            ? [.claudeSession]
            : config.enabledMetrics.map(\.metricID)

        observeAppearanceChanges()
    }

    /// Updates status bar items based on new configuration (incremental approach)
    func updateConfiguration(target: AnyObject, action: Selector, config: MenuBarIconConfiguration) {
        // Determine what the new set of items should be
        let newMetricTypes: Set<MenuBarMetricID>
        if config.enabledMetrics.isEmpty {
            // No credentials/metrics - show default app logo using .session as placeholder
            newMetricTypes = [.claudeSession]
        } else {
            newMetricTypes = Set(config.enabledMetrics.map(\.metricID))
        }

        let currentMetricTypes = Set(statusItems.keys)

        // Step 1: Remove items that are no longer needed
        let itemsToRemove = currentMetricTypes.subtracting(newMetricTypes)
        for metricType in itemsToRemove {
            if let statusItem = statusItems[metricType] {
                if let button = statusItem.button {
                    lastImageData.removeValue(
                        forKey: ObjectIdentifier(button)
                    )
                    statusItemIdentities.removeValue(
                        forKey: ObjectIdentifier(button)
                    )
                    button.image = nil
                    button.action = nil
                    button.target = nil
                }
                NSStatusBar.system.removeStatusItem(statusItem)
                LoggingService.shared.logUIEvent(
                    "Removed status item for \(metricType.stableValue)"
                )
            }
            statusItems.removeValue(forKey: metricType)
        }

        // Step 2: Add items that are new
        let itemsToAdd = newMetricTypes.subtracting(currentMetricTypes)
        for metricType in itemsToAdd {
            let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            // Stable identifier so Bartender and similar tools can reliably track this item
            statusItem.autosaveName = Self.autosaveName(
                for: metricType,
                isLegacyPlaceholder:
                    config.enabledMetrics.isEmpty
                        && metricType == .claudeSession
            )
            statusItem.isVisible = true

            if let button = statusItem.button {
                Self.configureActionButton(
                    button,
                    target: target,
                    action: action
                )
                if metricType == .claudeSession {
                    // Default logo placeholder
                    button.title = ""
                }
            }

            statusItems[metricType] = statusItem
            LoggingService.shared.logUIEvent(
                "Created status item for \(metricType.stableValue)"
            )
        }

        // Step 3: Items that already exist don't need recreation, just keep them
        // Their images will be updated by updateAllButtons() or updateButton()
        singleMetricOrder = config.enabledMetrics.isEmpty
            ? [.claudeSession]
            : config.enabledMetrics.map(\.metricID)

        LoggingService.shared.logUIEvent("Status bar configuration updated: removed=\(itemsToRemove.count), added=\(itemsToAdd.count), kept=\(currentMetricTypes.intersection(newMetricTypes).count)")
    }

    /// Reconciles and renders a provider-neutral single-profile catalog.
    /// Dynamic metrics are keyed exclusively by `MenuBarMetricID`; the legacy
    /// `metricType` compatibility facade is intentionally not used here.
    func updateProviderSingle(
        presentation: ProviderMenuPresentation,
        target: AnyObject,
        action: Selector,
        config: MenuBarIconConfiguration
    ) {
        // A display-mode transition must remove the one-item-per-profile
        // collection before reconciling the one-item-per-metric collection.
        if isMultiProfileMode {
            cleanup()
        }
        isMultiProfileMode = false
        let desiredMetricIDs = presentation.metrics.map(\.id)
        let reconciledEntries =
            ProviderStatusItemReconciliation.singleEntries(
                for: presentation
            )
        let reconciledIDs = reconciledEntries.map(\.statusMetricID)
        let identities = Dictionary(
            uniqueKeysWithValues: reconciledEntries.map {
                ($0.statusMetricID, $0.identity)
            }
        )
        let desiredIDs = Set(reconciledIDs)
        let currentIDs = Set(statusItems.keys)

        for metricID in currentIDs.subtracting(desiredIDs) {
            guard let item = statusItems.removeValue(forKey: metricID)
            else { continue }
            if let button = item.button {
                lastImageData.removeValue(forKey: ObjectIdentifier(button))
                statusItemIdentities.removeValue(
                    forKey: ObjectIdentifier(button)
                )
                button.image = nil
                button.action = nil
                button.target = nil
            }
            NSStatusBar.system.removeStatusItem(item)
        }

        let idsToAdd = desiredIDs.subtracting(currentIDs)
        for metricID in reconciledIDs where idsToAdd.contains(metricID) {
            let item = NSStatusBar.system.statusItem(
                withLength: NSStatusItem.variableLength
            )
            item.autosaveName = desiredMetricIDs.isEmpty
                ? "claude-usage-tracker.provider."
                    + "\(presentation.identity.profileID.uuidString).default"
                : Self.autosaveName(for: metricID)
            item.isVisible = true
            if let button = item.button {
                Self.configureActionButton(
                    button,
                    target: target,
                    action: action
                )
            }
            statusItems[metricID] = item
        }
        singleMetricOrder = reconciledIDs

        for (index, metricID) in (
            reconciledIDs
        ).enumerated() {
            guard let item = statusItems[metricID],
                  let button = item.button else {
                continue
            }
            item.autosaveName = desiredMetricIDs.isEmpty
                ? "claude-usage-tracker.provider."
                    + "\(presentation.identity.profileID.uuidString).default"
                : Self.autosaveName(for: metricID)
            let metric = presentation.metrics.first { $0.id == metricID }
            statusItemIdentities[ObjectIdentifier(button)] =
                identities[metricID]
            let menuBarIsDark = button.effectiveAppearance.bestMatch(
                from: [.darkAqua, .aqua]
            ) == .darkAqua
            let metricConfig = metric.flatMap {
                config.config(for: $0.id)
            } ?? MetricIconConfig(
                metricID: metricID,
                isEnabled: metric != nil
            )
            let renderedImage = renderer.createProviderMetricImage(
                metric,
                appearance: presentation.appearance,
                metricConfig: metricConfig,
                globalConfig: config,
                isDarkMode: menuBarIsDark,
                showProviderLabel: true,
                visualLabel: Self.providerMetricVisualLabel(
                    for: metric,
                    in: presentation,
                    showLongProviderName: config.showIconNames
                ),
                placeholderState: presentation.state
            )
            let badgeStyle = ProfileManager.shared.providerBadgeStyle
            let image = renderer.applyProviderBadge(
                to: renderedImage,
                providerID: presentation.identity.providerID,
                style: badgeStyle,
                isDarkMode: menuBarIsDark
            )
            image.isTemplate = config.colorMode == .monochrome
                && !config.showPaceMarker
                && !badgeStyle.showsTint
            setButtonImage(button, image: image)
            let accessibility = metric?.accessibilityLabel
                ?? "\(presentation.appearance.displayName), "
                    + presentation.state.accessibilityText
            let activeAccessibility =
                Self.profileAccessibilityLabel(
                    accessibility,
                    isActive: true
                )
            button.setAccessibilityLabel(activeAccessibility)
            button.toolTip = activeAccessibility
            button.tag = index
        }

        if appearanceObservers.isEmpty {
            observeAppearanceChanges()
        }
    }

    /// Associates characterized legacy Claude status items with their captured
    /// profile identity without changing their renderer or pixel output.
    func bindLegacySingleProfile(_ profile: Profile) {
        for (metricID, statusItem) in statusItems {
            guard let button = statusItem.button else { continue }
            statusItemIdentities[ObjectIdentifier(button)] =
                ProviderStatusItemIdentity(
                    profileID: profile.id,
                    providerID: profile.providerID,
                    providerRevision: profile.providerRevision,
                    metricID: metricID
                )
        }
    }

    func statusIdentity(
        for sender: NSStatusBarButton?
    ) -> ProviderStatusItemIdentity? {
        guard let sender else { return nil }
        return statusItemIdentities[ObjectIdentifier(sender)]
    }

    func autosaveName(
        for sender: NSStatusBarButton?
    ) -> String? {
        guard let sender else { return nil }
        return statusItems.values.first {
            $0.button === sender
        }?.autosaveName
            ?? multiProfileStatusItems.values.first {
                $0.button === sender
            }?.autosaveName
            ?? (overflowStatusItem?.button === sender
                ? overflowStatusItem?.autosaveName
                : nil)
    }

    var orderedSingleButtonsForTesting: [NSStatusBarButton] {
        singleMetricOrder.compactMap {
            statusItems[$0]?.button
        }
    }

    /// The overflow item's own identity, independent of its current
    /// visibility (unlike `overflowButton`, which is `nil` while hidden).
    /// Exposed so a test can confirm an empty-then-non-empty overflow cycle
    /// reuses the SAME `NSStatusItem` (see `updateOverflowItem`) rather than
    /// emptying it out and recreating a new one with a fresh AppKit window
    /// ID — the exact churn `MenuBarManager.swift:1579` warns defeats a menu
    /// bar manager's tracking.
    var overflowItemIdentityForTesting: ObjectIdentifier? {
        overflowStatusItem.map(ObjectIdentifier.init)
    }

    /// A tracked multi-profile item's identity, independent of whether it is
    /// currently individual or collapsed into overflow (unlike
    /// `button(for:)`, which is `nil` while hidden). Exposed for the same
    /// reason as `overflowItemIdentityForTesting`: confirming a profile that
    /// crosses the overflow boundary and back keeps its original item.
    func multiProfileItemIdentityForTesting(
        _ profileID: UUID
    ) -> ObjectIdentifier? {
        multiProfileStatusItems[profileID].map(ObjectIdentifier.init)
    }

    /// Whether `cleanup(isApplicationTerminating:)` should hand a given item
    /// to `NSStatusBar.removeStatusItem(_:)` during teardown. Pulled out as
    /// its own pure function — rather than three duplicated
    /// `if !isApplicationTerminating` checks — so the one decision that
    /// actually matters here (termination teardown vs. a genuine removal)
    /// has a single, directly testable source of truth.
    static func shouldRemoveStatusItem(isApplicationTerminating: Bool) -> Bool {
        !isApplicationTerminating
    }

    /// Tears down every status item this manager owns.
    ///
    /// - Parameter isApplicationTerminating: When `true` (the app-quit
    ///   path), every item's button wiring is released and our own
    ///   bookkeeping is cleared, but `NSStatusBar.removeStatusItem(_:)` is
    ///   deliberately NOT called. Removing an item discards AppKit's
    ///   persisted `"NSStatusItem Preferred Position <autosaveName>"` entry
    ///   for it — proven experimentally: injecting that key and relaunching
    ///   survives untouched, but injecting it and then quitting cleanly
    ///   deletes it. Every other menu bar app on the same machine (Alfred,
    ///   VLC, Claude Desktop, Notion, Duplicacy) has exactly one such key and
    ///   never calls `removeStatusItem` on quit — the item simply vanishes
    ///   when the process exits, and AppKit still has the position on next
    ///   launch. Calling `removeStatusItem` here was silently wiping every
    ///   user's menu bar arrangement (as tracked by Bartender/Ice/Thaw) on
    ///   every restart. Defaults to `false` so every other caller (config
    ///   reload, display-mode switch, multi-profile setup) keeps today's
    ///   full teardown-and-rebuild behavior — those are genuine removals,
    ///   not a process exit.
    func cleanup(isApplicationTerminating: Bool = false) {
        appearanceObservers.forEach { $0.invalidate() }
        appearanceObservers.removeAll()
        appearanceDebounceTimer?.invalidate()
        appearanceDebounceTimer = nil

        let shouldRemove = Self.shouldRemoveStatusItem(
            isApplicationTerminating: isApplicationTerminating
        )

        // Clean up single profile status items
        for (_, statusItem) in statusItems {
            // Clear button references first
            if let button = statusItem.button {
                button.image = nil
                button.action = nil
                button.target = nil
            }
            // Then remove from status bar — unless the app is quitting; see
            // the doc comment above.
            if shouldRemove {
                NSStatusBar.system.removeStatusItem(statusItem)
            }
        }
        statusItems.removeAll()
        singleMetricOrder.removeAll()
        statusItemIdentities.removeAll()

        // Clean up multi-profile status items
        for (_, statusItem) in multiProfileStatusItems {
            if let button = statusItem.button {
                button.image = nil
                button.action = nil
                button.target = nil
            }
            if shouldRemove {
                NSStatusBar.system.removeStatusItem(statusItem)
            }
        }
        multiProfileStatusItems.removeAll()

        // Clean up the overflow status item, if any
        if let overflowItem = overflowStatusItem {
            if let button = overflowItem.button {
                lastImageData.removeValue(forKey: ObjectIdentifier(button))
                button.image = nil
                button.action = nil
                button.target = nil
            }
            if shouldRemove {
                NSStatusBar.system.removeStatusItem(overflowItem)
            }
        }
        overflowStatusItem = nil
        overflowProfileIDs.removeAll()

        isMultiProfileMode = false

        LoggingService.shared.logUIEvent(
            isApplicationTerminating
                ? "Status bar torn down for app termination "
                    + "(menu bar positions preserved)"
                : "Status bar cleaned up"
        )
    }

    // MARK: - Multi-Profile Mode

    /// Sets up status bar for multi-profile display mode
    func setupMultiProfile(profiles: [Profile], target: AnyObject, action: Selector) {
        // Clean up existing items
        cleanup()

        isMultiProfileMode = true

        // Filter to only profiles selected for display
        let selectedProfiles = profiles.filter {
            $0.isSelectedForDisplay && !$0.deletionInProgress
        }

        if selectedProfiles.isEmpty {
            // No profiles selected - show default logo
            let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            // Stable identifier so Bartender and similar tools can reliably track this item
            statusItem.autosaveName = "claude-usage-tracker.multi.default"
            statusItem.isVisible = true
            if let button = statusItem.button {
                Self.configureActionButton(
                    button,
                    target: target,
                    action: action
                )
                button.title = ""
            } else {
                LoggingService.shared.logWarning("Multi-profile status bar button is nil - screens: \(NSScreen.screens.count)")
            }
            // Use a fixed placeholder UUID (stable across calls) for the default logo item
            multiProfileStatusItems[Self.multiProfileDefaultPlaceholderID] = statusItem
            LoggingService.shared.logUIEvent("Multi-profile: No profiles selected, showing default logo")
        } else {
            // Above the overflow threshold, only the first few profiles get
            // their own status item; the rest collapse into one overflow
            // item (see `overflowPlan(for:mode:currentCollapsedCount:spaceInput:)`).
            let plan = currentOverflowPlan(for: selectedProfiles)

            // Create one status item per individually-shown profile
            for profile in plan.individual {
                let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                // Stable identifier so Bartender and similar tools can reliably track this item
                statusItem.autosaveName = "claude-usage-tracker.profile.\(profile.id.uuidString)"
                statusItem.isVisible = true

                if let button = statusItem.button {
                    Self.configureActionButton(
                        button,
                        target: target,
                        action: action
                    )
                } else {
                    LoggingService.shared.logWarning("Multi-profile status bar button is nil for \(profile.name) - screens: \(NSScreen.screens.count)")
                }

                multiProfileStatusItems[profile.id] = statusItem
                if let button = statusItem.button {
                    statusItemIdentities[ObjectIdentifier(button)] =
                        ProviderStatusItemIdentity(
                            profileID: profile.id,
                            providerID: profile.providerID,
                            providerRevision: profile.providerRevision,
                            metricID: nil
                        )
                }
            }

            updateOverflowItem(
                for: plan.overflow,
                target: target,
                action: action
            )

            LoggingService.shared.logUIEvent(
                "Multi-profile: Created \(plan.individual.count) status items"
                    + (plan.overflow.isEmpty
                        ? ""
                        : " + overflow item (\(plan.overflow.count))")
            )
        }

        observeAppearanceChanges()
    }

    /// Pure reconciliation decision behind `updateMultiProfileConfiguration`:
    /// which profile IDs' status items must be fully removed vs. created,
    /// given which profiles are still selected for display at all versus
    /// which currently land in the individual (non-overflow) half of the
    /// plan. Isolated from any `NSStatusItem`/`NSStatusBar` call so the
    /// removal-vs-keep-alive decision — the crux of not destroying a saved
    /// menu bar position — can be unit tested without a real status bar.
    ///
    /// A profile ID present in `currentIDs` but absent from
    /// `stillSelectedIDs` is a genuine removal (the user deselected or
    /// deleted that profile) and gets `removeStatusItem`. A profile ID that
    /// remains in `stillSelectedIDs` but crosses into or out of
    /// `individualIDs` (the overflow boundary moving as counts or available
    /// space change) is NOT a removal at all — its existing item is kept and
    /// only hidden/shown, exactly like the overflow item itself.
    struct MultiProfileItemReconciliation: Equatable {
        let idsToRemove: Set<UUID>
        let idsToAdd: Set<UUID>
    }

    static func reconcileMultiProfileItems(
        currentIDs: Set<UUID>,
        stillSelectedIDs: Set<UUID>
    ) -> MultiProfileItemReconciliation {
        MultiProfileItemReconciliation(
            idsToRemove: currentIDs.subtracting(stillSelectedIDs),
            idsToAdd: stillSelectedIDs.subtracting(currentIDs)
        )
    }

    /// Updates the selected multi-profile status items without recreating retained items.
    /// This preserves macOS item identity and the ordering remembered by menu-bar tools.
    func updateMultiProfileConfiguration(profiles: [Profile], target: AnyObject, action: Selector) {
        guard isMultiProfileMode else {
            setupMultiProfile(profiles: profiles, target: target, action: action)
            return
        }

        let selectedProfiles = profiles.filter {
            $0.isSelectedForDisplay && !$0.deletionInProgress
        }
        let plan = currentOverflowPlan(for: selectedProfiles)
        let individualIDs = Set(plan.individual.map(\.id))
        // Every still-selected profile keeps an item alive — visible or
        // hidden behind the overflow badge — across this update; only a
        // profile no longer selected at all loses its item. A profile
        // crosses between individual and overflow on almost every
        // recompute as counts or available space change, and recreating the
        // item on every crossing would both discard its AppKit-persisted
        // position (see `cleanup()`) and mint a new window ID that defeats
        // a menu bar manager's tracking of it (see the note at
        // `MenuBarManager.swift:1579`).
        let stillSelectedIDs: Set<UUID> = selectedProfiles.isEmpty
            ? [Self.multiProfileDefaultPlaceholderID]
            : Set(selectedProfiles.map(\.id))
        let currentIDs = Set(multiProfileStatusItems.keys)
        let reconciliation = Self.reconcileMultiProfileItems(
            currentIDs: currentIDs,
            stillSelectedIDs: stillSelectedIDs
        )

        for profileID in reconciliation.idsToRemove {
            if let statusItem = multiProfileStatusItems.removeValue(forKey: profileID) {
                if let button = statusItem.button {
                    lastImageData.removeValue(forKey: ObjectIdentifier(button))
                    statusItemIdentities.removeValue(
                        forKey: ObjectIdentifier(button)
                    )
                    button.image = nil
                    button.action = nil
                    button.target = nil
                }
                NSStatusBar.system.removeStatusItem(statusItem)
                LoggingService.shared.logUIEvent("Multi-profile: Removed status item for \(profileID)")
            }
        }

        if selectedProfiles.isEmpty,
           reconciliation.idsToAdd.contains(Self.multiProfileDefaultPlaceholderID) {
            let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem.autosaveName = "claude-usage-tracker.multi.default"
            statusItem.isVisible = true
            if let button = statusItem.button {
                Self.configureActionButton(
                    button,
                    target: target,
                    action: action
                )
                button.title = ""
            }
            multiProfileStatusItems[Self.multiProfileDefaultPlaceholderID] = statusItem
            LoggingService.shared.logUIEvent("Multi-profile: Added default logo status item")
        } else {
            // Preserve profile order for first-time additions while retaining existing item identity.
            for profile in selectedProfiles
            where reconciliation.idsToAdd.contains(profile.id) {
                let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                statusItem.autosaveName = "claude-usage-tracker.profile.\(profile.id.uuidString)"
                // Start in the correct visibility immediately rather than
                // visible-then-hidden, in case this brand-new profile lands
                // straight in overflow (e.g. several profiles added at once).
                statusItem.isVisible = individualIDs.contains(profile.id)
                if let button = statusItem.button {
                    Self.configureActionButton(
                        button,
                        target: target,
                        action: action
                    )
                }
                multiProfileStatusItems[profile.id] = statusItem
                if let button = statusItem.button {
                    statusItemIdentities[ObjectIdentifier(button)] =
                        ProviderStatusItemIdentity(
                            profileID: profile.id,
                            providerID: profile.providerID,
                            providerRevision: profile.providerRevision,
                            metricID: nil
                        )
                }
                LoggingService.shared.logUIEvent("Multi-profile: Added status item for \(profile.name)")
            }
        }

        // A profile already tracked here may have crossed between the
        // individual and overflow halves of the plan since the last
        // update; toggle visibility rather than recreate the item. The
        // placeholder item has no overflow concept at all and must stay
        // visible.
        for (profileID, item) in multiProfileStatusItems
        where profileID != Self.multiProfileDefaultPlaceholderID {
            item.isVisible = individualIDs.contains(profileID)
        }

        updateOverflowItem(
            for: plan.overflow,
            target: target,
            action: action
        )

        LoggingService.shared.logUIEvent(
            "Multi-profile config updated: removed=\(reconciliation.idsToRemove.count), "
                + "added=\(reconciliation.idsToAdd.count), "
                + "kept=\(currentIDs.intersection(stillSelectedIDs).count)"
        )
    }

    /// Computes the individual/overflow split for `selectedProfiles`
    /// according to `overflowMode`, measuring current item widths via
    /// `spaceProbe` and the running-application list via
    /// `runningApplicationsProvider` when `.automatic` is in effect.
    /// `.never` and `.afterCount` never touch either at all.
    private func currentOverflowPlan(
        for selectedProfiles: [Profile]
    ) -> (individual: [Profile], overflow: [Profile]) {
        let spaceInput: MenuBarLayoutInput?
        let runningBundleIdentifiers: [String]
        if case .automatic = overflowMode {
            // Read the running-application list FIRST — it's a cheap
            // in-process `NSWorkspace` query with no Accessibility
            // involvement — so the manager check below can decide whether
            // the expensive gathering beneath it is worth doing at all.
            runningBundleIdentifiers =
                runningApplicationsProvider.runningBundleIdentifiers
            if MenuBarManagerDetection.detectedManager(
                runningBundleIdentifiers: runningBundleIdentifiers
            ) != nil {
                // `overflowPlan(...)`'s `.automatic` guard below always
                // returns "every profile keeps its own item" once a
                // manager is detected, regardless of `spaceInput` — so
                // skip both the width rendering and `spaceProbe
                // .makeLayoutInput(...)` entirely rather than computing an
                // answer only to discard it. This is NOT just an
                // optimization: `makeLayoutInput` performs synchronous
                // Accessibility reads on the main thread, and a menu bar
                // manager (Ice, Thaw, Bartender, ...) is, at the same
                // moment, driving OUR status item windows via synthetic
                // drag events to lay itself out. AX contention between the
                // two was observed to make Thaw's move events miss their
                // response deadline (`EventError.itemResponseTimeout`),
                // locking up Thaw's rearrange UI completely — switching
                // this app to `.never` (which never touches the probe)
                // fixed it outright. Do not reorder this back to "gather
                // input, then decide" — the policy that manager-detected
                // means never-collapse still lives solely in
                // `overflowPlan(...)`'s guard; this only skips collecting
                // input that guard would throw away anyway.
                spaceInput = nil
            } else {
                let config = ProfileManager.shared.multiProfileConfig
                let activeProfileId =
                    ProfileManager.shared.activeClaudeProfileID
                let ourItemWidths = selectedProfiles.map {
                    profile -> CGFloat in
                    guard profile.providerID == .claude else {
                        return itemWidth(
                            for: multiProfileStatusItems[profile.id]
                        ) ?? Self.estimatedProfileItemWidth
                    }
                    return intendedItemWidth(
                        for: profile,
                        config: config,
                        isActive: profile.id == activeProfileId
                    )
                }
                let overflowWidth = itemWidth(for: overflowStatusItem)
                    ?? Self.estimatedProfileItemWidth
                // Only items ALREADY on the menu bar are baked into the
                // status region the probe is about to measure, so only
                // those are added back. `itemWidth(for:)` returning nil
                // means "not rendered yet" — an estimate must NOT be
                // substituted here, or we would credit ourselves space we
                // do not occupy. See
                // `MenuBarLayoutInput.currentlyOnScreenWidth`.
                let currentlyOnScreenWidth =
                    multiProfileStatusItems.values
                        .compactMap { itemWidth(for: $0) }
                        .reduce(0, +)
                    + (itemWidth(for: overflowStatusItem) ?? 0)
                spaceInput = spaceProbe.makeLayoutInput(
                    ourItemWidths: ourItemWidths,
                    overflowItemWidth: overflowWidth,
                    currentlyOnScreenWidth: currentlyOnScreenWidth
                )
            }
        } else {
            spaceInput = nil
            runningBundleIdentifiers = []
        }
        return Self.overflowPlan(
            for: selectedProfiles,
            mode: overflowMode,
            currentCollapsedCount: overflowProfileIDs.count,
            spaceInput: spaceInput,
            runningBundleIdentifiers: runningBundleIdentifiers
        )
    }

    /// The real, measured width of `item`'s button window, or its rendered
    /// image's width as a fallback for the brief window before AppKit
    /// finishes laying the button's own window out. `nil` when neither is
    /// available (most commonly: `item` is `nil`, because no status item
    /// has been created yet for that profile) — or when `item` exists but
    /// is hidden (`isVisible == false`), which now happens when a profile
    /// has collapsed into the overflow item, or the overflow item itself
    /// currently has nothing to show: such an item is kept alive (rather
    /// than removed) so its AppKit-persisted menu bar position survives the
    /// round trip, but it occupies zero menu bar space, so it must not be
    /// credited any width here. This is checked explicitly rather than
    /// assumed from `window.frame.width` collapsing to zero on hide, since
    /// that AppKit behavior isn't something a unit test can verify.
    private func itemWidth(for item: NSStatusItem?) -> CGFloat? {
        guard let item, item.isVisible, let button = item.button else {
            return nil
        }
        if let window = button.window, window.frame.width > 0 {
            return window.frame.width
        }
        if let image = button.image {
            return image.size.width
        }
        return nil
    }

    /// Sum of `itemWidth(for:)` over every tracked multi-profile item,
    /// including ones currently hidden behind the overflow item. Exposed
    /// only for testing the invariant `currentOverflowPlan` depends on: a
    /// profile that has collapsed into overflow keeps its `NSStatusItem`
    /// alive (see `updateMultiProfileConfiguration`) but must contribute
    /// exactly zero width here, the same as if it had been removed outright.
    var multiProfileItemsOnScreenWidthForTesting: CGFloat {
        multiProfileStatusItems.values
            .compactMap { itemWidth(for: $0) }
            .reduce(0, +)
    }

    /// Difference between a status item button's window width and the width
    /// of the image inside it. Calibrated from a real rendered item rather
    /// than hardcoded, so it stays correct if AppKit's status item metrics
    /// change. Scans every current profile item plus the overflow item for
    /// one that has both a laid-out window and an image; caches the last
    /// good value so a later cold pass (nothing currently qualifies) can
    /// still use a real measurement instead of `Self.fallbackButtonPadding`.
    func calibratedButtonPadding() -> CGFloat? {
        let candidates = Array(multiProfileStatusItems.values)
            + [overflowStatusItem].compactMap { $0 }
        for item in candidates {
            guard let button = item.button,
                  let window = button.window,
                  window.frame.width > 0,
                  let image = button.image else {
                continue
            }
            let padding = window.frame.width - image.size.width
            guard padding >= 0 else { continue }
            lastKnownButtonPadding = padding
            return padding
        }
        return lastKnownButtonPadding
    }

    /// The width a profile's status item WILL have once rendered with
    /// `config`, computed by calling the same rendering code the paint path
    /// (`updateMultiProfileButtons`/`renderProfileMenuBar`) uses — rather
    /// than reusing the previous render's measured width (one render
    /// behind) or a hardcoded estimate (off by −65% to +32% across real
    /// configs). Used only to plan the overflow split before a profile's
    /// status item necessarily exists yet.
    func intendedItemWidth(
        for profile: Profile,
        config: MultiProfileDisplayConfig,
        isActive: Bool
    ) -> CGFloat {
        // isDarkMode is always false here: light and dark render identically
        // at 34.5pt for the same config, since appearance only changes
        // colour, not geometry — verified against `renderProfileMenuBar`.
        let render = renderProfileMenuBar(
            for: profile,
            config: config,
            isDarkMode: false,
            isActive: isActive
        )
        return render.image.size.width
            + (calibratedButtonPadding() ?? Self.fallbackButtonPadding)
    }

    /// Reconciles the single overflow status item against the profiles
    /// that should currently collapse into it. Creates the item the first
    /// time there's overflow, removes it once there no longer is, and
    /// otherwise reuses the existing item (preserving its on-screen
    /// position) while refreshing its badge count and the profile list it
    /// represents.
    private func updateOverflowItem(
        for overflowProfiles: [Profile],
        target: AnyObject,
        action: Selector
    ) {
        guard !overflowProfiles.isEmpty else {
            overflowProfileIDs = []
            // Hide rather than remove: the overflow item routinely empties
            // out and refills again (a profile gets deselected, an
            // automatic-mode space measurement changes, ...), and
            // `removeStatusItem` would both discard its AppKit-persisted
            // menu bar position (see `cleanup()`) and force a new window ID
            // on the next recreation, defeating a menu bar manager's
            // tracking of it exactly like the case described at
            // `MenuBarManager.swift:1579`. A hidden item occupies no menu
            // bar space, so leaving it in place costs nothing.
            guard let item = overflowStatusItem, item.isVisible else {
                return
            }
            item.isVisible = false
            LoggingService.shared.logUIEvent(
                "Multi-profile: Hid overflow status item (nothing to show)"
            )
            return
        }

        overflowProfileIDs = overflowProfiles.map(\.id)

        if let item = overflowStatusItem {
            item.isVisible = true
        } else {
            let item = NSStatusBar.system.statusItem(
                withLength: NSStatusItem.variableLength
            )
            item.autosaveName = Self.overflowAutosaveName
            item.isVisible = true
            if let button = item.button {
                Self.configureActionButton(
                    button,
                    target: target,
                    action: action
                )
            }
            overflowStatusItem = item
        }

        renderOverflowBadge(count: overflowProfiles.count)
    }

    /// Draws the "+N" badge for the overflow item directly, rather than
    /// routing through `MenuBarIconRenderer`'s much larger per-metric icon
    /// surface for one small combined-count glyph. Follows the same
    /// nil-safe font handling used throughout this app's icon drawing:
    /// `NSFont` factory methods are declared non-optional but can
    /// transiently bridge back `nil`, so both the preferred and the
    /// fallback font are captured through an explicit `NSFont?` before use
    /// — never insert a nil font into an attributes dictionary.
    private func renderOverflowBadge(count: Int) {
        guard let button = overflowStatusItem?.button else { return }
        let menuBarIsDark = button.effectiveAppearance.bestMatch(
            from: [.darkAqua, .aqua]
        ) == .darkAqua
        let foreground: NSColor = menuBarIsDark ? .white : .black
        let text = "+\(count)" as NSString

        let preferredFont: NSFont? = NSFont.monospacedDigitSystemFont(
            ofSize: 11,
            weight: .semibold
        )
        let fallbackFont: NSFont? = NSFont.systemFont(ofSize: 11)
        let image: NSImage
        if let font = preferredFont ?? fallbackFont {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: foreground
            ]
            let textSize = text.size(withAttributes: attributes)
            image = NSImage(
                size: NSSize(width: textSize.width + 6, height: 18)
            )
            image.lockFocus()
            text.draw(
                at: NSPoint(x: 3, y: (18 - textSize.height) / 2),
                withAttributes: attributes
            )
            image.unlockFocus()
        } else {
            // Even the system-font fallback is unavailable; skip the
            // glyph rather than crash rendering an unlabeled badge.
            image = NSImage(size: NSSize(width: 18, height: 18))
        }
        image.isTemplate = false
        setButtonImage(button, image: image)

        let label = String(
            format: ProviderUILocalization.text(
                "menubar.overflow.accessibility_label",
                fallback: "%@ more profiles"
            ),
            "\(count)"
        )
        button.setAccessibilityLabel(label)
        button.toolTip = label
    }

    /// True when `sender` is the overflow status item's button — the "+N"
    /// item representing every profile past the first `overflowThreshold - 1`
    /// that `splitForOverflow` keeps individual.
    func isOverflowButton(_ sender: NSStatusBarButton?) -> Bool {
        guard let sender else { return false }
        return overflowStatusItem?.button === sender
    }

    /// The overflow status item's button, if it currently has anything to
    /// show (used to position the overflow profile list popover). The item
    /// itself may still exist hidden behind the scenes — see
    /// `updateOverflowItem(for:target:action:)` — so this checks `isVisible`
    /// rather than nilness to keep "no overflow right now" indistinguishable
    /// from callers' perspective, whether or not the underlying item was
    /// kept alive to preserve its menu bar position.
    var overflowButton: NSStatusBarButton? {
        guard let overflowStatusItem, overflowStatusItem.isVisible else {
            return nil
        }
        return overflowStatusItem.button
    }

    /// Adds a thin green underline to an image to indicate the active profile.
    /// The canvas is 2pts taller than the source so the icon shifted up by 2pts is
    /// not clipped. A 1.5pt rounded underline, inset 1pt per side, sits at the bottom.
    private func addGreenUnderline(to image: NSImage) -> NSImage {
        let newSize = NSSize(width: image.size.width, height: image.size.height + 2)
        let newImage = NSImage(size: newSize)
        newImage.lockFocus()
        defer { newImage.unlockFocus() }
        // Draw source image shifted up by 2pts (creating a gap above the underline).
        // NSRect.zero passed as `from:` is AppKit's sentinel meaning "draw entire image".
        image.draw(at: NSPoint(x: 0, y: 2), from: NSRect(origin: .zero, size: image.size), operation: .copy, fraction: 1.0)
        NSColor.systemGreen.setFill()
        let underlineRect = NSRect(x: 1, y: 0, width: image.size.width - 2, height: 1.5)
        NSBezierPath(roundedRect: underlineRect, xRadius: 0.75, yRadius: 0.75).fill()
        return newImage
    }

    /// The rendered menu bar image for one profile, plus the session values
    /// needed to build its accessibility label. Returned together so the
    /// image and the label built from it can never drift apart.
    struct ProfileMenuBarRender {
        let image: NSImage
        let sessionDisplay: Double
        let showRemaining: Bool
        /// Which windows had no reading behind them. Carried alongside the
        /// image so the accessibility label and tooltip cannot describe a
        /// figure the image is deliberately refusing to show.
        let unknownWindows: MenuBarUnknownWindows

        init(
            image: NSImage,
            sessionDisplay: Double,
            showRemaining: Bool,
            unknownWindows: MenuBarUnknownWindows = []
        ) {
            self.image = image
            self.sessionDisplay = sessionDisplay
            self.showRemaining = showRemaining
            self.unknownWindows = unknownWindows
        }
    }

    /// Builds the exact image `updateMultiProfileButtons` paints for one
    /// profile's status item — usage percentages, statuses, time/pace
    /// markers, the icon-style-specific render, the provider badge, and the
    /// active-profile underline — without touching any button. Shared by
    /// the paint path and `intendedItemWidth(for:config:isActive:)`, which
    /// needs the same image's width before its status item exists, so the
    /// overflow-space calculation is never a render behind reality.
    func renderProfileMenuBar(
        for profile: Profile,
        config: MultiProfileDisplayConfig,
        isDarkMode: Bool,
        isActive: Bool,
        /// Which of this profile's two credentials is signed out or
        /// rejected, decided by `MenuBarAttentionSignal`; `nil` for no
        /// marker. The kind reaches the drawing because the two credentials
        /// get two different marks — a filled disc and a hollow ring — not
        /// only two different sentences. Defaulted so
        /// `intendedItemWidth(for:config:isActive:)` can keep measuring
        /// without knowing: both markers are drawn inside the existing canvas
        /// and neither changes the image's width, so the overflow plan is the
        /// same either way.
        attention: MenuBarAttentionSignal.Credential? = nil
    ) -> ProfileMenuBarRender {
        // Get usage data for this profile. `ClaudeUsage.empty` stands for
        // "nothing has been read yet" and says so through its availability
        // flags, so a profile that never completed a fetch renders as no
        // reading rather than as a pristine account at 0%.
        let usage = profile.claudeUsage ?? ClaudeUsage.empty
        let showRemaining = config.showRemainingPercentage

        var unknownWindows: MenuBarUnknownWindows = []
        if !usage.sessionPercentageAvailable {
            unknownWindows.insert(.session)
        }
        if !usage.weeklyPercentageAvailable {
            unknownWindows.insert(.week)
        }

        // Calculate percentages
        let sessionUsed = usage.effectiveSessionPercentage
        let weekUsed = usage.weeklyPercentage

        let sessionDisplay = UsageStatusCalculator.getDisplayPercentage(
            usedPercentage: sessionUsed,
            showRemaining: showRemaining
        )
        let weekDisplay = UsageStatusCalculator.getDisplayPercentage(
            usedPercentage: weekUsed,
            showRemaining: showRemaining
        )

        let sessionElapsed = UsageStatusCalculator.elapsedFraction(
            resetTime: usage.sessionResetTime,
            duration: Constants.sessionWindow,
            showRemaining: false
        )
        let weekElapsed = UsageStatusCalculator.elapsedFraction(
            resetTime: usage.weeklyResetTime,
            duration: Constants.weeklyWindow,
            showRemaining: false
        )
        let sessionStatus = UsageStatusCalculator.calculateStatus(
            usedPercentage: sessionUsed,
            showRemaining: showRemaining,
            elapsedFraction: config.usePaceColoring ? sessionElapsed : nil
        )
        let weekStatus = UsageStatusCalculator.calculateStatus(
            usedPercentage: weekUsed,
            showRemaining: showRemaining,
            elapsedFraction: config.usePaceColoring ? weekElapsed : nil
        )

        // Use multi-profile config's useSystemColor as monochrome mode
        // When useSystemColor is ON, icons will be white (like single-profile monochrome)
        let useMonochrome = config.useSystemColor

        // Calculate time marker fractions for multi-profile display
        let sessionMarker: CGFloat? = config.showTimeMarker
            ? sessionElapsed.map { CGFloat(showRemaining ? 1.0 - $0 : $0) }
            : nil
        let weekMarker: CGFloat? = config.showTimeMarker
            ? weekElapsed.map { CGFloat(showRemaining ? 1.0 - $0 : $0) }
            : nil

        // Compute pace status for multi-profile rendering
        let sessionPaceStatus: PaceStatus? = {
            guard config.showPaceMarker, let elapsed = sessionElapsed else { return nil }
            return PaceStatus.calculate(usedPercentage: sessionUsed, elapsedFraction: elapsed)
        }()
        let weekPaceStatus: PaceStatus? = {
            guard config.showPaceMarker, let elapsed = weekElapsed else { return nil }
            return PaceStatus.calculate(usedPercentage: weekUsed, elapsedFraction: elapsed)
        }()

        // Create icon based on selected style
        let image: NSImage
        switch config.iconStyle {
        case .concentric:
            if config.showProfileLabel {
                image = renderer.createConcentricIconWithLabel(
                    sessionPercentage: sessionDisplay,
                    weekPercentage: config.showWeek ? weekDisplay : 0,
                    sessionStatus: sessionStatus,
                    weekStatus: weekStatus,
                    profileName: profile.name,
                    monochromeMode: useMonochrome,
                    isDarkMode: isDarkMode,
                    useSystemColor: false,
                    sessionTimeMarker: sessionMarker,
                    weekTimeMarker: config.showWeek ? weekMarker : nil,
                    sessionPaceStatus: sessionPaceStatus,
                    weekPaceStatus: config.showWeek ? weekPaceStatus : nil,
                    showPaceMarker: config.showPaceMarker,
                    unknownWindows: unknownWindows
                )
            } else {
                image = renderer.createConcentricIcon(
                    sessionPercentage: sessionDisplay,
                    weekPercentage: config.showWeek ? weekDisplay : 0,
                    sessionStatus: sessionStatus,
                    weekStatus: weekStatus,
                    profileInitial: String(profile.name.prefix(1)),
                    monochromeMode: useMonochrome,
                    isDarkMode: isDarkMode,
                    useSystemColor: false,
                    sessionTimeMarker: sessionMarker,
                    weekTimeMarker: config.showWeek ? weekMarker : nil,
                    sessionPaceStatus: sessionPaceStatus,
                    weekPaceStatus: config.showWeek ? weekPaceStatus : nil,
                    showPaceMarker: config.showPaceMarker,
                    unknownWindows: unknownWindows
                )
            }
        case .progressBar:
            image = renderer.createMultiProfileProgressBar(
                sessionPercentage: sessionDisplay,
                weekPercentage: config.showWeek ? weekDisplay : nil,
                sessionStatus: sessionStatus,
                weekStatus: weekStatus,
                profileName: config.showProfileLabel ? profile.name : nil,
                monochromeMode: useMonochrome,
                isDarkMode: isDarkMode,
                useSystemColor: false,
                sessionTimeMarker: sessionMarker,
                weekTimeMarker: config.showWeek ? weekMarker : nil,
                sessionPaceStatus: sessionPaceStatus,
                weekPaceStatus: config.showWeek ? weekPaceStatus : nil,
                showPaceMarker: config.showPaceMarker,
                unknownWindows: unknownWindows
            )
        case .compact:
            image = renderer.createCompactDot(
                percentage: sessionDisplay,
                status: sessionStatus,
                profileInitial: config.showProfileLabel ? String(profile.name.prefix(1)) : nil,
                monochromeMode: useMonochrome,
                isDarkMode: isDarkMode,
                useSystemColor: false,
                paceStatus: sessionPaceStatus,
                showPaceMarker: config.showPaceMarker,
                unknownWindows: unknownWindows
            )
        case .percentage:
            image = renderer.createMultiProfilePercentage(
                sessionPercentage: sessionDisplay,
                weekPercentage: config.showWeek ? weekDisplay : nil,
                sessionStatus: sessionStatus,
                weekStatus: weekStatus,
                profileName: config.showProfileLabel ? profile.name : nil,
                monochromeMode: useMonochrome,
                isDarkMode: isDarkMode,
                useSystemColor: false,
                sessionPaceStatus: sessionPaceStatus,
                weekPaceStatus: config.showWeek ? weekPaceStatus : nil,
                showPaceMarker: config.showPaceMarker,
                unknownWindows: unknownWindows
            )
        }

        let badgeStyle = ProfileManager.shared.providerBadgeStyle
        let badgedImage = renderer.applyProviderBadge(
            to: image,
            providerID: .claude,
            style: badgeStyle,
            isDarkMode: isDarkMode
        )

        var finalImage: NSImage
        if isActive {
            let underlinedImage = addGreenUnderline(to: badgedImage)
            underlinedImage.isTemplate = false
            finalImage = underlinedImage
        } else {
            badgedImage.isTemplate = useMonochrome
                && !config.showPaceMarker
                && !badgeStyle.showsTint
            finalImage = badgedImage
        }

        if let attention {
            // Last, so it survives the badge and the active-profile
            // underline instead of being drawn over by them. Template
            // rendering is switched off for the same reason the underline
            // above switches it off: macOS would flatten the marker into
            // the icon's own foreground colour, taking both its colour and
            // — for the hollow ring — the punched-out hole that tells the
            // two credentials apart.
            let marked = renderer.applyAttentionMarker(
                to: finalImage,
                credential: attention,
                isDarkMode: isDarkMode
            )
            marked.isTemplate = false
            finalImage = marked
        }

        return ProfileMenuBarRender(
            image: finalImage,
            sessionDisplay: sessionDisplay,
            showRemaining: showRemaining,
            unknownWindows: unknownWindows
        )
    }

    /// Updates all multi-profile status items
    ///
    /// `attention` names the profiles whose account is signed out or
    /// rejected, and for each of them WHICH of its two credentials — a
    /// dictionary rather than a set of ids, because the marker, the tooltip
    /// and the accessibility label all have to say which one, and a set
    /// could only say "something". Purely additive to what is DRAWN: no
    /// status item is created, removed, or reordered on account of it,
    /// because removing and recreating an item discards AppKit's saved
    /// menu-bar position and users lose their arrangement.
    func updateMultiProfileButtons(
        profiles: [Profile],
        config: MultiProfileDisplayConfig,
        activeProfileId: UUID? = nil,
        attention: [UUID: MenuBarAttentionSignal.Credential] = [:]
    ) {
        guard isMultiProfileMode else { return }

        for profile in profiles
        where profile.isSelectedForDisplay
            && profile.providerID == .claude {
            guard let statusItem = multiProfileStatusItems[profile.id],
                  let button = statusItem.button else {
                continue
            }

            // Get actual menu bar appearance from the button (based on wallpaper, not system mode)
            let menuBarIsDark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let isActive = profile.id == activeProfileId

            let render = renderProfileMenuBar(
                for: profile,
                config: config,
                isDarkMode: menuBarIsDark,
                isActive: isActive,
                attention: attention[profile.id]
            )
            button.image = render.image
            statusItemIdentities[ObjectIdentifier(button)] =
                ProviderStatusItemIdentity(
                    profileID: profile.id,
                    providerID: profile.providerID,
                    providerRevision: profile.providerRevision,
                    metricID: nil
                )
            let appearance = ProviderAppearance.forProvider(
                profile.providerID
            )
            let baseLabel = "\(appearance.displayName), \(profile.name), "
                + Self.sessionAccessibilityValue(for: render)
            let label = Self.profileAccessibilityLabel(
                baseLabel,
                isActive: isActive,
                attention: attention[profile.id]
            )
            button.setAccessibilityLabel(label)
            button.toolTip = label
        }
    }

    /// Resolves the up-to-two rendered metrics (primary/secondary window)
    /// shown by the shared compact two-row percentage icon, so the image
    /// renderer and the accessibility label are always built from the same
    /// data instead of drifting apart.
    static func compactPercentageMetrics(
        presentation: ProviderMenuPresentation,
        config: MultiProfileDisplayConfig
    ) -> (
        primary: ProviderMetricPresentation?,
        secondary: ProviderMetricPresentation?
    ) {
        let rendered = presentation.metrics.prefix(2).map {
            ProviderMenuPresentationBuilder.metric($0, applying: config)
        }
        let primary = rendered.first ?? nil
        let secondary = config.showWeek && rendered.count > 1 ? rendered[1] : nil
        return (primary, secondary)
    }

    /// Renders the shared compact two-row percentage image (top row: up to
    /// two window percentages separated by a dimmed " · "; bottom row: a
    /// 3-char profile label) for any provider's multi-profile status item.
    /// Claude's own `.percentage` style already calls the same renderer
    /// method directly from `updateMultiProfileButtons`.
    private static func compactPercentageImage(
        renderer: MenuBarIconRenderer,
        presentation: ProviderMenuPresentation,
        config: MultiProfileDisplayConfig,
        isDarkMode: Bool
    ) -> NSImage {
        let (primary, secondary) = compactPercentageMetrics(
            presentation: presentation,
            config: config
        )

        func paceStatus(
            for metric: ProviderMetricPresentation?
        ) -> PaceStatus? {
            guard config.showPaceMarker,
                  let metric,
                  let elapsed = metric.elapsedFraction,
                  let used = metric.usedPercentage else {
                return nil
            }
            return PaceStatus.calculate(
                usedPercentage: used,
                elapsedFraction: elapsed
            )
        }

        return renderer.createMultiProfilePercentage(
            sessionPercentage: primary?.displayedPercentage,
            weekPercentage: secondary?.displayedPercentage,
            sessionStatus: primary?.statusLevel ?? .safe,
            weekStatus: secondary?.statusLevel ?? .safe,
            profileName: config.showProfileLabel
                ? presentation.profileName
                : nil,
            monochromeMode: config.useSystemColor,
            isDarkMode: isDarkMode,
            useSystemColor: false,
            sessionPaceStatus: paceStatus(for: primary),
            weekPaceStatus: paceStatus(for: secondary),
            showPaceMarker: config.showPaceMarker
        )
    }

    /// Accessibility label for the compact two-row percentage icon. The icon
    /// packs up to two windows (e.g. session + weekly) into one image, but a
    /// label built from only the primary metric silently drops the second
    /// window from VoiceOver. Describe every window the icon actually shows.
    static func compactPercentageAccessibilityLabel(
        presentation: ProviderMenuPresentation,
        config: MultiProfileDisplayConfig
    ) -> String {
        let (primary, secondary) = compactPercentageMetrics(
            presentation: presentation,
            config: config
        )
        let parts = [primary, secondary].compactMap {
            metric -> String? in
            guard let metric else { return nil }
            let stateSuffix = metric.state == .ready
                ? ""
                : ", \(metric.state.accessibilityText)"
            return "\(metric.descriptor.metricName), "
                + "\(metric.percentageText) \(metric.modeText)"
                + stateSuffix
        }
        guard !parts.isEmpty else {
            return "\(presentation.appearance.displayName), "
                + presentation.state.accessibilityText
        }
        return "\(presentation.appearance.displayName), "
            + parts.joined(separator: ", ")
    }

    /// Overrides non-Claude multi-profile buttons with provider-neutral
    /// dynamic metrics while leaving characterized Claude icons untouched.
    /// `isActive` is resolved per-profile (via `ProfileManager.isActive(_:)`)
    /// since this spans both providers' independent active slots.
    func updateProviderMultiProfileButtons(
        presentations: [ProviderMenuPresentation],
        profiles: [Profile],
        config: MultiProfileDisplayConfig,
        activeClaudeProfileID: UUID?,
        isActive: (Profile) -> Bool,
        attention: [UUID: MenuBarAttentionSignal.Credential] = [:]
    ) {
        updateMultiProfileButtons(
            profiles: profiles,
            config: config,
            activeProfileId: activeClaudeProfileID,
            attention: attention
        )
        for presentation in presentations
        where presentation.identity.providerID != .claude {
            guard let item =
                    multiProfileStatusItems[presentation.identity.profileID],
                  let button = item.button else {
                continue
            }
            let menuBarIsDark = button.effectiveAppearance.bestMatch(
                from: [.darkAqua, .aqua]
            ) == .darkAqua
            let profile = profiles.first {
                $0.id == presentation.identity.profileID
            }
            var iconConfig = profile?.iconConfig.adaptedForProvider(
                presentation.identity.providerID
            ) ?? .default(
                for: presentation.identity.providerID
            )
            iconConfig.colorMode = config.useSystemColor
                ? .monochrome
                : .multiColor
            iconConfig.showRemainingPercentage =
                config.showRemainingPercentage
            iconConfig.showTimeMarker = config.showTimeMarker
            iconConfig.showPaceMarker = config.showPaceMarker
            iconConfig.usePaceColoring = config.usePaceColoring

            let image: NSImage
            if config.iconStyle == .percentage {
                // Compact two-row form shared with Claude: pack up to two
                // windows' integer percentages into one image per profile
                // instead of a single metric. Window display names stay
                // popover-only here, matching the Claude rendering this
                // mirrors.
                image = Self.compactPercentageImage(
                    renderer: renderer,
                    presentation: presentation,
                    config: config,
                    isDarkMode: menuBarIsDark
                )
            } else {
                let renderedMetric =
                    ProviderMenuPresentationBuilder.metric(
                        presentation.metric,
                        applying: config
                    )
                var metricConfig = renderedMetric.flatMap {
                    iconConfig.config(for: $0.id)
                } ?? MetricIconConfig(
                    metricID: renderedMetric?.id
                        ?? .providerPlaceholder(
                            presentation.identity.providerID
                        ),
                    isEnabled: renderedMetric != nil
                )
                switch config.iconStyle {
                case .concentric:
                    metricConfig.iconStyle = .icon
                case .progressBar:
                    metricConfig.iconStyle = .progressBar
                case .compact:
                    metricConfig.iconStyle = .compact
                case .percentage:
                    metricConfig.iconStyle = .percentageOnly
                }
                let profileInitial = config.showProfileLabel
                    ? String(presentation.profileName.prefix(1))
                        .uppercased()
                    : ""
                let renderAppearance = ProviderAppearance(
                    providerID: presentation.appearance.providerID,
                    displayName: presentation.appearance.displayName,
                    compactBadge:
                        presentation.appearance.compactBadge
                            + profileInitial,
                    symbolName: presentation.appearance.symbolName
                )
                let baseVisualLabel = Self.providerMetricVisualLabel(
                    for: renderedMetric,
                    in: presentation,
                    showLongProviderName: false
                )
                let visualLabel = profileInitial.isEmpty
                    ? baseVisualLabel
                    : baseVisualLabel.replacingOccurrences(
                        of: presentation.appearance.compactBadge,
                        with: presentation.appearance.compactBadge
                            + profileInitial,
                        options: [.anchored]
                    )
                image = renderer.createProviderMetricImage(
                    renderedMetric,
                    appearance: renderAppearance,
                    metricConfig: metricConfig,
                    globalConfig: iconConfig,
                    isDarkMode: menuBarIsDark,
                    showProviderLabel: true,
                    visualLabel: visualLabel,
                    placeholderState: presentation.state
                )
            }
            let badgeStyle = ProfileManager.shared.providerBadgeStyle
            let badgedImage = renderer.applyProviderBadge(
                to: image,
                providerID: presentation.identity.providerID,
                style: badgeStyle,
                isDarkMode: menuBarIsDark
            )
            badgedImage.isTemplate = config.useSystemColor
                && !iconConfig.showPaceMarker
                && !badgeStyle.showsTint
            if let profile, isActive(profile) {
                let underlined = addGreenUnderline(to: badgedImage)
                underlined.isTemplate = false
                setButtonImage(button, image: underlined)
            } else {
                setButtonImage(button, image: badgedImage)
            }
            statusItemIdentities[ObjectIdentifier(button)] =
                ProviderStatusItemReconciliation.multiIdentity(
                    for: presentation
                )
            let baseLabel = "\(presentation.profileName), "
                + (config.iconStyle == .percentage
                    ? Self.compactPercentageAccessibilityLabel(
                        presentation: presentation,
                        config: config
                    )
                    : presentation.metric?.accessibilityLabel
                        ?? "\(presentation.appearance.displayName), "
                            + presentation.state.accessibilityText)
            let label = Self.profileAccessibilityLabel(
                baseLabel,
                isActive: profile.map(isActive) ?? false
            )
            button.setAccessibilityLabel(label)
            button.toolTip = label
        }
    }

    /// Checks if currently in multi-profile mode
    var isInMultiProfileMode: Bool {
        return isMultiProfileMode
    }

    /// Checks if status bar has at least one valid button (for headless mode detection)
    var hasValidStatusBar: Bool {
        // Check single-profile status items
        for (_, statusItem) in statusItems {
            if statusItem.button != nil {
                return true
            }
        }
        // Check multi-profile status items
        for (_, statusItem) in multiProfileStatusItems {
            if statusItem.button != nil {
                return true
            }
        }
        if overflowStatusItem?.button != nil {
            return true
        }
        return false
    }

    /// Get button for a specific profile (multi-profile mode). `nil` both
    /// when no item exists for this profile and when one exists but is
    /// currently hidden behind the overflow item (see
    /// `updateMultiProfileConfiguration`) — either way, there's no button on
    /// screen right now to anchor a click or a popover to.
    func button(for profileId: UUID) -> NSStatusBarButton? {
        guard let item = multiProfileStatusItems[profileId], item.isVisible
        else {
            return nil
        }
        return item.button
    }

    /// Find which profile ID owns the given button (multi-profile mode)
    func profileId(for sender: NSStatusBarButton?) -> UUID? {
        guard let sender = sender else { return nil }

        for (profileId, statusItem) in multiProfileStatusItems {
            if statusItem.button === sender {
                return profileId
            }
        }
        return nil
    }

    // MARK: - UI Updates

    /// Updates all status bar buttons based on current usage data
    ///
    /// `attention` marks the single-profile Claude icons the same way the
    /// multi-profile path marks its own, decided by the same
    /// `MenuBarAttentionSignal`. Without it the marker would exist only for
    /// people running several profiles, and a signed-out account would still
    /// be invisible for everyone else.
    ///
    /// The credential and not a `Bool`, because it selects both surfaces
    /// this path writes: which mark is drawn — a filled red disc for
    /// claude.ai, a hollow amber ring for Claude Code — and the wording of
    /// the label and tooltip built beneath it. A `Bool` would leave this
    /// path drawing one shape for two unrelated failures while the
    /// multi-profile path drew two.
    func updateAllButtons(
        usage: ClaudeUsage,
        apiUsage: APIUsage?,
        attention: MenuBarAttentionSignal.Credential? = nil
    ) {
        // Get config from active profile
        let profile = ProfileManager.shared.activeClaudeProfile
        let config = profile?.iconConfig ?? .default

        // Check if we should show default logo (no usage credentials OR no enabled metrics)
        let hasUsageCredentials = profile?.hasUsageCredentials ?? false
        if !hasUsageCredentials || config.enabledMetrics.isEmpty {
            // Show default app logo
            if let statusItem = statusItems[.claudeSession],
               let button = statusItem.button {
                // Get actual menu bar appearance from the button
                let menuBarIsDark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let logoImage = renderer.createDefaultAppLogo(isDarkMode: menuBarIsDark)
                logoImage.isTemplate = true  // Let macOS handle the color
                setButtonImage(button, image: logoImage)
                let label = Self.legacyDefaultLogoAccessibilityLabel(
                    profileName: profile?.name
                )
                button.setAccessibilityLabel(label)
                button.toolTip = label
            }
            return
        }

        // Normal metric display
        for metricConfig in config.enabledMetrics {
            guard let statusItem = statusItems[metricConfig.metricID],
                  let button = statusItem.button else {
                continue
            }

            // Get actual menu bar appearance from the button
            let menuBarIsDark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

            // Create image directly using our renderer
            let renderedImage = renderer.createImage(
                for: metricConfig.metricType,
                config: metricConfig,
                globalConfig: config,
                usage: usage,
                apiUsage: apiUsage,
                isDarkMode: menuBarIsDark,
                colorMode: config.colorMode,
                singleColorHex: config.singleColorHex,
                showIconName: config.showIconNames,
                showNextSessionTime: metricConfig.showNextSessionTime
            )

            let badgeStyle = ProfileManager.shared.providerBadgeStyle
            let badged = renderer.applyProviderBadge(
                to: renderedImage,
                providerID: .claude,
                style: badgeStyle,
                isDarkMode: menuBarIsDark
            )
            badged.isTemplate = config.colorMode == .monochrome
                && !config.showPaceMarker
                && !badgeStyle.showsTint
            button.image = Self.marked(
                badged,
                attention: attention,
                renderer: renderer,
                isDarkMode: menuBarIsDark
            )
            let label = Self.legacyMetricAccessibilityLabel(
                for: metricConfig.metricType,
                profileName: profile?.name,
                usage: usage,
                apiUsage: apiUsage,
                showRemaining: config.showRemainingPercentage,
                attention: attention
            )
            button.setAccessibilityLabel(label)
            button.toolTip = label
        }
    }

    /// Updates a specific metric's button
    ///
    /// Takes the credential for the same reason `updateAllButtons` does:
    /// this path repaints one item on its own, and a label rebuilt without
    /// the fact would silently drop the complaint the other path had just
    /// put there.
    func updateButton(
        for metricType: MenuBarMetricType,
        usage: ClaudeUsage,
        apiUsage: APIUsage?,
        attention: MenuBarAttentionSignal.Credential? = nil
    ) {
        let metricID: MenuBarMetricID
        switch metricType {
        case .session: metricID = .claudeSession
        case .week: metricID = .claudeWeek
        case .api: metricID = .claudeAPI
        }
        guard let statusItem = statusItems[metricID],
              let button = statusItem.button else {
            return
        }

        // Get config from active profile
        let config = ProfileManager.shared.activeClaudeProfile?.iconConfig ?? .default
        guard let metricConfig = config.config(for: metricType) else {
            return
        }

        // Get the actual menu bar appearance from the button's effective appearance
        let menuBarIsDark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        // Create image directly using our renderer
        let renderedImage = renderer.createImage(
            for: metricType,
            config: metricConfig,
            globalConfig: config,
            usage: usage,
            apiUsage: apiUsage,
            isDarkMode: menuBarIsDark,
            colorMode: config.colorMode,
            singleColorHex: config.singleColorHex,
            showIconName: config.showIconNames,
            showNextSessionTime: metricConfig.showNextSessionTime
        )

        let badgeStyle = ProfileManager.shared.providerBadgeStyle
        let badged = renderer.applyProviderBadge(
            to: renderedImage,
            providerID: .claude,
            style: badgeStyle,
            isDarkMode: menuBarIsDark
        )
        badged.isTemplate = config.colorMode == .monochrome
            && !config.showPaceMarker
            && !badgeStyle.showsTint
        button.image = Self.marked(
            badged,
            attention: attention,
            renderer: renderer,
            isDarkMode: menuBarIsDark
        )
        let label = Self.legacyMetricAccessibilityLabel(
            for: metricType,
            profileName: ProfileManager.shared.activeClaudeProfile?.name,
            usage: usage,
            apiUsage: apiUsage,
            showRemaining: config.showRemainingPercentage,
            attention: attention
        )
        button.setAccessibilityLabel(label)
        button.toolTip = label
    }

    /// Stamps the attention marker when there is something to mark, and
    /// hands the image back untouched when there is not — so the ordinary
    /// healthy render is byte-for-byte what it always was.
    private static func marked(
        _ image: NSImage,
        attention: MenuBarAttentionSignal.Credential?,
        renderer: MenuBarIconRenderer,
        isDarkMode: Bool
    ) -> NSImage {
        guard let attention else { return image }
        // Same reason as the multi-profile path: template rendering would
        // flatten the marker into the icon's foreground colour, taking the
        // ring's punched-out hole with it.
        let marked = renderer.applyAttentionMarker(
            to: image,
            credential: attention,
            isDarkMode: isDarkMode
        )
        marked.isTemplate = false
        return marked
    }

    /// Get button for a specific metric (used for popover positioning)
    func button(for metricType: MenuBarMetricType) -> NSStatusBarButton? {
        let metricID: MenuBarMetricID
        switch metricType {
        case .session: metricID = .claudeSession
        case .week: metricID = .claudeWeek
        case .api: metricID = .claudeAPI
        }
        return statusItems[metricID]?.button
    }

    /// Get the first enabled metric's button (for backwards compatibility)
    var primaryButton: NSStatusBarButton? {
        let config = DataStore.shared.loadMenuBarIconConfiguration()
        if let firstMetric = config.enabledMetrics.first,
           let button = statusItems[firstMetric.metricID]?.button {
            return button
        }
        for metricID in singleMetricOrder {
            if let button = statusItems[metricID]?.button {
                return button
            }
        }
        return statusItems.values.compactMap(\.button).first
    }

    /// Find which metric type owns the given button (sender)
    func metricType(for sender: NSStatusBarButton?) -> MenuBarMetricType? {
        guard let sender = sender else { return nil }

        // Find which status item has this button
        for (metricID, statusItem) in statusItems {
            if statusItem.button === sender {
                return metricID.legacyMetricType
            }
        }
        return nil
    }

    // MARK: - Appearance Observation

    private var lastObservedAppearanceName: NSAppearance.Name?

    private func observeAppearanceChanges() {
        appearanceObservers.forEach { $0.invalidate() }
        appearanceObservers.removeAll()

        // IMPORTANT: Do NOT observe per-button effectiveAppearance.
        // Setting button.image triggers effectiveAppearance KVO on the button,
        // which causes an infinite redraw loop.
        let appObserver = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, change in
            guard let self = self else { return }
            let newName = change.newValue?.name
            guard newName != self.lastObservedAppearanceName else { return }
            self.lastObservedAppearanceName = newName
            // Clear image cache so next update re-renders with new appearance
            self.lastImageData.removeAll()
            self.delegate?.statusBarAppearanceDidChange()
        }
        appearanceObservers.append(appObserver)
    }

    /// Only sets button.image if the image data actually changed.
    /// This prevents triggering effectiveAppearance KVO when the image is identical.
    private func setButtonImage(_ button: NSStatusBarButton, image: NSImage) {
        let buttonId = ObjectIdentifier(button)
        guard let newData = Self.imageFingerprint(image) else {
            button.image = image
            return
        }
        if lastImageData[buttonId] == newData { return }
        lastImageData[buttonId] = newData
        button.image = image
    }

    /// Returns stable pixel bytes without invoking NSImage.tiffRepresentation, whose
    /// TIFF error-handler initialization crashes under the macOS 26 SDK.
    static func imageFingerprint(_ image: NSImage) -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = cgImage.dataProvider?.data else {
            return nil
        }
        let length = CFDataGetLength(data)
        guard length > 0, let bytes = CFDataGetBytePtr(data) else {
            return Data()
        }
        // `CGDataProvider.data` may be backed by provider-owned storage.
        // Copy the bytes so the cache never outlives that provider.
        return Data(bytes: bytes, count: length)
    }

    /// Debounces appearance change notifications so multiple displays/buttons
    /// coalesce into a single delegate callback
    private func scheduleAppearanceUpdate() {
        appearanceDebounceTimer?.invalidate()
        appearanceDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            self?.delegate?.statusBarAppearanceDidChange()
        }
    }
}

// MARK: - Delegate Protocol

protocol StatusBarUIManagerDelegate: AnyObject {
    func statusBarAppearanceDidChange()
}
