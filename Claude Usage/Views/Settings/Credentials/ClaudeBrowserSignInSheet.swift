//
//  ClaudeBrowserSignInSheet.swift
//  Claude Usage - Claude.ai Personal Usage Tracking
//
//  Created by Claude Code on 2025-12-20.
//

import SwiftUI
import UsageCore

// MARK: - Wizard State Machine

enum WizardStep: Int, Comparable {
    case enterKey = 1
    case selectOrg = 2
    case confirm = 3

    static func < (lhs: WizardStep, rhs: WizardStep) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct WizardState {
    var currentStep: WizardStep = .enterKey
    var sessionKey: String = ""
    var validationState: ValidationState = .idle
    var testedOrganizations: [ClaudeAPIService.AccountInfo] = []
    var selectedOrgId: String? = nil
    var originalSessionKey: String? = nil
    var originalOrgId: String? = nil
    var showingAuthSheet: Bool = false
    var sessionKeyExpiryDate: Date? = nil
    /// The profile selected when this authentication attempt began. This is
    /// intentionally transient: it never enters profile storage or defaults.
    var targetProfileID: UUID? = nil
    var targetProfileName: String? = nil
    var attempt = SessionKeyAttempt()
    /// A Chrome label is user-confirmed context only, never an account claim.
    var launchedChromeProfileLabel: String? = nil
    var hasConfirmedChromeContext = false
}

enum PersonalUsageAttemptGate {
    static func targetIsAvailable(
        wizardState: WizardState,
        profiles: [Profile]
    ) -> Bool {
        guard let targetID = wizardState.targetProfileID else { return false }
        return profiles.contains(where: {
            $0.id == targetID && $0.providerID == .claude
        })
    }

    static func acceptsCompletion(
        wizardState: WizardState,
        targetID: UUID,
        generation: UUID,
        key: String,
        profiles: [Profile]
    ) -> Bool {
        SessionKeyAttemptPolicy.acceptsCompletion(
            generation: generation,
            currentGeneration: wizardState.attempt.generation,
            keyMatches: wizardState.sessionKey == key,
            targetMatches: wizardState.targetProfileID == targetID
                && targetIsAvailable(
                    wizardState: wizardState,
                    profiles: profiles
                )
        )
    }
}

/// Reusable browser sign-in flow for one Claude profile.
struct ClaudeBrowserSignInSheet: View {
    @StateObject private var profileManager = ProfileManager.shared
    @State private var wizardState: WizardState
    let targetProfileID: UUID
    let onCompletion: () -> Void
    private let apiService = ClaudeAPIService()

    init(targetProfileID: UUID, onCompletion: @escaping () -> Void) {
        self.targetProfileID = targetProfileID
        self.onCompletion = onCompletion
        _wizardState = State(
            initialValue: WizardState(targetProfileID: targetProfileID)
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.section) {
                SettingsPageHeader(
                    title: "claude_account.browser_sheet.title".localized,
                    subtitle: "claude_account.browser_sheet.subtitle".localized
                )

                // Configuration Card Container
                VStack(alignment: .leading, spacing: 0) {
                    // Step Indicator Header
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
                        Text("personal.configuration_title".localized)
                            .font(DesignTokens.Typography.sectionTitle)
                            .foregroundColor(.secondary)

                        HStack(spacing: DesignTokens.Spacing.small) {
                            ForEach(1...3, id: \.self) { step in
                                let stepEnum = WizardStep(rawValue: step)!
                                let isCurrent = wizardState.currentStep == stepEnum
                                let isCompleted = wizardState.currentStep > stepEnum

                                HStack(spacing: DesignTokens.Spacing.extraSmall) {
                                    ZStack {
                                        Circle()
                                            .fill(isCompleted ? Color.green : (isCurrent ? Color.accentColor : Color.secondary.opacity(0.2)))
                                            .frame(width: 20, height: 20)

                                        if isCompleted {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 10, weight: .semibold))
                                                .foregroundColor(.white)
                                        } else {
                                            Text("\(step)")
                                                .font(.system(size: 11, weight: .medium))
                                                .foregroundColor(isCurrent ? .white : .secondary)
                                        }
                                    }

                                    if isCurrent {
                                        Text(stepTitle(for: step))
                                            .font(DesignTokens.Typography.body)
                                            .fontWeight(.medium)
                                            .foregroundColor(.primary)
                                            // The connector rectangles below
                                            // are greedy, so without this the
                                            // step title loses the width
                                            // contest and wraps to two lines,
                                            // costing the step below it 10pt of
                                            // room. Longer titles now shorten
                                            // the connectors instead.
                                            .fixedSize(
                                                horizontal: true,
                                                vertical: false
                                            )
                                    }
                                }

                                if step < 3 {
                                    Rectangle()
                                        .fill(isCompleted ? Color.green.opacity(0.3) : Color.secondary.opacity(0.2))
                                        .frame(height: 1)
                                }
                            }
                        }
                    }
                    .padding(DesignTokens.Spacing.cardPadding)
                    .padding(.bottom, DesignTokens.Spacing.extraSmall)

