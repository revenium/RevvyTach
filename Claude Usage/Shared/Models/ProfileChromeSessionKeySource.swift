//
//  ProfileChromeSessionKeySource.swift
//  Claude Usage
//
//  Which Chrome profile a stored claude.ai session key was copied from.
//

import Foundation

/// The Chrome profile one claude.ai session key was read from.
///
/// Recorded only by a successful **Read from Chrome**, and cleared the moment
/// the key stops being the one that read produced — a hand-typed key, a key
/// from the embedded sign-in, or a key read from a different Chrome profile
/// all replace or clear it. That is what makes the recorded profile a fact
/// about *this* key rather than a guess about where the account lives.
///
/// Deliberately small and non-sensitive: Chrome's own directory name, the
/// label already shown in the picker, and when it was recorded. No GAIA id, no
/// avatar, no account email, and never the key itself.
nonisolated struct ProfileChromeSessionKeySource:
    Codable,
    Equatable,
    Sendable
{
    /// Chrome's profile directory name, such as `Profile 19`. This is what a
    /// later read is scoped to, so it is the field that must survive.
    var directoryName: String
    /// The label the picker showed for that profile, such as
    /// `Work — Profile 19`. Display only; it is what a notification names.
    var label: String
    /// When this pairing was recorded.
    var recordedAt: Date

    init(directoryName: String, label: String, recordedAt: Date = Date()) {
        self.directoryName = directoryName
        self.label = label
        self.recordedAt = recordedAt
    }

    /// Whether the recorded directory name is still one this app will open or
    /// read. A stored value that no longer passes the path policy is treated
    /// as no remembered profile at all.
    var isUsable: Bool {
        ChromeProfilePathPolicy.isValidDirectoryName(directoryName)
    }
}
