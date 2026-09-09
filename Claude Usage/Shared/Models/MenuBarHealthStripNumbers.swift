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
enum MenuBarHealthStripNumbersThreshold: Equatable {
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
