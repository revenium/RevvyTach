import SwiftUI

/// A lightweight invalidation token for one manual-key validation/save flow.
/// The token intentionally carries no credential or browser metadata.
nonisolated struct SessionKeyAttempt: Equatable, Sendable {
    private(set) var generation = UUID()

    mutating func invalidate() {
        generation = UUID()
    }

    func matches(_ candidate: UUID) -> Bool {
        generation == candidate
    }
}

nonisolated struct ChromeLaunchAttempt: Equatable, Sendable {
    let nonce: UUID
    let parentGeneration: UUID
}

/// Pure transition rules shared by the two manual Claude setup flows.
nonisolated enum SessionKeyAttemptPolicy {
    static func hasSelectableOrganization(_ count: Int) -> Bool {
        count > 0
    }

    static func acceptsCompletion(
        generation: UUID,
        currentGeneration: UUID,
        keyMatches: Bool,
        targetMatches: Bool = true
    ) -> Bool {
        generation == currentGeneration && keyMatches && targetMatches
    }

    static func acceptsChromeLaunch(
        _ launch: ChromeLaunchAttempt,
        currentNonce: UUID,
        currentGeneration: UUID
    ) -> Bool {
        acceptsChromeLaunch(
            launch,
            currentNonce: currentNonce,
            parentGenerationIsCurrent:
                launch.parentGeneration == currentGeneration
        )
    }

    static func acceptsChromeLaunch(
        _ launch: ChromeLaunchAttempt,
        currentNonce: UUID,
        parentGenerationIsCurrent: Bool
    ) -> Bool {
        launch.nonce == currentNonce && parentGenerationIsCurrent
    }

    static func acceptsSetupCompletion(
        generation: UUID,
        currentGeneration: UUID,
        keyMatches: Bool,
        capturedTarget: ClaudeManualSetupTarget?,
        completedProfileID: UUID,
        completedProfileIsClaude: Bool,
        activeClaudeProfileID: UUID?
    ) -> Bool {
        guard generation == currentGeneration,
              keyMatches,
              completedProfileIsClaude,
              capturedTarget != .compatibilityCurrent,
              activeClaudeProfileID == completedProfileID else {
            return false
        }
        switch capturedTarget {
        case .existing(let profileID), .createdProfile(let profileID):
            return profileID == completedProfileID
        case .newProfile:
            return true
        case .compatibilityCurrent, .none:
            return false
        }
    }

    static func retryTargetAfterFailedSetup(
        capturedTarget: ClaudeManualSetupTarget,
        claudeProfileIDs: [UUID]
    ) -> ClaudeManualSetupTarget {
        guard capturedTarget == .newProfile,
              claudeProfileIDs.count == 1,
              let createdProfileID = claudeProfileIDs.first else {
            return capturedTarget
        }
        return .createdProfile(createdProfileID)
    }

    static func permitsSave(
        validationSucceeded: Bool,
        isSessionOnlyRetry: Bool,
        selectedOrganizationID: String?,
        chromeProfileLabel: String?,
        chromeContextConfirmed: Bool,
        targetMatches: Bool = true
    ) -> Bool {
        (validationSucceeded || isSessionOnlyRetry)
            && selectedOrganizationID != nil
            && targetMatches
            && (chromeProfileLabel == nil || chromeContextConfirmed)
    }
}

/// The one Chrome profile the user launched in this attempt.
///
/// Label and directory name travel together on purpose. They were separate
/// values once, and a failed second launch left the directory name pointing
/// at the profile from the attempt before it — so the read would have been
/// scoped to a profile the user had not just opened, which is the promise the
/// consent notice makes.
nonisolated struct LaunchedChromeProfile: Equatable, Sendable {
    let label: String
    let directoryName: String
}

nonisolated enum ChromeReadAdoptionPolicy {
    /// A finished read may only be adopted for the profile it was scoped to,
    /// and only if the key field has not moved underneath it.
    ///
    /// The read runs off the main actor while the wizard stays live, so two
    /// things can change before it returns. The user can launch a second
    /// profile: adopting anyway would hand profile A's session key to a screen
    /// — and to the save gate's confirmation — that names profile B, a
    /// wrong-but-plausible credential and a silent breach of the consent
    /// notice's promise that only the profile just opened is used. Or the user
    /// can type a key by hand while waiting: adopting then would overwrite,
    /// without a word, the key they just entered — and the profile check
    /// cannot see it, because the profile genuinely did not change. The field
    /// is also disabled during a read, but that only stops the edit from
    /// starting; this comparison is what decides whether a finished read is
    /// allowed to land. A nil current profile means a launch is in flight or
    /// the last one failed, so nothing is addressable.
    ///
    /// The keys are compared by value and nothing else: neither is rendered,
    /// logged, hashed, or interpolated anywhere.
    static func permitsAdoption(
        readProfile: LaunchedChromeProfile,
        launchedProfile: LaunchedChromeProfile?,
        sessionKeyAtReadStart: String,
        sessionKeyNow: String
    ) -> Bool {
        guard let launchedProfile, launchedProfile == readProfile else {
            return false
        }
        return sessionKeyNow == sessionKeyAtReadStart
    }
}

