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
    /// The account as it stood when the list was built. Carried on the row so
    /// an action fired after a credential rotation bumped the account's
    /// provider revision is rejected, rather than landing on the account that
    /// replaced it.
    let identity: ProviderStatusItemIdentity
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

    var id: UUID { identity.profileID }
}

/// One of the three things a row lets you do to an account.
///
/// A value, not three hand-written buttons, so the set the row renders and
/// the set a test can inspect are the same list. SwiftUI vends no
/// accessibility tree from a hosted view outside a real accessibility
/// session, so walking the rendered row is not available; this is.
struct HealthStripRowAction: Identifiable, Equatable {
    enum Kind: Hashable {
        case makeActive
        case refresh
        case open
    }

    let kind: Kind
    let systemName: String
    let label: String

    var id: Kind { kind }
}

extension HealthStripAccountRow {
    /// "Open <account>", the label shared by the name column and the last
    /// icon button, which do the same thing.
    var openLabel: String {
        String(
            format: ProviderUILocalization.text(
                "menu.provider.open_profile",
                fallback: "Open %@"
            ),
            name
        )
    }

    /// The row's action buttons, in the order they are drawn. Make Active is
    /// absent only for the account that is already active — the same terms
    /// the context menu offers it on.
    var actions: [HealthStripRowAction] {
        var actions: [HealthStripRowAction] = []
        if canActivate {
            actions.append(
                HealthStripRowAction(
                    kind: .makeActive,
                    systemName: "checkmark.circle",
                    label: ProviderUILocalization.text(
                        "menu.provider.make_active",
                        fallback: "Make Active"
                    )
                )
            )
        }
        actions.append(
            HealthStripRowAction(
                kind: .refresh,
                systemName: "arrow.clockwise",
                label: ProviderUILocalization.text(
                    "common.refresh",
                    fallback: "Refresh"
                )
            )
        )
        actions.append(
            HealthStripRowAction(
                kind: .open,
                systemName: "chevron.right",
                label: openLabel
            )
        )
        return actions
    }

    private var windowRow: OverflowProfileRow {
        OverflowProfileRow(id: id, name: name, windows: windows)
    }

    /// One visible line per usage window, including its reset when known, or
    /// a single dash when nothing was read.
    func valueLines(now: Date = Date()) -> [String] {
        guard windows.contains(where: { $0.percentageText != nil }) else {
            return [OverflowProfileRow.noReadingText]
        }
        return windows.map { window in
            let value = "\(window.name) "
                + "\(window.percentageText ?? OverflowProfileRow.noReadingText)"
            guard window.percentageText != nil,
                  let resetTime = window.resetTime else {
                return value
            }
            let reset = ProviderUILocalization.text(
                "menubar.resets_time",
                fallback: "Resets %@"
            )
            return value + " · " + String(
                format: reset,
                resetTime.resetTimeString(from: now)
            )
        }
    }

    var valueLines: [String] { valueLines() }

    /// Kept as a model-level summary for tests and non-view callers. The
    /// card renders `valueLines` separately rather than embedding newlines in
    /// one Text view.
    var valueText: String { valueLines.joined(separator: "\n") }

    /// The spoken form of the same thing, including each usable reset time.
    func accessibilityValueText(now: Date = Date()) -> String {
        guard windows.contains(where: { $0.percentageText != nil }) else {
            return windowRow.accessibilityValueText
        }
        let resetFormat = ProviderUILocalization.text(
            "menubar.resets_time",
            fallback: "Resets %@"
        )
        let noReading = ProviderUILocalization.text(
            "menubar.accessibility.state.no_data",
            fallback: "no usage data"
        )
        return windows.map { window in
            guard let percentage = window.percentageText else {
                return "\(window.name), \(noReading)"
            }
            var text = "\(window.name), \(percentage) \(window.modeText)"
            if let resetTime = window.resetTime {
                text += ", " + String(
                    format: resetFormat,
                    resetTime.resetTimeString(from: now)
                )
            }
            return text
        }.joined(separator: ", ")
    }

    var accessibilityValueText: String { accessibilityValueText() }

