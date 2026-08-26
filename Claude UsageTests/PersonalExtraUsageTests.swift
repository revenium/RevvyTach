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
    /// for is gone by the time the fetch actually runs (removed mid-refresh).
    /// The organization figure must still explain why no member figure sits
    /// beside it, rather than rendering as if nothing were missing.
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

        XCTAssertEqual(usage.personalExtraUsageIssue, .claudeAccountUnresolved)
        XCTAssertNil(usage.personalCostUsed)
        XCTAssertEqual(usage.costUsed, 26_118)
        XCTAssertFalse(
            StubClaudeEndpointsURLProtocol.requestedURLs.contains {
                $0.hasSuffix("/api/oauth/usage")
            },
            "no member figure may be requested with no profile to attach it to"
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

    /// The per-account credentials file is not kept current the way the
    /// Keychain is — Claude Code can leave a stale copy sitting in
    /// `~/.claude-accounts/<account>/.credentials.json` for weeks after the
    /// Keychain item for the same account has moved on to a fresh login.
    /// The file used to win the fallback chain on JSON validity and a login
    /// shape alone, so on a machine where these files exist and are stale,
    /// every profile linked to those accounts showed a sign-in notice while
    /// a valid login sat one step down the chain in the Keychain. The same
    /// code on a machine with no such files behaved correctly, which is why
    /// this hid for so long — nothing exercised the case where the file
    /// exists, parses, and looks like a login, but is simply too old.
    func testAnExpiredCredentialsFileDoesNotPreemptTheKeychain() {
        let sync = ClaudeCodeSyncService.shared

        let expired = Self.credentialsJSON(expiresAt: 1_000)
        XCTAssertFalse(sync.fileLoginPreemptsKeychain(expired))

        let future = Self.credentialsJSON(
            expiresAt: Date()
                .addingTimeInterval(8 * 3600)
                .timeIntervalSince1970 * 1000
        )
        XCTAssertTrue(sync.fileLoginPreemptsKeychain(future))

        let mcpOnly = #"{"mcpOAuth":{"some-server":{"accessToken":"x"}}}"#
        XCTAssertFalse(sync.fileLoginPreemptsKeychain(mcpOnly))

        let blankToken = #"{"claudeAiOauth":{"accessToken":""}}"#
        XCTAssertFalse(sync.fileLoginPreemptsKeychain(blankToken))
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
        let cliSync = ClaudeCodeSyncService(
            profileStore: store,
            systemCredentialsReader: { expired },
            securityRunner: keychain
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
        let accountDirectory = ClaudeCodeSyncService
            .configurationDirectory(forAccountNamed: "fixture-account")
        let accountService = ClaudeCodeSyncService.serviceName(
            forConfigurationDirectory: accountDirectory.path
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
        let cliSync = ClaudeCodeSyncService(
            profileStore: store,
            systemCredentialsReader: { expired },
            securityRunner: keychain
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

    func testBrowserBackedRefreshDoesNotEnterTerminalRenewalPath()
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

        XCTAssertEqual(request.source, .claudeAI(checkOverage: true))
        XCTAssertFalse(
            StubClaudeEndpointsURLProtocol.requestedURLs.contains(
                ClaudeCLITokenRefresher.tokenEndpoint
            )
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
                + "Settings → Claude.ai."
        )
        XCTAssertEqual(
            english.localizedString(
                forKey: "cli.connect_extra_usage_hint",
                value: nil,
                table: nil
            ),
            "Connect your Claude Code account to see your own extra usage. "
                + "If you're an admin, you'll see your organization's by "
                + "default."
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

    static func install(
        cliOrganizationID: String,
        tokenRefreshStatusCode: Int = 200,
        oauthProfileStatusCode: Int = 200,
        tokenRefreshErrorCode: String = "invalid_grant",
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
                200,
                Data(
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
                        errorCode: tokenRefreshErrorCode
                    ).utf8
                )
            )
        ]
        isActive = true
        URLProtocol.registerClass(StubClaudeEndpointsURLProtocol.self)
    }

    private static func tokenBody(
        for statusCode: Int,
        errorCode: String = "invalid_grant"
    ) -> String {
        guard statusCode == 200 else {
            return #"{"error":"\#(errorCode)"}"#
        }
        return """
        {"access_token":"renewed-access",
         "refresh_token":"renewed-refresh",
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
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: canned.0,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
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
