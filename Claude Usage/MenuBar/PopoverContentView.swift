import SwiftUI
import Charts
import UsageCore

// MARK: - Always-active vibrancy background
/// Clean popover material with no tint overlay. The previous
/// `.hudWindow` + solid black/white tint stack muddied the background into
/// a flat gray and defeated the system material's vibrancy in both
/// appearances; `.popover` tracks the native menu/popover look across
/// light and dark mode on its own.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let effectView = NSVisualEffectView()
        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        return effectView
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Native macOS popover interface - minimal, flat, system-style
struct PopoverNavigationActions {
    let manageProfiles: () -> Void
    let preferences: () -> Void
    /// Settings → CLI Account, where a Claude Code account gets linked.
    let cliAccount: () -> Void
    /// Settings → Claude.ai, where the profile's claude.ai organization link
    /// gets reconnected.
    let claudeAIAccount: () -> Void
}

enum LegacyPopoverBanner: Equatable {
    enum Action: Equatable {
        case preferences
        /// Settings → Claude.ai, where the session key lives. Distinct from
        /// `preferences` because "open Settings" is not an answer when the
        /// user has two unrelated credentials and only one of them is broken.
        case claudeAIAccount
        case refresh
        case retryCredentialSave
    }

    /// A credential the Keychain refused, held in memory. Outranks every
    /// other banner: the others describe something already broken, this one
    /// describes something the user can still prevent — the credential is
    /// lost at quit.
    case credentialsNotSaved(count: Int)
    case credentialError
    case refreshFailed(count: Int)
    case stale(minutesAgo: Int)

    var action: Action {
        switch self {
        case .credentialsNotSaved:
            return .retryCredentialSave
        case .credentialError:
            // `hasCredentialError` is set only when the usage refresh fails
            // as `.unauthenticated`, which is reachable only from the
            // claude.ai session-key error codes — never from the Claude Code
            // CLI credential. Sending the user to Settings at large let them
            // re-sync the CLI account instead, which can never clear this
            // banner no matter how many times it succeeds.
            return .claudeAIAccount
        case .refreshFailed, .stale:
            return .refresh
        }
    }

    var message: String {
        switch self {
        case .credentialsNotSaved(let count):
            return String(
                format: "popover.banner.credentials_not_saved".localized,
                count
            )
        case .credentialError:
            return "popover.banner.credentials_expired".localized
        case .refreshFailed(let count):
            return String(
                format: "popover.banner.refresh_failed".localized,
                count
            )
        case .stale(let minutesAgo):
            return String(
                format: "popover.banner.updated_ago".localized,
                minutesAgo
            )
        }
    }

    static func resolve(
        sessionOnlyCredentialCount: Int = 0,
        hasCredentialError: Bool,
        consecutiveRefreshFailures: Int,
        lastSuccessfulRefreshTime: Date?,
        now: Date
    ) -> LegacyPopoverBanner? {
        if sessionOnlyCredentialCount > 0 {
            return .credentialsNotSaved(
                count: sessionOnlyCredentialCount
            )
        }
        if hasCredentialError {
            return .credentialError
        }
        if consecutiveRefreshFailures >= 3 {
            return .refreshFailed(
                count: consecutiveRefreshFailures
            )
        }
        if let lastSuccessfulRefreshTime {
            let age = now.timeIntervalSince(
                lastSuccessfulRefreshTime
            )
            if age > 300 {
                return .stale(minutesAgo: Int(age / 60))
            }
        }
        return nil
    }
}

/// Diagnostic detail shown when a refresh-failure or stale banner expands.
/// A pure resolver (mirroring `LegacyPopoverBanner` itself) so "does the
/// chevron actually produce useful content" stays unit-testable without
/// driving SwiftUI: every notice with a disclosure affordance must resolve
/// to real text, never an empty or purely decorative expansion.
enum LegacyPopoverBannerDetail: Equatable {
    /// Single-sourced from `NormalizedUsageFailureVocabulary`, the same
    /// provider-neutral vocabulary the normalized notice list
    /// (`NormalizedUsagePresentationBuilder`) uses, rather than duplicating
    /// Claude-specific copy, since the failure kinds themselves are
    /// provider-neutral.
    static func explanationLocalization(
        for failureKind: ProviderRefreshFailureKind?
    ) -> (key: String, default: String) {
        switch failureKind {
        case .unauthenticated:
            return NormalizedUsageFailureVocabulary.unauthenticated
        case .unsupportedAccount:
            return NormalizedUsageFailureVocabulary.unsupportedAccount
        case .disabled, .unlinked, .dependencyMissing,
             .invalidConfiguration:
            return NormalizedUsageFailureVocabulary.configuration
        case .rateLimited:
            return NormalizedUsageFailureVocabulary.rateLimited
        case .serverError:
            return NormalizedUsageFailureVocabulary.serverError
        case .transport, .protocolMismatch, .malformedResponse,
             .timedOut, .persistence, .unknown, nil:
            return NormalizedUsageFailureVocabulary.refreshFailed
        }
    }