nonisolated enum ChromeLaunchBookkeeping {
    /// The launched-profile state after one launch attempt. Every attempt
    /// clears the previous result first (the user must choose a profile
    /// again for each launch), so a failed attempt leaves nothing
    /// addressable — never the profile from the attempt before it.
    static func result(
        didLaunch: Bool,
        profile: ChromeProfile
    ) -> LaunchedChromeProfile? {
        guard didLaunch else { return nil }
        return LaunchedChromeProfile(
            label: profile.label,
            directoryName: profile.directoryName
        )
    }
}

nonisolated enum ChromeReadAvailabilityPolicy {
    /// Default-off contract: nothing is readable until a specific profile has
    /// been launched successfully in this attempt.
    static func permitsRead(
        launchedProfile: LaunchedChromeProfile?,
        isLaunching: Bool,
        isReading: Bool,
        isValidating: Bool
    ) -> Bool {
        launchedProfile != nil && !isLaunching && !isReading && !isValidating
    }
}

/// The recommended browser-assisted path for Claude session-key setup.
///
/// Profile discovery reads only Chrome profile labels/directories via
/// `ChromeProfileDiscoverer`, and launching a profile reads nothing else.
/// Reading the claude.ai session key is a separate, default-off action: the
/// **Read from Chrome** button, which is disabled until a specific profile has
/// been launched in this attempt, shows a consent sheet, and only then runs
/// `ChromeCookieSessionKeyReader` off the main actor. Login databases, saved
/// passwords and browser history are never read.
struct ChromeAssistedSessionKeyEntry: View {
    @Binding var sessionKey: String
    let validationState: ValidationState
    let onSessionKeyChanged: () -> Void
    let onValidationRequested: () -> Void
    /// Invalidates the parent attempt and returns its new generation.
    let onLaunchStarted: () -> UUID
    let isLaunchCurrent: (UUID) -> Bool
    let onChromeProfileLaunched: (String) -> Void
    /// Adopts a key read from Chrome. Deliberately not `onSessionKeyChanged`:
    /// the adoption path has to keep the captured setup target and the
    /// Chrome-context confirmation gate, which a plain paste does not.
    let onSessionKeyReadFromChrome: (String) -> Void