                    Divider()

                    // Step Content
                    Group {
                        switch wizardState.currentStep {
                        case .enterKey:
                            EnterKeyStep(wizardState: $wizardState, apiService: apiService)
                        case .selectOrg:
                            SelectOrgStep(wizardState: $wizardState)
                        case .confirm:
                            ConfirmStep(
                                wizardState: $wizardState,
                                apiService: apiService,
                                onSave: onCompletion
                            )
                        }
                    }
                    .padding(DesignTokens.Spacing.cardPadding)
                    .animation(.easeInOut(duration: 0.25), value: wizardState.currentStep)
                }
                .background(DesignTokens.Colors.cardBackground)
                .cornerRadius(DesignTokens.Radius.card)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.card)
                        .strokeBorder(DesignTokens.Colors.cardBorder, lineWidth: 1)
                )

                Spacer()
            }
            .padding()
        }
        .onAppear {
            loadExistingConfiguration()
        }
    }

    private func stepTitle(for step: Int) -> String {
        switch step {
        case 1: return "setup.step.enter_session_key".localized
        case 2: return "wizard.select_organization".localized
        case 3: return "wizard.review_config".localized
        default: return ""
        }
    }

    private func loadExistingConfiguration() {
        guard let profile = profileManager.profiles.first(where: {
            $0.id == targetProfileID && $0.providerID == .claude
        }) else { return }
        wizardState.targetProfileID = profile.id
        wizardState.targetProfileName = profile.name

        // Load existing credentials for comparison
        if let creds = try? ProfileStore.shared.loadProfileCredentials(profile.id) {
            wizardState.originalOrgId = creds.organizationId
            wizardState.originalSessionKey = creds.claudeSessionKey
        }
    }

}

// MARK: - Step 1: Enter Key

struct EnterKeyStep: View {
    @Binding var wizardState: WizardState
    let apiService: ClaudeAPIService

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ChromeAssistedSessionKeyEntry(
                sessionKey: $wizardState.sessionKey,
                validationState: wizardState.validationState,
                onSessionKeyChanged: retireAttemptForKeyEdit,
                onValidationRequested: testConnection,
                onLaunchStarted: beginChromeLaunch,
                isLaunchCurrent: { generation in
                    wizardState.attempt.matches(generation)
                },
                onChromeProfileLaunched: { label in
                    wizardState.launchedChromeProfileLabel = label
                    wizardState.hasConfirmedChromeContext = false
                },
                onSessionKeyReadFromChrome: adoptSessionKeyReadFromChrome
            )

