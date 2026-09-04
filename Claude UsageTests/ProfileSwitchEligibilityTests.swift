//
//  ProfileSwitchEligibilityTests.swift
//  Claude UsageTests
//

import UsageCore
import XCTest
@testable import Claude_Usage

/// The rule that decides where the app may move you without being told a
/// name, and the two surfaces that must keep applying the same one.
///
/// Before `ProfileSwitchEligibility` existed the Next Profile hotkey filtered
/// nothing at all — it took the next entry in the list, Codex profile, dead
/// sign-in, half-deleted profile and all — while auto-switch filtered on the
/// 5-hour window alone and read "no reading at all" as "empty". Both then
/// went through `activateProfile`, which rewrites `CLAUDE_CONFIG_DIR` or
/// `CODEX_HOME` and the tmux environment, so a wrong destination followed the
/// user into every terminal.
///
/// Two kinds of test live here on purpose. Most exercise the rule itself. The
/// last four exercise the two call sites, because "one rule, two surfaces" is
/// exactly the claim that stops being true silently: convert one function,
/// forget the other, and nothing else in the suite notices.
@MainActor
final class ProfileSwitchEligibilityTests: HostedAppTestCase {

    // MARK: - Fixtures

    /// A Claude sign-in that satisfies `hasImmediatelyUsableCredentials`
    /// through `hasClaudeAI` alone — no keychain, no JSON parsing, so it
    /// cannot flake.
    private func liveClaude(
        _ name: String,
        usage: ClaudeUsage?
    ) -> Profile {
        Profile(
            name: name,
            claudeSessionKey: "session-key",
            organizationId: "org-id",
            claudeUsage: usage
        )
    }

    /// The blob `ProfileProviderCoreTests` already pins as a login that cannot
    /// be repaired: expired, with no refresh token.
    private func deadClaude(
        _ name: String,
        usage: ClaudeUsage?
    ) -> Profile {
        Profile(
            name: name,
            cliCredentialsJSON:
                #"{"claudeAiOauth":{"accessToken":"expired","expiresAt":1}}"#,
            claudeUsage: usage
        )
    }

    /// A Claude profile mid-deletion that still carries live credentials and a
    /// healthy reading. Real tombstones have both stripped by
    /// `ProfileStore.beginProfileDeletion`; this one deliberately does not, so
    /// the test proves the tombstone guard fires on its own rather than being
    /// carried by the credential guard.
    private func claudeTombstone(
        _ name: String,
        usage: ClaudeUsage?
    ) -> Profile {
        Profile(
            name: name,
            claudeSessionKey: "session-key",
            organizationId: "org-id",
            claudeUsage: usage,
            deletionInProgress: true
        )
    }

