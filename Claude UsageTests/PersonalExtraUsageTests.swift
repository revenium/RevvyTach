import Foundation
import XCTest
import UsageCore
@testable import Claude_Usage

/// The popover used to show only the organization's extra usage. These tests
/// pin the member's own figure beside it: the values it decodes, the guard
/// that refuses to show one context's number under another's label, and the
/// rule that a failed token renewal never touches a stored credential.
///
/// Every figure here is a real response captured from a Team member's account
/// on 2026-08-22.
@MainActor
final class PersonalExtraUsageTests: XCTestCase {

    /// The organization the maintainer's claude.ai session belongs to.
    private let teamOrganizationID = "665a6475-2eb6-4da8-8379-d5529d283568"
    /// A second organization, on the same email, holding a personal
    /// subscription. Its CLI login must never feed the team profile.
    private let personalOrganizationID = "ef142542-c027-47d7-9b93-80f8415554a9"

    override func tearDown() {
        StubClaudeEndpointsURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Decoding

    /// The live member response. `utilization` comes back null, so the
    /// percentage has to be computed from used and limit.
    func testMemberExtraUsageDecodesAsFiftyDollarsUnused() throws {
        let json = """
        {
            "extra_usage": {
                "is_enabled": true,
                "monthly_limit": 5000,
                "used_credits": 0.0,
                "utilization": null,
                "currency": "USD",
                "decimal_places": 2,
                "disabled_reason": null,
                "user_disabled": false,
                "spend_limit_reached": false,
                "credits_ever_enabled": true
            }
        }
        """

        let decoded = try JSONDecoder().decode(
            ClaudeAPIService.OAuthUsageResponse.self,
            from: Data(json.utf8)
        )
        let extraUsage = try XCTUnwrap(decoded.extraUsage)
        XCTAssertEqual(extraUsage.isEnabled, true)
        XCTAssertEqual(extraUsage.monthlyLimit, 5_000)
        XCTAssertEqual(extraUsage.usedCredits, 0)
        XCTAssertEqual(extraUsage.currency, "USD")

        var usage = ClaudeUsage.empty
        usage.personalCostUsed = extraUsage.usedCredits
        usage.personalCostLimit = extraUsage.monthlyLimit
        usage.personalCostCurrency = extraUsage.currency

        let window = try XCTUnwrap(
            try makeReport(from: usage)
                .limitGroups
                .first { $0.id.rawValue == "extra-usage" }?
                .windows
                .first
        )
        XCTAssertEqual(window.quantity?.limit, 50)
        XCTAssertEqual(window.quantity?.used, 0)
        XCTAssertEqual(window.usedPercentage, 0)
        XCTAssertEqual(window.quantity?.currencyCode?.rawValue, "USD")
    }

    /// A record written before the member figure existed decodes with no
    /// member figure — not with a zero, which would read as "you have spent
    /// nothing" rather than "we do not know".
    func testUsageRecordWithoutPersonalKeysDecodesWithNilPersonalFields() throws {
        let json = """
        {
            "sessionTokensUsed": 1250,
            "sessionLimit": 10000,
            "sessionPercentage": 12.5,
            "sessionResetTime": 20000,
            "weeklyTokensUsed": 480000,
            "weeklyLimit": 1000000,
            "weeklyPercentage": 48,
            "weeklyResetTime": 30000,
            "opusWeeklyTokensUsed": 0,
            "opusWeeklyPercentage": 0,
            "sonnetWeeklyTokensUsed": 0,
            "sonnetWeeklyPercentage": 0,
            "costUsed": 26118,
            "costLimit": 100000,
            "costCurrency": "USD",
            "lastUpdated": 10000,
            "userTimezone": {"identifier": "GMT"}
        }
        """

        let usage = try JSONDecoder().decode(
            ClaudeUsage.self,
            from: Data(json.utf8)
        )

        XCTAssertNil(usage.personalCostUsed)
        XCTAssertNil(usage.personalCostLimit)
        XCTAssertNil(usage.personalCostCurrency)
        XCTAssertEqual(usage.costUsed, 26_118)
    }

    func testPersonalFiguresSurviveAnEncodeDecodeRoundTrip() throws {
        var usage = ClaudeUsage.empty
        usage.personalCostUsed = 0
        usage.personalCostLimit = 5_000
        usage.personalCostCurrency = "USD"

        let decoded = try JSONDecoder().decode(
            ClaudeUsage.self,
            from: JSONEncoder().encode(usage)
        )

        XCTAssertEqual(decoded.personalCostUsed, 0)
        XCTAssertEqual(decoded.personalCostLimit, 5_000)
        XCTAssertEqual(decoded.personalCostCurrency, "USD")
    }

    // MARK: - Popover groups

    /// Both figures, in the order a person reads them: theirs, then the
    /// company's. The organization's amounts are the ones a real team
    /// reported at the same moment the member reported nothing.
    func testBothFiguresRenderAsTwoGroupsWithThePersonalOneFirst() throws {
        var usage = ClaudeUsage.empty
        usage.costUsed = 26_118
        usage.costLimit = 100_000
        usage.costCurrency = "USD"
        usage.costScope = .organization
        usage.personalCostUsed = 0
        usage.personalCostLimit = 5_000
        usage.personalCostCurrency = "USD"

        let groups = try makeReport(from: usage).limitGroups.filter {
            $0.id.rawValue.hasPrefix("extra-usage")
        }

        XCTAssertEqual(
            groups.map(\.id.rawValue),
            ["extra-usage", "extra-usage-organization"]
        )
        XCTAssertEqual(groups[0].displayName, "Extra Usage")
        XCTAssertEqual(groups[1].displayName, "Extra Usage · Organization")

        XCTAssertEqual(groups[0].windows[0].quantity?.used, 0)
        XCTAssertEqual(groups[0].windows[0].quantity?.limit, 50)

        XCTAssertEqual(groups[1].windows[0].quantity?.used, 261.18)
        XCTAssertEqual(groups[1].windows[0].quantity?.limit, 1_000)
        XCTAssertEqual(
            try XCTUnwrap(groups[1].windows[0].usedPercentage),
            26.12,
            accuracy: 0.005
        )
    }

    /// Regression guard for the previous change: with no member figure the
    /// popover looks exactly as it did — one group, labelled as the
    /// organization's, under the identifier it has always had.
    func testOrganizationOnlyStillRendersOneGroupUnderTheOriginalIdentifier() throws {
        var usage = ClaudeUsage.empty
        usage.costUsed = 26_118
        usage.costLimit = 100_000
        usage.costCurrency = "USD"
        usage.costScope = .organization

        let groups = try makeReport(from: usage).limitGroups.filter {
            $0.id.rawValue.hasPrefix("extra-usage")
        }

        XCTAssertEqual(groups.map(\.id.rawValue), ["extra-usage"])
        XCTAssertEqual(groups[0].displayName, "Extra Usage · Organization")
    }

    /// The popover explains a missing member figure only when there is an
    /// organization figure with no member figure beside it — and says which
    /// of the three reasons applies, because they need different actions.
    func testTheNoticeAppearsOnlyForAnUnaccompaniedOrganizationFigure() {
        var organizationOnly = ClaudeUsage.empty
        organizationOnly.costUsed = 26_118
        organizationOnly.costLimit = 100_000
        organizationOnly.costCurrency = "USD"
        organizationOnly.costScope = .organization
        organizationOnly.personalExtraUsageIssue = .notLinked
        XCTAssertEqual(
            ClaudeUsageProviderAdapter
                .personalExtraUsageIssueToExplain(for: organizationOnly),
            .notLinked
        )

        // A linked account whose sign-in stopped working must not be told to
        // link one: that sends someone to a screen with nothing to connect.
        var brokenSignIn = organizationOnly
        brokenSignIn.personalExtraUsageIssue = .signInUnusable
        XCTAssertEqual(
            ClaudeUsageProviderAdapter
                .personalExtraUsageIssueToExplain(for: brokenSignIn),
            .signInUnusable
        )

        // Distinct from the above: re-syncing cannot renew an expired login,
        // so the two must never collapse into one message.
        var expiredSignIn = organizationOnly
        expiredSignIn.personalExtraUsageIssue = .signInExpired
        XCTAssertEqual(
            ClaudeUsageProviderAdapter
                .personalExtraUsageIssueToExplain(for: expiredSignIn),
            .signInExpired
        )

        var otherOrganization = organizationOnly
        otherOrganization.personalExtraUsageIssue = .differentOrganization
        XCTAssertEqual(
            ClaudeUsageProviderAdapter
                .personalExtraUsageIssueToExplain(for: otherOrganization),
            .differentOrganization
        )

        var withPersonal = organizationOnly
        withPersonal.personalCostUsed = 0
        withPersonal.personalCostLimit = 5_000
        withPersonal.personalCostCurrency = "USD"
        withPersonal.personalExtraUsageIssue = nil
        XCTAssertNil(
            ClaudeUsageProviderAdapter
                .personalExtraUsageIssueToExplain(for: withPersonal)
        )

        // A single-person organization's figure already is the viewer's.
        var singlePerson = organizationOnly
        singlePerson.costScope = .personal
        XCTAssertNil(
            ClaudeUsageProviderAdapter
                .personalExtraUsageIssueToExplain(for: singlePerson)
        )

        // Extra usage simply switched off leaves no reason to explain.
        var noReason = organizationOnly
        noReason.personalExtraUsageIssue = nil
        XCTAssertNil(
            ClaudeUsageProviderAdapter
                .personalExtraUsageIssueToExplain(for: noReason)
        )

        XCTAssertNil(
            ClaudeUsageProviderAdapter
                .personalExtraUsageIssueToExplain(for: .empty)
        )
    }

    // MARK: - The absence statement

    /// The reconciliation notice above only ever fires when a figure is on
    /// screen. When none is, the extra-usage row simply does not render and
    /// the app used to say nothing at all — while holding the exact reason.
    func testAMissingFigureWithAKnownReasonIsExplained() {
        var noFigure = ClaudeUsage.empty
        noFigure.personalExtraUsageIssue = .signInExpired

        XCTAssertNil(
            ClaudeUsageProviderAdapter
                .personalExtraUsageIssueToExplain(for: noFigure),
            "There is no organization figure to reconcile, so the "
                + "reconciliation notice must stay quiet."
        )
        XCTAssertEqual(
            ClaudeUsageProviderAdapter
                .extraUsageAbsenceToExplain(for: noFigure),
            .unreadablePersonalFigure(.signInExpired),
            "...and the absence statement must take its place, naming the "
                + "reason the app already knew."
        )
    }

    /// Every reason survives the trip, because their remedies differ and a
    /// single collapsed message sent people to the wrong screen once already.
    func testEveryReasonReachesTheAbsenceStatement() {
        let issues: [ClaudeUsage.PersonalExtraUsageIssue] = [
            .notLinked, .signInExpired, .signInHasNoToken,
            .signInUnusable, .temporarilyUnavailable,
            .differentOrganization, .claudeAccountUnresolved
        ]
        for issue in issues {
            var usage = ClaudeUsage.empty
            usage.personalExtraUsageIssue = issue
            XCTAssertEqual(
                ClaudeUsageProviderAdapter
                    .extraUsageAbsenceToExplain(for: usage),
                .unreadablePersonalFigure(issue),
                "\(issue) was dropped on the way to the popover."
            )
        }
    }

    /// A failed request and extra usage being switched off both used to leave
    /// the same three nil fields. Only one of them is worth saying anything
    /// about, so they have to be distinguishable first.
    func testAFailedLookupIsDistinguishableFromExtraUsageBeingOff() {
        var lookupFailed = ClaudeUsage.empty
        lookupFailed.organizationExtraUsageIssue = .lookupFailed
        XCTAssertEqual(
            ClaudeUsageProviderAdapter
                .extraUsageAbsenceToExplain(for: lookupFailed),
            .unreadableOrganizationFigure
        )

        var notEnabled = ClaudeUsage.empty
        notEnabled.organizationExtraUsageIssue = .notEnabled
        XCTAssertNil(
            ClaudeUsageProviderAdapter
                .extraUsageAbsenceToExplain(for: notEnabled),
            "Switched off is a settled answer with nothing to fix; a notice "
                + "about it would be noise on every refresh."
        )

        XCTAssertNotEqual(
            lookupFailed.organizationExtraUsageIssue,
            notEnabled.organizationExtraUsageIssue
        )
    }

    /// An organization claude.ai does not offer extra usage to is a settled
    /// answer, and must be as silent as having it switched off.
    ///
    /// It was reaching the popover as `lookupFailed`, which renders the
    /// degraded header notice "Some usage details are unavailable" on a
    /// profile where nothing is wrong, nothing failed, and there is nothing
    /// anyone can do. Both the notice and the health classification are
    /// asserted, because they are decided in different functions and only one
    /// of them used to be exhaustive.
    func testAnOrganizationWithoutExtraUsageIsSilentAndStillHealthy() throws {
        var notAvailable = Self.fullyReadUsage()
        notAvailable.organizationExtraUsageIssue = .notAvailableForOrganization
        XCTAssertNil(
            ClaudeUsageProviderAdapter
                .extraUsageAbsenceToExplain(for: notAvailable),
            "a feature this organization is not offered is settled; a notice "
                + "about it would be noise on every refresh"
        )

        XCTAssertEqual(
            try makeReport(from: notAvailable).health.status,
            .healthy,
            "and the account is not degraded for a settled answer"
        )

        var lookupFailed = Self.fullyReadUsage()
        lookupFailed.organizationExtraUsageIssue = .lookupFailed
        XCTAssertEqual(
            ClaudeUsageProviderAdapter
                .extraUsageAbsenceToExplain(for: lookupFailed),
            .unreadableOrganizationFigure,
            "and a genuine failure must still say so, or this change would "
                + "have silenced the real case along with the false one"
        )
        XCTAssertEqual(
            try makeReport(from: lookupFailed).health.status,
            .degraded,
            "which is the header notice Jason was seeing — it must survive "
                + "for the organizations that really cannot be read"
        )
    }

    /// The two statements are mutually exclusive: a reader must never be told
    /// both "this is your organization's total" and "no figure could be read".
    func testTheTwoStatementsNeverAppearTogether() {
        var organizationFigure = ClaudeUsage.empty
        organizationFigure.costUsed = 26_118
        organizationFigure.costLimit = 100_000
        organizationFigure.costCurrency = "USD"
        organizationFigure.costScope = .organization
        organizationFigure.personalExtraUsageIssue = .notLinked

        XCTAssertNotNil(
            ClaudeUsageProviderAdapter
                .personalExtraUsageIssueToExplain(for: organizationFigure)
        )
        XCTAssertNil(
            ClaudeUsageProviderAdapter
                .extraUsageAbsenceToExplain(for: organizationFigure)
        )
    }

    /// A personal Max/Pro subscription's organization figure *is* that
    /// person's own, so the deliberate silence there is preserved.
    func testASinglePersonOrganizationFigureStaysSilent() {
        var singlePerson = ClaudeUsage.empty
        singlePerson.costUsed = 1_000
        singlePerson.costLimit = 5_000
        singlePerson.costCurrency = "USD"
        singlePerson.costScope = .personal
        singlePerson.personalExtraUsageIssue = .notLinked

        XCTAssertNil(
            ClaudeUsageProviderAdapter
                .personalExtraUsageIssueToExplain(for: singlePerson)
        )
        XCTAssertNil(
            ClaudeUsageProviderAdapter
                .extraUsageAbsenceToExplain(for: singlePerson),
            "The figure on screen already is this person's own."
        )
    }

    /// Their own number is on screen, so nothing is missing regardless of
    /// what else failed.
    func testAPresentPersonalFigureSilencesBothStatements() {
        var withPersonal = ClaudeUsage.empty
        withPersonal.personalCostUsed = 0
        withPersonal.personalCostLimit = 5_000
        withPersonal.personalCostCurrency = "USD"
        withPersonal.organizationExtraUsageIssue = .lookupFailed

        XCTAssertNil(
            ClaudeUsageProviderAdapter
                .extraUsageAbsenceToExplain(for: withPersonal)
        )
    }

    /// Nothing failed and nothing was asked for: silence, as before.
    func testAnUntouchedRecordSaysNothing() {
        XCTAssertNil(
            ClaudeUsageProviderAdapter
                .extraUsageAbsenceToExplain(for: .empty)
        )
    }

    // MARK: - The organization's own extra-usage answer

    /// A successful answer carrying no extra-usage record is settled, not a
    /// failure.
    ///
    /// This is the measured case, not a hypothetical one. Across 10,421
    /// logged `overage_spend_limit` responses on the maintainer's machine
    /// every single reply was HTTP 200 — including the two organizations the
    /// app was reporting as unreadable. The request never failed; the app
    /// simply had no name for a 200 whose body is not a record, so a `try?`
    /// dropped it into `lookupFailed` and the header said "Some usage details
    /// are unavailable" on two profiles where nothing was wrong.
    ///
    /// Both shapes a bodyless 200 can take are pinned, because these two —
    /// a zero-byte body and a literal `null` — are the only ones the app
    /// accepts as a settled answer, and either one alone would let the other
    /// regress into the failure bucket.
    func testASuccessfulAnswerWithNoExtraUsageRecordIsSettledNotFailed()
        async throws
    {
        for body in ["", "null"] {
            let profileID = UUID()
            let store = makeIsolatedProfileStore()
            try seedProfile(
                id: profileID,
                organizationID: teamOrganizationID,
                in: store
            )
            let service = try makeService(profileID: profileID, store: store)

            StubClaudeEndpointsURLProtocol.install(
                cliOrganizationID: teamOrganizationID,
                overageSpendLimitBody: body
            )
            defer { StubClaudeEndpointsURLProtocol.reset() }

            let usage = try await service.fetchUsageData(
                sessionKey: "sk-ant-sid01-fixture-session-key-value",
                organizationId: teamOrganizationID,
                profile: try seededProfile(profileID)
            )

            XCTAssertEqual(
                usage.organizationExtraUsageIssue,
                .notAvailableForOrganization,
                "a 200 whose body is \"\(body)\" is an answer, not a failure"
            )
            XCTAssertNil(usage.costUsed)
        }
    }

    /// An empty object still decodes, and must not be mistaken for the
    /// bodyless answer above.
    ///
    /// Every property of `OverageSpendLimitResponse` is optional, so `{}`
    /// decodes cleanly to a record with `isEnabled == nil` — which is not
    /// `true`, so it is extra usage switched off. Pinned because the fix
    /// hinges on "is the body an object", and an over-eager reading of that
    /// would sweep `{}` into the new case and lose a distinction the app
    /// already made correctly.
    func testAnEmptyObjectIsStillTheSwitchedOffAnswer() async throws {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            in: store
        )
        let service = try makeService(profileID: profileID, store: store)

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            overageSpendLimitBody: "{}"
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let usage = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: try seededProfile(profileID)
        )

