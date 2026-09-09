//
//  ProfileResetOrder.swift
//  Claude Usage
//
//  Created by Codex on 2026-09-09.
//

import Foundation

/// The one account ordering used anywhere RevvyTach controls the order of
/// several Claude accounts.
///
/// A real weekly reset sorts before an unknown one. Equal weekly resets fall
/// to the session reset (again, known before unknown), then Finder-style name
/// order, then the incoming position so duplicate names remain stable.
enum ProfileResetOrder {
    private struct Entry {
        let profile: Profile
        let position: Int
        let weeklyResetTime: Date?
        let sessionResetTime: Date?
    }

    static func sorted(
        _ profiles: [Profile],
        snapshots: [UUID: PresentationSnapshot]
    ) -> [Profile] {
        profiles.enumerated()
            .map { position, profile in
                let usage = claudeUsage(
                    for: profile,
                    snapshot: snapshots[profile.id]
                )
                return Entry(
                    profile: profile,
                    position: position,
                    weeklyResetTime: usage.flatMap {
                        $0.weeklyPercentageAvailable
                            ? $0.weeklyResetTime
                            : nil
                    },
                    sessionResetTime: usage.flatMap {
                        $0.sessionPercentageAvailable
                            ? $0.sessionResetTime
                            : nil
                    }
                )
            }
            .sorted(by: comesBefore)
            .map(\.profile)
    }

    /// Resolves the reading on the same snapshot-first terms as the menu
    /// presentation layer. A stale snapshot is ignored rather than being
    /// allowed to reorder the profile it used to describe.
    static func claudeUsage(
        for profile: Profile,
        snapshot: PresentationSnapshot?
    ) -> ClaudeUsage? {
        let validSnapshot = snapshot.flatMap {
            ProviderMenuPresentationBuilder.snapshotMatches(
                profile: profile,
                snapshot: $0
            ) ? $0 : nil
        }
        return validSnapshot?.claudeUsage ?? profile.claudeUsage
    }

    private static func comesBefore(_ lhs: Entry, _ rhs: Entry) -> Bool {
        if let result = compareKnownFirst(
            lhs.weeklyResetTime,
            rhs.weeklyResetTime
        ) {
            return result
        }
        if let result = compareKnownFirst(
            lhs.sessionResetTime,
            rhs.sessionResetTime
        ) {
            return result
        }
        let byName = lhs.profile.name.localizedStandardCompare(
            rhs.profile.name
        )
        if byName != .orderedSame {
            return byName == .orderedAscending
        }
        return lhs.position < rhs.position
    }

    /// Returns nil when the two values are tied and comparison should move
    /// to the next key.
    private static func compareKnownFirst(
        _ lhs: Date?,
        _ rhs: Date?
    ) -> Bool? {
        switch (lhs, rhs) {
        case let (left?, right?) where left != right:
            return left < right
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        default:
            return nil
        }
    }
}
