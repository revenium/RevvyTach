import Cocoa
import SwiftUI
import UsageCore
import UserNotifications

struct SetupWizardDecision {
    static func shouldShow(
        hasShownWizardOnce: Bool,
        hasCompletedSetup: Bool = true,
        activeProfile: Profile?,
        hasValidClaudeCLI: () -> Bool
    ) -> Bool {
        if activeProfile?.providerID == .codex {
            // Provider routing precedes the one-time Claude migration wizard.
            // Otherwise a first-launch Codex profile would enter the wizard
            // branch, be rejected by the presentation guard, and initialize
            // no menu-bar UI.
            return !hasCompletedSetup
        }
        guard hasShownWizardOnce else { return true }
        guard let activeProfile else { return true }

        switch activeProfile.providerConfiguration {
        case .codex:
            // Covered before the first-launch rule above.
            return false
        case .claude:
            if activeProfile.hasAnyCredentials {
                return false
            }
            // Setup has already been completed once: never force the wizard
            // again. A credential-less profile launches to the menu bar's
            // no-credential state (the app-logo status icon), where
            // credentials can be re-added — being walked back through
            // first-run setup on every launch is not it.
            if hasCompletedSetup {
                return false
            }
            return !hasValidClaudeCLI()
        }
    }

    static func canPresentLegacyWizard(activeProfile: Profile?) -> Bool {
        activeProfile?.providerID != .codex
    }

