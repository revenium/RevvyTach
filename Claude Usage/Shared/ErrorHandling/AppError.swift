//
//  AppError.swift
//  Claude Usage - Unified Error Handling System
//
//  Created on 2025-12-27.
//

import Foundation
import UsageCore

/// Unified error system with error codes for debugging and user support
struct AppError: Error, LocalizedError, CustomStringConvertible {

    // MARK: - Properties

    /// Unique error code for identification and support
    let code: ErrorCode

    /// Human-readable error message
    let message: String

    /// Technical details for debugging
    let technicalDetails: String?

    /// Underlying error if this wraps another error
    let underlyingError: Error?

    /// Timestamp when error occurred
    let timestamp: Date

    /// Whether this error is recoverable
    let isRecoverable: Bool

    /// Suggested recovery action for the user
    let recoverySuggestion: String?

    /// Safe provider category, when the error originated from a provider.
    let providerCategory: ProviderErrorCategory?

    /// Recovery actions that the app can safely offer for this error.
    let recoveryActions: [ProviderRecoveryAction]

    /// Context information (file, line, function)
    let context: ErrorContext?

    /// Server-advertised retry delay (from a `Retry-After` response header),
    /// when the error originated from a rate-limited or throttled HTTP
    /// response. `nil` when no such hint was present.
    let retryAfter: TimeInterval?

    /// HTTP status code, when the error originated from an HTTP response.
    /// `nil` when the error has no associated HTTP response (e.g. a
    /// connection failure that never reached the server).
    let statusCode: Int?

    // MARK: - Initialization

    init(
        code: ErrorCode,
        message: String,
        technicalDetails: String? = nil,
        underlyingError: Error? = nil,
        isRecoverable: Bool = true,
        recoverySuggestion: String? = nil,
        providerCategory: ProviderErrorCategory? = nil,
        recoveryActions: [ProviderRecoveryAction] = [],
        retryAfter: TimeInterval? = nil,
        statusCode: Int? = nil,
        file: String = #file,
        line: Int = #line,
        function: String = #function
    ) {
        self.code = code
        self.message = SensitiveDataRedactor.redact(message)
        self.technicalDetails =
            technicalDetails.map { SensitiveDataRedactor.redact($0) }
        self.underlyingError = underlyingError.map {
            RedactedUnderlyingError(
                safeDescription:
                    SensitiveDataRedactor.redact(error: $0)
            )
        }
        self.timestamp = Date()
        self.isRecoverable = isRecoverable
        self.recoverySuggestion =
            recoverySuggestion.map {
                SensitiveDataRedactor.redact($0)
            }
        self.providerCategory = providerCategory
        self.recoveryActions = recoveryActions
        self.retryAfter = retryAfter
        self.statusCode = statusCode
        self.context = ErrorContext(
            file: (file as NSString).lastPathComponent,
            line: line,
            function: SensitiveDataRedactor.redact(function)
        )
    }

    // MARK: - LocalizedError

    var errorDescription: String? {
        return message
    }

    var failureReason: String? {
        return technicalDetails
    }

    var recoverySuggestionValue: String? {
        return recoverySuggestion
    }

    // MARK: - CustomStringConvertible

    var description: String {
        var desc = "[\(code.rawValue)] \(message)"
        if let details = technicalDetails {
            desc += "\nDetails: \(details)"
        }
        if let underlying = underlyingError {
            desc += "\nUnderlying: "
                + SensitiveDataRedactor.redact(
                    underlying.localizedDescription
                )
        }
        return desc
    }

    // MARK: - Support Information

    /// User-friendly error report for support tickets
    var supportReport: String {
        var report = """
        Error Code: \(code.rawValue)
        Message: \(message)
        Time: \(timestamp.formatted())
        Recoverable: \(isRecoverable ? "Yes" : "No")
        """

        if let details = technicalDetails {
            report += "\nTechnical Details: \(details)"
        }

        if let suggestion = recoverySuggestion {
            report += "\nSuggested Action: \(suggestion)"
        }

        if let context = context {
            report += "\nLocation: \(context.fileName):"
                + "\(context.line) in \(context.function)"
        }

        return SensitiveDataRedactor.redact(report)
    }

    /// Copy-friendly error code for users to report
    var copyableErrorCode: String {
        return "Error-\(code.rawValue)-\(Int(timestamp.timeIntervalSince1970))"
    }
}

// MARK: - Error Context

struct ErrorContext {
    let file: String
    let line: Int
    let function: String

    var fileName: String {
        return (file as NSString).lastPathComponent
    }
}

// MARK: - Error Codes

