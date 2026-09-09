//
//  ManageProfilesView.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-01-07.
//

import SwiftUI
import AppKit
import UsageCore

struct ManageProfilesView: View {
    private let dependencies: ProviderUIDependencies
    @ObservedObject private var profileManager: ProfileManager
    @State private var showingCreateProfile = false
    @State private var newProfileName = ""
    @State private var newProfileProvider:
        ProfileProviderKind = .claude
    @State private var newCodexHomePath = ""
    @State private var errorMessage: String?
    // `DataStore` isn't an `ObservableObject`; this view owns the
    // displayed value locally and writes through on every change, the
    // same pattern `SettingToggle`'s bindings above use for other
    // `DataStore`-backed settings elsewhere in the app.
    @State private var overflowMode: MenuBarOverflowMode =
        DataStore.shared.loadMenuBarOverflowMode()
    /// Owned locally and written through on change, exactly like
    /// `overflowMode` above and for the same reason.
    @State private var multiLayout: MenuBarMultiLayout =
        DataStore.shared.loadMenuBarMultiLayout()
    @State private var healthStripNumbers:
        MenuBarHealthStripNumbersThreshold =
            DataStore.shared.loadHealthStripNumbersThreshold()

    init(
        dependencies: ProviderUIDependencies? = nil
    ) {
        let dependencies =
            dependencies
            ?? ProviderUICompositionRoot.shared.dependencies
        self.dependencies = dependencies
        _profileManager = ObservedObject(
            wrappedValue: dependencies.profileManager
        )
    }

    private var supportsAutomaticProfileSwitch: Bool {
        guard let activeProviderID =
                profileManager.activeProfile?.providerID else {
            return false
        }
        let activePolicy = ProviderFeatureSurfacePolicy(
            capabilities: dependencies.capabilities(
                for: activeProviderID
            )
        )
        guard activePolicy.supports(.automaticProfileSwitch) else {
            return false
        }
        return profileManager.profiles.lazy.filter {
            ProviderFeatureSurfacePolicy(
                capabilities: dependencies.capabilities(
                    for: $0.providerID
                )
            ).supports(.automaticProfileSwitch)
        }.count > 1
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.section) {
                // Page Header
                SettingsPageHeader(
                    title: "profiles.title".localized,
                    subtitle: "profiles.subtitle".localized
                )

                // Profile List
                SettingsContentCard {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
                        ForEach(profileManager.profiles) { profile in
                            ProfileRow(
                                profile: profile,
                                dependencies: dependencies
                            )
                                .padding(.vertical, DesignTokens.Spacing.extraSmall)

                            if profile.id != profileManager.profiles.last?.id {
                                Divider()
                            }
                        }
                    }
                }

                // Create New Profile Button
                SettingsButton(
                    title: "profiles.create_new".localized,
                    icon: "plus.circle.fill"
                ) {
                    showingCreateProfile = true
                }
                .accessibilityIdentifier(
                    ProviderUIAccessibility.profileCreateOpen
                )

                // Multi-Profile Display Section
                SettingsSectionCard(
                    title: "multiprofile.title".localized,
                    subtitle: "multiprofile.subtitle".localized
                ) {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.cardPadding) {
                        // Main toggle
                        SettingToggle(
                            title: "multiprofile.enable_title".localized,
                            description: "multiprofile.enable_description".localized,
                            badge: .new,
                            isOn: Binding(
                                get: { profileManager.displayMode == .multi },
                                set: { enabled in
                                    profileManager.updateDisplayMode(enabled ? .multi : .single)
                                    MenuBarNotificationDelivery.enqueue(.displayModeChanged)
                                }
                            )
                        )

                        // Profile selection (visible when multi-profile is ON)
                        if profileManager.displayMode == .multi {
                            Divider()

                            VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                                Text("multiprofile.select_profiles".localized)
                                    .font(DesignTokens.Typography.caption)
                                    .foregroundColor(.secondary)

                                ForEach(profileManager.profiles) { profile in
                                    ProfileSelectionRow(
                                        profile: profile,
                                        isSelected: profile.isSelectedForDisplay,
                                        isActive: profileManager.isActive(profile),
                                        onToggle: {
                                            // Ensure at least one profile stays selected
                                            let selectedCount = profileManager.profiles.filter { $0.isSelectedForDisplay }.count
                                            if profile.isSelectedForDisplay && selectedCount <= 1 {
                                                // Can't deselect the last one
                                                return
                                            }
                                            profileManager.toggleProfileSelection(profile.id)
                                            MenuBarNotificationDelivery.enqueue(.multiProfileConfigChanged)
                                        }
                                    )
                                }

                                // Warning if trying to deselect last profile
                                if profileManager.profiles.filter({ $0.isSelectedForDisplay }).count == 1 {
                                    HStack(alignment: .top, spacing: 6) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .font(.system(size: 10))
                                            .foregroundColor(.orange)
                                        Text("multiprofile.at_least_one".localized)
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.top, 4)
                                }
                            }

