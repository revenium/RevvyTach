//
//  ClaudeAccountView.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-01-07.
//

import SwiftUI
import AppKit
import UsageCore

/// Keychain-first verification for the link sheet. The injected operations
/// keep source ordering and token validation testable without touching the
/// developer's real Keychain or Claude account directories.
struct ClaudeTerminalLinkVerifier {
    enum Source: Equatable {
        case keychain
        case linkedAccountFile
    }

    let syncKeychainToProfile: (UUID) throws -> Void
    let readLinkedAccountCredential: (String) -> String?
    let persistLinkedAccountCredential: (UUID, String) throws -> Void

    func verify(
        profileID: UUID,
        accountName: String
    ) throws -> Source {
        do {
            try syncKeychainToProfile(profileID)
            return .keychain
        } catch let error as ClaudeCodeError {
            switch error {
            case .noCredentialsFound:
                break
            case .invalidJSON, .keychainReadFailed,
                 .keychainWriteFailed, .noProfileCredentials:
                throw error
            }
        }

        guard let json = readLinkedAccountCredential(accountName),
              ClaudeCodeSyncService.carriesLogin(json) else {
            throw ClaudeCodeError.noCredentialsFound
        }
        try persistLinkedAccountCredential(profileID, json)
        return .linkedAccountFile
    }
}

enum ClaudeTerminalLinkVerificationState: Equatable {
    case unverified
    case ready(ClaudeTerminalLinkVerifier.Source)
    case failed

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

struct ClaudeTerminalAccountActions: Equatable {
    enum Primary: Equatable {
        case link
        case resync
    }

    let primary: Primary
    let canUnlink: Bool

    static func forProfile(_ profile: Profile) -> Self {
        let hasLinkedDirectory = profile.cliAccountName != nil
        return Self(
            primary: hasLinkedDirectory ? .resync : .link,
            canUnlink: hasLinkedDirectory
        )
    }
}

struct ClaudeAccountSheetTarget: Identifiable, Equatable {
    let id: UUID

    func profile(in profiles: [Profile]) -> Profile? {
        profiles.first { $0.id == id && $0.providerID == .claude }
    }
}

struct ClaudeBrowserCredentialDetail: Equatable {
    let organization: String
    let savedAt: Date?

    init(profile: Profile) {
        organization =
            profile.organizationName ?? profile.organizationId ?? "—"
        savedAt = profile.claudeBrowserCredentialSavedAt
    }
}

struct ClaudeAccountView: View {
    @StateObject private var profileManager = ProfileManager.shared
    /// The menu bar's own attention verdict for each profile. Read rather
    /// than recomputed: the claude.ai failure streak and provider health it
    /// depends on are not reachable from Settings, and a second rule here is
    /// exactly how this page came to say "Working" about a sign-in the icon
    /// was already marking as broken.
    @ObservedObject private var attentionStore =
        ClaudeSignInAttentionStore.shared
    @State private var isSyncing = false
    @State private var syncError: String?
    @State private var cliAccountInfo: CLIAccountInfo?

    // Linking flow state
    @State private var showLinkConfirmation = false
    @State private var linkingInProgress = false
    @State private var terminalLinkVerification:
        ClaudeTerminalLinkVerificationState = .unverified
    @State private var showUnlinkConfirmation = false
    /// The unlink confirmation raised from inside the terminal sign-in sheet.
    /// It needs its own flag because it is presented on a different window
    /// from the page-level one; see `terminalLinkSheet(profile:)`.
    @State private var showUnlinkConfirmationInSheet = false
    @State private var showShellIntegration = false
    @State private var showSetupGuide = false
    @State private var copiedToClipboard = false
    @State private var copiedShellSnippet = false
    @State private var browserSheetTarget: ClaudeAccountSheetTarget?
    @State private var terminalSheetTarget: ClaudeAccountSheetTarget?
    @State private var linkConfirmationTargetID: UUID?
    @State private var unlinkConfirmationTargetID: UUID?
    @State private var showWhyBoth = false

    // MCP sync state
    @State private var mcpSyncResult: McpSyncResult?
    @State private var skillsSyncResult: SkillsSyncResult?
    @State private var mcpSyncInProgress = false