enum ErrorCode: String, CaseIterable {

    // MARK: - Session Key Errors (1000-1099)

    case sessionKeyNotFound = "E1000"
    case sessionKeyInvalid = "E1001"
    case sessionKeyExpired = "E1002"
    case sessionKeyTooShort = "E1003"
    case sessionKeyTooLong = "E1004"
    case sessionKeyInvalidPrefix = "E1005"
    case sessionKeyInvalidCharacters = "E1006"
    case sessionKeyInvalidFormat = "E1007"
    case sessionKeyMalicious = "E1008"
    case sessionKeyWhitespace = "E1009"
    case sessionKeyStorageFailed = "E1010"

    // MARK: - Network Errors (2000-2099)

    case networkUnavailable = "E2000"
    case networkTimeout = "E2001"
    case networkConnectionLost = "E2002"
    case networkDNSFailed = "E2003"
    case networkSSLFailed = "E2004"
    case networkGenericError = "E2099"

    // MARK: - API Errors (3000-3099)

    case apiUnauthorized = "E3000"
    /// The server knew who we were and refused the resource anyway (HTTP
    /// 403). Deliberately distinct from `apiUnauthorized` (401): 403 says
    /// nothing about the credential, and reporting it as an expired session
    /// key put a red "sign in again" marker on accounts whose sign-in was
    /// working — see `MenuBarAttentionSignal`.
    case apiForbidden = "E3008"
    case apiInvalidResponse = "E3001"
    case apiServerError = "E3002"
    case apiRateLimited = "E3003"
    case apiNotFound = "E3004"
    case apiBadRequest = "E3005"
    case apiServiceUnavailable = "E3006"
    case apiParsingFailed = "E3007"
    case apiGenericError = "E3099"

    // MARK: - URL Construction Errors (4000-4099)

    case urlInvalidBase = "E4000"
    case urlInvalidPath = "E4001"
    case urlInvalidQuery = "E4002"
    case urlMalformed = "E4003"
    case urlPathTraversal = "E4004"

    // MARK: - Data Storage Errors (5000-5099)

    case storageReadFailed = "E5000"
    case storageWriteFailed = "E5001"
    case storageEncodingFailed = "E5002"
    case storageDecodingFailed = "E5003"
    case storagePermissionDenied = "E5004"
    case storageFileNotFound = "E5005"
    case credentialStorageUnavailable = "E5006"
    case credentialStorageFailed = "E5007"

    // MARK: - GitHub API Errors (6000-6099)

    case githubRateLimited = "E6000"
    case githubNotFound = "E6001"
    case githubServerError = "E6002"
    case githubGenericError = "E6099"

    // MARK: - Provider Errors (7000-7099)

    case providerExecutableMissing = "E7000"
    case providerLaunchFailed = "E7001"
    case providerTimedOut = "E7002"
    case providerCancelled = "E7003"
    case providerIncompatible = "E7004"
    case providerMalformedResponse = "E7005"
    case providerInvalidHome = "E7006"
    case providerDuplicateHome = "E7007"
    case providerLoggedOut = "E7008"
    case providerUnsupportedAccount = "E7009"
    case providerPartialUsage = "E7010"
    case providerTransientFailure = "E7011"

    // MARK: - Unknown Errors (9000-9999)

    case unknown = "E9999"

    // MARK: - Helpers

    var category: ErrorCategory {
        let prefix = String(rawValue.prefix(2))
        switch prefix {
        case "E1": return .sessionKey
        case "E2": return .network
        case "E3": return .api
        case "E4": return .urlConstruction
        case "E5": return .dataStorage
        case "E6": return .github
        case "E7": return .provider
        default: return .unknown
        }
    }
}

// MARK: - Error Category

enum ErrorCategory: String {
    case sessionKey = "Session Key"
    case network = "Network"
    case api = "API"
    case urlConstruction = "URL Construction"
    case dataStorage = "Data Storage"
    case github = "GitHub"
    case provider = "Provider"
    case unknown = "Unknown"
}

private struct RedactedUnderlyingError: LocalizedError {
    let safeDescription: String

    var errorDescription: String? { safeDescription }
}

// MARK: - Convenience Constructors

extension AppError {

    // MARK: - Session Key Errors

    static func sessionKeyNotFound(file: String = #file, line: Int = #line, function: String = #function) -> AppError {
        return AppError(
            code: .sessionKeyNotFound,
            message: "error.session_key_not_found".localized,
            technicalDetails: "Session key file does not exist at expected path",
            isRecoverable: true,
            recoverySuggestion: "error.session_key_not_found.suggestion".localized,
            file: file,
            line: line,
            function: function
        )
    }

