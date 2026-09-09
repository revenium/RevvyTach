//
//  MenuBarMultiLayout.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-09-08.
//

import Foundation

/// Chooses how the selected Claude profiles are drawn while multi-profile
/// mode is on.
///
/// This is deliberately *not* a third `ProfileDisplayMode` case. Twenty-seven
/// places compare `displayMode == .multi` to decide refresh fan-out, popover
/// targeting, credential-change routing and freshness deadlines; a new case
/// would make every one of those comparisons silently false for health-strip
/// users, with no compiler error. Keeping the choice inside multi mode leaves
/// profile selection, refresh, notifications and the popover untouched and
/// branches only where status items are built.
///
/// It is also not a `MultiProfileIconStyle`: that enum picks how a *single*
/// profile's own status item is drawn, and every consumer of it assumes one
/// item per profile.
enum MenuBarMultiLayout: String, Codable, CaseIterable {
    /// Today's behavior: one `NSStatusItem` per selected profile, with the
    /// overflow ("+N") item collapsing the ones that don't fit.
    case perProfileItems
    /// One status item for every selected Claude profile, drawn as a row of
    /// small vertical usage bars. Overflow does not apply.
    case healthStrip
}
