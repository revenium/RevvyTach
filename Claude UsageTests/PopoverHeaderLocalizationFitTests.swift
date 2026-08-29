//
//  PopoverHeaderLocalizationFitTests.swift
//  Claude UsageTests
//
//  Created by Claude Code on 2026-08-24.
//

import AppKit
import XCTest
@testable import Claude_Usage

/// Measures the header's new meta rows in every shipped locale.
///
/// Measured, not counted. A previous pass on this popover predicted two
/// truncations by counting characters and six of the nine locales truncated,
/// because a character is not a width — "Nicht unterstütztes Konto" and
/// "アカウント" have nothing to do with each other per glyph. These are real
/// Core Text measurements of the real strings at the real font sizes.
final class PopoverHeaderLocalizationFitTests: XCTestCase {

    /// Width the header's meta rows actually get: the popover width, less the
    /// horizontal insets, less the 40pt indent that lines them up under the
    /// account name rather than the avatar.
    private static let availableWidth =
        PopoverDesign.width - 2 * PopoverDesign.outerInset - 40

    private static let locales = [
        "de", "en", "es", "fr", "it", "ja", "ko", "pt", "zh-Hans"
    ]

    /// The SF Symbol leading the account row, at 9pt. Deliberately generous:
    /// under-stating the glyph would make this test pass a row that clips.
    private static let glyphWidth: CGFloat = 16

    private static let dotWidth: CGFloat = 6
    private static let rowSpacing: CGFloat = 5

    private func resourceBundle(for locale: String) throws -> Bundle {
        let host = Bundle(for: MenuBarManager.self)
        let path = try XCTUnwrap(
            host.path(forResource: locale, ofType: "lproj"),
            "\(locale).lproj is missing from the built bundle"
        )
        return try XCTUnwrap(Bundle(path: path))
    }

    private func string(
        _ key: String,
        _ locale: String
    ) throws -> String {
        let value = try resourceBundle(for: locale)
            .localizedString(forKey: key, value: nil, table: nil)
        XCTAssertNotEqual(
            value,
            key,
            "\(locale) has no translation for \(key)"
        )
        return value
    }

    private func width(
        _ text: String,
        size: CGFloat,
        weight: NSFont.Weight = .regular
    ) -> CGFloat {
        (text as NSString).size(
            withAttributes: [
                .font: NSFont.systemFont(ofSize: size, weight: weight)
            ]
        ).width
    }

