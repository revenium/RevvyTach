//
//  SharedDataStore.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-01-10.
//

import Foundation
import UsageCore

/// Manages app-wide settings that are shared across all profiles
class SharedDataStore {
    static let shared = SharedDataStore()

    private let defaults: UserDefaults

    private enum Keys {
        // Language & Localization
        static let languageCode = "selectedLanguageCode"

        // Setup State
        static let hasCompletedSetup = "hasCompletedSetup"
        static let hasShownWizardOnce = "hasShownWizardOnce"
        static let hasShownCLIShellIntegration = "hasShownCLIShellIntegration"
        static let didClassifyClaudeAccountUpgrade =
            "didClassifyClaudeAccountUpgradeV41"
        static let claudeAccountUpgradeBoundaryProfileIDs =
            "claudeAccountUpgradeBoundaryProfileIDsV41"
        static let terminalOnlyClaudeAccountUpgradeProfileIDs =
            "terminalOnlyClaudeAccountUpgradeProfileIDsV41"
        static let didRetireClaudeAccountUpgrade =
            "didRetireClaudeAccountUpgradeV42"

        // GitHub Star Tracking
        static let firstLaunchDate = "firstLaunchDate"
        static let lastGitHubStarPromptDate = "lastGitHubStarPromptDate"
        static let hasStarredGitHub = "hasStarredGitHub"
        static let neverShowGitHubPrompt = "neverShowGitHubPrompt"

        // Feedback Prompt Tracking
        static let lastFeedbackPromptDate = "lastFeedbackPromptDate"
        static let hasSubmittedFeedback = "hasSubmittedFeedback"
        static let neverShowFeedbackPrompt = "neverShowFeedbackPrompt"

        // Debug Settings
        static let debugAPILoggingEnabled = "debugAPILoggingEnabled"

        // Keyboard Shortcuts
        static let shortcutTogglePopover = "shortcutTogglePopover"
        static let shortcutRefresh = "shortcutRefresh"
        static let shortcutOpenSettings = "shortcutOpenSettings"
        static let shortcutNextProfile = "shortcutNextProfile"

        // Auto-Switch Profile
        static let autoSwitchProfileEnabled = "autoSwitchProfileEnabled"

        // MCP Server Sync
        static let autoSyncMCPEnabled = "autoSyncMCPEnabled"

        // Skills Sync
        static let skillsSourceDirectory = "skillsSourceDirectory"

        // Popover Settings
        static let popoverShowRemainingTime = "popoverShowRemainingTime" // legacy bool key
        static let popoverTimeDisplay = "popoverTimeDisplay"
        static let timeFormatPreference = "timeFormatPreference"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        LoggingService.shared.log("SharedDataStore: Using configured app storage")
    }

    // MARK: - Language & Localization

    func saveLanguageCode(_ code: String) {
        defaults.set(code, forKey: Keys.languageCode)
    }

    func loadLanguageCode() -> String? {
        return defaults.string(forKey: Keys.languageCode)
    }

    // MARK: - Setup State

    func saveHasCompletedSetup(_ completed: Bool) {
        defaults.set(completed, forKey: Keys.hasCompletedSetup)
    }

    func hasCompletedSetup() -> Bool {
        // Check if flag is set
        if defaults.bool(forKey: Keys.hasCompletedSetup) {
            return true
        }

        // Also check if session key file exists as fallback (legacy)
        let sessionKeyPath = Constants.ClaudePaths.homeDirectory
            .appendingPathComponent(".claude-session-key")

        if FileManager.default.fileExists(atPath: sessionKeyPath.path) {
            // Auto-mark as complete if session key exists
            saveHasCompletedSetup(true)
            return true
        }

        return false
    }

    func hasShownWizardOnce() -> Bool {
        return defaults.bool(forKey: Keys.hasShownWizardOnce)
    }

    func markWizardShown() {
        defaults.set(true, forKey: Keys.hasShownWizardOnce)
    }

    func hasShownCLIShellIntegration() -> Bool {
        return defaults.bool(forKey: Keys.hasShownCLIShellIntegration)
    }

    func markCLIShellIntegrationShown() {
        defaults.set(true, forKey: Keys.hasShownCLIShellIntegration)
    }

