//
//  SupportView.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-01-30.
//

import SwiftUI
import AppKit

/// Support and contribution entry points for the Revenium-owned project.
struct SupportView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                // Header
                VStack(spacing: 16) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.pink, .red],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    Text("support.title".localized)
                        .font(.system(size: 24, weight: .bold))

                    Text("support.subtitle".localized)
                        .font(.system(size: 14))
                        .foregroundColor(SettingsColors.secondary)
                }
                .padding(.top, 20)

                // Main message
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(SettingsColors.success)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("support.all_features_free".localized)
                                .font(.system(size: 14, weight: .semibold))
                            Text("support.all_features_desc".localized)
                                .font(.system(size: 13))
                                .foregroundColor(SettingsColors.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "lock.open.fill")
                            .font(.system(size: 18))
                            .foregroundColor(SettingsColors.info)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("support.open_source".localized)
                                .font(.system(size: 14, weight: .semibold))
                            Text("support.open_source_desc".localized)
                                .font(.system(size: 13))
                                .foregroundColor(SettingsColors.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "hand.raised.fill")
                            .font(.system(size: 18))
                            .foregroundColor(SettingsColors.warning)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("support.no_tracking".localized)
                                .font(.system(size: 14, weight: .semibold))
                            Text("support.no_tracking_desc".localized)
                                .font(.system(size: 13))
                                .foregroundColor(SettingsColors.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(20)
                .background(SettingsColors.cardBackground)
                .cornerRadius(12)

                // Support section
                VStack(spacing: 16) {
                    Text("support.message".localized)
                        .font(.system(size: 13))
                        .foregroundColor(SettingsColors.secondary)
                        .multilineTextAlignment(.center)

                    Button(action: openIssues) {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.bubble.fill")
                                .font(.system(size: 16))
                            Text("about.report_issue".localized)
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(SettingsColors.cardBackground)
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }

                // GitHub star
                VStack(spacing: 12) {
                    Text("support.also_support".localized)
                        .font(.system(size: 12))
                        .foregroundColor(SettingsColors.secondary)

                    Button(action: {
                        if let url = URL(string: Constants.GitHub.repoURL) {
                            NSWorkspace.shared.open(url)
                        }
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 14))
                            Text("support.star_github".localized)
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundColor(.primary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(SettingsColors.cardBackground)
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(SettingsColors.border, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }
            .padding(28)
        }
    }

    private func openIssues() {
        guard let url = URL(string: Constants.GitHub.issuesURL) else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Previews

#Preview {
    SupportView()
        .frame(width: 520, height: 600)
}