            // Fallback: embedded sign-in remains available for users who
            // prefer it. Browser-assisted setup above reads the claude.ai
            // session key only through the explicit Read from Chrome button.
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
                        replaceSessionKey(result.sessionKey)
                        wizardState.sessionKeyExpiryDate = result.expiryDate
                        testConnection()
                    },
                    onCancel: {
                        wizardState.showingAuthSheet = false
                        retireAttempt(clearKey: false)
                    }
                )
            }

            // Validation status
            if case .success(let message) = wizardState.validationState {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 14))
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.08))
                .cornerRadius(6)
            } else if case .error(let message) = wizardState.validationState {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .font(.system(size: 14))
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.08))
                .cornerRadius(6)
            }
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
            clearChromeContext: false
        )
        guard let target = capturedTargetIfStillCurrent() else { return }
        let generation = wizardState.attempt.generation
        let key = wizardState.sessionKey
        wizardState.validationState = .validating

        Task {
            do {
                // READ-ONLY TEST - does NOT save to Keychain
                let organizations = try await apiService.testSessionKey(key)

                await MainActor.run {
                    guard PersonalUsageAttemptGate.acceptsCompletion(
                        wizardState: wizardState,
                        targetID: target.id,
                        generation: generation,
                        key: key,
                        profiles: ProfileManager.shared.profiles
                    ) else { return }
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
                    guard PersonalUsageAttemptGate.acceptsCompletion(
                        wizardState: wizardState,
                        targetID: target.id,
                        generation: generation,
                        key: key,
                        profiles: ProfileManager.shared.profiles
                    ) else { return }
                    let errorMessage = SetupErrorMessage.text(for: appError)
                    wizardState.validationState = .error(errorMessage)
                }
            }
        }
    }

    private func beginChromeLaunch() -> UUID {
        guard let target = capturedTargetIfAvailable() else {
            return wizardState.attempt.generation
        }
        retireAttempt(clearKey: false)
        wizardState.targetProfileID = target.id
        wizardState.targetProfileName = target.name
        return wizardState.attempt.generation
    }

    private func beginEmbeddedAuth() {
        _ = beginChromeLaunch()
        wizardState.showingAuthSheet = true
    }

    private func replaceSessionKey(_ key: String) {
        wizardState.sessionKey = key
        retireAttempt(clearKey: false)
    }

    /// Same contract as the setup wizard's adoption path: keep the launched
    /// Chrome profile label, so the account-confirmation checkbox keeps
    /// gating Save, but re-arm the confirmation itself because the key just
    /// changed.
    private func adoptSessionKeyReadFromChrome(_ key: String) {
        wizardState.sessionKey = key
        retireAttempt(
            clearKey: false,
            clearChromeContext: false,
            rearmChromeConfirmation: true
        )
        testConnection()
    }

    private func retireAttemptForKeyEdit() {
        retireAttempt(
            clearKey: false,
            clearChromeContext: false
        )
    }

    private func retireAttempt(
        clearKey: Bool,
        clearChromeContext: Bool = true,
        rearmChromeConfirmation: Bool = false
    ) {
        wizardState.attempt.invalidate()
        wizardState.validationState = .idle
        wizardState.testedOrganizations = []
        wizardState.selectedOrgId = nil
        if clearChromeContext {
            wizardState.launchedChromeProfileLabel = nil
            wizardState.hasConfirmedChromeContext = false
        } else if rearmChromeConfirmation {
            wizardState.hasConfirmedChromeContext = false
        }
        if clearKey { wizardState.sessionKey = "" }
    }

    private func capturedTargetIfStillCurrent() -> Profile? {
        capturedTargetIfAvailable()
    }

    private func capturedTargetIfAvailable() -> Profile? {
        guard let targetID = wizardState.targetProfileID,
              let target = ProfileManager.shared.profiles.first(where: {
                  $0.id == targetID && $0.providerID == .claude
              }) else {
            wizardState.validationState = .error(
                "chrome_assisted.profile_changed".localized
            )
            return nil
        }
        return target
    }
}

// MARK: - Step 2: Select Organization

struct SelectOrgStep: View {
    @Binding var wizardState: WizardState

    /// Only the organizations that can carry Claude usage, in server order.
    /// Console/API-only ones are left out and counted, not dimmed. Shared with
    /// the setup wizard's picker so the two cannot drift.
    private var organizations: [ClaudeAPIService.AccountInfo] {
        ClaudeOrganizationClassifier.pickerRows(wizardState.testedOrganizations)
    }

    /// The sentence accounting for the rows above that were left out, or `nil`
    /// when none were.
    private var hiddenOrganizationsNotice: String? {
        ClaudeOrganizationClassifier.hiddenOrganizationsNotice(
            for: wizardState.testedOrganizations
        )
    }

