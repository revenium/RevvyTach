//
//  AppearanceSettingsView.swift
//  Claude Usage - Menu Bar Appearance Settings
//
//  Created by Claude Code on 2025-12-27.
//

import SwiftUI
import UsageCore

/// Menu bar icon appearance and customization with multi-metric support
struct AppearanceSettingsView: View {
    @ObservedObject private var profileManager: ProfileManager
    @ObservedObject private var catalogStore =
        ProviderMenuCatalogStore.shared
    @State private var configuration: MenuBarIconConfiguration = .default
    @State private var saveDebounceTimer: Timer?
    private let metricCatalogProvider:
        ((Profile) -> [ProviderMetricDescriptor])?

    @MainActor
    init(
        profileManager: ProfileManager? = nil,
        metricCatalogProvider:
            ((Profile) -> [ProviderMetricDescriptor])? = nil
    ) {
        _profileManager = ObservedObject(
            wrappedValue: profileManager ?? .shared
        )
        self.metricCatalogProvider = metricCatalogProvider
    }

    private var isMultiProfileMode: Bool {
        profileManager.displayMode == .multi
    }

    private var activeProfile: Profile? {
        profileManager.activeProfile
    }

    private var activeProfileAccessibilityValue: String {
        guard let activeProfile else {
            return "none|none"
        }
        return [
            activeProfile.id.uuidString.lowercased(),
            activeProfile.providerID.rawValue
        ].joined(separator: "|")
    }

    private var isProviderNeutralCatalog: Bool {
        activeProfile?.providerID != .claude
    }

    private var providerCatalog: [ProviderMetricDescriptor] {
        guard let activeProfile else { return [] }
        if let metricCatalogProvider {
            return metricCatalogProvider(activeProfile)
        }
        return catalogStore.catalog(
            for: activeProfile,
            configuration: configuration
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.section) {
                // Page Header
                SettingsPageHeader(
                    title: "appearance.title".localized,
                    subtitle: "appearance.subtitle".localized
                )

                // Multi-profile mode warning
                if isMultiProfileMode {
                    MultiProfileModeWarningCard(
                        onDisableMultiProfile: {
                            Self.disableMultiProfile {
                                profileManager.updateDisplayMode(.single)
                            }
                        }
                    )
                }

                // Global Settings
                SettingsSectionCard(
                    title: "appearance.global_settings".localized,
                    subtitle: "appearance.global_subtitle".localized
                ) {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.cardPadding) {
                        SettingToggle(
                            title: "appearance.monochrome_title".localized,
                            description: "appearance.monochrome_description".localized,
                            isOn: Binding(
                                get: { configuration.colorMode == .monochrome },
                                set: { newValue in
                                    configuration.colorMode = newValue ? .monochrome : .multiColor
                                    saveConfiguration()
                                }
                            )
                        )

                        SettingToggle(
                            title: "appearance.show_labels_title".localized,
                            description: "appearance.show_labels_description".localized,
                            isOn: Binding(
                                get: { configuration.showIconNames },
                                set: { newValue in
                                    configuration.showIconNames = newValue
                                    saveConfiguration()
                                }
                            )
                        )

                        SettingToggle(
                            title: "appearance.show_remaining_title".localized,
                            description: "appearance.show_remaining_description".localized,
                            isOn: Binding(
                                get: { configuration.showRemainingPercentage },
                                set: { newValue in
                                    configuration.showRemainingPercentage = newValue
                                    saveConfiguration()
                                }
                            )
                        )

                        SettingToggle(
                            title: "appearance.show_time_marker_title".localized,
                            description: "appearance.show_time_marker_description".localized,
                            isOn: Binding(
                                get: { configuration.showTimeMarker },
                                set: { newValue in
                                    configuration.showTimeMarker = newValue
                                    saveConfiguration()
                                }
                            )
                        )

                        SettingToggle(
                            title: "appearance.show_pace_marker_title".localized,
                            description: "appearance.show_pace_marker_description".localized,
                            isOn: Binding(
                                get: { configuration.showPaceMarker },
                                set: { newValue in
                                    configuration.showPaceMarker = newValue
                                    saveConfiguration()
                                }
                            )
                        )

                        SettingToggle(
                            title: "appearance.pace_coloring_title".localized,
                            description: "appearance.pace_coloring_description".localized,
                            isOn: Binding(
                                get: { configuration.usePaceColoring },
                                set: { newValue in
                                    configuration.usePaceColoring = newValue
                                    saveConfiguration()
                                }
                            )
                        )
                    }
                }
                .disabled(isMultiProfileMode)
                .opacity(isMultiProfileMode ? 0.5 : 1.0)

                // Provider Badge — global across display modes, so it lives
                // outside the single-profile-only card above and stays
                // usable in multi-profile mode too.
                SettingsSectionCard(
                    title: NSLocalizedString(
                        "appearance.provider_badge_title",
                        value: "Provider badge",
                        comment: ""
                    ),
                    subtitle: NSLocalizedString(
                        "appearance.provider_badge_description",
                        value: "Distinguish Claude and Codex items in the menu bar without clicking.",
                        comment: ""
                    )
                ) {
                    providerBadgeToggles
                }

                // Metrics Configuration
                SettingsSectionCard(
                    title: "appearance.menu_bar_metrics".localized,
                    subtitle: "appearance.metrics_subtitle".localized
                ) {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                        // Info message when all metrics are disabled
                        if configuration.metricSelectionMode == .custom,
                           configuration.metrics.filter({
                               $0.isEnabled
                           }).isEmpty {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "info.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundColor(SettingsColors.info)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("appearance.all_metrics_off_title".localized)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(.primary)

                                    Text("appearance.all_metrics_off_description".localized)
                                        .font(.system(size: 10))
                                        .foregroundColor(SettingsColors.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(DesignTokens.Spacing.small)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(SettingsColors.info.opacity(0.1))
                            )
                        }

                        if isProviderNeutralCatalog {
                            providerMetricConfiguration
                        } else {
                            legacyClaudeMetricConfiguration
                        }
                    }
                }
                .disabled(isMultiProfileMode)
                .opacity(isMultiProfileMode ? 0.5 : 1.0)