    private func wrappedHeight(
        _ text: String,
        width: CGFloat,
        size: CGFloat,
        weight: NSFont.Weight = .regular
    ) -> CGFloat {
        (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: weight)
            ]
        ).height
    }

    /// Every health verdict the account row can carry.
    private static let healthKeys = [
        "popover.normalized.health.healthy",
        "popover.normalized.health.degraded",
        "popover.normalized.health.unavailable",
        "popover.normalized.health.sign_in",
        "popover.normalized.health.unsupported",
        "popover.normalized.health.checking",
        "popover.normalized.health.sign_in_problem",
        // The credential-specific verdicts. They carry a product name the
        // generic ones do not, which is exactly the kind of growth that
        // truncates: measured here rather than assumed to fit because the
        // shorter string above did.
        "popover.normalized.health.claude_ai_sign_in",
        "popover.normalized.health.claude_ai_sign_in_problem",
        "popover.normalized.health.claude_code_sign_in_problem"
    ]

    /// Width the top-of-popover banner's message actually gets: the popover
    /// width, less the outer inset on each side, less the banner card's own
    /// 12pt horizontal padding, less the 12pt leading icon, the chevron, and
    /// the 8pt gaps between them.
    private static let bannerTextWidth =
        PopoverDesign.width - 2 * PopoverDesign.outerInset - 2 * 12
        - 14 - 9 - 2 * 8

    /// Every message the top-of-popover banners can carry. Measured together
    /// so a new banner is held to the same budget as the one it sits under.
    private static let bannerKeys = [
        "popover.banner.credentials_expired",
        "popover.banner.cli_sign_in_expired",
        "popover.banner.cli_signed_out",
        "popover.banner.cli_sign_in_unusable"
    ]

    /// `StatusBannerView` gives its message `lineLimit(2)`, so the budget is
    /// two lines of `bannerTextWidth`. Measured rather than counted: the
    /// character-counting pass on this popover predicted two truncations and
    /// six of nine locales truncated.
    ///
    /// The 0.9 factor is the wrapping allowance — a line break lands on a
    /// word boundary, not at the exact pixel the width runs out, so a string
    /// measuring just under 2× the width can still need a third line.
    func testStatusBannerMessagesFitTwoLinesInEveryLocale() throws {
        let budget = Self.bannerTextWidth * 2 * 0.9
        for locale in Self.locales {
            for key in Self.bannerKeys {
                let message = try string(key, locale)
                let measured = width(message, size: 11, weight: .medium)
                XCTAssertLessThanOrEqual(
                    measured,
                    budget,
                    "\(locale) truncates \"\(message)\" — \(Int(measured))pt "
                        + "against a \(Int(budget))pt two-line budget"
                )
            }
        }
    }

    /// The two banners rendered with `lineLimit(4)`. Measured together so a
    /// new one is held to the same budget as the one it sits beside.
    private static let fourLineBannerKeys = [
        "popover.banner.setup_incomplete",
        "popover.banner.browser_sign_in_expired"
    ]

    func testFourLineBannersFitTheirSurfaceInEveryLocale() throws {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let fourLineHeight = ceil(font.ascender - font.descender
            + font.leading) * 4
        for locale in Self.locales {
            for key in Self.fourLineBannerKeys {
                let message = try string(key, locale)
                let measured = wrappedHeight(
                    message,
                    width: Self.bannerTextWidth,
                    size: 11,
                    weight: .medium
                )
                XCTAssertLessThanOrEqual(
                    measured,
                    fourLineHeight,
                    "\(locale) truncates \(key) — "
                        + "\(Int(measured))pt high against a four-line "
                        + "\(Int(fourLineHeight))pt limit"
                )
            }
        }
    }

    /// The Claude Account page's verdict card. Its four verdicts changed with
    /// CLI-first and six of the nine catalogues grew, so they are measured
    /// rather than counted — the recorded finding on this repo is that
    /// character counts predicted two truncations where measurement found
    /// six.
    ///
    /// Width is the real one: a 720pt settings window, less the 190pt
    /// sidebar, less the page's 20pt horizontal padding on each side, less
    /// the card's 16pt (`Spacing.lg`) padding on each side, less the 15pt
    /// leading symbol and the 8pt (`Spacing.md`) gap after it.
    private static let verdictTextWidth: CGFloat =
        720 - 190 - 2 * 20 - 2 * 16 - 15 - 8

    /// Every verdict the summary card can show, plus the two status pills
    /// added with them.
    private static let accountVerdictKeys = [
        "claude_account.summary.verdict.complete",
        "claude_account.summary.verdict.browser_only",
        "claude_account.summary.verdict.terminal_only",
        "claude_account.summary.verdict.none",
        "claude_account.subtitle",
        "claude_account.browser.missing_detail",
        "claude_account.summary.status.optional",
        "claude_account.summary.status.recommended",
        "claude_account.summary.verdict.browser_needs_attention"
    ]

    func testClaudeAccountVerdictsFitTheirCardInEveryLocale() throws {
        let font = NSFont.systemFont(ofSize: 13)
        let fourLineHeight = ceil(font.ascender - font.descender
            + font.leading) * 4
        for locale in Self.locales {
            for key in Self.accountVerdictKeys {
                let verdict = try string(key, locale)
                let measured = wrappedHeight(
                    verdict,
                    width: Self.verdictTextWidth,
                    size: 13
                )
                XCTAssertLessThanOrEqual(
                    measured,
                    fourLineHeight,
                    "\(locale) overflows \(key) — \(Int(measured))pt high "
                        + "against a four-line \(Int(fourLineHeight))pt "
                        + "budget in \(Int(Self.verdictTextWidth))pt"
                )
            }
        }
    }

    /// The two status pills sit inline beside a row title, so they are held
    /// to a width rather than a height.
    func testStatusPillsFitBesideTheirRowTitleInEveryLocale() throws {
        // Row title, an 8pt gap, the pill's 7pt horizontal padding on each
        // side, and the action button's own share of the row.
        let pillBudget: CGFloat = 140
        for locale in Self.locales {
            for key in [
                "claude_account.summary.status.optional",
                "claude_account.summary.status.recommended",
                "claude_account.summary.status.working",
                "claude_account.summary.status.needs_attention",
                "claude_account.summary.status.not_linked",
                "claude_account.summary.status.missing"
            ] {
                let pill = try string(key, locale)
                let measured = width(pill, size: 10, weight: .semibold)
                    + 2 * 7
                XCTAssertLessThanOrEqual(
                    measured,
                    pillBudget,
                    "\(locale) overflows the \(key) pill — "
                        + "\(Int(measured))pt in \(Int(pillBudget))pt"
                )
            }
        }
    }

    func testAccountHealthRowFitsInEveryLocale() throws {
        for locale in Self.locales {
            let label = try string(
                "popover.normalized.account_health.label",
                locale
            )
            let fixed = Self.glyphWidth
                + width(label, size: 11, weight: .semibold)
                + width("·", size: 11)
                + Self.rowSpacing * 3

            for key in Self.healthKeys {
                let verdict = try string(key, locale)
                let total = fixed + width(verdict, size: 11)
                XCTAssertLessThanOrEqual(
                    total,
                    Self.availableWidth,
                    "\(locale) truncates \"\(label) · \(verdict)\" — "
                        + "\(Int(total))pt in \(Int(Self.availableWidth))pt"
                )
            }
        }
    }

    func testClaudeAccountSidebarBadgeFitsInEveryLocale() throws {
        // Exact production geometry: `ProfileSectionContainer` consumes 12pt
        // on each sidebar edge; `CredentialMiniCard` adds 4pt outer and 8pt
        // inner padding on each edge; its leading icon is 12pt; and the
        // icon/VStack plus VStack/Spacer boundaries each consume the real 8pt
        // HStack gap. The title and badge are vertically stacked, so each gets
        // this leading-column width independently. The badge's text also pays
        // its own 5pt capsule inset on each side.
        let sidebarWidth: CGFloat = 190
        let containerInsets: CGFloat = 2 * 12
        let rowInsets: CGFloat = 2 * 8
        let cardOuterInsets: CGFloat = 2 * 4
        let cardInnerInsets: CGFloat = 2 * 8
        let iconWidth: CGFloat = 12
        let hStackGaps: CGFloat = 2 * 8
        let badgeInsets: CGFloat = 2 * 5
        let leadingColumnWidth = sidebarWidth - containerInsets - rowInsets
            - cardOuterInsets - cardInnerInsets - iconWidth - hStackGaps
        let badgeTextWidth = leadingColumnWidth - badgeInsets
        for locale in Self.locales {
            let title = try string("section.claude_account_title", locale)
            let titleWidth = width(title, size: 11, weight: .medium)
            XCTAssertLessThanOrEqual(
                titleWidth,
                leadingColumnWidth,
                "\(locale) truncates Claude Account — "
                    + "\(Int(titleWidth))pt in "
                    + "\(Int(leadingColumnWidth))pt"
            )
            // Both badges this row can carry. "Needs attention" arrived
            // after the geometry above was measured, and is the longer of
            // the two, so it is asserted rather than assumed to fit.
            for key in [
                "claude_account.incomplete_badge",
                "claude_account.summary.status.needs_attention"
            ] {
                let badge = try string(key, locale)
                let badgeWidth = width(badge, size: 8, weight: .semibold)
                XCTAssertLessThanOrEqual(
                    badgeWidth,
                    badgeTextWidth,
                    "\(locale) truncates the \(badge) badge — "
                        + "\(Int(badgeWidth))pt in "
                        + "\(Int(badgeTextWidth))pt"
                )
            }
        }
    }

    /// The service-status row is unchanged by the account row above it, but it
    /// is the string that already truncated once here, so its headroom is
    /// asserted rather than assumed.
    func testServiceStatusRowStillFits() {
        // Not localized: it is Anthropic's own wording, from status.claude.com.
        let longestKnownStatus = "All Systems Operational"
        let total = width("Claude", size: 11, weight: .semibold)
            + width("·", size: 11)
            + Self.dotWidth
            + width(longestKnownStatus, size: 11)
            + Self.rowSpacing * 3
        XCTAssertLessThanOrEqual(total, Self.availableWidth)
    }

    func testFigureAgeLineFitsInEveryLocale() throws {
        for locale in Self.locales {
            for key in [
                "popover.normalized.age.ago",
                "popover.normalized.age.just_now"
            ] {
                let format = try string(key, locale)
                // The longest duration the compact formatter produces.
                let rendered = String(
                    format: format,
                    locale: Locale(identifier: locale),
                    "365d 23h"
                )
                XCTAssertLessThanOrEqual(
                    width(rendered, size: 10),
                    Self.availableWidth,
                    "\(locale) truncates \"\(rendered)\""
                )
            }
        }
    }
}