    static func explanation(
        for failureKind: ProviderRefreshFailureKind?
    ) -> String {
        let localization = explanationLocalization(for: failureKind)
        return NormalizedUsageStrings.localized(
            localization.key,
            default: localization.default
        )
    }

    /// Formats a sanitized technical detail string (HTTP status / URL error
    /// domain+code, already free of paths, tokens, org identifiers, and
    /// response bodies — see `ProviderRefreshFailure.detail`) for display
    /// below the human explanation. The wrapper text is localized; the
    /// technical fragment itself is left as-is since it's already a safe,
    /// English-language system/API string.
    static func technicalDetailText(_ detail: String?) -> String? {
        guard let detail else { return nil }
        return NormalizedUsageStrings.formatted(
            "popover.banner.technical_detail",
            default: "Details: %@",
            arguments: [detail]
        )
    }

    static func lastSuccessText(
        _ date: Date?,
        formatted: (Date) -> String
    ) -> String {
        guard let date else {
            return NormalizedUsageStrings.localized(
                "popover.banner.never_succeeded",
                default: "No successful refresh yet."
            )
        }
        return NormalizedUsageStrings.formatted(
            "popover.banner.last_success",
            default: "Last successful refresh: %@",
            arguments: [formatted(date)]
        )
    }

    /// A "Retrying at {time}" line shown alongside the explanation when the
    /// engine knows the next scheduled attempt won't start before a
    /// specific time (backoff, or a server-provided `Retry-After` hint).
    /// `nil` when no such time is known, so the caller can omit the line
    /// entirely rather than show empty/placeholder text.
    static func retryText(
        _ retryNotBefore: Date?,
        formatted: (Date) -> String
    ) -> String? {
        guard let retryNotBefore else { return nil }
        return NormalizedUsageStrings.formatted(
            "popover.banner.retrying_at",
            default: "Retrying at %@",
            arguments: [formatted(retryNotBefore)]
        )
    }
}

struct PopoverContentView: View {
    @ObservedObject var manager: MenuBarManager
    let onRefresh: () -> Void
    let navigationActions: PopoverNavigationActions
    let onCredentialsBannerTap: (UUID?) -> Void

    @State private var isRefreshing = false
    // Replaces NSPopover's native resize animation, which can recurse indefinitely
    // on macOS 26/27 when preferredContentSize drives the hosting controller.
    @State private var appeared = false
    @ObservedObject private var profileManager: ProfileManager

    init(
        manager: MenuBarManager,
        profileManager: ProfileManager,
        onRefresh: @escaping () -> Void,
        onManageProfiles: @escaping () -> Void,
        onPreferences: @escaping () -> Void,
        onCLIAccount: @escaping () -> Void,
        onClaudeAIAccount: @escaping () -> Void,
        onCredentialsBannerTap: @escaping (UUID?) -> Void
    ) {
        self.manager = manager
        _profileManager = ObservedObject(
            wrappedValue: profileManager
        )
        self.onRefresh = onRefresh
        navigationActions = PopoverNavigationActions(
            manageProfiles: onManageProfiles,
            preferences: onPreferences,
            cliAccount: onCLIAccount,
            claudeAIAccount: onClaudeAIAccount
        )
        self.onCredentialsBannerTap = onCredentialsBannerTap
    }

    private var displayedProfile: Profile? {
        if let clickedProfileID = manager.clickedProfileId {
            return profileManager.profiles.first {
                $0.id == clickedProfileID
            }
        }
        return profileManager.activeProfile
    }

