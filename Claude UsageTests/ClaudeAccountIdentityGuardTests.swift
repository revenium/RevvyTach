import Foundation
import XCTest
@testable import Claude_Usage

/// Whether the Claude Code login a profile is bound to is still the account
/// that profile stands for.
///
/// The identifiers below are the ones from a machine where two Claude Code
/// configuration directories held one account's login: two profiles fetched
/// that one account and published its percentages twice, with nothing on
/// screen to say why.
@MainActor
final class ClaudeAccountIdentityGuardTests: XCTestCase {

    /// The account `daithi-walsh` and `daithi-ie` are both signed in as.
    private let sharedAccount = "048a9b16-1391-4949-94be-b4f0f3c866c3"
    /// The account the third profile is signed in as.
    private let otherAccount = "ed73b56e-85e9-4a68-81e6-e7db3e26c2b9"
    private let firstOrganization = "9a19e5fe-1790-402b-9cdd-0b04171a69f0"
    private let secondOrganization = "2c637784-5e2d-4473-b7be-cc8cb2bd8214"

    private let firstID = UUID()
    private let secondID = UUID()

    private func binding(
        _ id: UUID,
        _ name: String,
        organization: String? = nil,
        account: String? = nil
    ) -> ClaudeAccountIdentityGuard.ProfileBinding {
        ClaudeAccountIdentityGuard.ProfileBinding(
            id: id,
            name: name,
            organizationUUID: organization,
            accountUUID: account
        )
    }

    private func account(
        _ uuid: String
    ) -> ClaudeAccountIdentityGuard.ClaudeCodeAccount {
        ClaudeAccountIdentityGuard.ClaudeCodeAccount(
            uuid: uuid,
            emailAddress: "someone@example.com"
        )
    }

    // MARK: - The defect itself

    /// Two profiles, two directory names, one account. The organization the
    /// API reports cannot catch this — a personal subscription has none — so
    /// the account uuid in the directory's own `.claude.json` is what does.
    func testAnAccountAnotherProfileAlreadyShowsIsRefused() {
        XCTAssertEqual(
            ClaudeAccountIdentityGuard.verdict(
                claudeCodeAccount: account(sharedAccount),
                for: binding(firstID, "daithi-walsh"),
                otherProfiles: [
                    binding(secondID, "daithi-ie", account: sharedAccount)
                ]
            ),
            .mismatch(.accountAlreadyBound(profileName: "daithi-ie"))
        )
    }

    /// The collision is checked before the profile's own recorded identity,
    /// so a machine already in the broken state is caught on the first
    /// reading rather than only after someone re-links something.
    func testAdoptionNeverOverridesACollision() {
        XCTAssertEqual(
            ClaudeAccountIdentityGuard.verdict(
                claudeCodeAccount: account(sharedAccount),
                for: binding(firstID, "daithi-walsh", account: nil),
                otherProfiles: [
                    binding(secondID, "daithi-ie", account: sharedAccount)
                ]
            ),
            .mismatch(.accountAlreadyBound(profileName: "daithi-ie"))
        )
    }

    func testADirectorySignedInAsAnotherAccountIsRefused() {
        XCTAssertEqual(
            ClaudeAccountIdentityGuard.verdict(
                claudeCodeAccount: account(otherAccount),
                for: binding(firstID, "first", account: sharedAccount),
                otherProfiles: []
            ),
            .mismatch(
                .differentAccount(
                    expected: sharedAccount,
                    actual: otherAccount
                )
            )
        )
    }

    // MARK: - What must never be read as a refusal

    /// No directory, no `oauthAccount`, an unreadable file: all of them
    /// arrive as nil, and none may blank a working reading.
    func testAnUnreadableIdentityFailsOpen() {
        XCTAssertEqual(
            ClaudeAccountIdentityGuard.verdict(
                claudeCodeAccount: nil,
                for: binding(firstID, "first", account: sharedAccount),
                otherProfiles: [
                    binding(secondID, "second", account: sharedAccount)
                ]
            ),
            .undetermined
        )
        XCTAssertEqual(
            ClaudeAccountIdentityGuard.verdict(
                claudeCodeAccount: ClaudeAccountIdentityGuard
                    .ClaudeCodeAccount(uuid: ""),
                for: binding(firstID, "first", account: sharedAccount),
                otherProfiles: []
            ),
            .undetermined
        )
    }

    /// A profile bound before this field existed carries nothing to compare.
    /// It adopts what it is signed in as rather than breaking on upgrade.
    func testAProfileWithNothingRecordedAdoptsItsAccount() {
        XCTAssertEqual(
            ClaudeAccountIdentityGuard.verdict(
                claudeCodeAccount: account(otherAccount),
                for: binding(firstID, "first"),
                otherProfiles: [
                    binding(secondID, "second", account: sharedAccount)
                ]
            ),
            .belongsToThisProfile
        )
        XCTAssertTrue(
            ClaudeAccountIdentityGuard.shouldRecordAccountUUID(
                otherAccount,
                on: binding(firstID, "first")
            )
        )
    }

