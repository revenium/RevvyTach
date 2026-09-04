import SwiftUI
import AppKit
import UsageCore

// MARK: - Setup Mode

enum SetupMode {
    case providerSelection
    case manualSetup
    case codexSetup
}

// MARK: - Wizard State Machine

/// CLI-first: the Claude Code sign-in comes first because it is the one that
/// produces every usage number. The browser sign-in follows and is skippable —
/// it adds the organization-wide extra-usage row and the organization name.
///
/// `Comparable` and the four step circles both follow the raw values, so the
/// numbering below is the single source of the order.
enum SetupWizardStep: Int, Comparable {
    case linkClaudeCode = 1
    case enterKey = 2
    case selectOrg = 3
    case confirm = 4

    static func < (lhs: SetupWizardStep, rhs: SetupWizardStep) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum ClaudeCodeDetectionStatus: Equatable {
    case idle
    case checking
    case detected
    case notDetected
}

struct SetupWizardState {
    var currentStep: SetupWizardStep = .linkClaudeCode
    var sessionKey: String = ""
    var validationState: ValidationState = .idle
    var testedOrganizations: [ClaudeAPIService.AccountInfo] = []
    var selectedOrgId: String? = nil
    var autoStartSessionEnabled: Bool = false
    var showInstructions: Bool = false
    var showingAuthSheet: Bool = false
    var attempt = SessionKeyAttempt()
    var claudeSetupTarget: ClaudeManualSetupTarget? = nil
    var targetProfileName: String? = nil
    var launchedChromeProfileLabel: String? = nil
    var hasConfirmedChromeContext = false
    var terminalDetectionStatus: ClaudeCodeDetectionStatus = .idle
    var detectedTerminalCredentials: String? = nil
    var detectedTerminalAccountName: String? = nil
    var detectedTerminalDirectory: String? = nil
    var detectedTerminalSignedInAt: Date? = nil
    var shouldLinkTerminalSignIn = false
}

@MainActor
private enum SetupTargetFreshness {
    static func isCurrent(
        _ target: ClaudeManualSetupTarget?,
        profileManager: ProfileManager
    ) -> Bool {
        guard let target else { return false }
        switch target {
        case .compatibilityCurrent:
            return false
        case .existing(let profileID):
            return profileManager.activeClaudeProfile?.id == profileID
                && profileManager.profiles.contains(where: {
                    $0.id == profileID && $0.providerID == .claude
                })
        case .createdProfile(let profileID):
            let claudeProfiles = profileManager.profiles.filter {
                $0.providerID == .claude
            }
            return claudeProfiles.map(\.id) == [profileID]
                && (profileManager.activeClaudeProfile == nil
                    || profileManager.activeClaudeProfile?.id == profileID)
        case .newProfile:
            return profileManager.activeClaudeProfile == nil
                && !profileManager.profiles.contains(where: {
                    $0.providerID == .claude
                })
        }
    }
}

/// Professional, native macOS setup wizard with a browser-first four-step flow.
struct SetupWizardView: View {
    @Environment(\.dismiss) var dismiss
    @State private var wizardState = SetupWizardState()
    @State private var isMigrating = false
    @State private var migrationMessage: String?
    @State private var setupMode: SetupMode = .providerSelection
    private let apiService = ClaudeAPIService()
    private let dependencies: ProviderUIDependencies
    private let completionOverride: (() -> Void)?

    init(
        dependencies: ProviderUIDependencies? = nil,
        completionOverride: (() -> Void)? = nil
    ) {
        self.dependencies =
            dependencies
            ?? ProviderUICompositionRoot.shared.dependencies
        self.completionOverride = completionOverride
    }

    var body: some View {
        switch setupMode {
        case .providerSelection:
            SetupProviderChoiceView(
                codexAvailable:
                    dependencies.availability.codexSupportEnabled,
                onSelectClaude: {
                    setupMode = .manualSetup
                },
                onSelectCodex: {
                    setupMode = .codexSetup
                }
            )
        case .manualSetup:
            manualSetupBody
        case .codexSetup:
            CodexSetupWizardView(
                dependencies: dependencies,
                onBack: {
                    setupMode = .providerSelection
                },
                onComplete: {
                    if let completionOverride {
                        completionOverride()
                    } else {
                        dismiss()
                    }
                }
            )
        }
    }