                Spacer()
            }
            .padding()
        }
        .accessibilityIdentifier("settings.appearance.surface")
        .accessibilityValue(activeProfileAccessibilityValue)
        .onAppear {
            // Load configuration from active profile
            if let activeProfile = profileManager.activeProfile {
                configuration = activeProfile.iconConfig
                    .adaptedForProvider(activeProfile.providerID)
            }
        }
        .onChange(of: profileManager.activeProfile?.id) { _, newProfileId in
            // Reload configuration when profile changes
            if let activeProfile = profileManager.activeProfile {
                configuration = activeProfile.iconConfig
                    .adaptedForProvider(activeProfile.providerID)
            }
        }
    }

    // MARK: - Helper Methods

    /// Lets the user independently enable a provider glyph and/or a provider
    /// background tint so Claude vs Codex status items are visually
    /// distinguished in the menu bar without clicking. Both default off
    /// (unchanged current behavior); turning both on is the combined look —
    /// there is no separate combined option. Global (like
    /// `multiProfileConfig`), not per-profile, since it applies to every
    /// provider's status items at once.
    @ViewBuilder
    private var providerBadgeToggles: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.cardPadding) {
            SettingToggle(
                title: NSLocalizedString(
                    "appearance.provider_badge_glyph_title",
                    value: "Provider glyph",
                    comment: ""
                ),
                description: NSLocalizedString(
                    "appearance.provider_badge_glyph_description",
                    value: "Show a small provider mark before each item's content.",
                    comment: ""
                ),
                isOn: Binding(
                    get: { profileManager.providerBadgeGlyphEnabled },
                    set: { newValue in
                        profileManager.updateProviderBadgeGlyphEnabled(newValue)
                    }
                )
            )

            SettingToggle(
                title: NSLocalizedString(
                    "appearance.provider_badge_tint_title",
                    value: "Provider background tint",
                    comment: ""
                ),
                description: NSLocalizedString(
                    "appearance.provider_badge_tint_description",
                    value: "Show a faint provider-colored background behind each item.",
                    comment: ""
                ),
                isOn: Binding(
                    get: { profileManager.providerBadgeTintEnabled },
                    set: { newValue in
                        profileManager.updateProviderBadgeTintEnabled(newValue)
                    }
                )
            )
        }
    }

    @ViewBuilder
    private var legacyClaudeMetricConfiguration: some View {
        ForEach(
            MenuBarMetricType.allCases.filter { metricType in
                configuration.metrics.contains {
                    $0.metricID.legacyMetricType == metricType
                }
            }
        ) { metricType in
            if let index = configuration.metrics.firstIndex(
                where: { $0.metricID.legacyMetricType == metricType }
            ) {
                MetricIconCard(
                    metricType: metricType,
                    config: Binding(
                        get: { configuration.metrics[index] },
                        set: { configuration.metrics[index] = $0 }
                    ),
                    onConfigChanged: saveConfiguration
                )
            }
        }
    }

    @ViewBuilder
    private var providerMetricConfiguration: some View {
        SettingToggle(
            title: NSLocalizedString(
                "appearance.metric_selection.automatic.title",
                value: "Choose a metric automatically",
                comment: ""
            ),
            description: NSLocalizedString(
                "appearance.metric_selection.automatic.description",
                value: "Shows the first usable provider limit and adapts when the provider adds or removes windows.",
                comment: ""
            ),
            isOn: Binding(
                get: {
                    configuration.metricSelectionMode == .automatic
                },
                set: { automatic in
                    configuration.metricSelectionMode =
                        automatic ? .automatic : .custom
                    if !automatic {
                        var seeded = configuration
                        for (index, descriptor) in
                            providerCatalog.enumerated()
                        where seeded.config(for: descriptor.id) == nil {
                            seeded.updateConfig(
                                MetricIconConfig(
                                    metricID: descriptor.id,
                                    isEnabled: false,
                                    order: index
                                )
                            )
                        }
                        seeded.metricSelectionMode = .custom
                        configuration = seeded
                    }
                    saveConfiguration()
                }
            )
        )

        if configuration.metricSelectionMode == .automatic {
            let selected = providerCatalog.first(where: \.isUsable)
            Text(
                selected.map {
                    String(
                        format: NSLocalizedString(
                            "appearance.metric_selection.automatic.selected",
                            value: "Automatic: %@ — %@",
                            comment: ""
                        ),
                        $0.groupName,
                        $0.metricName
                    )
                } ?? NSLocalizedString(
                    "appearance.metric_selection.waiting",
                    value: "Waiting for the provider to publish a usable limit.",
                    comment: ""
                )
            )
            .font(.system(size: 10))
            .foregroundColor(SettingsColors.secondary)
        } else if providerCatalog.isEmpty {
            Text(
                NSLocalizedString(
                    "appearance.metric_selection.unavailable",
                    value: "Refresh this profile to discover its available usage limits.",
                    comment: ""
                )
            )
            .font(.system(size: 10))
            .foregroundColor(SettingsColors.secondary)
        } else {
            ForEach(providerCatalog) { descriptor in
                ProviderMetricSettingsRow(
                    descriptor: descriptor,
                    config: providerMetricBinding(for: descriptor),
                    onConfigChanged: saveConfiguration
                )
            }
        }
    }

    private func providerMetricBinding(
        for descriptor: ProviderMetricDescriptor
    ) -> Binding<MetricIconConfig> {
        Binding(
            get: {
                configuration.config(for: descriptor.id)
                    ?? MetricIconConfig(metricID: descriptor.id)
            },
            set: { newValue in
                configuration.updateConfig(newValue)
            }
        )
    }

    static func disableMultiProfile(
        updateDisplayMode: () -> Void,
        queue: DispatchQueue = .main,
        center: NotificationCenter = .default
    ) {
        updateDisplayMode()
        MenuBarNotificationDelivery.enqueue(
            .displayModeChanged,
            queue: queue,
            center: center
        )
    }

    private func saveConfiguration() {
        // Allow all metrics to be disabled - will show default app logo
        // No minimum enforcement needed

        // Save to active profile
        guard let profileId = profileManager.activeProfile?.id else {
            LoggingService.shared.logError("Cannot save appearance: no active profile")
            return
        }

        profileManager.updateIconConfig(configuration, for: profileId)

        // Notify that config changed (for MenuBarManager to update)
        NotificationCenter.default.post(name: .menuBarIconConfigChanged, object: nil)

        let enabledCount = configuration.metrics.filter { $0.isEnabled }.count
        LoggingService.shared.log("Saved icon configuration to profile (enabled: \(enabledCount))")
    }
}