    private var displayPreferences: NormalizedUsageDisplayPreferences {
        NormalizedUsageDisplayPreferences.make(
            displayMode: profileManager.displayMode,
            displayedProfile: displayedProfile,
            multiProfileConfiguration:
                profileManager.multiProfileConfig
        )
    }

    private var timeDisplay: PopoverTimeDisplay {
        SharedDataStore.shared.loadPopoverTimeDisplay()
    }

    private func presentation(
        at now: Date
    ) -> NormalizedUsagePresentation {
        if let displayedProfile {
            return NormalizedUsagePresentationBuilder.make(
                snapshot: manager.displayedUsagePresentation,
                expectedProfile: NormalizedUsageExpectedProfile(
                    id: displayedProfile.id,
                    name: displayedProfile.name,
                    providerID: displayedProfile.providerID,
                    providerRevision:
                        displayedProfile.providerRevision
                ),
                now: now
            )
        }

        // A removed profile can remain the popover click target for one render
        // turn. Keep that target isolated instead of falling back to active
        // profile data.
        let unavailableID = manager.clickedProfileId
            ?? Self.unavailableProfileID
        return NormalizedUsagePresentationBuilder.make(
            snapshot: nil,
            expectedProfile: NormalizedUsageExpectedProfile(
                id: unavailableID,
                name: NormalizedUsageStrings.localized(
                    "popover.normalized.selected_profile",
                    default: "Selected profile"
                ),
                providerID: Self.unknownProviderID,
                providerRevision: 0
            ),
            now: now
        )
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            popoverBody(
                presentation: presentation(at: timeline.date),
                now: timeline.date
            )
        }
    }

    private func popoverBody(
        presentation: NormalizedUsagePresentation,
        now: Date
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            shellContent(
                presentation: presentation,
                now: now
            )
        }
        .padding(.bottom, 10)
        .frame(width: PopoverDesign.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            ZStack {
                VisualEffectBackground()
                // Readability scrim: behind-window vibrancy alone lets
                // whatever sits under the popover (e.g. a bright window
                // beneath a dark menu bar) bleed through and wash out
                // text and status colors. A translucent layer of the
                // system window background keeps a hint of vibrancy at
                // the edges while guaranteeing contrast, per the HIG
                // guidance on legibility over vibrant materials.
                Color(nsColor: .windowBackgroundColor)
                    .opacity(0.6)
            }
        )
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared ? 1 : 0.96, anchor: .top)
        .onAppear {
            appeared = false
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                appeared = true
            }
        }
    }

    @ViewBuilder
    private func shellContent(
        presentation: NormalizedUsagePresentation,
        now: Date
    ) -> some View {
        ProviderPopoverHeader(
            presentation: presentation,
            claudeStatus: manager.status,
            isRefreshing: isRefreshing
                || presentation.notices.contains {
                    $0.kind == .loading
                },
            isViewedProfileActive: displayedProfile.map {
                profileManager.isActive($0)
            },
            onRefresh: triggerRefresh,
            onPreferences:
                navigationActions.preferences
        )

        PopoverDivider()

        let resolvedBanner: LegacyPopoverBanner? =
            presentation.providerID == .claude
            ? LegacyPopoverBanner.resolve(
                sessionOnlyCredentialCount:
                    profileManager.sessionOnlyCredentialProfileIDs.count,
                hasCredentialError: manager.hasCredentialError,
                consecutiveRefreshFailures:
                    manager.consecutiveRefreshFailures,
                lastSuccessfulRefreshTime:
                    manager.lastSuccessfulRefreshTime,
                now: now
            )
            : nil

        if presentation.providerID == .claude {
            claudeBanner(resolvedBanner: resolvedBanner)
        }

        // Usage for the viewed account is the popover's primary content
        // and comes first; the accounts switcher is navigation and sits
        // pinned below the scrolling usage area.
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                normalizedProfileTag(
                    presentation: presentation
                )
                NormalizedUsageView(
                    presentation: presentation
                        .filteringOutNoticesShownByClaudeBanner(
                            matching: resolvedBanner
                        ),
                    displayPreferences: displayPreferences,
                    timeDisplay: timeDisplay,
                    now: now,
                    // Always available: every reason a member's figure is
                    // missing is resolved on the same screen, and hiding the
                    // notice from an already-linked profile would bury a
                    // broken sign-in rather than surface it. Which of the
                    // three explanations appears is decided from the data.
                    onConnectCLIAccount: navigationActions.cliAccount,
                    onConnectClaudeAIAccount: navigationActions.claudeAIAccount
                )
            }
        }
        .frame(maxHeight: .infinity)
        .layoutPriority(1)

        PopoverDivider()
            .padding(.top, 2)

        activeAccountsSection()
    }

    /// Complete list, in the popover's own profile order.
    private var sessionOnlyCredentialNames: [String] {
        profileManager.profiles
            .filter {
                profileManager.sessionOnlyCredentialProfileIDs.contains($0.id)
            }
            .map(\.name)
    }

    private func triggerRefresh() {
        withAnimation(.easeInOut(duration: 0.3)) {
            isRefreshing = true
        }
        onRefresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            withAnimation(.easeInOut(duration: 0.3)) {
                isRefreshing = false
            }
        }
    }

    @ViewBuilder
    private func claudeBanner(
        resolvedBanner: LegacyPopoverBanner?
    ) -> some View {
        if let banner = resolvedBanner {
            switch banner {
            case .credentialsNotSaved:
                ExpandableStatusBanner(
                    icon: "exclamationmark.triangle.fill",
                    message: banner.message,
                    detail:
                        "popover.banner.credentials_not_saved.detail"
                        .localized,
                    accountNames: sessionOnlyCredentialNames,
                    color: .orange,
                    retryActionTitle:
                        "popover.banner.credentials_not_saved.retry"
                        .localized,
                    onRetry: {
                        profileManager.retrySessionOnlyCredentialSave()
                    }
                )
            case .credentialError:
                StatusBannerView(
                    icon: "exclamationmark.triangle.fill",
                    message:
                        "popover.banner.credentials_expired".localized,
                    color: .orange,
                    onTap: { onCredentialsBannerTap(displayedProfile?.id) }
                )
            case .refreshFailed:
                ExpandableStatusBanner(
                    icon: "arrow.clockwise.circle.fill",
                    message: banner.message,
                    detail: LegacyPopoverBannerDetail.explanation(
                        for: manager.lastRefreshFailureKind
                    ),
                    technicalDetail: LegacyPopoverBannerDetail.technicalDetailText(
                        manager.lastRefreshFailureDetail
                    ),
                    retryText: LegacyPopoverBannerDetail.retryText(
                        manager.lastRefreshFailureRetryAt,
                        formatted: Self.absoluteTimeText
                    ),
                    lastSuccessText:
                        LegacyPopoverBannerDetail.lastSuccessText(
                            manager.lastSuccessfulRefreshTime,
                            formatted: Self.absoluteTimeText
                        ),
                    color: .yellow,
                    onRetry: onRefresh
                )
            case .stale:
                ExpandableStatusBanner(
                    icon: "clock.fill",
                    message: banner.message,
                    detail: nil,
                    lastSuccessText:
                        LegacyPopoverBannerDetail.lastSuccessText(
                            manager.lastSuccessfulRefreshTime,
                            formatted: Self.absoluteTimeText
                        ),
                    color: .orange,
                    onRetry: onRefresh
                )
            }
        }
    }

    @ViewBuilder
    private func activeAccountsSection() -> some View {
        let groups = AccountChipGroup.make(
            profiles: profileManager.profiles,
            isActive: profileManager.isActive,
            viewedProfileID: displayedProfile?.id
        )
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    PopoverSectionHeader(
                        title: NormalizedUsageStrings.localized(
                            "popover.accounts.title",
                            default: "Accounts"
                        )
                    )
                    .padding(.leading, 2)
                    .accessibilityHidden(true)

                    Spacer()

                    // Direct route to profile management; removing the
                    // header switcher menu removed the popover's only
                    // "Manage Profiles" entry point.
                    Button(action: navigationActions.manageProfiles) {
                        Text("popover.manage_profiles".localized)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(
                        "popover.action.manage_profiles"
                    )
                }

                // Bounded: with many accounts the chip rows scroll
                // inside the footer instead of growing the popover
                // past screen height.
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: 4) {
                                // Caption only earns its row when there
                                // is a second provider to distinguish
                                // from.
                                if groups.count > 1 {
                                    Text(group.providerName)
                                        .font(
                                            .system(
                                                size: 10,
                                                weight: .medium
                                            )
                                        )
                                        .foregroundColor(.secondary)
                                        .padding(.leading, 2)
                                }

                                PopoverChipFlowLayout(spacing: 6) {
                                    ForEach(group.chips) { chip in
                                        AccountChipView(chip: chip) {
                                            manager.setViewedProfile(
                                                chip.id
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxHeight: 150)
            }
            .padding(.horizontal, PopoverDesign.outerInset)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .accessibilityElement(children: .contain)
        }
    }

    // Shown only when the viewed profile is not its provider's active
    // profile: one short fixed-label strip pairing the state with the
    // single action that changes it. Deliberately contains no account
    // names — names live in the header and the accounts chips, where
    // truncation is graceful; a prose sentence with an embedded name can
    // never be guaranteed to fit the popover's width. When viewing the
    // active profile the strip disappears entirely (the header pill and
    // the chips' green dot already carry that state).
    @ViewBuilder
    private func normalizedProfileTag(
        presentation: NormalizedUsagePresentation
    ) -> some View {
        if let viewingProfile = displayedProfile,
           !profileManager.isActive(viewingProfile) {
            HStack(spacing: 8) {
                Image(systemName: "eye")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .accessibilityHidden(true)

                Text(
                    NormalizedUsageStrings.localized(
                        "popover.viewing_strip.not_active",
                        default: "Not active"
                    )
                )
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)

                Spacer(minLength: 8)
                makeActiveButton(for: viewingProfile)
                    .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(
                    cornerRadius: PopoverDesign.cardRadius,
                    style: .continuous
                )
                .fill(Color.accentColor.opacity(0.08))
            )
            .padding(.horizontal, PopoverDesign.outerInset)
            .padding(.top, 8)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(
                "popover.profile."
                    + viewingProfile.id.uuidString
            )
        }
    }

    // Activation stays an explicit, opt-in action, so this only ever
    // appears — and only ever does one thing — when the viewed profile
    // genuinely isn't active.
    @ViewBuilder
    private func makeActiveButton(for profile: Profile) -> some View {
        if !profileManager.isActive(profile) {
            let title = NormalizedUsageStrings.localized(
                "menu.provider.make_active",
                default: "Make Active"
            )
            Button(action: {
                Task {
                    await profileManager.activateProfile(profile.id)
                }
            }) {
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .strokeBorder(
                                Color.accentColor.opacity(0.45),
                                lineWidth: 1
                            )
                    )
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(
                NormalizedUsageStrings.formatted(
                    "popover.make_active.help",
                    default: "Make %@ the active account its provider uses. Viewing usage never changes this.",
                    arguments: [profile.name]
                )
            )
            .accessibilityIdentifier("popover.profile.make_active")
            .accessibilityLabel(
                "\(title): \(profile.name)"
            )
        }
    }

    private static let absoluteTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static func absoluteTimeText(_ date: Date) -> String {
        absoluteTimeFormatter.string(from: date)
    }

    private static let unavailableProfileID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )

    private static let unknownProviderID: ProviderID = {
        guard let providerID = try? ProviderID("unknown") else {
            preconditionFailure("Invalid unknown provider identifier")
        }
        return providerID
    }()
}