    private var manualSetupBody: some View {
        VStack(spacing: 0) {
            // Header with logo and progress indicator
            VStack(spacing: 16) {
                // Logo and title
                HStack(spacing: 2) {
                    Image("WizardLogo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 80, height: 80)

                    VStack(spacing: 8) {
                        Text("setup.welcome.title".localized)
                            .font(.system(size: 24, weight: .semibold))

                        Text("setup.welcome.subtitle".localized)
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.top, 32)

                // Step progress indicator
                HStack(spacing: 8) {
                    SetupStepCircle(number: 1, isCurrent: wizardState.currentStep == .linkClaudeCode, isCompleted: wizardState.currentStep > .linkClaudeCode)
                    SetupStepLine(isCompleted: wizardState.currentStep > .linkClaudeCode)
                    SetupStepCircle(number: 2, isCurrent: wizardState.currentStep == .enterKey, isCompleted: wizardState.currentStep > .enterKey)
                    SetupStepLine(isCompleted: wizardState.currentStep > .enterKey)
                    SetupStepCircle(number: 3, isCurrent: wizardState.currentStep == .selectOrg, isCompleted: wizardState.currentStep > .selectOrg)
                    SetupStepLine(isCompleted: wizardState.currentStep > .selectOrg)
                    SetupStepCircle(number: 4, isCurrent: wizardState.currentStep == .confirm, isCompleted: false)
                    Spacer()
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 16)
            }

            Divider()

            // Migration section - compact (only show if migration not completed yet)
            if MigrationService.shared.shouldShowMigrationOption() {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 16))
                        .foregroundColor(.blue)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("wizard.migrate_old_data".localized)
                            .font(.system(size: 12, weight: .medium))

                        if let message = migrationMessage {
                            Text(message)
                                .font(.system(size: 11))
                                .foregroundColor(.green)
                                .lineLimit(1)
                        } else {
                            Text("wizard.migrate_description_short".localized)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                    }

                    Spacer()

                    HStack(spacing: 8) {
                        Button(action: migrateOldData) {
                            HStack {
                                if isMigrating {
                                    ProgressView()
                                        .scaleEffect(0.6)
                                } else {
                                    Text("wizard.migrate_button".localized)
                                        .font(.system(size: 11))
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isMigrating)

                        Button(action: skipMigration) {
                            Text("wizard.skip_migration".localized)
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                        .disabled(isMigrating)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Color.blue.opacity(0.08))

                Divider()
            }

            // Step content based on wizard state
            Group {
                switch wizardState.currentStep {
                case .enterKey:
                    EnterKeyStepSetup(
                        wizardState: $wizardState,
                        apiService: apiService,
                        dependencies: dependencies
                    )
                case .selectOrg:
                    SelectOrgStepSetup(wizardState: $wizardState)
                case .linkClaudeCode:
                    LinkClaudeCodeStepSetup(wizardState: $wizardState)
                case .confirm:
                    ConfirmStepSetup(
                        wizardState: $wizardState,
                        apiService: apiService,
                        dismiss: dismiss,
                        dependencies: dependencies
                    )
                }
            }
            .animation(.easeInOut(duration: 0.3), value: wizardState.currentStep)
        }
        .frame(width: 580, height: 680)
        .onAppear {
            // Load auto-start preference from active profile
            if let activeProfile =
                dependencies.profileManager.activeProfile {
                wizardState.autoStartSessionEnabled = activeProfile.autoStartSessionEnabled
            }
        }
    }

    // MARK: - Migration Functions

    private func migrateOldData() {
        isMigrating = true
        migrationMessage = nil

        Task {
            do {
                let count = try MigrationService.shared.migrateFromAppGroup()
                // Imported v3 profiles and legacy credential/settings sources
                // must pass the verified provider-aware migration before the
                // wizard can consider setup complete.
                try ProfileMigrationService.shared.migrateIfNeededThrowing()
                await MainActor.run {
                    isMigrating = false
                    migrationMessage = String(format: "wizard.migration_success".localized, count)
                    // Reload profiles to reflect migrated data
                    dependencies.profileManager.loadProfiles()
                }

                // A legacy container can contain settings/credentials without
                // a profile. Preserve them for explicit provider choice and
                // never dismiss into a zero-profile state.
                let hasProfiles = await MainActor.run {
                    !dependencies.profileManager.profiles.isEmpty
                }
                if hasProfiles {
                    await MainActor.run {
                        dependencies.markSetupCompleted()
                    }
                    try? await Task.sleep(
                        nanoseconds: 1_500_000_000
                    )
                    await MainActor.run {
                        dismiss()
                    }
                }
            } catch {
                await MainActor.run {
                    isMigrating = false
                    migrationMessage = String(format: "wizard.migration_failed".localized, error.localizedDescription)
                }
            }
        }
    }

    private func skipMigration() {
        // Mark migration as completed (declined) so we don't ask again
        UserDefaults.standard.set(true, forKey: "HasMigratedFromAppGroup")
        migrationMessage = "wizard.migration_skipped".localized
    }
}

struct SetupProviderChoiceView: View {
    let codexAvailable: Bool
    let onSelectClaude: () -> Void
    let onSelectCodex: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 16)

            Image("WizardLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 180, height: 180)
                .padding(.bottom, 26)

            VStack(spacing: 10) {
                Text(
                    ProviderUILocalization.text(
                        "setup.provider.title",
                        fallback: "Choose a Usage Provider"
                    )
                )
                .font(.system(size: 27, weight: .semibold))
                Text(
                    ProviderUILocalization.text(
                        "setup.provider.subtitle",
                        fallback:
                            "Profiles keep provider accounts and usage separate. You can add both Claude and Codex profiles."
                    )
                )
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 430)
            }
            .padding(.bottom, 30)

            HStack(spacing: 20) {
                providerButton(
                    title: ProviderUILocalization.text(
                        "setup.provider.claude_title",
                        fallback: "Claude"
                    ),
                    subtitle: ProviderUILocalization.text(
                        "setup.provider.claude_subtitle",
                        fallback:
                            "Connect Claude.ai, Console API, or Claude Code"
                    ),
                    icon: "sparkles",
                    enabled: true,
                    identifier:
                        ProviderUIAccessibility.providerChoiceClaude,
                    action: onSelectClaude
                )
                providerButton(
                    title: ProviderUILocalization.text(
                        "setup.provider.codex_title",
                        fallback: "Codex"
                    ),
                    subtitle: ProviderUILocalization.text(
                        "setup.provider.codex_subtitle",
                        fallback:
                            "Link CODEX_HOME and your ChatGPT subscription"
                    ),
                    icon:
                        "chevron.left.forwardslash.chevron.right",
                    enabled: codexAvailable,
                    identifier:
                        ProviderUIAccessibility.providerChoiceCodex,
                    action: onSelectCodex
                )
            }

            if !codexAvailable {
                Text(
                    ProviderUILocalization.text(
                        "codex.feature_unavailable",
                        fallback:
                            "Codex support is not available in this build."
                    )
                )
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .padding(.top, 16)
                .accessibilityIdentifier(
                    ProviderUIAccessibility.capabilityDisabled
                )
            }

            Spacer(minLength: 16)
        }
        .padding(.horizontal, 40)
        .frame(width: 580, height: 680)
    }

    private func providerButton(
        title: String,
        subtitle: String,
        icon: String,
        enabled: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        ProviderChoiceCard(
            title: title,
            subtitle: subtitle,
            icon: icon,
            enabled: enabled,
            identifier: identifier,
            action: action
        )
    }
}

/// One provider card in the setup wizard's provider-choice screen. A struct
/// rather than a builder function so each card can hold its own hover state.
private struct ProviderChoiceCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let enabled: Bool
    let identifier: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 36, weight: .medium))
                    .frame(height: 42)
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 18)
            }
            .frame(width: 240, height: 210)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(
                        Color.primary.opacity(
                            isHovering && enabled ? 0.10 : 0.05
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(
                        Color.accentColor.opacity(
                            isHovering && enabled ? 0.8 : 0
                        ),
                        lineWidth: 1.5
                    )
            )
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.55)
        .accessibilityIdentifier(identifier)
    }
}

struct CodexSetupWizardView: View {
    private enum FocusTarget: Hashable {
        case profileName
        case homePath
    }

    private let dependencies: ProviderUIDependencies
    let onBack: () -> Void
    let onComplete: () -> Void

    @StateObject private var viewModel: ProviderAccountViewModel
    @State private var profileName = ""
    @State private var homePath = ""
    @State private var isHomeVerified = false
    @State private var isCommitting = false
    @State private var operationMessage: String?
    @FocusState private var focusTarget: FocusTarget?

    init(
        dependencies: ProviderUIDependencies,
        onBack: @escaping () -> Void,
        onComplete: @escaping () -> Void
    ) {
        self.dependencies = dependencies
        self.onBack = onBack
        self.onComplete = onComplete
        _viewModel = StateObject(
            wrappedValue: ProviderAccountViewModel(
                dependencies: dependencies
            )
        )
        _homePath = State(
            initialValue: Self.prefillHomePath(dependencies: dependencies)
        )
    }

