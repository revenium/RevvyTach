//
//  HealthStripAccountsView.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-09-08.
//

import SwiftUI
import UsageCore

/// One account in the health strip's list: everything the strip draws about
/// it, said in words, plus the three things you can do to it.
///
/// The percentages come from the same
/// `ProviderMenuPresentationBuilder`/`ProviderMetricPresentation` text every
/// status item already renders, so this list never becomes a second source
/// of truth for "what is this account at".
struct HealthStripAccountRow: Identifiable, Equatable {
    let id: UUID
    let name: String
    /// The account's leading two usage windows, in the shape the overflow
    /// list already speaks.
    let windows: [OverflowProfileRow.Window]
    let isActive: Bool
    /// Which credential needs attention, or nil. Drawn with the same shapes
    /// the strip uses: a filled disc and a hollow ring.
    let attention: MenuBarAttentionSignal.Credential?
    let paceStatus: PaceStatus?
    /// False when this account cannot be made active right now — the same
    /// answer the context menu reaches through `presentation.actions`.
    let canActivate: Bool
}

extension HealthStripAccountRow {
    private var windowRow: OverflowProfileRow {
        OverflowProfileRow(id: id, name: name, windows: windows)
    }

    /// "Session 42% · Week 78%", or a single dash when nothing was read.
    var valueText: String { windowRow.valueText }

    /// The spoken form of the same thing, which collapses on exactly the
    /// condition `valueText` collapses on.
    var accessibilityValueText: String {
        windowRow.accessibilityValueText
    }

    /// Builds the list the strip's popover shows.
    ///
    /// The row set is the predicate the strip DRAWS — selected for display,
    /// not mid-deletion, and Claude — rather than the looser "selected for
    /// display" alone. Order is the profile list's own order, so the rows
    /// and the bars read left to right the same way.
    static func rows(
        profiles: [Profile],
        snapshots: [UUID: PresentationSnapshot],
        activeClaudeProfileID: UUID?,
        attention: [UUID: MenuBarAttentionSignal.Credential],
        showRemaining: Bool,
        showPaceMarker: Bool,
        isActive: (Profile) -> Bool,
        now: Date = Date()
    ) -> [HealthStripAccountRow] {
        profiles
            .filter {
                $0.isSelectedForDisplay
                    && !$0.deletionInProgress
                    && $0.providerID == .claude
            }
            .map { profile in
                let snapshot = snapshots[profile.id]
                let metrics = ProviderMenuPresentationBuilder
                    .leadingWindowPresentations(
                        profile: profile,
                        snapshot: snapshot,
                        showRemaining: showRemaining,
                        now: now
                    )
                let presentation = ProviderMenuPresentationBuilder
                    .presentation(
                        profile: profile,
                        snapshot: snapshot,
                        now: now,
                        isActive: isActive(profile)
                    )
                let leading = metrics.first
                let pace: PaceStatus? = {
                    guard showPaceMarker,
                          let used = leading?.usedPercentage,
                          let elapsed = leading?.elapsedFraction else {
                        return nil
                    }
                    return PaceStatus.calculate(
                        usedPercentage: used,
                        elapsedFraction: elapsed
                    )
                }()
                return HealthStripAccountRow(
                    id: profile.id,
                    name: profile.name,
                    windows: metrics.map {
                        OverflowProfileRow.Window(
                            name: $0.descriptor.metricName,
                            percentageText: $0.displayedPercentage == nil
                                ? nil
                                : $0.percentageText,
                            modeText: $0.modeText
                        )
                    },
                    isActive: profile.id == activeClaudeProfileID,
                    attention: attention[profile.id],
                    paceStatus: pace,
                    canActivate: presentation.actions.contains {
                        $0.kind == .activate
                    }
                )
            }
    }
}

/// The list behind a left click on the health strip.
///
/// A SwiftUI popover rather than an `NSMenu`: a row carries a name, two
/// windows, a pace dot, an attention flag, an active badge and three
/// actions, which in an `NSMenu` means custom views — losing keyboard and
/// VoiceOver behaviour, and unable to do the two-line name-over-numbers
/// layout that 8 of the 9 shipped locales need.
struct HealthStripAccountsView: View {
    let rows: [HealthStripAccountRow]
    let onOpen: (UUID) -> Void
    let onActivate: (UUID) -> Void
    let onRefresh: (UUID) -> Void
    let onRefreshAll: () -> Void
    let onManageProfiles: () -> Void
    let onQuit: () -> Void

    static let rowSpacing: CGFloat = 4

    /// The list scrolls past this height rather than growing the popover
    /// without limit. A cap in points, not in rows: row height is a text
    /// measurement that differs between locales, so counting rows would clip
    /// exactly where the rows are tallest.
    static let scrollMaxHeight: CGFloat = 360

    /// Size of one action icon button, the space between them, and the
    /// width the whole cluster takes out of a row.
    ///
    /// Not private: the localization fit test subtracts this from the row's
    /// content budget, because the name and numbers columns get whatever is
    /// left after the three buttons, not the whole row.
    ///
    /// Sized by that measurement rather than by taste. Italian's
    /// "Sessione 100% · Settimana 100%" needs 207.8pt at the real font, out
    /// of the row's 272pt, so the cluster cannot exceed about 64pt without
    /// clipping the very numbers the list exists to show. Three 18pt buttons
    /// with 1pt between them and a 4pt gap come to 60pt.
    static let actionButtonSize: CGFloat = 18
    static let actionSpacing: CGFloat = 1
    static let actionColumnWidth: CGFloat =
        actionButtonSize * 3 + actionSpacing * 2 + 4

