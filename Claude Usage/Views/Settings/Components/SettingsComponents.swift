//
//  SettingsCard2.swift
//  Claude Usage - Reusable Settings Card Component
//
//  A consistent, reusable card container for all settings sections
//  (Named SettingsCard2 to avoid conflict with SettingsSection enum)
//

import SwiftUI

/// A small pill next to a `SettingsSectionCard` title — e.g. "Optional"/
/// "Required" on the Codex CLI-switching card — matching the capsule style
/// already used for `SettingToggle`'s BETA/PRO/NEW badges and the profile
/// list's "Active" badge, rather than folding the state into the title
/// string. Not nested inside `SettingsSectionCard` so call sites don't have
/// to spell out its unrelated `Content` generic parameter to name this type.
struct SettingsSectionCardBadge {
    let text: String
    let tone: SettingsTone

    init(_ text: String, tone: SettingsTone) {
        self.text = text
        self.tone = tone
    }
}

/// Reusable card container for settings sections
/// Provides consistent header, divider, content layout with proper styling
struct SettingsSectionCard<Content: View>: View {
    let title: String
    let subtitle: String?
    /// Additive and optional: existing call sites that don't pass one are
    /// unaffected.
    let titleBadge: SettingsSectionCardBadge?
    let content: Content

    init(
        title: String,
        subtitle: String? = nil,
        titleBadge: SettingsSectionCardBadge? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.titleBadge = titleBadge
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.extraSmall) {
                HStack(spacing: DesignTokens.Spacing.small) {
                    Text(title)
                        .font(DesignTokens.Typography.sectionTitle)
                        .foregroundColor(SettingsColors.secondary)

                    if let titleBadge {
                        SettingsBadge(text: titleBadge.text, tone: titleBadge.tone)
                    }
                }

                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(DesignTokens.Typography.sectionSubtitle)
                        .foregroundColor(SettingsColors.secondary)
                }
            }
            .padding(DesignTokens.Spacing.cardPadding)
            .padding(.bottom, DesignTokens.Spacing.extraSmall)

            Divider()

            // Content
            content
                .padding(DesignTokens.Spacing.cardPadding)
        }
        .background(SettingsColors.cardBackground)
        .cornerRadius(DesignTokens.Radius.card)
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.card)
                .strokeBorder(SettingsColors.border, lineWidth: 1)
        )
    }
}

/// Simpler version without header - just a content card
struct SettingsContentCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(DesignTokens.Spacing.cardPadding)
            .background(SettingsColors.cardBackground)
            .cornerRadius(DesignTokens.Radius.card)
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.card)
                    .strokeBorder(SettingsColors.border, lineWidth: 1)
            )
    }
}

/// Page header component - reusable across all settings tabs
struct SettingsPageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(DesignTokens.Typography.pageTitle)
            Text(subtitle)
                .font(DesignTokens.Typography.pageSubtitle)
                .foregroundColor(SettingsColors.secondary)
        }
    }
}

// MARK: - Bullet Point Helper

/// A simple bullet point view for displaying lists
struct BulletPoint: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Text("•")
            Text(text)
        }
    }
}

// MARK: - Preview

#Preview {
    ScrollView {
        VStack(alignment: .leading, spacing: 24) {
            SettingsPageHeader(
                title: "Example Settings",
                subtitle: "This is how the page header looks"
            )

            SettingsSectionCard(
                title: "Example Section",
                subtitle: "This is a subtitle description"
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Content goes here")
                    Toggle("Some Toggle", isOn: .constant(true))
                }
            }

            SettingsContentCard {
                Text("Simple content card without header")
            }
        }
        .padding()
    }
    .frame(width: 500, height: 600)
}