private struct ProviderMetricSettingsRow: View {
    let descriptor: ProviderMetricDescriptor
    @Binding var config: MetricIconConfig
    let onConfigChanged: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
            HStack {
                Image(
                    systemName: ProviderAppearance.forProvider(
                        descriptor.providerID
                    ).symbolName
                )
                .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(descriptor.groupName) — \(descriptor.metricName)")
                        .font(DesignTokens.Typography.body)
                    if let reason = descriptor.unavailableReason {
                        Text(reason)
                            .font(.system(size: 10))
                            .foregroundColor(SettingsColors.secondary)
                    }
                }
                Spacer()
                Toggle(
                    "",
                    isOn: Binding(
                        get: { config.isEnabled },
                        set: {
                            config.isEnabled = $0
                            onConfigChanged()
                        }
                    )
                )
                .labelsHidden()
                .disabled(!descriptor.isUsable)
            }
            if config.isEnabled && descriptor.isUsable {
                IconStylePicker(
                    selectedStyle: Binding(
                        get: { config.iconStyle },
                        set: {
                            config.iconStyle = $0
                            onConfigChanged()
                        }
                    )
                )
            }
        }
        .padding(DesignTokens.Spacing.small)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(SettingsColors.cardBackground)
        )
        .opacity(descriptor.isUsable ? 1 : 0.6)
    }
}

// MARK: - Multi-Profile Mode Warning Card

struct MultiProfileModeWarningCard: View {
    let onDisableMultiProfile: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
            HStack(alignment: .top, spacing: DesignTokens.Spacing.small) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 16))
                    .foregroundColor(SettingsColors.warning)

                VStack(alignment: .leading, spacing: 4) {
                    Text("appearance.multiprofile_locked_title".localized)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)

                    Text("appearance.multiprofile_locked_description".localized)
                        .font(.system(size: 11))
                        .foregroundColor(SettingsColors.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }

            Button(action: onDisableMultiProfile) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 10))
                    Text("appearance.disable_multiprofile".localized)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(SettingsColors.warning)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(SettingsColors.warning, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(DesignTokens.Spacing.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.card)
                .fill(SettingsColors.warning.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.card)
                .stroke(SettingsColors.warning.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Previews

#Preview {
    AppearanceSettingsView()
        .frame(width: 520, height: 600)
}