    /// Captures only the profiles that need the one-time 4.1 upgrade
    /// explanation. Later sign-in changes never rewrite this historical set.
    @discardableResult
    func classifyClaudeAccountsForUpgradeOnce(
        _ profiles: [Profile],
        isProfileIdentitySetAuthoritative: Bool = true,
        isAuthoritative: Bool = true
    ) -> Set<UUID> {
        if defaults.bool(
            forKey: Keys.didClassifyClaudeAccountUpgrade
        ) {
            return terminalOnlyClaudeAccountUpgradeProfileIDs()
        }
        let boundaryProfileIDs: Set<UUID>
        if let storedBoundary = defaults.stringArray(
            forKey: Keys.claudeAccountUpgradeBoundaryProfileIDs
        ) {
            boundaryProfileIDs = Set(
                storedBoundary.compactMap(UUID.init(uuidString:))
            )
        } else {
            guard isProfileIdentitySetAuthoritative else {
                return []
            }
            boundaryProfileIDs = Set(profiles.map(\.id))
            defaults.set(
                boundaryProfileIDs.map(\.uuidString).sorted(),
                forKey: Keys.claudeAccountUpgradeBoundaryProfileIDs
            )
        }
        guard isAuthoritative else {
            return []
        }
        let profileIDs = Set(
            profiles.lazy
                .filter {
                    boundaryProfileIDs.contains($0.id)
                        && $0.providerID == .claude
                        && ClaudeSetupState.of($0) == .terminalOnly
                }
                .map(\.id)
        )
        defaults.set(
            profileIDs.map(\.uuidString).sorted(),
            forKey: Keys.terminalOnlyClaudeAccountUpgradeProfileIDs
        )
        defaults.set(
            true,
            forKey: Keys.didClassifyClaudeAccountUpgrade
        )
        return profileIDs
    }

    func terminalOnlyClaudeAccountUpgradeProfileIDs() -> Set<UUID> {
        Set(
            (defaults.stringArray(
                forKey: Keys.terminalOnlyClaudeAccountUpgradeProfileIDs
            ) ?? []).compactMap(UUID.init(uuidString:))
        )
    }

    @available(
        *,
        deprecated,
        message: "The 4.1 upgrade cohort no longer exists; this always returns false."
    )
    func wasTerminalOnlyAtClaudeAccountUpgrade(_ profileID: UUID) -> Bool {
        // Always false. The banner this answered said a browser sign-in had
        // become required in 4.1; it is not required, and a profile in that
        // set is a terminal-only profile — exactly the population that is now
        // fully supported. The reader is kept rather than deleted so no call
        // site can break silently, and so this line is where anyone looking
        // for the old behaviour lands.
        _ = profileID
        return false
    }

    /// Removes the 4.1 upgrade cohort permanently.
    ///
    /// Deleting the stored keys *is* the migration. Making the reader above
    /// return false is not enough on its own: leaving the sets behind leaves
    /// a live cohort of profiles one code change away from seeing a banner
    /// about a requirement that no longer exists.
    ///
    /// One-way, and one-shot. The wizard and first-run flags are deliberately
    /// untouched — this is not a re-onboarding.
    func retireClaudeAccountUpgradeClassificationV42() {
        guard !defaults.bool(
            forKey: Keys.didRetireClaudeAccountUpgrade
        ) else { return }
        defaults.removeObject(
            forKey: Keys.didClassifyClaudeAccountUpgrade
        )
        defaults.removeObject(
            forKey: Keys.claudeAccountUpgradeBoundaryProfileIDs
        )
        defaults.removeObject(
            forKey: Keys.terminalOnlyClaudeAccountUpgradeProfileIDs
        )
        defaults.set(
            true,
            forKey: Keys.didRetireClaudeAccountUpgrade
        )
    }

    // MARK: - GitHub Star Prompt Tracking

    func saveFirstLaunchDate(_ date: Date) {
        defaults.set(date, forKey: Keys.firstLaunchDate)
    }

    func loadFirstLaunchDate() -> Date? {
        return defaults.object(forKey: Keys.firstLaunchDate) as? Date
    }

    func saveLastGitHubStarPromptDate(_ date: Date) {
        defaults.set(date, forKey: Keys.lastGitHubStarPromptDate)
    }

