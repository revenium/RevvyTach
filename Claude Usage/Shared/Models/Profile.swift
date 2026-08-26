//
//  Profile.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-01-07.
//

import Foundation
import UsageCore

/// Represents a complete isolated profile with all credentials and settings
struct Profile: Codable, Identifiable, Equatable {
    // MARK: - Identity
    let id: UUID
    var name: String
    /// Provider identity is immutable for the lifetime of this UUID.
    var providerConfiguration: ProfileProviderConfiguration
    /// Monotonic identity revision for provider-owned request state.
    var providerRevision: UInt64

    // MARK: - Credentials (runtime values hydrated from secure storage)
    var claudeSessionKey: String?
    var organizationId: String?
    /// Display name of the claude.ai organization, cached alongside its
    /// classification so the lookup happens once per profile.
    var organizationName: String?
    /// Whether `organizationId` is a single-person organization (a personal
    /// Max/Pro subscription) rather than a shared Team/Enterprise one.
    /// `nil` means not yet determined; callers must treat that as shared.
    var organizationIsPersonal: Bool?
    var apiSessionKey: String?
    var apiOrganizationId: String?
    var apiSessionKeyExpiry: Date?
    var cliCredentialsJSON: String?
    /// UUID of the organization the stored CLI credential belongs to.
    ///
    /// The CLI login and the claude.ai session key are separate credentials
    /// and can belong to different organizations for the same person, so a
    /// member-scoped figure fetched with the CLI token only describes this
    /// profile when this matches `organizationId`. Cached here because
    /// resolving it costs a request; `nil` means not yet resolved.
    var cliOrganizationId: String?

    // MARK: - CLI Account Sync Metadata
    var hasCliAccount: Bool
    var cliAccountSyncedAt: Date?
    var cliAccountName: String?  // Maps to a claude-switch account directory name

    // MARK: - Usage Data (Per-Profile)
    var claudeUsage: ClaudeUsage?
    var apiUsage: APIUsage?

    // MARK: - Appearance Settings (Per-Profile)
    var iconConfig: MenuBarIconConfiguration

    // MARK: - Behavior Settings (Per-Profile)
    var refreshInterval: TimeInterval
    var autoStartSessionEnabled: Bool
    var checkOverageLimitEnabled: Bool

    // MARK: - Notification Settings (Per-Profile)
    var notificationSettings: NotificationSettings

    // MARK: - Display Configuration
    var isSelectedForDisplay: Bool  // For multi-profile menu bar mode

    // MARK: - Metadata
    var createdAt: Date
    var lastUsedAt: Date

    /// Legacy plaintext secrets from an older on-disk profile.
    ///
    /// Inbound only, and deliberately asymmetric: `decode` still reads it so
    /// an existing install can be rescued, `encode` never writes it, and
    /// adoption at the decode boundary empties it before any caller can
    /// persist. Nothing sets it to a value — every remaining `setValue`
    /// writes nil.
    ///
    /// Keeping it decodable is what lets old data be migrated; refusing to
    /// encode it is what stops a secret reaching disk again.
    var credentialMigrationRetry: ProfileCredentialMigrationRetry

    /// Usage retained only while a legacy preference-blob migration has not
    /// yet passed an exact durable file readback. Runtime usage remains on the
    /// profile for UI compatibility, but normal profile JSON never encodes it.
    var currentUsageMigrationRetry: ProfileCurrentUsage?

    /// Set before any destructive profile cleanup starts. The retained record
    /// keeps enough identity for the user to retry deletion, while loaders
    /// refuse to hydrate credentials or usage back into a partially deleted
    /// profile.
    var deletionInProgress: Bool

