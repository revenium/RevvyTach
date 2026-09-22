//
//  AccessibilityDisplayOptions.swift
//  Claude Usage - Settings Design System
//

import AppKit
import Combine

/// The System Settings → Accessibility → Display switches the Settings
/// window honors, kept live so toggling one while the window is open
/// re-renders it instead of waiting for the next open.
@MainActor
final class AccessibilityDisplayOptions: ObservableObject {
    static let shared = AccessibilityDisplayOptions()

    @Published private(set) var reduceTransparency: Bool
    @Published private(set) var differentiateWithoutColor: Bool

    private let workspace: NSWorkspace
    private var observer: NSObjectProtocol?

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
        reduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency
        differentiateWithoutColor = workspace.accessibilityDisplayShouldDifferentiateWithoutColor
        observer = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: workspace,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    deinit {
        if let observer {
            workspace.notificationCenter.removeObserver(observer)
        }
    }

    func refresh() {
        reduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency
        differentiateWithoutColor = workspace.accessibilityDisplayShouldDifferentiateWithoutColor
    }
}