    // Skills source
    @State private var skillsSourcePath: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.section) {
                SettingsPageHeader(
                    title: "claude_account.title".localized,
                    subtitle: "claude_account.subtitle".localized
                )

                if let profile = profileManager.activeClaudeProfile {
                    let setupState = profileManager.claudeSetupState(
                        for: profile
                    ) ?? .none
                    let terminalActions =
                        ClaudeTerminalAccountActions.forProfile(profile)
                    ClaudeSignInSummaryView(
                        state: setupState,
                        browserDetail: Self.browserDetail(profile),
                        terminalDetail: Self.terminalDetail(
                            profile,
                            setupState: setupState
                        ),
                        browserAction: ClaudeSignInSummaryAction(
                            profile.hasClaudeAI
                                ? "claude_account.browser.sign_in_again".localized
                                : "claude_account.browser.sign_in".localized,
                            // Never destructive-styled. A terminal-only
                            // profile is complete; a red button on the
                            // browser row would be telling someone to fix
                            // something that works.
                            style: .standard,
                            action: {
                                browserSheetTarget = .init(id: profile.id)
                            }
                        ),
                        terminalAction: ClaudeSignInSummaryAction(
                            terminalActions.primary == .resync
                                ? "claude_account.terminal.resync".localized
                                : "claude_account.terminal.link".localized,
                            action: {
                                if terminalActions.primary == .resync {
                                    syncFromCLI(profileID: profile.id)
                                } else {
                                    terminalSheetTarget = .init(id: profile.id)
                                }
                            }
                        ),
                        terminalHealth: Self.terminalSummaryHealth(profile),
                        browserHealth: Self.browserSummaryHealth(
                            attention: attentionStore.credential(
                                for: profile.id
                            )
                        )
                    )

                    if Self.showsBrowserCredentialNotSavedWarning(
                        profileID: profile.id,
                        browserSessionOnlyProfileIDs: profileManager
                            .sessionOnlyClaudeAICredentialProfileIDs
                    ) {
                        browserCredentialNotSavedCard(profileID: profile.id)
                    }

                    HStack(spacing: DesignTokens.Spacing.small) {
                        if profile.hasClaudeAI {
                            Button("common.remove".localized) {
                                removeBrowserSignIn(profile.id)
                            }
                            .buttonStyle(.bordered)
                            .foregroundStyle(.red)
                        }
                        if terminalActions.canUnlink {
                            Button("cli.unlink".localized) {
                                unlinkConfirmationTargetID = profile.id
                                showUnlinkConfirmation = true
                            }
                            .buttonStyle(.bordered)
                            .foregroundStyle(.red)
                        }
                        Spacer()
                    }

                    // Keep every existing sync control and its multi-profile
                    // gate, but group them under the combined account page.
                    if profileManager.displayMode == .multi {
                        SettingsSectionCard(
                            title: "claude_account.sync.title".localized,
                            subtitle: "claude_account.sync.subtitle".localized
                        ) {
                            VStack(
                                alignment: .leading,
                                spacing: DesignTokens.Spacing.medium
                            ) {
                                mcpSyncSection
                                skillsSourceSection
                                if showShellIntegration {
                                    shellIntegrationCard
                                }
                            }
                        }
                    } else {
                        multiProfileRequiredCard
                    }

                    if profile.hasCliAccount {
                        accountDetailsCard(profile: profile)
                    }

                    // Error display
                    if let error = syncError {
                        errorCard(message: error)
                    }

                    // Info card
                    infoCard
                }
            }
            .padding()
        }
        .onAppear {
            loadCLIAccountInfo()
            skillsSourcePath = SharedDataStore.shared.loadSkillsSourceDirectory()
        }
        .onChange(of: profileManager.activeClaudeProfile?.id) { _, _ in
            if let terminalTarget = terminalSheetTarget {
                loadCLIAccountInfo(profileID: terminalTarget.id)
                return
            }
            loadCLIAccountInfo()
            syncError = nil
            terminalLinkVerification = .unverified
        }
        .sheet(item: $browserSheetTarget) { target in
            if target.profile(in: profileManager.profiles) != nil {
                ClaudeBrowserSignInSheet(
                    targetProfileID: target.id,
                    onCompletion: {
                        browserSheetTarget = nil
                        profileManager.loadProfiles()
                    }
                )
                .frame(width: 560, height: 650)
            }
        }
        .sheet(item: $terminalSheetTarget) { target in
            if let profile = target.profile(in: profileManager.profiles) {
                terminalLinkSheet(profile: profile)
            }
        }
        .sheet(isPresented: $showWhyBoth) {
            whyBothSheet
                .frame(width: 540, height: 360)
        }
        // Unlink confirmation alert for the button on the page itself. The
        // sheet carries its own copy — a confirmation can only appear on the
        // window whose button raised it.
        .alert("cli.unlink_title".localized, isPresented: $showUnlinkConfirmation) {
            unlinkConfirmationActions
        } message: {
            unlinkConfirmationMessage
        }
    }

    // MARK: - Terminal Sign-In Sheet

    /// The terminal sign-in sheet, with its confirmations attached to the
    /// sheet itself.
    ///
    /// AppKit allows a window one attached sheet at a time. A confirmation
    /// declared on the page behind this sheet is built but never attached, so
    /// the button that raised it appears to do nothing — and the request is
    /// not discarded either: it waits, and can surface as a confirmation out
    /// of nowhere once this sheet closes. That is what "Link CLI Account" did
    /// during onboarding. A confirmation has to belong to the window its
    /// button lives on.
    private func terminalLinkSheet(profile: Profile) -> some View {
        ScrollView {
            VStack(
                alignment: .leading,
                spacing: DesignTokens.Spacing.section
            ) {
                SettingsPageHeader(
                    title: "claude_account.terminal.link_sheet.title".localized,
                    subtitle: "claude_account.terminal.link_sheet.subtitle".localized
                )
                cliAccountLinkingSection(profile: profile)
            }
            .padding()
        }
        .frame(width: 560, height: 560)
        .alert(
            "cli.link_confirm_title".localized,
            isPresented: $showLinkConfirmation
        ) {
            Button("common.cancel".localized, role: .cancel) {}
            Button("cli.link_confirm_action".localized) {
                if let profileID = linkConfirmationTargetID {
                    performLinkAccount(profileID: profileID)
                }
            }
        } message: {
            Text(
                String(
                    format: "cli.link_confirm_message".localized,
                    sanitizedName(for: linkConfirmationTargetID)
                )
            )
        }
        .alert(
            "cli.unlink_title".localized,
            isPresented: $showUnlinkConfirmationInSheet
        ) {
            unlinkConfirmationActions
        } message: {
            unlinkConfirmationMessage
        }
    }

    @ViewBuilder
    private var unlinkConfirmationActions: some View {
        Button("common.cancel".localized, role: .cancel) {}
        Button("cli.unlink_action".localized, role: .destructive) {
            if let profileID = unlinkConfirmationTargetID {
                performUnlinkAccount(profileID: profileID)
            }
        }
    }

    @ViewBuilder
    private var unlinkConfirmationMessage: some View {
        if let profileID = unlinkConfirmationTargetID,
           let name = profileManager.profiles.first(where: {
               $0.id == profileID
           })?.cliAccountName {
            Text(String(format: "cli.unlink_confirm".localized, name))
        }
    }

    private var whyBothSheet: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.section) {
            SettingsPageHeader(
                title: "claude_account.why_both.title".localized,
                subtitle: "claude_account.why_both.subtitle".localized
            )
            HStack(alignment: .top, spacing: DesignTokens.Spacing.medium) {
                whyBothColumn(
                    title: "claude_account.summary.browser.title".localized,
                    text: "claude_account.why_both.browser".localized
                )
                whyBothColumn(
                    title: "claude_account.summary.terminal.title".localized,
                    text: "claude_account.why_both.terminal".localized
                )
            }
            Text("claude_account.why_both.renewal".localized)
                .font(DesignTokens.Typography.bodyMedium)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding()
    }

    private func whyBothColumn(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
            Text(title).font(DesignTokens.Typography.sectionTitle)
            Text(text)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.Colors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card))
    }

    static func browserDetail(
        _ profile: Profile,
        now: Date = Date()
    ) -> String {
        guard profile.hasClaudeAI else {
            return "claude_account.browser.missing_detail".localized
        }
        let detail = ClaudeBrowserCredentialDetail(profile: profile)
        guard let savedAt = detail.savedAt else {
            return String(
                format: "claude_account.browser.detail_without_saved_time"
                    .localized,
                detail.organization
            )
        }
        return String(
            format: "claude_account.browser.detail".localized,
            detail.organization,
            Self.relativeFormatter.localizedString(
                for: savedAt,
                relativeTo: now
            )
        )
    }

    static func terminalDetail(
        _ profile: Profile,
        setupState: ClaudeSetupState? = nil,
        now: Date = Date()
    ) -> String {
        guard profile.hasCliAccount || profile.cliCredentialsJSON != nil else {
            return "claude_account.terminal.not_linked_detail".localized
        }
        let name = profile.cliAccountName ?? profile.name
        if let problem = LegacyPopoverBanner.CLISignInProblem(
            profile.claudeUsage?.personalExtraUsageIssue
        ) {
            switch problem {
            case .expired:
                return "cli.login_expired_explain".localized
            case .signedOut:
                return "popover.banner.cli_signed_out".localized
            case .unusable:
                return "popover.banner.cli_sign_in_unusable".localized
            }
        }
        if terminalSignInIsExpired(profile) {
            return "cli.login_expired_explain".localized
        }
        // No terminal-only special case any more. That branch showed a
        // countdown to expiry because the app refused to renew a Claude Code
        // login without a browser sign-in — a restriction that never had a
        // technical basis; `ClaudeCLITokenRefresher` never needed one. A
        // terminal-only profile takes the ordinary "last renewed" path below.
        let renewed = profile.cliAccountSyncedAt.map {
            Self.relativeFormatter.localizedString(
                for: $0,
                relativeTo: now
            )
        } ?? "—"
        return String(
            format: "claude_account.terminal.detail".localized,
            name,
            renewed
        )
    }

    private static func terminalSignInIsExpired(_ profile: Profile) -> Bool {
        profile.cliCredentialsJSON.map {
            ClaudeCodeSyncService.shared.isTokenExpired($0)
        } ?? false
    }

    /// No longer takes the setup state. It used to return
    /// `.workingNotRenewable` for a terminal-only profile, a state that only
    /// existed because the app refused to renew a Claude Code login without a
    /// browser sign-in. It renews it, so the state is gone.
    static func terminalSummaryHealth(
        _ profile: Profile
    ) -> ClaudeTerminalSummaryHealth {
        if LegacyPopoverBanner.CLISignInProblem(
            profile.claudeUsage?.personalExtraUsageIssue
        ) != nil {
            return .needsAttention
        }
        guard let credentials = profile.cliCredentialsJSON,
              ClaudeCodeSyncService.carriesLogin(credentials),
              !ClaudeCodeSyncService.shared.isTokenExpired(credentials)
        else {
            return .needsAttention
        }
        return .working
    }

    /// Whether the browser (claude.ai) sign-in row should say it needs
    /// attention, decided by the menu bar's verdict rather than by a second
    /// rule of this page's own.
    ///
    /// Only `.claudeAI` counts. `.claudeCode` is the terminal sign-in, which
    /// has its own row and its own health, and `.setupIncomplete` is already
    /// carried by the setup-state verdict. Marking the browser row for either
    /// of those would send the reader to the wrong repair.
    static func browserSummaryHealth(
        attention: MenuBarAttentionSignal.Credential?
    ) -> ClaudeBrowserSummaryHealth {
        attention == .claudeAI ? .needsAttention : .working
    }

    private func browserCredentialNotSavedCard(
        profileID: UUID
    ) -> some View {
        SettingsContentCard {
            HStack(spacing: DesignTokens.Spacing.medium) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(
                    alignment: .leading,
                    spacing: DesignTokens.Spacing.extraSmall
                ) {
                    Text("personal.connected_not_saved".localized)
                        .font(DesignTokens.Typography.bodyMedium)
                    Text("popover.banner.credentials_not_saved.detail".localized)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("personal.retry_save".localized) {
                    _ = profileManager.retrySessionOnlyCredentialSave(
                        profileID: profileID
                    )
                    profileManager.loadProfiles()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    static func showsBrowserCredentialNotSavedWarning(
        profileID: UUID,
        browserSessionOnlyProfileIDs: Set<UUID>
    ) -> Bool {
        browserSessionOnlyProfileIDs.contains(profileID)
    }

    private func removeBrowserSignIn(_ profileID: UUID) {
        do {
            try profileManager.removeClaudeAICredentials(for: profileID)
            profileManager.loadProfiles()
        } catch {
            let appError = AppError.wrap(error)
            ErrorLogger.shared.log(appError, severity: .error)
            ErrorPresenter.shared.showAlert(for: appError)
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    // MARK: - Multi-Profile Required Card

    private var multiProfileRequiredCard: some View {
        SettingsContentCard {
            HStack(spacing: DesignTokens.Spacing.small) {
                Image(systemName: "info.circle.fill")
                    .foregroundColor(.blue)
                    .font(.system(size: DesignTokens.Icons.standard))
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.extraSmall) {
                    Text("cli.multi_profile_required_title".localized)
                        .font(DesignTokens.Typography.sectionTitle)
                    Text("cli.multi_profile_required".localized)
                        .font(DesignTokens.Typography.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - CLI Account Linking Section

    @ViewBuilder
    private func cliAccountLinkingSection(profile: Profile) -> some View {
        if let accountName = profile.cliAccountName {
            // Linked state
            linkedStatusCard(
                accountName: accountName,
                profileID: profile.id,
                hasCredentials: profile.hasCliAccount
            )

            if !profile.hasCliAccount || !terminalLinkVerification.isReady {
                // Linked but no credentials yet — show setup instructions
                postSetupCard(
                    accountName: accountName,
                    profileID: profile.id
                )
            }

            // Shell integration card (shown once after first successful credential detection)
            if showShellIntegration {
                shellIntegrationCard
            }

            // Action buttons for linked state
            linkedActionsCard(profile: profile)
        } else {
            // Not linked — show link button
            notLinkedStatusCard
            linkButtonCard(profileID: profile.id)
        }
    }

    // MARK: - Status Cards

    private var notLinkedStatusCard: some View {
        HStack(spacing: DesignTokens.Spacing.medium) {
            Circle()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: DesignTokens.StatusDot.standard, height: DesignTokens.StatusDot.standard)

            Text("cli.status_not_linked".localized)
                .font(DesignTokens.Typography.bodyMedium)

            Spacer()
        }
        .padding(DesignTokens.Spacing.medium)
        .background(DesignTokens.Colors.cardBackground)
        .cornerRadius(DesignTokens.Radius.card)
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.card)
                .strokeBorder(DesignTokens.Colors.cardBorder, lineWidth: 1)
        )
    }

    private func linkedStatusCard(
        accountName: String,
        profileID: UUID,
        hasCredentials: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
            HStack(spacing: DesignTokens.Spacing.medium) {
                Circle()
                    .fill(hasCredentials ? Color.green : Color.orange)
                    .frame(width: DesignTokens.StatusDot.standard, height: DesignTokens.StatusDot.standard)

                VStack(alignment: .leading, spacing: DesignTokens.Spacing.extraSmall) {
                    Text(hasCredentials ? "cli.status_linked".localized : "cli.status_linked_pending".localized)
                        .font(DesignTokens.Typography.bodyMedium)

                    Text("~/.claude-accounts/\(accountName)")
                        .font(DesignTokens.Typography.monospaced)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }

            if hasCredentials, isStoredLoginExpired(profileID: profileID) {
                Divider()
                expiredLoginNotice(accountName: accountName)
            } else if hasCredentials {
                Divider()

                HStack(spacing: DesignTokens.Spacing.small) {
                    Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                        .foregroundColor(.green)
                        .font(.system(size: DesignTokens.Icons.standard))
                    Text("cli.switching_enabled".localized)
                        .font(DesignTokens.Typography.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(DesignTokens.Spacing.medium)
        .background(DesignTokens.Colors.cardBackground)
        .cornerRadius(DesignTokens.Radius.card)
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.card)
                .strokeBorder(DesignTokens.Colors.cardBorder, lineWidth: 1)
        )
    }

    /// Whether the copy of the login this profile holds is past its expiry.
    ///
    /// Re-syncing cannot fix this and the button appears to work anyway, so
    /// the screen has to say what actually does: sign in to that account
    /// again. Re-sync is only the remedy when this copy is stale but the
    /// account's own login is current.
    private func isStoredLoginExpired(profileID: UUID) -> Bool {
        guard let credentials = profileManager.profiles.first(where: {
            $0.id == profileID
        })?.cliCredentialsJSON
        else { return false }
        return ClaudeCodeSyncService.shared.isTokenExpired(credentials)
    }

    /// The sign-in step, offered rather than described: the command is right
    /// here with a copy button, because the alternative is a sentence telling
    /// someone to go and construct it themselves.
    private func expiredLoginNotice(accountName: String) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
            HStack(spacing: DesignTokens.Spacing.small) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: DesignTokens.Icons.standard))
                Text("cli.login_expired_title".localized)
                    .font(DesignTokens.Typography.bodyMedium)
            }

            Text("cli.login_expired_explain".localized)
                .font(DesignTokens.Typography.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: DesignTokens.Spacing.small) {
                Text("CLAUDE_CONFIG_DIR=~/.claude-accounts/\(accountName) claude")
                    .font(DesignTokens.Typography.monospaced)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                Button(action: {
                    let command = "CLAUDE_CONFIG_DIR="
                        + "~/.claude-accounts/\(accountName) claude"
                    copyToClipboard(command)
                }) {
                    Text(
                        copiedToClipboard
                            ? "cli.copied".localized
                            : "cli.copy_command".localized
                    )
                    .font(DesignTokens.Typography.caption)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("cli.login_expired_copy")
            }

            Text("cli.login_expired_then_resync".localized)
                .font(DesignTokens.Typography.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("cli.login_expired")
    }

    // MARK: - Link Button Card

    private func linkButtonCard(profileID: UUID) -> some View {
        SettingsSectionCard(
            title: "cli.link_title".localized,
            subtitle: "cli.link_subtitle".localized
        ) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.cardPadding) {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.extraSmall) {
                    BulletPoint("cli.link_benefit_1".localized)
                    BulletPoint("cli.link_benefit_2".localized)
                    BulletPoint("cli.link_benefit_3".localized)
                }
                .font(DesignTokens.Typography.caption)
                .foregroundColor(.secondary)

                Button(action: {
                    linkConfirmationTargetID = profileID
                    showLinkConfirmation = true
                }) {
                    HStack(spacing: DesignTokens.Spacing.extraSmall) {
                        if linkingInProgress {
                            ProgressView()
                                .scaleEffect(0.8)
                                .frame(width: DesignTokens.Icons.small, height: DesignTokens.Icons.small)
                        } else {
                            Image(systemName: "link.badge.plus")
                                .font(.system(size: DesignTokens.Icons.small))
                        }
                        Text("cli.link_button".localized)
                            .font(DesignTokens.Typography.body)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(linkingInProgress)
            }
        }
    }

    // MARK: - Post-Setup Card (login instructions)

    private func postSetupCard(
        accountName: String,
        profileID: UUID
    ) -> some View {
        SettingsSectionCard(
            title: "cli.setup_complete_title".localized,
            subtitle: "cli.setup_complete_subtitle".localized
        ) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.cardPadding) {
                // Step 1
                HStack(alignment: .top, spacing: DesignTokens.Spacing.small) {
                    Text("1.")
                        .font(DesignTokens.Typography.bodyMedium)
                        .foregroundColor(.accentColor)
                        .frame(width: 20, alignment: .trailing)
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.extraSmall) {
                        Text("cli.setup_step1".localized)
                            .font(DesignTokens.Typography.body)
                            .foregroundColor(.secondary)

                        // Command display
                        HStack {
                            Text("CLAUDE_CONFIG_DIR=~/.claude-accounts/\(accountName) claude")
                                .font(DesignTokens.Typography.monospaced)
                                .foregroundColor(.primary)
                                .padding(DesignTokens.Spacing.small)

                            Spacer()

                            Button(action: {
                                copyToClipboard("CLAUDE_CONFIG_DIR=~/.claude-accounts/\(accountName) claude")
                            }) {
                                HStack(spacing: DesignTokens.Spacing.extraSmall) {
                                    Image(systemName: copiedToClipboard ? "checkmark" : "doc.on.doc")
                                        .font(.system(size: DesignTokens.Icons.small))
                                    Text(copiedToClipboard ? "cli.copied".localized : "cli.copy_command".localized)
                                        .font(DesignTokens.Typography.caption)
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .padding(.trailing, DesignTokens.Spacing.small)
                        }
                        .background(Color.primary.opacity(0.06))
                        .cornerRadius(DesignTokens.Radius.small)
                    }
                }

                // Step 2
                HStack(alignment: .top, spacing: DesignTokens.Spacing.small) {
                    Text("2.")
                        .font(DesignTokens.Typography.bodyMedium)
                        .foregroundColor(.accentColor)
                        .frame(width: 20, alignment: .trailing)
                    Text("cli.setup_step2".localized)
                        .font(DesignTokens.Typography.body)
                        .foregroundColor(.secondary)
                }

                // Step 3
                HStack(alignment: .top, spacing: DesignTokens.Spacing.small) {
                    Text("3.")
                        .font(DesignTokens.Typography.bodyMedium)
                        .foregroundColor(.accentColor)
                        .frame(width: 20, alignment: .trailing)
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                        Text("cli.setup_step3".localized)
                            .font(DesignTokens.Typography.body)
                            .foregroundColor(.secondary)

                        HStack(spacing: DesignTokens.Spacing.iconText) {
                            Button(action: {
                                checkCredentials(profileID: profileID)
                            }) {
                                HStack(spacing: DesignTokens.Spacing.extraSmall) {
                                    Image(systemName: "magnifyingglass")
                                        .font(.system(size: DesignTokens.Icons.small))
                                    Text("cli.check_credentials".localized)
                                        .font(DesignTokens.Typography.body)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)

                            if terminalLinkVerification.isReady {
                                HStack(spacing: DesignTokens.Spacing.extraSmall) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                        .font(.system(size: DesignTokens.Icons.small))
                                    Text("cli.credentials_found".localized)
                                        .font(DesignTokens.Typography.caption)
                                        .foregroundColor(.green)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Linked Actions Card

    private func linkedActionsCard(profile: Profile) -> some View {
        HStack(spacing: DesignTokens.Spacing.iconText) {
            Button(action: { syncFromCLI(profileID: profile.id) }) {
                HStack(spacing: DesignTokens.Spacing.extraSmall) {
                    if isSyncing {
                        ProgressView()
                            .scaleEffect(0.8)
                            .frame(width: DesignTokens.Icons.small, height: DesignTokens.Icons.small)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: DesignTokens.Icons.small))
                    }
                    Text(profile.hasCliAccount ? "cli.resync".localized : "cli.sync_from_code".localized)
                        .font(DesignTokens.Typography.body)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(isSyncing)

            Button(action: {
                unlinkConfirmationTargetID = profile.id
                // This card only ever renders inside the terminal sign-in
                // sheet, so the confirmation has to be the sheet's own.
                showUnlinkConfirmationInSheet = true
            }) {
                HStack(spacing: DesignTokens.Spacing.extraSmall) {
                    Image(systemName: "link.badge.minus")
                        .font(.system(size: DesignTokens.Icons.small))
                    Text("cli.unlink".localized)
                        .font(DesignTokens.Typography.body)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .foregroundColor(.red)

            Spacer()
        }
        .padding(.horizontal, DesignTokens.Spacing.small)
    }

    // MARK: - Shell Integration Card

    private var shellIntegrationCard: some View {
        SettingsContentCard {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
                HStack(spacing: DesignTokens.Spacing.small) {
                    Image(systemName: "lightbulb.fill")
                        .foregroundColor(.yellow)
                        .font(.system(size: DesignTokens.Icons.standard))
                    Text("cli.shell_integration_title".localized)
                        .font(DesignTokens.Typography.sectionTitle)
                }

                Text(String(format: "cli.shell_integration_explain".localized, shellConfigFile))
                    .font(DesignTokens.Typography.caption)
                    .foregroundColor(.secondary)

                // Shell snippet
                Text(shellSnippet)
                    .font(DesignTokens.Typography.monospaced)
                    .foregroundColor(.primary)
                    .padding(DesignTokens.Spacing.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.06))
                    .cornerRadius(DesignTokens.Radius.small)

                HStack(spacing: DesignTokens.Spacing.iconText) {
                    Button(action: {
                        copyShellSnippet()
                    }) {
                        HStack(spacing: DesignTokens.Spacing.extraSmall) {
                            Image(systemName: copiedShellSnippet ? "checkmark" : "doc.on.doc")
                                .font(.system(size: DesignTokens.Icons.small))
                            Text(copiedShellSnippet ? "cli.copied".localized : "cli.shell_integration_copy".localized)
                                .font(DesignTokens.Typography.body)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)

                    Button(action: {
                        SharedDataStore.shared.markCLIShellIntegrationShown()
                        showShellIntegration = false
                    }) {
                        HStack(spacing: DesignTokens.Spacing.extraSmall) {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: DesignTokens.Icons.small))
                            Text("cli.shell_integration_dismiss".localized)
                                .font(DesignTokens.Typography.body)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
            }
        }
    }

    // MARK: - Account Details Card

    private func accountDetailsCard(profile: Profile) -> some View {
        SettingsSectionCard(
            title: "cli.account_details".localized,
            subtitle: "cli.credentials_synced".localized
        ) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
                if let json = profile.cliCredentialsJSON {
                    if let sessionKey = extractSessionKey(from: json) {
                        HStack(spacing: DesignTokens.Spacing.iconText) {
                            Image(systemName: "key")
                                .font(.system(size: DesignTokens.Icons.standard))
                                .foregroundColor(.accentColor)
                                .frame(width: DesignTokens.Spacing.iconFrame)

                            VStack(alignment: .leading, spacing: DesignTokens.Spacing.extraSmall) {
                                Text("cli.access_token".localized)
                                    .font(DesignTokens.Typography.caption)
                                    .fontWeight(.medium)
                                    .foregroundColor(.secondary)
                                Text(maskCredential(sessionKey))
                                    .font(DesignTokens.Typography.monospaced)
                                    .foregroundColor(.primary)
                            }
                        }
                    }

                    if let info = cliAccountInfo {
                        Divider()

                        HStack(spacing: DesignTokens.Spacing.iconText) {
                            Image(systemName: "person.badge.key")
                                .font(.system(size: DesignTokens.Icons.standard))
                                .foregroundColor(.accentColor)
                                .frame(width: DesignTokens.Spacing.iconFrame)

                            VStack(alignment: .leading, spacing: DesignTokens.Spacing.extraSmall) {
                                Text("cli.subscription".localized)
                                    .font(DesignTokens.Typography.caption)
                                    .fontWeight(.medium)
                                    .foregroundColor(.secondary)
                                Text(info.subscriptionType)
                                    .font(DesignTokens.Typography.body)
                                    .foregroundColor(.primary)
                            }
                        }

                        if !info.scopes.isEmpty {
                            HStack(spacing: DesignTokens.Spacing.iconText) {
                                Image(systemName: "checkmark.shield")
                                    .font(.system(size: DesignTokens.Icons.standard))
                                    .foregroundColor(.accentColor)
                                    .frame(width: DesignTokens.Spacing.iconFrame)

                                VStack(alignment: .leading, spacing: DesignTokens.Spacing.extraSmall) {
                                    Text("cli.scopes".localized)
                                        .font(DesignTokens.Typography.caption)
                                        .fontWeight(.medium)
                                        .foregroundColor(.secondary)
                                    Text(info.scopes.joined(separator: ", "))
                                        .font(DesignTokens.Typography.body)
                                        .foregroundColor(.primary)
                                }
                            }
                        }
                    }

                    if let syncedAt = profile.cliAccountSyncedAt {
                        Divider()
                        HStack(spacing: DesignTokens.Spacing.extraSmall) {
                            Text("cli.last_synced".localized)
                                .font(DesignTokens.Typography.caption)
                                .foregroundColor(.secondary)
                            Text(syncedAt, style: .relative)
                                .font(DesignTokens.Typography.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Error Card

    private func errorCard(message: String) -> some View {
        HStack(spacing: DesignTokens.Spacing.small) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
                .font(.system(size: DesignTokens.Icons.standard))
            Text(message)
                .font(DesignTokens.Typography.body)
                .foregroundColor(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DesignTokens.Spacing.iconText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08))
        .cornerRadius(DesignTokens.Radius.small)
    }

    // MARK: - MCP Server Sync

    private var mcpSyncSection: some View {
        SettingsSectionCard(
            title: "cli.mcp_sync_title".localized,
            subtitle: "cli.mcp_sync_subtitle".localized
        ) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
                SettingToggle(
                    title: "cli.mcp_auto_sync_title".localized,
                    description: "cli.mcp_auto_sync_description".localized,
                    badge: .new,
                    isOn: Binding(
                        get: { SharedDataStore.shared.loadAutoSyncMCPEnabled() },
                        set: { enabled in
                            SharedDataStore.shared.saveAutoSyncMCPEnabled(enabled)
                        }
                    )
                )

                Divider()

                HStack {
                    Button(action: {
                        mcpSyncInProgress = true
                        mcpSyncResult = nil
                        skillsSyncResult = nil
                        // Run sync off the main thread to keep UI responsive
                        DispatchQueue.global(qos: .userInitiated).async {
                            let mcpResult = ClaudeSwitchService.shared.bidirectionalMcpSync()
                            let skillsResult = ClaudeSwitchService.shared.syncSkills()
                            DispatchQueue.main.async {
                                mcpSyncResult = mcpResult
                                skillsSyncResult = skillsResult
                                mcpSyncInProgress = false
                            }
                        }
                    }) {
                        HStack(spacing: DesignTokens.Spacing.small) {
                            if mcpSyncInProgress {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .frame(width: 14, height: 14)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                            Text("cli.mcp_sync_button".localized)
                        }
                    }
                    .disabled(mcpSyncInProgress)

                    Spacer()
                }

                // Results display (shown after manual sync)
                if let mcpResult = mcpSyncResult {
                    if mcpResult.hasChanges {
                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.extraSmall) {
                            ForEach(mcpResult.changes) { change in
                                HStack(spacing: DesignTokens.Spacing.small) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                        .font(.system(size: DesignTokens.Icons.small))
                                    Text("\(change.addedServers.joined(separator: ", ")) \u{2192} \(change.accountName)")
                                    .font(DesignTokens.Typography.caption)
                                    .foregroundColor(.secondary)
                                }
                            }
                        }
                    } else if skillsSyncResult?.hasChanges != true {
                        HStack(spacing: DesignTokens.Spacing.small) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.system(size: DesignTokens.Icons.small))
                            Text("cli.mcp_sync_no_changes".localized)
                                .font(DesignTokens.Typography.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                if let skillsResult = skillsSyncResult, skillsResult.hasChanges {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.extraSmall) {
                        ForEach(skillsResult.changes) { change in
                            HStack(spacing: DesignTokens.Spacing.small) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.system(size: DesignTokens.Icons.small))
                                Text("\(change.addedSkills.joined(separator: ", ")) \u{2192} \(change.accountName)")
                                    .font(DesignTokens.Typography.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Skills Source Section

    private var skillsSourceSection: some View {
        SettingsSectionCard(
            title: "cli.skills_source_title".localized,
            subtitle: "cli.skills_source_subtitle".localized
        ) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
                HStack(spacing: DesignTokens.Spacing.small) {
                    Image(systemName: "folder")
                        .font(.system(size: DesignTokens.Icons.standard))
                        .foregroundColor(.accentColor)
                        .frame(width: DesignTokens.Spacing.iconFrame)

                    if let path = skillsSourcePath {
                        Text(path)
                            .font(DesignTokens.Typography.monospaced)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    } else {
                        Text("cli.skills_source_not_configured".localized)
                            .font(DesignTokens.Typography.body)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if skillsSourcePath != nil {
                        Button("cli.skills_source_clear".localized) {
                            skillsSourcePath = nil
                            SharedDataStore.shared.saveSkillsSourceDirectory(nil)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .foregroundColor(.secondary)
                    }

                    Button("cli.skills_source_choose".localized) {
                        chooseSkillsSourceDirectory()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Text("cli.skills_source_description".localized)
                    .font(DesignTokens.Typography.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func chooseSkillsSourceDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            skillsSourcePath = url.path
            SharedDataStore.shared.saveSkillsSourceDirectory(url.path)
        }
    }

    // MARK: - Setup Guide Button & Sheet

    private var infoCard: some View {
        Button(action: { showSetupGuide = true }) {
            HStack(spacing: DesignTokens.Spacing.small) {
                Image(systemName: "book.pages")
                    .font(.system(size: DesignTokens.Icons.standard))
                    .foregroundColor(.accentColor)
                Text("cli.guide_button".localized)
                    .font(DesignTokens.Typography.body)
                    .foregroundColor(.accentColor)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: DesignTokens.Icons.small))
                    .foregroundColor(.secondary)
            }
            .padding(DesignTokens.Spacing.medium)
            .background(DesignTokens.Colors.cardBackground)
            .cornerRadius(DesignTokens.Radius.card)
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.card)
                    .strokeBorder(DesignTokens.Colors.cardBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showSetupGuide) {
            setupGuideSheet
        }
    }

    private var setupGuideSheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.section) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.extraSmall) {
                        Text("cli.guide_title".localized)
                            .font(DesignTokens.Typography.pageTitle)
                        Text("cli.guide_subtitle".localized)
                            .font(DesignTokens.Typography.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: { showSetupGuide = false }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                // How it works
                SettingsSectionCard(
                    title: "cli.guide_how_title".localized,
                    subtitle: "cli.guide_how_subtitle".localized
                ) {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
                        guideStep(number: "1", text: "cli.guide_step1".localized)
                        guideStep(number: "2", text: "cli.guide_step2".localized)
                        guideStep(number: "3", text: "cli.guide_step3".localized)
                        guideStep(number: "4", text: "cli.guide_step4".localized)
                    }
                }

                // Shell integration
                SettingsSectionCard(
                    title: "cli.shell_integration_title".localized,
                    subtitle: String(format: "cli.shell_integration_explain".localized, shellConfigFile)
                ) {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
                        Text(shellSnippet)
                            .font(DesignTokens.Typography.monospaced)
                            .foregroundColor(.primary)
                            .padding(DesignTokens.Spacing.small)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.06))
                            .cornerRadius(DesignTokens.Radius.small)

                        Button(action: { copyShellSnippet() }) {
                            HStack(spacing: DesignTokens.Spacing.extraSmall) {
                                Image(systemName: copiedShellSnippet ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: DesignTokens.Icons.small))
                                Text(copiedShellSnippet ? "cli.copied".localized : "cli.shell_integration_copy".localized)
                                    .font(DesignTokens.Typography.body)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)

                        Text("cli.guide_shell_note".localized)
                            .font(DesignTokens.Typography.caption)
                            .foregroundColor(.orange)
                            .padding(DesignTokens.Spacing.small)
                            .background(Color.orange.opacity(0.08))
                            .cornerRadius(DesignTokens.Radius.tiny)
                    }
                }

                // Important notes
                SettingsContentCard {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
                        HStack(spacing: DesignTokens.Spacing.small) {
                            Image(systemName: "lightbulb.fill")
                                .foregroundColor(.yellow)
                                .font(.system(size: DesignTokens.Icons.standard))
                            Text("cli.guide_notes_title".localized)
                                .font(DesignTokens.Typography.sectionTitle)
                        }

                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.extraSmall) {
                            BulletPoint("cli.guide_note1".localized)
                            BulletPoint("cli.guide_note2".localized)
                            BulletPoint("cli.guide_note3".localized)
                            BulletPoint("cli.guide_note4".localized)
                        }
                        .font(DesignTokens.Typography.caption)
                        .foregroundColor(.secondary)
                    }
                }
            }
            .padding()
        }
        .frame(minWidth: 500, minHeight: 500)
    }

    private func guideStep(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.small) {
            Text(number)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
                .background(Color.accentColor)
                .clipShape(Circle())
            Text(text)
                .font(DesignTokens.Typography.body)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Computed Properties

    private func sanitizedName(for profileID: UUID?) -> String {
        guard let profileID,
              let name = profileManager.profiles.first(where: {
                  $0.id == profileID
              })?.name else { return "" }
        return ClaudeSwitchService.shared.previewDirectoryName(for: name)
    }

    /// Detects the user's shell and returns the appropriate config file name
    private var shellConfigFile: String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        if shell.contains("zsh") {
            return "~/.zshrc"
        } else if shell.contains("bash") {
            // macOS uses .bash_profile for login shells, .bashrc for non-login
            return "~/.bashrc or ~/.bash_profile"
        } else if shell.contains("fish") {
            return "~/.config/fish/config.fish"
        }
        return "your shell configuration file"
    }

    private var shellSnippet: String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        if shell.contains("fish") {
            return """
            # Claude CLI account auto-switch (one-time setup, applies to all accounts)
            if test -f ~/.claude-tokens/.last-account
                set -gx CLAUDE_CONFIG_DIR "$HOME/.claude-accounts/"(cat ~/.claude-tokens/.last-account)
            end
            """
        }
        return """
        # Claude CLI account auto-switch (one-time setup, applies to all accounts)
        if [ -f ~/.claude-tokens/.last-account ]; then
          export CLAUDE_CONFIG_DIR="$HOME/.claude-accounts/$(cat ~/.claude-tokens/.last-account)"
        fi
        """
    }

    // MARK: - Actions

    private func performLinkAccount(profileID: UUID) {
        guard let profile = profileManager.profiles.first(where: {
            $0.id == profileID && $0.providerID == .claude
        }) else { return }
        linkingInProgress = true
        syncError = nil
        var plannedLinkWasPersisted = false
        var completedLink: LinkAccountResult?

        do {
            let plannedDirectoryName = ClaudeSwitchService.shared.previewDirectoryName(
                for: profile.name
            )
            var updated = profile
            updated.cliAccountName = plannedDirectoryName
            try profileManager.updateProfileThrowing(updated)
            plannedLinkWasPersisted = true

            let result = try ClaudeSwitchService.shared.linkAccount(profileName: profile.name)
            completedLink = result

            if result.directoryName != plannedDirectoryName {
                updated.cliAccountName = result.directoryName
                try profileManager.updateProfileThrowing(updated)
            }

            LoggingService.shared.log("ClaudeAccountView: Linked account '\(result.directoryName)' (\(result.symlinkCount) symlinks)")
        } catch {
            var recoveryFailures: [String] = []
            if let completedLink, completedLink.createdNewDirectory {
                do {
                    try ClaudeSwitchService.shared.unlinkAccount(
                        directoryName: completedLink.directoryName
                    )
                } catch {
                    recoveryFailures.append(
                        "linked directory cleanup failed: \(error.localizedDescription)"
                    )
                }
            }
            if plannedLinkWasPersisted {
                do {
                    try profileManager.updateProfileThrowing(profile)
                } catch {
                    recoveryFailures.append(
                        "profile rollback failed: \(error.localizedDescription)"
                    )
                }
            }
            syncError = operationErrorDescription(
                error,
                recoveryFailures: recoveryFailures
            )
            LoggingService.shared.logError(
                "ClaudeAccountView: Link failed: \(syncError ?? "unknown error")"
            )
        }

        linkingInProgress = false
    }

    private func performUnlinkAccount(profileID: UUID) {
        guard let profile = profileManager.profiles.first(where: {
            $0.id == profileID && $0.providerID == .claude
        }),
              let accountName = profile.cliAccountName else { return }

        do {
            var updated = profile
            updated.cliAccountName = nil
            updated.hasCliAccount = false
            updated.cliAccountSyncedAt = nil
            updated.cliCredentialsJSON = nil
            try profileManager.updateProfileThrowing(updated)

            do {
                try ClaudeSwitchService.shared.unlinkAccount(directoryName: accountName)
            } catch {
                // Keep the UI linked if the directory could not be removed.
                // This compensation also restores the CLI credential through
                // the same verified single-field transaction.
                let unlinkError = error
                do {
                    try profileManager.updateProfileThrowing(profile)
                } catch {
                    syncError = operationErrorDescription(
                        unlinkError,
                        recoveryFailures: [
                            "profile rollback failed: \(error.localizedDescription)"
                        ]
                    )
                    LoggingService.shared.logError(
                        "ClaudeAccountView: Unlink recovery failed: "
                        + (syncError ?? "unknown error")
                    )
                    return
                }
                throw unlinkError
            }

            cliAccountInfo = nil
            terminalLinkVerification = .unverified
        } catch {
            syncError = error.localizedDescription
            LoggingService.shared.logError(
                "ClaudeAccountView: Unlink failed: \(error.localizedDescription)"
            )
        }
    }

    private func checkCredentials(profileID: UUID) {
        guard let profile = profileManager.profiles.first(where: {
            $0.id == profileID && $0.providerID == .claude
        }),
              let accountName = profile.cliAccountName else { return }

        syncError = nil
        let verifier = ClaudeTerminalLinkVerifier(
            syncKeychainToProfile: {
                try ClaudeCodeSyncService.shared.syncKeychainToProfile($0)
            },
            readLinkedAccountCredential: {
                ClaudeSwitchService.shared.readLinkedAccountCredentials(
                    directoryName: $0
                )
            },
            persistLinkedAccountCredential: { profileID, json in
                guard var target = profileManager.profiles.first(
                    where: { $0.id == profileID }
                ) else {
                    throw ClaudeCodeError.noProfileCredentials
                }
                target.cliCredentialsJSON = json
                try profileManager.updateProfileThrowing(target)
            }
        )

        do {
            let source = try verifier.verify(
                profileID: profile.id,
                accountName: accountName
            )
            profileManager.loadProfiles()
            guard var updated = profileManager.profiles.first(
                where: { $0.id == profile.id }
            ) else {
                throw ClaudeCodeError.noProfileCredentials
            }
            updated.hasCliAccount = true
            updated.cliAccountSyncedAt = Date()
            try profileManager.updateProfileThrowing(updated)
            terminalLinkVerification = .ready(source)
            loadCLIAccountInfo(profileID: profile.id)
            if !SharedDataStore.shared.hasShownCLIShellIntegration() {
                showShellIntegration = true
            }
        } catch {
            terminalLinkVerification = .failed
            syncError = error.localizedDescription
            LoggingService.shared.logError(
                "ClaudeAccountView: Credential verification failed",
                error: error
            )
        }
    }

    private func syncFromCLI(profileID: UUID) {
        guard let profile = profileManager.profiles.first(where: {
            $0.id == profileID && $0.providerID == .claude
        }) else { return }

        isSyncing = true
        syncError = nil

        // Try linked account directory first, then fall back to system keychain
        if let accountName = profile.cliAccountName,
           let json = ClaudeSwitchService.shared.readLinkedAccountCredentials(directoryName: accountName) {
            do {
                var updated = profile
                updated.cliCredentialsJSON = json
                updated.hasCliAccount = true
                updated.cliAccountSyncedAt = Date()
                try profileManager.updateProfileThrowing(updated)
                loadCLIAccountInfo(profileID: profile.id)
                LoggingService.shared.log(
                    "ClaudeAccountView: Re-synced from linked account directory"
                )
            } catch {
                syncError = error.localizedDescription
                LoggingService.shared.logError(
                    "ClaudeAccountView: Linked credential persistence failed",
                    error: error
                )
            }
        } else {
            // Fall back to system keychain (works for both linked and unlinked profiles)
            do {
                try ClaudeCodeSyncService.shared.syncToProfile(profile.id)
                profileManager.loadProfiles()

                if var updated = profileManager.profiles.first(where: {
                    $0.id == profile.id
                }) {
                    updated.hasCliAccount = true
                    updated.cliAccountSyncedAt = Date()
                    try profileManager.updateProfileThrowing(updated)
                }
                loadCLIAccountInfo(profileID: profile.id)
                LoggingService.shared.log("ClaudeAccountView: Re-synced from system keychain")
            } catch {
                syncError = error.localizedDescription
                LoggingService.shared.logError("ClaudeAccountView: CLI sync failed - \(error.localizedDescription)")
            }
        }

        isSyncing = false
    }

    private func operationErrorDescription(
        _ error: Error,
        recoveryFailures: [String]
    ) -> String {
        guard !recoveryFailures.isEmpty else {
            return error.localizedDescription
        }
        return error.localizedDescription
            + " Recovery was incomplete: "
            + recoveryFailures.joined(separator: "; ")
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedToClipboard = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copiedToClipboard = false
        }
    }

    private func copyShellSnippet() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(shellSnippet, forType: .string)
        copiedShellSnippet = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copiedShellSnippet = false
        }
    }

    // MARK: - Helpers

    private func loadCLIAccountInfo(profileID: UUID? = nil) {
        let profile = profileID.flatMap { id in
            profileManager.profiles.first { $0.id == id }
        } ?? profileManager.activeClaudeProfile
        guard let profile,
              let json = profile.cliCredentialsJSON else {
            cliAccountInfo = nil
            return
        }
        cliAccountInfo = parseCLIInfo(from: json)
    }

    private func parseCLIInfo(from json: String) -> CLIAccountInfo? {
        let info = ClaudeCodeSyncService.shared.extractSubscriptionInfo(from: json)
        guard let info = info else { return nil }
        return CLIAccountInfo(subscriptionType: info.type, scopes: info.scopes)
    }

    private func extractSessionKey(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = parsed["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String else {
            return nil
        }
        return accessToken
    }

    private func maskCredential(_ credential: String) -> String {
        guard credential.count > 20 else { return "•••••••••" }
        let prefix = String(credential.prefix(12))
        let suffix = String(credential.suffix(4))
        return "\(prefix)•••••\(suffix)"
    }
}

struct CLIAccountInfo {
    let subscriptionType: String
    let scopes: [String]
}