// MARK: - Native Divider

struct PopoverDivider: View {
    var body: some View {
        Divider()
            .padding(.horizontal, 16)
    }
}

// MARK: - Account Chip

/// One chip in the "Accounts" section, tappable to switch the popover to
/// that account. Purely a view switch — see
/// `MenuBarManager.setViewedProfile(_:)` for why activation never
/// happens here.
struct AccountChipView: View {
    let chip: AccountChipPresentation
    let onTap: () -> Void

    private var accessibilityLabel: String {
        var base = "\(chip.providerName) · \(chip.profileName)"
        if chip.isActive {
            base += ", " + NormalizedUsageStrings.localized(
                "popover.normalized.profile.active",
                default: "Active"
            )
        }
        guard chip.isViewing else { return base }
        return base + ", " + NormalizedUsageStrings.localized(
            "popover.normalized.profile.viewing",
            default: "Viewing"
        )
    }

    @State private var isHovered = false

    private var helpText: String {
        var parts = ["\(chip.providerName) · \(chip.profileName)"]
        if chip.isActive {
            parts.append(
                NormalizedUsageStrings.localized(
                    "popover.normalized.profile.active",
                    default: "Active"
                )
            )
        }
        if chip.isViewing {
            parts.append(
                NormalizedUsageStrings.localized(
                    "popover.normalized.profile.viewing",
                    default: "Viewing"
                )
            )
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                Text(chip.profileName)
                    .font(PopoverDesign.chipFont)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if chip.isActive {
                    Circle()
                        .fill(Color.adaptiveGreen)
                        .frame(width: 5, height: 5)
                        .accessibilityHidden(true)
                }
            }
            .foregroundColor(
                chip.isViewing ? .accentColor : .primary
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(
                        chip.isViewing
                            ? Color.accentColor.opacity(0.14)
                            : isHovered
                                ? PopoverDesign.hoverFill
                                : PopoverDesign.cardFill
                    )
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        chip.isViewing
                            ? Color.accentColor.opacity(0.45)
                            : Color.clear,
                        lineWidth: 1
                    )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .help(helpText)
        .accessibilityIdentifier(chip.accessibilityIdentifier)
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - Header Icon Button
struct HeaderIconButton: View {
    let icon: String
    var fontSize: CGFloat = 10.5
    var isRefreshing: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 10, height: 10)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: fontSize, weight: .medium))
                        .imageScale(.medium)
                }
            }
            .foregroundColor(isHovered ? .primary : .secondary)
            .frame(width: 24, height: 24, alignment: .center)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - API Cost Card