    func loadLastGitHubStarPromptDate() -> Date? {
        return defaults.object(forKey: Keys.lastGitHubStarPromptDate) as? Date
    }

    func saveHasStarredGitHub(_ starred: Bool) {
        defaults.set(starred, forKey: Keys.hasStarredGitHub)
    }

    func loadHasStarredGitHub() -> Bool {
        return defaults.bool(forKey: Keys.hasStarredGitHub)
    }

    func saveNeverShowGitHubPrompt(_ neverShow: Bool) {
        defaults.set(neverShow, forKey: Keys.neverShowGitHubPrompt)
    }

    func loadNeverShowGitHubPrompt() -> Bool {
        return defaults.bool(forKey: Keys.neverShowGitHubPrompt)
    }

    func shouldShowGitHubStarPrompt() -> Bool {
        // Don't show if user said "don't ask again"
        if loadNeverShowGitHubPrompt() {
            return false
        }

        // Don't show if user already starred
        if loadHasStarredGitHub() {
            return false
        }

        let now = Date()

        // Check if we have a first launch date
        guard let firstLaunch = loadFirstLaunchDate() else {
            // If no first launch date, save it now and don't show prompt yet
            saveFirstLaunchDate(now)
            return false
        }

        // Check if it's been at least 1 day since first launch
        let timeSinceFirstLaunch = now.timeIntervalSince(firstLaunch)
        if timeSinceFirstLaunch < Constants.GitHubPromptTiming.initialDelay {
            return false
        }

        // Check if we've ever shown the prompt before
        guard let lastPrompt = loadLastGitHubStarPromptDate() else {
            // Never shown before, and it's been 1+ days since first launch
            return true
        }

        // Has been shown before - check if enough time has passed for a reminder
        let timeSinceLastPrompt = now.timeIntervalSince(lastPrompt)
        return timeSinceLastPrompt >= Constants.GitHubPromptTiming.reminderInterval
    }

    // MARK: - Feedback Prompt Tracking

    func saveLastFeedbackPromptDate(_ date: Date) {
        defaults.set(date, forKey: Keys.lastFeedbackPromptDate)
    }

    func loadLastFeedbackPromptDate() -> Date? {
        return defaults.object(forKey: Keys.lastFeedbackPromptDate) as? Date
    }

    func saveHasSubmittedFeedback(_ submitted: Bool) {
        defaults.set(submitted, forKey: Keys.hasSubmittedFeedback)
    }

    func loadHasSubmittedFeedback() -> Bool {
        return defaults.bool(forKey: Keys.hasSubmittedFeedback)
    }

    func saveNeverShowFeedbackPrompt(_ neverShow: Bool) {
        defaults.set(neverShow, forKey: Keys.neverShowFeedbackPrompt)
    }

    func loadNeverShowFeedbackPrompt() -> Bool {
        return defaults.bool(forKey: Keys.neverShowFeedbackPrompt)
    }

    func shouldShowFeedbackPrompt() -> Bool {
        if loadNeverShowFeedbackPrompt() { return false }
        if loadHasSubmittedFeedback() { return false }

        guard let firstLaunch = loadFirstLaunchDate() else { return false }

        let now = Date()
        let timeSinceFirstLaunch = now.timeIntervalSince(firstLaunch)
        if timeSinceFirstLaunch < Constants.FeedbackPromptTiming.initialDelay {
            return false
        }

        guard let lastPrompt = loadLastFeedbackPromptDate() else {
            return true
        }

        let timeSinceLastPrompt = now.timeIntervalSince(lastPrompt)
        return timeSinceLastPrompt >= Constants.FeedbackPromptTiming.reminderInterval
    }

    func resetFeedbackPromptForTesting() {
        defaults.removeObject(forKey: Keys.lastFeedbackPromptDate)
        defaults.removeObject(forKey: Keys.hasSubmittedFeedback)
        defaults.removeObject(forKey: Keys.neverShowFeedbackPrompt)
    }

    // MARK: - Debug Settings