        XCTAssertEqual(usage.organizationExtraUsageIssue, .notEnabled)
    }

    /// The shape classifier itself, which is what keeps a genuine shape
    /// change out of the settled bucket. Content never reaches it — only the
    /// top-level kind — so this is also the guard that no response body can
    /// be logged by way of this path.
    func testJSONShapeNamesTheTopLevelKindOnly() {
        XCTAssertEqual(ClaudeAPIService.jsonShape(of: Data()), .empty)
        XCTAssertEqual(
            ClaudeAPIService.jsonShape(of: Data("null".utf8)),
            .null
        )
        XCTAssertEqual(ClaudeAPIService.jsonShape(of: Data("[]".utf8)), .array)
        XCTAssertEqual(ClaudeAPIService.jsonShape(of: Data("{}".utf8)), .object)
        XCTAssertEqual(ClaudeAPIService.jsonShape(of: Data("7".utf8)), .scalar)
        XCTAssertEqual(
            ClaudeAPIService.jsonShape(of: Data("<html>".utf8)),
            .notJSON
        )
    }

    /// A 200 whose body IS an object but no longer decodes is a shape change,
    /// not an organization with nothing to report. It cannot happen while
    /// every field is optional, which is exactly why it needs pinning: the
    /// day someone makes one required, this is the difference between a
    /// visible failure and silent wrong data.
    func testAnUndecodableObjectIsAFailureNotASettledAnswer() {
        XCTAssertEqual(
            ClaudeAPIService.jsonShape(
                of: Data(#"{"monthly_credit_limit":"not-a-number"}"#.utf8)
            ),
            .object,
            "an object stays an object, and the object branch reports a "
                + "failure rather than going quiet"
        )
    }

    /// A JSON array is not a record, and is not the server saying there is no
    /// record either.
    ///
    /// The settled answer is narrow on purpose: a zero-byte body or a literal
    /// `null`. An array is neither, and reading it as "this organization has
    /// nothing to report" would be permanent — a settled answer is silent, is
    /// never retried, and leaves no notice for anyone to act on. Whatever an
    /// array from this endpoint would mean, the honest report is that the
    /// figure could not be read.
    func testAJSONArrayFromTheOrganizationEndpointStaysAVisibleFailure()
        async throws
    {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            in: store
        )
        let service = try makeService(profileID: profileID, store: store)

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            overageSpendLimitBody: "[]"
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let usage = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: try seededProfile(profileID)
        )

        XCTAssertEqual(
            usage.organizationExtraUsageIssue,
            .lookupFailed,
            "an array is not an extra-usage record and not an absence of "
                + "one; it stays reported rather than going quiet"
        )
    }

    /// The same for a bare scalar. Pinned separately from the array because
    /// the two arrive by different branches of the shape classifier, and
    /// because a scalar is the shape most easily mistaken for "nothing" —
    /// a `0` or a `false` reads like an absence to a human eye and is
    /// nothing of the sort to this endpoint.
    func testABareScalarFromTheOrganizationEndpointStaysAVisibleFailure()
        async throws
    {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            in: store
        )
        let service = try makeService(profileID: profileID, store: store)

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            overageSpendLimitBody: "0"
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let usage = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: try seededProfile(profileID)
        )

        XCTAssertEqual(
            usage.organizationExtraUsageIssue,
            .lookupFailed,
            "a bare scalar says nothing about this organization, so the app "
                + "must not claim it said there is nothing here"
        )
    }

    /// The case that makes the narrowing worth having: an HTML page served
    /// under HTTP 200.
    ///
    /// This is what a corporate proxy, a WAF challenge, or a hotel captive
    /// portal returns in claude.ai's place — a 200 that never reached
    /// Anthropic at all. Every profile behind that network would have gone
    /// permanently silent about extra usage if any non-object body counted as
    /// settled, and the app would have looked healthy while reporting nothing.
    /// It is a reading that did not happen, and it must say so.
    func testAnHTMLPageServedUnderHTTP200StaysAVisibleFailure() async throws {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            in: store
        )
        let service = try makeService(profileID: profileID, store: store)

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            overageSpendLimitBody:
                "<html><body>Access denied by network policy</body></html>"
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let usage = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: try seededProfile(profileID)
        )

        XCTAssertEqual(
            usage.organizationExtraUsageIssue,
            .lookupFailed,
            "a proxy answering in claude.ai's place is a failure to read the "
                + "figure, never a statement that there is no figure"
        )
    }

    /// The contrast that keeps the split honest: the far end being broken is
    /// still a failure and must still be reported. A 5xx is retryable and
    /// says nothing about whether this organization has extra usage, so it
    /// must not be mistaken for the settled answer above.
    func testAServerErrorOnTheOrganizationEndpointIsStillReported()
        async throws
    {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            in: store
        )
        let service = try makeService(profileID: profileID, store: store)

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            overageSpendLimitStatusCode: 503
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let usage = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: try seededProfile(profileID)
        )

        XCTAssertEqual(usage.organizationExtraUsageIssue, .lookupFailed)
    }

    /// A rate-limited answer is a failure too, not a statement about the
    /// organization. Pinned separately from the 5xx because 429 takes its own
    /// throwing branch in `performRequest`, and because a future "the server
    /// declined this organization" category built on status codes would be
    /// most tempting to write as a `400...499` range — which would swallow
    /// 429 and make the app go quiet exactly when it is asking too often.
    func testARateLimitedOrganizationEndpointIsNotMistakenForSettled()
        async throws
    {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            in: store
        )
        let service = try makeService(profileID: profileID, store: store)

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            overageSpendLimitStatusCode: 429
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let usage = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: try seededProfile(profileID)
        )

        XCTAssertEqual(usage.organizationExtraUsageIssue, .lookupFailed)
    }

    /// The organization endpoint gets the same cancellation treatment the
    /// member endpoint already has.
    ///
    /// A refresh superseded mid-flight tore this request down; the app did
    /// that to itself. `performRequest` wraps the URLSession failure in an
    /// `AppError`, so the -999 sits one layer down and a direct `as? URLError`
    /// check would miss it and report a complaint instead.
    func testACancelledOrganizationExtraUsageRequestRecordsNothing()
        async throws
    {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            in: store
        )
        let service = try makeService(profileID: profileID, store: store)

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            transportErrors: [
                "https://claude.ai/api/organizations/"
                    + "665a6475-2eb6-4da8-8379-d5529d283568/overage_spend_limit":
                    .cancelled
            ]
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let usage = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: try seededProfile(profileID)
        )

        XCTAssertNil(
            usage.organizationExtraUsageIssue,
            "the app cancelled this itself; there is no verdict to record"
        )
        XCTAssertNil(usage.costUsed)
    }

    /// And an ordinary transport failure is still a failure — the contrast
    /// that stops the cancellation branch being widened into "any network
    /// error is nothing to worry about".
    func testANonCancellationTransportFailureIsStillReported() async throws {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            in: store
        )
        let service = try makeService(profileID: profileID, store: store)

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            transportErrors: [
                "https://claude.ai/api/organizations/"
                    + "665a6475-2eb6-4da8-8379-d5529d283568/overage_spend_limit":
                    .networkConnectionLost
            ]
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let usage = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: try seededProfile(profileID)
        )

        XCTAssertEqual(usage.organizationExtraUsageIssue, .lookupFailed)
    }

    // MARK: - The organization guard

    /// The defect this guard exists for: one person, one email, two Claude
    /// Code logins in different organizations. The member figure from the
    /// wrong one must never appear under this profile — and must not even be
    /// requested.
    func testAMismatchedCLIOrganizationSkipsTheMemberFigureEntirely() async throws {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            in: store
        )
        let service = try makeService(profileID: profileID, store: store)

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: personalOrganizationID
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let usage = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: try seededProfile(profileID)
        )

        XCTAssertNil(usage.personalCostUsed)
        XCTAssertNil(usage.personalCostLimit)
        XCTAssertNil(usage.personalCostCurrency)
        XCTAssertEqual(usage.costUsed, 26_118)
        XCTAssertFalse(
            StubClaudeEndpointsURLProtocol.requestedURLs.contains {
                $0.hasSuffix("/api/oauth/usage")
            },
            "the member's usage must not be requested for a mismatched "
                + "organization"
        )
    }

    /// The fifth, previously silent outcome: a profile bound to a different
    /// claude.ai organization than the one this refresh is showing. The old
    /// behaviour left `personalExtraUsageIssue` nil, so the organization's
    /// figure rendered with no explanation at all — this pins that it now
    /// reports itself, and still never requests the member's endpoint.
    func testAnOrganizationMismatchReportsTheIssueInsteadOfNothing() async throws {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedProfile(
            id: profileID,
            organizationID: personalOrganizationID,
            in: store
        )
        let service = try makeService(profileID: profileID, store: store)

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: personalOrganizationID
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        // The profile is bound to `personalOrganizationID`; the refresh is
        // for `teamOrganizationID`. The mismatch guard has to fire before
        // any credential is even looked at.
        let usage = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: try seededProfile(profileID)
        )

        XCTAssertEqual(usage.personalExtraUsageIssue, .claudeAccountUnresolved)
        XCTAssertNil(usage.personalCostUsed)
        XCTAssertEqual(usage.costUsed, 26_118)
        XCTAssertFalse(
            StubClaudeEndpointsURLProtocol.requestedURLs.contains {
                $0.hasSuffix("/api/oauth/usage")
            },
            "an organization mismatch must never reach the member's usage "
                + "endpoint"
        )
    }

    /// The other previously silent route: the profile a request was captured
    /// for is gone by the time the fetch actually runs (removed mid-refresh)
    /// — but this profile is CLI-sourced, so under CLI-first that no longer
    /// means anything is missing. `applyMemberExtraUsage` reads the member's
    /// own figure straight out of the same `/api/oauth/usage` response the
    /// windows came from, authenticated by the one CLI token this request
    /// already carries; no profile lookup sits between the token and that
    /// figure, so a vanished profile leaves it untouched. Unlike the
    /// claude.ai-sourced path above, where the member figure is a *second*
    /// credential's reading and genuinely needs a resolved profile to
    /// attribute it correctly.
    func testANoLongerResolvableProfileStillExplainsItself() async throws {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            in: store
        )
        let manager = ProfileManager(profileStore: store)
        let profile = try seededProfile(profileID)
        manager.profiles = [profile]
        manager.activeProfile = profile
        retained.append(manager)
        retained.append(store)
        // Routed through the isolated builder, not `ClaudeAPIService(...)`
        // directly: the bare initialiser leaves `renewedCredentialWriter`
        // resolving to `ProfileStore.shared`, which reads every stored secret
        // out of the developer's login Keychain.
        let service = makeIsolatedClaudeAPIService(
            profileManager: manager,
            store: store
        )

        let request = try service.captureUsageRequest(for: profile)

        // The profile vanishes between capture and fetch — removed, in this
        // case, but a deleted profile reaches the same `nil` lookup.
        manager.profiles = []

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let usage = try await service.fetchUsageData(using: request)

        XCTAssertNil(usage.personalExtraUsageIssue)
        XCTAssertEqual(usage.personalCostUsed, 0)
        XCTAssertEqual(usage.costUsed, 26_118)
        XCTAssertTrue(
            StubClaudeEndpointsURLProtocol.requestedURLs.contains {
                $0.hasSuffix("/api/oauth/usage")
            },
            "the CLI-sourced fetch needs no profile to attach the member "
                + "figure to, so a vanished profile must not skip it"
        )
    }

    /// Extra usage switched off for the member is a settled answer with
    /// nothing to fix, and must stay silent — a guard against this route
    /// later being folded into `.claudeAccountUnresolved` by mistake.
    func testExtraUsageSwitchedOffForTheMemberStaysSilent() async throws {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            in: store
        )
        let service = try makeService(profileID: profileID, store: store)

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            memberExtraUsageEnabled: false
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let usage = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: try seededProfile(profileID)
        )

        XCTAssertNil(usage.personalExtraUsageIssue)
        XCTAssertNil(usage.personalCostUsed)
        XCTAssertEqual(usage.costUsed, 26_118)
    }

    /// The same flow with the logins agreeing: the member's own figure lands
    /// on the record beside the organization's.
    func testAMatchingCLIOrganizationPopulatesTheMemberFigure() async throws {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            in: store
        )
        let service = try makeService(profileID: profileID, store: store)

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let usage = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: try seededProfile(profileID)
        )

        XCTAssertEqual(usage.personalCostUsed, 0)
        XCTAssertEqual(usage.personalCostLimit, 5_000)
        XCTAssertEqual(usage.personalCostCurrency, "USD")
        XCTAssertEqual(usage.costUsed, 26_118)
        XCTAssertEqual(usage.costLimit, 100_000)
    }

    /// A renewal that fails must cost nothing. Losing a credential that still
    /// works is far worse than going without one number.
    func testAFailedTokenRenewalLeavesTheStoredCredentialUntouched() async throws {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        let expired = Self.credentialsJSON(expiresAt: 1_000)
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            credentialsJSON: expired,
            in: store
        )
        let service = try makeService(profileID: profileID, store: store)

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            tokenRefreshStatusCode: 400
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let usage = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: try seededProfile(profileID)
        )

        XCTAssertNil(usage.personalCostUsed)
        XCTAssertNil(usage.personalCostLimit)
        XCTAssertEqual(
            try store.loadProfileCredentials(profileID).cliCredentialsJSON,
            expired,
            "a failed renewal must not rewrite or clear the credential"
        )
    }

    // MARK: - Renewal mechanics

    /// The server may hand back a new refresh token. Keeping the old one
    /// would break the *next* renewal, and dropping the surrounding keys
    /// would break everything else that reads this blob.
    func testARenewalRotatesTheRefreshTokenAndKeepsEverythingElse() throws {
        let stored = """
        {
            "claudeAiOauth": {
                "accessToken": "old-access",
                "refreshToken": "old-refresh",
                "expiresAt": 1000,
                "scopes": ["user:inference"],
                "subscriptionType": "max"
            },
            "unrelatedKey": "kept"
        }
        """
        let response = """
        {
            "access_token": "new-access",
            "refresh_token": "new-refresh",
            "expires_in": 28800,
            "scope": "user:inference user:profile",
            "token_type": "Bearer"
        }
        """

        let merged = try XCTUnwrap(
            ClaudeCLITokenRefresher.merging(
                tokenResponse: Data(response.utf8),
                into: stored,
                now: Date(timeIntervalSince1970: 1_000_000)
            )
        )
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(merged.utf8))
                as? [String: Any]
        )
        let oauth = try XCTUnwrap(json["claudeAiOauth"] as? [String: Any])

        XCTAssertEqual(oauth["accessToken"] as? String, "new-access")
        XCTAssertEqual(oauth["refreshToken"] as? String, "new-refresh")
        XCTAssertEqual(oauth["subscriptionType"] as? String, "max")
        XCTAssertEqual(json["unrelatedKey"] as? String, "kept")
        XCTAssertEqual(
            oauth["scopes"] as? [String],
            ["user:inference", "user:profile"]
        )
        // Milliseconds since epoch, the unit the CLI stores expiry in.
        XCTAssertEqual(oauth["expiresAt"] as? Double, 1_028_800_000)

        // And with a real clock the renewed credential reads as live again,
        // which is the whole point of renewing it.
        let renewedNow = try XCTUnwrap(
            ClaudeCLITokenRefresher.merging(
                tokenResponse: Data(response.utf8),
                into: stored,
                now: Date()
            )
        )
        XCTAssertTrue(ClaudeCodeSyncService.shared.isTokenExpired(stored))
        XCTAssertFalse(
            ClaudeCodeSyncService.shared.isTokenExpired(renewedNow)
        )
    }

    /// A response the app cannot understand is not applied at all.
    func testAnUnusableRenewalResponseIsNotApplied() {
        let stored = Self.credentialsJSON(expiresAt: 1_000)
        XCTAssertNil(
            ClaudeCLITokenRefresher.merging(
                tokenResponse: Data(#"{"error":"invalid_grant"}"#.utf8),
                into: stored
            )
        )
    }

    // MARK: - A rotation must reach the store with its provenance

    /// The seam that decides whether Claude Code stays signed in.
    ///
    /// Anthropic rotates the refresh token on every use, so an ordinary
    /// timer-driven renewal spends the token Claude Code may itself be
    /// holding. The store can only write the rotated token back into the
    /// CLI's own Keychain item if it is told *which* credential was spent —
    /// so this asserts the spent credential reaches the writer, not merely
    /// that a renewal was persisted. Nothing else in the suite would notice
    /// if that argument were dropped on the way through.
    func testARenewalHandsTheSpentCredentialToTheCredentialWriter()
        async throws
    {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        let stored = Self.credentialsJSON(expiresAt: 1_000)
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            credentialsJSON: stored,
            in: store
        )
        let renewals = RenewedCredentialRecorder()
        let service = try makeService(
            profileID: profileID,
            store: store,
            renewals: renewals
        )
        let profile = try seededProfile(profileID)

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        _ = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: profile
        )

        let write = try XCTUnwrap(renewals.writes.first)
        XCTAssertEqual(write.profileID, profileID)
        XCTAssertEqual(
            write.rotatedFrom,
            stored,
            "the credential whose refresh token was spent must reach the "
                + "store, or Claude Code's copy of that token is rotated "
                + "away with nothing written back"
        )
    }

    /// Adoption spends no refresh token — it copies the login Claude Code is
    /// already holding — so it must NOT claim a rotation. Claiming one would
    /// send the store to rewrite a working CLI login for no reason.
    func testAnAdoptedLoginClaimsNoRotation() async throws {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            credentialsJSON: Self.credentialsJSON(expiresAt: 1_000),
            in: store
        )
        let manager = ProfileManager(profileStore: store)
        let profile = try seededProfile(profileID)
        manager.profiles = [profile]
        manager.activeProfile = profile
        retained.append(manager)
        retained.append(store)

        let renewals = RenewedCredentialRecorder()
        let live = Self.liveLoginJSON(
            expiresAt: Date()
                .addingTimeInterval(8 * 3600)
                .timeIntervalSince1970 * 1000
        )
        let service = makeIsolatedClaudeAPIService(
            profileManager: manager,
            store: store,
            systemCredentials: { live },
            renewals: renewals
        )

        // A 400 from the token endpoint is what sends the app down the
        // adoption path rather than the renewal path.
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            tokenRefreshStatusCode: 400
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        _ = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: profile
        )

        let write = try XCTUnwrap(
            renewals.writes.first { $0.json == live }
        )
        XCTAssertNil(
            write.rotatedFrom,
            "adoption spends no refresh token, so it must not report one"
        )
    }

    // MARK: - Adopting the live CLI login

    /// The reported bug: the app's stored copy can no longer be renewed
    /// because the CLI already rotated its refresh token, but Claude Code
    /// itself is signed in the whole time. The member's own extra usage
    /// must resolve without anyone pressing Re-sync, and the adopted login
    /// must be written back so the next refresh doesn't repeat the recovery.
    func testAnUnrenewableCredentialAdoptsTheLiveCLILoginAndSucceeds()
        async throws
    {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            credentialsJSON: Self.credentialsJSON(expiresAt: 1_000),
            in: store
        )
        let manager = ProfileManager(profileStore: store)
        let profile = try seededProfile(profileID)
        manager.profiles = [profile]
        manager.activeProfile = profile
        retained.append(manager)
        retained.append(store)

        let renewals = RenewedCredentialRecorder()
        let live = Self.liveLoginJSON(
            expiresAt: Date()
                .addingTimeInterval(8 * 3600)
                .timeIntervalSince1970 * 1000
        )
        let service = makeIsolatedClaudeAPIService(
            profileManager: manager,
            store: store,
            systemCredentials: { live },
            renewals: renewals
        )

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            tokenRefreshStatusCode: 400
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let usage = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: profile
        )

        XCTAssertEqual(usage.personalCostUsed, 0)
        XCTAssertEqual(usage.personalCostLimit, 5_000)
        XCTAssertNil(
            usage.personalExtraUsageIssue,
            "the adopted live login must resolve the member's own usage, "
                + "not merely avoid .signInExpired"
        )
        XCTAssertTrue(
            renewals.writes.contains {
                $0.json == live && $0.profileID == profileID
            },
            "the adopted login must be persisted so the user is not asked "
                + "to press Re-sync"
        )
    }

    // MARK: - Never spend a refresh token another process is relying on

    /// The bug this whole change exists for. A `claude` process holds its
    /// account's refresh token in memory; Anthropic rotates that token on
    /// every use, so the moment this app spends it the running process is
    /// holding a token the server has retired. Its next renewal comes back
    /// `invalid_grant`, Claude Code blanks its own Keychain item, and the
    /// person is told to sign in to an account they never signed out of.
    ///
    /// So for a live account the app reads instead of spending: Claude Code
    /// keeps that login fresh for as long as it is running.
    func testALiveAccountIsReadRatherThanRefreshed() async throws {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            credentialsJSON: Self.credentialsJSON(expiresAt: 1_000),
            in: store
        )
        let manager = ProfileManager(profileStore: store)
        let profile = try seededProfile(profileID)
        manager.profiles = [profile]
        manager.activeProfile = profile
        retained.append(manager)
        retained.append(store)

        let renewals = RenewedCredentialRecorder()
        let live = Self.liveLoginJSON(
            expiresAt: Date()
                .addingTimeInterval(8 * 3600)
                .timeIntervalSince1970 * 1000
        )
        let service = makeIsolatedClaudeAPIService(
            profileManager: manager,
            store: store,
            systemCredentials: { live },
            renewals: renewals,
            accountIsInUse: { _ in true }
        )

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let usage = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: profile
        )

        XCTAssertNil(usage.personalExtraUsageIssue)
        XCTAssertEqual(usage.personalCostUsed, 0)
        XCTAssertFalse(
            StubClaudeEndpointsURLProtocol.requestedURLs.contains {
                $0.contains("/v1/oauth/token")
            },
            "A refresh token owned by a running claude must never be spent: "
                + "\(StubClaudeEndpointsURLProtocol.requestedURLs)"
        )
    }

    /// The calm state. A live account whose token has run down, with nothing
    /// better in the store, is asleep — not expired. Nothing was spent and
    /// the server was never asked, so "your sign-in expired" would be a
    /// guess, and a wrong one: that account is signed in and working in the
    /// terminal the person is looking at.
    func testALiveAccountWithNothingLeftToReadIsReportedAsAsleep()
        async throws
    {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            credentialsJSON: Self.credentialsJSON(expiresAt: 1_000),
            in: store
        )
        let manager = ProfileManager(profileStore: store)
        let profile = try seededProfile(profileID)
        manager.profiles = [profile]
        manager.activeProfile = profile
        retained.append(manager)
        retained.append(store)

        let renewals = RenewedCredentialRecorder()
        let service = makeIsolatedClaudeAPIService(
            profileManager: manager,
            store: store,
            systemCredentials: { nil },
            renewals: renewals,
            accountIsInUse: { _ in true }
        )

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let usage = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: profile
        )

        XCTAssertEqual(usage.personalExtraUsageIssue, .signInAsleep)
        XCTAssertEqual(
            usage.claudeCodeAsleepSince,
            Date(timeIntervalSince1970: 1_000),
            "the calm wording names the time the token ran out"
        )
        XCTAssertNil(usage.personalCostUsed)
        XCTAssertTrue(renewals.writes.isEmpty)
        XCTAssertFalse(
            StubClaudeEndpointsURLProtocol.requestedURLs.contains {
                $0.contains("/v1/oauth/token")
            }
        )
    }

    /// The verdict must not become a blanket excuse. An idle account whose
    /// renewal the server actually refused is still an expired sign-in, and
    /// saying "asleep" there would hide a login that genuinely needs
    /// attention.
    func testAnIdleAccountRefusedByTheServerIsStillExpiredNotAsleep()
        async throws
    {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            credentialsJSON: Self.credentialsJSON(expiresAt: 1_000),
            in: store
        )
        let manager = ProfileManager(profileStore: store)
        let profile = try seededProfile(profileID)
        manager.profiles = [profile]
        manager.activeProfile = profile
        retained.append(manager)
        retained.append(store)

        let service = makeIsolatedClaudeAPIService(
            profileManager: manager,
            store: store,
            systemCredentials: { nil },
            renewals: RenewedCredentialRecorder(),
            accountIsInUse: { _ in false }
        )

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            tokenRefreshStatusCode: 400
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let usage = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: profile
        )

        XCTAssertEqual(usage.personalExtraUsageIssue, .signInExpired)
        XCTAssertNil(usage.claudeCodeAsleepSince)
    }

    /// A stored snapshot with no refresh token is not the last word on the
    /// account. Claude Code's own store may have been signed in again since
    /// that snapshot was taken, and reading it costs nothing and spends
    /// nothing. Declaring the account asleep without looking denied it a
    /// perfectly good login for the rest of the run, while the notice
    /// promised it would wake by itself.
    func testAStoredLoginWithNoRefreshTokenStillAdoptsTheLiveOne()
        async throws
    {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            credentialsJSON: Self.accessTokenOnlyCredentialsJSON(
                expiresAt: 1_000
            ),
            in: store
        )
        let manager = ProfileManager(profileStore: store)
        let profile = try seededProfile(profileID)
        manager.profiles = [profile]
        manager.activeProfile = profile
        retained.append(manager)
        retained.append(store)

        let renewals = RenewedCredentialRecorder()
        let live = Self.liveLoginJSON(
            expiresAt: Date()
                .addingTimeInterval(8 * 3600)
                .timeIntervalSince1970 * 1000
        )
        let service = makeIsolatedClaudeAPIService(
            profileManager: manager,
            store: store,
            systemCredentials: { live },
            renewals: renewals,
            accountIsInUse: { _ in false }
        )

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let usage = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: profile
        )

        XCTAssertNil(
            usage.personalExtraUsageIssue,
            "the store held a usable login, so nothing is asleep"
        )
        XCTAssertNil(usage.claudeCodeAsleepSince)
        XCTAssertEqual(usage.personalCostLimit, 5_000)
        XCTAssertTrue(
            renewals.writes.contains {
                $0.json == live && $0.profileID == profileID
            },
            "the adopted login must be persisted"
        )
        XCTAssertFalse(
            StubClaudeEndpointsURLProtocol.requestedURLs.contains {
                $0.contains("/v1/oauth/token")
            },
            "there was no refresh token to spend, so nothing may be posted"
        )
    }

    /// And when the store has nothing better either, the calm state is still
    /// the right one: nothing was spent and nothing was refused.
    func testAStoredLoginWithNoRefreshTokenAndAnEmptyStoreIsAsleep()
        async throws
    {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            credentialsJSON: Self.accessTokenOnlyCredentialsJSON(
                expiresAt: 1_000
            ),
            in: store
        )
        let manager = ProfileManager(profileStore: store)
        let profile = try seededProfile(profileID)
        manager.profiles = [profile]
        manager.activeProfile = profile
        retained.append(manager)
        retained.append(store)

        let renewals = RenewedCredentialRecorder()
        let service = makeIsolatedClaudeAPIService(
            profileManager: manager,
            store: store,
            systemCredentials: { nil },
            renewals: renewals,
            accountIsInUse: { _ in false }
        )

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let usage = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: profile
        )

        XCTAssertEqual(usage.personalExtraUsageIssue, .signInAsleep)
        XCTAssertEqual(
            usage.claudeCodeAsleepSince,
            Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertTrue(renewals.writes.isEmpty)
        XCTAssertFalse(
            StubClaudeEndpointsURLProtocol.requestedURLs.contains {
                $0.contains("/v1/oauth/token")
            }
        )
    }

    // MARK: - Refreshing under Claude Code's own lock

    /// Claude Code takes `<configDir>/.oauth_refresh.lock` before it
    /// refreshes. When it is holding it, it is refreshing the very token this
    /// tick wanted — so this app skips the tick rather than queueing behind
    /// it, and reads the result next time. Nothing is spent, and the
    /// credential is not accused of anything.
    func testARefreshIsSkippedWhileAnotherProcessHoldsTheLock() async throws {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            credentialsJSON: Self.credentialsJSON(expiresAt: 1_000),
            in: store
        )
        let manager = ProfileManager(profileStore: store)
        let profile = try seededProfile(profileID)
        manager.profiles = [profile]
        manager.activeProfile = profile
        retained.append(manager)
        retained.append(store)

        let renewals = RenewedCredentialRecorder()
        let service = makeIsolatedClaudeAPIService(
            profileManager: manager,
            store: store,
            systemCredentials: { nil },
            renewals: renewals
        )
        service.acquireRefreshLock = { _ in
            throw ClaudeCodeStoreLock.AcquisitionFailure.heldByAnotherProcess
        }

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let usage = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: profile
        )

        XCTAssertEqual(
            usage.personalExtraUsageIssue,
            .temporarilyUnavailable,
            "A refresh somebody else is already performing is a reading that "
                + "did not arrive, not a credential that failed"
        )
        XCTAssertTrue(renewals.writes.isEmpty)
        XCTAssertFalse(
            StubClaudeEndpointsURLProtocol.requestedURLs.contains {
                $0.contains("/v1/oauth/token")
            },
            "Nothing may be spent while another process holds the lock: "
                + "\(StubClaudeEndpointsURLProtocol.requestedURLs)"
        )
    }

    /// Claude Code re-reads its store immediately before it posts a refresh
    /// and adopts a sibling's rotated token rather than spending one that has
    /// already been replaced. Under the lock, this app makes the same check:
    /// a store holding a different access token means somebody got there
    /// first, and the endpoint is not called at all.
    func testAStoreThatMovedOnUnderTheLockIsAdoptedInsteadOfSpent()
        async throws
    {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            credentialsJSON: Self.credentialsJSON(expiresAt: 1_000),
            in: store
        )
        let manager = ProfileManager(profileStore: store)
        let profile = try seededProfile(profileID)
        manager.profiles = [profile]
        manager.activeProfile = profile
        retained.append(manager)
        retained.append(store)

        let renewals = RenewedCredentialRecorder()
        let live = Self.liveLoginJSON(
            expiresAt: Date()
                .addingTimeInterval(8 * 3600)
                .timeIntervalSince1970 * 1000
        )
        let service = makeIsolatedClaudeAPIService(
            profileManager: manager,
            store: store,
            systemCredentials: { live },
            renewals: renewals
        )
        useIsolatedClaudeCodeLocks(
            on: service,
            in: makeIsolatedClaudeConfigurationDirectory(),
            storeComparison: { _, _ in .movedOn }
        )

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let usage = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: profile
        )

        XCTAssertNil(usage.personalExtraUsageIssue)
        XCTAssertEqual(usage.personalCostUsed, 0)
        XCTAssertFalse(
            StubClaudeEndpointsURLProtocol.requestedURLs.contains {
                $0.contains("/v1/oauth/token")
            },
            "A token somebody already rotated must not be posted: "
                + "\(StubClaudeEndpointsURLProtocol.requestedURLs)"
        )
        XCTAssertTrue(
            renewals.writes.contains {
                $0.json == live && $0.rotatedFrom == nil
            },
            "The adopted login is not a rotation and must claim none"
        )
    }

    /// The stall this cost a live debugging session for. A store that has
    /// moved past our copy is usually newer *and* usable, and adopting it is
    /// the whole remedy — but on an idle account nobody was running `claude`
    /// to keep that copy fresh, so it can be newer and expired at once.
    /// Adoption declines a dead login, correctly, and the account was then
    /// left with nothing renewable: ours superseded, theirs out of time. It
    /// logged "already moved past the copy this app was about to renew"
    /// every thirty seconds, forever, and its Keychain item never rotated.
    ///
    /// The store's copy becomes the new base instead, which is what Claude
    /// Code itself does after it re-reads its store.
    func testAnExpiredStoreCopyOnAnIdleAccountIsRenewedInPlace() async throws {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        let stored = Self.credentialsJSON(expiresAt: 1_000)
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            credentialsJSON: stored,
            in: store
        )
        let manager = ProfileManager(profileStore: store)
        let profile = try seededProfile(profileID)
        manager.profiles = [profile]
        manager.activeProfile = profile
        retained.append(manager)
        retained.append(store)

        let renewals = RenewedCredentialRecorder()
        // Newer than the app's copy — a different refresh token entirely —
        // and expired, which is the whole shape of the defect.
        let storeCopy = Self.liveLoginJSON(expiresAt: 1_000)
        let service = makeIsolatedClaudeAPIService(
            profileManager: manager,
            store: store,
            systemCredentials: { storeCopy },
            renewals: renewals,
            accountIsInUse: { _ in false }
        )
        useIsolatedClaudeCodeLocks(
            on: service,
            in: makeIsolatedClaudeConfigurationDirectory(),
            storeComparison: { snapshot, _ in
                snapshot == storeCopy ? .unchanged : .movedOn
            }
        )

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let usage = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: profile
        )

        XCTAssertNil(usage.personalExtraUsageIssue)
        XCTAssertTrue(
            StubClaudeEndpointsURLProtocol.requestedURLs.contains {
                $0.contains("/v1/oauth/token")
            },
            "An idle account whose only renewable login is the store's own "
                + "copy must actually renew it: "
                + "\(StubClaudeEndpointsURLProtocol.requestedURLs)"
        )
        let write = try XCTUnwrap(
            renewals.writes.first { $0.json.contains("renewed-access") }
        )
        XCTAssertEqual(
            write.rotatedFrom,
            storeCopy,
            "the compare-and-swap has to measure against the token actually "
                + "in the store, so the store's own copy is what was spent — "
                + "naming the superseded copy would fail the swap and leave "
                + "Claude Code holding a token this app just rotated away"
        )
    }

    /// The same state on an account a `claude` process is using stays
    /// read-only. That refresh token belongs to the running process under
    /// R2, whatever shape the store's copy is in, so the answer is still
    /// asleep and the endpoint is still never asked.
    func testAnExpiredStoreCopyOnALiveAccountIsLeftAsleep() async throws {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            credentialsJSON: Self.credentialsJSON(expiresAt: 1_000),
            in: store
        )
        let manager = ProfileManager(profileStore: store)
        let profile = try seededProfile(profileID)
        manager.profiles = [profile]
        manager.activeProfile = profile
        retained.append(manager)
        retained.append(store)

        let renewals = RenewedCredentialRecorder()
        let storeCopy = Self.liveLoginJSON(expiresAt: 1_000)
        let service = makeIsolatedClaudeAPIService(
            profileManager: manager,
            store: store,
            systemCredentials: { storeCopy },
            renewals: renewals,
            accountIsInUse: { _ in true }
        )
        useIsolatedClaudeCodeLocks(
            on: service,
            in: makeIsolatedClaudeConfigurationDirectory(),
            storeComparison: { snapshot, _ in
                snapshot == storeCopy ? .unchanged : .movedOn
            }
        )

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let usage = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: profile
        )

        XCTAssertEqual(usage.personalExtraUsageIssue, .signInAsleep)
        XCTAssertTrue(renewals.writes.isEmpty)
        XCTAssertFalse(
            StubClaudeEndpointsURLProtocol.requestedURLs.contains {
                $0.contains("/v1/oauth/token")
            },
            "A refresh token a running claude owns must never be spent, "
                + "however far the store has moved: "
                + "\(StubClaudeEndpointsURLProtocol.requestedURLs)"
        )
    }

    /// The account that found this, on 2026-09-13: idle, its store's copy
    /// newer than ours and expired, and that copy's refresh token refused
    /// with `invalid_grant`. The refusal was filed under the store's copy and
    /// looked up under ours, so the notice said the sign-in "isn't working"
    /// instead of that it had expired and needed signing in again — the one
    /// instruction that fixes it. Nothing was filed under our copy either, so
    /// the next refresh walked the whole path again.
    func testARefusedRetryOfTheStoresOwnCopyIsReportedAsExpiredAndNotRetried()
        async throws
    {
        let scene = try makeDeadIdleLoginScene()
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            tokenRefreshStatusCode: 400
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let first = try await fetchMemberUsage(scene)
        let second = try await fetchMemberUsage(scene)

        XCTAssertEqual(
            first.personalExtraUsageIssue,
            .signInExpired,
            "a login the server refused is expired, and the notice has to "
                + "say so to name the fix"
        )
        XCTAssertEqual(second.personalExtraUsageIssue, .signInExpired)
        XCTAssertEqual(
            tokenRequestCount,
            1,
            "a refused refresh token cannot succeed on a second try: "
                + "\(StubClaudeEndpointsURLProtocol.requestedURLs)"
        )
        XCTAssertTrue(scene.renewals.writes.isEmpty)
    }

    /// The other half of the same defect. The refresh after a refused retry
    /// used to take Claude Code's `.oauth_refresh.lock` again and read the
    /// store three times to arrive back at the same answer, twice a minute
    /// for as long as the app ran — a lock a `claude` starting on that
    /// account could collide with. Once the store's copy is known to be
    /// refused there is nothing a lock could change, so none is taken.
    ///
    /// The read count is exact on purpose. Two reads is one look at whether
    /// the account was signed in again and one at what the store now holds;
    /// a third means the known-refused copy was handed back into the renewal
    /// path to be turned away there.
    func testASecondRefreshAfterARefusedRetryTakesNoLock() async throws {
        let scene = try makeDeadIdleLoginScene()
        // Every refresh gets its look at the store, so what is counted below
        // is the path itself rather than the throttle standing in front of it.
        scene.service.liveCLILoginAdoptionRetryInterval = 0
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            tokenRefreshStatusCode: 400
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        _ = try await fetchMemberUsage(scene)
        XCTAssertEqual(
            scene.store.locks,
            2,
            "the first refresh locks once for our copy and once for the "
                + "store's"
        )
        let readsBefore = scene.store.reads

        let second = try await fetchMemberUsage(scene)

        XCTAssertEqual(second.personalExtraUsageIssue, .signInExpired)
        XCTAssertEqual(
            scene.store.locks,
            2,
            "no lock may be taken to rediscover a refusal already on record"
        )
        XCTAssertEqual(scene.store.reads - readsBefore, 2)
        XCTAssertEqual(tokenRequestCount, 1)
    }

    /// What the person actually sees. The Health strip marker appeared in
    /// both versions, because any broken Claude Code sign-in raises it; the
    /// banner under it is what carried the wrong instruction. Run the way a
    /// browser-backed profile really refreshes — prepare the terminal
    /// sign-in, then fetch — which walks the renewal path twice per tick.
    func testADeadIdleLoginRaisesTheClaudeCodeMarkerWithTheExpiredWording()
        async throws
    {
        let scene = try makeDeadIdleLoginScene()
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            tokenRefreshStatusCode: 400
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        for tick in 1...2 {
            let request = try await scene.service
                .captureUsageRequestPreparingTerminalSignIn(for: scene.profile)
            XCTAssertEqual(request.source, .claudeAI)
            let usage = try await scene.service.fetchUsageData(using: request)

            XCTAssertEqual(
                usage.personalExtraUsageIssue,
                .signInExpired,
                "tick \(tick)"
            )
            XCTAssertEqual(
                LegacyPopoverBanner.CLISignInProblem(
                    usage.personalExtraUsageIssue
                ),
                .expired,
                "the banner must ask for a new sign-in, not call the sign-in "
                    + "broken (tick \(tick))"
            )
            XCTAssertEqual(
                MenuBarAttentionSignal.attention(
                    cliSignInIssue: usage.personalExtraUsageIssue,
                    credentialFailureStreak: 0,
                    healthStatus: ClaudeUsageProviderAdapter.accountHealth(
                        from: usage,
                        base: ProviderHealth(status: .healthy, checkedAt: Date())
                    ).status
                ),
                .claudeCode,
                "tick \(tick)"
            )
        }

        XCTAssertEqual(
            scene.store.locks,
            2,
            "only the very first pass may lock; every later pass already "
                + "knows the answer"
        )
        XCTAssertEqual(tokenRequestCount, 1)
    }

    /// Recording the verdict on our copy must not stand between the account
    /// and the sign-in that fixes it. A `/login` the app finds still fresh is
    /// simply adopted, as before, with nothing spent and no lock taken.
    func testSigningInAgainAfterARefusedStoreCopyRetryRecovers() async throws {
        let scene = try makeDeadIdleLoginScene()
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            tokenRefreshStatusCode: 400
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let dead = try await fetchMemberUsage(scene)
        XCTAssertEqual(dead.personalExtraUsageIssue, .signInExpired)
        let locksBefore = scene.store.locks

        let signedIn = Self.signInAgainJSON(
            expiresAt: Date()
                .addingTimeInterval(8 * 3600)
                .timeIntervalSince1970 * 1000
        )
        scene.store.copy = signedIn
        scene.service.liveCLILoginAdoptionRetryInterval = 0
        let recovered = try await fetchMemberUsage(scene)

        XCTAssertNil(recovered.personalExtraUsageIssue)
        XCTAssertTrue(
            scene.renewals.writes.contains {
                $0.json == signedIn && $0.rotatedFrom == nil
            },
            "a new sign-in is adopted as-is and claims no rotation"
        )
        XCTAssertEqual(scene.store.locks, locksBefore)
        XCTAssertEqual(tokenRequestCount, 1)
    }

    /// The recovery the fix could have broken. Someone signs in again, the
    /// Mac sleeps before the app looks, and by morning that new login has
    /// expired too. Adoption declines an expired login, so with a verdict
    /// sitting on our copy the account said "sign in again" for the rest of
    /// the run however many times the person did. The new login carries a
    /// refresh token nobody has sent, so it gets the one locked renewal any
    /// superseded copy gets, measured against the store it came from.
    func testANewSignInThatExpiredBeforeTheAppLookedIsStillRenewed()
        async throws
    {
        let scene = try makeDeadIdleLoginScene()
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            tokenRefreshStatusCode: 400
        )

        let dead = try await fetchMemberUsage(scene)
        XCTAssertEqual(dead.personalExtraUsageIssue, .signInExpired)
        // Read before the stub is re-installed, which starts a new count.
        XCTAssertEqual(tokenRequestCount, 1)
        let locksBefore = scene.store.locks

        let expiredSignIn = Self.signInAgainJSON(expiresAt: 1_000)
        scene.store.copy = expiredSignIn
        scene.service.liveCLILoginAdoptionRetryInterval = 0
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let renewed = try await fetchMemberUsage(scene)

        XCTAssertNil(renewed.personalExtraUsageIssue)
        XCTAssertEqual(tokenRequestCount, 1)
        XCTAssertEqual(scene.store.locks - locksBefore, 1)
        let write = try XCTUnwrap(
            scene.renewals.writes.first { $0.json.contains("renewed-access") }
        )
        XCTAssertEqual(
            write.rotatedFrom,
            expiredSignIn,
            "the spent token is the new sign-in's own, so that is what the "
                + "write-back has to measure the store against"
        )
    }

    /// An exchange that timed out after dispatch may already have rotated
    /// the token, so it is never replayed — and that has to hold for the
    /// token, not only for the bytes it arrived in. Here the store hands the
    /// same login back with one unrelated key added, the way a store that
    /// re-serializes its own file does.
    func testAStoreCopyCarryingAnUnansweredRefreshTokenIsNeverSentAgain()
        async throws
    {
        let scene = try makeDeadIdleLoginScene()
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            transportErrors: [
                ClaudeCLITokenRefresher.tokenEndpoint: .timedOut
            ]
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let unanswered = try await fetchMemberUsage(scene)
        XCTAssertEqual(unanswered.personalExtraUsageIssue, .signInUnusable)
        XCTAssertEqual(tokenRequestCount, 1)
        let locksBefore = scene.store.locks

        scene.store.copy = Self.rewrittenByItsStore(
            Self.liveLoginJSON(expiresAt: 1_000)
        )
        scene.service.liveCLILoginAdoptionRetryInterval = 0
        let second = try await fetchMemberUsage(scene)

        XCTAssertEqual(
            tokenRequestCount,
            1,
            "a refresh token that may already be spent must never be sent "
                + "again, whatever bytes it arrives in: "
                + "\(StubClaudeEndpointsURLProtocol.requestedURLs)"
        )
        XCTAssertEqual(scene.store.locks, locksBefore)
        XCTAssertEqual(second.personalExtraUsageIssue, .signInUnusable)
    }

    /// The guarantee a running `claude` depends on survives the dead state.
    /// If someone starts `claude` on the account after the verdict was
    /// recorded, the refresh token belongs to that process again, and the
    /// answer is asleep with nothing locked and nothing sent.
    func testADeadIdleLoginThatBecomesLiveIsStillNeverRenewed() async throws {
        let scene = try makeDeadIdleLoginScene()
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            tokenRefreshStatusCode: 400
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        _ = try await fetchMemberUsage(scene)
        let locksBefore = scene.store.locks

        scene.service.accountIsInUse = { _ in true }
        scene.service.liveCLILoginAdoptionRetryInterval = 0
        let live = try await fetchMemberUsage(scene)

        XCTAssertEqual(live.personalExtraUsageIssue, .signInAsleep)
        XCTAssertEqual(scene.store.locks, locksBefore)
        XCTAssertEqual(tokenRequestCount, 1)
        XCTAssertTrue(scene.renewals.writes.isEmpty)
    }

    /// A verdict our copy borrowed from the store's copy is about that other
    /// login, and it must not outlive the other login's stay in the store.
    /// When the store holds our own login again — a profile switch writes it
    /// back — our refresh token has never been sent, and the account must
    /// get the ordinary locked, compared, spend-once renewal rather than an
    /// "expired" nobody established.
    func testABorrowedExpiredVerdictIsRetiredWhenTheStoreHoldsTheAppsOwnLoginAgain()
        async throws
    {
        let stored = Self.credentialsJSON(expiresAt: 1_000)
        let scene = try makeDeadIdleLoginScene(stored: stored)
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            tokenRefreshStatusCode: 400
        )

        let dead = try await fetchMemberUsage(scene)
        XCTAssertEqual(dead.personalExtraUsageIssue, .signInExpired)
        XCTAssertEqual(tokenRequestCount, 1)

        scene.store.copy = stored
        scene.service.liveCLILoginAdoptionRetryInterval = 0
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let locksBefore = scene.store.locks
        _ = try await fetchMemberUsage(scene)
        XCTAssertEqual(
            tokenRequestCount,
            0,
            "the refresh that notices the store holds our login only drops "
                + "the borrowed verdict"
        )
        XCTAssertEqual(scene.store.locks, locksBefore)

        let renewed = try await fetchMemberUsage(scene)

        XCTAssertNil(renewed.personalExtraUsageIssue)
        XCTAssertEqual(tokenRequestCount, 1)
        XCTAssertEqual(scene.store.locks - locksBefore, 1)
        let write = try XCTUnwrap(
            scene.renewals.writes.first { $0.json.contains("renewed-access") }
        )
        XCTAssertEqual(write.rotatedFrom, stored)
    }

    /// Carrying a verdict is for answers, not for a failed attempt. A 503
    /// from the token endpoint says nothing about the store's copy, so it is
    /// neither reported as expired nor remembered, and the next refresh asks
    /// again — which is the behavior every transient failure has always had.
    func testATransientFailureRenewingTheStoresOwnCopyIsRetriedNotCarried()
        async throws
    {
        let scene = try makeDeadIdleLoginScene()
        scene.service.liveCLILoginAdoptionRetryInterval = 0
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            tokenRefreshStatusCode: 503,
            tokenRefreshErrorCode: "service_unavailable"
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let first = try await fetchMemberUsage(scene)
        let second = try await fetchMemberUsage(scene)

        XCTAssertNotEqual(first.personalExtraUsageIssue, .signInExpired)
        XCTAssertNotEqual(second.personalExtraUsageIssue, .signInExpired)
        XCTAssertEqual(
            tokenRequestCount,
            2,
            "a server that was briefly unavailable must be asked again: "
                + "\(StubClaudeEndpointsURLProtocol.requestedURLs)"
        )
    }

    /// The double send the dead-verdict renewal could otherwise open. Our
    /// own copy's exchange times out after dispatch, then the store hands
    /// back the same tokens in different bytes — what an account backed by a
    /// credentials file looks like once its store re-serializes the login
    /// next to its other keys. Keyed on the blob, that looked like a login
    /// nobody had tried, and the possibly-rotated token went out again.
    func testTheSameRefreshTokenInDifferentBytesIsNeverSentTwice() async throws {
        let stored = Self.credentialsJSON(expiresAt: 1_000)
        let scene = try makeDeadIdleLoginScene(stored: stored, storeCopy: stored)
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            transportErrors: [
                ClaudeCLITokenRefresher.tokenEndpoint: .timedOut
            ]
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let unanswered = try await fetchMemberUsage(scene)
        XCTAssertEqual(unanswered.personalExtraUsageIssue, .signInUnusable)
        XCTAssertEqual(tokenRequestCount, 1)
        let locksBefore = scene.store.locks

        scene.store.copy = Self.rewrittenByItsStore(stored)
        scene.service.liveCLILoginAdoptionRetryInterval = 0
        for refresh in 2...3 {
            let usage = try await fetchMemberUsage(scene)
            XCTAssertEqual(
                usage.personalExtraUsageIssue,
                .signInUnusable,
                "refresh \(refresh)"
            )
        }

        XCTAssertEqual(
            tokenRequestCount,
            1,
            "the same refresh token must never be sent twice: "
                + "\(StubClaudeEndpointsURLProtocol.requestedURLs)"
        )
        XCTAssertEqual(scene.store.locks, locksBefore)
    }

    /// The same promise after an exchange that worked. Two profiles linked
    /// to one account backed by a credentials file hold the same login in
    /// different bytes, so they do not join one exchange. The first renews;
    /// with no Keychain item the store comparison has nothing to measure the
    /// second against, and the spent token went out again — which the
    /// server refuses, turning a login renewed a moment ago into "sign in
    /// again". The second profile is not handed the first one's renewal: it
    /// reads the store, where the write-back put it, and stores what it read.
    func testARefreshTokenSpentOnARenewalIsNeverSentAgainFromAnotherProfile()
        async throws
    {
        let expired = Self.credentialsJSON(expiresAt: 1_000)
        let pair = try makeFileBackedScene(
            expired,
            Self.rewrittenByItsStore(expired)
        )
        let scene = pair.scene
        let (firstProfile, secondProfile) = (pair.profiles[0], pair.profiles[1])
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let first = try await scene.service
            .captureUsageRequestPreparingTerminalSignIn(for: firstProfile)
        XCTAssertTrue(first.capturesOAuthToken("renewed-access"))
        XCTAssertEqual(tokenRequestCount, 1)
        let renewal = try XCTUnwrap(scene.renewals.writes.last?.json)
        scene.store.copy = Self.rewrittenByItsStore(renewal)
        let locksBefore = scene.store.locks

        // What the server does with a refresh token it already rotated, so
        // a second send shows up as a dead login as well as in the count.
        // Re-installing starts a new count.
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            tokenRefreshStatusCode: 400
        )
        let second = try? await scene.service
            .captureUsageRequestPreparingTerminalSignIn(for: secondProfile)

        XCTAssertEqual(
            tokenRequestCount,
            0,
            "a refresh token a renewal already spent must never be sent "
                + "again, whatever bytes it arrives in: "
                + "\(StubClaudeEndpointsURLProtocol.requestedURLs)"
        )
        XCTAssertEqual(scene.store.locks, locksBefore)
        XCTAssertTrue(
            second?.capturesOAuthToken("renewed-access") == true,
            "the store holds the renewal, and the second profile must read "
                + "it rather than be told to sign in again"
        )
        XCTAssertTrue(
            scene.renewals.writes.contains {
                $0.profileID == secondProfile.id
                    && $0.json == scene.store.copy
                    && $0.rotatedFrom == nil
            },
            "what the second profile uses it must also store, or a restart "
                + "puts the spent token back in front of the renewal path"
        )
    }

    /// The browser-backed wording of the same defect. The profile presents
    /// its login re-serialized by the credentials file after the write-back
    /// landed there. That copy must read the renewal from the store, not
    /// come back "expired, sign in again".
    func testARenewedLoginInDifferentBytesIsNeitherResentNorReportedExpired()
        async throws
    {
        let stored = Self.credentialsJSON(expiresAt: 1_000)
        let scene = try makeDeadIdleLoginScene(stored: stored, storeCopy: stored)
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let renewed = try await fetchMemberUsage(scene)
        XCTAssertNil(renewed.personalExtraUsageIssue)
        XCTAssertEqual(tokenRequestCount, 1)
        let locksBefore = scene.store.locks

        let rewritten = Self.rewrittenByItsStore(stored)
        scene.store.copy = Self.rewrittenByItsStore(
            try XCTUnwrap(scene.renewals.writes.last?.json)
        )
        var reSynced = scene.profile
        reSynced.cliCredentialsJSON = rewritten
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            tokenRefreshStatusCode: 400
        )
        for refresh in 2...3 {
            let usage = try await scene.service.fetchUsageData(
                sessionKey: "sk-ant-sid01-fixture-session-key-value",
                organizationId: teamOrganizationID,
                profile: reSynced
            )
            XCTAssertNil(
                usage.personalExtraUsageIssue,
                "a login renewed this run is neither expired nor unusable "
                    + "(refresh \(refresh))"
            )
        }

        XCTAssertEqual(
            tokenRequestCount,
            0,
            "a refresh token a renewal already spent must never be sent "
                + "again: \(StubClaudeEndpointsURLProtocol.requestedURLs)"
        )
        XCTAssertEqual(scene.store.locks, locksBefore)
    }

    /// When the write-back did not land, the store still holds the spent
    /// token, and there is nothing anywhere this copy may use. That is not
    /// a dead login — it renewed a moment ago — so it is neither sent, nor
    /// locked for, nor reported as expired, however often it is looked at.
    func testASpentTokenInOtherBytesWithNothingToAdoptTakesNoLockAndIsNotExpired()
        async throws
    {
        let stored = Self.credentialsJSON(expiresAt: 1_000)
        let scene = try makeDeadIdleLoginScene(stored: stored, storeCopy: stored)
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        _ = try await fetchMemberUsage(scene)
        XCTAssertEqual(tokenRequestCount, 1)
        let locksBefore = scene.store.locks

        let rewritten = Self.rewrittenByItsStore(stored)
        scene.store.copy = rewritten
        var reSynced = scene.profile
        reSynced.cliCredentialsJSON = rewritten
        // Every refresh gets its look at the store, so what is counted is the
        // path rather than the throttle in front of it.
        scene.service.liveCLILoginAdoptionRetryInterval = 0
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            tokenRefreshStatusCode: 400
        )
        for refresh in 2...3 {
            let usage = try await scene.service.fetchUsageData(
                sessionKey: "sk-ant-sid01-fixture-session-key-value",
                organizationId: teamOrganizationID,
                profile: reSynced
            )
            XCTAssertNotEqual(
                usage.personalExtraUsageIssue,
                .signInExpired,
                "a token spent on a renewal that worked is not an expired "
                    + "sign-in (refresh \(refresh))"
            )
        }

        XCTAssertEqual(
            tokenRequestCount,
            0,
            "a refresh token a renewal already spent must never be sent "
                + "again: \(StubClaudeEndpointsURLProtocol.requestedURLs)"
        )
        XCTAssertEqual(
            scene.store.locks,
            locksBefore,
            "no lock may be taken for a token that can never be sent"
        )
    }

    /// The handover this replaced was held only in memory. A profile that
    /// used another profile's renewal without storing it presented the spent
    /// token again after a restart, to a service that no longer knew it was
    /// spent. After a restart, every profile must present what it stored.
    func testAfterARestartNeitherProfilePresentsARenewedAwayToken()
        async throws
    {
        let expired = Self.credentialsJSON(expiresAt: 1_000)
        let pair = try makeFileBackedScene(
            expired,
            Self.rewrittenByItsStore(expired)
        )
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        _ = try await pair.scene.service
            .captureUsageRequestPreparingTerminalSignIn(for: pair.profiles[0])
        let renewal = try XCTUnwrap(pair.scene.renewals.writes.last?.json)
        pair.scene.store.copy = renewal
        _ = try? await pair.scene.service
            .captureUsageRequestPreparingTerminalSignIn(for: pair.profiles[1])
        XCTAssertEqual(
            tokenRequestCount,
            1,
            "before the restart: \(StubClaudeEndpointsURLProtocol.requestedURLs)"
        )

        // A new process: a new service, profiles read back from storage.
        let reloaded = try pair.profiles.map { profile in
            var reloaded = profile
            reloaded.cliCredentialsJSON = try pair.profileStore
                .loadProfileCredentials(profile.id).cliCredentialsJSON
            return reloaded
        }
        let manager = ProfileManager(profileStore: pair.profileStore)
        manager.profiles = reloaded
        retained.append(manager)
        let restarted = makeDeadIdleLoginScene(
            profile: reloaded[0],
            manager: manager,
            store: pair.profileStore,
            storeCopy: renewal
        )
        restarted.service.claudeCodeStoreComparison = { _, _ in .unchanged }
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            tokenRefreshStatusCode: 400
        )

        for profile in reloaded {
            let request = try? await restarted.service
                .captureUsageRequestPreparingTerminalSignIn(for: profile)
            XCTAssertTrue(
                request?.capturesOAuthToken("renewed-access") == true,
                "'\(profile.name)' must come back with the login it stored"
            )
        }
        XCTAssertEqual(
            tokenRequestCount,
            0,
            "after the restart: \(StubClaudeEndpointsURLProtocol.requestedURLs)"
        )
        XCTAssertEqual(restarted.store.locks, 0)
    }

    /// A spent token says nothing about which account a profile belongs to.
    /// A profile linked to a different account — or to none, as a legacy
    /// decode leaves it — that presents the same token must never be given
    /// this account's renewal, and must not spend anything under its own
    /// lock and store either.
    func testAProfileOfAnotherAccountPresentingASpentTokenGetsNothingOfThisAccount()
        async throws
    {
        let expired = Self.credentialsJSON(expiresAt: 1_000)
        let scenario = try makeFileBackedScene(
            expired,
            expired,
            expired,
            accountNames: ["fixture-account", "other-account", nil]
        )
        let scene = scenario.scene
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let renewed = try await scene.service
            .captureUsageRequestPreparingTerminalSignIn(
                for: scenario.profiles[0]
            )
        XCTAssertTrue(renewed.capturesOAuthToken("renewed-access"))
        XCTAssertEqual(tokenRequestCount, 1)
        let locksBefore = scene.store.locks

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            tokenRefreshStatusCode: 400
        )
        for other in scenario.profiles.dropFirst() {
            let request = try? await scene.service
                .captureUsageRequestPreparingTerminalSignIn(for: other)
            XCTAssertFalse(
                request?.capturesOAuthToken("renewed-access") == true,
                "'\(other.cliAccountName ?? "no account")' was handed "
                    + "another account's login"
            )
            XCTAssertFalse(
                scene.renewals.writes.contains { $0.profileID == other.id },
                "nothing may be stored for "
                    + "'\(other.cliAccountName ?? "no account")'"
            )
        }
        XCTAssertEqual(
            tokenRequestCount,
            0,
            "a renewed-away token must not be spent under another account: "
                + "\(StubClaudeEndpointsURLProtocol.requestedURLs)"
        )
        XCTAssertEqual(scene.store.locks, locksBefore)
    }

    /// Where the write-back did not land in a store with a Keychain item,
    /// the store keeps the login this app renewed away, so every comparison
    /// under the lock said it had moved on. Adopting refused its expired
    /// copy and renewing it would resend a spent token, so each refresh took
    /// the lock to learn nothing, and this app's own newer copy — which
    /// nobody else holds — was never renewed again. It is renewed under the
    /// lock instead: one lock and one exchange, and the next refresh uses it.
    func testAStoreLeftHoldingARenewedAwayLoginRenewsOurCopyOnceInsteadOfLooping()
        async throws
    {
        let stored = Self.credentialsJSON(expiresAt: 1_000)
        let scene = try makeDeadIdleLoginScene(stored: stored, storeCopy: stored)
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        _ = try await fetchMemberUsage(scene)
        XCTAssertEqual(tokenRequestCount, 1)
        XCTAssertEqual(scene.store.locks, 1)

        // Hours later: the renewal this app holds has run out of time, and
        // the store still holds the login it was renewed from.
        let ours = try Self.expiring(
            try XCTUnwrap(scene.renewals.writes.last?.json),
            at: 1_000
        )
        var later = scene.profile
        later.cliCredentialsJSON = ours
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID
        )
        for tick in 1...2 {
            let usage = try await scene.service.fetchUsageData(
                sessionKey: "sk-ant-sid01-fixture-session-key-value",
                organizationId: teamOrganizationID,
                profile: later
            )
            XCTAssertNil(usage.personalExtraUsageIssue, "tick \(tick)")
        }

        XCTAssertEqual(
            scene.store.locks - 1,
            1,
            "one lock renews our copy; the next refresh has nothing to lock for"
        )
        XCTAssertEqual(
            tokenRequestCount,
            1,
            "\(StubClaudeEndpointsURLProtocol.requestedURLs)"
        )
        XCTAssertTrue(
            scene.renewals.writes.contains {
                $0.json.contains("renewed-access") && $0.rotatedFrom == ours
            },
            "the renewal spends our copy's token, and the write-back measures "
                + "the store against that token"
        )
    }

    /// The other half of that rule. A store left behind proves only that
    /// this app's own renewal is newer; it says nothing about a snapshot
    /// this app never renewed into, which another program may already have
    /// rotated. Sending that is the reuse the comparison exists to prevent,
    /// so it still gets the ordinary `.movedOn` answer and nothing is sent.
    func testAStoreLeftBehindNeverLicensesSendingACopyThisAppDidNotRenew()
        async throws
    {
        let stored = Self.credentialsJSON(expiresAt: 1_000)
        let scene = try makeDeadIdleLoginScene(stored: stored, storeCopy: stored)
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        _ = try await fetchMemberUsage(scene)
        XCTAssertEqual(tokenRequestCount, 1)

        var older = scene.profile
        older.cliCredentialsJSON = Self.signInAgainJSON(expiresAt: 1_000)
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID
        )
        _ = try await scene.service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: older
        )

        XCTAssertEqual(
            tokenRequestCount,
            0,
            "\(StubClaudeEndpointsURLProtocol.requestedURLs)"
        )
    }

    /// Two renewals this app made prove nothing about each other. With the
    /// store left holding the first chain's spent login, a copy from a second,
    /// unrelated chain is not that login's descendant, and the store having
    /// "moved on" from it is not evidence it is current. It gets the ordinary
    /// `.movedOn` answer: one lock, and nothing sent.
    func testAStoreLeftBehindByOneRenewalNeverLicensesACopyFromAnotherChain()
        async throws
    {
        let stored = Self.credentialsJSON(expiresAt: 1_000)
        let scene = try makeDeadIdleLoginScene(stored: stored, storeCopy: stored)
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            issuedRefreshToken: "chain-a-refresh"
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }
        _ = try await fetchMemberUsage(scene)

        // A second chain, renewed while the store held its own login.
        let chainB = Self.signInAgainJSON(expiresAt: 1_000)
        var onChainB = scene.profile
        onChainB.cliCredentialsJSON = chainB
        scene.store.copy = chainB
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            issuedRefreshToken: "chain-b-refresh"
        )
        _ = try await scene.service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: onChainB
        )
        XCTAssertEqual(tokenRequestCount, 1)
        let chainBRenewal = try XCTUnwrap(
            scene.renewals.writes.last { $0.rotatedFrom == chainB }?.json
        )

        // The store is back on chain A's spent login; the profile presents
        // chain B's renewal once its hours are up.
        scene.store.copy = stored
        var later = scene.profile
        later.cliCredentialsJSON = try Self.expiring(chainBRenewal, at: 1_000)
        let locksBefore = scene.store.locks
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID
        )
        _ = try await scene.service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: later
        )

        XCTAssertEqual(
            tokenRequestCount,
            0,
            "a copy the store's login never led to must not be sent: "
                + "\(StubClaudeEndpointsURLProtocol.requestedURLs)"
        )
        XCTAssertEqual(
            scene.store.locks - locksBefore,
            1,
            "only the ordinary moved-on lock"
        )
    }

    /// Several hops still license the renewal: the store holds the original
    /// login, and this app has renewed twice since, each link a rotation it
    /// made and nobody else holds. The newest copy is renewed once.
    func testAStoreLeftBehindByTwoRenewalsStillRenewsTheNewestCopyOnce()
        async throws
    {
        let stored = Self.credentialsJSON(expiresAt: 1_000)
        let scene = try makeDeadIdleLoginScene(stored: stored, storeCopy: stored)
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            issuedRefreshToken: "hop-1-refresh"
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }
        _ = try await fetchMemberUsage(scene)
        let firstHop = try Self.expiring(
            try XCTUnwrap(scene.renewals.writes.last?.json),
            at: 1_000
        )

        var onFirstHop = scene.profile
        onFirstHop.cliCredentialsJSON = firstHop
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            issuedRefreshToken: "hop-2-refresh"
        )
        _ = try await scene.service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: onFirstHop
        )
        let secondHop = try Self.expiring(
            try XCTUnwrap(
                scene.renewals.writes.last { $0.rotatedFrom == firstHop }?.json
            ),
            at: 1_000
        )

        var onSecondHop = scene.profile
        onSecondHop.cliCredentialsJSON = secondHop
        let locksBefore = scene.store.locks
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            issuedRefreshToken: "hop-3-refresh"
        )
        for tick in 1...2 {
            let usage = try await scene.service.fetchUsageData(
                sessionKey: "sk-ant-sid01-fixture-session-key-value",
                organizationId: teamOrganizationID,
                profile: onSecondHop
            )
            XCTAssertNil(usage.personalExtraUsageIssue, "tick \(tick)")
        }

        XCTAssertEqual(
            tokenRequestCount,
            1,
            "\(StubClaudeEndpointsURLProtocol.requestedURLs)"
        )
        XCTAssertEqual(scene.store.locks - locksBefore, 1)
        XCTAssertTrue(
            scene.renewals.writes.contains { $0.rotatedFrom == secondHop }
        )
    }

    /// The same promise when nobody was left waiting for the answer. The
    /// verdict on a blob is recorded by the caller, and a caller the app
    /// cancelled mid-exchange records nothing, so the next refresh found no
    /// verdict and sent the token again. What the exchange itself records
    /// does not depend on who is still listening.
    func testAnUnansweredRefreshTokenIsNeverSentAgainAfterItsCallerWasCancelled()
        async throws
    {
        let stored = Self.credentialsJSON(expiresAt: 1_000)
        let scene = try makeDeadIdleLoginScene(stored: stored, storeCopy: stored)
        let refreshStarted = expectation(description: "token refresh started")
        // A second send is the defect under test. It has to reach the count
        // assertion below rather than crash the run on a second fulfill.
        refreshStarted.assertForOverFulfill = false
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            transportErrors: [
                ClaudeCLITokenRefresher.tokenEndpoint: .timedOut
            ],
            holdTokenRefreshResponse: true,
            onTokenRefreshStarted: { refreshStarted.fulfill() }
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let cancelledWaitEnded = expectation(
            description: "cancelled reading stopped waiting"
        )
        let cancelledReading = Task { @MainActor in
            defer { cancelledWaitEnded.fulfill() }
            return try await self.fetchMemberUsage(scene)
        }
        await fulfillment(of: [refreshStarted], timeout: 2)
        cancelledReading.cancel()
        await fulfillment(of: [cancelledWaitEnded], timeout: 2)
        StubClaudeEndpointsURLProtocol.releaseTokenRefreshResponse()
        _ = try? await cancelledReading.value

        // The exchange carries on without its caller. It releases Claude
        // Code's lock only after it has recorded its answer, so the lock
        // disappearing is the moment that answer exists.
        let deadline = Date().addingTimeInterval(5)
        while FileManager.default.fileExists(atPath: scene.store.lockPath),
              Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: scene.store.lockPath),
            "the abandoned exchange never finished"
        )
        XCTAssertEqual(tokenRequestCount, 1)

        _ = try await fetchMemberUsage(scene)

        XCTAssertEqual(
            tokenRequestCount,
            1,
            "an exchange nobody waited for still counts as sent: "
                + "\(StubClaudeEndpointsURLProtocol.requestedURLs)"
        )
        XCTAssertEqual(scene.store.locks, 1)
    }

    /// Terminal-only accounts were caught in the same lock loop, even though
    /// they have no browser fallback to word a notice on. The first cycle
    /// locks for both copies; the second has nothing left to learn.
    func testATerminalOnlyDeadIdleLoginTakesNoLockOnTheNextCycle()
        async throws
    {
        let stored = Self.credentialsJSON(expiresAt: 1_000)
        let profile = terminalOnlyProfile(credentialsJSON: stored)
        let store = makeIsolatedProfileStore()
        try seedProfilesForTesting([profile], in: store)
        try store.saveCLIProfileCredential(stored, for: profile.id)
        let manager = ProfileManager(profileStore: store)
        manager.profiles = [profile]
        retained.append(manager)
        retained.append(store)
        let scene = makeDeadIdleLoginScene(
            profile: profile,
            manager: manager,
            store: store,
            storeCopy: Self.liveLoginJSON(expiresAt: 1_000)
        )
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            tokenRefreshStatusCode: 400
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        for _ in 0..<2 {
            do {
                _ = try await scene.service
                    .captureUsageRequestPreparingTerminalSignIn(for: profile)
                XCTFail("a refused login leaves nothing to fetch with")
            } catch let error as AppError {
                XCTAssertEqual(error.code, .sessionKeyNotFound)
            }
        }

        XCTAssertEqual(scene.store.locks, 2)
        XCTAssertEqual(tokenRequestCount, 1)
    }

    /// A store that cannot be read is not permission to spend. Answering
    /// "unchanged" there spent the token and then hit the compare-and-swap,
    /// which fails closed on the same unreadable item — so the token was
    /// gone and the mirror-back refused, which is the original bug reached by
    /// another road.
    func testAnUnreadableStoreUnderTheLockSpendsNothing() async throws {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            credentialsJSON: Self.credentialsJSON(expiresAt: 1_000),
            in: store
        )
        let manager = ProfileManager(profileStore: store)
        let profile = try seededProfile(profileID)
        manager.profiles = [profile]
        manager.activeProfile = profile
        retained.append(manager)
        retained.append(store)

        let renewals = RenewedCredentialRecorder()
        let service = makeIsolatedClaudeAPIService(
            profileManager: manager,
            store: store,
            systemCredentials: { nil },
            renewals: renewals
        )
        useIsolatedClaudeCodeLocks(
            on: service,
            in: makeIsolatedClaudeConfigurationDirectory(),
            storeComparison: { _, _ in .unreadable }
        )

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let usage = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: profile
        )

        XCTAssertEqual(usage.personalExtraUsageIssue, .temporarilyUnavailable)
        XCTAssertTrue(renewals.writes.isEmpty)
        XCTAssertFalse(
            StubClaudeEndpointsURLProtocol.requestedURLs.contains {
                $0.contains("/v1/oauth/token")
            },
            "A token whose write-back cannot be checked must not be spent: "
                + "\(StubClaudeEndpointsURLProtocol.requestedURLs)"
        )
    }

    /// The plain single-account user: a wizard terminal sign-in that was
    /// never linked to an account directory, so the profile carries no
    /// account name. Once any `claude` runs and their token passes expiry,
    /// this app must not refresh — and must still be able to read the login
    /// Claude Code itself keeps fresh, or the numbers freeze until a manual
    /// re-sync.
    func testAnUnlinkedProfileStillReadsTheDefaultStoreWhileClaudeRuns()
        async throws
    {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            credentialsJSON: Self.credentialsJSON(expiresAt: 1_000),
            cliAccountName: nil,
            in: store
        )
        let manager = ProfileManager(profileStore: store)
        let profile = try seededProfile(profileID)
        manager.profiles = [profile]
        manager.activeProfile = profile
        retained.append(manager)
        retained.append(store)

        let renewals = RenewedCredentialRecorder()
        let live = Self.liveLoginJSON(
            expiresAt: Date()
                .addingTimeInterval(8 * 3600)
                .timeIntervalSince1970 * 1000
        )
        let service = makeIsolatedClaudeAPIService(
            profileManager: manager,
            store: store,
            systemCredentials: { live },
            renewals: renewals,
            accountIsInUse: { _ in true }
        )

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let usage = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: profile
        )

        XCTAssertNil(
            usage.personalExtraUsageIssue,
            "An unlinked profile must not go permanently asleep just because "
                + "a claude is running"
        )
        XCTAssertEqual(usage.personalCostUsed, 0)
        XCTAssertFalse(
            StubClaudeEndpointsURLProtocol.requestedURLs.contains {
                $0.contains("/v1/oauth/token")
            }
        )
    }

    /// A genuinely signed-out account must still be reported as expired —
    /// this fix must not paper over a real expiry.
    func testAGenuinelySignedOutAccountStillReportsExpired() async throws {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            credentialsJSON: Self.credentialsJSON(expiresAt: 1_000),
            in: store
        )
        let manager = ProfileManager(profileStore: store)
        let profile = try seededProfile(profileID)
        manager.profiles = [profile]
        manager.activeProfile = profile
        retained.append(manager)
        retained.append(store)

        let renewals = RenewedCredentialRecorder()
        let service = makeIsolatedClaudeAPIService(
            profileManager: manager,
            store: store,
            systemCredentials: { nil },
            renewals: renewals
        )

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            tokenRefreshStatusCode: 400
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let usage = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: profile
        )

        XCTAssertEqual(usage.personalExtraUsageIssue, .signInExpired)
        XCTAssertNil(usage.personalCostUsed)
        XCTAssertTrue(renewals.writes.isEmpty)
    }

    /// A dead login must never be swapped for another dead login: the live
    /// read exists, but is itself expired.
    func testADeadLiveLoginIsNotAdopted() async throws {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            credentialsJSON: Self.credentialsJSON(expiresAt: 1_000),
            in: store
        )
        let manager = ProfileManager(profileStore: store)
        let profile = try seededProfile(profileID)
        manager.profiles = [profile]
        manager.activeProfile = profile
        retained.append(manager)
        retained.append(store)

        let renewals = RenewedCredentialRecorder()
        let expiredLive = Self.liveLoginJSON(expiresAt: 1_000)
        let service = makeIsolatedClaudeAPIService(
            profileManager: manager,
            store: store,
            systemCredentials: { expiredLive },
            renewals: renewals
        )

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            tokenRefreshStatusCode: 400
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let usage = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: profile
        )

        XCTAssertEqual(usage.personalExtraUsageIssue, .signInExpired)
        XCTAssertTrue(
            renewals.writes.isEmpty,
            "an expired live login must never be adopted"
        )
    }

    /// A live blob with no token must never be adopted: a credential write
    /// here validates shape only, so a tokenless blob could otherwise
    /// overwrite a working login and read back as valid.
    func testATokenlessLiveLoginIsNotAdopted() async throws {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            credentialsJSON: Self.credentialsJSON(expiresAt: 1_000),
            in: store
        )
        let manager = ProfileManager(profileStore: store)
        let profile = try seededProfile(profileID)
        manager.profiles = [profile]
        manager.activeProfile = profile
        retained.append(manager)
        retained.append(store)

        let renewals = RenewedCredentialRecorder()
        let service = makeIsolatedClaudeAPIService(
            profileManager: manager,
            store: store,
            systemCredentials: { Self.signedOutCredentialsJSON },
            renewals: renewals
        )

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            tokenRefreshStatusCode: 400
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let usage = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: profile
        )

        XCTAssertEqual(usage.personalExtraUsageIssue, .signInExpired)
        XCTAssertTrue(
            renewals.writes.isEmpty,
            "a tokenless live blob must never be written over the stored "
                + "credential"
        )
    }

    /// A byte-identical live login is not a recovery: adopting it would
    /// change nothing and still must be reported as the same failure as
    /// before.
    func testAByteIdenticalLiveLoginIsNotTreatedAsRecovery() async throws {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        let stored = Self.credentialsJSON(expiresAt: 1_000)
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            credentialsJSON: stored,
            in: store
        )
        let manager = ProfileManager(profileStore: store)
        let profile = try seededProfile(profileID)
        manager.profiles = [profile]
        manager.activeProfile = profile
        retained.append(manager)
        retained.append(store)

        let renewals = RenewedCredentialRecorder()
        let service = makeIsolatedClaudeAPIService(
            profileManager: manager,
            store: store,
            systemCredentials: { stored },
            renewals: renewals
        )

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            tokenRefreshStatusCode: 400
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let usage = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: profile
        )

        XCTAssertEqual(usage.personalExtraUsageIssue, .signInExpired)
        XCTAssertTrue(renewals.writes.isEmpty)
    }

    /// The tokenless-stored path, not the unrenewable one: a stored login
    /// that carries no token at all must also try the live login before
    /// reporting `.signInHasNoToken`.
    func testATokenlessStoredCredentialAdoptsTheLiveCLILogin() async throws {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            credentialsJSON: Self.signedOutCredentialsJSON,
            in: store
        )
        let manager = ProfileManager(profileStore: store)
        let profile = try seededProfile(profileID)
        manager.profiles = [profile]
        manager.activeProfile = profile
        retained.append(manager)
        retained.append(store)

        let renewals = RenewedCredentialRecorder()
        let live = Self.liveLoginJSON(
            expiresAt: Date()
                .addingTimeInterval(8 * 3600)
                .timeIntervalSince1970 * 1000
        )
        let service = makeIsolatedClaudeAPIService(
            profileManager: manager,
            store: store,
            systemCredentials: { live },
            renewals: renewals
        )

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let usage = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: profile
        )

        XCTAssertNotEqual(
            usage.personalExtraUsageIssue,
            ClaudeUsage.PersonalExtraUsageIssue.signInHasNoToken
        )
        XCTAssertEqual(usage.personalCostUsed, 0)
        XCTAssertEqual(usage.personalCostLimit, 5_000)
        XCTAssertTrue(
            renewals.writes.contains {
                $0.json == live && $0.profileID == profileID
            }
        )
    }

    /// The Keychain read behind adoption must happen once per dead
    /// credential, not on every refresh tick — `liveCLILoginAdoptionAttempts`
    /// exists for exactly this.
    func testTheLiveCLILoginIsReadAtMostOncePerDeadCredential() async throws {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            credentialsJSON: Self.credentialsJSON(expiresAt: 1_000),
            in: store
        )
        let manager = ProfileManager(profileStore: store)
        let profile = try seededProfile(profileID)
        manager.profiles = [profile]
        manager.activeProfile = profile
        retained.append(manager)
        retained.append(store)

        var readCount = 0
        let service = makeIsolatedClaudeAPIService(
            profileManager: manager,
            store: store,
            systemCredentials: {
                readCount += 1
                return nil
            }
        )

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            tokenRefreshStatusCode: 400
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        _ = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: profile
        )
        _ = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: profile
        )

        XCTAssertEqual(
            readCount,
            1,
            "the live CLI login must be consulted once per dead stored "
                + "credential, not on every refresh"
        )
    }

    /// A profile with a stored, unrenewable credential but no linked account
    /// name must never fall back to the unscoped Keychain read: on a
    /// multi-account machine that read returns whichever account happens to
    /// own the shared item, which is exactly the cross-account confusion
    /// PR #71 fixed for a different call site. This is the regression guard
    /// for that reintroduction: `systemCredentialsReader` must not be
    /// called at all.
    func testANilAccountNameNeverAdoptsAnUnscopedLiveLogin() async throws {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            credentialsJSON: Self.credentialsJSON(expiresAt: 1_000),
            cliAccountName: nil,
            in: store
        )
        let manager = ProfileManager(profileStore: store)
        let profile = try seededProfile(profileID)
        manager.profiles = [profile]
        manager.activeProfile = profile
        retained.append(manager)
        retained.append(store)

        var readCount = 0
        let renewals = RenewedCredentialRecorder()
        let service = makeIsolatedClaudeAPIService(
            profileManager: manager,
            store: store,
            systemCredentials: {
                readCount += 1
                return Self.liveLoginJSON(
                    expiresAt: Date()
                        .addingTimeInterval(8 * 3600)
                        .timeIntervalSince1970 * 1000
                )
            },
            renewals: renewals
        )

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            tokenRefreshStatusCode: 400
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let usage = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: profile
        )

        XCTAssertEqual(usage.personalExtraUsageIssue, .signInExpired)
        XCTAssertEqual(
            readCount,
            0,
            "a profile with no linked account name must never trigger the "
                + "unscoped live Keychain read"
        )
        XCTAssertTrue(
            renewals.writes.isEmpty,
            "nothing may be written to this profile's credential storage "
                + "when the account name is unknown"
        )
    }

    /// The tokenless-stored path must apply the same nil-account-name guard
    /// as the unrenewable path above.
    func testANilAccountNameNeverAdoptsForATokenlessStoredCredential()
        async throws
    {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            credentialsJSON: Self.signedOutCredentialsJSON,
            cliAccountName: nil,
            in: store
        )
        let manager = ProfileManager(profileStore: store)
        let profile = try seededProfile(profileID)
        manager.profiles = [profile]
        manager.activeProfile = profile
        retained.append(manager)
        retained.append(store)

        var readCount = 0
        let renewals = RenewedCredentialRecorder()
        let service = makeIsolatedClaudeAPIService(
            profileManager: manager,
            store: store,
            systemCredentials: {
                readCount += 1
                return Self.liveLoginJSON(
                    expiresAt: Date()
                        .addingTimeInterval(8 * 3600)
                        .timeIntervalSince1970 * 1000
                )
            },
            renewals: renewals
        )

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let usage = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: profile
        )

        XCTAssertEqual(
            usage.personalExtraUsageIssue,
            ClaudeUsage.PersonalExtraUsageIssue.signInHasNoToken
        )
        XCTAssertEqual(
            readCount,
            0,
            "a profile with no linked account name must never trigger the "
                + "unscoped live Keychain read"
        )
        XCTAssertTrue(renewals.writes.isEmpty)
    }

    /// Proves the notice's promise is actually true: a first refresh that
    /// finds no live login yet must not permanently forfeit the credential's
    /// one chance at recovery. Once the user signs in to Claude Code, a
    /// later refresh over the same dead credential must adopt it.
    func testSigningInAfterTheNoticeIsAdoptedOnALaterRefresh() async throws {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            credentialsJSON: Self.credentialsJSON(expiresAt: 1_000),
            in: store
        )
        let manager = ProfileManager(profileStore: store)
        let profile = try seededProfile(profileID)
        manager.profiles = [profile]
        manager.activeProfile = profile
        retained.append(manager)
        retained.append(store)

        var signedIn = false
        let live = Self.liveLoginJSON(
            expiresAt: Date()
                .addingTimeInterval(8 * 3600)
                .timeIntervalSince1970 * 1000
        )
        let renewals = RenewedCredentialRecorder()
        let service = makeIsolatedClaudeAPIService(
            profileManager: manager,
            store: store,
            systemCredentials: { signedIn ? live : nil },
            renewals: renewals
        )
        // Isolates this test from real wall-clock time: the throttle exists
        // to bound Keychain reads across the seconds-apart ticks of a real
        // refresh timer, not to stand between two calls made back-to-back
        // in a test.
        service.liveCLILoginAdoptionRetryInterval = 0

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            tokenRefreshStatusCode: 400
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let beforeSignIn = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: profile
        )
        XCTAssertEqual(beforeSignIn.personalExtraUsageIssue, .signInExpired)
        XCTAssertTrue(renewals.writes.isEmpty)

        signedIn = true
        let afterSignIn = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: profile
        )

        XCTAssertNil(
            afterSignIn.personalExtraUsageIssue,
            "a refresh after the user signs in must recover automatically, "
                + "which is the promise the updated notice makes"
        )
        XCTAssertTrue(
            renewals.writes.contains {
                $0.json == live && $0.profileID == profileID
            }
        )
    }

    /// The recovery throttle in `adoptLiveCLILogin` used to key its cooldown
    /// on the stale credential's own text, not on which profile was asking.
    /// On a real machine two profiles routinely carried the exact same
    /// unusable stored blob — a historical import stamped it into every
    /// profile alike — and the app refreshed both through one shared
    /// service, a tick or two apart. Whichever profile refreshed second
    /// within the retry window (60 seconds by default) found the cooldown
    /// already spent by the first and was turned away without ever trying
    /// the Keychain, even though a perfectly good live login was sitting
    /// there. That profile kept showing the user a sign-in problem that the
    /// other profile, refreshed a moment earlier, never saw. The cooldown is
    /// now keyed on the profile as well as the credential, so each profile
    /// gets its own attempt regardless of what other profiles share its
    /// stored credential.
    func testTwoProfilesSharingAStaleCredentialBothRecover() async throws {
        let profileA = UUID()
        let profileB = UUID()
        let store = makeIsolatedProfileStore()
        let staleCredential = Self.credentialsJSON(expiresAt: 1_000)
        try seedProfile(
            id: profileA,
            organizationID: teamOrganizationID,
            credentialsJSON: staleCredential,
            in: store
        )
        // A second profile with the identical stale credential, appended
        // alongside the first rather than through `seedProfile` again —
        // that helper always creates the *initial* profile in the store,
        // which only one profile in a store may be.
        let profileBValue = Profile(
            id: profileB,
            name: "Fixture B",
            claudeSessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            organizationIsPersonal: false,
            cliCredentialsJSON: staleCredential,
            hasCliAccount: true,
            cliAccountName: "fixture-account-b"
        )
        try store.appendProfile(
            profileBValue,
            expectedExistingIDs: [profileA]
        )
        try store.saveCLIProfileCredential(staleCredential, for: profileB)
        let manager = ProfileManager(profileStore: store)
        let a = try seededProfile(profileA)
        let b = profileBValue
        manager.profiles = [a, b]
        manager.activeProfile = a
        retained.append(manager)
        retained.append(store)

        let live = Self.liveLoginJSON(
            expiresAt: Date()
                .addingTimeInterval(8 * 3600)
                .timeIntervalSince1970 * 1000
        )
        let renewals = RenewedCredentialRecorder()
        // Left at the default: this test is about the interval the app
        // actually ships with, not a zeroed-out stand-in for it.
        let service = makeIsolatedClaudeAPIService(
            profileManager: manager,
            store: store,
            systemCredentials: { live },
            renewals: renewals
        )

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            tokenRefreshStatusCode: 400
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let usageA = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: a
        )
        let usageB = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: b
        )

        XCTAssertNil(
            usageA.personalExtraUsageIssue,
            "the first profile refreshed should recover its live login"
        )
        XCTAssertNil(
            usageB.personalExtraUsageIssue,
            "a second profile with its own identical stale credential must "
                + "recover too — instead the shared cooldown, keyed only on "
                + "the credential text, denies it a Keychain read and it "
                + "keeps reporting a sign-in problem the user cannot fix"
        )
        XCTAssertTrue(
            renewals.writes.contains { $0.profileID == profileA },
            "profile A's recovered login should have been written back"
        )
        XCTAssertTrue(
            renewals.writes.contains { $0.profileID == profileB },
            "profile B's recovered login should have been written back too"
        )
    }

    // MARK: - The credentials file that is not a login

    /// The defect behind every profile showing an organization figure with no
    /// member figure: `~/.claude/.credentials.json` exists on installs that
    /// have only MCP server logins, holds `mcpOAuth` and nothing else, and is
    /// perfectly valid JSON. It was read before the Keychain and accepted on
    /// JSON validity alone, so it won, carried no token, and could not be
    /// renewed — leaving profiles that looked linked but never once returned
    /// the signed-in member's usage.
    func testACredentialsFileWithoutALoginIsNotAcceptedAsOne() throws {
        let mcpOnly = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(#"{"mcpOAuth":{"some-server":{"accessToken":"x"}}}"#.utf8)
            ) as? [String: Any]
        )
        XCTAssertFalse(
            ClaudeCodeSyncService.containsClaudeCodeLogin(mcpOnly),
            "An MCP-only credentials file must fall through to the Keychain."
        )

        let empty = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data("{}".utf8))
                as? [String: Any]
        )
        XCTAssertFalse(ClaudeCodeSyncService.containsClaudeCodeLogin(empty))

        let blankToken = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(#"{"claudeAiOauth":{"accessToken":""}}"#.utf8)
            ) as? [String: Any]
        )
        XCTAssertFalse(
            ClaudeCodeSyncService.containsClaudeCodeLogin(blankToken),
            "An empty token is no more usable than a missing one."
        )

        let realLogin = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(
                    #"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-abc","refreshToken":"sk-ant-ort01-def"}}"#.utf8
                )
            ) as? [String: Any]
        )
        XCTAssertTrue(
            ClaudeCodeSyncService.containsClaudeCodeLogin(realLogin)
        )
    }

    /// Contract change: the credentials file no longer competes with the
    /// Keychain on freshness, so there is no "may this file pre-empt the
    /// Keychain" question left to answer. The file is read only when the
    /// Keychain has no item at all, exactly as Claude Code reads it, and the
    /// classification of one Keychain document is what decides everything.
    ///
    /// This test used to assert the freshness comparison that predicate
    /// made. That comparison is gone rather than inverted: whichever program
    /// holds the newer token no longer matters once both read the same store
    /// in the same order.
    func testAKeychainDocumentIsClassifiedTheWayClaudeCodeClassifiesIt() {
        let login = Self.credentialsJSON(
            expiresAt: Date()
                .addingTimeInterval(8 * 3600)
                .timeIntervalSince1970 * 1000
        )
        XCTAssertEqual(
            ClaudeCodeSyncService.classifyKeychainDocument(login),
            .login(login)
        )

        // An expired login is still a login. Claude Code hands it to the
        // refresh path rather than treating the account as signed out, and
        // so must we — the alternative resurrects a file behind it.
        let expired = Self.credentialsJSON(expiresAt: 1_000)
        XCTAssertEqual(
            ClaudeCodeSyncService.classifyKeychainDocument(expired),
            .login(expired)
        )

        // The shape Claude Code writes when it retires a dead refresh
        // token. It means "signed out", and the file behind it must not be
        // consulted.
        let blankToken = #"{"claudeAiOauth":{"accessToken":""}}"#
        XCTAssertEqual(
            ClaudeCodeSyncService.classifyKeychainDocument(blankToken),
            .loggedOut
        )

        // No Claude Code record here at all — an MCP-only store. Claude
        // Code falls through to the file for this, and so do we.
        let mcpOnly = #"{"mcpOAuth":{"some-server":{"accessToken":"x"}}}"#
        XCTAssertEqual(
            ClaudeCodeSyncService.classifyKeychainDocument(mcpOnly),
            .noItem
        )

        // Bytes that will not parse. Claude Code's own keychain read wraps
        // the parse in a try/catch and answers null, which sends it to the
        // file.
        XCTAssertEqual(
            ClaudeCodeSyncService.classifyKeychainDocument("{not json"),
            .noItem
        )
    }

    // MARK: - Importing a login that carries no token

    /// The shape Claude Code leaves behind for a configuration directory it
    /// has been signed out of: `claudeAiOauth` still present, `accessToken`
    /// empty, no expiry and no refresh token.
    private static let signedOutCredentialsJSON = """
    {"mcpOAuth":{"some-server":{"accessToken":"mcp-token"}},\
    "claudeAiOauth":{"accessToken":"","scopes":[]}}
    """

    /// An empty access token is absent, not present-and-empty.
    ///
    /// Returning `""` here was the load-bearing mistake: it satisfied every
    /// `if let` downstream, so requests went out as a bare
    /// `Authorization: Bearer `.
    func testAnEmptyAccessTokenReadsAsNoTokenAtAll() {
        XCTAssertNil(
            ClaudeCodeSyncService.shared.extractAccessToken(
                from: Self.signedOutCredentialsJSON
            ),
            "an empty accessToken must not be handed out as a token"
        )
        XCTAssertEqual(
            ClaudeCodeSyncService.shared.extractAccessToken(
                from: Self.credentialsJSON(expiresAt: 1_000)
            ),
            "fixture-access-token"
        )
    }

    /// The single rule every import path shares: a blob that cannot
    /// authenticate must never be stored over one that can.
    func testASignedOutBlobIsNotAcceptedAsALogin() {
        XCTAssertFalse(
            ClaudeCodeSyncService.carriesLogin(Self.signedOutCredentialsJSON)
        )
        XCTAssertFalse(ClaudeCodeSyncService.carriesLogin("not json at all"))
        XCTAssertTrue(
            ClaudeCodeSyncService.carriesLogin(
                Self.credentialsJSON(expiresAt: 1_000)
            )
        )
    }

    /// A stored login with no token is its own reported state, and no request
    /// is made with it.
    ///
    /// Previously it reached the renewal path, which answered with an empty
    /// access token because an empty string is not nil, so the member's usage
    /// really was requested with a bare bearer, 401ed, and surfaced as
    /// "couldn't be read just now — re-sync" — the one action that re-imports
    /// the same empty blob. Both halves of that are asserted here.
    func testAStoredLoginWithNoTokenIsReportedAsSuchAndNeverRequestedWith()
        async throws
    {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            credentialsJSON: Self.signedOutCredentialsJSON,
            in: store
        )
        let service = try makeService(profileID: profileID, store: store)

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let usage = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: try seededProfile(profileID)
        )

        XCTAssertEqual(
            usage.personalExtraUsageIssue,
            ClaudeUsage.PersonalExtraUsageIssue.signInHasNoToken,
            "a login with no token must not be reported as a re-syncable "
                + "read failure"
        )
        XCTAssertNil(usage.personalCostUsed)
        XCTAssertFalse(
            StubClaudeEndpointsURLProtocol.requestedURLs.contains {
                $0.hasSuffix("/api/oauth/profile")
                    || $0.hasSuffix("/api/oauth/usage")
            },
            "nothing may be requested with a credential that has no token"
        )
        // The organization's own figure is unaffected.
        XCTAssertEqual(usage.costUsed, 26_118)
    }

    /// A failed organization lookup must not fall back to the cached answer.
    ///
    /// The cached id was resolved from a different credential. Answering with
    /// it let the organization-match guard pass on the previous account's
    /// identity and then read the member figure with the new account's token,
    /// which is the cross-account attribution the guard exists to stop — and
    /// one failed request was enough to reach it.
    func testAFailedOrganizationLookupDoesNotFallBackToTheCachedOrganization()
        async throws
    {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            in: store
        )
        // The cached answer that used to be trusted: it matches the
        // organization on screen exactly, so it satisfied the guard.
        ProfileManager(profileStore: store)
            .updateCliOrganizationId(teamOrganizationID, for: profileID)
        var profile = try seededProfile(profileID)
        profile.cliOrganizationId = teamOrganizationID
        let service = try makeService(profileID: profileID, store: store)

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            oauthProfileStatusCode: 401
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let usage = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: profile
        )

        XCTAssertNil(
            usage.personalCostUsed,
            "no member figure may be attributed on an unverified organization"
        )
        // A refused request says nothing about the credential — the token
        // was good enough to be sent — so this reports a reading that did not
        // arrive, not a sign-in that needs attention.
        XCTAssertEqual(
            usage.personalExtraUsageIssue,
            .temporarilyUnavailable
        )
        XCTAssertFalse(
            StubClaudeEndpointsURLProtocol.requestedURLs.contains {
                $0.hasSuffix("/api/oauth/usage")
            },
            "the member's usage must not be requested once the organization "
                + "could not be established"
        )
    }

    /// A transient renewal failure must be retried, not treated as a verdict.
    ///
    /// The failure record used to be permanent for the process, and this app
    /// runs for days, so one moment offline and a genuinely dead login became
    /// the same outcome. The stored credential is unchanged between the two
    /// fetches here; only the token endpoint's answer differs.
    func testATransientRenewalFailureIsRetriedOnTheNextRefresh() async throws {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            credentialsJSON: Self.credentialsJSON(expiresAt: 1_000),
            in: store
        )
        let renewals = RenewedCredentialRecorder()
        let service = try makeService(
            profileID: profileID,
            store: store,
            renewals: renewals
        )
        let profile = try seededProfile(profileID)

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            tokenRefreshStatusCode: 503,
            tokenRefreshErrorCode: "service_unavailable"
        )
        let unavailable = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: profile
        )
        StubClaudeEndpointsURLProtocol.reset()
        XCTAssertEqual(unavailable.personalExtraUsageIssue, .signInUnusable)
        XCTAssertEqual(
            try store.loadProfileCredentials(profileID).cliCredentialsJSON,
            Self.credentialsJSON(expiresAt: 1_000),
            "a failed renewal must leave the stored credential alone"
        )
        XCTAssertTrue(
            renewals.writes.isEmpty,
            "a failed renewal must not be handed to the credential writer"
        )

        // Same stored credential, the endpoint is back.
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }
        let recovered = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: profile
        )

        XCTAssertEqual(
            recovered.personalCostUsed,
            0,
            "renewal must be attempted again once the transient failure clears"
        )
        XCTAssertNil(recovered.personalExtraUsageIssue)
        // Where the renewed token was sent, not merely that one was obtained.
        // `ClaudeAPIService` swallows a persistence failure by design, so a
        // renewal written to the wrong store costs nothing visible — which is
        // how this test came to write through `ProfileStore.shared`, reading
        // the developer's whole login Keychain on the way.
        XCTAssertTrue(
            renewals.carriesAccessToken("renewed-access", for: profileID),
            "the renewed token must be handed to this test's own writer"
        )
    }

    /// An expired login stays short-circuited until the credential is
    /// replaced — which is what the notice now tells people to do, and what
    /// makes that instruction true.
    func testReplacingAnExpiredCredentialRetiresItsExpiredVerdict()
        async throws
    {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            credentialsJSON: Self.credentialsJSON(expiresAt: 1_000),
            in: store
        )
        let service = try makeService(profileID: profileID, store: store)
        var profile = try seededProfile(profileID)

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            tokenRefreshStatusCode: 400
        )
        let expired = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: profile
        )
        StubClaudeEndpointsURLProtocol.reset()
        XCTAssertEqual(expired.personalExtraUsageIssue, .signInExpired)

        // What a re-sync after signing in again produces: a different
        // credential, whose predecessor's verdict must not apply to it.
        profile.cliCredentialsJSON = Self.credentialsJSON(
            expiresAt: Date()
                .addingTimeInterval(8 * 3600)
                .timeIntervalSince1970 * 1000
        )
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }
        let renewed = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: profile
        )

        XCTAssertEqual(renewed.personalCostUsed, 0)
        XCTAssertNil(renewed.personalExtraUsageIssue)
    }

    // MARK: - One login per account

    /// Claude Code stores one Keychain item per configuration directory,
    /// named `Claude Code-credentials-<first 8 hex of SHA-256 of the path>`.
    /// Verified against a machine holding 13 such items, 10 of which mapped
    /// exactly onto their `~/.claude-accounts/<name>` directories.
    ///
    /// Getting this wrong is not a visible failure — it silently resolves to
    /// some other account's login, which is the shape of the original defect.
    func testEachAccountResolvesToItsOwnKeychainItem() {
        XCTAssertEqual(
            ClaudeCodeSyncService.serviceName(
                forConfigurationDirectory: "/Users/jason/.claude"
            ),
            "Claude Code-credentials-cacce12b"
        )
        XCTAssertEqual(
            ClaudeCodeSyncService.serviceName(
                forConfigurationDirectory: "/Users/jason/.claude-accounts/jcr"
            ),
            "Claude Code-credentials-05bbc126"
        )
        XCTAssertEqual(
            ClaudeCodeSyncService.serviceName(
                forConfigurationDirectory: "/Users/jason/.claude-accounts/r2"
            ),
            "Claude Code-credentials-14546770"
        )

        // Two accounts must never collide onto one login.
        let names = [
            "/Users/jason/.claude",
            "/Users/jason/.claude-accounts/jcr",
            "/Users/jason/.claude-accounts/r2",
            "/Users/jason/.claude-accounts/r3"
        ].map { ClaudeCodeSyncService.serviceName(forConfigurationDirectory: $0) }
        XCTAssertEqual(Set(names).count, names.count)

        // A trailing slash is a different path and must not be normalized
        // away by accident: it would resolve to an item that does not exist.
        XCTAssertNotEqual(
            ClaudeCodeSyncService.serviceName(
                forConfigurationDirectory: "/Users/jason/.claude-accounts/jcr"
            ),
            ClaudeCodeSyncService.serviceName(
                forConfigurationDirectory: "/Users/jason/.claude-accounts/jcr/"
            )
        )
    }

    /// The directory an account's login lives in, which is what the item name
    /// above is derived from.
    func testAnAccountsConfigurationDirectory() {
        XCTAssertEqual(
            ClaudeCodeSyncService
                .configurationDirectory(forAccountNamed: "jcr")
                .path,
            Constants.ClaudePaths.homeDirectory
                .appendingPathComponent(".claude-accounts")
                .appendingPathComponent("jcr")
                .path
        )
    }

    /// An expired login must be reported as expired, not as a generic
    /// failure: the remedies are opposite and the wrong one is a dead end.
    func testAnExpiredLoginIsReportedAsExpired() async {
        let noRefreshToken = #"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-x"}}"#
        let outcome = await ClaudeCLITokenRefresher.refreshOutcome(
            from: noRefreshToken,
            session: .shared
        )
        XCTAssertEqual(outcome, .failed(.expired))
    }

    // MARK: - Terminal-only usage renewal

    func testTerminalOnlyRefreshRenewsPersistsAndCapturesTheNewToken()
        async throws
    {
        let expired = Self.credentialsJSON(expiresAt: 1_000)
        let profile = terminalOnlyProfile(credentialsJSON: expired)
        let store = makeIsolatedProfileStore()
        try seedProfilesForTesting([profile], in: store)
        try store.saveCLIProfileCredential(expired, for: profile.id)
        let manager = ProfileManager(profileStore: store)
        manager.profiles = [profile]
        let renewals = RenewedCredentialRecorder()
        var logMessages: [String] = []
        let loggingService = LoggingService {
            logMessages.append($0)
        }
        let keychain = TerminalRenewalSecurityRunner(holding: expired)
        // Claude Code's refresh and store-write locks are directories inside
        // the account's configuration directory; a fixture account must not
        // make one under the developer's real `~/.claude-accounts`.
        let configurationDirectory = makeIsolatedClaudeConfigurationDirectory()
        let cliSync = ClaudeCodeSyncService(
            profileStore: store,
            systemCredentialsReader: { expired },
            securityRunner: keychain,
            credentialsFileDirectory: { _ in configurationDirectory },
            liveProcessDetector: .stubbedIdle()
        )
        let service = ClaudeAPIService(
            profileManager: manager,
            systemCredentialsReader: { nil },
            renewedCredentialWriter: { renewal, profileID in
                renewals.record(
                    renewal.credentialsJSON,
                    rotatedFrom: renewal.rotatedFrom,
                    for: profileID
                )
                try cliSync.saveRefreshedCredentials(
                    renewal.credentialsJSON,
                    for: profileID,
                    rotatedFrom: renewal.rotatedFrom
                )
            },
            loggingService: loggingService
        )
        useIsolatedClaudeCodeLocks(on: service, in: configurationDirectory)
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID
        )

        let request = try await service
            .captureUsageRequestPreparingTerminalSignIn(for: profile)
        let usage = try await service.fetchUsageData(using: request)

        XCTAssertEqual(request.source, .profileCLI)
        XCTAssertTrue(request.capturesOAuthToken("renewed-access"))
        XCTAssertTrue(
            try XCTUnwrap(
                store.loadProfileCredentials(profile.id).cliCredentialsJSON
            ).contains(#""accessToken":"renewed-access""#)
        )
        XCTAssertEqual(renewals.writes.count, 1)
        XCTAssertEqual(renewals.writes.first?.rotatedFrom, expired)
        // Contract change: the Keychain item is now named from the same
        // directory the liveness check uses, so the expectation is derived
        // from this test's own configuration directory rather than from the
        // production account path. That shared resolution is the point —
        // the item written and the directory checked can no longer belong to
        // two different accounts.
        let accountService = ClaudeCodeSyncService.serviceName(
            forConfigurationDirectory: configurationDirectory.path
        )
        let keychainWrite = try XCTUnwrap(keychain.invocations.last)
        XCTAssertEqual(keychainWrite.first, "add-generic-password")
        XCTAssertTrue(keychainWrite.contains(accountService))
        XCTAssertFalse(keychainWrite.contains("Claude Code-credentials"))
        XCTAssertTrue(
            keychainWrite.contains { $0.contains("renewed-access") }
        )
        XCTAssertTrue(
            logMessages.contains(
                "Renewed the terminal sign-in for profile "
                    + "'Terminal-only fixture' without a browser sign-in."
            )
        )
        XCTAssertFalse(
            logMessages.contains {
                $0.contains("Adopted Claude Code's live login")
            }
        )
        XCTAssertEqual(usage.sessionPercentage, 0)
    }

    func testCancellingTerminalPreparationStillStoresAndMirrorsRotation()
        async throws
    {
        let expired = Self.credentialsJSON(expiresAt: 1_000)
        let profile = terminalOnlyProfile(credentialsJSON: expired)
        let store = makeIsolatedProfileStore()
        try seedProfilesForTesting([profile], in: store)
        try store.saveCLIProfileCredential(expired, for: profile.id)
        let manager = ProfileManager(profileStore: store)
        manager.profiles = [profile]
        let renewals = RenewedCredentialRecorder()
        var logMessages: [String] = []
        let keychain = TerminalRenewalSecurityRunner(holding: expired)
        // Claude Code's refresh and store-write locks are directories inside
        // the account's configuration directory; a fixture account must not
        // make one under the developer's real `~/.claude-accounts`.
        let configurationDirectory = makeIsolatedClaudeConfigurationDirectory()
        let cliSync = ClaudeCodeSyncService(
            profileStore: store,
            systemCredentialsReader: { expired },
            securityRunner: keychain,
            credentialsFileDirectory: { _ in configurationDirectory },
            liveProcessDetector: .stubbedIdle()
        )
        let service = ClaudeAPIService(
            profileManager: manager,
            systemCredentialsReader: { nil },
            renewedCredentialWriter: { renewal, profileID in
                renewals.record(
                    renewal.credentialsJSON,
                    rotatedFrom: renewal.rotatedFrom,
                    for: profileID
                )
                try cliSync.saveRefreshedCredentials(
                    renewal.credentialsJSON,
                    for: profileID,
                    rotatedFrom: renewal.rotatedFrom
                )
            },
            loggingService: LoggingService { logMessages.append($0) }
        )
        useIsolatedClaudeCodeLocks(on: service, in: configurationDirectory)
        let refreshStarted = expectation(description: "token refresh started")
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            holdTokenRefreshResponse: true,
            onTokenRefreshStarted: { refreshStarted.fulfill() }
        )

        let cancelledWaitEnded = expectation(
            description: "cancelled preparation stopped waiting"
        )
        let cancelledPreparation = Task { @MainActor in
            defer { cancelledWaitEnded.fulfill() }
            try await service.captureUsageRequestPreparingTerminalSignIn(
                for: profile
            )
        }
        await fulfillment(of: [refreshStarted], timeout: 2)
        cancelledPreparation.cancel()
        await fulfillment(of: [cancelledWaitEnded], timeout: 2)
        StubClaudeEndpointsURLProtocol.releaseTokenRefreshResponse()
        do {
            _ = try await cancelledPreparation.value
            XCTFail("the cancelled owner must stop waiting")
        } catch {
            XCTAssertTrue(cancelledPreparation.isCancelled)
        }

        let laterCapture = try await service
            .captureUsageRequestPreparingTerminalSignIn(for: profile)

        XCTAssertTrue(laterCapture.capturesOAuthToken("renewed-access"))
        XCTAssertEqual(renewals.writes.count, 1)
        XCTAssertTrue(
            try XCTUnwrap(
                store.loadProfileCredentials(profile.id).cliCredentialsJSON
            ).contains(#""accessToken":"renewed-access""#)
        )
        let keychainWrite = try XCTUnwrap(keychain.invocations.last)
        XCTAssertEqual(keychainWrite.first, "add-generic-password")
        XCTAssertTrue(
            keychainWrite.contains { $0.contains("renewed-access") }
        )
        XCTAssertTrue(
            logMessages.contains(
                "Finished renewing the terminal sign-in for Claude Code "
                    + "account 'fixture-account' after its refresh job was "
                    + "cancelled; the rotated login was stored."
            )
        )
    }

    func testConcurrentTerminalPreparationWaitersShareOneTokenRefresh()
        async throws
    {
        let expired = Self.credentialsJSON(expiresAt: 1_000)
        let profile = terminalOnlyProfile(credentialsJSON: expired)
        let store = makeIsolatedProfileStore()
        try seedProfilesForTesting([profile], in: store)
        try store.saveCLIProfileCredential(expired, for: profile.id)
        let manager = ProfileManager(profileStore: store)
        manager.profiles = [profile]
        let renewals = RenewedCredentialRecorder()
        let service = makeIsolatedClaudeAPIService(
            profileManager: manager,
            store: store,
            renewals: renewals
        )
        let refreshStarted = expectation(description: "token refresh started")
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            holdTokenRefreshResponse: true,
            onTokenRefreshStarted: { refreshStarted.fulfill() }
        )

        let first = Task { @MainActor in
            try await service.captureUsageRequestPreparingTerminalSignIn(
                for: profile
            )
        }
        await fulfillment(of: [refreshStarted], timeout: 2)
        let second = Task { @MainActor in
            try await service.captureUsageRequestPreparingTerminalSignIn(
                for: profile
            )
        }
        await Task.yield()
        StubClaudeEndpointsURLProtocol.releaseTokenRefreshResponse()

        let firstRequest = try await first.value
        let secondRequest = try await second.value
        XCTAssertTrue(firstRequest.capturesOAuthToken("renewed-access"))
        XCTAssertTrue(secondRequest.capturesOAuthToken("renewed-access"))
        XCTAssertEqual(
            StubClaudeEndpointsURLProtocol.requestedURLs.filter {
                $0 == ClaudeCLITokenRefresher.tokenEndpoint
            }.count,
            1
        )
        XCTAssertEqual(renewals.writes.count, 1)
    }

    func testSharedTerminalCredentialRefreshRotatesEveryJoinedProfile()
        async throws
    {
        let expired = Self.credentialsJSON(expiresAt: 1_000)
        let firstProfile = terminalOnlyProfile(credentialsJSON: expired)
        var joiningProfile = terminalOnlyProfile(credentialsJSON: expired)
        joiningProfile.name = "Joined terminal-only fixture"
        let store = makeIsolatedProfileStore()
        try seedProfilesForTesting([firstProfile, joiningProfile], in: store)
        try store.saveCLIProfileCredential(expired, for: firstProfile.id)
        try store.saveCLIProfileCredential(expired, for: joiningProfile.id)
        let manager = ProfileManager(profileStore: store)
        manager.profiles = [firstProfile, joiningProfile]
        let renewals = RenewedCredentialRecorder()
        let service = makeIsolatedClaudeAPIService(
            profileManager: manager,
            store: store,
            renewals: renewals
        )
        let refreshStarted = expectation(description: "token refresh started")
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            holdTokenRefreshResponse: true,
            onTokenRefreshStarted: { refreshStarted.fulfill() }
        )

        let first = Task { @MainActor in
            try await service.captureUsageRequestPreparingTerminalSignIn(
                for: firstProfile
            )
        }
        await fulfillment(of: [refreshStarted], timeout: 2)
        let joined = Task { @MainActor in
            try await service.captureUsageRequestPreparingTerminalSignIn(
                for: joiningProfile
            )
        }
        await Task.yield()
        StubClaudeEndpointsURLProtocol.releaseTokenRefreshResponse()

        let firstRequest = try await first.value
        let joinedRequest = try await joined.value
        XCTAssertTrue(firstRequest.capturesOAuthToken("renewed-access"))
        XCTAssertTrue(joinedRequest.capturesOAuthToken("renewed-access"))
        XCTAssertEqual(
            StubClaudeEndpointsURLProtocol.requestedURLs.filter {
                $0 == ClaudeCLITokenRefresher.tokenEndpoint
            }.count,
            1
        )
        XCTAssertEqual(renewals.writes.count, 2)
        XCTAssertEqual(
            Set(renewals.writes.map(\.profileID)),
            Set([firstProfile.id, joiningProfile.id])
        )

        let laterFirst = try await service
            .captureUsageRequestPreparingTerminalSignIn(for: firstProfile)
        let laterJoiner = try await service
            .captureUsageRequestPreparingTerminalSignIn(for: joiningProfile)
        XCTAssertTrue(laterFirst.capturesOAuthToken("renewed-access"))
        XCTAssertTrue(laterJoiner.capturesOAuthToken("renewed-access"))
        XCTAssertEqual(
            StubClaudeEndpointsURLProtocol.requestedURLs.filter {
                $0 == ClaudeCLITokenRefresher.tokenEndpoint
            }.count,
            1
        )
    }

    func testCancelledSharedTerminalCredentialRefreshStillRotatesJoiner()
        async throws
    {
        let expired = Self.credentialsJSON(expiresAt: 1_000)
        let firstProfile = terminalOnlyProfile(credentialsJSON: expired)
        var joiningProfile = terminalOnlyProfile(credentialsJSON: expired)
        joiningProfile.name = "Joined terminal-only fixture"
        let store = makeIsolatedProfileStore()
        try seedProfilesForTesting([firstProfile, joiningProfile], in: store)
        try store.saveCLIProfileCredential(expired, for: firstProfile.id)
        try store.saveCLIProfileCredential(expired, for: joiningProfile.id)
        let manager = ProfileManager(profileStore: store)
        manager.profiles = [firstProfile, joiningProfile]
        let renewals = RenewedCredentialRecorder()
        let service = makeIsolatedClaudeAPIService(
            profileManager: manager,
            store: store,
            renewals: renewals
        )
        let refreshStarted = expectation(description: "token refresh started")
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            holdTokenRefreshResponse: true,
            onTokenRefreshStarted: { refreshStarted.fulfill() }
        )

        let cancelledWaitEnded = expectation(
            description: "cancelled preparation stopped waiting"
        )
        let first = Task { @MainActor in
            defer { cancelledWaitEnded.fulfill() }
            return try await service.captureUsageRequestPreparingTerminalSignIn(
                for: firstProfile
            )
        }
        await fulfillment(of: [refreshStarted], timeout: 2)
        first.cancel()
        await fulfillment(of: [cancelledWaitEnded], timeout: 2)
        _ = try? await first.value

        let joined = Task { @MainActor in
            try await service.captureUsageRequestPreparingTerminalSignIn(
                for: joiningProfile
            )
        }
        await Task.yield()
        StubClaudeEndpointsURLProtocol.releaseTokenRefreshResponse()

        let joinedRequest = try await joined.value
        XCTAssertTrue(joinedRequest.capturesOAuthToken("renewed-access"))
        XCTAssertEqual(
            StubClaudeEndpointsURLProtocol.requestedURLs.filter {
                $0 == ClaudeCLITokenRefresher.tokenEndpoint
            }.count,
            1
        )
        XCTAssertEqual(renewals.writes.count, 2)
        XCTAssertEqual(
            Set(renewals.writes.map(\.profileID)),
            Set([firstProfile.id, joiningProfile.id])
        )
        for profileID in [firstProfile.id, joiningProfile.id] {
            XCTAssertTrue(
                try XCTUnwrap(
                    store.loadProfileCredentials(profileID).cliCredentialsJSON
                ).contains(#""accessToken":"renewed-access""#)
            )
        }
    }

    func testCancelledPersonalExtraUsageWaitStillPersistsTokenRotation()
        async throws
    {
        let profileID = UUID()
        let expired = Self.credentialsJSON(expiresAt: 1_000)
        let store = makeIsolatedProfileStore()
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            credentialsJSON: expired,
            in: store
        )
        let renewals = RenewedCredentialRecorder()
        let service = try makeService(
            profileID: profileID,
            store: store,
            renewals: renewals
        )
        let profile = try seededProfile(profileID)
        let refreshStarted = expectation(description: "token refresh started")
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            holdTokenRefreshResponse: true,
            onTokenRefreshStarted: { refreshStarted.fulfill() }
        )

        let cancelledWaitEnded = expectation(
            description: "cancelled personal reading stopped waiting"
        )
        let cancelledReading = Task { @MainActor in
            defer { cancelledWaitEnded.fulfill() }
            try await service.fetchUsageData(
                sessionKey: "sk-ant-sid01-fixture-session-key-value",
                organizationId: teamOrganizationID,
                profile: profile
            )
        }
        await fulfillment(of: [refreshStarted], timeout: 2)
        cancelledReading.cancel()
        await fulfillment(of: [cancelledWaitEnded], timeout: 2)
        StubClaudeEndpointsURLProtocol.releaseTokenRefreshResponse()
        _ = try? await cancelledReading.value

        _ = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: profile
        )

        XCTAssertEqual(renewals.writes.count, 1)
        XCTAssertTrue(
            renewals.carriesAccessToken("renewed-access", for: profileID)
        )
        XCTAssertTrue(
            try XCTUnwrap(
                store.loadProfileCredentials(profileID).cliCredentialsJSON
            ).contains(#""accessToken":"renewed-access""#)
        )
    }

    func testSupersedingPreparationJoinsRefreshInsteadOfRetryingSpentToken()
        async throws
    {
        let expired = Self.credentialsJSON(expiresAt: 1_000)
        let profile = terminalOnlyProfile(credentialsJSON: expired)
        let store = makeIsolatedProfileStore()
        try seedProfilesForTesting([profile], in: store)
        try store.saveCLIProfileCredential(expired, for: profile.id)
        let manager = ProfileManager(profileStore: store)
        manager.profiles = [profile]
        let service = makeIsolatedClaudeAPIService(
            profileManager: manager,
            store: store
        )
        let refreshStarted = expectation(description: "token refresh started")
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            holdTokenRefreshResponse: true,
            onTokenRefreshStarted: { refreshStarted.fulfill() }
        )

        let supersededWaitEnded = expectation(
            description: "superseded preparation stopped waiting"
        )
        let superseded = Task { @MainActor in
            defer { supersededWaitEnded.fulfill() }
            try await service.captureUsageRequestPreparingTerminalSignIn(
                for: profile
            )
        }
        await fulfillment(of: [refreshStarted], timeout: 2)
        superseded.cancel()
        await fulfillment(of: [supersededWaitEnded], timeout: 2)
        _ = try? await superseded.value
        let replacement = Task { @MainActor in
            try await service.captureUsageRequestPreparingTerminalSignIn(
                for: profile
            )
        }
        await Task.yield()

        XCTAssertEqual(
            StubClaudeEndpointsURLProtocol.requestedURLs.filter {
                $0 == ClaudeCLITokenRefresher.tokenEndpoint
            }.count,
            1,
            "the replacement must join the exchange already spending this token"
        )
        StubClaudeEndpointsURLProtocol.releaseTokenRefreshResponse()
        let request = try await replacement.value

        XCTAssertTrue(request.capturesOAuthToken("renewed-access"))
        XCTAssertEqual(
            StubClaudeEndpointsURLProtocol.requestedURLs.filter {
                $0 == ClaudeCLITokenRefresher.tokenEndpoint
            }.count,
            1
        )
    }

    func testTimedOutTokenExchangeIsNotRetriedWithTheSameRefreshToken()
        async throws
    {
        let expired = Self.credentialsJSON(expiresAt: 1_000)
        let profile = terminalOnlyProfile(credentialsJSON: expired)
        let store = makeIsolatedProfileStore()
        try seedProfilesForTesting([profile], in: store)
        try store.saveCLIProfileCredential(expired, for: profile.id)
        let manager = ProfileManager(profileStore: store)
        manager.profiles = [profile]
        let service = makeIsolatedClaudeAPIService(
            profileManager: manager,
            store: store
        )
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            transportErrors: [
                ClaudeCLITokenRefresher.tokenEndpoint: .timedOut
            ]
        )

        for _ in 0..<2 {
            do {
                _ = try await service
                    .captureUsageRequestPreparingTerminalSignIn(for: profile)
                XCTFail("an exchange with no knowable result is not usable")
            } catch let error as AppError {
                XCTAssertEqual(error.code, .sessionKeyNotFound)
            }
        }

        XCTAssertEqual(
            StubClaudeEndpointsURLProtocol.requestedURLs.filter {
                $0 == ClaudeCLITokenRefresher.tokenEndpoint
            }.count,
            1,
            "a timeout may have spent the token, so the old token is never replayed"
        )
    }

    func testTerminalOnlyRefreshAdoptsLiveLoginAfterInvalidGrant()
        async throws
    {
        let expired = Self.credentialsJSON(expiresAt: 1_000)
        let live = Self.liveLoginJSON(
            expiresAt: Date().addingTimeInterval(8 * 3_600)
                .timeIntervalSince1970 * 1_000
        )
        let profile = terminalOnlyProfile(credentialsJSON: expired)
        let store = makeIsolatedProfileStore()
        try seedProfilesForTesting([profile], in: store)
        try store.saveCLIProfileCredential(expired, for: profile.id)
        let manager = ProfileManager(profileStore: store)
        manager.profiles = [profile]
        var liveReads = 0
        var logMessages: [String] = []
        let service = makeIsolatedClaudeAPIService(
            profileManager: manager,
            store: store,
            systemCredentials: {
                liveReads += 1
                return live
            },
            loggingService: LoggingService {
                logMessages.append($0)
            }
        )
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            tokenRefreshStatusCode: 400
        )

        let first = try await service
            .captureUsageRequestPreparingTerminalSignIn(for: profile)
        _ = try await service.fetchUsageData(using: first)
        let second = try await service
            .captureUsageRequestPreparingTerminalSignIn(for: profile)

        XCTAssertEqual(first.source, .profileCLI)
        XCTAssertTrue(first.capturesOAuthToken("live-access-token"))
        XCTAssertTrue(second.capturesOAuthToken("live-access-token"))
        XCTAssertEqual(liveReads, 1)
        XCTAssertTrue(
            try XCTUnwrap(
                store.loadProfileCredentials(profile.id).cliCredentialsJSON
            ).contains(#""accessToken":"live-access-token""#)
        )
        XCTAssertTrue(
            logMessages.contains(
                "Adopted Claude Code's live login for profile "
                    + "'Terminal-only fixture' without a browser sign-in."
            )
        )
        XCTAssertFalse(
            logMessages.contains { $0.contains("Renewed the terminal sign-in") }
        )
    }

    func testLiveRefreshRuntimePreparesTerminalOnlyLoginBeforeFetching()
        async throws
    {
        let expired = Self.credentialsJSON(expiresAt: 1_000)
        let profile = terminalOnlyProfile(credentialsJSON: expired)
        let store = makeIsolatedProfileStore()
        try seedProfilesForTesting([profile], in: store)
        try store.saveCLIProfileCredential(expired, for: profile.id)
        let manager = ProfileManager(profileStore: store)
        manager.profiles = [profile]
        manager.activeProfile = profile
        let renewals = RenewedCredentialRecorder()
        let service = makeIsolatedClaudeAPIService(
            profileManager: manager,
            store: store,
            renewals: renewals
        )
        let completed = expectation(description: "live refresh completed")
        let runtime = UsageRefreshRuntime.live(
            profileManager: manager,
            apiService: service,
            statusService: ClaudeStatusService(),
            featureAvailability: .testing(),
            batchObserver: { _ in completed.fulfill() }
        )
        runtime.activate(
            profiles: [profile],
            focusedProfileID: profile.id,
            visibleProfileIDs: [profile.id],
            epoch: 1
        )
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID
        )

        _ = await runtime.refresh(
            profiles: [profile],
            trigger: .manual
        ).value
        await fulfillment(of: [completed], timeout: 2)

        XCTAssertEqual(
            StubClaudeEndpointsURLProtocol.requestedURLs.filter {
                $0 == ClaudeCLITokenRefresher.tokenEndpoint
            }.count,
            1
        )
        XCTAssertTrue(
            renewals.carriesAccessToken("renewed-access", for: profile.id)
        )
        let snapshot = try XCTUnwrap(
            runtime.presentationStore.snapshot(for: profile.id)
        )
        XCTAssertNotNil(snapshot.report)
        XCTAssertNil(snapshot.currentFailure)
        await runtime.shutdownAndWait(profiles: [profile])
    }

    func testTerminalOnlyDeadLoginFailsAndIsNotRenewedAgainNextCycle()
        async throws
    {
        let expired = Self.credentialsJSON(expiresAt: 1_000)
        let profile = terminalOnlyProfile(credentialsJSON: expired)
        let store = makeIsolatedProfileStore()
        try seedProfilesForTesting([profile], in: store)
        try store.saveCLIProfileCredential(expired, for: profile.id)
        let manager = ProfileManager(profileStore: store)
        manager.profiles = [profile]
        var liveReads = 0
        var logMessages: [String] = []
        let service = makeIsolatedClaudeAPIService(
            profileManager: manager,
            store: store,
            systemCredentials: {
                liveReads += 1
                return nil
            },
            loggingService: LoggingService {
                logMessages.append($0)
            }
        )
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            tokenRefreshStatusCode: 400
        )

        for _ in 0..<2 {
            do {
                _ = try await service
                    .captureUsageRequestPreparingTerminalSignIn(for: profile)
                XCTFail("a settled dead login must remain unauthenticated")
            } catch let error as AppError {
                XCTAssertEqual(error.code, .sessionKeyNotFound)
            }
        }

        XCTAssertEqual(
            StubClaudeEndpointsURLProtocol.requestedURLs.filter {
                $0 == ClaudeCLITokenRefresher.tokenEndpoint
            }.count,
            1
        )
        XCTAssertEqual(liveReads, 1)
        XCTAssertFalse(
            logMessages.contains { message in
                message.contains("Renewed the terminal sign-in")
                    || message.contains("Adopted Claude Code's live login")
            }
        )
    }

    /// Inverted deliberately. Under CLI-first the Claude Code sign-in
    /// produces every number, so a browser-backed profile whose stored CLI
    /// token has expired must attempt the renewal that fixes it. It used to
    /// be handed straight to the synchronous capture, which meant the renewal
    /// machinery never ran for it and the profile fell back to claude.ai
    /// forever.
    func testBrowserBackedRefreshEntersTerminalRenewalPath()
        async throws
    {
        let profile = Profile(
            id: UUID(),
            name: "Browser fixture",
            claudeSessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            cliCredentialsJSON: Self.credentialsJSON(expiresAt: 1_000),
            hasCliAccount: true,
            cliAccountName: "fixture-account"
        )
        let store = makeIsolatedProfileStore()
        try seedProfilesForTesting([profile], in: store)
        let manager = ProfileManager(profileStore: store)
        manager.profiles = [profile]
        let service = makeIsolatedClaudeAPIService(
            profileManager: manager,
            store: store
        )
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID
        )

        let request = try await service
            .captureUsageRequestPreparingTerminalSignIn(for: profile)

        XCTAssertTrue(request.capturesOverageCheck(true))
        XCTAssertTrue(
            StubClaudeEndpointsURLProtocol.requestedURLs.contains(
                ClaudeCLITokenRefresher.tokenEndpoint
            ),
            "a browser-backed profile with an expired CLI token must now "
            + "attempt renewal"
        )
        // Whatever the renewal produced, the browser sign-in rides along on
        // the request so the organization-wide extra usage is still
        // reachable.
        XCTAssertTrue(request.carriesBrowserSignIn)
    }

    // MARK: - The CLI as the usage source

    /// The `r3` profile's `/api/oauth/usage` body, saved verbatim from the
    /// live probe on 2026-08-29. Reproduced whole rather than reduced,
    /// because its exact key set is the evidence: `seven_day_opus` and
    /// `seven_day_sonnet` are JSON `null`, `limits` carries one
    /// `weekly_scoped` Fable row at 20% and no Opus or Sonnet entry, and ten
    /// codename windows sit alongside them. Every per-model assertion below
    /// is about one of those three facts, and a hand-written fixture would
    /// let them drift from what the endpoint actually sends.
    ///
    /// The 20% matches what the claude.ai path had already stored as
    /// `fableWeeklyPercentage` for the same profile — which is what says the
    /// two sources agree and the Fable row does not regress.
    private static let savedTeamOAuthUsageBody = """
        {
          "amber_ladder": null,
          "cinder_cove": null,
          "extra_usage": {
            "credits_ever_enabled": false,
            "currency": null,
            "daily": null,
            "decimal_places": null,
            "disabled_reason": null,
            "is_enabled": false,
            "monthly_limit": null,
            "spend_limit_reached": false,
            "used_credits": null,
            "user_disabled": false,
            "utilization": null,
            "weekly": null
          },
          "five_hour": {
            "limit_dollars": null,
            "locked_reason": null,
            "remaining_dollars": null,
            "resets_at": null,
            "used_dollars": null,
            "utilization": 0.0
          },
          "iguana_necktie": null,
          "juniper_tide": null,
          "limits": [
            {
              "group": "session",
              "is_active": false,
              "kind": "session",
              "percent": 0,
              "resets_at": null,
              "scope": null,
              "severity": "normal"
            },
            {
              "group": "weekly",
              "is_active": true,
              "kind": "weekly_all",
              "percent": 100,
              "resets_at": "2026-08-30T05:59:59.867369+00:00",
              "scope": null,
              "severity": "critical"
            },
            {
              "group": "weekly",
              "is_active": false,
              "kind": "weekly_scoped",
              "percent": 20,
              "resets_at": "2026-08-30T05:59:59.867631+00:00",
              "scope": {
                "model": {
                  "display_name": "Fable",
                  "id": null
                },
                "surface": null
              },
              "severity": "normal"
            }
          ],
          "member_dashboard_available": false,
          "nimbus_quill": {
            "limit_dollars": null,
            "locked_reason": null,
            "remaining_dollars": null,
            "resets_at": null,
            "used_dollars": null,
            "utilization": 0.0
          },
          "omelette_promotional": null,
          "seven_day": {
            "limit_dollars": null,
            "locked_reason": null,
            "remaining_dollars": null,
            "resets_at": "2026-08-30T05:59:59.867369+00:00",
            "used_dollars": null,
            "utilization": 100.0
          },
          "seven_day_cowork": null,
          "seven_day_oauth_apps": null,
          "seven_day_omelette": null,
          "seven_day_opus": null,
          "seven_day_sonnet": null,
          "spend": {
            "auto_reload": null,
            "balance": null,
            "can_purchase_credits": false,
            "can_toggle": false,
            "cap": null,
            "disabled_reason": null,
            "disclaimer": "Usage credits cover you when you hit your plan limits. [Learn more](https://support.claude.com/articles/12429409)",
            "enabled": false,
            "limit": null,
            "percent": 0,
            "severity": "normal",
            "used": {
              "amount_minor": 0,
              "currency": "USD",
              "exponent": 2
            }
          },
          "tangelo": null
        }
        """

    /// Every window the OAuth body carries, in the shape a live probe
    /// returned. `seven_day_opus` and `seven_day_sonnet` come back as JSON
    /// `null` on a Team account, which is exactly the case the `limits`
    /// array exists to answer.
    private static func oauthUsageBody(
        fiveHour: String = #"{"utilization":12.5,"resets_at":null}"#,
        sevenDay: String = #"{"utilization":100.0,"resets_at":null}"#,
        sevenDayOpus: String = "null",
        limits: String = """
        [{"kind":"session","group":"session","percent":12,"scope":null},
         {"kind":"weekly_all","group":"weekly","percent":100,"scope":null},
         {"kind":"weekly_scoped","group":"weekly","percent":20,
          "scope":{"model":{"id":null,"display_name":"Fable"}}}]
        """,
        extraUsage: String = """
        {"is_enabled":true,"monthly_limit":5000,"used_credits":4200.0,
         "currency":"USD"}
        """
    ) -> String {
        """
        {"five_hour":\(fiveHour),
         "seven_day":\(sevenDay),
         "seven_day_opus":\(sevenDayOpus),
         "seven_day_sonnet":null,
         "nimbus_quill":null,
         "cinder_cove":{"utilization":0.0,"resets_at":null},
         "limits":\(limits),
         "extra_usage":\(extraUsage)}
        """
    }

    /// A profile with a Claude Code sign-in and no browser sign-in — the
    /// population that used to be told its setup was incomplete.
    private func seedTerminalOnlyProfile(
        id: UUID,
        in store: ProfileStore
    ) throws {
        let profile = Profile(
            id: id,
            name: "Terminal only",
            cliCredentialsJSON: Self.credentialsJSON(
                expiresAt: Date()
                    .addingTimeInterval(8 * 3600)
                    .timeIntervalSince1970 * 1000
            ),
            hasCliAccount: true,
            cliAccountName: "fixture-account"
        )
        try seedProfilesForTesting([profile], in: store)
        try store.saveCLIProfileCredential(
            XCTUnwrap(profile.cliCredentialsJSON),
            for: id
        )
        seededProfiles.append(profile)
    }

    func testCLISourcedFetchReadsEveryWindowFromTheOAuthBody() async throws {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedTerminalOnlyProfile(id: profileID, in: store)
        let service = try makeService(profileID: profileID, store: store)
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            oauthUsageBody: Self.oauthUsageBody()
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let usage = try await service.fetchUsageData(
            using: try service.captureUsageRequest(
                for: try seededProfile(profileID)
            )
        )

        XCTAssertEqual(usage.sessionPercentage, 12.5)
        XCTAssertTrue(usage.sessionPercentageAvailable)
        XCTAssertEqual(usage.weeklyPercentage, 100.0)
        XCTAssertTrue(usage.weeklyPercentageAvailable)
    }

    /// Pins the finding that made CLI-first buildable: `/api/oauth/usage`
    /// ships claude.ai's `limits` array, so the Fable row — which has no
    /// legacy top-level key and exists on screen only because of that
    /// array — resolves from the OAuth body with no new parser.
    func testPerModelRowsResolveFromTheOAuthBodysLimitsArray() async throws {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedTerminalOnlyProfile(id: profileID, in: store)
        let service = try makeService(profileID: profileID, store: store)
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            oauthUsageBody: Self.oauthUsageBody()
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let usage = try await service.fetchUsageData(
            using: try service.captureUsageRequest(
                for: try seededProfile(profileID)
            )
        )

        XCTAssertEqual(usage.fableWeeklyPercentage, 20)
        XCTAssertTrue(usage.fableWeeklyLimitAvailable)
        XCTAssertEqual(usage.weeklyPercentage, 100)
        XCTAssertTrue(usage.weeklyPercentageAvailable)
    }

    /// The other half of the saved body, and the reason the two availability
    /// flags exist. `seven_day_opus` and `seven_day_sonnet` are JSON `null`
    /// and `limits` carries no entry for either, so neither model resolves
    /// from anywhere — and `parseUsageResponse` turns that nil into `0.0`.
    ///
    /// Asserted through the flags rather than through `tokensUsed == 0`,
    /// because `tokensUsed > 0` is exactly the inference being replaced: it
    /// happened to hide this particular zero, and it hides a real one just as
    /// thoroughly. claude.ai's own body for this profile returns the same two
    /// nulls, so moving source loses nothing visible — the flags are what
    /// stop the zero becoming visible later.
    func testAbsentOpusAndSonnetWindowsReportThemselvesUnavailable()
        async throws
    {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedTerminalOnlyProfile(id: profileID, in: store)
        let service = try makeService(profileID: profileID, store: store)
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            oauthUsageBody: Self.savedTeamOAuthUsageBody
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let usage = try await service.fetchUsageData(
            using: try service.captureUsageRequest(
                for: try seededProfile(profileID)
            )
        )

        XCTAssertFalse(usage.opusWeeklyLimitAvailable)
        XCTAssertFalse(usage.sonnetWeeklyLimitAvailable)

        // And the rows are genuinely absent from what the popover renders,
        // which is the fact the flags exist to produce.
        let ids = try Self.limitGroupIDs(for: usage)
        XCTAssertFalse(ids.contains("opus"))
        XCTAssertFalse(ids.contains("sonnet"))
        XCTAssertTrue(ids.contains("fable"))
    }

    /// The case `tokensUsed > 0` gets wrong today, and the reason the flag is
    /// an improvement rather than a formality: an account that DOES have an
    /// Opus allowance, measured at 0% because the week just reset, must show
    /// its row. Fable has had this since v4.0.8; Opus and Sonnet never did.
    func testAMeasuredZeroPercentOpusWeekStillShowsItsRow() async throws {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedTerminalOnlyProfile(id: profileID, in: store)
        let service = try makeService(profileID: profileID, store: store)
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            oauthUsageBody: Self.oauthUsageBody(
                sevenDayOpus: #"{"utilization":0,"resets_at":null}"#
            )
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let usage = try await service.fetchUsageData(
            using: try service.captureUsageRequest(
                for: try seededProfile(profileID)
            )
        )

        XCTAssertEqual(usage.opusWeeklyPercentage, 0)
        XCTAssertEqual(usage.opusWeeklyTokensUsed, 0)
        XCTAssertTrue(
            usage.opusWeeklyLimitAvailable,
            "a measured zero is a figure, not a missing window"
        )
        XCTAssertTrue(
            try Self.limitGroupIDs(for: usage).contains("opus"),
            "the row this zero belongs to was hidden by `tokensUsed > 0`"
        )
    }

    /// The rows the popover would draw for a record, by id.
    private static func limitGroupIDs(
        for usage: ClaudeUsage
    ) throws -> [String] {
        try ClaudeUsageProviderAdapter.makeReport(
            from: usage,
            context: ClaudeUsageProviderContext(
                health: ProviderHealth(
                    status: .healthy,
                    checkedAt: Date()
                ),
                fetchedAt: Date()
            )
        ).limitGroups.map(\.id.rawValue)
    }

    /// The §1.5 hardening, end to end. A null legacy key used to satisfy the
    /// legacy branch and return a measured-looking 0%, which also stopped the
    /// fall-through to `limits` — so a good Opus entry was shadowed by a
    /// figure the account never sent.
    func testANullLegacyOpusKeyDoesNotShadowTheLimitsEntry() async throws {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedTerminalOnlyProfile(id: profileID, in: store)
        let service = try makeService(profileID: profileID, store: store)
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            oauthUsageBody: Self.oauthUsageBody(
                sevenDayOpus: #"{"utilization":null,"resets_at":null}"#,
                limits: """
                [{"kind":"weekly_scoped","group":"weekly","percent":37,
                  "scope":{"model":{"display_name":"Opus"}}}]
                """
            )
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let usage = try await service.fetchUsageData(
            using: try service.captureUsageRequest(
                for: try seededProfile(profileID)
            )
        )

        XCTAssertEqual(usage.opusWeeklyPercentage, 37)
        XCTAssertTrue(usage.opusWeeklyLimitAvailable)
    }

    /// The same defect as a pure function, with no URL stub in the way.
    func testNullLegacyUtilizationFallsThroughToTheLimitsArray() throws {
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data("""
                {"seven_day_opus":{"utilization":null},
                 "limits":[{"kind":"weekly_scoped","group":"weekly",
                            "percent":37,
                            "scope":{"model":{"display_name":"Opus"}}}]}
                """.utf8)
            ) as? [String: Any]
        )

        let opus = UsageLimitParsing.parseWeeklyModelUsage(
            from: json,
            legacyKey: "seven_day_opus",
            modelDisplayName: "Opus"
        )

        XCTAssertEqual(opus?.percentage, 37)

        // And with nothing in either place the answer is "no figure", never
        // a zero: that is what hides the row rather than drawing 0%.
        let sonnet = UsageLimitParsing.parseWeeklyModelUsage(
            from: json,
            legacyKey: "seven_day_sonnet",
            modelDisplayName: "Sonnet"
        )
        XCTAssertNil(sonnet)

        // A genuine measured zero still parses as available.
        let measuredZero = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(
                    #"{"seven_day_opus":{"utilization":0}}"#.utf8
                )
            ) as? [String: Any]
        )
        XCTAssertEqual(
            UsageLimitParsing.parseWeeklyModelUsage(
                from: measuredZero,
                legacyKey: "seven_day_opus",
                modelDisplayName: "Opus"
            )?.percentage,
            0
        )
    }

    /// Unrecognised codename windows are read by nothing. Guessing which
    /// model one of them describes would label one model's consumption with
    /// another model's name, so being ignored is the correct handling.
    func testCodenameWindowsAreIgnoredEntirely() async throws {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedTerminalOnlyProfile(id: profileID, in: store)
        let service = try makeService(profileID: profileID, store: store)
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            oauthUsageBody: Self.oauthUsageBody(limits: "[]")
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let usage = try await service.fetchUsageData(
            using: try service.captureUsageRequest(
                for: try seededProfile(profileID)
            )
        )

        XCTAssertFalse(usage.opusWeeklyLimitAvailable)
        XCTAssertFalse(usage.sonnetWeeklyLimitAvailable)
        XCTAssertFalse(usage.fableWeeklyLimitAvailable)
        XCTAssertEqual(usage.sessionPercentage, 12.5)
    }

    /// The member's own extra usage now rides on the same response as the
    /// windows, so a terminal-only profile costs one request where it used to
    /// cost a profile lookup and a usage lookup on top of a Messages call.
    func testCLISourcedFetchTakesTheMemberFigureFromTheSameResponse()
        async throws
    {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedTerminalOnlyProfile(id: profileID, in: store)
        let service = try makeService(profileID: profileID, store: store)
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            oauthUsageBody: Self.oauthUsageBody()
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let usage = try await service.fetchUsageData(
            using: try service.captureUsageRequest(
                for: try seededProfile(profileID)
            )
        )

        XCTAssertEqual(usage.personalCostUsed, 4_200)
        XCTAssertEqual(usage.personalCostLimit, 5_000)
        XCTAssertEqual(usage.personalCostCurrency, "USD")
        XCTAssertFalse(
            StubClaudeEndpointsURLProtocol.requestedURLs.contains {
                $0.hasSuffix("/api/oauth/profile")
            },
            "the organization lookup is only needed to cross-attribute a "
                + "figure from a different credential; here both come from "
                + "one token"
        )
        XCTAssertFalse(
            StubClaudeEndpointsURLProtocol.requestedURLs.contains {
                $0.hasSuffix("/v1/messages")
            },
            "the Messages fallback must not run when the endpoint answered"
        )
    }

    /// The endpoint being disabled again is the reason the header path was
    /// kept rather than deleted.
    func testAMissingOAuthUsageEndpointFallsBackToMessagesHeaders()
        async throws
    {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedTerminalOnlyProfile(id: profileID, in: store)
        let service = try makeService(profileID: profileID, store: store)
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            oauthUsageStatusCode: 404,
            messagesRateLimitHeaders: [
                "anthropic-ratelimit-unified-5h-utilization": "0.25",
                "anthropic-ratelimit-unified-7d-utilization": "0.5"
            ]
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let usage = try await service.fetchUsageData(
            using: try service.captureUsageRequest(
                for: try seededProfile(profileID)
            )
        )

        XCTAssertEqual(usage.sessionPercentage, 25)
        XCTAssertTrue(usage.sessionPercentageAvailable)
        XCTAssertEqual(usage.weeklyPercentage, 50)
        XCTAssertTrue(
            StubClaudeEndpointsURLProtocol.requestedURLs.contains {
                $0.hasSuffix("/v1/messages")
            }
        )
    }

    /// A 401 is the one status that says something about the credential, so
    /// it must not fall back: the Messages endpoint authenticates with the
    /// same token and would refuse it for the same reason, producing a second
    /// differently worded complaint about one dead sign-in.
    func testARefusedCLITokenRaisesUnauthorizedWithoutFallingBack()
        async throws
    {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedTerminalOnlyProfile(id: profileID, in: store)
        let service = try makeService(profileID: profileID, store: store)
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            oauthUsageStatusCode: 401
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let request = try service.captureUsageRequest(
            for: try seededProfile(profileID)
        )
        do {
            _ = try await service.fetchUsageData(using: request)
            XCTFail("a refused CLI token must not produce usage")
        } catch let error as AppError {
            XCTAssertEqual(error.code, .apiUnauthorized)
        }

        XCTAssertFalse(
            StubClaudeEndpointsURLProtocol.requestedURLs.contains {
                $0.hasSuffix("/v1/messages")
            }
        )
        XCTAssertEqual(
            MenuBarAttentionSignal.attention(
                cliSignInIssue: .signInExpired,
                credentialFailureStreak: 0,
                healthStatus: .degraded
            ),
            .claudeCode
        )
    }

    /// The requirement that cannot be inferred from the old model: one
    /// sign-in refused, the other still produces numbers. claude.ai answers
    /// the organization's extra-usage request with the HTTP 403 carrying
    /// `account_session_invalid` that means a dead browser session.
    func testADeadBrowserSessionKeepsTheCLIWindows() async throws {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            in: store
        )
        let service = try makeService(profileID: profileID, store: store)
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            overageSpendLimitStatusCode: 403,
            overageSpendLimitBody: """
                {"type":"error","error":{"type":"permission_error",
                 "message":"Invalid authorization",
                 "details":{"error_code":"account_session_invalid",
                            "error_visibility":"user_facing"}}}
                """,
            oauthUsageBody: Self.oauthUsageBody()
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let usage = try await service.fetchUsageData(
            using: try service.captureUsageRequest(
                for: try seededProfile(profileID)
            )
        )

        XCTAssertEqual(usage.sessionPercentage, 12.5)
        XCTAssertEqual(usage.fableWeeklyPercentage, 20)
        XCTAssertEqual(usage.personalCostUsed, 4_200)
        XCTAssertEqual(usage.browserSignInIssue, .expired)
        XCTAssertNil(usage.costUsed)
    }

    /// A server fault is not a credential verdict, so it stays silent — the
    /// same discipline the Claude Code side has always followed.
    func testAFailingOrganizationRequestKeepsTheWindowsAndStaysSilent()
        async throws
    {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            in: store
        )
        let service = try makeService(profileID: profileID, store: store)
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            overageSpendLimitStatusCode: 500,
            oauthUsageBody: Self.oauthUsageBody()
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let usage = try await service.fetchUsageData(
            using: try service.captureUsageRequest(
                for: try seededProfile(profileID)
            )
        )

        XCTAssertEqual(usage.sessionPercentage, 12.5)
        XCTAssertEqual(usage.browserSignInIssue, .temporarilyUnavailable)
        XCTAssertNil(
            MenuBarAttentionSignal.attention(
                cliSignInIssue: nil,
                browserSignInIssue: .temporarilyUnavailable,
                credentialFailureStreak: 0,
                healthStatus: .healthy
            )
        )
    }

    /// A browser-only profile is unchanged: no Claude Code credential exists,
    /// so claude.ai remains the source and the whole existing sequence runs.
    func testABrowserOnlyProfileStillFetchesFromClaudeAI() async throws {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        let profile = Profile(
            id: profileID,
            name: "Browser only",
            claudeSessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            organizationIsPersonal: false
        )
        try seedProfilesForTesting([profile], in: store)
        seededProfiles.append(profile)
        let service = try makeService(profileID: profileID, store: store)
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let request = try service.captureUsageRequest(
            for: try seededProfile(profileID)
        )
        XCTAssertEqual(request.source, .claudeAI)

        let usage = try await service.fetchUsageData(using: request)

        XCTAssertEqual(usage.costUsed, 26_118)
        XCTAssertTrue(
            StubClaudeEndpointsURLProtocol.requestedURLs.contains {
                $0.hasSuffix("/organizations/\(teamOrganizationID)/usage")
            }
        )
    }

    // MARK: - Catalog

    func testEnglishCatalogCarriesEveryPersonalUsageMessage() throws {
        let path = try XCTUnwrap(
            Bundle.main.path(forResource: "en", ofType: "lproj")
        )
        let english = try XCTUnwrap(Bundle(path: path))

        // Each names the missing connection and where to fix it. A profile
        // signs in twice — claude.ai in a browser, and Claude Code — so a
        // message that says only "connect your account" cannot be acted on.
        XCTAssertEqual(
            english.localizedString(
                forKey: "popover.extra_usage.cli_not_linked",
                value: nil,
                table: nil
            ),
            "This is your organization's total. Your own extra usage comes "
                + "from Claude Code, which isn't linked to this account yet "
                + "— add it in Settings → CLI Account."
        )
        // Signing in again is now necessary AND sufficient. This message
        // used to end "then re-sync it in Settings → CLI Account — signing in
        // alone doesn't reach the app", which was true when the app only ever
        // re-read the real login on a re-sync or a profile activation. It no
        // longer is: `adoptLiveCLILogin(for:replacing:)` performs that read
        // itself when its own copy cannot be renewed, so the next refresh
        // picks up a fresh sign-in unaided. Asking for the re-sync anyway was
        // asking for the one step that was not needed — observed live, on a
        // profile whose CLI login was valid the entire time.
        XCTAssertEqual(
            english.localizedString(
                forKey: "popover.extra_usage.cli_sign_in_expired",
                value: nil,
                table: nil
            ),
            "This is your organization's total. Claude Code's sign-in for "
                + "this account has expired. Sign in to Claude Code again "
                + "and your own extra usage will reappear on its own."
        )
        // Reaching this state now means the app already looked at the login
        // Claude Code holds and found none usable there either, so the
        // account really is signed out — and signing in is again the whole
        // remedy, with no manual re-import to ask for.
        XCTAssertEqual(
            english.localizedString(
                forKey: "popover.extra_usage.cli_sign_in_has_no_token",
                value: nil,
                table: nil
            ),
            "This is your organization's total. Claude Code is signed out of "
                + "the account linked here, so there's no sign-in to read "
                + "your own extra usage with. Sign in to it and this will "
                + "fill in on its own."
        )
        // No instruction, deliberately. The re-sync this used to name has
        // already been performed by the app itself before this verdict is
        // reached, and the Re-sync import validates JSON shape only — so
        // steering someone toward it asks them to repeat a step that just
        // failed, on a button that can overwrite a working login with an
        // empty one.
        XCTAssertEqual(
            english.localizedString(
                forKey: "popover.extra_usage.cli_sign_in_unusable",
                value: nil,
                table: nil
            ),
            "This is your organization's total. Your own extra usage couldn't "
                + "be read with the Claude Code account linked here."
        )
        XCTAssertEqual(
            english.localizedString(
                forKey: "popover.extra_usage.absent.cli_sign_in_unusable",
                value: nil,
                table: nil
            ),
            "Your extra usage couldn't be read with the Claude Code account "
                + "linked here."
        )
        XCTAssertEqual(
            english.localizedString(
                forKey: "popover.extra_usage.cli_temporarily_unavailable",
                value: nil,
                table: nil
            ),
            "This is your organization's total. Your own extra usage couldn't "
                + "be read this time. It will be retried automatically."
        )
        XCTAssertEqual(
            english.localizedString(
                forKey: "popover.extra_usage.absent.cli_temporarily_unavailable",
                value: nil,
                table: nil
            ),
            "Your extra usage couldn't be read this time. It will be retried "
                + "automatically."
        )
        for key in [
            "cli.login_expired_title",
            "cli.login_expired_explain",
            "cli.login_expired_then_resync"
        ] {
            XCTAssertNotEqual(
                english.localizedString(forKey: key, value: nil, table: nil),
                key,
                "\(key) is missing from the English catalog."
            )
        }
        XCTAssertEqual(
            english.localizedString(
                forKey: "popover.extra_usage.cli_other_organization",
                value: nil,
                table: nil
            ),
            "This is your organization's total. Your linked Claude Code "
                + "account belongs to a different organization, so its usage "
                + "isn't shown here."
        )
        XCTAssertEqual(
            english.localizedString(
                forKey: "popover.extra_usage.claude_account_unresolved",
                value: nil,
                table: nil
            ),
            "This is your organization's total. Your own usage couldn't be "
                + "matched to this organization — reconnect your account in "
                + "Settings → Claude Account."
        )
    }

    // MARK: - Settled answers must not become user homework

    /// A successful, well-formed response that simply carries no figure.
    ///
    /// `is_enabled` is true and the credit fields are absent, which is Claude
    /// saying "there is nothing here" — the same class of answer as extra
    /// usage being switched off, which has always been silent. It used to be
    /// recorded as `.signInUnusable`, so a request that had just succeeded
    /// produced a notice telling the reader to re-sync a working sign-in.
    /// That branch also logged nothing at all, which is why the notice
    /// appeared on nearly every profile while the log showed almost no
    /// warnings.
    func testAnEnabledExtraUsageWithNoCreditFiguresStaysSilent() async throws {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            in: store
        )
        let service = try makeService(profileID: profileID, store: store)

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            memberExtraUsageCarriesCreditFigures: false
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let usage = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: try seededProfile(profileID)
        )

        XCTAssertNil(
            usage.personalExtraUsageIssue,
            "a complete answer carrying no figure is settled, and settled "
                + "answers say nothing"
        )
        XCTAssertNil(usage.personalCostUsed)
        XCTAssertNil(usage.personalCostLimit)
        // The request really did go out and really did succeed: this is not
        // silence from having skipped the endpoint.
        XCTAssertTrue(
            StubClaudeEndpointsURLProtocol.requestedURLs.contains {
                $0.hasSuffix("/api/oauth/usage")
            }
        )
        XCTAssertEqual(usage.costUsed, 26_118)
    }

    /// Provably distinct from the settled answer above: a credential that
    /// cannot be made usable still reports itself. The two states share a
    /// code path up to the last guard, and collapsing them is exactly the
    /// defect this pair exists to prevent recurring.
    func testARejectedCredentialIsStillDistinguishableFromNoFigure()
        async throws
    {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            credentialsJSON: Self.credentialsJSON(expiresAt: 1_000),
            in: store
        )
        let service = try makeService(profileID: profileID, store: store)

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            tokenRefreshStatusCode: 400
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let usage = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: try seededProfile(profileID)
        )

        XCTAssertEqual(usage.personalExtraUsageIssue, .signInExpired)
    }

    /// An account with no organization behind it — a personal Max/Pro
    /// subscription — is a settled fact, not a broken credential.
    ///
    /// Three unrelated outcomes used to collapse into one nil here: the
    /// request failed, the body did not decode, and the body parsed perfectly
    /// and carried no `organization`. The caller could only read that nil as
    /// "the sign-in is unusable", which is why the notice appeared on every
    /// one of the maintainer's profiles except the single team account — the
    /// only one with an organization to report.
    ///
    /// Two fetches, because the settled answer has to hold across refreshes
    /// rather than merely be right once. What proves it is not being treated
    /// as a *failure* is the silence: a latched failure short-circuits too,
    /// but goes on reporting `.temporarilyUnavailable` to the reader every
    /// time — see
    /// `testAFailedProfileRequestIsRetriedUnlikeAMissingOrganization`, which
    /// is the same shape with the opposite verdict.
    func testAnAccountWithNoOrganizationStaysSilentAndIsNotLatched()
        async throws
    {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            in: store
        )
        let service = try makeService(profileID: profileID, store: store)

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            oauthProfileCarriesOrganization: false
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let profile = try seededProfile(profileID)
        for _ in 0..<2 {
            let usage = try await service.fetchUsageData(
                sessionKey: "sk-ant-sid01-fixture-session-key-value",
                organizationId: teamOrganizationID,
                profile: profile
            )
            XCTAssertNil(
                usage.personalExtraUsageIssue,
                "there is no organization-scoped figure to attribute and "
                    + "nothing anyone can do about it, so nothing is said"
            )
            XCTAssertNil(usage.personalCostUsed)
            XCTAssertEqual(usage.costUsed, 26_118)
        }

        XCTAssertEqual(
            StubClaudeEndpointsURLProtocol.requestedURLs.filter {
                $0.hasSuffix("/api/oauth/profile")
            }.count,
            1,
            "the answer cannot change while the credential does not, so it "
                + "is asked once rather than on every refresh"
        )
        XCTAssertFalse(
            StubClaudeEndpointsURLProtocol.requestedURLs.contains {
                $0.hasSuffix("/api/oauth/usage")
            },
            "with no organization there is nothing to scope a member figure "
                + "to, so the member endpoint must never be asked"
        )
    }

    /// The settled answer is remembered against the credential that gave it,
    /// and only against that one.
    ///
    /// Both halves are load-bearing, and each guards a different way of
    /// "simplifying" this back into a defect. Dropping the memory returns one
    /// profile GET per personal profile per refresh tick — and on a machine
    /// holding mostly personal subscriptions that is most of them, against an
    /// API whose 429 responses this file already blames on exactly that kind
    /// of per-tick per-profile traffic. Keying it on the profile alone
    /// instead of the credential would make a profile re-linked to a
    /// different Claude Code account keep answering with the old account's
    /// verdict, so a member who moved onto a team would never see their own
    /// figure again until the app restarted.
    func testASettledNoOrganizationAnswerIsRememberedPerCredential()
        async throws
    {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            in: store
        )
        let service = try makeService(profileID: profileID, store: store)

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            oauthProfileCarriesOrganization: false
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let profile = try seededProfile(profileID)
        for _ in 0..<2 {
            _ = try await service.fetchUsageData(
                sessionKey: "sk-ant-sid01-fixture-session-key-value",
                organizationId: teamOrganizationID,
                profile: profile
            )
        }

        XCTAssertEqual(
            profileLookupCount(),
            1,
            "two refreshes over one unchanged credential must ask once"
        )

        // The profile is re-linked: a different Claude Code login is now
        // presented. The remembered answer belonged to the old credential and
        // says nothing about this one.
        var relinked = profile
        relinked.cliCredentialsJSON = Self.liveLoginJSON(
            expiresAt: Date()
                .addingTimeInterval(8 * 3600)
                .timeIntervalSince1970 * 1000
        )

        let afterRelink = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: relinked
        )

        XCTAssertEqual(
            profileLookupCount(),
            2,
            "a different credential has not been asked yet, so it must be"
        )
        XCTAssertNil(
            afterRelink.personalExtraUsageIssue,
            "this account still reports no organization; remembering that "
                + "must never turn into reporting a problem"
        )
    }

    /// A rotated token must not throw the settled answer away.
    ///
    /// The answer is keyed on the credential fingerprint, and Anthropic's
    /// OAuth rotates the refresh token on use — so without rolling the entry
    /// forward onto the refreshed credential, the cache misses on essentially
    /// every refresh that follows a rotation and the lookup runs anyway. It
    /// would look present and do nothing, restoring the per-tick request
    /// volume it was added to remove. Its sibling
    /// `cliOrganizationCredentialHashes` has always been rolled forward for
    /// the same reason; this asserts the symmetry.
    ///
    /// The credential is seeded valid and expires between the two readings,
    /// which is the only way to get a rotation to land *after* the answer was
    /// recorded. Both renewal assertions are load-bearing against a slow
    /// machine: if the first reading were to rotate the token itself the
    /// second would trivially hit the cache, so this would pass without
    /// testing anything — asserting that the first reading renewed nothing
    /// and the second one did turns that timing slip into a failure instead.
    func testASettledNoOrganizationAnswerSurvivesATokenRotation()
        async throws
    {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            credentialsJSON: Self.credentialsJSON(
                expiresAt: Date()
                    .addingTimeInterval(2.5)
                    .timeIntervalSince1970 * 1000
            ),
            in: store
        )
        let renewals = RenewedCredentialRecorder()
        let service = try makeService(
            profileID: profileID,
            store: store,
            renewals: renewals
        )
        let profile = try seededProfile(profileID)
        // Contract change: renewal now starts five minutes before expiry,
        // the way Claude Code's does, so a credential 2.5 seconds from
        // expiry is already due. This test is about an answer surviving a
        // rotation, not about when one starts, and no suite can wait five
        // minutes for the boundary — so the lead time is put back to zero
        // and the original timing is preserved.
        service.cliRefreshLeadTime = 0

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            oauthProfileCarriesOrganization: false
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let first = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: profile
        )
        XCTAssertNil(first.personalExtraUsageIssue)
        XCTAssertEqual(profileLookupCount(), 1)
        XCTAssertTrue(
            renewals.writes.isEmpty,
            "the first reading must run on the unrotated credential, or this "
                + "test proves nothing about rolling the answer forward"
        )

        // The token expires; the next reading renews it, and the answer was
        // recorded against the credential being replaced.
        try await Task.sleep(nanoseconds: 2_800_000_000)

        let afterRotation = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: profile
        )

        XCTAssertTrue(
            renewals.carriesAccessToken("renewed-access", for: profileID),
            "the second reading must actually rotate the token"
        )
        XCTAssertEqual(
            profileLookupCount(),
            1,
            "a rotated token is the same account, so the settled answer moves "
                + "onto it rather than being asked for again"
        )
        XCTAssertNil(afterRotation.personalExtraUsageIssue)
    }

    /// A remembered "no organization" must stay incapable of satisfying the
    /// organization-match guard.
    ///
    /// The guard is what stops one account's member figure being read with
    /// another account's token, and the cache is the obvious place for
    /// someone to reintroduce that by answering a hit with
    /// `profile.cliOrganizationId` — a value resolved from a *different*
    /// credential. Here the profile carries exactly that: a cached id
    /// matching the organization on screen, which would pass the guard if it
    /// were ever returned.
    func testARememberedNoOrganizationNeverSatisfiesTheOrganizationGuard()
        async throws
    {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            in: store
        )
        ProfileManager(profileStore: store)
            .updateCliOrganizationId(teamOrganizationID, for: profileID)
        var profile = try seededProfile(profileID)
        profile.cliOrganizationId = teamOrganizationID
        let service = try makeService(profileID: profileID, store: store)

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            oauthProfileCarriesOrganization: false
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        for _ in 0..<2 {
            let usage = try await service.fetchUsageData(
                sessionKey: "sk-ant-sid01-fixture-session-key-value",
                organizationId: teamOrganizationID,
                profile: profile
            )
            XCTAssertNil(usage.personalCostUsed)
            XCTAssertNil(usage.personalExtraUsageIssue)
        }

        XCTAssertFalse(
            StubClaudeEndpointsURLProtocol.requestedURLs.contains {
                $0.hasSuffix("/api/oauth/usage")
            },
            "no member figure may be attributed on an organization this "
                + "credential never reported — cached or fresh"
        )
    }

    /// How many times the CLI profile endpoint has been asked since the stub
    /// was installed. The whole point of the cache is that this stops
    /// growing, so it is counted rather than described.
    private func profileLookupCount() -> Int {
        StubClaudeEndpointsURLProtocol.requestedURLs.filter {
            $0.hasSuffix("/api/oauth/profile")
        }.count
    }

    /// The contrast that makes the test above mean something.
    ///
    /// A settled "no organization" is remembered and never asked again while
    /// the credential holds; a failure is asked again on the very next
    /// reading, because the notice it produces promises exactly that. Both
    /// short-circuit — the difference is how long for, and what the reader is
    /// told in the meantime.
    ///
    /// This used to assert the opposite: one request across two refreshes,
    /// on the strength of a latch that lasted the whole app run. That was
    /// consistent with the wording this branch replaced, which promised
    /// nothing, and is not consistent with "It will be retried
    /// automatically".
    func testAFailedProfileRequestIsRetriedUnlikeAMissingOrganization()
        async throws
    {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            in: store
        )
        let service = try makeService(profileID: profileID, store: store)

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            oauthProfileStatusCode: 500
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        let profile = try seededProfile(profileID)
        for _ in 0..<2 {
            let usage = try await service.fetchUsageData(
                sessionKey: "sk-ant-sid01-fixture-session-key-value",
                organizationId: teamOrganizationID,
                profile: profile
            )
            XCTAssertEqual(
                usage.personalExtraUsageIssue,
                .temporarilyUnavailable
            )
        }

        XCTAssertEqual(
            profileLookupCount(),
            2,
            "each refresh is the retry the notice promises; suppressing the "
                + "second one makes the message a lie"
        )
    }

    /// A transient failure must actually recover, because the app says it
    /// will.
    ///
    /// `.temporarilyUnavailable` renders as "It will be retried
    /// automatically". The failure record used to last the whole app run, so
    /// the member's figure could not come back until the credential changed
    /// or the app was restarted — and this app runs for days. One moment of
    /// 5xx and a permanently unreadable figure were the same outcome, under a
    /// sentence promising the opposite.
    ///
    /// The credential is untouched between the two readings here; only the
    /// endpoint's answer differs. That is what makes the second request the
    /// retry rather than a re-link being picked up.
    func testATransientOrganizationLookupFailureRecoversOnTheNextRefresh()
        async throws
    {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            in: store
        )
        let service = try makeService(profileID: profileID, store: store)
        let profile = try seededProfile(profileID)

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            oauthProfileStatusCode: 503
        )
        let unavailable = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: profile
        )
        XCTAssertEqual(
            unavailable.personalExtraUsageIssue,
            .temporarilyUnavailable
        )
        StubClaudeEndpointsURLProtocol.reset()

        // Same stored credential, the endpoint is back. `install` clears the
        // recorded URLs, so the count below is the second reading's own
        // traffic — a short-circuit would leave it at zero.
        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }
        let recovered = try await service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: profile
        )

        XCTAssertEqual(
            profileLookupCount(),
            1,
            "the next refresh must ask again; that request is the automatic "
                + "retry the notice names"
        )
        XCTAssertEqual(
            recovered.personalCostUsed,
            0,
            "and the member's figure must actually come back"
        )
        XCTAssertEqual(recovered.personalCostLimit, 5_000)
        XCTAssertNil(recovered.personalExtraUsageIssue)
    }

    /// The other half: within one reading, the lookup is not repeated.
    ///
    /// Retrying on the next refresh must not become retrying twice inside the
    /// same one. Asserted through `applyPersonalExtraUsage`, which is one
    /// reading, called twice — the second call is a second reading and asks
    /// again, so the count separates "per reading" from "per call".
    func testAFailedLookupIsNotRepeatedWithinOneReading() async throws {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            in: store
        )
        let service = try makeService(profileID: profileID, store: store)

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            oauthProfileStatusCode: 500
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        var usage = ClaudeUsage.empty
        await service.applyPersonalExtraUsage(
            to: &usage,
            profile: try seededProfile(profileID),
            organizationId: teamOrganizationID
        )
        XCTAssertEqual(
            profileLookupCount(),
            1,
            "one reading asks once"
        )
        XCTAssertEqual(usage.personalExtraUsageIssue, .temporarilyUnavailable)

        await service.applyPersonalExtraUsage(
            to: &usage,
            profile: try seededProfile(profileID),
            organizationId: teamOrganizationID
        )
        XCTAssertEqual(
            profileLookupCount(),
            2,
            "and the next reading asks again rather than reusing the verdict"
        )
    }

    // MARK: - A request the app cancelled itself

    /// The refresh engine cancels an earlier batch's in-flight work whenever
    /// a later refresh supersedes it. That teardown used to be indistinguish-
    /// able from a rejected credential, so the app reported its own
    /// housekeeping as a problem with the user's sign-in.
    ///
    /// Asserted through `applyPersonalExtraUsage` rather than a whole fetch
    /// because the property is that *nothing is written*: every path through
    /// `fetchUsageData` builds a fresh record, where "wrote nothing" and
    /// "wrote nil" are the same picture.
    func testACancelledRequestLeavesTheHeldFigureAndIssueUntouched()
        async throws
    {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            in: store
        )
        let service = try makeService(profileID: profileID, store: store)

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            transportErrors: [
                "https://api.anthropic.com/api/oauth/usage": .cancelled
            ]
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        var usage = ClaudeUsage.empty
        usage.personalCostUsed = 12
        usage.personalCostLimit = 5_000
        usage.personalCostCurrency = "USD"

        await service.applyPersonalExtraUsage(
            to: &usage,
            profile: try seededProfile(profileID),
            organizationId: teamOrganizationID
        )

        XCTAssertEqual(
            usage.personalCostUsed,
            12,
            "a superseded request must not replace a figure that is already "
                + "on screen"
        )
        XCTAssertEqual(usage.personalCostLimit, 5_000)
        XCTAssertEqual(usage.personalCostCurrency, "USD")
        XCTAssertNil(
            usage.personalExtraUsageIssue,
            "the app cancelled this itself; there is no verdict to record"
        )
    }

    /// The same request failing for any other reason is a different state,
    /// and must be treated as one: a reading that did not arrive, reported as
    /// transient. Run against the identical fixture as the test above so the
    /// only difference is which error came back.
    func testANonCancellationFailureIsReportedAsTransient() async throws {
        let profileID = UUID()
        let store = makeIsolatedProfileStore()
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            in: store
        )
        let service = try makeService(profileID: profileID, store: store)

        StubClaudeEndpointsURLProtocol.install(
            cliOrganizationID: teamOrganizationID,
            transportErrors: [
                "https://api.anthropic.com/api/oauth/usage": .timedOut
            ]
        )
        defer { StubClaudeEndpointsURLProtocol.reset() }

        var usage = ClaudeUsage.empty
        await service.applyPersonalExtraUsage(
            to: &usage,
            profile: try seededProfile(profileID),
            organizationId: teamOrganizationID
        )

        XCTAssertEqual(
            usage.personalExtraUsageIssue,
            .temporarilyUnavailable,
            "a timeout is a reading that did not arrive, not a credential "
                + "that was refused"
        )
    }

    /// The transient notice must never instruct anyone. The app performs the
    /// retry itself, so there is nothing for a person to do — and the two
    /// steps the old wording named, a re-sync and a trip to Settings, are
    /// precisely the ones that cannot help and, in the re-sync's case, can
    /// destroy a working login. Asserted on the absence of that wording so a
    /// future edit cannot quietly put it back.
    func testTheTransientNoticeCarriesNoInstruction() throws {
        let path = try XCTUnwrap(
            Bundle.main.path(forResource: "en", ofType: "lproj")
        )
        let english = try XCTUnwrap(Bundle(path: path))

        for key in [
            "popover.extra_usage.cli_temporarily_unavailable",
            "popover.extra_usage.absent.cli_temporarily_unavailable",
            // The genuine unusable-credential case is held to the same rule:
            // the app has already performed the equivalent of a re-sync by
            // the time it is reached.
            "popover.extra_usage.cli_sign_in_unusable",
            "popover.extra_usage.absent.cli_sign_in_unusable"
        ] {
            let message = english.localizedString(
                forKey: key,
                value: nil,
                table: nil
            )
            XCTAssertNotEqual(message, key, "\(key) is missing.")
            for forbidden in ["re-sync", "Re-sync", "Settings", "→"] {
                XCTAssertFalse(
                    message.contains(forbidden),
                    "\(key) tells the reader to \"\(forbidden)\", which is "
                        + "either something the app already does itself or "
                        + "something that cannot help here."
                )
            }
        }
    }

    // MARK: - Helpers

    /// A record carrying a real capacity reading.
    ///
    /// `ClaudeUsage.empty` reports no session or weekly percentage at all,
    /// which the adapter classifies as `.unavailable` before it ever looks at
    /// extra usage — so a health assertion built on `.empty` measures the
    /// wrong thing and passes or fails for the wrong reason.
    static func fullyReadUsage() -> ClaudeUsage {
        var usage = ClaudeUsage.empty
        usage.sessionPercentage = 20
        usage.sessionPercentageAvailable = true
        usage.weeklyPercentage = 31
        usage.weeklyPercentageAvailable = true
        return usage
    }

    private func makeReport(from usage: ClaudeUsage) throws -> UsageReport {
        let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
        return try ClaudeUsageProviderAdapter.makeReport(
            from: usage,
            context: ClaudeUsageProviderContext(
                health: ProviderHealth(
                    status: .healthy,
                    checkedAt: fetchedAt
                ),
                fetchedAt: fetchedAt
            )
        )
    }

    private static func credentialsJSON(expiresAt: Double) -> String {
        """
        {"claudeAiOauth":{"accessToken":"fixture-access-token",\
        "refreshToken":"fixture-refresh-token","expiresAt":\(expiresAt),\
        "scopes":["user:inference"],"subscriptionType":"max"}}
        """
    }

    /// A credential distinct from `credentialsJSON(expiresAt:)`'s, standing
    /// in for the login Claude Code itself is holding — as read through
    /// `systemCredentialsReader` rather than the profile's stored copy.
    private static func liveLoginJSON(expiresAt: Double) -> String {
        """
        {"claudeAiOauth":{"accessToken":"live-access-token",\
        "refreshToken":"live-refresh-token","expiresAt":\(expiresAt),\
        "scopes":["user:inference"],"subscriptionType":"max"}}
        """
    }

    /// A third login, distinct from both of the above: what Claude Code's
    /// store holds after someone signs in to the account again.
    private static func signInAgainJSON(expiresAt: Double) -> String {
        """
        {"claudeAiOauth":{"accessToken":"relogin-access-token",\
        "refreshToken":"relogin-refresh-token","expiresAt":\(expiresAt),\
        "scopes":["user:inference"],"subscriptionType":"max"}}
        """
    }

    /// The same login in different bytes: its tokens untouched, with one
    /// unrelated top-level key beside them, the way a credentials file keeps
    /// `mcpOAuth` next to `claudeAiOauth` when the store rewrites it.
    private static func rewrittenByItsStore(_ credentialsJSON: String) -> String {
        String(credentialsJSON.dropLast()) + #","mcpOAuth":{}}"#
    }

    /// The same login with its access token's expiry moved, which is how a
    /// renewal looks once its hours are up.
    private static func expiring(
        _ credentialsJSON: String,
        at expiresAt: Double
    ) throws -> String {
        var document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(credentialsJSON.utf8))
                as? [String: Any]
        )
        var oauth = try XCTUnwrap(document["claudeAiOauth"] as? [String: Any])
        oauth["expiresAt"] = expiresAt
        document["claudeAiOauth"] = oauth
        return String(
            decoding: try JSONSerialization.data(withJSONObject: document),
            as: UTF8.self
        )
    }

    /// Claude Code's store as one idle account's tests stage it: what the
    /// store holds, how often it was read, and how often its refresh lock
    /// was taken.
    private nonisolated final class StagedClaudeCodeStore {
        var copy: String
        var reads = 0
        var locks = 0
        let lockPath: String

        init(copy: String, lockPath: String) {
            self.copy = copy
            self.lockPath = lockPath
        }
    }

    private struct DeadIdleLoginScene {
        let profile: Profile
        let service: ClaudeAPIService
        let renewals: RenewedCredentialRecorder
        let store: StagedClaudeCodeStore
    }

    /// The idle account from PRODUCT-3329: a browser-backed profile whose
    /// stored copy has expired, beside a store whose copy has moved past it
    /// and expired as well.
    private func makeDeadIdleLoginScene(
        stored: String? = nil,
        storeCopy: String? = nil
    ) throws -> DeadIdleLoginScene {
        let profileID = UUID()
        let profileStore = makeIsolatedProfileStore()
        try seedProfile(
            id: profileID,
            organizationID: teamOrganizationID,
            credentialsJSON: stored ?? Self.credentialsJSON(expiresAt: 1_000),
            in: profileStore
        )
        let manager = ProfileManager(profileStore: profileStore)
        let profile = try seededProfile(profileID)
        manager.profiles = [profile]
        manager.activeProfile = profile
        retained.append(manager)
        retained.append(profileStore)
        return makeDeadIdleLoginScene(
            profile: profile,
            manager: manager,
            store: profileStore,
            storeCopy: storeCopy ?? Self.liveLoginJSON(expiresAt: 1_000)
        )
    }

    private func makeDeadIdleLoginScene(
        profile: Profile,
        manager: ProfileManager,
        store profileStore: ProfileStore,
        storeCopy: String
    ) -> DeadIdleLoginScene {
        let configurationDirectory = makeIsolatedClaudeConfigurationDirectory()
        let staged = StagedClaudeCodeStore(
            copy: storeCopy,
            lockPath: configurationDirectory
                .appendingPathComponent(ClaudeCodeSyncService.refreshLockName)
                .path
        )
        let renewals = RenewedCredentialRecorder()
        let service = makeIsolatedClaudeAPIService(
            profileManager: manager,
            store: profileStore,
            systemCredentials: {
                staged.reads += 1
                return staged.copy
            },
            renewals: renewals,
            accountIsInUse: { _ in false }
        )
        useIsolatedClaudeCodeLocks(
            on: service,
            in: configurationDirectory,
            storeComparison: { snapshot, _ in
                snapshot == staged.copy ? .unchanged : .movedOn
            }
        )
        // Wrapped only after the locks above are installed: that call
        // replaces `acquireRefreshLock`, and a counter wrapped before it would
        // be thrown away and count nothing.
        let acquire = service.acquireRefreshLock
        service.acquireRefreshLock = { accountName in
            staged.locks += 1
            return try acquire(accountName)
        }
        return DeadIdleLoginScene(
            profile: profile,
            service: service,
            renewals: renewals,
            store: staged
        )
    }

    private struct FileBackedScene {
        let scene: DeadIdleLoginScene
        let profiles: [Profile]
        let profileStore: ProfileStore
    }

    /// Terminal-only profiles on an account backed by a credentials file,
    /// one per credential, the first standing in for the store's own copy.
    /// With no Keychain item the store comparison answers `.unchanged`
    /// whatever it is shown, while a read of the store falls back to the file.
    private func makeFileBackedScene(
        _ credentials: String...,
        accountNames: [String?]? = nil
    ) throws -> FileBackedScene {
        let profiles = credentials.enumerated().map { index, credential in
            var profile = terminalOnlyProfile(credentialsJSON: credential)
            profile.name = "Terminal-only fixture \(index + 1)"
            if let accountNames {
                profile.cliAccountName = accountNames[index]
            }
            return profile
        }
        let store = makeIsolatedProfileStore()
        try seedProfilesForTesting(profiles, in: store)
        for profile in profiles {
            try store.saveCLIProfileCredential(
                profile.cliCredentialsJSON,
                for: profile.id
            )
        }
        let manager = ProfileManager(profileStore: store)
        manager.profiles = profiles
        retained.append(manager)
        retained.append(store)
        let scene = makeDeadIdleLoginScene(
            profile: profiles[0],
            manager: manager,
            store: store,
            storeCopy: credentials[0]
        )
        scene.service.claudeCodeStoreComparison = { _, _ in .unchanged }
        return FileBackedScene(
            scene: scene,
            profiles: profiles,
            profileStore: store
        )
    }

    private func fetchMemberUsage(
        _ scene: DeadIdleLoginScene
    ) async throws -> ClaudeUsage {
        try await scene.service.fetchUsageData(
            sessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: teamOrganizationID,
            profile: scene.profile
        )
    }

    /// Requests that reached the token endpoint since the stub was last
    /// installed.
    private var tokenRequestCount: Int {
        StubClaudeEndpointsURLProtocol.requestedURLs.filter {
            $0 == ClaudeCLITokenRefresher.tokenEndpoint
        }.count
    }

    /// The snapshot a profile can be left holding after Claude Code rotated
    /// its refresh token and this app copied only the access token forward:
    /// a login with nothing left to spend.
    private static func accessTokenOnlyCredentialsJSON(
        expiresAt: Double
    ) -> String {
        """
        {"claudeAiOauth":{"accessToken":"fixture-access-token",\
        "expiresAt":\(expiresAt),\
        "scopes":["user:inference"],"subscriptionType":"max"}}
        """
    }

    private func terminalOnlyProfile(credentialsJSON: String) -> Profile {
        Profile(
            id: UUID(),
            name: "Terminal-only fixture",
            claudeSessionKey: nil,
            organizationId: nil,
            cliCredentialsJSON: credentialsJSON,
            hasCliAccount: true,
            cliAccountName: "fixture-account"
        )
    }

    private func seedProfile(
        id: UUID,
        organizationID: String,
        credentialsJSON: String? = nil,
        // Non-nil by default: every recovery test in this file exercises
        // `adoptLiveCLILogin`'s ordinary path, which requires a linked
        // account name to scope the Keychain read. The nil case is its own
        // profile-shaped defect — a legacy decode can leave a stored
        // credential with no account name — and is exercised explicitly by
        // tests that pass `cliAccountName: nil`.
        cliAccountName: String? = "fixture-account",
        in store: ProfileStore
    ) throws {
        let profile = Profile(
            id: id,
            name: "Fixture",
            claudeSessionKey: "sk-ant-sid01-fixture-session-key-value",
            organizationId: organizationID,
            // Already classified, so the scope lookup needs no extra request.
            organizationIsPersonal: false,
            cliCredentialsJSON: credentialsJSON
                ?? Self.credentialsJSON(
                    expiresAt: Date()
                        .addingTimeInterval(8 * 3600)
                        .timeIntervalSince1970 * 1000
                ),
            hasCliAccount: true,
            cliAccountName: cliAccountName
        )
        try seedProfilesForTesting([profile], in: store)
        try store.saveCLIProfileCredential(
            profile.cliCredentialsJSON,
            for: id
        )
        seededProfiles.append(profile)
    }

    private var seededProfiles: [Profile] = []

    /// The exact profile a test seeded, so it can be threaded into
    /// `fetchUsageData(sessionKey:organizationId:profile:)` the same way a
    /// real caller would rather than left for the service to re-derive.
    private func seededProfile(_ id: UUID) throws -> Profile {
        try XCTUnwrap(seededProfiles.first { $0.id == id })
    }

    private func makeService(
        profileID: UUID,
        store: ProfileStore,
        renewals: RenewedCredentialRecorder? = nil
    ) throws -> ClaudeAPIService {
        let manager = ProfileManager(profileStore: store)
        let profile = try XCTUnwrap(
            seededProfiles.first { $0.id == profileID }
        )
        manager.profiles = [profile]
        manager.activeProfile = profile
        retained.append(manager)
        retained.append(store)
        return makeIsolatedClaudeAPIService(
            profileManager: manager,
            store: store,
            renewals: renewals
        )
    }

    private var retained: [AnyObject] = []
}