struct APICostCard: View {
    let apiUsage: APIUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("API Cost")
                        .font(PopoverDesign.rowTitleFont)
                        .foregroundColor(.primary)

                    Text("This Month")
                        .font(PopoverDesign.metaFont)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Total cost
                if let formatted = apiUsage.formattedAPICost {
                    Text(formatted)
                        .font(PopoverDesign.valueFont)
                        .monospacedDigit()
                        .foregroundColor(.primary)
                }
            }

            // Daily cost chart
            DailyCostChart(dailyCosts: apiUsage.sortedDailyCosts, currency: apiUsage.currency)

            // Per-key breakdown (if multiple sources) or flat model list
            if apiUsage.hasMultipleSources {
                VStack(spacing: 6) {
                    ForEach(apiUsage.sortedCostSources) { source in
                        APICostSourceRow(source: source, currency: apiUsage.currency)
                    }
                }
            } else {
                // Single source or no source data — show flat model breakdown
                let models = apiUsage.sortedModelCosts
                if !models.isEmpty {
                    VStack(spacing: 4) {
                        ForEach(models, id: \.model) { item in
                            HStack {
                                Text(item.model)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)

                                Spacer()

                                Text(item.cost)
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .popoverCard()
    }
}

// MARK: - Daily Cost Chart
struct DailyCostChart: View {
    let dailyCosts: [(date: Date, cents: Double)]
    let currency: String

    private struct DayCost: Identifiable {
        let id: Date
        let dollars: Double
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    private var xDomain: ClosedRange<Date> {
        let cal = Calendar.current
        let today = Date()
        let startOfMonth = cal.date(from: cal.dateComponents([.year, .month], from: today))!
        // End of today (start of tomorrow)
        let endOfToday = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: today))!
        return startOfMonth ... endOfToday
    }

    var body: some View {
        if !dailyCosts.isEmpty {
            let data = dailyCosts.map { DayCost(id: $0.date, dollars: $0.cents / 100.0) }
            let maxValue = data.map(\.dollars).max() ?? 0
            Chart(data) { item in
                BarMark(
                    x: .value("Day", item.id, unit: .day),
                    y: .value("Cost", item.dollars),
                    width: .fixed(12)
                )
                .foregroundStyle(Color.orange.opacity(0.75))
                .cornerRadius(2)
            }
            .chartXScale(domain: xDomain)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { value in
                    AxisValueLabel(centered: true) {
                        if let date = value.as(Date.self) {
                            Text("\(Calendar.current.component(.day, from: date))")
                                .font(.system(size: 7))
                                .foregroundColor(.secondary.opacity(0.6))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.3))
                        .foregroundStyle(Color.secondary.opacity(0.15))
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(formatDollars(v, max: maxValue))
                                .font(.system(size: 7, design: .rounded))
                                .foregroundColor(.secondary.opacity(0.6))
                        }
                    }
                }
            }
            .chartYScale(domain: 0 ... max(maxValue * 1.15, 0.01))
            .frame(height: 80)
        }
    }

    private func formatDollars(_ amount: Double, max: Double) -> String {
        if max >= 100 {
            return "$\(Int(amount))"
        } else if max >= 1 {
            return String(format: "$%.1f", amount)
        } else {
            return String(format: "$%.2f", amount)
        }
    }
}

