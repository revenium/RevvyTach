//
//  ClaudeSignInSummaryView.swift
//  Claude Usage
//

import SwiftUI

/// An optional action shown alongside one of the sign-in rows.
struct ClaudeSignInSummaryAction {
    enum Style {
        case standard
        case destructive
    }

    let title: String
    let style: Style
    let action: () -> Void

    init(
        _ title: String,
        style: Style = .standard,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.style = style
        self.action = action
    }
}

/// Whether the browser (claude.ai) sign-in is actually working, as opposed
/// to merely being stored.
///
/// `ClaudeSetupState` answers only "is a session key present". A key that
/// claude.ai has started rejecting is still present, so the row badged it
/// "Working" and the banner stayed green while the menu bar showed the red
/// disc for the same profile — the app contradicting itself on the one page
/// a person opens to fix it. The caller supplies this from the menu bar's own
/// verdict; see `ClaudeAccountView.browserSummaryHealth(attention:)`.
enum ClaudeBrowserSummaryHealth: Equatable {
    case working
    case needsAttention
}

enum ClaudeTerminalSummaryHealth: Equatable {
    case working
    case workingNotRenewable
    case needsAttention
}

/// A reusable summary of the browser and terminal sign-ins for a Claude profile.
///
/// The caller supplies live, context-specific detail text and optional actions;
/// this view owns the shared verdict, row labels, and status presentation.
struct ClaudeSignInSummaryView: View {
    let state: ClaudeSetupState
    let browserDetail: String
    let terminalDetail: String
    let browserAction: ClaudeSignInSummaryAction?
    let terminalAction: ClaudeSignInSummaryAction?
    let terminalHealth: ClaudeTerminalSummaryHealth
    let browserHealth: ClaudeBrowserSummaryHealth