    init(
        id: UUID = UUID(),
        name: String,
        providerConfiguration: ProfileProviderConfiguration = .claude,
        providerRevision: UInt64 = 0,
        claudeSessionKey: String? = nil,
        organizationId: String? = nil,
        organizationName: String? = nil,
        organizationIsPersonal: Bool? = nil,
        apiSessionKey: String? = nil,
        apiOrganizationId: String? = nil,
        apiSessionKeyExpiry: Date? = nil,
        cliCredentialsJSON: String? = nil,
        cliOrganizationId: String? = nil,
        hasCliAccount: Bool = false,
        cliAccountSyncedAt: Date? = nil,
        cliAccountName: String? = nil,
        claudeUsage: ClaudeUsage? = nil,
        apiUsage: APIUsage? = nil,
        iconConfig: MenuBarIconConfiguration = .default,
        refreshInterval: TimeInterval = 30.0,
        autoStartSessionEnabled: Bool = false,
        checkOverageLimitEnabled: Bool = true,
        notificationSettings: NotificationSettings = NotificationSettings(),
        isSelectedForDisplay: Bool = true,
        createdAt: Date = Date(),
        lastUsedAt: Date = Date(),
        credentialMigrationRetry: ProfileCredentialMigrationRetry = .init(),
        currentUsageMigrationRetry: ProfileCurrentUsage? = nil,
        deletionInProgress: Bool = false
    ) {
        self.id = id
        self.name = name
        self.providerConfiguration = providerConfiguration
        self.providerRevision = providerRevision
        self.claudeSessionKey = claudeSessionKey
        self.organizationId = organizationId
        self.organizationName = organizationName
        self.organizationIsPersonal = organizationIsPersonal
        self.apiSessionKey = apiSessionKey
        self.apiOrganizationId = apiOrganizationId
        self.apiSessionKeyExpiry = apiSessionKeyExpiry
        self.cliCredentialsJSON = cliCredentialsJSON
        self.cliOrganizationId = cliOrganizationId
        self.hasCliAccount = hasCliAccount
        self.cliAccountSyncedAt = cliAccountSyncedAt
        self.cliAccountName = cliAccountName
        self.claudeUsage = claudeUsage
        self.apiUsage = apiUsage
        self.iconConfig = iconConfig
        self.refreshInterval = refreshInterval
        self.autoStartSessionEnabled = autoStartSessionEnabled
        self.checkOverageLimitEnabled = checkOverageLimitEnabled
        self.notificationSettings = notificationSettings
        self.isSelectedForDisplay = isSelectedForDisplay
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.credentialMigrationRetry = credentialMigrationRetry
        self.currentUsageMigrationRetry = currentUsageMigrationRetry
        self.deletionInProgress = deletionInProgress
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case provider
        case providerRevision
        case claudeSessionKey
        case organizationId
        case organizationName
        case organizationIsPersonal
        case apiSessionKey
        case apiOrganizationId
        case apiSessionKeyExpiry
        case cliCredentialsJSON
        case cliOrganizationId
        case hasCliAccount
        case cliAccountSyncedAt
        case cliAccountName
        case claudeUsage
        case apiUsage
        case iconConfig
        case refreshInterval
        case autoStartSessionEnabled
        case checkOverageLimitEnabled
        case notificationSettings
        case isSelectedForDisplay
        case createdAt
        case lastUsedAt
        case credentialMigrationRetry
        case currentUsageMigrationRetry
        case deletionInProgress
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        let hasExplicitProvider = container.contains(.provider)
        if hasExplicitProvider {
            providerConfiguration = try container.decode(
                ProfileProviderConfiguration.self,
                forKey: .provider
            )
        } else {
            // Every profile written before provider support represented Claude.
            providerConfiguration = .claude
        }
        if hasExplicitProvider {
            guard container.contains(.providerRevision) else {
                throw ProfileProviderConfigurationError.invalidTaggedShape
            }
            providerRevision = try container.decode(
                UInt64.self,
                forKey: .providerRevision
            )
        } else {
            providerRevision = try container.decodeIfPresent(
                UInt64.self,
                forKey: .providerRevision
            ) ?? 0
        }
        organizationId = try container.decodeIfPresent(String.self, forKey: .organizationId)
        organizationName = try container.decodeIfPresent(String.self, forKey: .organizationName)
        organizationIsPersonal = try container.decodeIfPresent(
            Bool.self,
            forKey: .organizationIsPersonal
        )
        apiOrganizationId = try container.decodeIfPresent(String.self, forKey: .apiOrganizationId)
        apiSessionKeyExpiry = try container.decodeIfPresent(Date.self, forKey: .apiSessionKeyExpiry)
        cliOrganizationId = try container.decodeIfPresent(
            String.self,
            forKey: .cliOrganizationId
        )
        hasCliAccount = try container.decodeIfPresent(Bool.self, forKey: .hasCliAccount) ?? false
        cliAccountSyncedAt = try container.decodeIfPresent(Date.self, forKey: .cliAccountSyncedAt)
        cliAccountName = try container.decodeIfPresent(String.self, forKey: .cliAccountName)
        let legacyClaudeUsage = try container.decodeIfPresent(
            ClaudeUsage.self,
            forKey: .claudeUsage
        )
        let legacyAPIUsage = try container.decodeIfPresent(
            APIUsage.self,
            forKey: .apiUsage
        )
        iconConfig = try container.decodeIfPresent(
            MenuBarIconConfiguration.self,
            forKey: .iconConfig
        ) ?? .default
        refreshInterval = try container.decodeIfPresent(
            TimeInterval.self,
            forKey: .refreshInterval
        ) ?? 30
        autoStartSessionEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .autoStartSessionEnabled
        ) ?? false
        checkOverageLimitEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .checkOverageLimitEnabled
        ) ?? true
        notificationSettings = try container.decodeIfPresent(
            NotificationSettings.self,
            forKey: .notificationSettings
        ) ?? NotificationSettings()
        isSelectedForDisplay = try container.decodeIfPresent(
            Bool.self,
            forKey: .isSelectedForDisplay
        ) ?? true
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastUsedAt = try container.decodeIfPresent(Date.self, forKey: .lastUsedAt) ?? createdAt
        deletionInProgress = try container.decodeIfPresent(
            Bool.self,
            forKey: .deletionInProgress
        ) ?? false

        var retry = try container.decodeIfPresent(
            ProfileCredentialMigrationRetry.self,
            forKey: .credentialMigrationRetry
        ) ?? .init()

        // Legacy v3 profile blobs placed secrets directly on Profile. Decode
        // them for migration, but immediately classify them as retry material
        // so a subsequent ordinary encode cannot silently discard them.
        if let value = try container.decodeIfPresent(String.self, forKey: .claudeSessionKey) {
            retry.claudeSessionKey = value
        }
        if let value = try container.decodeIfPresent(String.self, forKey: .apiSessionKey) {
            retry.apiSessionKey = value
        }
        if let value = try container.decodeIfPresent(String.self, forKey: .cliCredentialsJSON) {
            retry.cliCredentialsJSON = value
        }

        credentialMigrationRetry = retry
        claudeSessionKey = retry.claudeSessionKey
        apiSessionKey = retry.apiSessionKey
        cliCredentialsJSON = retry.cliCredentialsJSON

        var usageRetry = try container.decodeIfPresent(
            ProfileCurrentUsage.self,
            forKey: .currentUsageMigrationRetry
        )
        if legacyClaudeUsage != nil || legacyAPIUsage != nil {
            usageRetry = ProfileCurrentUsage(
                providerID: providerID,
                providerRevision: providerRevision,
                report: usageRetry?.report,
                claudeUsage: legacyClaudeUsage ?? usageRetry?.claudeUsage,
                apiUsage: legacyAPIUsage ?? usageRetry?.apiUsage
            )
        }
        currentUsageMigrationRetry = usageRetry?.isEmpty == false ? usageRetry : nil
        claudeUsage = currentUsageMigrationRetry?.claudeUsage
        apiUsage = currentUsageMigrationRetry?.apiUsage
        try validateProviderIsolation()
    }

    func encode(to encoder: Encoder) throws {
        try validateProviderIsolation()
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(providerConfiguration, forKey: .provider)
        try container.encode(providerRevision, forKey: .providerRevision)
        try container.encodeIfPresent(organizationId, forKey: .organizationId)
        try container.encodeIfPresent(organizationName, forKey: .organizationName)
        try container.encodeIfPresent(
            organizationIsPersonal,
            forKey: .organizationIsPersonal
        )
        try container.encodeIfPresent(apiOrganizationId, forKey: .apiOrganizationId)
        try container.encodeIfPresent(apiSessionKeyExpiry, forKey: .apiSessionKeyExpiry)
        try container.encodeIfPresent(cliOrganizationId, forKey: .cliOrganizationId)
        try container.encode(hasCliAccount, forKey: .hasCliAccount)
        try container.encodeIfPresent(cliAccountSyncedAt, forKey: .cliAccountSyncedAt)
        try container.encodeIfPresent(cliAccountName, forKey: .cliAccountName)
        try container.encode(iconConfig, forKey: .iconConfig)
        try container.encode(refreshInterval, forKey: .refreshInterval)
        try container.encode(autoStartSessionEnabled, forKey: .autoStartSessionEnabled)
        try container.encode(checkOverageLimitEnabled, forKey: .checkOverageLimitEnabled)
        try container.encode(notificationSettings, forKey: .notificationSettings)
        try container.encode(isSelectedForDisplay, forKey: .isSelectedForDisplay)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(lastUsedAt, forKey: .lastUsedAt)
        if deletionInProgress {
            try container.encode(true, forKey: .deletionInProgress)
        }

        if let currentUsageMigrationRetry, !currentUsageMigrationRetry.isEmpty {
            try container.encode(
                currentUsageMigrationRetry,
                forKey: .currentUsageMigrationRetry
            )
        }
    }

    // MARK: - Computed Properties
    var hasClaudeAI: Bool {
        claudeSessionKey != nil && organizationId != nil
    }

    var hasAPIConsole: Bool {
        apiSessionKey != nil && apiOrganizationId != nil
    }

    /// True when usage can be fetched now or after renewing/adopting a linked
    /// terminal login during the refresh attempt.
    var hasUsageCredentials: Bool {
        hasClaudeAI || hasAPIConsole || hasRenewableCLILogin
    }

    /// True if profile has CLI OAuth credentials that are not expired
    var hasValidCLIOAuth: Bool {
        guard let cliJSON = cliCredentialsJSON else { return false }
        let sync = ClaudeCodeSyncService.shared
        return sync.extractAccessToken(from: cliJSON) != nil
            && !sync.isTokenExpired(cliJSON)
    }

    /// True if usage can be fetched without first repairing a terminal login.
    var hasImmediatelyUsableCredentials: Bool {
        hasClaudeAI || hasAPIConsole || hasValidCLIOAuth
    }

    /// True if the terminal login can be used now or repaired before refresh.
    /// A linked account remains eligible because its live Claude Code login can
    /// be adopted even when the stored snapshot is missing or no longer usable.
    var hasRenewableCLILogin: Bool {
        if let cliAccountName,
           !cliAccountName.trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty {
            return true
        }
        guard let cliJSON = cliCredentialsJSON,
              ClaudeCodeSyncService.shared.extractAccessToken(
                  from: cliJSON
              ) != nil else {
            return false
        }
        return hasValidCLIOAuth
            || ClaudeCLITokenRefresher.refreshToken(in: cliJSON) != nil
    }

    var hasAnyCredentials: Bool {
        hasClaudeAI || hasAPIConsole || cliCredentialsJSON != nil
    }

    var providerID: ProviderID {
        switch providerConfiguration.kind {
        case .claude:
            return .claude
        case .codex:
            return .codex
        }
    }

    func validateProviderIsolation() throws {
        if let currentUsageMigrationRetry {
            try currentUsageMigrationRetry.validate(
                expectedProviderID: providerID,
                expectedProviderRevision: providerRevision
            )
        }
        guard providerConfiguration.kind == .codex else { return }
        let containsClaudeState =
            claudeSessionKey != nil
            || organizationId != nil
            || organizationName != nil
            || organizationIsPersonal != nil
            || apiSessionKey != nil
            || apiOrganizationId != nil
            || apiSessionKeyExpiry != nil
            || cliCredentialsJSON != nil
            || cliOrganizationId != nil
            || hasCliAccount
            || cliAccountSyncedAt != nil
            || cliAccountName != nil
            || !credentialMigrationRetry.isEmpty
            || claudeUsage != nil
            || apiUsage != nil
            || currentUsageMigrationRetry != nil
        guard !containsClaudeState else {
            throw ProfileProviderConfigurationError
                .claudeStateOnCodexProfile(id)
        }
    }
}