    private var hasSelectableOrganization: Bool {
        ClaudeOrganizationClassifier.hasSelectableOrganization(
            wizardState.testedOrganizations
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("wizard.select_organization".localized)
                    .font(.system(size: 13, weight: .medium))
                Text("wizard.choose_organization".localized)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            // Stated before the list, not after it: the note explains a gap in
            // what follows, and in the wizard's taller list an explanation
            // placed underneath falls below the fold exactly when there are
            // enough organizations to need it.
            if let hiddenOrganizationsNotice {
                HiddenOrganizationsFootnote(message: hiddenOrganizationsNotice)
            }

            // Only organizations that can carry Claude usage. Console/API-only
            // ones are left out and accounted for by the note above.
            VStack(alignment: .leading, spacing: 8) {
                ForEach(organizations, id: \.uuid) { org in
                    let isSelected = wizardState.selectedOrgId == org.uuid
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            wizardState.selectedOrgId = org.uuid
                        }
                    }) {
                        HStack(spacing: 10) {
                            // Radio button
                            ZStack {
                                Circle()
                                    .strokeBorder(
                                        isSelected
                                            ? Color.accentColor
                                            : Color.secondary.opacity(0.3),
                                        lineWidth: 1.5
                                    )
                                    .frame(width: 16, height: 16)

                                if isSelected {
                                    Circle()
                                        .fill(Color.accentColor)
                                        .frame(width: 8, height: 8)
                                }
                            }

                            VStack(alignment: .leading, spacing: 3) {
                                Text(org.name)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.primary)
                                Text(ClaudeOrganizationClassifier.descriptor(org))
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                // Several organizations can share both a name
                                // and a kind; the id prefix is the last thing
                                // that separates them.
                                Text(String(org.uuid.prefix(8)))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            if isSelected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .padding(10)
                        .background(
                            isSelected
                                ? Color.accentColor.opacity(0.06)
                                : Color.primary.opacity(0.04)
                        )
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(
                                    isSelected
                                        ? Color.accentColor.opacity(0.3)
                                        : Color.primary.opacity(0.08),
                                    lineWidth: 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("wizard.org_row.\(org.uuid)")
                }
            }

            // An account can hold nothing but console organizations. Say so,
            // rather than leaving every row dimmed and Next dead with no
            // explanation.
            if !hasSelectableOrganization {
                WizardStatusBox(
                    message: "wizard.no_claude_organizations".localized,
                    type: .error
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Navigation buttons
            HStack(spacing: 10) {
                Button(action: {
                    withAnimation {
                        wizardState.currentStep = .enterKey
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11))
                        Text("common.back".localized)
                            .font(.system(size: 12))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Spacer()

                Button(action: {
                    withAnimation {
                        wizardState.currentStep = .confirm
                    }
                }) {
                    HStack(spacing: 6) {
                        Text("common.next".localized)
                            .font(.system(size: 12))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11))
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(wizardState.selectedOrgId == nil)
            }
        }
    }
}

// MARK: - Step 3: Confirm & Save

struct ConfirmStep: View {
    @Binding var wizardState: WizardState
    let apiService: ClaudeAPIService
    let onSave: () -> Void
    @State private var isSaving = false
    /// Set only when the save failed because secure storage refused the
    /// credential, which is the one case the user can knowingly accept.
    @State private var offerSessionOnly = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("wizard.review_config".localized)
                    .font(.system(size: 13, weight: .medium))
                Text("wizard.confirm_settings".localized)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            // Balanced summary card
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "key")
                        .font(.system(size: 14))
                        .foregroundColor(.accentColor)
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("wizard.session_key".localized)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                        Text("personal.session_key_validated".localized)
                            .font(.system(size: 12))
                            .foregroundColor(.primary)
                    }
                }