// MARK: - API Cost Source Row
struct APICostSourceRow: View {
    let source: APICostSource
    let currency: String
    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 4) {
            // Source header (tappable to expand)
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: source.sourceType.icon)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 12)

                    Text(source.keyName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    Spacer()

                    Text(source.formattedTotal(currency: currency))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.primary)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(.secondary.opacity(0.6))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.06))
                )
            }
            .buttonStyle(.plain)

            // Expanded model breakdown
            if isExpanded {
                let models = source.sortedModelCosts(currency: currency)
                VStack(spacing: 3) {
                    ForEach(models, id: \.model) { item in
                        HStack {
                            Text(item.model)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.secondary)
                                .lineLimit(1)

                            Spacer()

                            Text(item.cost)
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.leading, 24)
                .padding(.trailing, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

// MARK: - API Usage Card
struct APIUsageCard: View {
    let apiUsage: APIUsage
    let showRemaining: Bool
    var timeDisplay: PopoverTimeDisplay = .resetTime

    private var displayPercentage: Double {
        UsageStatusCalculator.getDisplayPercentage(
            usedPercentage: apiUsage.usagePercentage,
            showRemaining: showRemaining
        )
    }

    private var statusLevel: UsageStatusLevel {
        UsageStatusCalculator.calculateStatus(
            usedPercentage: apiUsage.usagePercentage,
            showRemaining: showRemaining
        )
    }

    private var usageColor: Color {
        switch statusLevel {
        case .safe: return .adaptiveGreen
        case .moderate: return .orange
        case .critical: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("menubar.api_credits".localized)
                        .font(PopoverDesign.rowTitleFont)
                        .foregroundColor(.primary)

                    Text("menubar.anthropic_console".localized)
                        .font(PopoverDesign.metaFont)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text("\(Int(displayPercentage))%")
                    .font(PopoverDesign.valueFont)
                    .monospacedDigit()
                    .foregroundColor(usageColor)
            }

            PopoverProgressBar(
                fraction: min(displayPercentage / 100.0, 1.0),
                color: usageColor
            )

            // Used / Remaining
            HStack {
                Text(apiUsage.formattedUsed)
                    .font(PopoverDesign.metaFont)
                    .foregroundColor(.secondary)

                Spacer()

                Text(apiUsage.formattedRemaining)
                    .font(PopoverDesign.metaFont)
                    .foregroundColor(.secondary)
            }

            // Reset Time
            if apiUsage.resetsAt > Date() {
                Text(resetTimeText(for: apiUsage.resetsAt))
                    .font(PopoverDesign.metaFont)
                    .foregroundColor(.secondary)
            }
        }
        .popoverCard()
    }

    private func resetTimeText(for reset: Date) -> String {
        switch timeDisplay {
        case .resetTime:
            return "menubar.resets_time".localized(with: reset.resetTimeString())
        case .remainingTime:
            return "menubar.resets_in".localized(with: reset.timeRemainingString())
        case .both:
            return "menubar.resets_both".localized(with: reset.timeRemainingString(), reset.resetTimeString())
        }
    }
}

// MARK: - Status Banner View
struct StatusBannerView: View {
    let icon: String
    let message: String
    let color: Color
    var onTap: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(color)
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(2)
            Spacer()
            if onTap != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(
                cornerRadius: PopoverDesign.cardRadius,
                style: .continuous
            )
            .fill(color.opacity(0.12))
        )
        .padding(.horizontal, PopoverDesign.outerInset)
        .padding(.top, 6)
        // Without an explicit hit-testing shape, `onTapGesture` only
        // registers over the row's rendered content (icon/text), not the
        // `Spacer()` that fills most of the row — including the area right
        // under the chevron the layout draws to invite a tap. That made the
        // affordance look dead even though the closure was reachable.
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
    }
}