enum ProfileCurrentUsageValidationError: Error, LocalizedError, Equatable {
    case identityMismatch(
        expectedProviderID: ProviderID,
        expectedProviderRevision: UInt64,
        foundProviderID: ProviderID,
        foundProviderRevision: UInt64
    )
    case reportProviderMismatch(
        payloadProviderID: ProviderID,
        reportProviderID: ProviderID
    )
    case claudeCompatibilityOnCodex

    var errorDescription: String? {
        switch self {
        case .identityMismatch(
            let expectedProviderID,
            let expectedProviderRevision,
            let foundProviderID,
            let foundProviderRevision
        ):
            return "Current usage belongs to \(foundProviderID) revision "
                + "\(foundProviderRevision), not \(expectedProviderID) "
                + "revision \(expectedProviderRevision)."
        case .reportProviderMismatch(
            let payloadProviderID,
            let reportProviderID
        ):
            return "Current usage for \(payloadProviderID) contains a "
                + "\(reportProviderID) report."
        case .claudeCompatibilityOnCodex:
            return "Codex current usage cannot contain Claude or Anthropic "
                + "API compatibility projections."
        }
    }
}

/// Atomic durable usage state for one exact provider-profile identity.
///
/// `claudeUsage` and `apiUsage` are compatibility projections retained while
/// existing Claude-only consumers move to the normalized `report`. Legacy
/// payloads predate the identity and report fields and decode as Claude
/// revision zero.
struct ProfileCurrentUsage: Codable, Equatable {
    var providerID: ProviderID
    var providerRevision: UInt64
    var report: UsageReport?
    var claudeUsage: ClaudeUsage?
    var apiUsage: APIUsage?

