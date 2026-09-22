//
//  IconStylePicker.swift
//  Claude Usage - Icon Style Selection Component
//
//  Created by Claude Code on 2025-12-20.
//

import SwiftUI

/// Custom picker for menu bar icon styles with visual previews
struct IconStylePicker: View {
    @Binding var selectedStyle: MenuBarIconStyle

    var body: some View {
        GeometryReader { geometry in
            let cardWidth = (geometry.size.width - (12 * 4)) / 5  // 5 cards with 12px spacing
            HStack(alignment: .top, spacing: 12) {
                ForEach(MenuBarIconStyle.allCases, id: \.self) { style in
                    IconStyleCard(
                        style: style,
                        isSelected: selectedStyle == style,
                        cardWidth: cardWidth,
                        action: {
                            selectedStyle = style
                        }
                    )
                }
            }
        }
        .frame(height: 80)  // Fixed height for the picker
    }
}

/// Individual icon style card
private struct IconStyleCard: View {
    let style: MenuBarIconStyle
    let isSelected: Bool
    let cardWidth: CGFloat
    let action: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            // Clickable icon area
            Button(action: action) {
                IconPreviewLarge(style: style)
                    .frame(width: cardWidth, height: 50)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isSelected ? SettingsColors.primary.opacity(0.12) : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(
                                isSelected ? SettingsColors.accentText : SettingsColors.border,
                                lineWidth: isSelected ? 2 : 1
                            )
                    )
                    .overlay(alignment: .topTrailing) {
                        // The ring alone tells selection by hue; the mark
                        // tells it by shape.
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(SettingsColors.accentText)
                                .padding(3)
                                .accessibilityHidden(true)
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            // Name - outside border
            Text(style.displayName)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(isSelected ? .primary : SettingsColors.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: cardWidth)
        }
        .frame(width: cardWidth)
    }
}

/// Large icon style preview for cards
private struct IconPreviewLarge: View {
    let style: MenuBarIconStyle

    var body: some View {
        VStack(spacing: 3) {
            // Icon representation
            switch style {
            case .battery:
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.secondary.opacity(0.3))
                        .frame(width: 40, height: 8)
                        .overlay(
                            GeometryReader { geo in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(SettingsColors.success)
                                    .frame(width: geo.size.width * 0.6)
                                    .padding(1.5)
                            }
                        )
                    Text("Claude")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(SettingsColors.secondary)
                }

            case .progressBar:
                RoundedRectangle(cornerRadius: 3)
                    .fill(.secondary.opacity(0.3))
                    .frame(width: 40, height: 8)
                    .overlay(
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(SettingsColors.success)
                                .frame(width: geo.size.width * 0.6)
                        }
                    )

            case .percentageOnly:
                Text("60%")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(SettingsColors.success)

            case .icon:
                ZStack {
                    Circle()
                        .stroke(.secondary.opacity(0.2), lineWidth: 3)
                        .frame(width: 30, height: 30)

                    Circle()
                        .trim(from: 0, to: 0.6)
                        .stroke(SettingsColors.success, lineWidth: 3)
                        .frame(width: 30, height: 30)
                        .rotationEffect(.degrees(-90))
                }

            case .compact:
                Circle()
                    .fill(SettingsColors.success)
                    .frame(width: 10, height: 10)
            }
        }
    }
}

// MARK: - Previews

#Preview("Icon Style Picker") {
    IconStylePicker(selectedStyle: .constant(.battery))
        .padding()
        .frame(width: 480)
}

#Preview("All States") {
    VStack(spacing: 16) {
        ForEach(MenuBarIconStyle.allCases, id: \.self) { style in
            IconStylePicker(selectedStyle: .constant(style))
                .padding()
        }
    }
    .frame(width: 480)
}
