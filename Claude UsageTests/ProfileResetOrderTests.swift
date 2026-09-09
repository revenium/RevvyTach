//
//  ProfileResetOrderTests.swift
//  Claude UsageTests
//
//  Created by Codex on 2026-09-09.
//

import XCTest
@testable import Claude_Usage

final class ProfileResetOrderTests: XCTestCase {
    private func profile(
        _ name: String,
        weeklyReset: TimeInterval?,
        sessionReset: TimeInterval? = 1_000,
        id: UUID = UUID()
    ) -> Profile {
        var usage = ClaudeUsage.empty
        if let weeklyReset {
            usage.weeklyPercentageAvailable = true
            usage.weeklyResetTime = Date(timeIntervalSince1970: weeklyReset)
        }
        if let sessionReset {
            usage.sessionPercentageAvailable = true
            usage.sessionResetTime = Date(timeIntervalSince1970: sessionReset)
        }
        var profile = Profile(id: id, name: name)
        profile.claudeUsage = usage
        return profile
    }

    private func names(_ profiles: [Profile]) -> [String] {
        ProfileResetOrder.sorted(profiles, snapshots: [:]).map(\.name)
    }

    func testEarliestWeeklyResetSortsFirst() {
        XCTAssertEqual(
            names([
                profile("Late", weeklyReset: 300),
                profile("Early", weeklyReset: 100),
                profile("Middle", weeklyReset: 200)
            ]),
            ["Early", "Middle", "Late"]
        )
    }

    func testUnknownWeeklyResetSortsLastAsAGroup() {
        XCTAssertEqual(
            names([
                profile("Unknown A", weeklyReset: nil, sessionReset: 10),
                profile("Known", weeklyReset: 500, sessionReset: nil),
                profile("Unknown B", weeklyReset: nil, sessionReset: 20)
            ]),
            ["Known", "Unknown A", "Unknown B"]
        )
    }

    func testWeeklyTieFallsToSessionResetWithUnknownSessionLast() {
        XCTAssertEqual(
            names([
                profile("Unknown session", weeklyReset: 500, sessionReset: nil),
                profile("Later session", weeklyReset: 500, sessionReset: 200),
                profile("Earlier session", weeklyReset: 500, sessionReset: 100)
            ]),
            ["Earlier session", "Later session", "Unknown session"]
        )
    }

    func testResetTieFallsToLocalizedStandardName() {
        XCTAssertEqual(
            names([
                profile("Profile 10", weeklyReset: 500),
                profile("Profile 2", weeklyReset: 500),
                profile("profile 1", weeklyReset: 500)
            ]),
            ["profile 1", "Profile 2", "Profile 10"]
        )
    }

    func testCompleteTieKeepsIncomingPosition() {
        let firstID = UUID()
        let secondID = UUID()
        let profiles = [
            profile("Same", weeklyReset: 500, id: firstID),
            profile("Same", weeklyReset: 500, id: secondID)
        ]

        XCTAssertEqual(
            ProfileResetOrder.sorted(profiles, snapshots: [:]).map(\.id),
            [firstID, secondID]
        )
    }
}
