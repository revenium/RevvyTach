//
//  ClaudeAISessionRefusalTests.swift
//  Claude UsageTests
//
//  A dead claude.ai browser session is answered 403, not 401.
//

import Foundation
import UsageCore
import XCTest
@testable import Claude_Usage

/// v4.1.2 made every HTTP 403 mean "the credential is fine, this account may
/// not read that", which stopped the menu bar accusing working sign-ins. It
/// also created the opposite failure, because claude.ai answers a **dead
/// session key** with 403 as well: the account was signed out, the menu bar
/// said nothing, Settings said the browser sign-in was Working, and a reading
/// from the previous day stayed frozen on screen.
///
/// The body is the only thing that separates the two, so these pin the body
/// rule — captured verbatim from claude.ai on 2026-08-29 — and then follow it
/// out to the surface that has to change: the credential marker.
final class ClaudeAISessionRefusalTests: XCTestCase {
    /// The exact 403 body claude.ai returns for a revoked or expired
    /// `sessionKey` cookie, on `/api/organizations` and on
    /// `/api/organizations/<id>/usage` alike.
    private static let deadSessionBody = """
    {"type":"error","error":{"type":"permission_error",\
    "message":"Invalid authorization","details":\
    {"error_code":"account_session_invalid",\
    "error_visibility":"user_facing"}},"request_id":null}
    """

    /// A permission refusal about a resource. The session is alive; this is
    /// the body the settled 403 behaviour exists for.
    private static let resourceRefusalBody = """
    {"type":"error","error":{"type":"permission_error",\
    "message":"This organization is not permitted to read usage",\
    "details":{"error_code":"organization_not_permitted"}},\
    "request_id":"req_1"}
    """

    // MARK: - The classifier

    func testTheLiveDeadSessionBodyIsClassifiedAsADeadSession() {
        XCTAssertTrue(
            ClaudeAISessionRefusal.isDeadBrowserSession(
                responseBody: Self.deadSessionBody
            )
        )
    }

    /// The machine-readable code is the primary signal, so it decides even
    /// when the message text is one nobody has seen yet.
    func testTheErrorCodeAloneIsEnough() {
        XCTAssertTrue(
            ClaudeAISessionRefusal.isDeadBrowserSession(
                responseBody: """
                {"error":{"type":"authentication_error",\
                "message":"Some future wording",\
                "details":{"error_code":"account_session_invalid"}}}
                """
            )
        )
    }

    /// The same refusal has been served without the `details` object. A dead
    /// session read as "nothing to do here" is the failure that hides for a
    /// day, so the message is accepted as a secondary signal.
    func testPermissionErrorSayingInvalidAuthorizationCountsWithoutDetails() {
        XCTAssertTrue(
            ClaudeAISessionRefusal.isDeadBrowserSession(
                responseBody: """
                {"error":{"type":"permission_error",\
                "message":"Invalid authorization"}}
                """
            )
        )
    }

    /// Both halves of the secondary signal are required. `permission_error`
    /// on its own is the ordinary resource refusal, and swallowing it would
    /// reintroduce the bug v4.1.2 fixed.
    func testAResourceRefusalIsNotADeadSession() {
        XCTAssertFalse(
            ClaudeAISessionRefusal.isDeadBrowserSession(
                responseBody: Self.resourceRefusalBody
            )
        )
    }

    func testBodiesThatCarryNoVerdictAreNotDeadSessions() {
        let notDeadSessions = [
            "<html><body>403 Forbidden</body></html>",
            "",
            "{}",
            "{\"error\":\"forbidden\"}",
            "Forbidden"
        ]
        for body in notDeadSessions {
            XCTAssertFalse(
                ClaudeAISessionRefusal.isDeadBrowserSession(
                    responseBody: body
                ),
                "\(body) says nothing about the session key and must not "
                    + "be read as a rejected credential"
            )
        }
    }

    func testAnAbsentBodyIsNotADeadSession() {
        XCTAssertFalse(
            ClaudeAISessionRefusal.isDeadBrowserSession(responseBody: nil)
        )
    }

    // MARK: - The error the classifier builds

    func testADeadSessionBodyProducesAnExpiredCredentialError() {
        let error = ClaudeAISessionRefusal.error(
            endpoint: "/organizations",
            responseBody: Data(Self.deadSessionBody.utf8),
            forbiddenDetail: "unused"
        )

        XCTAssertEqual(error.code, .sessionKeyExpired)
        XCTAssertNotEqual(
            error.code,
            .apiForbidden,
            "a dead session key must never be described as a permission "
                + "refusal the reader can ignore"
        )
        XCTAssertTrue(error.isRecoverable)
        // The wire status is kept so logs still say what was answered.
        XCTAssertEqual(error.statusCode, 403)
        XCTAssertTrue(
            error.technicalDetails?.contains("account_session_invalid")
                == true,
            "the body that decided this belongs in the details"
        )
        XCTAssertTrue(
            error.technicalDetails?.contains("/organizations") == true
        )
    }

    func testEveryOther403KeepsTheSettledForbiddenBehaviour() {
        let error = ClaudeAISessionRefusal.error(
            endpoint: "/organizations/org-1/usage",
            responseBody: Data(Self.resourceRefusalBody.utf8),
            forbiddenDetail: "Usage refused (HTTP 403)"
        )

        XCTAssertEqual(error.code, .apiForbidden)
        XCTAssertEqual(error.statusCode, 403)
        XCTAssertEqual(error.technicalDetails, "Usage refused (HTTP 403)")
    }

    // MARK: - Out to the credential marker