    /// There's no existing linked home to defer to here (this is initial
    /// setup for a brand-new profile), unlike the equivalent prefill in
    /// `ProviderAccountSettingsView`. See
    /// `CodexDefaultHomeResolver.prefillCandidate` for the prefill rule
    /// itself.
    private static func prefillHomePath(
        dependencies: ProviderUIDependencies
    ) -> String {
        CodexDefaultHomeResolver.prefillCandidate(
            profiles: dependencies.profileManager.profiles
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text(
                    ProviderUILocalization.text(
                        "codex.setup.title",
                        fallback: "Set Up Codex Usage"
                    )
                )
                .font(.system(size: 24, weight: .semibold))
                .accessibilityIdentifier(
                    ProviderUIAccessibility.setupTitle
                )
                Text(
                    ProviderUILocalization.text(
                        "codex.setup.subtitle",
                        fallback:
                            "Link an existing Codex home. Authentication files remain owned by Codex and are never read or copied by this app."
                    )
                )
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            }
            .padding(28)

            Divider()

            ScrollView {
                VStack(
                    alignment: .leading,
                    spacing: 18
                ) {
                    TextField(
                        ProviderUILocalization.text(
                            "profiles.name_placeholder",
                            fallback: "Profile name (optional)"
                        ),
                        text: $profileName
                    )
                    .textFieldStyle(.roundedBorder)
                    .focused($focusTarget, equals: .profileName)
                    .accessibilityIdentifier(
                        ProviderUIAccessibility.profileName
                    )

                    HStack {
                        TextField(
                            ProviderUILocalization.text(
                                "codex.home.placeholder",
                                fallback:
                                    "Choose a CODEX_HOME directory"
                            ),
                            text: $homePath
                        )
                        .textFieldStyle(.roundedBorder)
                        .focused($focusTarget, equals: .homePath)
                        .accessibilityIdentifier(
                            ProviderUIAccessibility.homePath
                        )
                        Button {
                            chooseHome()
                        } label: {
                            Image(systemName: "folder")
                        }
                        .accessibilityIdentifier(
                            ProviderUIAccessibility.homePicker
                        )
                        Button(
                            !isHomeVerified
                                ? ProviderUILocalization.text(
                                    "codex.home.link",
                                    fallback: "Verify Home"
                                )
                                : ProviderUILocalization.text(
                                    "codex.home.relink",
                                    fallback: "Verify Again"
                                )
                        ) {
                            linkHome()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(homePath.isEmpty)
                        .accessibilityIdentifier(
                            ProviderUIAccessibility.homeLink
                        )
                    }

                    if let operationMessage {
                        WizardStatusBox(
                            message: operationMessage,
                            type: .error
                        )
                    }

                    if isHomeVerified {
                        accountSetup
                    }
                }
                .padding(32)
            }

            Divider()
            HStack {
                Button("common.back".localized) {
                    viewModel.dismiss()
                    onBack()
                }
                .accessibilityIdentifier(
                    ProviderUIAccessibility.setupBack
                )
                Spacer()
                Button(
                    ProviderUILocalization.text(
                        "codex.setup.start_tracking",
                        fallback: "Start Tracking"
                    )
                ) {
                    commitSetup()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canComplete || isCommitting)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier(
                    ProviderUIAccessibility.setupComplete
                )
            }
            .padding(20)
        }
        .frame(width: 580, height: 680)
        .onChange(of: homePath) { _, _ in
            guard isHomeVerified else { return }
            isHomeVerified = false
            viewModel.invalidateDraft()
            operationMessage = ProviderUILocalization.text(
                "codex.home.reverify_after_edit",
                fallback:
                    "The Codex home changed. Verify it again before continuing."
            )
        }
        .onChange(of: viewModel.loginState) { _, state in
            if case .awaiting(.browser(let url)) = state {
                NSWorkspace.shared.open(url)
            }
        }
        .onAppear {
            focusTarget = .homePath
        }
        .onDisappear {
            viewModel.dismiss()
        }
    }

    @ViewBuilder
    private var accountSetup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Text(
                ProviderUILocalization.text(
                    "codex.setup.account",
                    fallback: "Codex Account"
                )
            )
            .font(.system(size: 14, weight: .semibold))

            switch viewModel.accountState {
            case .linked(let snapshot):
                Label(
                    [
                        snapshot.account.displayName,
                        snapshot.account.planName
                    ]
                    .compactMap { $0 }
                    .joined(separator: " • "),
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundColor(.green)
                .accessibilityIdentifier(
                    ProviderUIAccessibility.accountStatus
                )
            case .loading:
                HStack {
                    ProgressView()
                    Text(
                        ProviderUILocalization.text(
                            "codex.account.checking",
                            fallback: "Checking Codex…"
                        )
                    )
                }
            case .unauthenticated:
                Text(
                    ProviderUILocalization.text(
                        "codex.account.signed_out",
                        fallback: "Sign-in required"
                    )
                )
                    .foregroundColor(.secondary)
            case .unsupported:
                Text(
                    ProviderUILocalization.text(
                        "codex.account.unsupported",
                        fallback:
                            "This account does not expose ChatGPT subscription usage."
                    )
                )
                .foregroundColor(.red)
            case .unavailable(let message):
                Text(message).foregroundColor(.red)
            case .idle:
                EmptyView()
            }

            HStack {
                Button("common.refresh".localized) {
                    viewModel.refresh()
                }
                .accessibilityIdentifier(
                    ProviderUIAccessibility.accountRefresh
                )
                Button(
                    ProviderUILocalization.text(
                        "codex.login.browser",
                        fallback: "Sign In in Browser"
                    )
                ) {
                    viewModel.startLogin(.browser)
                }
                .accessibilityIdentifier(
                    ProviderUIAccessibility.loginStartBrowser
                )
                Button(
                    ProviderUILocalization.text(
                        "codex.login.device",
                        fallback: "Use Device Code"
                    )
                ) {
                    viewModel.startLogin(.deviceCode)
                }
                .accessibilityIdentifier(
                    ProviderUIAccessibility.loginStartDevice
                )
            }

            switch viewModel.loginState {
            case .awaiting(.deviceCode(
                let verificationURL,
                let userCode
            )):
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        ProviderUILocalization.text(
                            "codex.login.user_code",
                            fallback: "Device code"
                        )
                        + ": \(userCode)"
                    )
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityIdentifier(
                            ProviderUIAccessibility.loginDeviceCode
                        )
                    Button(
                        ProviderUILocalization.text(
                            "codex.login.open_verification",
                            fallback: "Open Verification Page"
                        )
                    ) {
                        NSWorkspace.shared.open(verificationURL)
                    }
                    .accessibilityIdentifier(
                        ProviderUIAccessibility.loginOpenVerification
                    )
                    Button(
                        ProviderUILocalization.text(
                            "codex.login.cancel",
                            fallback: "Cancel Sign-In"
                        )
                    ) {
                        viewModel.cancelLogin()
                    }
                    .accessibilityIdentifier(
                        ProviderUIAccessibility.loginCancel
                    )
                }
            case .awaiting(.browser):
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        ProviderUILocalization.text(
                            "codex.login.browser_waiting",
                            fallback:
                                "Complete sign-in in the browser."
                        )
                    )
                    Button(
                        ProviderUILocalization.text(
                            "codex.login.cancel",
                            fallback: "Cancel Sign-In"
                        )
                    ) {
                        viewModel.cancelLogin()
                    }
                    .accessibilityIdentifier(
                        ProviderUIAccessibility.loginCancel
                    )
                }
            case .starting:
                ProgressView()
            case .cancelling:
                Text(
                    ProviderUILocalization.text(
                        "codex.login.cancelling",
                        fallback: "Canceling sign-in…"
                    )
                )
            case .succeeded:
                Label(
                    ProviderUILocalization.text(
                        "codex.login.succeeded",
                        fallback: "Signed in with Codex"
                    ),
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundColor(.green)
            case .failed(let message):
                Text(message).foregroundColor(.red)
            case .idle:
                EmptyView()
            }
        }
        .font(.system(size: 12))
    }

    private var canComplete: Bool {
        if case .linked = viewModel.accountState {
            return true
        }
        return false
    }

    private func chooseHome() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            homePath = url.path
        }
    }

    private func linkHome() {
        do {
            try viewModel.selectDraftCodexHome(homePath)
            isHomeVerified = true
            operationMessage = nil
            viewModel.refresh()
        } catch {
            isHomeVerified = false
            operationMessage =
                ProviderAccountViewModel.message(for: error)
        }
    }

    /// Re-canonicalizes and duplicate-checks the home immediately before the
    /// only metadata write. Back, close, login failure, and cancellation leave
    /// a zero-profile first run untouched.
    private func commitSetup() {
        guard !isCommitting else { return }
        guard let verifiedIdentity =
                viewModel.verifiedDraftIdentity else {
            operationMessage = ProviderAccountViewModel.message(
                for: CodexHomeCanonicalizationError
                    .changedSinceVerification
            )
            return
        }
        isCommitting = true
        Task {
            do {
                _ = try await dependencies.completeCodexSetup(
                    name:
                        profileName.isEmpty
                        ? nil : profileName,
                    homePath: homePath,
                    verifiedIdentity: verifiedIdentity
                )
                isCommitting = false
                onComplete()
            } catch {
                isCommitting = false
                operationMessage =
                    ProviderAccountViewModel.message(for: error)
            }
        }
    }
}

