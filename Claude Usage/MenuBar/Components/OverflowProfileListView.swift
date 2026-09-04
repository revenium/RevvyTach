//
//  OverflowProfileListView.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-08-07.
//

import SwiftUI

/// One row in the overflow profile list: a profile's name and both of its
/// usage windows, with the exact text `MenuBarManager` already renders for a
/// status item (see
/// `ProviderMenuPresentationBuilder`/`ProviderMetricPresentation`), so this
/// list never invents a second source of truth for "what percentage is this
/// profile at".
struct OverflowProfileRow: Identifiable, Equatable {
    /// One usage window as this list states it.
    struct Window: Equatable {
        /// Always `ProviderMetricPresentation.descriptor.metricName` — the
        /// same localized name Appearance settings and the popover show.
        /// Never fetched from the localization key here; that would be the
        /// second source of truth this type exists to avoid.
        let name: String

        /// `nil` means "no reading" — not zero. The view renders the dash,
        /// so nothing downstream has to recognise it in a rendered string.
        let percentageText: String?

        /// "used" or "remaining". Spoken by VoiceOver only: the visible row
        /// has never carried a polarity marker, and a whole list shares one
        /// polarity, so the word would be noise on screen and is the only
        /// cue a VoiceOver user gets.
        let modeText: String
    }

    let id: UUID
    let name: String
    let windows: [Window]
}

extension OverflowProfileRow {
    /// The same em dash `ProviderMetricPresentation.percentageText` uses for
    /// a window it has no figure for.
    static let noReadingText = "—"

    /// "Session 42% · Week 78%", or a single dash when no window was read.
    ///
    /// The dash describes the *account*, not each window: a row with one
    /// window missing still names both, so the dash says which one is
    /// missing, but a row with nothing at all is one dash rather than a
    /// grid of them.
    var valueText: String {
        guard windows.contains(where: { $0.percentageText != nil }) else {
            return Self.noReadingText
        }
        return windows
            .map { "\($0.name) \($0.percentageText ?? Self.noReadingText)" }
            .joined(separator: " · ")
    }

    /// "Session 42% used, Week 78% used", or the localized "no usage data".
    ///
    /// Shape borrowed from
    /// `StatusBarUIManager.compactPercentageAccessibilityLabel`, the
    /// reviewed label for the status item that already packs two windows.
    /// Collapses on exactly the condition `valueText` collapses on, so the
    /// dash and the spoken phrase always describe the same input.
    var accessibilityValueText: String {
        let noReading = ProviderUILocalization.text(
            "menubar.accessibility.state.no_data",
            fallback: "no usage data"
        )
        guard windows.contains(where: { $0.percentageText != nil }) else {
            return noReading
        }
        return windows
            .map { window in
                guard let text = window.percentageText else {
                    return "\(window.name), \(noReading)"
                }
                return "\(window.name), \(text) \(window.modeText)"
            }
            .joined(separator: ", ")
    }
}

/// Content of the popover shown when clicking the "+N" overflow status
/// item created once more than four profiles are selected for menu bar
/// display (see `StatusBarUIManager.splitForOverflow`). Lists every
/// profile that didn't get its own status item and lets the user click
/// through to it exactly like clicking that profile's own status item
/// would — same `onSelect` contract as `AccountChipView`'s tap handler.
///
/// Rows arrive already ordered freest-first by
/// `MenuBarManager.overflowProfileRows`; this view never reorders them, and
/// must not, because the ordering is keyed on raw used percentages the
/// rendered text no longer carries. The "More Profiles" header is what
/// names this as the set of accounts that did *not* fit, so a ranked
/// partial list does not read as an answer about every account.
struct OverflowProfileListView: View {
    let rows: [OverflowProfileRow]
    let onSelect: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PopoverDesign.sectionSpacing) {
            PopoverSectionHeader(
                title: ProviderUILocalization.text(
                    "menubar.overflow.header",
                    fallback: "More Profiles"
                )
            )
            VStack(spacing: 4) {
                ForEach(rows) { row in
                    OverflowProfileRowButton(row: row) {
                        onSelect(row.id)
                    }
                }
            }
        }
        .padding(PopoverDesign.outerInset)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: PopoverDesign.width)
    }
}

private struct OverflowProfileRowButton: View {
    let row: OverflowProfileRow
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            // Two lines, not one. Measured at the real fonts, the composed
            // windows text needs up to 207.8pt (Italian) and the row's whole
            // content width is 272pt, so sharing a line with an email-shaped
            // profile name clips in 8 of the 9 shipped locales. Pinned by
            // `PopoverHeaderLocalizationFitTests`.
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(PopoverDesign.rowTitleFont)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(row.valueText)
                    .font(PopoverDesign.valueFont)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        isHovering
                            ? PopoverDesign.hoverFill
                            : PopoverDesign.cardFill
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("\(row.name), \(row.accessibilityValueText)")
    }
}