    /// Decoding is the established way to get a real `CanonicalCodexHome`
    /// without touching the filesystem — see `CodexDefaultHomeResolverTests`.
    /// It validates the string shape only.
    private func canonicalHome(_ path: String) throws -> CanonicalCodexHome {
        try JSONDecoder().decode(
            CanonicalCodexHome.self,
            from: Data(#"{"path":"\#(path)"}"#.utf8)
        )
    }

    private func linkedCodex(
        _ name: String,
        home: String,
        deleted: Bool = false
    ) throws -> Profile {
        Profile(
            name: name,
            providerConfiguration: .codex(
                .init(linkedHome: try canonicalHome(home))
            ),
            deletionInProgress: deleted
        )
    }

    private func unlinkedCodex(_ name: String) -> Profile {
        Profile(name: name, providerConfiguration: .codex(.init()))
    }

    /// Builds on `ClaudeUsage.empty`, whose availability flags are already
    /// false, so a `nil` argument means "no reading was ever received". Reset
    /// times are pushed well clear of `Date()` so the window-expiry branch
    /// inside `effectiveSessionPercentage` cannot make a test flake.
    private func reading(
        session: Double?,
        weekly: Double?,
        browserSignIn: ClaudeUsage.BrowserSignInIssue? = nil,
        personalExtraUsage: ClaudeUsage.PersonalExtraUsageIssue? = nil
    ) -> ClaudeUsage {
        var usage = ClaudeUsage.empty
        usage.sessionResetTime = Date().addingTimeInterval(3_600)
        usage.weeklyResetTime = Date().addingTimeInterval(604_800)
        if let session {
            usage.sessionPercentage = session
            usage.sessionPercentageAvailable = true
        }
        if let weekly {
            usage.weeklyPercentage = weekly
            usage.weeklyPercentageAvailable = true
        }
        usage.browserSignInIssue = browserSignIn
        usage.personalExtraUsageIssue = personalExtraUsage
        return usage
    }

    private var healthy: ClaudeUsage { reading(session: 10, weekly: 20) }

    /// `codexHomeAvailable` defaults to "every linked home is usable" so the
    /// existing presence-only fixtures (`linkedCodex` decodes a path-only,
    /// identity-less `CanonicalCodexHome` — see `canonicalHome` below) keep
    /// meaning what they always meant, without touching the real filesystem.
    /// Only `testStaleCodexHomeIsSkippedInFavorOfALiveOne` overrides it.
    private func next(
        after active: Profile,
        in profiles: [Profile],
        codexHomeAvailable: (CanonicalCodexHome) -> Bool = { _ in true }
    ) -> Profile? {
        ProfileSwitchEligibility.nextEligibleProfile(
            after: active.id,
            in: profiles,
            codexHomeAvailable: codexHomeAvailable
        )
    }

    // MARK: - Order and wrap-around

    /// Order decides, not headroom. `B` at 90%/90% wins over `C` at 1%/1%
    /// because `B` comes first — ranking is a later slice, and this pins that
    /// it was deliberately not built.
    func testNearestEligibleProfileWinsWithNoRanking() {
        let a = liveClaude("A", usage: healthy)
        let b = liveClaude("B", usage: reading(session: 90, weekly: 90))
        let c = liveClaude("C", usage: reading(session: 1, weekly: 1))

        XCTAssertEqual(next(after: a, in: [a, b, c])?.id, b.id)
    }

    func testSearchWrapsPastTheEndOfTheList() {
        let a = liveClaude("A", usage: healthy)
        let b = deadClaude("B", usage: healthy)
        let c = liveClaude("C", usage: healthy)

        XCTAssertEqual(next(after: c, in: [a, b, c])?.id, a.id)
    }

    func testUnknownActiveProfileReturnsNil() {
        let a = liveClaude("A", usage: healthy)
        let b = liveClaude("B", usage: healthy)

        XCTAssertNil(
            ProfileSwitchEligibility.nextEligibleProfile(
                after: UUID(),
                in: [a, b]
            )
        )
    }

    func testEmptyProfileListReturnsNil() {
        XCTAssertNil(
            ProfileSwitchEligibility.nextEligibleProfile(
                after: UUID(),
                in: []
            )
        )
    }

    func testSingleProfileListReturnsNil() {
        let a = liveClaude("A", usage: healthy)

        XCTAssertNil(next(after: a, in: [a]))
    }

    /// Asserts the rule directly rather than the `count > 1` early-out, which
    /// would answer nil for a one-element list whatever the rule said.
    func testActiveProfileIsNeverItsOwnDestination() {
        let a = liveClaude("A", usage: healthy)

        XCTAssertFalse(
            ProfileSwitchEligibility.isEligible(a, switchingFrom: a)
        )
    }

    // MARK: - Provider

    /// A fully ready Codex profile is still the wrong destination for a Claude
    /// account: activating it would repoint the terminal at `CODEX_HOME`.
    func testOtherProviderIsSkipped() throws {
        let a = liveClaude("A", usage: healthy)
        let b = try linkedCodex("B", home: "/Users/example/codex-b")
        let c = liveClaude("C", usage: healthy)

        XCTAssertEqual(next(after: a, in: [a, b, c])?.id, c.id)
    }

    func testClaudeNeverHopsToCodexEvenWhenItIsTheOnlyOtherProfile() throws {
        let a = liveClaude("A", usage: healthy)
        let b = try linkedCodex("B", home: "/Users/example/codex-b")

        XCTAssertNil(next(after: a, in: [a, b]))
    }

    func testCodexHopsToTheNextLinkedCodexProfile() throws {
        let a = try linkedCodex("A", home: "/Users/example/codex-a")
        let b = try linkedCodex("B", home: "/Users/example/codex-b")

        XCTAssertEqual(next(after: a, in: [a, b])?.id, b.id)
    }

    func testCodexNeverHopsToClaude() throws {
        let a = try linkedCodex("A", home: "/Users/example/codex-a")
        let b = liveClaude("B", usage: healthy)

        XCTAssertNil(next(after: a, in: [a, b]))
    }

    func testCodexSkipsTheClaudeProfileBetweenTwoCodexProfiles() throws {
        let a = try linkedCodex("A", home: "/Users/example/codex-a")
        let b = liveClaude("B", usage: healthy)
        let c = try linkedCodex("C", home: "/Users/example/codex-c")

        XCTAssertEqual(next(after: a, in: [a, b, c])?.id, c.id)
    }

    // MARK: - Profiles being deleted

    /// `ProfileStore.beginProfileDeletion` strips Claude-shaped state only, so
    /// a Codex tombstone loses nothing and stays indistinguishable from a live
    /// profile on every field except this one. Returning it would hand
    /// `activateProfile` an id it refuses, and the walk has already stopped —
    /// a dead hotkey with a good profile sitting one slot further on.
    func testCodexTombstoneIsSkippedAndTheSearchContinues() throws {
        let a = try linkedCodex("A", home: "/Users/example/codex-a")
        let b = try linkedCodex(
            "B",
            home: "/Users/example/codex-b",
            deleted: true
        )
        let c = try linkedCodex("C", home: "/Users/example/codex-c")

        XCTAssertEqual(next(after: a, in: [a, b, c])?.id, c.id)
    }

    func testClaudeTombstoneIsRejectedEvenCarryingLiveCredentialsAndAReading() {
        let a = liveClaude("A", usage: healthy)
        let tombstone = claudeTombstone("B", usage: healthy)

        XCTAssertTrue(tombstone.hasImmediatelyUsableCredentials)
        XCTAssertFalse(
            ProfileSwitchEligibility.isEligible(tombstone, switchingFrom: a)
        )
    }

    // MARK: - Codex readiness

    /// Activating an unlinked Codex profile calls `clearHome()`, repointing
    /// every terminal at Codex's own `~/.codex` default — the ticket's harm in
    /// Codex form, so it is not a destination.
    func testUnlinkedCodexProfileIsSkippedAndTheSearchContinues() throws {
        let a = try linkedCodex("A", home: "/Users/example/codex-a")
        let b = unlinkedCodex("B")
        let c = try linkedCodex("C", home: "/Users/example/codex-c")

        XCTAssertEqual(next(after: a, in: [a, b, c])?.id, c.id)
    }

    func testUnlinkedCodexProfileAloneReturnsNil() throws {
        let a = try linkedCodex("A", home: "/Users/example/codex-a")
        let b = unlinkedCodex("B")

        XCTAssertNil(next(after: a, in: [a, b]))
    }

    /// A linked home is not automatically a usable one. `B` is linked but its
    /// directory is gone (or moved, or on an unavailable volume) — the exact
    /// failure `CodexProviderFactory.capture(linkedHome:)` catches at
    /// activation time. Because `nextEligibleProfile` returns the first
    /// match, a presence-only check would land on `B` and never reach `C`,
    /// the linked home that is actually still there.
    func testStaleCodexHomeIsSkippedInFavorOfALiveOne() throws {
        let a = try linkedCodex("A", home: "/Users/example/codex-a")
        let b = try linkedCodex("B", home: "/Users/example/codex-b-stale")
        let c = try linkedCodex("C", home: "/Users/example/codex-c-live")

        let chosen = next(after: a, in: [a, b, c]) { linkedHome in
            linkedHome.path == "/Users/example/codex-c-live"
        }

        XCTAssertEqual(chosen?.id, c.id)
    }

    /// Every linked home in the walk is stale: no candidate qualifies, the
    /// same outcome as no candidate being linked at all.
    func testAllStaleCodexHomesReturnsNil() throws {
        let a = try linkedCodex("A", home: "/Users/example/codex-a")
        let b = try linkedCodex("B", home: "/Users/example/codex-b-stale")

        XCTAssertNil(next(after: a, in: [a, b]) { _ in false })
    }

    // MARK: - Claude credentials and sign-in

    func testDeadSignInIsSkipped() {
        let a = liveClaude("A", usage: healthy)
        let b = deadClaude("B", usage: healthy)
        let c = liveClaude("C", usage: healthy)

        XCTAssertEqual(next(after: a, in: [a, b, c])?.id, c.id)
    }

    func testAllDeadSignInsReturnNil() {
        let a = liveClaude("A", usage: healthy)
        let b = deadClaude("B", usage: healthy)
        let c = deadClaude("C", usage: healthy)

        XCTAssertNil(next(after: a, in: [a, b, c]))
    }

    /// Neither extra-usage verdict disqualifies a destination, and this is the
    /// clause most likely to be "helpfully" added back.
    ///
    /// `browserSignInIssue` reads like an account-level liveness verdict and
    /// is not one: it is written only by
    /// `ClaudeAPIService.applyOrganizationExtraUsage`, whose own log line says
    /// the percentages on screen come from the Claude Code sign-in and are
    /// unaffected. `personalExtraUsageIssue` is the member row's equivalent.
    /// This profile is at 10% and 20% and is exactly where someone who has
    /// just run out should land.
    func testNeitherExtraUsageVerdictCostsAProfileItsPlaceAsADestination() {
        let a = liveClaude("A", usage: healthy)
        let b = liveClaude(
            "B",
            usage: reading(
                session: 10,
                weekly: 20,
                browserSignIn: .expired,
                personalExtraUsage: .signInExpired
            )
        )

        XCTAssertEqual(next(after: a, in: [a, b])?.id, b.id)
    }

    /// The transient half of the same field, kept apart so a future change
    /// that starts refusing on `.expired` cannot quietly take this with it.
    func testTemporarilyUnavailableBrowserSignInStillCounts() {
        let a = liveClaude("A", usage: healthy)
        let b = liveClaude(
            "B",
            usage: reading(
                session: 10,
                weekly: 20,
                browserSignIn: .temporarilyUnavailable
            )
        )

        XCTAssertEqual(next(after: a, in: [a, b])?.id, b.id)
    }

    // MARK: - Capacity windows

    /// The headline defect: 4% of the 5-hour window left and none of the
    /// 7-day window. The old session-only test accepted it, which is pinned
    /// inline on the very input the rule now refuses.
    func testWeeklyAtOneHundredIsSkippedThoughTodaysSessionCheckWouldAcceptIt() throws {
        let a = liveClaude("A", usage: healthy)
        let b = liveClaude("B", usage: reading(session: 4, weekly: 100))

        XCTAssertLessThan(
            try XCTUnwrap(b.claudeUsage).effectiveSessionPercentage,
            100
        )
        XCTAssertNil(next(after: a, in: [a, b]))
    }

    func testSessionAtOneHundredIsSkipped() {
        let a = liveClaude("A", usage: healthy)
        let b = liveClaude("B", usage: reading(session: 100, weekly: 4))

        XCTAssertNil(next(after: a, in: [a, b]))
    }

    func testExactlyOneHundredIsNotRoom() {
        let a = liveClaude("A", usage: healthy)
        let b = liveClaude("B", usage: reading(session: 100, weekly: 100))

        XCTAssertFalse(
            ProfileSwitchEligibility.isEligible(b, switchingFrom: a)
        )
    }

    func testNinetyNinePointNineStillCounts() {
        let a = liveClaude("A", usage: healthy)
        let b = liveClaude("B", usage: reading(session: 99.9, weekly: 99.9))

        XCTAssertTrue(
            ProfileSwitchEligibility.isEligible(b, switchingFrom: a)
        )
    }

    func testUnmeasuredSessionIsSkipped() throws {
        let a = liveClaude("A", usage: healthy)
        let b = liveClaude("B", usage: reading(session: nil, weekly: 10))

        XCTAssertNil(try XCTUnwrap(b.claudeUsage).readableSessionPercentage)
        XCTAssertNil(next(after: a, in: [a, b]))
    }

    func testUnmeasuredWeeklyIsSkipped() throws {
        let a = liveClaude("A", usage: healthy)
        let b = liveClaude("B", usage: reading(session: 10, weekly: nil))

        XCTAssertNil(try XCTUnwrap(b.claudeUsage).readableWeeklyPercentage)
        XCTAssertNil(next(after: a, in: [a, b]))
    }

    /// "We read nothing" used to arrive downstream as a confident zero, which
    /// is why an account nobody had measured looked like the emptiest one
    /// available. Both halves are pinned inline.
    func testEmptyUsageIsSkippedThoughTodaysCheckWouldReadItAsZero() throws {
        let a = liveClaude("A", usage: healthy)
        let b = liveClaude("B", usage: .empty)

        let usage = try XCTUnwrap(b.claudeUsage)
        XCTAssertEqual(usage.effectiveSessionPercentage, 0)
        XCTAssertNil(usage.readableSessionPercentage)
        XCTAssertNil(next(after: a, in: [a, b]))
    }

    /// A profile that has never been refreshed at all. The old auto-switch
    /// loop returned it immediately, on the reasoning that no stored usage
    /// meant nothing had been used.
    func testMissingUsageIsSkippedThoughTodaysCheckWouldReturnItImmediately() {
        let a = liveClaude("A", usage: healthy)
        let b = liveClaude("B", usage: nil)

        XCTAssertNil(b.claudeUsage)
        XCTAssertNil(next(after: a, in: [a, b]))
    }

    /// A session window whose reset time has passed is genuinely free, and
    /// `readableSessionPercentage` keeps that behaviour: the figure was
    /// received, it has simply rolled over.
    func testExpiredSessionWindowReadsAsRoom() {
        let a = liveClaude("A", usage: healthy)
        var expired = reading(session: 100, weekly: 10)
        expired.sessionResetTime = Date().addingTimeInterval(-60)
        let b = liveClaude("B", usage: expired)

        XCTAssertEqual(next(after: a, in: [a, b])?.id, b.id)
    }

    /// A weekly window whose reset time has passed is genuinely free, the
    /// same way an expired session window is: the figure was received, it
    /// has simply rolled over.
    func testExpiredWeeklyWindowReadsAsRoom() {
        let a = liveClaude("A", usage: healthy)
        var expired = reading(session: 10, weekly: 100)
        expired.weeklyResetTime = Date().addingTimeInterval(-60)
        let b = liveClaude("B", usage: expired)

        XCTAssertEqual(next(after: a, in: [a, b])?.id, b.id)
    }

    /// One of every rejection reason in a single walk.
    func testNoEligibleProfileReturnsNil() throws {
        let a = liveClaude("A", usage: healthy)
        let b = deadClaude("B", usage: healthy)
        let c = liveClaude("C", usage: reading(session: 100, weekly: 100))
        let d = try linkedCodex("D", home: "/Users/example/codex-d")
        let e = claudeTombstone("E", usage: healthy)

        XCTAssertNil(next(after: a, in: [a, b, c, d, e]))
    }

    // MARK: - Call sites

    private struct CallSiteContext {
        let profileManager: ProfileManager
        let menuBarManager: MenuBarManager
    }

    /// Stands up the real `MenuBarManager` against isolated storage.
    ///
    /// The store is seeded so the profile **ids** exist on disk — that is all
    /// `activateProfile`'s internal reload needs to resolve a destination.
    /// `Profile`'s encoder writes neither credentials nor usage, so the
    /// in-memory array is then restored to the rich fixtures the rule has to
    /// judge. Every activation side effect is injected as a no-op so nothing
    /// reaches the developer's real Claude Code login, `CODEX_HOME` pointer
    /// file, or tmux server.
    private func makeCallSiteContext(
        _ profiles: [Profile]
    ) throws -> CallSiteContext {
        let store = retain(makeIsolatedProfileStore())
        try seedProfilesForTesting(profiles, in: store)
        let profileManager = retain(ProfileManager(
            profileStore: store,
            activationClaudeEffects: ProfileActivationClaudeEffects(
                resyncBeforeSwitching: { _ in },
                applyProfileCredentials: { _ in },
                switchAccountAndSync: { _ in }
            ),
            activationCodexEffects: .noOp
        ))
        profileManager.profiles = profiles
        let apiService = retain(makeIsolatedClaudeAPIService(
            profileManager: profileManager,
            store: store
        ))
        let statusService = retain(ClaudeStatusService())
        let runtime = retain(UsageRefreshRuntime.live(
            profileManager: profileManager,
            apiService: apiService,
            statusService: statusService,
            featureAvailability: .testing()
        ))
        let menuBarManager = retain(MenuBarManager(
            apiService: apiService,
            statusService: statusService,
            profileManager: profileManager,
            refreshRuntime: runtime,
            providerUIDependencies: ProviderUIDependencies(
                profileManager: profileManager,
                codexProviderFactory: CodexProviderFactory(
                    availability: .testing()
                )
            )
        ))
        return CallSiteContext(
            profileManager: profileManager,
            menuBarManager: menuBarManager
        )
    }

    /// `switchToNextProfile()` fires an unstructured `Task`. It inherits the
    /// main actor, and `activateProfile` contains no `await`, so it runs to
    /// completion in one hop once scheduled — a bounded yield loop settles it
    /// and cannot hang.
    private func settleHotkeyActivation() async {
        for _ in 0..<50 {
            await Task.yield()
        }
    }

    func testAutoSwitchCallSiteReturnsTheSharedRulesChoice() throws {
        let a = liveClaude("A", usage: healthy)
        let b = deadClaude("B", usage: healthy)
        let c = liveClaude("C", usage: healthy)
        let context = try makeCallSiteContext([a, b, c])

        let chosen = context.menuBarManager.findNextAvailableProfile(after: a)

        XCTAssertEqual(chosen?.id, c.id)
        XCTAssertEqual(chosen?.id, next(after: a, in: [a, b, c])?.id)
    }

    func testAutoSwitchCallSiteReturnsNilWhenNobodyQualifies() throws {
        let a = liveClaude("A", usage: healthy)
        let b = deadClaude("B", usage: healthy)
        let context = try makeCallSiteContext([a, b])

        XCTAssertNil(context.menuBarManager.findNextAvailableProfile(after: a))
        XCTAssertNil(next(after: a, in: [a, b]))
    }

    /// Red against a half-done implementation: convert
    /// `findNextAvailableProfile` and leave the hotkey alone, and this lands
    /// on `B`, the profile with the dead sign-in.
    ///
    /// The expected id is computed from the literal fixtures, deliberately not
    /// from `profileManager.profiles` the way the two tests above do. Those
    /// activate nothing, so their array stays rich; `activateProfile` reloads
    /// from disk partway through, and `Profile`'s encoder writes neither
    /// credentials nor usage — so after this call the manager's array is the
    /// stripped copy, and re-running the rule against it would answer nil.
    func testHotkeyCallSiteActivatesTheSharedRulesChoice() async throws {
        let a = liveClaude("A", usage: healthy)
        let b = deadClaude("B", usage: healthy)
        let c = liveClaude("C", usage: healthy)
        let context = try makeCallSiteContext([a, b, c])
        context.profileManager.activeProfile = a

        context.menuBarManager.switchToNextProfile()
        await settleHotkeyActivation()

        XCTAssertEqual(context.profileManager.activeProfile?.id, c.id)
        XCTAssertEqual(
            context.profileManager.activeProfile?.id,
            next(after: a, in: [a, b, c])?.id
        )
    }

    func testHotkeyCallSiteStaysPutWhenNobodyQualifies() async throws {
        let a = liveClaude("A", usage: healthy)
        let b = deadClaude("B", usage: healthy)
        let context = try makeCallSiteContext([a, b])
        context.profileManager.activeProfile = a

        context.menuBarManager.switchToNextProfile()
        await settleHotkeyActivation()

        XCTAssertEqual(context.profileManager.activeProfile?.id, a.id)
    }
}
