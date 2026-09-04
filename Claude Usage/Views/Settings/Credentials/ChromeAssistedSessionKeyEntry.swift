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

    /// Whether a finished launch may be applied. The reason a launch is
    /// *rejected* decides whether the user hears about it, so the view asks
    /// `ChromeLaunchOutcomePolicy` for the full disposition; this stays the
    /// one-bit question, answered by the same rules.
    static func acceptsChromeLaunch(
        _ launch: ChromeLaunchAttempt,
        currentNonce: UUID,
        parentGenerationIsCurrent: Bool
    ) -> Bool {
        ChromeLaunchOutcomePolicy.disposition(
            launch,
            currentNonce: currentNonce,
            parentGenerationIsCurrent: parentGenerationIsCurrent
        ) == .adopt
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
///
/// `Identifiable` so the consent notice can be presented from this value
/// itself. It used to be presented from a separate boolean set in the same
/// frame as the value, and SwiftUI built the sheet's content from the state
/// snapshot the presentation began with — so the profile was still `nil`, the
/// `if let` around the content failed, and macOS presented an empty sheet: a
/// small blank square with no title, no body, no Cancel and no Continue, over
/// a dimmed window, with nothing left to press. The only way out was to force
/// quit the app. Presenting from the value keeps the content non-optional, so
/// the sheet can never render without its buttons.
nonisolated struct LaunchedChromeProfile: Equatable, Sendable, Identifiable {
    let label: String
    let directoryName: String

    /// Derived, never stored: a launch is identified by the profile it opened.
    /// A stored identifier would have to be excluded from `Equatable`, and
    /// that equality is what `ChromeReadAdoptionPolicy` uses to decide whether
    /// a finished read belongs to the profile still on screen.
    var id: String { "\(directoryName)\u{1F}\(label)" }
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
    /// clears the previous result before it starts and assigns this one
    /// unconditionally when it finishes, so a failed attempt leaves nothing
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

/// What to do with a browser launch that has just finished.
///
/// The completion used to collapse two unrelated situations into one silent
/// `return`, and the second one cost a user a whole attempt: Chrome opened,
/// the result was thrown away, **Read from Chrome** stayed grey, and nothing
/// on screen said why. A launch is only ever dropped for one of two reasons,
/// and they deserve opposite treatment.
nonisolated enum ChromeLaunchOutcomePolicy {
    enum Disposition: Equatable {
        /// This launch is still the current one: apply its result.
        case adopt
        /// A newer launch has started. Stay silent and leave the busy
        /// indicator alone: the newer launch owns the UI and its own result
        /// is still coming.
        case supersededByNewerLaunch
        /// The setup attempt itself moved on while Chrome was opening — a key
        /// edit, a cancelled embedded sign-in, or a profile change. The launch
        /// is genuinely lost, so the user has to be told; otherwise both
        /// buttons sit grey with no explanation.
        case staleAttempt
    }

    static func disposition(
        _ launch: ChromeLaunchAttempt,
        currentNonce: UUID,
        parentGenerationIsCurrent: Bool
    ) -> Disposition {
        guard launch.nonce == currentNonce else {
            return .supersededByNewerLaunch
        }
        return parentGenerationIsCurrent ? .adopt : .staleAttempt
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
    /// Captured when the consent sheet opens, so neither the sheet's copy nor
    /// the background read can drift onto a different profile mid-flight.
    ///
    /// This is also what presents the sheet. There is deliberately no separate
    /// "showing" boolean: a second piece of state set in the same frame is what
    /// produced an empty, un-dismissable consent sheet.
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
            // Presented from the value itself, so the content is never
            // optional and the sheet always renders its Cancel button. A
            // sheet with nothing to press cannot be dismissed at all.
            .sheet(item: $pendingRead, onDismiss: { pendingRead = nil }) {
                pending in
                ChromeReadConsentSheet(
                    profileLabel: pending.label,
                    onContinue: { continueChromeRead(pending) },
                    onCancel: cancelChromeRead
                )
            }

            // Manual entry, and it stays. Reading from Chrome is an optional
            // shortcut, never a replacement: a user who declines the macOS
            // password prompt, cancels the consent notice, or simply prefers
            // to do it themselves must be able to paste a key exactly as
            // before. So the DevTools steps, the key field and Test
            // Connection are siblings of the Chrome card, always visible,
            // never collapsed behind it and never gated on a Chrome launch.
            // Nothing here is conditional. The field's only disabled state is
            // while a read is actually in flight, which clears the moment the
            // read finishes, succeeds or fails — cancelling the notice never
            // starts one.
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
        // The single state change that presents the notice.
        pendingRead = launchedProfile
    }

    private func cancelChromeRead() {
        pendingRead = nil
    }

    /// Takes the profile the sheet was built from rather than re-reading
    /// state: the sheet on screen named this profile, so this is the profile
    /// the user consented to.
    private func continueChromeRead(_ pending: LaunchedChromeProfile) {
        // Clearing the pending read is what dismisses the notice.
        pendingRead = nil
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

        // The picker keeps its choice. Emptying it after every launch made a
        // working launch look like a failed one: the profile the user had just
        // opened vanished from the picker and the Open button went grey. What
        // actually has to be re-earned is `launchedProfile`, which is cleared
        // here and re-assigned unconditionally when the launch finishes.
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
                switch ChromeLaunchOutcomePolicy.disposition(
                    attempt,
                    currentNonce: launchNonce,
                    parentGenerationIsCurrent:
                        isLaunchCurrent(attempt.parentGeneration)
                ) {
                case .supersededByNewerLaunch:
                    // A newer launch owns the busy indicator and will report
                    // its own result. Saying anything here would describe a
                    // launch the user has already replaced.
                    return
                case .staleAttempt:
                    // Chrome may well have opened, but this attempt is gone,
                    // so nothing was linked to it. Never leave both buttons
                    // grey with no explanation.
                    isLaunching = false
                    launchError =
                        "chrome_assisted.launch_superseded".localized
                    return
                case .adopt:
                    break
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