                if let selectedOrg = wizardState.testedOrganizations.first(where: { $0.uuid == wizardState.selectedOrgId }) {
                    Divider()

                    HStack(spacing: 10) {
                        Image(systemName: "building.2")
                            .font(.system(size: 14))
                            .foregroundColor(.accentColor)
                            .frame(width: 20)

                        VStack(alignment: .leading, spacing: 3) {
                            Text("wizard.organization".localized)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                            Text(selectedOrg.name)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.primary)
                            Text(selectedOrg.uuid)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }

                if keyHasChanged() {
                    Divider()

                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 12))
                            .foregroundColor(.orange)
                        Text("wizard.key_will_update".localized)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }

                if let chromeLabel = wizardState.launchedChromeProfileLabel,
                   let targetName = wizardState.targetProfileName {
                    Divider()

                    Toggle(
                        isOn: $wizardState.hasConfirmedChromeContext
                    ) {
                        Text(
                            String(
                                format: "chrome_assisted.confirm_context".localized,
                                chromeLabel,
                                targetName
                            )
                        )
                        .font(.system(size: 11))
                    }
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("chrome.context_confirmation")
                }
            }
            .padding(12)
            .background(DesignTokens.Colors.cardBackground)
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(DesignTokens.Colors.cardBorder, lineWidth: 1)
            )

            // Saving is the only thing that can fail on this step, and the
            // failure had nowhere to surface: the button simply stopped
            // spinning and the credential was never stored.
            if case .error(let message) = wizardState.validationState {
                WizardStatusBox(message: message, type: .error)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if offerSessionOnly {
                    Button(action: { saveConfiguration(acceptSessionOnly: true) }) {
                        Text("setup.use_session_only".localized)
                            .font(DesignTokens.Typography.body)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSaving)
                    .accessibilityIdentifier("setup.use_session_only")
                }
            }

            // Navigation buttons
            HStack(spacing: 10) {
                Button(action: {
                    withAnimation {
                        // A save failure belongs to the attempt that produced
                        // it. Leaving the step retires it, so returning here
                        // does not accuse a save that never ran.
                        if case .error = wizardState.validationState {
                            wizardState.validationState = .idle
                        }
                        wizardState.currentStep = .selectOrg
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11))
                        Text("common.back".localized)
                            .font(.system(size: 12))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(isSaving)

                Spacer()

                Button(action: { saveConfiguration() }) {
                    HStack(spacing: 6) {
                        if isSaving {
                            ProgressView()
                                .scaleEffect(0.8)
                                .frame(width: 12, height: 12)
                        } else {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 12))
                        }
                        Text(isSaving ? "wizard.saving".localized : "wizard.save_configuration".localized)
                            .font(.system(size: 12))
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(isSaving || !canSave)
            }
        }
    }

    private func keyHasChanged() -> Bool {
        guard let originalKey = wizardState.originalSessionKey else { return true }
        return originalKey != wizardState.sessionKey
    }

    private func saveConfiguration(acceptSessionOnly: Bool = false) {
        guard isSaveAllowed(acceptSessionOnly: acceptSessionOnly),
              let profileId = wizardState.targetProfileID,
              let target = ProfileManager.shared.profiles.first(where: {
                  $0.id == profileId && $0.providerID == .claude
              }) else {
            wizardState.validationState = .error(
                "chrome_assisted.profile_changed".localized
            )
            return
        }
        let generation = wizardState.attempt.generation
        let key = wizardState.sessionKey
        let organizationID = wizardState.selectedOrgId
        // Captured before the wizard state is reset below, so the profile
        // records the same organization name and personal/shared
        // classification that an auto-selected organization would get.
        let selectedOrganization = wizardState.testedOrganizations.first(
            where: { $0.uuid == organizationID }
        )

        isSaving = true

        Task {
            do {
                // Re-check on the actor immediately before the synchronous
                // Keychain mutation; a queued profile switch must not write
                // this attempt into a different active profile.
                guard await MainActor.run(body: {
                    PersonalUsageAttemptGate.acceptsCompletion(
                        wizardState: wizardState,
                        targetID: target.id,
                        generation: generation,
                        key: key,
                        profiles: ProfileManager.shared.profiles
                    )
                }) else {
                    await MainActor.run { isSaving = false }
                    return
                }
                // Save to profile-specific Keychain
                var creds = try ProfileManager.shared.loadCredentials(for: target.id)
                creds.claudeSessionKey = key
                creds.organizationId = organizationID
                try ProfileManager.shared.saveCredentials(
                    for: target.id,
                    credentials: creds,
                    acceptingSessionOnly: acceptSessionOnly,
                    browserCredentialSave: true
                )

                await MainActor.run {
                    guard wizardState.attempt.matches(generation),
                          wizardState.targetProfileID == target.id,
                          wizardState.sessionKey == key
                    else {
                        isSaving = false
                        return
                    }
                    // Reset circuit breaker on successful credential save
                    ErrorRecovery.shared.recordSuccess(for: .api)

                    if let selectedOrganization {
                        ProfileManager.shared.updateOrganizationName(
                            selectedOrganization.name,
                            for: target.id
                        )
                        // Written even when indeterminate: a stale `true`
                        // left over from a previously bound organization
                        // would mislabel this one's figures.
                        ProfileManager.shared.updateOrganizationIsPersonal(
                            ClaudeOrganizationClassifier.isPersonal(
                                selectedOrganization
                            ),
                            for: target.id
                        )
                    }

                    // Reload credentials display
                    onSave()

                    // Reset wizard to start
                    withAnimation {
                        wizardState = WizardState()
                    }
                    isSaving = false
                }

            } catch {
                let appError = AppError.wrap(error)
                ErrorLogger.shared.log(appError, severity: .error)

                await MainActor.run {
                    guard wizardState.attempt.matches(generation),
                          wizardState.targetProfileID == target.id,
                          wizardState.sessionKey == key else {
                        isSaving = false
                        return
                    }
                    wizardState.validationState = .error(
                        SetupErrorMessage.text(for: appError)
                    )
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
            targetMatches: PersonalUsageAttemptGate.targetIsAvailable(
                wizardState: wizardState,
                profiles: ProfileManager.shared.profiles
            )
        )
    }
}

// MARK: - Visual Components (kept minimal)

// MARK: - Previews

#Preview {
    ClaudeBrowserSignInSheet(
        targetProfileID: UUID(),
        onCompletion: {}
    )
        .frame(width: 520, height: 600)
}
