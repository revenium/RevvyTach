//
//  ProfileSelectionRow.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-01-22.
//

import SwiftUI
import UsageCore

/// Compact row for selecting profiles in multi-profile display mode
struct ProfileSelectionRow: View {
    let profile: Profile
    let isSelected: Bool
    let isActive: Bool
    let onToggle: () -> Void
    @ObservedObject private var catalogStore =
        ProviderMenuCatalogStore.shared

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: DesignTokens.Spacing.small) {
                // Checkbox
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundColor(isSelected ? SettingsColors.accentText : SettingsColors.secondary)

                // Profile name (truncated)
                Text(profile.name)
                    .font(DesignTokens.Typography.body)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(
                    ProviderAppearance.forProvider(
                        profile.providerID
                    ).compactBadge
                )
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.primary)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.secondary, lineWidth: 1)
                )

                // Active badge
                if isActive {
                    SettingsBadge(
                        text: "multiprofile.active_badge".localized,
                        tone: .accent
                    )
                }

                Spacer()

                // Metric indicators (compact badges showing enabled metrics)
                HStack(spacing: 4) {
                    ForEach(
                        Array(enabledMetrics.prefix(2).enumerated()),
                        id: \.element.metricID
                    ) { index, metric in
                        MetricBadge(
                            letter: badgeLetter(
                                for: metric,
                                dynamicIndex: index
                            ),
                            color: profile.providerID == .claude
                                ? legacyBadgeColor(for: metric)
                                : SettingsColors.success
                        )
                    }
                    if enabledMetrics.count > 2 {
                        MetricBadge(letter: "+", color: .secondary)
                    }
                }
            }
            .padding(.vertical, DesignTokens.Spacing.extraSmall)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Computed Properties

    private var enabledMetrics: [MetricIconConfig] {
        Self.displayedMetrics(
            for: profile,
            catalog: catalogStore.catalog(
                for: profile,
                configuration: profile.iconConfig
                    .adaptedForProvider(profile.providerID)
            )
        )
    }

    static func displayedMetrics(
        for profile: Profile,
        catalog: [ProviderMetricDescriptor]
    ) -> [MetricIconConfig] {
        profile.iconConfig
            .adaptedForProvider(profile.providerID)
            .resolvedMetrics(catalog: catalog)
    }

    private func badgeLetter(
        for metric: MetricIconConfig,
        dynamicIndex: Int
    ) -> String {
        switch metric.metricID.legacyMetricType {
        case .session: return "S"
        case .week: return "W"
        case .api: return "A"
        case nil: return "\(dynamicIndex + 1)"
        }
    }

    private func legacyBadgeColor(
        for metric: MetricIconConfig
    ) -> Color {
        switch metric.metricID.legacyMetricType {
        case .session: return SettingsColors.info
        case .week: return SettingsColors.proBadge
        case .api: return SettingsColors.warning
        case nil: return SettingsColors.success
        }
    }
}

// MARK: - Metric Badge

/// Small badge showing metric type (S, W, A)
private struct MetricBadge: View {
    let letter: String
    let color: Color

    var body: some View {
        Text(letter)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(color)
            .frame(width: 16, height: 16)
            .background(
                Circle()
                    .fill(color.opacity(0.15))
            )
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 8) {
        ProfileSelectionRow(
            profile: Profile(name: "Work Profile"),
            isSelected: true,
            isActive: true,
            onToggle: {}
        )

        ProfileSelectionRow(
            profile: Profile(name: "Personal Account"),
            isSelected: true,
            isActive: false,
            onToggle: {}
        )

        ProfileSelectionRow(
            profile: Profile(name: "Test Environment"),
            isSelected: false,
            isActive: false,
            onToggle: {}
        )
    }
    .padding()
    .frame(width: 400)
}