    init(
        state: ClaudeSetupState,
        browserDetail: String,
        terminalDetail: String,
        browserAction: ClaudeSignInSummaryAction? = nil,
        terminalAction: ClaudeSignInSummaryAction? = nil,
        terminalHealth: ClaudeTerminalSummaryHealth = .working,
        browserHealth: ClaudeBrowserSummaryHealth = .working
    ) {
        self.state = state
        self.browserDetail = browserDetail
        self.terminalDetail = terminalDetail
        self.browserAction = browserAction
        self.terminalAction = terminalAction
        self.terminalHealth = terminalHealth
        self.browserHealth = browserHealth
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            verdictBanner

            VStack(spacing: 0) {
                signInRow(
                    title: localized("claude_account.summary.browser.title"),
                    detail: browserDetail,
                    status: browserStatus,
                    action: browserAction
                )

                Divider()
                    .padding(.leading, Spacing.lg)

                signInRow(
                    title: localized("claude_account.summary.terminal.title"),
                    detail: terminalDetail,
                    status: terminalStatus,
                    action: terminalAction
                )
            }
            .background(SettingsColors.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: Spacing.radiusLarge))
            .overlay {
                RoundedRectangle(cornerRadius: Spacing.radiusLarge)
                    .strokeBorder(SettingsColors.border, lineWidth: 0.5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var verdictBanner: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Image(systemName: verdict.icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(verdict.color)
                .accessibilityHidden(true)

            Text(localized(verdict.localizationKey))
                .font(Typography.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(verdict.color.opacity(verdict.backgroundOpacity))
        .clipShape(RoundedRectangle(cornerRadius: Spacing.radiusLarge))
        .overlay {
            RoundedRectangle(cornerRadius: Spacing.radiusLarge)
                .strokeBorder(verdict.color.opacity(0.24), lineWidth: 0.5)
        }
    }

    private func signInRow(
        title: String,
        detail: String,
        status: Status,
        action: ClaudeSignInSummaryAction?
    ) -> some View {
        HStack(alignment: .center, spacing: Spacing.lg) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.sm) {
                    Text(title)
                        .font(Typography.sectionHeader)
                        .foregroundStyle(.primary)

                    statusPill(status)
                }

                Text(detail)
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let action {
                actionButton(action)
            }
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusPill(_ status: Status) -> some View {
        Text(localized(status.localizationKey))
            .font(Typography.badge)
            .foregroundStyle(status.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(status.color.opacity(0.12), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(status.color.opacity(0.28), lineWidth: 0.5)
            }
            .accessibilityLabel(localized(status.localizationKey))
    }

    private func actionButton(_ summaryAction: ClaudeSignInSummaryAction) -> some View {
        Button(action: summaryAction.action) {
            Text(summaryAction.title)
                .font(Typography.label)
                .foregroundStyle(summaryAction.style.foregroundColor)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .background(summaryAction.style.backgroundColor)
                .clipShape(RoundedRectangle(cornerRadius: Spacing.radiusMedium))
                .overlay {
                    RoundedRectangle(cornerRadius: Spacing.radiusMedium)
                        .strokeBorder(summaryAction.style.borderColor, lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(summaryAction.title)
    }

    private var browserStatus: Status {
        Self.browserStatus(state: state, browserHealth: browserHealth)
    }

    /// A pure resolver so "which badge does the browser row get" is
    /// answerable in a unit test without driving SwiftUI, in the style of
    /// `NormalizedUsageView.accountHealthText`.
    static func browserStatus(
        state: ClaudeSetupState,
        browserHealth: ClaudeBrowserSummaryHealth
    ) -> Status {
        switch state {
        case .complete, .browserOnly:
            return browserHealth == .needsAttention
                ? .needsAttention
                : .working
        case .terminalOnly, .none:
            return .missing
        }
    }

    /// A stored-but-rejected browser sign-in, which only the health input can
    /// see. Checked before the setup-state verdicts because those describe
    /// which sign-ins exist, and this profile's problem is that one of them
    /// exists and no longer works — the state is `.complete` while every
    /// number on screen is frozen.
    private static func browserNeedsAttention(
        state: ClaudeSetupState,
        browserHealth: ClaudeBrowserSummaryHealth
    ) -> Bool {
        guard browserHealth == .needsAttention else { return false }
        switch state {
        case .complete, .browserOnly:
            return true
        case .terminalOnly, .none:
            // No browser sign-in to be broken; those verdicts already say to
            // add one, which is the same repair and the better wording.
            return false
        }
    }

    private var terminalStatus: Status {
        switch state {
        case .complete, .terminalOnly:
            switch terminalHealth {
            case .working:
                return .working
            case .workingNotRenewable:
                return .workingNotRenewable
            case .needsAttention:
                return .needsAttention
            }
        case .browserOnly, .none:
            return .notLinked
        }
    }

    private var verdict: Verdict {
        Self.verdict(state: state, browserHealth: browserHealth)
    }

    /// The banner's verdict, resolved without SwiftUI so the wording a
    /// broken browser sign-in gets can be asserted directly.
    static func verdict(
        state: ClaudeSetupState,
        browserHealth: ClaudeBrowserSummaryHealth
    ) -> Verdict {
        if browserNeedsAttention(state: state, browserHealth: browserHealth) {
            return Verdict(
                localizationKey:
                    "claude_account.summary.verdict.browser_needs_attention",
                icon: "exclamationmark.triangle.fill",
                color: SettingsColors.error,
                backgroundOpacity: 0.09
            )
        }
        switch state {
        case .complete:
            return Verdict(
                localizationKey: "claude_account.summary.verdict.complete",
                icon: "checkmark.circle.fill",
                color: SettingsColors.success,
                backgroundOpacity: 0.10
            )
        case .browserOnly:
            return Verdict(
                localizationKey: "claude_account.summary.verdict.browser_only",
                icon: "info.circle.fill",
                color: SettingsColors.secondary,
                backgroundOpacity: 0.07
            )
        case .terminalOnly:
            return Verdict(
                localizationKey: "claude_account.summary.verdict.terminal_only",
                icon: "exclamationmark.triangle.fill",
                color: SettingsColors.error,
                backgroundOpacity: 0.09
            )
        case .none:
            return Verdict(
                localizationKey: "claude_account.summary.verdict.none",
                icon: "exclamationmark.circle.fill",
                color: SettingsColors.error,
                backgroundOpacity: 0.09
            )
        }
    }

    private func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    struct Verdict {
        let localizationKey: String
        let icon: String
        let color: Color
        let backgroundOpacity: Double
    }

    enum Status: Equatable {
        case working
        case workingNotRenewable
        case needsAttention
        case notLinked
        case missing

        var localizationKey: String {
            switch self {
            case .working:
                return "claude_account.summary.status.working"
            case .workingNotRenewable:
                return "claude_account.summary.status.working_not_renewable"
            case .needsAttention:
                return "claude_account.summary.status.needs_attention"
            case .notLinked:
                return "claude_account.summary.status.not_linked"
            case .missing:
                return "claude_account.summary.status.missing"
            }
        }

        var color: Color {
            switch self {
            case .working:
                return SettingsColors.success
            case .workingNotRenewable, .needsAttention:
                return SettingsColors.error
            case .notLinked:
                return SettingsColors.secondary
            case .missing:
                return SettingsColors.error
            }
        }
    }
}

private extension ClaudeSignInSummaryAction.Style {
    var foregroundColor: Color {
        switch self {
        case .standard:
            return .primary
        case .destructive:
            return .white
        }
    }

    var backgroundColor: Color {
        switch self {
        case .standard:
            return SettingsColors.cardBackground
        case .destructive:
            return SettingsColors.error
        }
    }

    var borderColor: Color {
        switch self {
        case .standard:
            return SettingsColors.border
        case .destructive:
            return .clear
        }
    }
}
