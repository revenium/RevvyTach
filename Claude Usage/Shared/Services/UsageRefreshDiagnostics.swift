import Foundation
import UsageCore

nonisolated enum UsageRefreshDiagnostics {
    enum Event: String {
        case captureFailed = "capture_failed"
        case backoffSkipped = "backoff_skipped"
        case providerFailed = "provider_failed"
        case superseded
        case retired
    }

    enum Phase: String {
        case capture
        case queued
        case fetching
        case committing
    }

    static func message(
        _ event: Event,
        identity: ProviderRefreshIdentity,
        trigger: UsageRefreshTrigger,
        requestedAt: Date,
        now: Date,
        phase: Phase,
        failureKind: ProviderRefreshFailureKind? = nil,
        watchdogTimeout: Bool = false,
        consecutiveCount: Int,
        nextRetryAt: Date? = nil
    ) -> String {
        let provider = identity.providerID == .codex
            ? "codex"
            : identity.providerID == .claude ? "claude" : "unknown"
        let age = max(0, now.timeIntervalSince(requestedAt))
        let kind = failureKind.map { String(describing: $0) } ?? "none"
        let retry = nextRetryAt.map {
            String($0.timeIntervalSince1970)
        } ?? "none"
        return "Usage refresh event=\(event.rawValue) provider=\(provider) "
            + "profile=\(identity.profileID.uuidString) trigger=\(trigger.rawValue) "
            + "request_age_seconds=\(age) phase=\(phase.rawValue) "
            + "failure_kind=\(kind) timeout_stage=\(watchdogTimeout ? "watchdog" : "unknown") "
            + "consecutive_count=\(consecutiveCount) next_retry_at=\(retry)"
    }
}

nonisolated enum UsageRefreshBackoffPolicy {
    static let codexMaximumWindow: TimeInterval = 5 * 60
    static let claudeMaximumWindow: TimeInterval = 30 * 60

    static func maximumWindow(
        for providerID: ProviderID,
        configuredMaximum: TimeInterval
    ) -> TimeInterval {
        providerID == .codex
            ? min(codexMaximumWindow, configuredMaximum)
            : configuredMaximum
    }
}