// MARK: - Step 1: Enter Key

struct EnterKeyStepSetup: View {
    @Environment(\.dismiss) var dismiss
    @Binding var wizardState: SetupWizardState
    let apiService: ClaudeAPIService
    let dependencies: ProviderUIDependencies

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Step header
                    SetupStepHeader(
                        stepNumber: 2,
                        title: "wizard.browser_sign_in.title".localized
                    )

                    Text("setup.step.get_session_key.description".localized)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)

                    Text("wizard.browser_sign_in.why".localized)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)

                    ChromeAssistedSessionKeyEntry(
                        sessionKey: $wizardState.sessionKey,
                        validationState: wizardState.validationState,
                        onSessionKeyChanged: retireAttemptForKeyEdit,
                        onValidationRequested: testConnection,
                        onLaunchStarted: beginChromeLaunch,
                        isLaunchCurrent: { generation in
                            wizardState.attempt.matches(generation)
                                && capturedTargetIsStillCurrent()
                        },
                        onChromeProfileLaunched: { label in
                            wizardState.launchedChromeProfileLabel = label
                            wizardState.hasConfirmedChromeContext = false
                        }
                    )

                    // Fallback: the hardened embedded sign-in remains an
                    // alternative to browser-assisted manual setup.
                    VStack(alignment: .leading, spacing: 8) {
                        Text("chrome_assisted.embedded_fallback".localized)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)

                        Button(action: beginEmbeddedAuth) {
                            HStack(spacing: 6) {
                                Image(systemName: "globe")
                                    .font(.system(size: 12))
                                Text("personal.signin_button".localized)
                                    .font(.system(size: 12))
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .disabled(wizardState.validationState == .validating)
                    }
                    .sheet(isPresented: $wizardState.showingAuthSheet) {
                        ConsoleAuthSheet(
                            title: "personal.signin_sheet_title".localized,
                            loginURL: URL(string: "https://claude.ai/login")!,
                            cookieDomain: "claude.ai",
                            onSuccess: { result in
                                wizardState.showingAuthSheet = false
                                replaceSessionKey(
                                    result.sessionKey,
                                    preserveCapturedTarget: true
                                )
                                testConnection()
                            },
                            onCancel: {
                                wizardState.showingAuthSheet = false
                                retireAttempt(clearKey: false)
                            }
                        )
                    }

                    // Validation Status
                    if case .success(let message) = wizardState.validationState {
                        WizardStatusBox(message: message, type: .success)
                    } else if case .error(let message) = wizardState.validationState {
                        WizardStatusBox(message: message, type: .error)
                    }
                }
                .padding(32)
            }

            Divider()

            // Footer
            HStack {
                Button("common.back".localized) {
                    withAnimation {
                        wizardState.currentStep = .linkClaudeCode
                    }
                }
                .buttonStyle(.bordered)

                Button("common.cancel".localized) {
                    retireAttempt(clearKey: true)
                    dismiss()
                }
                .buttonStyle(.bordered)

                Spacer()

                // The browser sign-in is optional now, so the wizard has to
                // offer a way past it. Without this the only exits from this
                // step were entering a session key or cancelling the whole
                // wizard, which is what made a terminal-only setup feel like
                // an unfinished one.
                Button("wizard.link_terminal.skip_browser".localized) {
                    retireAttempt(clearKey: true)
                    wizardState.selectedOrgId = nil
                    wizardState.testedOrganizations = []
                    withAnimation {
                        wizardState.currentStep = .confirm
                    }
                }
                .buttonStyle(.bordered)
            }
            .padding(20)
        }
    }

    private func testConnection() {
        let validator = SessionKeyValidator()
        let validationResult = validator.validationStatus(wizardState.sessionKey)

        guard validationResult.isValid else {
            wizardState.validationState = .error(validationResult.errorMessage ?? "Invalid")
            return
        }

        retireAttempt(
            clearKey: false,
            clearChromeContext: false,
            clearTarget: false
        )
        if wizardState.claudeSetupTarget == nil {
            captureNewTarget()
        }
        guard capturedTargetIsStillCurrent() else {
            wizardState.validationState = .error(
                "chrome_assisted.profile_changed".localized
            )
            return
        }
        let generation = wizardState.attempt.generation
        let key = wizardState.sessionKey
        wizardState.validationState = .validating

        Task {
            do {
                // READ-ONLY TEST - does NOT save to Keychain
                let organizations = try await apiService.testSessionKey(key)

                await MainActor.run {
                    guard isCurrent(generation: generation, key: key) else {
                        return
                    }
                    guard SessionKeyAttemptPolicy.hasSelectableOrganization(
                        organizations.count
                    ) else {
                        wizardState.validationState = .error(
                            "chrome_assisted.no_organizations".localized
                        )
                        return
                    }
                    wizardState.testedOrganizations = organizations
                    // Never start on a console/API organization: that is the
                    // choice that leaves the popover permanently unavailable.
                    wizardState.selectedOrgId =
                        ClaudeOrganizationClassifier.defaultSelection(
                            organizations
                        )
                    wizardState.validationState = .success(
                        String(
                            format: "chrome_assisted.validation_success".localized,
                            organizations.count
                        )
                    )

                    // Auto-advance to next step
                    withAnimation {
                        wizardState.currentStep = .selectOrg
                    }
                }

            } catch {
                let appError = AppError.wrap(error)
                ErrorLogger.shared.log(appError, severity: .error)

                await MainActor.run {
                    guard isCurrent(generation: generation, key: key) else {
                        return
                    }
                    let errorMessage = SetupErrorMessage.text(for: appError)
                    wizardState.validationState = .error(errorMessage)
                }
            }
        }
    }

    private func replaceSessionKey(
        _ key: String,
        preserveCapturedTarget: Bool = false
    ) {
        wizardState.sessionKey = key
        retireAttempt(
            clearKey: false,
            clearTarget: !preserveCapturedTarget
        )
    }

    private func beginEmbeddedAuth() {
        _ = beginChromeLaunch()
        wizardState.showingAuthSheet = true
    }

    private func beginChromeLaunch() -> UUID {
        retireAttempt(clearKey: false)
        captureNewTarget()
        return wizardState.attempt.generation
    }

    private func retireAttemptForKeyEdit() {
        retireAttempt(
            clearKey: false,
            clearChromeContext: false,
            clearTarget: false
        )
    }

    private func retireAttempt(
        clearKey: Bool,
        clearChromeContext: Bool = true,
        clearTarget: Bool = true
    ) {
        wizardState.attempt.invalidate()
        wizardState.validationState = .idle
        wizardState.testedOrganizations = []
        wizardState.selectedOrgId = nil
        if clearTarget {
            wizardState.claudeSetupTarget = nil
            wizardState.targetProfileName = nil
        }
        if clearChromeContext {
            wizardState.launchedChromeProfileLabel = nil
            wizardState.hasConfirmedChromeContext = false
        }
        if clearKey { wizardState.sessionKey = "" }
    }

    private func isCurrent(generation: UUID, key: String) -> Bool {
        SessionKeyAttemptPolicy.acceptsCompletion(
            generation: generation,
            currentGeneration: wizardState.attempt.generation,
            keyMatches: wizardState.sessionKey == key,
            targetMatches: capturedTargetIsStillCurrent()
        )
    }

    private func captureNewTarget() {
        if let profile = dependencies.profileManager.activeClaudeProfile {
            wizardState.claudeSetupTarget = .existing(profile.id)
            wizardState.targetProfileName = profile.name
        } else {
            wizardState.claudeSetupTarget = .newProfile
            wizardState.targetProfileName =
                "chrome_assisted.new_claude_profile".localized
        }
    }

    private func capturedTargetIsStillCurrent() -> Bool {
        SetupTargetFreshness.isCurrent(
            wizardState.claudeSetupTarget,
            profileManager: dependencies.profileManager
        )
    }
}