    static func sessionKeyInvalid(reason: String, file: String = #file, line: Int = #line, function: String = #function) -> AppError {
        return AppError(
            code: .sessionKeyInvalid,
            message: "error.session_key_invalid".localized,
            technicalDetails: reason,
            isRecoverable: true,
            recoverySuggestion: "error.session_key_invalid.suggestion".localized,
            file: file,
            line: line,
            function: function
        )
    }

    // MARK: - Network Errors

    static func networkUnavailable(file: String = #file, line: Int = #line, function: String = #function) -> AppError {
        return AppError(
            code: .networkUnavailable,
            message: "error.network_unavailable".localized,
            technicalDetails: "Network is unreachable",
            isRecoverable: true,
            recoverySuggestion: "error.network_unavailable.suggestion".localized,
            file: file,
            line: line,
            function: function
        )
    }

    static func networkTimeout(file: String = #file, line: Int = #line, function: String = #function) -> AppError {
        return AppError(
            code: .networkTimeout,
            message: "error.network_timeout".localized,
            technicalDetails: "The server did not respond in time",
            isRecoverable: true,
            recoverySuggestion: "error.network_timeout.suggestion".localized,
            file: file,
            line: line,
            function: function
        )
    }

    // MARK: - API Errors

    static func apiUnauthorized(file: String = #file, line: Int = #line, function: String = #function) -> AppError {
        return AppError(
            code: .apiUnauthorized,
            message: "error.api_unauthorized".localized,
            technicalDetails: "API returned 401 - session key may be expired or invalid",
            isRecoverable: true,
            recoverySuggestion: "error.api_unauthorized.suggestion".localized,
            file: file,
            line: line,
            function: function
        )
    }

    /// HTTP 403. The credential was accepted and the resource was refused.
    ///
    /// Kept apart from `apiUnauthorized` because the two need opposite
    /// things from the reader: a 401 asks them to sign in again, a 403 asks
    /// them to do nothing at all. Folding 403 into 401 is what made the menu
    /// bar tell people their working sign-in had been rejected, so the
    /// recovery suggestion here deliberately says no action is needed.
    ///
    /// One 403 body is the exception and must never reach this constructor:
    /// claude.ai reports a dead browser session as 403
    /// `account_session_invalid`, which *is* a statement about the
    /// credential. `ClaudeAISessionRefusal` reads the body and routes that
    /// one to `claudeAISessionExpired` instead.
    static func apiForbidden(
        statusDetail: String? = nil,
        file: String = #file,
        line: Int = #line,
        function: String = #function
    ) -> AppError {
        return AppError(
            code: .apiForbidden,
            message: "error.api_forbidden".localized,
            technicalDetails: statusDetail
                ?? "API returned 403 - the credential is valid but this "
                + "resource is not permitted for this account",
            isRecoverable: true,
            recoverySuggestion: "error.api_forbidden.suggestion".localized,
            statusCode: 403,
            file: file,
            line: line,
            function: function
        )
    }

    /// The claude.ai browser session key has stopped working.
    ///
    /// Carries `sessionKeyExpired` even though the wire status is 403,
    /// because the code is what every downstream surface reads: it is what
    /// makes the refresh boundary call the account unauthenticated, which is
    /// what lights the menu bar's credential marker and names the browser
    /// sign-in as the broken one. The status code is kept at 403 so logs
    /// still say what the server actually answered.
    ///
    /// The wording is the existing expired-credential wording on purpose —
    /// this is the same fact people have always been told, arriving now from
    /// the status code that really reports it.
    static func claudeAISessionExpired(
        statusDetail: String? = nil,
        file: String = #file,
        line: Int = #line,
        function: String = #function
    ) -> AppError {
        return AppError(
            code: .sessionKeyExpired,
            message: "error.api_unauthorized".localized,
            technicalDetails: statusDetail
                ?? "claude.ai returned 403 account_session_invalid - the "
                + "browser session key is no longer valid",
            isRecoverable: true,
            recoverySuggestion: "error.api_unauthorized.suggestion".localized,
            statusCode: 403,
            file: file,
            line: line,
            function: function
        )
    }

    static func apiServerError(statusCode: Int, file: String = #file, line: Int = #line, function: String = #function) -> AppError {
        return AppError(
            code: .apiServerError,
            message: "error.api_server_error".localized,
            technicalDetails: "HTTP \(statusCode)",
            isRecoverable: true,
            recoverySuggestion: "error.api_server_error.suggestion".localized,
            file: file,
            line: line,
            function: function
        )
    }