                            Divider()
                                .padding(.vertical, DesignTokens.Spacing.small)

                            // Menu Bar Layout Picker
                            VStack(
                                alignment: .leading,
                                spacing: DesignTokens.Spacing.small
                            ) {
                                Text("multiprofile.layout.title".localized)
                                    .font(DesignTokens.Typography.caption)
                                    .foregroundColor(.secondary)

                                Picker("", selection: Binding(
                                    get: { multiLayout },
                                    set: { setMultiLayout($0) }
                                )) {
                                    Text(
                                        "multiprofile.layout.per_profile"
                                            .localized
                                    )
                                    .tag(MenuBarMultiLayout.perProfileItems)
                                    Text(
                                        "multiprofile.layout.health_strip"
                                            .localized
                                    )
                                    .tag(MenuBarMultiLayout.healthStrip)
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()

                                Text(
                                    "multiprofile.layout.description"
                                        .localized
                                )
                                .font(DesignTokens.Typography.caption)
                                .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            // Health strip numbers threshold
                            VStack(
                                alignment: .leading,
                                spacing: DesignTokens.Spacing.small
                            ) {
                                HStack(
                                    spacing: DesignTokens.Spacing.extraSmall
                                ) {
                                    Text(
                                        "multiprofile.healthstrip.numbers_title"
                                            .localized
                                    )
                                    .font(DesignTokens.Typography.caption)
                                    .foregroundColor(.secondary)

                                    Picker("", selection: Binding(
                                        get: { healthStripNumbersSelection },
                                        set: {
                                            setHealthStripNumbersSelection($0)
                                        }
                                    )) {
                                        ForEach(
                                            MenuBarHealthStripNumbersThreshold
                                                .selectablePercents,
                                            id: \.self
                                        ) { percent in
                                            Text(
                                                "\(percent)"
                                                    + "multiprofile.healthstrip.numbers_suffix"
                                                        .localized
                                            )
                                            .tag(percent)
                                        }
                                        Text(
                                            "multiprofile.healthstrip.numbers_never"
                                                .localized
                                        )
                                        .tag(Self.healthStripNumbersNeverTag)
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                    .frame(width: 110)
                                }

                                Text(
                                    "multiprofile.healthstrip.numbers_hint"
                                        .localized
                                )
                                .font(DesignTokens.Typography.caption)
                                .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .disabled(multiLayout != .healthStrip)

                            Divider()
                                .padding(.vertical, DesignTokens.Spacing.small)

                            // Icon Style Picker
                            VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                                Text("multiprofile.icon_style".localized)
                                    .font(DesignTokens.Typography.caption)
                                    .foregroundColor(.secondary)

                                Picker("", selection: Binding(
                                    get: { profileManager.multiProfileConfig.iconStyle },
                                    set: { newStyle in
                                        var config = profileManager.multiProfileConfig
                                        config.iconStyle = newStyle
                                        profileManager.updateMultiProfileConfig(config)
                                        MenuBarNotificationDelivery.enqueue(.multiProfileConfigChanged)
                                    }
                                )) {
                                    ForEach(MultiProfileIconStyle.allCases, id: \.self) { style in
                                        Text(style.shortNameKey.localized).tag(style)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .disabled(multiLayout == .healthStrip)

                                // A silently dead control is worse than a
                                // disabled one: in strip layout the icon
                                // style governs no Claude item at all.
                                if multiLayout == .healthStrip {
                                    Text(
                                        "multiprofile.layout.icon_style_hint"
                                            .localized
                                    )
                                    .font(DesignTokens.Typography.caption)
                                    .foregroundColor(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            // Show Week Toggle
                            SettingToggle(
                                title: "multiprofile.show_week".localized,
                                description: "multiprofile.show_week_description".localized,
                                isOn: Binding(
                                    get: { profileManager.multiProfileConfig.showWeek },
                                    set: { showWeek in
                                        var config = profileManager.multiProfileConfig
                                        config.showWeek = showWeek
                                        profileManager.updateMultiProfileConfig(config)
                                        MenuBarNotificationDelivery.enqueue(.multiProfileConfigChanged)
                                    }
                                )
                            )

                            // Show Profile Label Toggle
                            SettingToggle(
                                title: "multiprofile.show_label".localized,
                                description: "multiprofile.show_label_description".localized,
                                isOn: Binding(
                                    get: { profileManager.multiProfileConfig.showProfileLabel },
                                    set: { showLabel in
                                        var config = profileManager.multiProfileConfig
                                        config.showProfileLabel = showLabel
                                        profileManager.updateMultiProfileConfig(config)
                                        MenuBarNotificationDelivery.enqueue(.multiProfileConfigChanged)
                                    }
                                )
                            )

                            // Use System Color Toggle
                            SettingToggle(
                                title: "multiprofile.use_system_color".localized,
                                description: "multiprofile.use_system_color_description".localized,
                                isOn: Binding(
                                    get: { profileManager.multiProfileConfig.useSystemColor },
                                    set: { useSystemColor in
                                        var config = profileManager.multiProfileConfig
                                        config.useSystemColor = useSystemColor
                                        profileManager.updateMultiProfileConfig(config)
                                        MenuBarNotificationDelivery.enqueue(.multiProfileConfigChanged)
                                    }
                                )
                            )

                            // Show Time Marker Toggle
                            SettingToggle(
                                title: "appearance.show_time_marker_title".localized,
                                description: "appearance.show_time_marker_description".localized,
                                isOn: Binding(
                                    get: { profileManager.multiProfileConfig.showTimeMarker },
                                    set: { showMarker in
                                        var config = profileManager.multiProfileConfig
                                        config.showTimeMarker = showMarker
                                        profileManager.updateMultiProfileConfig(config)
                                        MenuBarNotificationDelivery.enqueue(.multiProfileConfigChanged)
                                    }
                                )
                            )

                            // Pace Marker Toggle
                            SettingToggle(
                                title: "appearance.show_pace_marker_title".localized,
                                description: "appearance.show_pace_marker_description".localized,
                                isOn: Binding(
                                    get: { profileManager.multiProfileConfig.showPaceMarker },
                                    set: { showPace in
                                        var config = profileManager.multiProfileConfig
                                        config.showPaceMarker = showPace
                                        profileManager.updateMultiProfileConfig(config)
                                        MenuBarNotificationDelivery.enqueue(.multiProfileConfigChanged)
                                    }
                                )
                            )

                            // Pace-Aware Bar Colors Toggle
                            SettingToggle(
                                title: "appearance.pace_coloring_title".localized,
                                description: "appearance.pace_coloring_description".localized,
                                isOn: Binding(
                                    get: { profileManager.multiProfileConfig.usePaceColoring },
                                    set: { usePace in
                                        var config = profileManager.multiProfileConfig
                                        config.usePaceColoring = usePace
                                        profileManager.updateMultiProfileConfig(config)
                                        MenuBarNotificationDelivery.enqueue(.multiProfileConfigChanged)
                                    }
                                )
                            )

                            // Show Remaining Percentage Toggle
                            SettingToggle(
                                title: "appearance.show_remaining_title".localized,
                                description: "appearance.show_remaining_description".localized,
                                isOn: Binding(
                                    get: { profileManager.multiProfileConfig.showRemainingPercentage },
                                    set: { showRemaining in
                                        var config = profileManager.multiProfileConfig
                                        config.showRemainingPercentage = showRemaining
                                        profileManager.updateMultiProfileConfig(config)
                                        MenuBarNotificationDelivery.enqueue(.multiProfileConfigChanged)
                                    }
                                )
                            )

                            Divider()
                                .padding(.vertical, DesignTokens.Spacing.small)

                            // Overflow Behavior
                            VStack(
                                alignment: .leading,
                                spacing: DesignTokens.Spacing.small
                            ) {
                                Text("multiprofile.overflow.title".localized)
                                    .font(DesignTokens.Typography.caption)
                                    .foregroundColor(.secondary)

                                VStack(
                                    alignment: .leading,
                                    spacing: DesignTokens.Spacing.extraSmall
                                ) {
                                    overflowModeRow(
                                        title:
                                            "multiprofile.overflow.automatic"
                                                .localized,
                                        isSelected: overflowModeKind
                                            == .automatic,
                                        onSelect: {
                                            setOverflowMode(.automatic)
                                        }
                                    )
                                    if multiLayout != .healthStrip {
                                        AccessibilityGrantHint()
                                            .padding(.leading, 22)
                                        DetectedMenuBarManagerHint()
                                            .padding(.leading, 22)
                                    }
                                    overflowModeRow(
                                        title:
                                            "multiprofile.overflow.never"
                                                .localized,
                                        isSelected: overflowModeKind
                                            == .never,
                                        onSelect: {
                                            setOverflowMode(.never)
                                        }
                                    )
                                    HStack(
                                        spacing: DesignTokens.Spacing
                                            .extraSmall
                                    ) {
                                        overflowModeRow(
                                            title:
                                                "multiprofile.overflow.after_count"
                                                    .localized,
                                            isSelected: overflowModeKind
                                                == .afterCount,
                                            onSelect: {
                                                setOverflowMode(
                                                    .afterCount(
                                                        overflowAfterCountThreshold
                                                    )
                                                )
                                            }
                                        )
                                        Picker(
                                            "",
                                            selection: Binding(
                                                get: {
                                                    overflowAfterCountThreshold
                                                },
                                                set: { newValue in
                                                    setOverflowMode(
                                                        .afterCount(newValue)
                                                    )
                                                }
                                            )
                                        ) {
                                            ForEach(
                                                Self.overflowAfterCountOptions,
                                                id: \.self
                                            ) { count in
                                                Text("\(count)").tag(count)
                                            }
                                        }
                                        .labelsHidden()
                                        .pickerStyle(.menu)
                                        .frame(width: 56)
                                        .disabled(
                                            overflowModeKind != .afterCount
                                        )
                                        Text(
                                            "multiprofile.overflow.after_count_suffix"
                                                .localized
                                        )
                                        .font(DesignTokens.Typography.body)
                                        .foregroundColor(.primary)
                                    }
                                }
                            }
                            // The strip is one item however many accounts
                            // it holds, so it cannot overflow.
                            .disabled(multiLayout == .healthStrip)

                            // Info message
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "info.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(.blue)
                                Text("multiprofile.info".localized)
                                    .font(DesignTokens.Typography.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.top, DesignTokens.Spacing.small)
                        }
                    }
                }

                if supportsAutomaticProfileSwitch {
                    // Auto-Switch Profile Section
                    SettingsSectionCard(
                        title: "auto_switch.title".localized,
                        subtitle: "auto_switch.subtitle".localized
                    ) {
                        SettingToggle(
                            title: "auto_switch.enable_title".localized,
                            description: "auto_switch.enable_description".localized,
                            badge: .new,
                            isOn: Binding(
                                get: { SharedDataStore.shared.loadAutoSwitchProfileEnabled() },
                                set: { enabled in
                                    SharedDataStore.shared.saveAutoSwitchProfileEnabled(enabled)
                                }
                            )
                        )
                    }
                }

                // Info Card
                SettingsContentCard {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
                        HStack(spacing: DesignTokens.Spacing.small) {
                            Image(systemName: "info.circle.fill")
                                .foregroundColor(.blue)
                                .font(.system(size: DesignTokens.Icons.standard))
                            Text("profiles.about_title".localized)
                                .font(DesignTokens.Typography.sectionTitle)
                        }

                        Text("profiles.about_description".localized)
                            .font(DesignTokens.Typography.caption)
                            .foregroundColor(.secondary)

                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.extraSmall) {
                            BulletPoint("profiles.about_credentials".localized)
                            BulletPoint("profiles.about_api".localized)
                            BulletPoint("profiles.about_cli".localized)
                            BulletPoint("profiles.about_appearance".localized)
                            BulletPoint("profiles.about_notifications".localized)
                            BulletPoint("profiles.about_refresh".localized)
                            BulletPoint("profiles.about_cli_switching".localized)
                        }
                        .font(DesignTokens.Typography.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, DesignTokens.Spacing.small)
                    }
                }

                if let error = errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.system(size: 11))
                }
            }
            .padding()
        }
        .sheet(isPresented: $showingCreateProfile) {
            CreateProfileSheet(
                profileName: $newProfileName,
                provider: $newProfileProvider,
                codexHomePath: $newCodexHomePath,
                codexAvailable:
                    dependencies.availability.codexSupportEnabled,
                onSave: {
                    createNewProfile()
                },
                onCancel: {
                    showingCreateProfile = false
                    newProfileName = ""
                    newProfileProvider = .claude
                    newCodexHomePath = ""
                }
            )
        }
    }

    private func createNewProfile() {
        let name = newProfileName.isEmpty ? nil : newProfileName
        do {
            _ = try dependencies.createProfile(
                name: name,
                provider: newProfileProvider,
                linkedCodexHome:
                    newProfileProvider == .codex
                    ? newCodexHomePath : nil
            )
        } catch {
            errorMessage =
                ProviderAccountViewModel.message(for: error)
            return
        }
        errorMessage = nil
        showingCreateProfile = false
        newProfileName = ""
        newProfileProvider = .claude
        newCodexHomePath = ""
    }

    // MARK: - Overflow Mode

    private static let overflowAfterCountOptions = [3, 4, 5, 6, 8, 10]

    private var overflowModeKind: MenuBarOverflowMode.StorageKind {
        overflowMode.storageKind
    }

    private var overflowAfterCountThreshold: Int {
        if case .afterCount(let count) = overflowMode {
            return count
        }
        return MenuBarOverflowMode.defaultAfterCountThreshold
    }

    /// Tag standing for "Never" in the numbers picker, which is otherwise
    /// keyed on percentages. Zero is not a selectable percentage, so it can
    /// never collide with one.
    private static let healthStripNumbersNeverTag = 0

    private var healthStripNumbersSelection: Int {
        if case .percent(let percent) = healthStripNumbers {
            return percent
        }
        return Self.healthStripNumbersNeverTag
    }

    private func setHealthStripNumbersSelection(_ selection: Int) {
        setHealthStripNumbers(
            selection == Self.healthStripNumbersNeverTag
                ? .never
                : .percent(selection)
        )
    }

    private func setHealthStripNumbers(
        _ threshold: MenuBarHealthStripNumbersThreshold
    ) {
        healthStripNumbers = threshold
        DataStore.shared.saveHealthStripNumbersThreshold(threshold)
        MenuBarNotificationDelivery.enqueue(.multiProfileConfigChanged)
    }

    /// Writes the layout through and reuses the existing multi-profile
    /// recompute path. That path ends in a fan-out refresh, which is an
    /// accepted cost for a setting nobody touches twice in a session — do
    /// not add a second notification just for this.
    private func setMultiLayout(_ layout: MenuBarMultiLayout) {
        multiLayout = layout
        DataStore.shared.saveMenuBarMultiLayout(layout)
        MenuBarNotificationDelivery.enqueue(.multiProfileConfigChanged)
    }

    private func setOverflowMode(_ mode: MenuBarOverflowMode) {
        overflowMode = mode
        DataStore.shared.saveMenuBarOverflowMode(mode)
        // Reuses the existing multi-profile recompute path — the overflow
        // mode is exactly the kind of visual/layout change that path
        // already exists to propagate to the live menu bar.
        MenuBarNotificationDelivery.enqueue(.multiProfileConfigChanged)
    }

    private func overflowModeRow(
        title: String,
        isSelected: Bool,
        onSelect: @escaping () -> Void
    ) -> some View {
        Button(action: onSelect) {
            HStack(spacing: DesignTokens.Spacing.extraSmall) {
                Image(
                    systemName: isSelected
                        ? "largecircle.fill.circle"
                        : "circle"
                )
                .foregroundColor(isSelected ? .accentColor : .secondary)
                Text(title)
                    .font(DesignTokens.Typography.body)
                    .foregroundColor(.primary)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Inline hint shown under the "Automatic" overflow option: automatic mode
/// needs the Accessibility grant to measure the frontmost app's menu bar
/// boundary (see `MenuBarSpaceProbe.frontmostAppMenuMaxX()`), and shows
/// nothing once it's granted. The grant is requested ONLY from this
/// explicit button — never silently at launch.
private struct AccessibilityGrantHint: View {
    @State private var isTrusted = MenuBarAccessibilityAccess.isTrusted()

    var body: some View {
        Group {
            if !isTrusted {
                HStack(
                    alignment: .top,
                    spacing: DesignTokens.Spacing.small
                ) {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                    VStack(
                        alignment: .leading,
                        spacing: DesignTokens.Spacing.extraSmall
                    ) {
                        Text(
                            "multiprofile.overflow.accessibility_hint"
                                .localized
                        )
                        .font(DesignTokens.Typography.caption)
                        .foregroundColor(.secondary)
                        Button(
                            "multiprofile.overflow.accessibility_grant_button"
                                .localized
                        ) {
                            MenuBarAccessibilityAccess.requestAccess()
                            if let url = URL(
                                string:
                                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                            ) {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .font(DesignTokens.Typography.caption)
                    }
                }
            }
        }
        .onAppear {
            isTrusted = MenuBarAccessibilityAccess.isTrusted()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            // The user grants access from System Settings, a different
            // app, so this is the moment we can observe the change —
            // there is no direct notification for an AX trust flip.
            isTrusted = MenuBarAccessibilityAccess.isTrusted()
        }
    }
}

/// Inline notice shown under the "Automatic" overflow option when a known
/// menu bar manager (Ice, Thaw, Bartender, ...) is currently running — see
/// `MenuBarManagerDetection` and the guard in
/// `StatusBarUIManager.overflowPlan(for:mode:currentCollapsedCount:spaceInput:runningBundleIdentifiers:)`
/// that this notice exists to explain. Without it, a user who wanted
/// collapsing would just see automatic mode silently stop collapsing and
/// conclude it's broken, rather than that it correctly deferred to the
/// manager they're already running.
private struct DetectedMenuBarManagerHint: View {
    @State private var detectedManager:
        MenuBarManagerDetection.KnownManager? = Self.detect()

    var body: some View {
        Group {
            if let detectedManager {
                HStack(
                    alignment: .top,
                    spacing: DesignTokens.Spacing.small
                ) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.blue)
                    Text(
                        String(
                            format:
                                "multiprofile.overflow.manager_detected_hint"
                                    .localized,
                            detectedManager.displayName
                        )
                    )
                    .font(DesignTokens.Typography.caption)
                    .foregroundColor(.secondary)
                }
            }
        }
        .onAppear {
            detectedManager = Self.detect()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            // A manager launched or quit while this window was in the
            // background is the moment we can next observe it, mirroring
            // `AccessibilityGrantHint` immediately above.
            detectedManager = Self.detect()
        }
    }

    private static func detect() -> MenuBarManagerDetection.KnownManager? {
        MenuBarManagerDetection.detectedManager(
            runningBundleIdentifiers:
                NSWorkspaceRunningApplications().runningBundleIdentifiers
        )
    }
}

// MARK: - Profile Row

struct ProfileRow: View {
    let profile: Profile
    private let dependencies: ProviderUIDependencies
    @ObservedObject private var profileManager: ProfileManager
    @State private var isEditing = false
    @State private var editedName: String = ""
    @State private var deletionAlert: ProfileDeletionAlert?
    @State private var renameAlert: ProfileRenameAlert?

    init(
        profile: Profile,
        dependencies: ProviderUIDependencies
    ) {
        self.profile = profile
        self.dependencies = dependencies
        _profileManager = ObservedObject(
            wrappedValue: dependencies.profileManager
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            // Profile Icon
            Image(systemName: profileIcon)
                .font(.system(size: 24))
                .foregroundColor(profileManager.isActive(profile) ? .accentColor : .secondary)
                .accessibilityLabel(profileAccessibilityLabel)

            VStack(alignment: .leading, spacing: 4) {
                if isEditing {
                    TextField(
                        "profiles.rename_name_placeholder".localized,
                        text: $editedName,
                        onCommit: {
                            saveProfileName()
                        }
                    )
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("profile.rename.field")
                } else {
                    HStack(spacing: 8) {
                        Text(profile.name)
                            .font(.system(size: 14, weight: .medium))

                        if profileManager.isActive(profile) {
                            Text("profiles.active_badge".localized)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor)
                                .cornerRadius(4)
                        }
                    }
                }

                Text(profileInfo)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Actions
            HStack(spacing: 8) {
                if !isEditing {
                    // Rename Button
                    Button(action: {
                        editedName = profile.name
                        isEditing = true
                    }) {
                        Image(systemName: "pencil")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .help("profiles.rename".localized)
                    .accessibilityIdentifier(
                        ProviderUIAccessibility.profileRename
                    )

                    // Activate Button (if not active)
                    if !profileManager.isActive(profile) {
                        Button(action: {
                            Task {
                                await dependencies.activateProfile(
                                    profile.id
                                )
                            }
                        }) {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.plain)
                        .help("profiles.activate".localized)
                        .accessibilityIdentifier(
                            ProviderUIAccessibility.profileActivate
                        )
                    }

                    // Delete Button (if not the last profile)
                    if profileManager.profiles.count > 1 {
                        Button(action: {
                            deletionAlert = .confirmation
                        }) {
                            Image(systemName: "trash")
                                .font(.system(size: 12))
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                        .help("profiles.delete".localized)
                        .accessibilityIdentifier(
                            ProviderUIAccessibility.profileDelete
                        )
                    }
                } else {
                    // Save Button
                    Button(action: {
                        saveProfileName()
                    }) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12))
                            .foregroundColor(.green)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("profile.rename.save")

                    // Cancel Button
                    Button(action: {
                        isEditing = false
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12))
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("profile.rename.cancel")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            "profile.row.\(profile.id.uuidString)"
        )
        .alert(
            "profiles.delete_title".localized,
            isPresented: deletionAlertPresented,
            presenting: deletionAlert
        ) { alert in
            switch alert {
            case .confirmation:
                Button(
                    "common.delete".localized,
                    role: .destructive
                ) {
                    deleteProfile()
                }
                .accessibilityIdentifier(
                    ProviderUIAccessibility.profileDeleteConfirmation
                )
                Button("common.cancel".localized, role: .cancel) {}
                    .accessibilityIdentifier(
                        ProviderUIAccessibility.profileDeleteCancel
                    )
            case .failure:
                Button("common.retry".localized) {
                    deleteProfile()
                }
                .accessibilityIdentifier(
                    ProviderUIAccessibility.profileDeleteRetry
                )
                Button("common.cancel".localized, role: .cancel) {}
                    .accessibilityIdentifier(
                        ProviderUIAccessibility.profileDeleteCancel
                    )
            }
        } message: { alert in
            switch alert {
            case .confirmation:
                Text(
                    String(
                        format: "profiles.delete_confirm".localized,
                        profile.name
                    )
                )
            case .failure(let presentation):
                Text(presentation.message)
            }
        }
        .alert(item: $renameAlert) { alert in
            Alert(
                title: Text(
                    ProviderUILocalization.text(
                        "profiles.rename_failed_title",
                        fallback: "Unable to Rename Profile"
                    )
                ),
                message: Text(alert.message),
                primaryButton: .default(
                    Text("common.retry".localized)
                ) {
                    editedName = alert.attemptedName
                    saveProfileName()
                },
                secondaryButton: .cancel(
                    Text("common.cancel".localized)
                )
            )
        }
    }

    private var profileInfo: String {
        let presentation =
            ProviderProfilePresentation(profile: profile)
        var parts = [presentation.detailText]
        parts.append("\("profiles.created".localized) \(profile.createdAt.formatted(date: .abbreviated, time: .omitted))")

        return parts.joined(separator: " • ")
    }

    private var deletionAlertPresented: Binding<Bool> {
        Binding(
            get: { deletionAlert != nil },
            set: { isPresented in
                if !isPresented {
                    deletionAlert = nil
                }
            }
        )
    }

    private var profileIcon: String {
        ProviderProfilePresentation(
            profile: profile
        ).systemImage
    }

    private var profileAccessibilityLabel: String {
        let active = ProviderUILocalization.text(
            profileManager.isActive(profile)
                ? "profiles.accessibility.active"
                : "profiles.accessibility.inactive",
            fallback: profileManager.isActive(profile)
                ? "active"
                : "inactive"
        )
        return "\(profile.name), \(profileInfo), \(active)"
    }

    private func saveProfileName() {
        if !editedName.isEmpty && editedName != profile.name {
            do {
                try ProfileRowMutation.rename(
                    editedName
                ).perform(
                    profileID: profile.id,
                    dependencies: dependencies
                )
            } catch {
                renameAlert = ProfileRenameAlert(
                    attemptedName: editedName,
                    message: ProfileRenameErrorPresentation(
                        error: error
                    ).message
                )
                return
            }
        }
        isEditing = false
    }

    private func deleteProfile() {
        do {
            try ProfileRowMutation.delete.perform(
                profileID: profile.id,
                dependencies: dependencies
            )
        } catch {
            let presentation = ProfileDeletionErrorPresentation(error: error)

            // Alert actions dismiss the current alert after invoking their
            // closure. Enqueue the failure state so it persists after that
            // dismissal and remains available for retry or cancellation.
            DispatchQueue.main.async {
                deletionAlert = .failure(presentation)
            }
        }
    }
}

struct ProfileRenameAlert: Identifiable {
    let id = UUID()
    let attemptedName: String
    let message: String
}

enum ProfileRowMutation: Equatable {
    case rename(String)
    case delete

    @MainActor
    func perform(
        profileID: UUID,
        dependencies: ProviderUIDependencies
    ) throws {
        switch self {
        case .rename(let name):
            try dependencies.updateName(
                name,
                profileID: profileID
            )
        case .delete:
            try dependencies.deleteProfile(profileID)
        }
    }
}

struct ProfileRenameErrorPresentation: Equatable {
    static var genericMessage: String {
        ProviderUILocalization.text(
            "profiles.rename_failed_message",
            fallback: "Unable to rename this profile. Please try again."
        )
    }

    let message: String

    init(error: Error) {
        if let localizedError = error as? any LocalizedError,
           let description = localizedError.errorDescription?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty {
            message = description
        } else {
            message = Self.genericMessage
        }
    }
}

enum ProfileDeletionAlert: Identifiable {
    case confirmation
    case failure(ProfileDeletionErrorPresentation)

    var id: String {
        switch self {
        case .confirmation:
            return "confirmation"
        case .failure:
            return "failure"
        }
    }
}

struct ProfileDeletionErrorPresentation: Equatable {
    static var genericMessage: String {
        ProviderUILocalization.text(
            "profiles.delete_failed_message",
            fallback: "Unable to delete this profile. Please try again."
        )
    }

    let message: String

    init(error: Error) {
        // Only use an intentionally authored LocalizedError description. Do not
        // bridge arbitrary Error/NSError payloads through localizedDescription:
        // those may include an underlying message or credential material.
        if let localizedError = error as? any LocalizedError,
           let description = localizedError.errorDescription?.trimmingCharacters(
               in: .whitespacesAndNewlines
           ),
           !description.isEmpty {
            message = description
        } else {
            message = Self.genericMessage
        }
    }
}

// MARK: - Create Profile Sheet

struct CreateProfileSheet: View {
    @Binding var profileName: String
    @Binding var provider: ProfileProviderKind
    @Binding var codexHomePath: String
    let codexAvailable: Bool
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("profiles.create_title".localized)
                .font(.system(size: 18, weight: .semibold))

            VStack(alignment: .leading, spacing: 8) {
                Text("profiles.name_label".localized)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                TextField("profiles.name_placeholder".localized, text: $profileName)
                    .textFieldStyle(.roundedBorder)

                Text("profiles.name_hint".localized)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)

                Text(
                    ProviderUILocalization.text(
                        "profiles.provider_label",
                        fallback: "Provider"
                    )
                )
                .font(.system(size: 12))
                .foregroundColor(.secondary)

                Picker("", selection: $provider) {
                    Text("setup.provider.claude_title".localized)
                        .tag(ProfileProviderKind.claude)
                    Text("setup.provider.codex_title".localized)
                        .tag(ProfileProviderKind.codex)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("profile.create.provider")
                .onChange(of: provider) { _, newProvider in
                    if newProvider == .codex && !codexAvailable {
                        provider = .claude
                    }
                }

                if provider == .codex {
                    HStack {
                        TextField(
                            ProviderUILocalization.text(
                                "codex.home.placeholder",
                                fallback:
                                    "Choose a CODEX_HOME directory"
                            ),
                            text: $codexHomePath
                        )
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier(
                            ProviderUIAccessibility.homePath
                        )

                        Button {
                            chooseCodexHome()
                        } label: {
                            Image(systemName: "folder")
                        }
                        .accessibilityIdentifier(
                            ProviderUIAccessibility.homePicker
                        )
                    }

                    Text(
                        ProviderUILocalization.text(
                            "codex.credentials.owned_by_codex",
                            fallback:
                                "Credentials remain in this directory and are managed only by Codex."
                        )
                    )
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                }

                if !codexAvailable {
                    Text(
                        ProviderUILocalization.text(
                            "codex.feature_unavailable",
                            fallback:
                                "Codex support is not available in this build."
                        )
                    )
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .accessibilityIdentifier(
                        ProviderUIAccessibility.capabilityDisabled
                    )
                }
            }

            HStack(spacing: 12) {
                Button("common.cancel".localized) {
                    onCancel()
                }
                .buttonStyle(.plain)

                Button("common.create".localized) {
                    onSave()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    provider == .codex
                        && (!codexAvailable
                            || codexHomePath.isEmpty)
                )
                .accessibilityIdentifier(
                    ProviderUIAccessibility.profileCreateConfirmation
                )
            }
        }
        .padding(24)
        .frame(width: 400)
    }

    private func chooseCodexHome() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            codexHomePath = url.path
        }
    }
}