// MARK: - Step 2: Select Organization

struct SelectOrgStepSetup: View {
    @Binding var wizardState: SetupWizardState

    /// Only the organizations that can carry Claude usage, in server order.
    /// Console/API-only ones are left out and counted, not dimmed. Shared with
    /// the credentials pane's picker so the two cannot drift.
    private var organizations: [ClaudeAPIService.AccountInfo] {
        ClaudeOrganizationClassifier.pickerRows(wizardState.testedOrganizations)
    }

    /// The sentence accounting for the rows that were left out, or `nil` when
    /// none were.
    private var hiddenAPIOnlyNotice: String? {
        ClaudeOrganizationClassifier.hiddenAPIOnlyNotice(
            for: wizardState.testedOrganizations
        )
    }

    private var hasSelectableOrganization: Bool {
        ClaudeOrganizationClassifier.hasSelectableOrganization(
            wizardState.testedOrganizations
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Step header
                    SetupStepHeader(
                        stepNumber: 3,
                        title: "wizard.organization.title".localized
                    )

                    Text("wizard.select_org_title".localized)
                        .font(.system(size: 13))

                    Text("wizard.select_org_subtitle".localized)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)

                    // Stated before the list, not after it: this list scrolls,
                    // and an explanation placed underneath falls below the fold
                    // exactly when there are enough organizations to need it.
                    if let hiddenAPIOnlyNotice {
                        APIOnlyHiddenFootnote(message: hiddenAPIOnlyNotice)
                    }

                    // Organization list with radio buttons. Only organizations
                    // that can carry Claude usage; console/API-only ones are
                    // left out and accounted for by the note above.
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(organizations, id: \.uuid) { org in
                            let isSelected = wizardState.selectedOrgId == org.uuid
                            HStack(spacing: 12) {
                                Image(systemName: isSelected ? "circle.fill" : "circle")
                                    .foregroundColor(isSelected ? .accentColor : .secondary)
                                    .font(.system(size: 14))

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(org.name)
                                        .font(.system(size: 13, weight: .medium))
                                    Text(ClaudeOrganizationClassifier.descriptor(org))
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                    // Several organizations can share both a
                                    // name and a kind; the id prefix is the
                                    // last thing that separates them.
                                    Text(String(org.uuid.prefix(8)))
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer()
                            }
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(isSelected ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: 1)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                wizardState.selectedOrgId = org.uuid
                            }
                            .accessibilityIdentifier("wizard.org_row.\(org.uuid)")
                        }
                    }

                    // An account can hold nothing but console organizations.
                    // Say so, rather than leaving every row dimmed and Next
                    // dead with no explanation.
                    if !hasSelectableOrganization {
                        WizardStatusBox(
                            message: "wizard.no_claude_organizations".localized,
                            type: .error
                        )
                    }
                }
                .padding(32)
            }

            Divider()

            // Footer
            HStack {
                Button("common.back".localized) {
                    withAnimation {
                        wizardState.currentStep = .enterKey
                    }
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("common.next".localized) {
                    withAnimation {
                        wizardState.currentStep = .confirm
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(wizardState.selectedOrgId == nil)
            }
            .padding(20)
        }
    }
}

// MARK: - Step 3: Link Claude Code

struct LinkClaudeCodeStepSetup: View {
    @Binding var wizardState: SetupWizardState

