import Foundation

/// Safe categories only. Provider bodies, messages and credential values are never persisted.
public enum ServiceFailureKind: String, Codable, Sendable, Equatable {
    case credentialMissing, credentialLocked, invalidCredential, accessDenied, configuration, insufficientCredits, billingLimit, rateLimited
    case unavailable, invalidResponse, invalidHints, tooLarge, storage
    public var allowsRecoveryAfterRemedy: Bool {
        switch self {
        case .credentialMissing, .credentialLocked, .invalidCredential, .accessDenied, .configuration, .insufficientCredits, .billingLimit: return true
        default: return false
        }
    }
}

public struct DictationFormatResult: Sendable, Equatable {
    public let text: String
    public let failure: ServiceFailureKind?
    public init(text: String, failure: ServiceFailureKind? = nil) { self.text = text; self.failure = failure }
}

extension ProviderError {
    public var failureKind: ServiceFailureKind? {
        switch self {
        case .authentication: return .invalidCredential
        case .accessDenied: return .accessDenied
        case .insufficientCredits: return .insufficientCredits
        case .billingLimit: return .billingLimit
        case .quota: return .rateLimited
        case .unavailable: return .unavailable
        case .invalidResponse: return .invalidResponse
        case .invalidHints: return .invalidHints
        case .configuration: return .configuration
        case .tooLarge: return .tooLarge
        case .cacheWrite: return .storage
        case .rejected: return .accessDenied
        case .cancelled: return nil
        }
    }
}

func classifiedProviderError(status: Int, body: Data) -> ProviderError {
    struct Envelope: Decodable {
        struct Detail: Decodable { let code: String?; let type: String? }
        let error: Detail
    }
    let detail = body.count <= 16_384 ? (try? JSONDecoder().decode(Envelope.self, from: body))?.error : nil
    switch detail?.code {
    case "credit_balance_exhausted": return .insufficientCredits
    case "project_spend_limit_exceeded", "organization_spend_limit_exceeded", "organization_usage_limit_exceeded", "insufficient_quota", "billing_hard_limit_reached": return .billingLimit
    case "rate_limit_exceeded", "slow_down": return .quota
    case "invalid_api_key", "not_authenticated": return .authentication
    case "account_deactivated", "permission_denied", "access_denied", "model_not_allowed", "model_not_found": return .accessDenied
    case "invalid_value", "invalid_request", "invalid_config": return .configuration
    default: break
    }
    if detail?.type == "insufficient_quota" { return .billingLimit }
    if detail?.type == "authentication_error" { return .authentication }
    if detail?.type == "permission_error" { return .accessDenied }
    if detail?.type == "invalid_request_error" { return .configuration }
    switch status {
    case 400, 422: return .configuration
    case 401: return .authentication
    case 403: return .accessDenied
    case 413: return .tooLarge
    case 429: return .quota
    case 500...599: return .unavailable
    default: return .rejected(status)
    }
}
