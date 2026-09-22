//
//  LicensesView.swift
//  Claude Usage - Bundled License Texts
//
//  Created by Claude Code on 2026-08-12.
//

import SwiftUI

/// Sheet showing the full text of every license bundled with the app,
/// including third-party dependencies (e.g. Sparkle). Presented from
/// `AboutView` so the MIT permission notice and warranty disclaimer travel
/// with the app rather than only being referenced by name.
struct LicensesView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("about.licenses_title".localized)
                    .font(.system(size: 16, weight: .semibold))

                Spacer()

                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(SettingsColors.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.section) {
                    ForEach(LicenseResourceService.bundledLicenses) { license in
                        LicenseSection(license: license)
                    }
                }
                .padding()
            }
        }
        .frame(width: 640, height: 560)
    }
}

// MARK: - License Section

private struct LicenseSection: View {
    let license: BundledLicense

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
            Text(license.sectionTitleKey.localized)
                .font(.system(size: 13, weight: .semibold))

            Text(licenseText)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(6)
        }
    }

    private var licenseText: String {
        LicenseResourceService.loadText(for: license)
            ?? "about.licenses_unavailable".localized
    }
}

// MARK: - Previews

#Preview {
    LicensesView()
}