    private var profileName: String {
        wizardState.targetProfileName
            ?? "chrome_assisted.new_claude_profile".localized
    }

    private var signInCommand: String {
        let slug = ClaudeSwitchService.shared.sanitizeProfileName(profileName)
        return "CLAUDE_CONFIG_DIR=~/.claude-accounts/\(slug) claude"
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    SetupStepHeader(
                        stepNumber: 1,
                        title: "wizard.link_terminal.title".localized
                    )

                    Text("wizard.link_terminal.subtitle".localized)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    switch wizardState.terminalDetectionStatus {
                    case .idle, .checking:
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            Text("wizard.link_terminal.checking".localized)
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 140)

                    case .detected:
                        detectedCard

                    case .notDetected:
                        notDetectedCard
                    }
                }
                .padding(32)
            }

            Divider()

            HStack {
                // First step now, so there is nothing to go back to. The
                // browser sign-in that used to precede it follows it instead.
                Spacer()

                if wizardState.terminalDetectionStatus == .detected {
                    Button("wizard.link_terminal.continue_without".localized) {
                        wizardState.shouldLinkTerminalSignIn = false
                        withAnimation {
                            wizardState.currentStep = .enterKey
                        }
                    }
                    .buttonStyle(.bordered)

                    Button("wizard.link_terminal.link_continue".localized) {
                        wizardState.shouldLinkTerminalSignIn = true
                        withAnimation {
                            wizardState.currentStep = .enterKey
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!wizardState.shouldLinkTerminalSignIn)
                } else if wizardState.terminalDetectionStatus == .notDetected {
                    Button("wizard.link_terminal.continue_without".localized) {
                        wizardState.shouldLinkTerminalSignIn = false
                        withAnimation {
                            wizardState.currentStep = .enterKey
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
        }
        .task {
            guard wizardState.terminalDetectionStatus == .idle else { return }
            detectTerminalSignIn()
        }
    }

    private var detectedCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(
                "wizard.link_terminal.detected_title".localized,
                systemImage: "checkmark.circle.fill"
            )
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.green)

            VStack(alignment: .leading, spacing: 5) {
                if let accountName = wizardState.detectedTerminalAccountName {
                    Text(
                        String(
                            format: "wizard.link_terminal.account".localized,
                            accountName
                        )
                    )
                }
                if let directory = wizardState.detectedTerminalDirectory {
                    Text(
                        String(
                            format: "wizard.link_terminal.directory".localized,
                            directory
                        )
                    )
                    .textSelection(.enabled)
                }
                if let signedInAt = wizardState.detectedTerminalSignedInAt {
                    HStack(spacing: 4) {
                        Text("wizard.link_terminal.signed_in".localized)
                        Text(signedInAt, style: .relative)
                    }
                }
            }
            .font(.system(size: 11))
            .foregroundColor(.secondary)

            Divider()

            Toggle(isOn: $wizardState.shouldLinkTerminalSignIn) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(
                        String(
                            format: "wizard.link_terminal.link_checkbox".localized,
                            profileName
                        )
                    )
                    .font(.system(size: 12, weight: .medium))
                    Text("wizard.link_terminal.link_detail".localized)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)
        }
        .padding(16)
        .background(Color.green.opacity(0.07))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.green.opacity(0.28))
        )
        .cornerRadius(10)
    }

    private var notDetectedCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(
                "wizard.link_terminal.not_found_title".localized,
                systemImage: "terminal"
            )
            .font(.system(size: 14, weight: .semibold))

            Text("wizard.link_terminal.not_found_detail".localized)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("wizard.link_terminal.command_label".localized)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                HStack(spacing: 8) {
                    Text(signInCommand)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Button("wizard.link_terminal.copy_command".localized) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            signInCommand,
                            forType: .string
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(10)
                .background(Color.secondary.opacity(0.07))
                .cornerRadius(6)
            }

            Button("wizard.link_terminal.check_again".localized) {
                detectTerminalSignIn()
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .background(Color.secondary.opacity(0.04))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.2))
        )
        .cornerRadius(10)
    }

    private func detectTerminalSignIn() {
        wizardState.terminalDetectionStatus = .checking
        wizardState.shouldLinkTerminalSignIn = false

        Task {
            let detection = detectedTerminalSignIn()
            await MainActor.run {
                guard let detection else {
                    wizardState.detectedTerminalCredentials = nil
                    wizardState.detectedTerminalAccountName = nil
                    wizardState.detectedTerminalDirectory = nil
                    wizardState.detectedTerminalSignedInAt = nil
                    wizardState.terminalDetectionStatus = .notDetected
                    return
                }

                let accountName = detection.accountName
                wizardState.detectedTerminalCredentials = detection.credentials
                wizardState.detectedTerminalAccountName = accountName
                if let accountName {
                    let directory = ClaudeSwitchService.shared
                        .accountDirectoryPath(for: accountName)
                    wizardState.detectedTerminalDirectory = directory.path
                    wizardState.detectedTerminalSignedInAt = latestSignInDate(
                        in: directory
                    )
                } else {
                    wizardState.detectedTerminalDirectory = nil
                    wizardState.detectedTerminalSignedInAt = nil
                }
                wizardState.shouldLinkTerminalSignIn = true
                wizardState.terminalDetectionStatus = .detected
            }
        }
    }

    private func detectedTerminalSignIn() -> (
        credentials: String,
        accountName: String?
    )? {
        let syncService = ClaudeCodeSyncService.shared
        let switchService = ClaudeSwitchService.shared
        let commandAccountName = switchService.sanitizeProfileName(profileName)

        // The only named directory this flow may adopt is the one the wizard
        // explicitly tells the user to sign into. Do not guess among other
        // linked accounts on a multi-account machine.
        if let credentials = try? syncService.readSystemCredentials(
            forAccountNamed: commandAccountName
        ), isUsableTerminalSignIn(credentials) {
            return (credentials, commandAccountName)
        }

        return nil
    }

    private func isUsableTerminalSignIn(_ credentials: String) -> Bool {
        ClaudeCodeSyncService.shared.extractAccessToken(from: credentials) != nil
            && !ClaudeCodeSyncService.shared.isTokenExpired(credentials)
    }

    private func latestSignInDate(in directory: URL) -> Date? {
        [".credentials.json", ".claude.json"]
            .compactMap { filename -> Date? in
                let path = directory.appendingPathComponent(filename).path
                return (try? FileManager.default.attributesOfItem(atPath: path))?[
                    .modificationDate
                ] as? Date
            }
            .max()
    }
}

// MARK: - Step 4: Review & Save

struct ConfirmStepSetup: View {
    @Binding var wizardState: SetupWizardState
    let apiService: ClaudeAPIService
    let dismiss: DismissAction
    let dependencies: ProviderUIDependencies
    @State private var isSaving = false
    /// Set only when the save failed because secure storage refused the
    /// credential, which is the one case the user can knowingly accept.
    @State private var offerSessionOnly = false

