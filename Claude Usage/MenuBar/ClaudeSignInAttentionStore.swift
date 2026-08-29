//
//  ClaudeSignInAttentionStore.swift
//  Claude Usage
//

import Combine
import Foundation

/// The menu bar's per-profile attention verdict, published so surfaces
/// outside the menu bar can render the same conclusion.
///
/// The verdict itself lives in `MenuBarAttentionSignal`, but its two inputs —
/// the claude.ai credential failure streak and the provider health status —
/// exist only inside `MenuBarManager`'s in-memory snapshot for a profile.
/// Nothing in Settings can reach them, which is how Settings came to disagree
/// with the icon: the menu bar showed the red disc for a rejected claude.ai
/// session key while Settings, which knows only that a key is stored, badged
/// the same sign-in "Working" and offered no repair.
///
/// This store is deliberately a relay and not a second rule. `MenuBarManager`
/// records what it just decided for a profile; readers take that value or
/// nothing. A surface that reads this can therefore never name a different
/// credential than the icon does, and a change to the rule changes both.
///
/// Absent means "the menu bar has not decided for this profile yet" and is
/// treated by readers exactly like "nothing wrong". Settings must not invent
/// an alarm for a profile the menu bar has never rendered.
/// `nonisolated` is load-bearing, not stylistic. This target defaults every
/// declaration to `@MainActor`, and under that default the synthesized deinit
/// of an isolated class aborts in malloc ("pointer being freed was not
/// allocated", inside `swift_task_deinitOnExecutorMainActorBackDeploy`)
/// whenever an instance is deallocated off the main actor — the same
/// toolchain trap `MenuBarManagerTransitionTracker`,
/// `LegacyBundleRelocationService`, and `ProfileUsageFileStore` opt out of.
/// It crashed the whole test host here. The type holds no actor-isolated
/// state; every writer and reader is already main-thread code.
nonisolated final class ClaudeSignInAttentionStore: ObservableObject {
    static let shared = ClaudeSignInAttentionStore()

    @Published private(set) var attention:
        [UUID: MenuBarAttentionSignal.Credential] = [:]

    init() {}

    /// Record the marker decision the menu bar just made for one profile.
    /// `nil` clears any previous verdict, so a repaired sign-in stops being
    /// reported the moment the icon stops marking it.
    func record(
        _ credential: MenuBarAttentionSignal.Credential?,
        for profileID: UUID
    ) {
        guard attention[profileID] != credential else { return }
        attention[profileID] = credential
    }

    /// Replace every verdict at once, which is how the refresh path
    /// publishes: it decides for every Claude profile the app knows about,
    /// so a profile that is not drawn in the menu bar still gets a verdict
    /// and a profile that has gone away stops carrying a stale one.
    func replace(
        with verdicts: [UUID: MenuBarAttentionSignal.Credential]
    ) {
        guard attention != verdicts else { return }
        attention = verdicts
    }

    func credential(
        for profileID: UUID
    ) -> MenuBarAttentionSignal.Credential? {
        attention[profileID]
    }
}