// MARK: - Expandable Status Banner

/// A status banner whose chevron toggles an in-place disclosure instead of
/// silently firing an action: tapping the row only ever reveals real detail
/// (and, when relevant, a last-successful-refresh time), and the visible
/// "Retry" button is the only thing that re-triggers a refresh. This keeps
/// the chevron affordance honest — it never implies detail that isn't there.
struct ExpandableStatusBanner: View {
    let icon: String
    let message: String
    /// Root-cause explanation for the failure, if any. `nil` for banners
    /// (like staleness) that have no distinct cause beyond time passing.
    let detail: String?
    /// Sanitized technical diagnostic line (HTTP status or URL error
    /// domain/code), shown below `detail` when known. `nil` omits the line
    /// entirely — most banners (credential errors, staleness) have no
    /// underlying transport error to surface.
    var technicalDetail: String? = nil
    /// "Retrying at {time}" line, shown only when the engine knows when the
    /// next scheduled attempt will start (backoff / `Retry-After`). `nil`
    /// omits the line entirely.
    var retryText: String? = nil
    /// Complete list of affected account names, rendered as structured rows
    /// rather than folded into a sentence.
    var accountNames: [String] = []
    /// Omitted entirely when there is no meaningful last success to cite.
    var lastSuccessText: String? = nil
    let color: Color
    /// Label for the single affordance. Defaults to refresh, which is what
    /// the failure banners want.
    var retryActionTitle: String = "common.refresh".localized
    let onRetry: () -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            }) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                        .foregroundColor(color)
                    Text(message)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("popover.banner.disclosure")

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    if let detail {
                        Text(detail)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let technicalDetail {
                        Text(technicalDetail)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier(
                                "popover.banner.technical_detail"
                            )
                    }
                    if let retryText {
                        Text(retryText)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .accessibilityIdentifier(
                                "popover.banner.retry_text"
                            )
                    }
                    ForEach(accountNames, id: \.self) { name in
                        Text(name)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .accessibilityIdentifier(
                                "popover.banner.account_row"
                            )
                    }
                    if let lastSuccessText {
                        Text(lastSuccessText)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }

                    Button(action: onRetry) {
                        Text(retryActionTitle)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                    .accessibilityIdentifier("popover.banner.retry")
                }
                .padding(.leading, 20)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(
                cornerRadius: PopoverDesign.cardRadius,
                style: .continuous
            )
            .fill(color.opacity(0.12))
        )
        .padding(.horizontal, PopoverDesign.outerInset)
        .padding(.top, 6)
        .accessibilityElement(children: .contain)
    }
}