    private var willLinkTerminalSignIn: Bool {
        guard wizardState.shouldLinkTerminalSignIn,
              let credentials = wizardState.detectedTerminalCredentials else {
            return false
        }
        return ClaudeCodeSyncService.carriesLogin(credentials)
    }

    /// A real three-way verdict now. It used to be binary — a browser
    /// sign-in was always being entered by the time this step was reached, so
    /// "no terminal sign-in" could only mean `.browserOnly`. The browser step
    /// is skippable now, so `.terminalOnly` is reachable and must be reported
    /// as the complete, working state it is.
    private var reviewSetupState: ClaudeSetupState {
        let hasBrowser = wizardState.selectedOrgId != nil
        switch (hasBrowser, willLinkTerminalSignIn) {
        case (true, true):
            return .complete
        case (true, false):
            return .browserOnly
        case (false, true):
            return .terminalOnly
        case (false, false):
            return .none
        }
    }

    private var browserReviewDetail: String {
        let organizationName = wizardState.testedOrganizations.first {
            $0.uuid == wizardState.selectedOrgId
        }?.name ?? "wizard.organization".localized
        return String(
            format: "wizard.review.browser_detail".localized,
            organizationName
        )
    }

    private var terminalReviewDetail: String {
        willLinkTerminalSignIn
            ? "wizard.review.terminal_linked_detail".localized
            : "wizard.review.terminal_not_linked_detail".localized
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Step header
                    SetupStepHeader(
                        stepNumber: 4,
                        title: "wizard.review.title".localized
                    )

                    ClaudeSignInSummaryView(
                        state: reviewSetupState,
                        browserDetail: browserReviewDetail,
                        terminalDetail: terminalReviewDetail
                    )

                    if let chromeLabel = wizardState.launchedChromeProfileLabel {
                        Toggle(
                            isOn: $wizardState.hasConfirmedChromeContext
                        ) {
                            Text(
                                String(
                                    format:
                                        "chrome_assisted.confirm_context"
                                            .localized,
                                    chromeLabel,
                                    targetProfileName
                                )
                            )
                            .font(.system(size: 11))
                        }
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("chrome.context_confirmation")
                    }

                    // Auto-start session option
                    VStack(alignment: .leading, spacing: 10) {
                        Divider()

                        HStack(spacing: 6) {
                            Text("setup.auto_start_session".localized)
                                .font(.system(size: 13, weight: .semibold))

                            Text("session.beta_badge".localized)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.orange)
                                )
                        }

                        Text("setup.auto_start_session.description".localized)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Toggle(isOn: $wizardState.autoStartSessionEnabled) {
                            Text("setup.enable_auto_start".localized)
                                .font(.system(size: 12, weight: .medium))
                        }
                        .toggleStyle(.switch)
                    }

                    // Saving is the only thing that can fail on this step, so
                    // the failure belongs here rather than back on step 1
                    // where it reads as a rejected session key.
                    if case .error(let message) = wizardState.validationState {
                        WizardStatusBox(message: message, type: .error)

                        if offerSessionOnly {
                            Button(action: { saveConfiguration(acceptSessionOnly: true) }) {
                                Text("setup.use_session_only".localized)
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(.bordered)
                            .disabled(isSaving)
                            .accessibilityIdentifier("setup.use_session_only")
                        }
                    }
                }
                .padding(32)
            }

            Divider()

            // Footer
            HStack {
                Button("common.back".localized) {
                    withAnimation {
                        // A save failure belongs to the attempt that produced
                        // it. Leaving the step retires it, so returning here
                        // does not accuse a save that never ran.
                        if case .error = wizardState.validationState {
                            wizardState.validationState = .idle
                        }
                        // Confirm is reachable two ways now: from
                        // SelectOrgStepSetup's Next after choosing an
                        // organization, or from EnterKeyStepSetup's "Skip —
                        // I only use Claude Code" button, which clears
                        // `selectedOrgId`/`testedOrganizations` and jumps
                        // straight here. Routing Back to `.selectOrg`
                        // unconditionally sent a skip-browser user to an
                        // empty organization list with no way forward
                        // (Tessie finding on PR #98) — the same
                        // `selectedOrgId != nil` check `reviewSetupState`
                        // already uses tells the two paths apart.
                        wizardState.currentStep =
                            wizardState.selectedOrgId != nil
                                ? .selectOrg
                                : .enterKey
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isSaving)

                Spacer()

                Button(action: { saveConfiguration() }) {
                    if isSaving {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 100)
                    } else {
                        Text("wizard.start_tracking".localized)
                            .frame(width: 100)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving || !canSave)
            }
            .padding(20)
        }
    }

    private func saveConfiguration(acceptSessionOnly: Bool = false) {
        guard isSaveAllowed(acceptSessionOnly: acceptSessionOnly),
              let target = wizardState.claudeSetupTarget,
              capturedTargetIsStillCurrent() else {
            wizardState.validationState = .error(
                "chrome_assisted.profile_changed".localized
            )
            return
        }
        let generation = wizardState.attempt.generation
        let key = wizardState.sessionKey
        let organizationID = wizardState.selectedOrgId
        // Captured up front so the profile records the same organization name
        // and personal/shared classification an auto-selected organization
        // would get.
        let selectedOrganization = wizardState.testedOrganizations.first(
            where: { $0.uuid == organizationID }
        )
        isSaving = true

        Task {
            do {
                let completedProfile = try await dependencies
                    .completeClaudeManualSetup(
                        sessionKey: key,
                        organizationID: organizationID,
                        autoStartSessionEnabled:
                            wizardState
                                .autoStartSessionEnabled,
                        terminalCredentialsJSON:
                            wizardState.shouldLinkTerminalSignIn
                                ? wizardState.detectedTerminalCredentials
                                : nil,
                        terminalAccountName:
                            wizardState.shouldLinkTerminalSignIn
                                ? wizardState.detectedTerminalAccountName
                                : nil,
                        acceptSessionOnlyStorage: acceptSessionOnly,
                        target: target
                    )
                LoggingService.shared.log(
                    "SetupWizard: Updated profile setup preferences"
                )

                await MainActor.run {
                    guard isSuccessfulCompletionCurrent(
                        generation: generation,
                        key: key,
                        target: target,
                        completedProfile: completedProfile
                    ) else {
                        isSaving = false
                        return
                    }
                    // Reset circuit breaker on successful credential save
                    ErrorRecovery.shared.recordSuccess(for: .api)

                    if let selectedOrganization {
                        dependencies.profileManager.updateOrganizationName(
                            selectedOrganization.name,
                            for: completedProfile.id
                        )
                        // Written even when indeterminate: a stale `true`
                        // left over from a previously bound organization
                        // would mislabel this one's figures.
                        dependencies.profileManager.updateOrganizationIsPersonal(
                            ClaudeOrganizationClassifier.isPersonal(
                                selectedOrganization
                            ),
                            for: completedProfile.id
                        )
                    }

                    isSaving = false
                    dismiss()
                }

            } catch {
                let appError = AppError.wrap(error)
                ErrorLogger.shared.log(appError, severity: .error)

                await MainActor.run {
                    guard isAttemptCurrent(
                        generation: generation,
                        key: key,
                        target: target
                    ) else {
                        isSaving = false
                        return
                    }
                    let retryTarget = SessionKeyAttemptPolicy
                        .retryTargetAfterFailedSetup(
                            capturedTarget: target,
                            claudeProfileIDs: dependencies.profileManager
                                .profiles.filter {
                                    $0.providerID == .claude
                                }.map(\.id)
                        )
                    if retryTarget != target {
                        wizardState.claudeSetupTarget = retryTarget
                        if case .createdProfile(let profileID) = retryTarget {
                            wizardState.targetProfileName = dependencies
                                .profileManager.profiles.first {
                                    $0.id == profileID
                                }?.name
                        }
                    }
                    wizardState.validationState = .error(
                        SetupErrorMessage.text(for: appError)
                    )
                    // Only a storage refusal is something the user can
                    // knowingly accept; every other failure needs fixing.
                    offerSessionOnly =
                        !acceptSessionOnly
                        && SetupErrorMessage.isCredentialStorageFailure(
                            appError
                        )
                    isSaving = false
                }
            }
        }
    }

    private var targetProfileName: String {
        wizardState.targetProfileName
            ?? "chrome_assisted.new_claude_profile".localized
    }

    private var canSave: Bool {
        isSaveAllowed(acceptSessionOnly: false)
    }

    private func isSaveAllowed(acceptSessionOnly: Bool) -> Bool {
        // Last line of defence: a console/API organization must never be
        // persisted, whatever the picker did or did not disable.
        guard ClaudeOrganizationClassifier.permitsSelection(
            of: wizardState.selectedOrgId,
            from: wizardState.testedOrganizations
        ) else { return false }
        return SessionKeyAttemptPolicy.permitsSave(
            validationSucceeded: wizardState.validationState.isSuccess,
            isSessionOnlyRetry: acceptSessionOnly && offerSessionOnly,
            selectedOrganizationID: wizardState.selectedOrgId,
            chromeProfileLabel: wizardState.launchedChromeProfileLabel,
            chromeContextConfirmed: wizardState.hasConfirmedChromeContext,
            targetMatches: capturedTargetIsStillCurrent()
        )
    }

    private func isSuccessfulCompletionCurrent(
        generation: UUID,
        key: String,
        target: ClaudeManualSetupTarget,
        completedProfile: Profile
    ) -> Bool {
        SessionKeyAttemptPolicy.acceptsSetupCompletion(
            generation: generation,
            currentGeneration: wizardState.attempt.generation,
            keyMatches: wizardState.sessionKey == key,
            capturedTarget: wizardState.claudeSetupTarget == target
                ? target : nil,
            completedProfileID: completedProfile.id,
            completedProfileIsClaude: completedProfile.providerID == .claude,
            activeClaudeProfileID:
                dependencies.profileManager.activeClaudeProfile?.id
        )
    }

    private func isAttemptCurrent(
        generation: UUID,
        key: String,
        target: ClaudeManualSetupTarget
    ) -> Bool {
        SessionKeyAttemptPolicy.acceptsCompletion(
            generation: generation,
            currentGeneration: wizardState.attempt.generation,
            keyMatches: wizardState.sessionKey == key,
            targetMatches: wizardState.claudeSetupTarget == target
        )
    }

    private func capturedTargetIsStillCurrent() -> Bool {
        SetupTargetFreshness.isCurrent(
            wizardState.claudeSetupTarget,
            profileManager: dependencies.profileManager
        )
    }
}