    /// The current wizard is provider aware and can always be opened manually,
    /// including from a Codex profile to add a Claude profile.
    static func canPresentProviderAwareWizard(
        activeProfile: Profile?
    ) -> Bool {
        true
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var menuBarManager: MenuBarManager?
    private var setupWindow: NSWindow?
    private var terminationTask: Task<Void, Never>?
    private let providerUICompositionRoot:
        ProviderUICompositionRoot

    override convenience init() {
        self.init(providerUICompositionRoot: .application)
    }

    init(providerUICompositionRoot: ProviderUICompositionRoot) {
        self.providerUICompositionRoot = providerUICompositionRoot
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hosted unit tests load the application target in-process. They must
        // never run startup migration against the developer's real defaults,
        // Keychain, or legacy session-key file.
        guard !Self.isRunningHostedUnitTests else {
            return
        }

#if UI_TESTING
        // The UITesting configuration is fail-closed: it never falls through
        // to migration, shared profile hydration, Keychain, updates,
        // notifications, browser launches, prompts, or background monitors.
        setupWindow = UITestApplicationBootstrap.launch(
            compositionRoot: providerUICompositionRoot
        )
        return
#endif

        // A crash between the Read-from-Chrome temp copy and its `defer`
        // unlink would strand a full copy of a Chrome profile's cookie jar in
        // $TMPDIR until reboot. Runs after the hosted-unit-test and UI-testing
        // guards above, so neither test mode touches the real $TMPDIR, and
        // detached so a large temporary directory cannot slow launch.
        Task.detached(priority: .utility) {
            ChromeCookieTempCopySweeper.sweep()
        }

        // Adopt data written under the app's pre-rename identity before
        // anything below reads UserDefaults or Application Support — the
        // status-item position sanitizer and profile migration both consume
        // values this import provides. A production no-op until the bundle
        // identifier actually changes (see AppIdentity).
        LegacyIdentityMigrationService.shared.migrateIfNeeded()

        // Re-own file-Keychain credential items the pre-rename app created,
        // so macOS stops showing a per-item consent dialog on every launch.
        // Runs after the defaults import above (it records completion in the
        // migrated domain) and is likewise a no-op until the bundle
        // identifier changes.
        KeychainOwnershipAdoptionService.shared.adoptIfNeeded()

        // Offer to move the app bundle itself if it is still installed
        // under its pre-rename filename — Sparkle updates install to
        // host.bundlePath, so an in-place update from a 3.x install never
        // relocates the .app on disk even though its contents, icon, and
        // bundle identifier are all correctly RevvyTach. Runs after
        // identity/keychain adoption above so those complete first, and is
        // a production no-op until the bundle identifier actually changes
        // or the app is already at its correct filename.
        LegacyBundleRelocationService.shared.relocateIfNeeded()

        // Disable window restoration for menu bar app
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")

        // Set app icon early for Stage Manager and windows
        if let appIcon = NSImage(named: "AppIcon") {
            NSApp.applicationIconImage = appIcon
        }

        // Hide dock icon (menu bar app only)
        NSApp.setActivationPolicy(.accessory)

        // Clear any AppKit-persisted status item positions left stranded
        // off-screen (e.g. by a since-removed monitor) before any status
        // item is created below — AppKit only reads the saved position at
        // creation time, so this must run first.
        StatusItemPositionSanitizer.sanitize(
            defaults: .standard,
            screens: NSScreen.screens
        )

        // Complete or retry the verified legacy credential/profile migration
        // before any normal profile hydration or first-launch decisions.
        _ = ProfileMigrationService.shared.migrateIfNeeded()

        // Copy any profile credential still sitting in the legacy file
        // Keychain into the data-protection Keychain now that this build can
        // use it. Additive only; see the service's own documentation.
        _ = ProfileKeychainDomainMigrationService.shared.migrateIfNeeded()

        // The 4.1 upgrade cohort is retired, not merely ignored. It existed
        // to explain, once, that a browser sign-in had become necessary for a
        // terminal-only profile. That is no longer true — a terminal-only
        // profile is fully supported and renews itself — so the banner must
        // never appear again, including for profiles already recorded in the
        // stored set. Leaving the set behind is how it comes back the moment
        // anyone re-adds a reader. Nothing classifies profiles into it any
        // more, so `configureClaudeAccountUpgradeClassification` is no longer
        // wired up here.
        //
        // One-way: back up `com.revenium.RevvyTach.plist` before first launch
        // of a build carrying this if the old classification matters to you.
        // Both migrations above still run for their own sake; only the
        // upgrade classification consumed their success flags.
        SharedDataStore.shared.retireClaudeAccountUpgradeClassificationV42()

        // Self-heal a CODEX_HOME pointer left behind by a since-deleted
        // directory (e.g. an external drive that's now unmounted) before any
        // new terminal pane can inherit it and fail with "CODEX_HOME points
        // to ... but that path does not exist." The singleton is already
        // inert under hosted unit tests, but this call site itself never
        // runs for them either — see the early return above.
        CodexSwitchService.shared.discardStaleHomeIfMissing()

        // Load profiles into ProfileManager (synchronously)
        providerUICompositionRoot.profileManager.loadProfiles()

        // Restore the live CODEX_HOME pointer for the active Codex profile,
        // now that profiles (and their persisted `linkedHome`) are loaded.
        // The self-heal above is deliberately aggressive about discarding a
        // pointer whose directory doesn't exist yet (e.g. an external
        // volume that hasn't mounted), so put it back here once it's known
        // to be available again — see `ProfileManager.reapplyActiveCodexHome()`
        // for why this can't simply be left to `activateProfile(_:)`.
        providerUICompositionRoot.profileManager.reapplyActiveCodexHome()

        // Initialize update manager to enable automatic update checks
        _ = UpdateManager.shared

        // Request notification permissions
        requestNotificationPermissions()

        // Listen for manual wizard trigger (for testing)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowSetupWizard),
            name: .showSetupWizard,
            object: nil
        )

        // Check if setup has been completed
        if !shouldShowSetupWizard() {
            // Initialize menu bar with active profile
            menuBarManager = makeMenuBarManager()
            menuBarManager?.setup()
            // A menu-bar-only launch must not be silent: briefly confirm the
            // app started and point the user at the menu bar.
            LaunchSplashPresenter.shared.show()
        } else {
            showSetupWizardManually()
            // Mark that wizard has been shown once
            SharedDataStore.shared.markWizardShown()
        }

        // Track first launch date for GitHub star prompt
        if SharedDataStore.shared.loadFirstLaunchDate() == nil {
            SharedDataStore.shared.saveFirstLaunchDate(Date())
        }

        // TESTING: Check for launch argument to force GitHub star prompt
        if CommandLine.arguments.contains("--show-github-prompt") {
            SharedDataStore.shared.resetGitHubStarPromptForTesting()
            SharedDataStore.shared.saveFirstLaunchDate(Date().addingTimeInterval(-2 * 24 * 60 * 60))
        }

        // TESTING: Check for launch argument to force feedback prompt
        if CommandLine.arguments.contains("--show-feedback-prompt") {
            SharedDataStore.shared.resetFeedbackPromptForTesting()
            SharedDataStore.shared.saveFirstLaunchDate(Date().addingTimeInterval(-8 * 24 * 60 * 60))
        }

        // Check if we should show GitHub star prompt (with a slight delay to not interrupt app startup)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            if SharedDataStore.shared.shouldShowGitHubStarPrompt() {
                self?.menuBarManager?.showGitHubStarPrompt()
            }
        }

        // Check if we should show feedback prompt (after GitHub prompt, avoid overlap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            if SharedDataStore.shared.shouldShowFeedbackPrompt() {
                self?.menuBarManager?.showFeedbackPrompt()
            }
        }

        // Headless support: delayed retry for Remote Desktop scenarios
        // If status bar failed to initialize (headless Mac), retry after a delay when displays connect
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self = self else { return }

            // Only retry if we have screens now but status bar failed
            if !NSScreen.screens.isEmpty && self.menuBarManager?.hasValidStatusBar() == false {
                LoggingService.shared.log("AppDelegate: Delayed retry of status bar setup (headless support)")
                // Sanitize again before this second setup(). The launch-time
                // call above is a guaranteed no-op on a headless start:
                // the sanitizer deliberately treats "no screens attached"
                // as "nothing is stale" rather than wiping every saved
                // position. This retry fires precisely when screens have
                // since appeared, so it is the first moment stale positions
                // can actually be judged — and AppKit only reads a saved
                // position when the status item is created, which is what
                // setup() is about to do.
                StatusItemPositionSanitizer.sanitize(
                    defaults: .standard,
                    screens: NSScreen.screens
                )
                self.menuBarManager?.setup()
            }
        }
    }

    nonisolated static var isRunningHostedUnitTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    /// Double-clicking the app while it is already running must not be
    /// silent either: with no window to bring forward, re-show the launch
    /// card so the user is pointed back at the menu bar.
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag, setupWindow == nil, menuBarManager != nil {
            LaunchSplashPresenter.shared.show()
        }
        return true
    }

    private func requestNotificationPermissions() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
            // Silently request permissions
        }
    }


    private func shouldShowSetupWizard() -> Bool {
        // FORCE SHOW wizard on very first app launch (one-time)
        // This ensures users see the migration option if they have old data
        let hasShownWizardOnce =
            SharedDataStore.shared.hasShownWizardOnce()
        if !hasShownWizardOnce {
            LoggingService.shared.log("AppDelegate: First launch - forcing wizard to show migration option")
        }
        return SetupWizardDecision.shouldShow(
            hasShownWizardOnce: hasShownWizardOnce,
            hasCompletedSetup:
                SharedDataStore.shared.hasCompletedSetup(),
            activeProfile:
                providerUICompositionRoot.profileManager.activeProfile
        ) {
            let valid = hasValidSystemCLICredentials()
            if valid {
                LoggingService.shared.log(
                    "AppDelegate: Found valid CLI credentials, skipping wizard"
                )
            }
            return valid
        }
    }

    /// Checks if valid Claude Code CLI credentials exist in system Keychain
    private func hasValidSystemCLICredentials() -> Bool {
        do {
            // Attempt to read credentials from system Keychain
            guard let jsonData = try ClaudeCodeSyncService.shared.readSystemCredentials() else {
                LoggingService.shared.log("AppDelegate: No CLI credentials found in system Keychain")
                return false
            }

            // Validate: not expired
            if ClaudeCodeSyncService.shared.isTokenExpired(jsonData) {
                LoggingService.shared.log("AppDelegate: CLI credentials found but expired")
                return false
            }

            // Validate: has valid access token
            guard ClaudeCodeSyncService.shared.extractAccessToken(from: jsonData) != nil else {
                LoggingService.shared.log("AppDelegate: CLI credentials found but missing access token")
                return false
            }

            LoggingService.shared.log("AppDelegate: Valid CLI credentials found in system Keychain")
            return true

        } catch {
            LoggingService.shared.logError("AppDelegate: Failed to check CLI credentials", error: error)
            return false
        }
    }

    /// Handles notification to show setup wizard
    @objc private func handleShowSetupWizard() {
        LoggingService.shared.log("AppDelegate: Received showSetupWizard notification")
        showSetupWizardManually()
    }

    /// Shows the setup wizard window (can be called manually for testing)
    func showSetupWizardManually() {
        LoggingService.shared.log("AppDelegate: showSetupWizardManually called")
        // Temporarily show dock icon for the setup window
        NSApp.setActivationPolicy(.regular)
        LoggingService.shared.log("AppDelegate: Set activation policy to regular")

        let setupView = SetupWizardView(
            dependencies: providerUICompositionRoot.dependencies
        )
        let hostingController = NSHostingController(rootView: setupView)
        LoggingService.shared.log("AppDelegate: Created hosting controller")

        let window = NSWindow(contentViewController: hostingController)
        window.title = "RevvyTach Setup"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        LoggingService.shared.log("AppDelegate: Window created and made key")

        // Hide dock icon again when setup window closes
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                NSApp.setActivationPolicy(.accessory)
                self?.setupWindow = nil

                if self?.menuBarManager == nil {
                    self?.menuBarManager =
                        self?.makeMenuBarManager()
                    self?.menuBarManager?.setup()
                    // The wizard just closed and the status item has only
                    // now appeared — point the user at it.
                    LaunchSplashPresenter.shared.show()
                }
            }
        }

        setupWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        // Last moment a credential held in memory can still be saved.
        if case .confirm(let accountNames) = quitCredentialOutcome(),
           !confirmQuitLosingCredentials(accountNames: accountNames) {
            return .terminateCancel
        }

        guard let menuBarManager else {
            return .terminateNow
        }
        guard terminationTask == nil else {
            return .terminateLater
        }
        terminationTask = Task { @MainActor in
            await menuBarManager.cleanupAndWaitForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Makes one final write attempt, then asks the pure policy what to do.
    private func quitCredentialOutcome() -> QuitCredentialGuard.Outcome {
        let profileManager = providerUICompositionRoot.profileManager
        guard !profileManager.sessionOnlyCredentialProfileIDs.isEmpty else {
            return .terminate
        }
        // Rescuing them here is the best outcome: the user is never bothered.
        profileManager.retrySessionOnlyCredentialSave()
        return QuitCredentialGuard.outcome(
            remaining: profileManager.sessionOnlyCredentialProfileIDs,
            orderedProfiles: profileManager.profiles.map {
                (id: $0.id, name: $0.name)
            }
        )
    }

    /// - Returns: true when the user accepts losing the credentials.
    private func confirmQuitLosingCredentials(
        accountNames: [String]
    ) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "quit.credentials_unsaved.title".localized
        alert.informativeText = accountNames.isEmpty
            ? "quit.credentials_unsaved.body".localized
            : accountNames.joined(separator: "\n")
                + "\n\n"
                + "quit.credentials_unsaved.body".localized
        // No Retry button: the final write already ran, so offering one
        // would be a lie.
        alert.addButton(withTitle: "common.cancel".localized)
        alert.addButton(withTitle: "quit.credentials_unsaved.quit".localized)
        return alert.runModal() == .alertSecondButtonReturn
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Idempotent fallback for termination paths that do not consult the
        // delegate reply gate.
        menuBarManager?.cleanup()
    }

    private func makeMenuBarManager() -> MenuBarManager {
        let apiService = ClaudeAPIService()
        let statusService = ClaudeStatusService()
        let runtime = UsageRefreshRuntime.live(
            profileManager:
                providerUICompositionRoot.profileManager,
            apiService: apiService,
            statusService: statusService,
            codexProviderFactory:
                providerUICompositionRoot.codexProviderFactory
        )
        return MenuBarManager(
            apiService: apiService,
            statusService: statusService,
            profileManager:
                providerUICompositionRoot.profileManager,
            refreshRuntime: runtime,
            providerUIDependencies:
                providerUICompositionRoot.dependencies
        )
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running even if all windows are closed
        return false
    }

    func application(_ application: NSApplication, willEncodeRestorableState coder: NSCoder) {
        // Prevent window restoration state from being saved
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        // Disable state restoration for menu bar app
        return false
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show notifications even when app is in foreground (menu bar apps are always foreground)
        completionHandler([.banner, .sound])
    }
}
