//
//  SettingsStatusViews.swift
//  Claude Usage - Settings Design System
//

import SwiftUI

/// A solid-fill capsule badge ("BETA", "Active", "Working") whose text is
/// black or white, whichever reads on the tone.
struct SettingsBadge: View {
    let text: String
    let tone: SettingsTone
    var font: Font = .system(size: 9, weight: .bold)

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(tone.textOn)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tone.color))
    }
}

/// A status mark that carries its meaning in shape as well as hue, so it
/// still reads when the person cannot tell green from orange.
struct SettingsStatusGlyph: View {
    enum Kind {
        case ok
        case warning
        case error
        case info
        case inactive

        var symbol: String {
            switch self {
            case .ok: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .error: return "xmark.circle.fill"
            case .info: return "info.circle.fill"
            case .inactive: return "circle"
            }
        }

        var tone: SettingsTone {
            switch self {
            case .ok: return .success
            case .warning: return .warning
            case .error: return .error
            case .info: return .info
            case .inactive: return .neutral
            }
        }
    }

    let kind: Kind
    var size: CGFloat = 12

    var body: some View {
        Image(systemName: kind.symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(kind.tone.color)
            .accessibilityHidden(true)
    }
}

/// A tinted message panel. The icon carries the hue; the text stays the
/// system label color, because colored body text on a tint of the same hue
/// cannot reach 4.5:1 for red in dark mode.
struct SettingsStatusBanner<Content: View>: View {
    let tone: SettingsTone
    let icon: String
    let content: Content

    init(
        tone: SettingsTone,
        icon: String,
        @ViewBuilder content: () -> Content
    ) {
        self.tone = tone
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tone.color)
                .accessibilityHidden(true)

            content
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.color.opacity(Self.fillOpacity))
        .clipShape(RoundedRectangle(cornerRadius: Spacing.radiusLarge))
        .overlay {
            RoundedRectangle(cornerRadius: Spacing.radiusLarge)
                .strokeBorder(tone.color.opacity(Self.borderOpacity), lineWidth: 1)
        }
    }

    static var fillOpacity: Double { 0.10 }
    static var borderOpacity: Double { 0.40 }
}

extension SettingsStatusBanner where Content == Text {
    init(tone: SettingsTone, icon: String, text: String) {
        self.init(tone: tone, icon: icon) {
            Text(text).font(Typography.body)
        }
    }
}