    init(
        providerID: ProviderID = .claude,
        providerRevision: UInt64 = 0,
        report: UsageReport? = nil,
        claudeUsage: ClaudeUsage? = nil,
        apiUsage: APIUsage? = nil
    ) {
        self.providerID = providerID
        self.providerRevision = providerRevision
        self.report = report
        self.claudeUsage = claudeUsage
        self.apiUsage = apiUsage
    }

    private enum CodingKeys: String, CodingKey {
        case providerID
        case providerRevision
        case report
        case claudeUsage
        case apiUsage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let hasProviderID = container.contains(.providerID)
        let hasProviderRevision = container.contains(.providerRevision)
        if !hasProviderID && !hasProviderRevision {
            providerID = .claude
            providerRevision = 0
        } else {
            guard hasProviderID && hasProviderRevision else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "Current usage identity requires "
                            + "both providerID and providerRevision."
                    )
                )
            }
            // `decode`, rather than `decodeIfPresent`, deliberately rejects a
            // tagged identity whose provider or revision is explicit null.
            providerID = try container.decode(
                ProviderID.self,
                forKey: .providerID
            )
            providerRevision = try container.decode(
                UInt64.self,
                forKey: .providerRevision
            )
        }
        report = try container.decodeIfPresent(
            UsageReport.self,
            forKey: .report
        )
        claudeUsage = try container.decodeIfPresent(
            ClaudeUsage.self,
            forKey: .claudeUsage
        )
        apiUsage = try container.decodeIfPresent(
            APIUsage.self,
            forKey: .apiUsage
        )
        try validateReportIdentity()
        try validateCompatibilityIsolation()
    }

    func encode(to encoder: Encoder) throws {
        try validateReportIdentity()
        try validateCompatibilityIsolation()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(providerID, forKey: .providerID)
        try container.encode(providerRevision, forKey: .providerRevision)
        try container.encodeIfPresent(report, forKey: .report)
        try container.encodeIfPresent(claudeUsage, forKey: .claudeUsage)
        try container.encodeIfPresent(apiUsage, forKey: .apiUsage)
    }

    var isEmpty: Bool {
        report == nil && claudeUsage == nil && apiUsage == nil
    }

    func validate(
        expectedProviderID: ProviderID,
        expectedProviderRevision: UInt64
    ) throws {
        guard providerID == expectedProviderID,
              providerRevision == expectedProviderRevision else {
            throw ProfileCurrentUsageValidationError.identityMismatch(
                expectedProviderID: expectedProviderID,
                expectedProviderRevision: expectedProviderRevision,
                foundProviderID: providerID,
                foundProviderRevision: providerRevision
            )
        }
        try validateReportIdentity()
        try validateCompatibilityIsolation()
    }

    private func validateReportIdentity() throws {
        guard let report else { return }
        guard report.providerID == providerID else {
            throw ProfileCurrentUsageValidationError.reportProviderMismatch(
                payloadProviderID: providerID,
                reportProviderID: report.providerID
            )
        }
    }

    private func validateCompatibilityIsolation() throws {
        guard providerID == .codex else { return }
        guard claudeUsage == nil, apiUsage == nil else {
            throw ProfileCurrentUsageValidationError
                .claudeCompatibilityOnCodex
        }
    }
}