    /// The error code is what the refresh boundary reads, and
    /// `.unauthenticated` is the only kind that raises a credential marker.
    func testAnExpiredSessionKeyIsAnUnauthenticatedRefreshFailure() {
        XCTAssertEqual(
            UsageRefreshEngine.refreshFailureKind(for: .sessionKeyExpired),
            .unauthenticated
        )
        XCTAssertTrue(
            ProviderRefreshFailure(
                kind: .unauthenticated,
                occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
                isRecoverable: true,
                consecutiveCount: 2
            ).isCredentialFailure
        )
    }

    /// The other half of the rule, unchanged: a resource refusal still
    /// carries no credential marker.
    func testAForbiddenResourceStaysAnUnsupportedAccount() {
        XCTAssertEqual(
            UsageRefreshEngine.refreshFailureKind(for: .apiForbidden),
            .unsupportedAccount
        )
    }

    /// The marker has to name the browser sign-in, not the terminal one.
    /// They are repaired on different screens, so a verdict that says only
    /// "sign-in" sends half the people who read it to the wrong place.
    @MainActor
    func testTheMarkerNamesTheBrowserSignIn() {
        // Two rejections in a row: one is the blip the threshold absorbs.
        XCTAssertEqual(
            MenuBarAttentionSignal.attention(
                cliSignInIssue: nil,
                credentialFailureStreak: 2,
                healthStatus: .unauthenticated
            ),
            .claudeAI
        )
        XCTAssertNotEqual(
            MenuBarAttentionSignal.attention(
                cliSignInIssue: nil,
                credentialFailureStreak: 2,
                healthStatus: .unauthenticated
            ),
            .claudeCode
        )
    }

    /// The wording behind that marker, on the surface a person reads.
    @MainActor
    func testThePopoverNamesTheClaudeAISignIn() {
        XCTAssertEqual(
            ProviderPopoverHeader.accountHealthText(
                status: .degraded,
                issue: .authenticationRequired,
                credential: .claudeAI
            ),
            "Claude.ai sign-in needs attention"
        )
    }

    // MARK: - Through a real request

    /// The whole path, from the wire answer to the thrown error. The live
    /// account that produced this bug was refused exactly this way on the
    /// organization list, which is the first request every refresh makes.
    @MainActor
    func testAForbiddenOrganizationListWithADeadSessionBodyReadsAsExpired()
        async throws {
        StubForbiddenOrganizationsURLProtocol.responseBody =
            Data(Self.deadSessionBody.utf8)
        URLProtocol.registerClass(
            StubForbiddenOrganizationsURLProtocol.self
        )
        defer {
            URLProtocol.unregisterClass(
                StubForbiddenOrganizationsURLProtocol.self
            )
            StubForbiddenOrganizationsURLProtocol.responseBody = nil
        }

        do {
            let organizationId = try await makeIsolatedService()
                .fetchOrganizationId(
                    sessionKey: "sk-ant-sid01-fixture-session-key-value"
                )
            XCTFail("Expected a thrown error, got \(organizationId)")
        } catch let error as AppError {
            XCTAssertEqual(error.code, .sessionKeyExpired)
        }
    }

    /// And the refusal that is genuinely about the resource still comes back
    /// as one, on the same endpoint and the same status code.
    @MainActor
    func testAForbiddenOrganizationListWithAResourceBodyStaysForbidden()
        async throws {
        StubForbiddenOrganizationsURLProtocol.responseBody =
            Data(Self.resourceRefusalBody.utf8)
        URLProtocol.registerClass(
            StubForbiddenOrganizationsURLProtocol.self
        )
        defer {
            URLProtocol.unregisterClass(
                StubForbiddenOrganizationsURLProtocol.self
            )
            StubForbiddenOrganizationsURLProtocol.responseBody = nil
        }

        do {
            let organizationId = try await makeIsolatedService()
                .fetchOrganizationId(
                    sessionKey: "sk-ant-sid01-fixture-session-key-value"
                )
            XCTFail("Expected a thrown error, got \(organizationId)")
        } catch let error as AppError {
            XCTAssertEqual(error.code, .apiForbidden)
        }
    }

    @MainActor
    private func makeIsolatedService() throws -> ClaudeAPIService {
        let (defaults, suiteName) = try HostedTestDefaults.defaults(
            "ClaudeAISessionRefusalTests"
        )
        HostedTestDefaults.reset(defaults, suiteName: suiteName)
        addTeardownBlock {
            HostedTestDefaults.finish(defaults, suiteName: suiteName)
        }
        let store = makeIsolatedProfileStore(
            defaults: defaults,
            secretStore: IsolatedProfileSecrets()
        )
        // Deliberately not loaded: with no profiles there is no stored
        // organization to short-circuit the lookup under test.
        let manager = ProfileManager(profileStore: store)
        return makeIsolatedClaudeAPIService(
            profileManager: manager,
            store: store
        )
    }
}

/// Answers the `/organizations` request with a 403 and one canned body, the
/// way claude.ai answers a session key it no longer accepts.
private nonisolated final class StubForbiddenOrganizationsURLProtocol:
    URLProtocol {
    nonisolated(unsafe) static var responseBody: Data?

    override class func canInit(with request: URLRequest) -> Bool {
        responseBody != nil
            && request.url?.path.hasSuffix("/organizations") == true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        guard
            let url = request.url,
            let body = Self.responseBody,
            let response = HTTPURLResponse(
                url: url,
                statusCode: 403,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )
        else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badServerResponse)
            )
            return
        }

        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