private final class TerminalRenewalSecurityRunner: SecurityCommandRunning {
    private(set) var invocations: [[String]] = []
    private let heldCredential: String

    init(holding heldCredential: String) {
        self.heldCredential = heldCredential
    }

    func run(_ arguments: [String]) throws -> SecurityCommandResult {
        invocations.append(arguments)
        let isRead = arguments.first == "find-generic-password"
        return SecurityCommandResult(
            exitCode: 0,
            standardOutput: isRead ? heldCredential : "",
            standardError: ""
        )
    }
}

/// Serves the whole set of endpoints one usage refresh touches, so no test
/// here reaches Anthropic. Anything not explicitly canned answers 404, which
/// is how a genuinely unexpected request shows up as a failing assertion
/// rather than a hang.
private nonisolated final class StubClaudeEndpointsURLProtocol: URLProtocol {
    nonisolated(unsafe) private static var responses: [String: (Int, Data)] = [:]
    nonisolated(unsafe) private static var isActive = false
    nonisolated(unsafe) private(set) static var requestedURLs: [String] = []

    /// URLs answered with a transport error instead of a response, keyed by
    /// absolute URL. `URLError.cancelled` is the app superseding its own
    /// refresh; anything else stands for the ordinary transport failures.
    nonisolated(unsafe) private static var transportErrors:
        [String: URLError.Code] = [:]
    nonisolated(unsafe) private static var tokenRefreshResponseGate:
        DispatchSemaphore?
    nonisolated(unsafe) private static var onTokenRefreshStarted:
        (() -> Void)?
    nonisolated(unsafe) private static var messagesRateLimitHeaders:
        [String: String] = [:]

    static func install(
        cliOrganizationID: String,
        tokenRefreshStatusCode: Int = 200,
        oauthProfileStatusCode: Int = 200,
        tokenRefreshErrorCode: String = "invalid_grant",
        // The refresh token a successful renewal hands back. Distinct values
        // keep two renewals in one test from issuing the same token.
        issuedRefreshToken: String = "renewed-refresh",
        memberExtraUsageEnabled: Bool = true,
        // What claude.ai answers for the organization-scoped extra-usage
        // endpoint. Two of the maintainer's organizations answer 200 with a
        // body that is not an extra-usage record, on every refresh.
        overageSpendLimitStatusCode: Int = 200,
        overageSpendLimitBody: String? = nil,
        // A response that is complete and simply carries no credit figures,
        // which is what Claude answers for an account that has extra usage
        // switched on with nothing recorded against it.
        memberExtraUsageCarriesCreditFigures: Bool = true,
        // A profile response with no `organization` key at all: what a
        // personal Max/Pro account looks like, as opposed to a team one.
        oauthProfileCarriesOrganization: Bool = true,
        // The CLI usage source. `/api/oauth/usage` carries the session and
        // weekly windows, the model-scoped `limits` array and the member's
        // own extra usage in one body, so these two control every figure a
        // CLI-sourced fetch produces.
        oauthUsageStatusCode: Int = 200,
        oauthUsageBody: String? = nil,
        // Headers on the Messages response, which is the fallback source
        // when `/api/oauth/usage` does not answer.
        messagesRateLimitHeaders: [String: String] = [:],
        transportErrors: [String: URLError.Code] = [:],
        holdTokenRefreshResponse: Bool = false,
        onTokenRefreshStarted: (() -> Void)? = nil
    ) {
        requestedURLs = []
        Self.transportErrors = transportErrors
        tokenRefreshResponseGate = holdTokenRefreshResponse
            ? DispatchSemaphore(value: 0)
            : nil
        Self.onTokenRefreshStarted = onTokenRefreshStarted
        responses = [
            "https://claude.ai/api/organizations": (200, Data("""
            [{"uuid":"665a6475-2eb6-4da8-8379-d5529d283568",
              "name":"Revenium","capabilities":["chat","raven"],
              "raven_type":"team"}]
            """.utf8)),
            "https://claude.ai/api/organizations/665a6475-2eb6-4da8-8379-d5529d283568/usage":
                (200, Data("{}".utf8)),
            "https://claude.ai/api/organizations/665a6475-2eb6-4da8-8379-d5529d283568/overage_spend_limit":
                (
                    overageSpendLimitStatusCode,
                    Data((overageSpendLimitBody ?? """
                    {"monthly_credit_limit":100000,"currency":"USD",
                     "used_credits":26118,"is_enabled":true,
                     "limit_type":"organization"}
                    """).utf8)
                ),
            "https://api.anthropic.com/api/oauth/profile": (
                oauthProfileStatusCode,
                Data(
                    oauthProfileCarriesOrganization
                        ? """
                          {"organization":{"uuid":"\(cliOrganizationID)"},
                           "account":{"email_address":"fixture@example.com"}}
                          """.utf8
                        : """
                          {"account":{"email_address":"fixture@example.com"}}
                          """.utf8
                )
            ),
            "https://api.anthropic.com/api/oauth/usage": (
                oauthUsageStatusCode,
                oauthUsageBody.map { Data($0.utf8) } ?? Data(
                    memberExtraUsageCarriesCreditFigures
                        ? """
                          {"extra_usage":{
                           "is_enabled":\(memberExtraUsageEnabled),
                           "monthly_limit":5000,
                           "used_credits":0.0,"utilization":null,
                           "currency":"USD"}}
                          """.utf8
                        : """
                          {"extra_usage":{
                           "is_enabled":\(memberExtraUsageEnabled),
                           "utilization":null,"currency":"USD",
                           "decimal_places":2,"user_disabled":false}}
                          """.utf8
                )
            ),
            "https://api.anthropic.com/v1/messages": (
                200,
                Data("{}".utf8)
            ),
            "https://status.claude.com/api/v2/status.json": (
                200,
                Data(
                    #"{"status":{"indicator":"none","description":"Operational"}}"#.utf8
                )
            ),
            "https://platform.claude.com/v1/oauth/token": (
                tokenRefreshStatusCode,
                Data(
                    tokenBody(
                        for: tokenRefreshStatusCode,
                        errorCode: tokenRefreshErrorCode,
                        issuedRefreshToken: issuedRefreshToken
                    ).utf8
                )
            )
        ]
        Self.messagesRateLimitHeaders = messagesRateLimitHeaders
        isActive = true
        URLProtocol.registerClass(StubClaudeEndpointsURLProtocol.self)
    }

    private static func tokenBody(
        for statusCode: Int,
        errorCode: String = "invalid_grant",
        issuedRefreshToken: String = "renewed-refresh"
    ) -> String {
        guard statusCode == 200 else {
            return #"{"error":"\#(errorCode)"}"#
        }
        return """
        {"access_token":"renewed-access",
         "refresh_token":"\(issuedRefreshToken)",
         "expires_in":28800}
        """
    }

    static func reset() {
        guard isActive else { return }
        releaseTokenRefreshResponse()
        URLProtocol.unregisterClass(StubClaudeEndpointsURLProtocol.self)
        isActive = false
        responses = [:]
        transportErrors = [:]
        tokenRefreshResponseGate = nil
        onTokenRefreshStarted = nil
        messagesRateLimitHeaders = [:]
    }

    static func releaseTokenRefreshResponse() {
        // Several signals make a failing de-duplication test fail its count
        // assertion instead of hanging a second accidental request forever.
        for _ in 0..<4 {
            tokenRefreshResponseGate?.signal()
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard isActive, let host = request.url?.host else { return false }
        return [
            "claude.ai",
            "api.anthropic.com",
            "platform.claude.com",
            "status.claude.com"
        ].contains(host)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badURL)
            )
            return
        }
        Self.requestedURLs.append(url.absoluteString)
        if url.absoluteString == ClaudeCLITokenRefresher.tokenEndpoint {
            Self.onTokenRefreshStarted?()
            Self.tokenRefreshResponseGate?.wait()
        }
        if let code = Self.transportErrors[url.absoluteString] {
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }
        let canned = Self.responses[url.absoluteString]
            ?? (404, Data("{}".utf8))
        var headerFields = ["Content-Type": "application/json"]
        if url.absoluteString == "https://api.anthropic.com/v1/messages" {
            headerFields.merge(Self.messagesRateLimitHeaders) { _, new in new }
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: canned.0,
            httpVersion: "HTTP/1.1",
            headerFields: headerFields
        ) else {
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
        client?.urlProtocol(self, didLoad: canned.1)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