extension NormalizedUsagePresentation {
    /// Claude renders its own credential-error and refresh-failure
    /// banners via `claudeBanner(resolvedBanner:)`. Strip only the
    /// notice kind that corresponds to the banner actually resolved
    /// for the current state, so the same problem isn't shown twice
    /// in the popover — but nothing is silently dropped when no
    /// banner is being rendered (e.g. fewer than 3 consecutive
    /// refresh failures).
    fileprivate func filteringOutNoticesShownByClaudeBanner(
        matching resolvedBanner: LegacyPopoverBanner?
    ) -> NormalizedUsagePresentation {
        guard let resolvedBanner else { return self }
        let kindToStrip: NormalizedUsageNotice.Kind
        switch resolvedBanner {
        case .credentialsNotSaved:
            // No notice kind corresponds to this banner, so there is no
            // duplicate to strip. A genuine credential problem alongside it
            // is a different problem and must still be shown.
            return self
        case .credentialError:
            kindToStrip = .unauthenticated
        case .refreshFailed:
            kindToStrip = .refreshFailed
        case .stale:
            kindToStrip = .stale
        }
        return NormalizedUsagePresentation(
            profileID: profileID,
            profileName: profileName,
            providerID: providerID,
            providerName: providerName,
            accountName: accountName,
            planName: planName,
            organizationName: organizationName,
            healthStatus: healthStatus,
            groups: groups,
            summary: summary,
            credits: credits,
            notices: notices.filter { $0.kind != kindToStrip },
            emptyState: emptyState,
            legacyClaudeUsage: legacyClaudeUsage,
            legacyClaudeAPIUsage: legacyClaudeAPIUsage
        )
    }
}