    @State private var profiles: [ChromeProfile] = []
    @State private var selectedDirectoryName: String?
    @State private var isLaunching = false
    @State private var launchError: String?
    @State private var launchedProfile: LaunchedChromeProfile?
    @State private var launchNonce = UUID()
    @State private var isReadingFromChrome = false
    @State private var readError: String?
    @State private var showingChromeReadConsent = false
    /// Captured when the consent sheet opens, so neither the sheet's copy nor
    /// the background read can drift onto a different profile mid-flight.
    @State private var pendingRead: LaunchedChromeProfile?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    "chrome_assisted.recommended".localized,
                    systemImage: "sparkles"
                )
                .font(.system(size: 13, weight: .semibold))

                Text("chrome_assisted.description".localized)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                if profiles.isEmpty {
                    Text("chrome_assisted.no_profiles".localized)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                } else {
                    Picker(
                        "chrome_assisted.profile_picker".localized,
                        selection: $selectedDirectoryName
                    ) {
                        Text("chrome_assisted.choose_profile".localized)
                            .tag(String?.none)
                        ForEach(profiles, id: \.directoryName) { profile in
                            Text(profile.label).tag(Optional(profile.directoryName))
                        }
                    }
                    .accessibilityIdentifier("chrome.profile_picker")
                    // A read in flight is scoped to the launched profile, so
                    // choosing another one mid-read only invites a result the
                    // adoption policy will discard.
                    .disabled(isReadingFromChrome)
                }

                Button(action: launchSelectedProfile) {
                    HStack(spacing: 6) {
                        if isLaunching {
                            ProgressView()
                                .scaleEffect(0.8)
                                .frame(width: 12, height: 12)
                        } else {
                            Image(systemName: "globe")
                                .font(.system(size: 12))
                        }
                        Text("chrome_assisted.launch".localized)
                            .font(.system(size: 12))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    selectedDirectoryName == nil
                        || isLaunching
                        || isReadingFromChrome
                        || validationState == .validating
                )
                .accessibilityIdentifier("chrome.launch")

                if let launchError {
                    Text(launchError)
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                }

                if let launchedProfile {
                    Text(
                        String(
                            format: "chrome_assisted.verify_account".localized,
                            launchedProfile.label
                        )
                    )
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                }

                // Default-off: this cannot be pressed until the user has
                // launched a specific profile in this attempt, and pressing
                // it only opens the consent notice.
                Button(action: beginChromeRead) {
                    HStack(spacing: 6) {
                        if isReadingFromChrome {
                            ProgressView()
                                .scaleEffect(0.8)
                                .frame(width: 12, height: 12)
                        } else {
                            Image(systemName: "key")
                                .font(.system(size: 12))
                        }
                        Text(
                            isReadingFromChrome
                                ? "chrome_assisted.reading".localized
                                : "chrome_assisted.read_button".localized
                        )
                        .font(.system(size: 12))
                    }
                }
                .buttonStyle(.bordered)
                .disabled(
                    !ChromeReadAvailabilityPolicy.permitsRead(
                        launchedProfile: launchedProfile,
                        isLaunching: isLaunching,
                        isReading: isReadingFromChrome,
                        isValidating: validationState == .validating
                    )
                )
                .accessibilityIdentifier("chrome.read_from_chrome")

                if let readError {
                    Text(readError)
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                }

                Text("chrome_assisted.no_extraction".localized)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .background(Color.accentColor.opacity(0.07))
            .cornerRadius(8)
            .sheet(isPresented: $showingChromeReadConsent) {
                if let pendingRead {
                    ChromeReadConsentSheet(
                        profileLabel: pendingRead.label,
                        onContinue: continueChromeRead,
                        onCancel: cancelChromeRead
                    )
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("personal.label_session_key".localized)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(
                        Array([
                            "setup.instruction.step1",
                            "setup.instruction.step2",
                            "setup.instruction.step3",
                            "setup.instruction.step4"
                        ].enumerated()),
                        id: \.offset
                    ) { index, localizationKey in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(index + 1).")
                            Text(localizationKey.localized)
                        }
                    }
                }
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .accessibilityIdentifier("session_key.instructions")

                SecureField(
                    "personal.placeholder_session_key".localized,
                    text: Binding(
                        get: { sessionKey },
                        set: { newValue in
                            guard newValue != sessionKey else { return }
                            sessionKey = newValue
                            onSessionKeyChanged()
                        }
                    )
                )
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .padding(10)
                .background(DesignTokens.Colors.inputBackground)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            DesignTokens.Colors.cardBorder,
                            lineWidth: 1
                        )
                )
                .accessibilityIdentifier("session_key.secure_field")
                // A key typed while a read is in flight would be discarded by
                // the adoption policy the moment the read lands, so let the
                // user see the field is busy rather than type into it and
                // watch the work go nowhere. The binding is untouched: when no
                // read is running this is `false`, and a normal edit still
                // reports through `onSessionKeyChanged()` exactly as before.
                .disabled(isReadingFromChrome)

                HStack {
                    Spacer()
                    Button(action: onValidationRequested) {
                        HStack(spacing: 6) {
                            if validationState == .validating {
                                ProgressView()
                                    .scaleEffect(0.8)
                                    .frame(width: 12, height: 12)
                            } else {
                                Image(systemName: "checkmark.circle")
                                    .font(.system(size: 12))
                            }
                            Text(
                                validationState == .validating
                                    ? "wizard.testing".localized
                                    : "wizard.test_connection".localized
                            )
                            .font(.system(size: 12))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(sessionKey.isEmpty || validationState == .validating)
                    .accessibilityIdentifier("session_key.validate")
                }
            }
        }
        .task { refreshProfiles() }
    }

    private func refreshProfiles() {
        profiles = ChromeProfileDiscoverer().discoverProfiles()
        selectedDirectoryName = nil
    }

    // MARK: - Read from Chrome

    private func beginChromeRead() {
        readError = nil
        guard let launchedProfile else { return }
        pendingRead = launchedProfile
        showingChromeReadConsent = true
    }

    private func cancelChromeRead() {
        showingChromeReadConsent = false
        pendingRead = nil
    }

    private func continueChromeRead() {
        showingChromeReadConsent = false
        guard let pending = pendingRead else { return }
        readError = nil
        isReadingFromChrome = true
        let scopedProfile = pending
        // Captured alongside the profile, and for the same reason: a result
        // that arrives after the field has moved is not addressable either.
        let scopedSessionKey = sessionKey

        // The read blocks on the macOS password prompt, so it must not run on
        // the main thread — a frozen wizard at the moment the user is asked
        // for their login password is the worst possible look. The work is
        // pushed to a global queue rather than a detached task so this view's
        // non-Sendable closures are never captured in a `@Sendable` closure.
        Task { @MainActor in
            let outcome: Result<String, Error> = await withCheckedContinuation {
                continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(
                        returning: Result {
                            try ChromeCookieSessionKeyReader().readSessionKey(
                                profileDirectoryName:
                                    scopedProfile.directoryName
                            )
                        }
                    )
                }
            }
            finishChromeRead(
                outcome,
                scopedTo: scopedProfile,
                sessionKeyAtReadStart: scopedSessionKey
            )
        }
    }

    private func finishChromeRead(
        _ outcome: Result<String, Error>,
        scopedTo scopedProfile: LaunchedChromeProfile,
        sessionKeyAtReadStart: String
    ) {
        isReadingFromChrome = false
        pendingRead = nil
        // The user launched a different profile, or entered a key themselves,
        // while this read was in flight — so the result belongs to a profile
        // they have moved on from, or would overwrite a key they just typed.
        // Discard it without a message: nothing broke, and a failure notice
        // here would describe a read the user is no longer waiting for.
        guard ChromeReadAdoptionPolicy.permitsAdoption(
            readProfile: scopedProfile,
            launchedProfile: launchedProfile,
            sessionKeyAtReadStart: sessionKeyAtReadStart,
            sessionKeyNow: sessionKey
        ) else {
            return
        }
        switch outcome {
        case .success(let key):
            readError = nil
            onSessionKeyReadFromChrome(key)
        case .failure(let error):
            readError = Self.message(for: error)
        }
    }

    /// Maps a failure to a fixed localized sentence. Nothing here
    /// interpolates a value, a path, or an `OSStatus`, so no decrypted or
    /// identifying bytes can reach the screen.
    static func message(for error: Error) -> String {
        switch error as? ChromeCookieReadError {
        case .keychainAccessDenied:
            return "chrome_assisted.read_failed_denied".localized
        case .databaseLocked:
            return "chrome_assisted.read_failed_locked".localized
        case .sessionCookieMissing, .keychainItemMissing:
            return "chrome_assisted.read_failed_missing".localized
        case .unknownEncryptionVersion:
            return "chrome_assisted.read_failed_version".localized
        default:
            return "chrome_assisted.read_failed_generic".localized
        }
    }

    private func launchSelectedProfile() {
        guard let directoryName = selectedDirectoryName,
              let profile = profiles.first(where: {
                  $0.directoryName == directoryName
              }) else {
            return
        }

        // A user must choose a profile again for every browser launch.
        selectedDirectoryName = nil
        launchError = nil
        readError = nil
        launchedProfile = nil
        let parentGeneration = onLaunchStarted()
        let attempt = ChromeLaunchAttempt(
            nonce: UUID(),
            parentGeneration: parentGeneration
        )
        launchNonce = attempt.nonce
        isLaunching = true

        Task {
            let didLaunch = await ChromeProfileLauncher(
                discoverer: ChromeProfileDiscoverer()
            ).launch(profile: profile)
            await MainActor.run {
                guard SessionKeyAttemptPolicy.acceptsChromeLaunch(
                    attempt,
                    currentNonce: launchNonce,
                    parentGenerationIsCurrent:
                        isLaunchCurrent(attempt.parentGeneration)
                ) else {
                    if attempt.nonce == launchNonce { isLaunching = false }
                    return
                }
                isLaunching = false
                // Assigned unconditionally, so a failed attempt clears the
                // profile the previous attempt launched instead of leaving it
                // addressable.
                launchedProfile = ChromeLaunchBookkeeping.result(
                    didLaunch: didLaunch,
                    profile: profile
                )
                guard let launched = launchedProfile else {
                    launchError = "chrome_assisted.launch_failed".localized
                    return
                }
                onChromeProfileLaunched(launched.label)
            }
        }
    }
}