    func saveDebugAPILoggingEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Keys.debugAPILoggingEnabled)
    }

    func loadDebugAPILoggingEnabled() -> Bool {
        return defaults.bool(forKey: Keys.debugAPILoggingEnabled)
    }

    // MARK: - Keyboard Shortcuts

    private func shortcutKey(for action: ShortcutAction) -> String {
        switch action {
        case .togglePopover: return Keys.shortcutTogglePopover
        case .refresh: return Keys.shortcutRefresh
        case .openSettings: return Keys.shortcutOpenSettings
        case .nextProfile: return Keys.shortcutNextProfile
        }
    }

    func saveShortcut(_ combo: KeyCombo?, for action: ShortcutAction) {
        let key = shortcutKey(for: action)
        if let combo = combo {
            if let data = try? JSONEncoder().encode(combo) {
                defaults.set(data, forKey: key)
            }
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    func loadShortcut(for action: ShortcutAction) -> KeyCombo? {
        let key = shortcutKey(for: action)
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(KeyCombo.self, from: data)
    }

    // MARK: - Auto-Switch Profile

    func saveAutoSwitchProfileEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Keys.autoSwitchProfileEnabled)
    }

    func loadAutoSwitchProfileEnabled() -> Bool {
        return defaults.bool(forKey: Keys.autoSwitchProfileEnabled)
    }

    // MARK: - MCP Server Sync

    func saveAutoSyncMCPEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Keys.autoSyncMCPEnabled)
    }

    func loadAutoSyncMCPEnabled() -> Bool {
        // Default to true (enabled) for new installs — UserDefaults.bool returns false for unset keys
        if defaults.object(forKey: Keys.autoSyncMCPEnabled) == nil { return true }
        return defaults.bool(forKey: Keys.autoSyncMCPEnabled)
    }

    // MARK: - Skills Sync

    func saveSkillsSourceDirectory(_ path: String?) {
        if let path = path {
            defaults.set(path, forKey: Keys.skillsSourceDirectory)
        } else {
            defaults.removeObject(forKey: Keys.skillsSourceDirectory)
        }
    }

    func loadSkillsSourceDirectory() -> String? {
        return defaults.string(forKey: Keys.skillsSourceDirectory)
    }

    // MARK: - Popover Settings

    func savePopoverTimeDisplay(_ display: PopoverTimeDisplay) {
        defaults.set(display.rawValue, forKey: Keys.popoverTimeDisplay)
    }

    func loadPopoverTimeDisplay() -> PopoverTimeDisplay {
        // Check new key first
        if let rawValue = defaults.string(forKey: Keys.popoverTimeDisplay),
           let display = PopoverTimeDisplay(rawValue: rawValue) {
            return display
        }
        // Migrate from old boolean key
        if defaults.object(forKey: Keys.popoverShowRemainingTime) != nil {
            let oldValue = defaults.bool(forKey: Keys.popoverShowRemainingTime)
            let migrated: PopoverTimeDisplay = oldValue ? .remainingTime : .resetTime
            savePopoverTimeDisplay(migrated)
            defaults.removeObject(forKey: Keys.popoverShowRemainingTime)
            return migrated
        }
        return .resetTime
    }

    func saveTimeFormatPreference(_ format: TimeFormatPreference) {
        defaults.set(format.rawValue, forKey: Keys.timeFormatPreference)
    }

    func loadTimeFormatPreference() -> TimeFormatPreference {
        guard let rawValue = defaults.string(forKey: Keys.timeFormatPreference),
              let preference = TimeFormatPreference(rawValue: rawValue) else {
            return .system
        }
        return preference
    }

    /// Returns whether 24-hour time should be used, resolving the system preference
    func uses24HourTime() -> Bool {
        switch loadTimeFormatPreference() {
        case .system:
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            let timeString = formatter.string(from: Date())
            // If the system-formatted time contains AM/PM, it's 12-hour
            return !timeString.contains(formatter.amSymbol) && !timeString.contains(formatter.pmSymbol)
        case .twelveHour:
            return false
        case .twentyFourHour:
            return true
        }
    }

    // MARK: - Testing Helpers

    func resetGitHubStarPromptForTesting() {
        defaults.removeObject(forKey: Keys.firstLaunchDate)
        defaults.removeObject(forKey: Keys.lastGitHubStarPromptDate)
        defaults.removeObject(forKey: Keys.hasStarredGitHub)
        defaults.removeObject(forKey: Keys.neverShowGitHubPrompt)
    }
}