// MARK: - Visual Components

struct SetupStepHeader: View {
    let stepNumber: Int
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            Text("\(stepNumber)")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.accentColor))

            Text(title)
                .font(.system(size: 16, weight: .semibold))
        }
    }
}

struct SetupStepCircle: View {
    let number: Int
    let isCurrent: Bool
    let isCompleted: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(backgroundColor)
                .frame(width: 24, height: 24)

            if isCompleted {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
            } else {
                Text("\(number)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(textColor)
            }
        }
    }

    private var backgroundColor: Color {
        if isCompleted { return .green }
        if isCurrent { return .accentColor }
        return Color.gray.opacity(0.3)
    }

    private var textColor: Color {
        isCurrent ? .white : .secondary
    }
}

struct SetupStepLine: View {
    let isCompleted: Bool

    var body: some View {
        Rectangle()
            .fill(isCompleted ? Color.green : Color.gray.opacity(0.3))
            .frame(width: 40, height: 2)
    }
}

// MARK: - Supporting Views

struct InstructionRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            Text(text)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Renders a setup failure so it says what to do next, not just what broke.
///
/// The error code stays for support conversations, but it is no longer the
/// only actionable thing in the box.
enum SetupErrorMessage {
    /// True when the credential itself was fine and only storing it failed,
    /// which the user can accept for the session.
    static func isCredentialStorageFailure(_ error: AppError) -> Bool {
        error.code == .credentialStorageUnavailable
            || error.code == .credentialStorageFailed
    }

    static func text(for error: AppError) -> String {
        var text = error.message
        if let suggestion = error.recoverySuggestion,
           !suggestion.isEmpty,
           suggestion != error.message {
            text += "\n\n\(suggestion)"
        }
        return text + "\n\nError Code: \(error.code.rawValue)"
    }
}

struct WizardStatusBox: View {
    let message: String
    let type: StatusType

    enum StatusType {
        case success, error

        var color: Color {
            switch self {
            case .success: return .green
            case .error: return .red
            }
        }

        var icon: String {
            switch self {
            case .success: return "checkmark.circle.fill"
            case .error: return "xmark.circle.fill"
            }
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: type.icon)
                .font(.system(size: 12))
            Text(message)
                .font(.system(size: 12))
        }
        .foregroundColor(type.color)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(type.color.opacity(0.1))
        )
    }
}

/// Explains a gap in the organization picker: rows the picker deliberately did
/// not draw.
///
/// Quiet by design. A hidden console organization is normal rather than a
/// fault, so this is 11pt secondary text — the same weight as the descriptor
/// line inside each row — and not anything that reads as a warning.
///
/// Used by both organization pickers, so the two cannot drift apart.
struct APIOnlyHiddenFootnote: View {
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "eye.slash")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .accessibilityHidden(true)
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                // The longest translations sit close to the width of the
                // narrower picker; wrap rather than truncate if one ever
                // outgrows it.
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    SetupWizardView()
}