    /// Builds the list the strip's popover shows.
    ///
    /// The row set is the predicate the strip DRAWS — selected for display,
    /// not mid-deletion, and Claude — rather than the looser "selected for
    /// display" alone. The shared reset ordering puts the earliest known
    /// weekly reset first, exactly as the strip's bars and overflow list do.
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
        ProfileResetOrder.sorted(
            profiles
            .filter {
                $0.isSelectedForDisplay
                    && !$0.deletionInProgress
                    && $0.providerID == .claude
            },
            snapshots: snapshots
        )
            .map { profile in
                let snapshot = snapshots[profile.id]
                let usage = ProfileResetOrder.claudeUsage(
                    for: profile,
                    snapshot: snapshot
                )
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
                    identity: ProviderStatusItemIdentity(
                        profileID: profile.id,
                        providerID: profile.providerID,
                        providerRevision: profile.providerRevision,
                        metricID: nil
                    ),
                    name: profile.name,
                    windows: metrics.map { metric in
                        OverflowProfileRow.Window(
                            name: metric.descriptor.metricName,
                            percentageText: metric.displayedPercentage == nil
                                ? nil
                                : metric.percentageText,
                            modeText: metric.modeText,
                            resetTime: {
                                switch metric.descriptor.id {
                                case .claudeSession:
                                    return usage?.sessionPercentageAvailable
                                        == true
                                        ? usage?.sessionResetTime
                                        : nil
                                case .claudeWeek:
                                    return usage?.weeklyPercentageAvailable
                                        == true
                                        ? usage?.weeklyResetTime
                                        : nil
                                default:
                                    return nil
                                }
                            }()
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
/// VoiceOver behaviour, and unable to do the three-line name-over-windows
/// layout the reset text needs.
struct HealthStripAccountsView: View {
    let rows: [HealthStripAccountRow]
    let onOpen: (ProviderStatusItemIdentity) -> Void
    let onActivate: (ProviderStatusItemIdentity) -> Void
    let onRefresh: (ProviderStatusItemIdentity) -> Void
    let onRefreshAll: () -> Void
    let onManageProfiles: () -> Void
    let onQuit: () -> Void

    static let rowSpacing: CGFloat = 4

    /// The reset rows need more horizontal room than the standard detail
    /// popover: German's longest real line is just over 304pt before the
    /// action column and card/list insets are added.
    static let width: CGFloat = 420

    /// Name plus two usage-window lines, including the card's vertical
    /// padding. Kept explicit so the cap and rendering tests describe the
    /// three-line card rather than the former two-line one.
    static let rowHeight: CGFloat = 62

    /// The list scrolls past this height rather than growing the popover
    /// without limit. A cap in points, not in rows: row height is a text
    /// measurement that differs between locales, so counting rows would clip
    /// exactly where the rows are tallest.
    static let scrollMaxHeight: CGFloat = 420
    static let clockRefreshInterval: TimeInterval = 60

    /// Size of one action icon button, the space between them, and the
    /// width the whole cluster takes out of a row.
    ///
    /// Not private: the localization fit test subtracts this from the row's
    /// content budget, because the name and window columns get whatever is
    /// left after the three buttons, not the whole row.
    ///
    /// Sized by that measurement rather than by taste. German's longest
    /// reset line needs just over 304pt at the real font, out of the row's
    /// 372pt, so the cluster cannot exceed about 68pt without clipping the
    /// information the list exists to show. Three 18pt buttons
    /// with 1pt between them and a 4pt gap come to 60pt.
    static let actionButtonSize: CGFloat = 18
    static let actionSpacing: CGFloat = 1
    static let actionColumnWidth: CGFloat =
        actionButtonSize * 3 + actionSpacing * 2 + 4

    /// Width the name and window columns actually get: the popover width,
    /// less the outer inset on each side, less the row's own 8pt horizontal
    /// padding on each side, less the action cluster.
    static let rowTextWidth: CGFloat =
        width
            - 2 * PopoverDesign.outerInset
            - 2 * 8
            - actionColumnWidth

    var body: some View {
        TimelineView(
            .periodic(from: .now, by: Self.clockRefreshInterval)
        ) { context in
            content(now: context.date)
        }
    }

    private func content(now: Date) -> some View {
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
                            now: now,
                            onOpen: { onOpen(row.identity) },
                            onActivate: { onActivate(row.identity) },
                            onRefresh: { onRefresh(row.identity) }
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
        .frame(width: Self.width)
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
/// nested inside an outer button break hit testing, so the name and windows
/// column carries the "Open" affordance and the three icon buttons sit
/// beside it.
/// Internal rather than private so a test can host one row on its own and
/// walk its accessibility tree: the three action buttons being present, and
/// labelled, is a promise about this view that no localization lookup can
/// stand in for.
struct HealthStripAccountRowView: View {
    let row: HealthStripAccountRow
    var now: Date = Date()
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
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(
                            Array(row.valueLines(now: now).enumerated()),
                            id: \.offset
                        ) { _, line in
                            Text(line)
                                .font(PopoverDesign.valueFont)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(openLabel)
            .accessibilityValue(row.accessibilityValueText(now: now))

            HStack(spacing: HealthStripAccountsView.actionSpacing) {
                ForEach(row.actions) { action in
                    actionButton(action)
                }
            }
            .frame(
                width: HealthStripAccountsView.actionColumnWidth,
                alignment: .trailing
            )
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .frame(minHeight: HealthStripAccountsView.rowHeight)
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

    private var openLabel: String { row.openLabel }

    /// Always in the view and in the accessibility tree; hover changes only
    /// the opacity. A control that appears on hover is a control a keyboard
    /// or VoiceOver user does not have.
    private func actionButton(
        _ action: HealthStripRowAction
    ) -> some View {
        let handler: () -> Void = {
            switch action.kind {
            case .makeActive: return onActivate
            case .refresh: return onRefresh
            case .open: return onOpen
            }
        }()
        let label = action.label
        return Button(action: handler) {
            Image(systemName: action.systemName)
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
