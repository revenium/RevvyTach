import Foundation

// MARK: - API Response Types

extension ClaudeAPIService {
    struct UsageResponse: Codable {
        let usage: [UsagePeriod]

        struct UsagePeriod: Codable {
            let period: String
            let usageType: String
            let inputTokens: Int
            let outputTokens: Int
            let cacheCreationTokens: Int?
            let cacheReadTokens: Int?

            enum CodingKeys: String, CodingKey {
                case period
                case usageType = "usage_type"
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
                case cacheCreationTokens = "cache_creation_tokens"
                case cacheReadTokens = "cache_read_tokens"
            }
        }
    }

    struct AccountInfo: Codable {
        let uuid: String
        let name: String
        let capabilities: [String]
        /// `"team"` / `"enterprise"` for shared organizations, absent for
        /// individual subscriptions and for console/API-only organizations.
        /// See `ClaudeOrganizationClassifier` for the observed values.
        let ravenType: String?

        enum CodingKeys: String, CodingKey {
            case uuid
            case name
            case capabilities
            case ravenType = "raven_type"
        }

        init(
            uuid: String,
            name: String,
            capabilities: [String],
            ravenType: String? = nil
        ) {
            self.uuid = uuid
            self.name = name
            self.capabilities = capabilities
            self.ravenType = ravenType
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            uuid = try container.decode(String.self, forKey: .uuid)
            name = try container.decode(String.self, forKey: .name)
            capabilities = try container.decodeIfPresent(
                [String].self,
                forKey: .capabilities
            ) ?? []
            ravenType = try container.decodeIfPresent(String.self, forKey: .ravenType)
        }
    }

    struct OverageSpendLimitResponse: Codable {
        let monthlyCreditLimit: Double?
        let currency: String?
        let usedCredits: Double?
        let isEnabled: Bool?

        enum CodingKeys: String, CodingKey {
            case monthlyCreditLimit = "monthly_credit_limit"
            case currency
            case usedCredits = "used_credits"
            case isEnabled = "is_enabled"
        }
    }

    /// `GET api.anthropic.com/api/oauth/usage`, authenticated with the CLI
    /// OAuth token. Unlike claude.ai's `overage_spend_limit` this describes
    /// the signed-in *member*: on the same team at the same moment the
    /// organization reported 26118 of 100000 while the member reported 0.0
    /// of 5000.
    struct OAuthUsageResponse: Codable {
        let extraUsage: ExtraUsage?

        enum CodingKeys: String, CodingKey {
            case extraUsage = "extra_usage"
        }

        struct ExtraUsage: Codable {
            let isEnabled: Bool?
            /// Minor currency units, like `OverageSpendLimitResponse`
            /// (5000 is $50.00).
            let monthlyLimit: Double?
            let usedCredits: Double?
            let currency: String?

            enum CodingKeys: String, CodingKey {
                case isEnabled = "is_enabled"
                case monthlyLimit = "monthly_limit"
                case usedCredits = "used_credits"
                case currency
            }
        }
    }

    /// `GET api.anthropic.com/api/oauth/profile`.
    ///
    /// The organization decides whether the CLI login's member figures
    /// describe the profile being displayed.
    ///
    /// The account is a *secondary* identity, read only to refine an answer
    /// the file on disk could not give. The primary source is
    /// `oauthAccount.accountUuid` in the bound account directory's
    /// `.claude.json`, which is known to be present — this field is not:
    /// nothing in this codebase has ever decoded it, so whether the endpoint
    /// carries it is unestablished. Optional for that reason, and a response
    /// without it changes nothing.
    struct OAuthProfileResponse: Codable {
        let organization: Organization?
        let account: Account?

        struct Organization: Codable {
            let uuid: String?
        }

        struct Account: Codable {
            let uuid: String?
        }
    }

    struct OverageCreditGrantResponse: Codable {
        let remainingBalance: Double?
        let currency: String?
        let totalGranted: Double?

        enum CodingKeys: String, CodingKey {
            case remainingBalance = "remaining_balance"
            case currency
            case totalGranted = "total_granted"
        }
    }

    struct CurrentSpendResponse: Codable {
        let amount: Int
        let resetsAt: String

        enum CodingKeys: String, CodingKey {
            case amount
            case resetsAt = "resets_at"
        }
    }

    struct PrepaidCreditsResponse: Codable {
        let amount: Int
        let currency: String
        let autoReloadSettings: AutoReloadSettings?

        enum CodingKeys: String, CodingKey {
            case amount
            case currency
            case autoReloadSettings = "auto_reload_settings"
        }

        struct AutoReloadSettings: Codable {
            let enabled: Bool?
            let threshold: Int?
            let reloadAmount: Int?
        }
    }

    struct ConsoleOrganization: Codable {
        let id: Int
        let uuid: String
        let name: String
    }

    struct UsageCostResponse: Codable {
        let costs: [String: [UsageCostEntry]]?
        let webSearchCosts: [String: [UsageCostEntry]]?
        let codeExecutionCosts: [String: [UsageCostEntry]]?

        enum CodingKeys: String, CodingKey {
            case costs
            case webSearchCosts = "web_search_costs"
            case codeExecutionCosts = "code_execution_costs"
        }
    }

    struct UsageCostEntry: Codable {
        let workspaceId: String?
        let keyId: String?
        let modelName: String?
        let total: Double?
        let tokenType: String?
        let usageType: String?

        enum CodingKeys: String, CodingKey {
            case workspaceId = "workspace_id"
            case keyId = "key_id"
            case modelName = "model_name"
            case total
            case tokenType = "token_type"
            case usageType = "usage_type"
        }

        var safeKeyId: String { keyId ?? "unknown" }
        var safeModelName: String { modelName ?? "Unknown" }
        var safeTotal: Double { total ?? 0 }
    }

    struct APIKeyInfo: Codable {
        let id: String
        let name: String
    }

    struct APIKeysResponse: Codable {
        let data: [APIKeyInfo]
    }

    enum APIError: Error, LocalizedError {
        case noSessionKey
        case invalidSessionKey
        case networkError(Error)
        case invalidResponse
        case unauthorized
        case serverError(statusCode: Int)

        var errorDescription: String? {
            switch self {
            case .noSessionKey:
                return "No session key found. Please configure your Claude session key."
            case .invalidSessionKey:
                return "Invalid session key format."
            case .networkError(let error):
                return "Network error: \(error.localizedDescription)"
            case .invalidResponse:
                return "Invalid response from Claude API."
            case .unauthorized:
                return "Unauthorized. Your session key may have expired."
            case .serverError(let code):
                return "Server error: HTTP \(code)"
            }
        }
    }
}