    static func apiRateLimited(
        retryAfter: TimeInterval? = nil,
        file: String = #file,
        line: Int = #line,
        function: String = #function
    ) -> AppError {
        return AppError(
            code: .apiRateLimited,
            message: "error.api_rate_limited".localized,
            technicalDetails: "Too many requests to the API",
            isRecoverable: true,
            recoverySuggestion: "error.api_rate_limited.suggestion".localized,
            retryAfter: retryAfter,
            file: file,
            line: line,
            function: function
        )
    }

    // MARK: - Storage Errors

    @MainActor
    static func storageWriteFailed(
        file: String = #file,
        line: Int = #line,
        function: String = #function
    ) -> AppError {
        AppError(
            code: .storageWriteFailed,
            message: "error.storage_write_failed".localized,
            technicalDetails:
                "Usage persistence transaction was rejected",
            isRecoverable: true,
            recoverySuggestion:
                "error.storage_write_failed.suggestion".localized,
            file: file,
            line: line,
            function: function
        )
    }

    // MARK: - Credential Storage Errors

    /// macOS refused Keychain access outright, so no credential can be saved
    /// until the install itself is fixed.
    static func credentialStorageUnavailable(
        technicalDetails: String,
        file: String = #file,
        line: Int = #line,
        function: String = #function
    ) -> AppError {
        AppError(
            code: .credentialStorageUnavailable,
            message: "error.credential_storage_unavailable".localized,
            technicalDetails: technicalDetails,
            isRecoverable: false,
            recoverySuggestion:
                "error.credential_storage_unavailable.suggestion".localized,
            // ErrorPresenter only auto-injects an action for the sessionKey
            // and api categories, so a dataStorage alert would otherwise
            // offer the user nothing to do.
            recoveryActions: [.openSettings],
            file: file,
            line: line,
            function: function
        )
    }

    /// A credential write failed for a reason that may clear on retry.
    static func credentialStorageFailed(
        technicalDetails: String,
        file: String = #file,
        line: Int = #line,
        function: String = #function
    ) -> AppError {
        AppError(
            code: .credentialStorageFailed,
            message: "error.credential_storage_failed".localized,
            technicalDetails: technicalDetails,
            isRecoverable: true,
            recoverySuggestion:
                "error.credential_storage_failed.suggestion".localized,
            recoveryActions: [.openSettings],
            file: file,
            line: line,
            function: function
        )
    }

    // MARK: - Wrapping Errors

    static func wrap(
        _ error: Error,
        providerID: ProviderID? = nil,
        file: String = #file,
        line: Int = #line,
        function: String = #function
    ) -> AppError {
        // If already an AppError, return as-is
        if let appError = error as? AppError {
            return appError
        }

        // Credential storage failures used to surface as E9999 with the
        // internal transaction wording, which told the user nothing about
        // what had gone wrong or what to do next.
        if let credentialError = fromCredentialStorageError(
            error,
            file: file,
            line: line,
            function: function
        ) {
            return credentialError
        }

        if let presentation = ProviderErrorMapper.presentation(
            for: error,
            providerID: providerID
        ) {
            return provider(
                presentation,
                file: file,
                line: line,
                function: function
            )
        }

        // If it's a SessionKeyValidationError, convert it
        if let validationError = error as? SessionKeyValidationError {
            return fromSessionKeyValidationError(validationError, file: file, line: line, function: function)
        }

        // If it's a URLBuilderError, convert it
        if let urlError = error as? URLBuilderError {
            return fromURLBuilderError(urlError, file: file, line: line, function: function)
        }

        // Generic wrap
        return AppError(
            code: .unknown,
            message: error.localizedDescription,
            technicalDetails: "\(type(of: error)): \(error)",
            underlyingError: error,
            isRecoverable: true,
            file: file,
            line: line,
            function: function
        )
    }

    static func provider(
        _ presentation: ProviderErrorPresentation,
        file: String = #file,
        line: Int = #line,
        function: String = #function
    ) -> AppError {
        AppError(
            code: presentation.category.errorCode,
            message: presentation.title,
            technicalDetails: presentation.explanation,
            isRecoverable: presentation.isRecoverable,
            recoverySuggestion: presentation.explanation,
            providerCategory: presentation.category,
            recoveryActions: presentation.actions,
            file: file,
            line: line,
            function: function
        )
    }

    // MARK: - Conversion from Other Errors