    func testTheProfilesOwnAccountPasses() {
        XCTAssertEqual(
            ClaudeAccountIdentityGuard.verdict(
                claudeCodeAccount: account(otherAccount),
                for: binding(firstID, "first", account: otherAccount),
                otherProfiles: [
                    binding(secondID, "second", account: sharedAccount)
                ]
            ),
            .belongsToThisProfile
        )
        XCTAssertFalse(
            ClaudeAccountIdentityGuard.shouldRecordAccountUUID(
                otherAccount,
                on: binding(firstID, "first", account: otherAccount)
            )
        )
        XCTAssertFalse(
            ClaudeAccountIdentityGuard.shouldRecordAccountUUID(
                nil,
                on: binding(firstID, "first")
            )
        )
    }

    // MARK: - Configuration time, browser sign-in

    /// Organizations exist on this credential, unlike on a personal Claude
    /// Code token, so the browser sign-in is checked by organization.
    func testAPastedKeyForAnotherAccountIsRefused() {
        XCTAssertEqual(
            ClaudeAccountIdentityGuard.browserSignInVerdict(
                organizationUUIDs: [secondOrganization],
                for: binding(
                    firstID,
                    "first",
                    organization: firstOrganization
                ),
                otherProfiles: []
            ),
            .mismatch(
                .differentOrganization(
                    expected: firstOrganization,
                    actual: secondOrganization
                )
            )
        )
    }

    /// Two profiles on one ORGANIZATION is a supported setup — two seats,
    /// two people, two sets of member figures — and this codebase says so
    /// twice, in `fetchUsageData(using:)` ("organization id which more than
    /// one profile can share") and on `CapturedUsageRequest.profileID`
    /// ("which two profiles can share"). Refusing it would make a documented
    /// configuration impossible to set up, which is a regression on team
    /// customers and not the defect being fixed. Two profiles on one ACCOUNT
    /// is the defect, and that is what the verdict above refuses.
    func testTwoProfilesOnOneOrganizationIsAllowed() {
        XCTAssertEqual(
            ClaudeAccountIdentityGuard.browserSignInVerdict(
                organizationUUIDs: [secondOrganization],
                for: binding(UUID(), "second seat"),
                otherProfiles: [
                    binding(
                        secondID,
                        "existing",
                        organization: secondOrganization
                    )
                ]
            ),
            .belongsToThisProfile
        )
    }

    func testAPastedKeyForThisProfilesOwnOrganizationIsAccepted() {
        XCTAssertEqual(
            ClaudeAccountIdentityGuard.browserSignInVerdict(
                organizationUUIDs: [firstOrganization, secondOrganization],
                for: binding(
                    firstID,
                    "first",
                    organization: firstOrganization
                ),
                otherProfiles: []
            ),
            .belongsToThisProfile
        )
    }

    func testAnEmptyOrganizationListEstablishesNothing() {
        XCTAssertEqual(
            ClaudeAccountIdentityGuard.browserSignInVerdict(
                organizationUUIDs: [],
                for: binding(
                    firstID,
                    "first",
                    organization: firstOrganization
                ),
                otherProfiles: []
            ),
            .undetermined
        )
    }

    // MARK: - This machine

    /// Two profiles, two directory names, one account, neither carrying a
    /// recorded identity: both are refused. There is no non-arbitrary winner
    /// between them, and publishing under one name a number the other earned
    /// equally is the defect, not the fix. Each of them names the reason on
    /// screen rather than going blank — see `fetchUsageData(using:)`, which
    /// returns an empty `ClaudeUsage` carrying `.differentAccount`.
    func testBothProfilesOnOneAccountAreRefusedAndTheThirdIsNot() {
        let walsh = binding(firstID, "daithi-walsh")
        let ie = binding(secondID, "daithi-ie")
        let reveniumID = UUID()

        XCTAssertEqual(
            ClaudeAccountIdentityGuard.verdict(
                claudeCodeAccount: account(sharedAccount),
                for: walsh,
                otherProfiles: [
                    binding(secondID, "daithi-ie", account: sharedAccount)
                ]
            ),
            .mismatch(.accountAlreadyBound(profileName: "daithi-ie"))
        )
        XCTAssertEqual(
            ClaudeAccountIdentityGuard.verdict(
                claudeCodeAccount: account(sharedAccount),
                for: ie,
                otherProfiles: [
                    binding(firstID, "daithi-walsh", account: sharedAccount)
                ]
            ),
            .mismatch(.accountAlreadyBound(profileName: "daithi-walsh"))
        )
        XCTAssertEqual(
            ClaudeAccountIdentityGuard.verdict(
                claudeCodeAccount: account(otherAccount),
                for: binding(reveniumID, "daithi-revenium"),
                otherProfiles: [
                    binding(firstID, "daithi-walsh", account: sharedAccount),
                    binding(secondID, "daithi-ie", account: sharedAccount)
                ]
            ),
            .belongsToThisProfile
        )
    }
}
