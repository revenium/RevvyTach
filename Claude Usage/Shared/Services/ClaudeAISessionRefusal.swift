//
//  ClaudeAISessionRefusal.swift
//  Claude Usage
//
//  Reads a claude.ai HTTP 403 body and decides whether the refusal is about
//  the browser session cookie itself.
//

import Foundation

/// claude.ai reports a dead browser session as **403**, not 401.
///
/// Every request made with a `sessionKey` cookie that has been revoked or has
/// expired — `GET /api/organizations` and `/api/organizations/<id>/usage`
/// included — comes back as:
///
/// ```
/// HTTP 403
/// {"type":"error","error":{"type":"permission_error",
///  "message":"Invalid authorization",
///  "details":{"error_code":"account_session_invalid",
///             "error_visibility":"user_facing"}},"request_id":null}
/// ```
///
/// The rule that every 403 is a statement about the *resource* and never
/// about the credential is right for every other body claude.ai sends, and it
/// is what stopped the menu bar accusing working sign-ins. It is wrong for
/// this one body, and the cost of getting it wrong is the worse half of the
/// same bug: the account is signed out, the menu bar says nothing, Settings
/// says the browser sign-in is "Working", and the last good reading is held
/// on screen for as long as it takes someone to notice the numbers stopped
/// moving.
///
/// So the status code alone cannot decide this — only the body can. The
/// classification lives here, in one place, so both claude.ai request paths
/// ask exactly the same question and cannot drift apart.
enum ClaudeAISessionRefusal {
    /// The machine-readable code claude.ai puts in `error.details` when the
    /// session cookie is no longer usable.
    static let deadSessionErrorCode = "account_session_invalid"

    /// claude.ai's error envelope. Only the fields this decision reads are
    /// modelled; every one of them is optional, because a 403 body that is
    /// HTML, empty, or some future shape must decode without throwing and
    /// simply fail to match.
    private struct Envelope: Decodable {
        struct Failure: Decodable {
            struct Details: Decodable {
                let errorCode: String?

                enum CodingKeys: String, CodingKey {
                    case errorCode = "error_code"
                }
            }

            let type: String?
            let message: String?
            let details: Details?
        }

        let error: Failure?
    }

    /// Whether a 403 body is claude.ai saying the browser session is dead.
    ///
    /// The primary signal is the machine-readable
    /// `error.details.error_code` — it is the field claude.ai intends to be
    /// read. The secondary signal, a `permission_error` whose message is
    /// "Invalid authorization", is accepted because the same refusal has been
    /// observed without the `details` object, and because a dead session
    /// reported as "nothing to do here" is the failure that hides for a day.
    ///
    /// Anything else — a permission refusal about a resource, an HTML error
    /// page, an empty body — is not a statement about the credential and must
    /// keep the settled 403 behaviour.
    static func isDeadBrowserSession(responseBody: Data?) -> Bool {
        guard let responseBody, !responseBody.isEmpty else { return false }
        guard
            let envelope = try? JSONDecoder().decode(
                Envelope.self,
                from: responseBody
            ),
            let failure = envelope.error
        else {
            return false
        }

        if failure.details?.errorCode == deadSessionErrorCode {
            return true
        }

        // Secondary signal. Both halves are required: `permission_error`
        // alone is the ordinary resource refusal this must not swallow.
        let message = failure.message?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return failure.type == "permission_error"
            && message == "invalid authorization"
    }

    /// Convenience for callers and tests holding the body as text.
    static func isDeadBrowserSession(responseBody: String) -> Bool {
        isDeadBrowserSession(responseBody: Data(responseBody.utf8))
    }

    /// The error to throw for an HTTP 403 on a request authenticated with a
    /// claude.ai session key.
    ///
    /// - Parameters:
    ///   - endpoint: named in the technical details, so a log line says which
    ///     request was refused.
    ///   - responseBody: the raw 403 body; the only thing that can tell the
    ///     two refusals apart.
    ///   - forbiddenDetail: the technical detail for the ordinary refusal —
    ///     the case where the credential was accepted and the resource was
    ///     not served.
    static func error(
        endpoint: String,
        responseBody: Data?,
        forbiddenDetail: String
    ) -> AppError {
        let preview = bodyPreview(responseBody)

        guard isDeadBrowserSession(responseBody: responseBody) else {
            return AppError.apiForbidden(statusDetail: forbiddenDetail)
        }

        return AppError.claudeAISessionExpired(
            statusDetail: "Endpoint: \(endpoint)\nStatus: 403\n"
                + "Response: \(preview)"
        )
    }

    /// First 200 characters of the body, matching the preview length the
    /// other status branches use.
    static func bodyPreview(_ responseBody: Data?) -> String {
        guard
            let responseBody,
            let text = String(data: responseBody, encoding: .utf8)
        else {
            return "Unable to read response"
        }
        return String(text.prefix(200))
    }
}
