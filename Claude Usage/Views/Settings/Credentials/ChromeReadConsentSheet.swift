import SwiftUI

/// The consent notice shown before RevvyTach reads the claude.ai session key
/// out of Chrome.
///
/// A sheet, never an alert: an alert raised while a sheet is up does not
/// appear on this target, and the session-key step already presents the
/// embedded sign-in as a sheet. The macOS password prompt that follows is an
/// out-of-process system dialog, so it cannot collide with this.
///
/// The frame is explicit rather than content-sized. Nine translations driving
/// the height of a fixed-size presentation is the shape that crashed the
/// popover in 4.0.7, so the body scrolls inside a fixed frame instead, and
/// `ChromeReadConsentLocalizationFitTests` measures every locale against
/// `bodyHeightBudget` so a translation that has drifted into an overrun fails
/// CI rather than making a user scroll a consent notice.
struct ChromeReadConsentSheet: View {
    /// Grown from 480×500 when the notice gained the paragraph saying macOS
    /// asks for the password twice. At the old size the German and Portuguese
    /// translations no longer fit, and a consent notice a user has to scroll
    /// is a notice they can miss half of.
    static let sheetWidth: CGFloat = 520
    static let sheetHeight: CGFloat = 600
    static let contentPadding: CGFloat = 24

    /// The wrap width every measured string is asserted against.
    static let textColumnWidth = sheetWidth - 2 * contentPadding

    /// `sheetHeight` minus the fixed chrome: 2×24 padding, an 18pt title,
    /// 12 + 12 + 16 of spacing, a 22pt button row, and a 39pt scope-note
    /// allowance (three wrapped lines at 11pt).
    static let bodyHeightBudget: CGFloat = 433

    let profileLabel: String
    let onContinue: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("chrome_assisted.read_consent_title".localized)
                .font(.system(size: 16, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                Text("chrome_assisted.read_consent_body".localized)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text(
                String(
                    format: "chrome_assisted.read_scope_note".localized,
                    profileLabel
                )
            )
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Spacer()

                Button("common.cancel".localized, action: onCancel)
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("chrome.read_consent.cancel")

                // Deliberately not the default action: approving this hands
                // over Chrome's master key, so it takes a click.
                Button(
                    "chrome_assisted.read_consent_continue".localized,
                    action: onContinue
                )
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("chrome.read_consent.continue")
            }
        }
        .padding(Self.contentPadding)
        .frame(width: Self.sheetWidth, height: Self.sheetHeight)
    }
}