    /// Width the name and numbers columns actually get: the popover width,
    /// less the outer inset on each side, less the row's own 8pt horizontal
    /// padding on each side, less the action cluster.
    static let rowTextWidth: CGFloat =
        PopoverDesign.width
            - 2 * PopoverDesign.outerInset
            - 2 * 8
            - actionColumnWidth

    var body: some View {
        VStack(alignment: .leading, spacing: PopoverDesign.sectionSpacing) {
            PopoverSectionHeader(
                title: ProviderUILocalization.text(
                    "menubar.healthstrip.header",
                    fallback: "Claude Accounts"
                )
            )
            // The rows scroll; the footer below does not. It carries the
            // only Quit and Manage Profiles the strip offers, so it must
            // never be the thing that goes below the fold.
            ScrollView(.vertical) {
                VStack(spacing: Self.rowSpacing) {
                    ForEach(rows) { row in
                        HealthStripAccountRowView(
                            row: row,
                            onOpen: { onOpen(row.id) },
                            onActivate: { onActivate(row.id) },
                            onRefresh: { onRefresh(row.id) }
                        )
                    }
                }
            }
            .frame(maxHeight: Self.scrollMaxHeight)
            Divider()
            HStack(spacing: 12) {
                footerButton(
                    ProviderUILocalization.text(
                        "menubar.healthstrip.footer.refresh_all",
                        fallback: "Refresh All"
                    ),
                    action: onRefreshAll
                )
                footerButton(
                    ProviderUILocalization.text(
                        "menu.provider.manage_profiles",
                        fallback: "Manage Profiles…"
                    ),
                    action: onManageProfiles
                )
                Spacer(minLength: 0)
                footerButton(
                    ProviderUILocalization.text(
                        "common.quit",
                        fallback: "Quit"
                    ),
                    action: onQuit
                )
            }
        }
        .padding(PopoverDesign.outerInset)
        // Self-sizing vertically, the shape the overflow list already uses
        // with `sizingOptions = .preferredContentSize`. A hand-computed
        // height would have to guess the tallest locale's row, and guessing
        // low clips the footer.
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: PopoverDesign.width)
    }

    private func footerButton(
        _ title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(PopoverDesign.chipFont)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .accessibilityLabel(title)
    }
}

/// One row. The container is deliberately not a `Button`: three buttons
/// nested inside an outer button break hit testing, so the name and numbers
/// column carries the "Open" affordance and the three icon buttons sit
/// beside it.
private struct HealthStripAccountRowView: View {
    let row: HealthStripAccountRow
    let onOpen: () -> Void
    let onActivate: () -> Void
    let onRefresh: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(row.name)
                            .font(PopoverDesign.rowTitleFont)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if let pace = row.paceStatus {
                            Circle()
                                .fill(Color(pace.color))
                                .frame(width: 6, height: 6)
                        }
                        if let attention = row.attention {
                            attentionGlyph(attention)
                        }
                        if row.isActive {
                            Text(
                                ProviderUILocalization.text(
                                    "menubar.healthstrip.row.active_badge",
                                    fallback: "Active"
                                )
                            )
                            .font(PopoverDesign.chipFont)
                            .foregroundColor(.secondary)
                        }
                    }
                    Text(row.valueText)
                        .font(PopoverDesign.valueFont)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(openLabel)

            HStack(spacing: HealthStripAccountsView.actionSpacing) {
                if row.canActivate {
                    actionButton(
                        systemName: "checkmark.circle",
                        label: ProviderUILocalization.text(
                            "menu.provider.make_active",
                            fallback: "Make Active"
                        ),
                        action: onActivate
                    )
                }
                actionButton(
                    systemName: "arrow.clockwise",
                    label: ProviderUILocalization.text(
                        "common.refresh",
                        fallback: "Refresh"
                    ),
                    action: onRefresh
                )
                actionButton(
                    systemName: "chevron.right",
                    label: openLabel,
                    action: onOpen
                )
            }
            .frame(
                width: HealthStripAccountsView.actionColumnWidth,
                alignment: .trailing
            )
        }
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
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
    }

    private var openLabel: String {
        String(
            format: ProviderUILocalization.text(
                "menu.provider.open_profile",
                fallback: "Open %@"
            ),
            row.name
        )
    }

    /// Always in the view and in the accessibility tree; hover changes only
    /// the opacity. A control that appears on hover is a control a keyboard
    /// or VoiceOver user does not have.
    private func actionButton(
        systemName: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .frame(
                    width: HealthStripAccountsView.actionButtonSize,
                    height: HealthStripAccountsView.actionButtonSize
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
        .opacity(isHovering ? 1.0 : 0.55)
        .help(label)
        .accessibilityLabel(label)
    }

    /// The list's echo of the strip's marker: a filled disc for the Claude
    /// Code sign-in, a hollow ring for the claude.ai one. Shape as well as
    /// colour, for the same reason the strip does it.
    @ViewBuilder
    private func attentionGlyph(
        _ credential: MenuBarAttentionSignal.Credential
    ) -> some View {
        switch credential {
        case .claudeCode, .setupIncomplete:
            Circle()
                .fill(Color(nsColor: .systemRed))
                .frame(width: 7, height: 7)
                .accessibilityLabel(
                    StatusBarUIManager.attentionStateText(credential)
                )
        case .claudeAI:
            Circle()
                .strokeBorder(Color(nsColor: .systemOrange), lineWidth: 1.5)
                .frame(width: 7, height: 7)
                .accessibilityLabel(
                    StatusBarUIManager.attentionStateText(credential)
                )
        }
    }
}
