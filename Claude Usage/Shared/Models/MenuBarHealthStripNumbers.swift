//
//  MenuBarHealthStripNumbers.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-09-08.
//

import Foundation

/// How busy an account has to be before the health strip spells out its
/// numbers beside its bar.
///
/// The level is configurable because the right answer depends on how many
/// accounts are on the strip: 80 fires for several of eight accounts most
/// days and gives the reclaimed width straight back, while 95 is too late to
/// be worth switching accounts over.
nonisolated enum MenuBarHealthStripNumbersThreshold: Equatable {
    /// Never widen a cell with numbers, however busy the account is.
    case never
    /// Show numbers once the account's session *or* weekly window is at or
    /// above this used percentage.
    case percent(Int)

    /// The default level for a fresh install and the fallback whenever a
    /// stored percentage is missing or non-positive.
    static let defaultPercent = 90

    /// The levels offered in Settings.
    static let selectablePercents = [80, 90, 95]

    /// How far below the threshold an account has to fall before its numbers
    /// disappear again. Without this an account hovering at the threshold
    /// widens and narrows the strip on every refresh, shifting every
    /// neighbouring app's menu bar item.
    static let hysteresisPoints = 3

    /// Stable raw identity for persistence, independent of the associated
    /// percentage. Mirrors `MenuBarOverflowMode.StorageKind`.
    enum StorageKind: String {
        case never
        case percent
    }

    var storageKind: StorageKind {
        switch self {
        case .never: return .never
        case .percent: return .percent
        }
    }
}

/// Decides whether one account's health strip cell spells out its numbers.
///
/// Pure: no AppKit, no state, no clock. The caller owns the "is it showing
/// right now" bit, because that state belongs to the status bar and has to
/// survive a redraw without surviving a relaunch.
nonisolated enum HealthStripNumbers {
    /// The two windows the threshold is allowed to look at.
    ///
    /// Named explicitly rather than "the leading two windows" so an
    /// API-console profile cannot smuggle a Credits window into the trigger.
    /// Both are *used* percentages, never the displayed figure — otherwise
    /// remaining mode would invert the trigger and an idle account would
    /// widen the strip.
    /// `now` rather than the wall clock: `readableSessionPercentage`
    /// compares the 5-hour window's expiry against `Date()` at call time, and
    /// a menu bar render has to be reproducible from its inputs. This is the
    /// same rule with the instant injected, and it is the one implementation
    /// — `updateHealthStrip` calls it rather than repeating it inline.
    ///
    /// `@MainActor` only because `ClaudeUsage` is: the app target defaults to
    /// main-actor isolation, and this reads its properties. The decision
    /// itself, `showsNumbers`, stays free of any isolation.
    @MainActor
    static func usedPercentages(
        for usage: ClaudeUsage,
        now: Date = Date()
    ) -> (session: Double?, week: Double?) {
        let session: Double? = usage.sessionPercentageAvailable
            ? (usage.sessionResetTime < now ? 0 : usage.sessionPercentage)
            : nil
        return (session, usage.readableWeeklyPercentage)
    }

    /// Whether this account's cell shows its numbers.
    ///
    /// - Parameters:
    ///   - sessionUsed: Used percentage of the 5-hour window, nil if unread.
    ///   - weekUsed: Used percentage of the 7-day window, nil if unread.
    ///   - threshold: The user's setting.
    ///   - isCurrentlyShowing: Whether this account's numbers are on screen
    ///     right now, which is what makes the hysteresis work.
    static func showsNumbers(
        sessionUsed: Double?,
        weekUsed: Double?,
        threshold: MenuBarHealthStripNumbersThreshold,
        isCurrentlyShowing: Bool
    ) -> Bool {
        guard case .percent(let percent) = threshold else {
            return false
        }
        // An account with no reading at all never triggers, and never keeps
        // numbers it is already showing: there is nothing to show.
        let readings = [sessionUsed, weekUsed].compactMap { $0 }
        guard let peak = readings.max() else {
            return false
        }

        let limit = Double(percent)
        if isCurrentlyShowing {
            // Stay until the account has dropped a full three points below
            // the threshold. Without this an account hovering at the
            // threshold widens and narrows the strip on every refresh,
            // shifting every neighbouring app's menu bar item.
            let release = limit
                - Double(MenuBarHealthStripNumbersThreshold.hysteresisPoints)
            return peak > release
        }
        return peak >= limit
    }
}