/// Per-field recovery envelope for credentials that have not yet passed a
/// verified Keychain write. This is deliberately separate from Profile's
/// legacy secret keys so normal Codable output never recreates the old format.
struct ProfileCredentialMigrationRetry: Codable, Equatable {
    var claudeSessionKey: String?
    var apiSessionKey: String?
    var cliCredentialsJSON: String?

    var isEmpty: Bool {
        claudeSessionKey == nil && apiSessionKey == nil && cliCredentialsJSON == nil
    }

    private enum CodingKeys: String, CodingKey {
        case claudeSessionKey = "claude-session-key"
        case apiSessionKey = "api-session-key"
        case cliCredentialsJSON = "cli-credentials"
    }

    func value(for field: ProfileSecretField) -> String? {
        switch field {
        case .claudeSessionKey:
            return claudeSessionKey
        case .apiSessionKey:
            return apiSessionKey
        case .cliCredentialsJSON:
            return cliCredentialsJSON
        }
    }

    mutating func setValue(_ value: String?, for field: ProfileSecretField) {
        switch field {
        case .claudeSessionKey:
            claudeSessionKey = value
        case .apiSessionKey:
            apiSessionKey = value
        case .cliCredentialsJSON:
            cliCredentialsJSON = value
        }
    }
}

// MARK: - ProfileCredentials (for compatibility)
/// Simple struct for passing credentials around
struct ProfileCredentials {
    var claudeSessionKey: String?
    var organizationId: String?
    var apiSessionKey: String?
    var apiOrganizationId: String?
    var apiSessionKeyExpiry: Date?
    var cliCredentialsJSON: String?

    var hasClaudeAI: Bool {
        claudeSessionKey != nil && organizationId != nil
    }

    var hasAPIConsole: Bool {
        apiSessionKey != nil && apiOrganizationId != nil
    }

    var hasCLI: Bool {
        cliCredentialsJSON != nil
    }

    /// Mirrors `Profile.secretValue(for:)` so credential-set and profile
    /// code can iterate the same field list without duplicating the mapping.
    func secretValue(for field: ProfileSecretField) -> String? {
        switch field {
        case .claudeSessionKey:
            return claudeSessionKey
        case .apiSessionKey:
            return apiSessionKey
        case .cliCredentialsJSON:
            return cliCredentialsJSON
        }
    }
}