    /// Maps every error that means "the credential could not be stored" onto a
    /// coded, actionable `AppError`. Returns `nil` for unrelated errors.
    private static func fromCredentialStorageError(
        _ error: Error,
        file: String,
        line: Int,
        function: String
    ) -> AppError? {
        if let keychainError = error as? KeychainError {
            let details = keychainError.errorDescription
                ?? "Keychain operation failed"
            return keychainError.isMissingEntitlement
                ? credentialStorageUnavailable(
                    technicalDetails: details,
                    file: file,
                    line: line,
                    function: function
                )
                : credentialStorageFailed(
                    technicalDetails: details,
                    file: file,
                    line: line,
                    function: function
                )
        }

        if let secretStoreError = error as? ProfileSecretStoreError {
            return credentialStorageFailed(
                technicalDetails: secretStoreError.errorDescription
                    ?? "Keychain verification failed",
                file: file,
                line: line,
                function: function
            )
        }

        guard let storeError = error as? ProfileStoreError else {
            return nil
        }
        switch storeError {
        case .credentialReadUnresolved,
             .credentialTransactionFailed,
             .credentialRollbackFailed,
             .credentialUsageUnlinkFailed,
             .credentialUsageUnlinkRollbackFailed,
             .credentialUsageUnlinkMarkerVerificationFailed:
            return credentialStorageFailed(
                technicalDetails: storeError.errorDescription
                    ?? "Credential transaction failed",
                file: file,
                line: line,
                function: function
            )
        case .profileNotFound,
             .profileDeletionInProgress,
             .currentUsageCommitRollbackFailed,
             .profileWriteVerificationFailed,
             .profileRestoreVerificationFailed:
            return nil
        }
    }

    private static func fromSessionKeyValidationError(_ error: SessionKeyValidationError, file: String, line: Int, function: String) -> AppError {
        switch error {
        case .empty:
            return sessionKeyNotFound(file: file, line: line, function: function)
        case .tooShort(let min, let actual):
            return AppError(code: .sessionKeyTooShort, message: "Session key too short", technicalDetails: "Min: \(min), Actual: \(actual)", file: file, line: line, function: function)
        case .tooLong(let max, let actual):
            return AppError(code: .sessionKeyTooLong, message: "Session key too long", technicalDetails: "Max: \(max), Actual: \(actual)", file: file, line: line, function: function)
        case .invalidPrefix:
            return AppError(code: .sessionKeyInvalidPrefix, message: "Invalid session key prefix", file: file, line: line, function: function)
        case .invalidCharacters:
            return AppError(code: .sessionKeyInvalidCharacters, message: "Invalid characters in session key", file: file, line: line, function: function)
        case .invalidFormat:
            return AppError(code: .sessionKeyInvalidFormat, message: "Invalid session key format", file: file, line: line, function: function)
        case .potentiallyMalicious:
            return AppError(code: .sessionKeyMalicious, message: "Potentially malicious session key", file: file, line: line, function: function)
        case .containsWhitespace:
            return AppError(code: .sessionKeyWhitespace, message: "Session key contains whitespace", file: file, line: line, function: function)
        }
    }

    private static func fromURLBuilderError(_ error: URLBuilderError, file: String, line: Int, function: String) -> AppError {
        switch error {
        case .invalidBaseURL(let url):
            return AppError(code: .urlInvalidBase, message: "Invalid base URL", technicalDetails: url, file: file, line: line, function: function)
        case .invalidPath(let path):
            return AppError(code: .urlInvalidPath, message: "Invalid URL path", technicalDetails: path, file: file, line: line, function: function)
        case .invalidQueryParameter(let key, let value):
            return AppError(code: .urlInvalidQuery, message: "Invalid query parameter", technicalDetails: "\(key)=\(value)", file: file, line: line, function: function)
        case .malformedURL(let details):
            return AppError(code: .urlMalformed, message: "Malformed URL", technicalDetails: details, file: file, line: line, function: function)
        }
    }
}

private extension ProviderErrorCategory {
    var errorCode: ErrorCode {
        switch self {
        case .missingExecutable:
            return .providerExecutableMissing
        case .launchFailure:
            return .providerLaunchFailed
        case .timeout:
            return .providerTimedOut
        case .cancellation:
            return .providerCancelled
        case .incompatibleAppServer:
            return .providerIncompatible
        case .malformedResponse:
            return .providerMalformedResponse
        case .invalidHome:
            return .providerInvalidHome
        case .duplicateHome:
            return .providerDuplicateHome
        case .loggedOut:
            return .providerLoggedOut
        case .unsupportedAccount:
            return .providerUnsupportedAccount
        case .partialUsage:
            return .providerPartialUsage
        case .transientFailure:
            return .providerTransientFailure
        }
    }
}
