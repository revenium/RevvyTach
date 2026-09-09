//
//  HealthStripAccessibilityTests.swift
//  Claude UsageTests
//
//  Created by Claude Code on 2026-09-08.
//

import AppKit
import XCTest
@testable import Claude_Usage

/// The strip is one picture holding eight accounts, so the words it carries
/// are the only way anyone reaches it through VoiceOver or a hover. These
/// tests hold those words to the same standard as the picture.
@MainActor
final class HealthStripAccessibilityTests: XCTestCase {
    private let renderer = MenuBarIconRenderer()

    /// `session` and `week` are the two windows' own displayed figures;
    /// the bar's figure is whichever is tighter, which is what the strip
    /// actually resolves upstream.
    private func input(
        name: String,
        session: Double?,
        week: Double? = nil,
        showRemaining: Bool = false,
        isActive: Bool = false,
        attention: MenuBarAttentionSignal.Credential? = nil
    ) -> MenuBarIconRenderer.HealthStripProfileInput {
        MenuBarIconRenderer.HealthStripProfileInput(
            profileID: UUID(),
            profileName: name,
            displayPercentage: [session, week].compactMap { $0 }.max(),
            sessionDisplay: session,
            weekDisplay: week,
            status: .safe,
            showRemaining: showRemaining,
            isActive: isActive,
            attention: attention,
            numbersImage: nil
        )
    }

    private func sessionName() -> String {
        StatusBarUIManager.legacyMetricName(for: .session)
    }

    private func weekName() -> String {
        StatusBarUIManager.legacyMetricName(for: .week)
    }

    private func strip(
        _ inputs: [MenuBarIconRenderer.HealthStripProfileInput]
    ) -> MenuBarIconRenderer.HealthStripRender {
        renderer.createHealthStrip(
            profiles: inputs,
            monochromeMode: false,
            isDarkMode: false
        )
    }

    func testTheTooltipNamesEveryAccountOnTheStrip() {
        let names = ["Work", "Personal", "Consulting", "Spare"]
        let render = strip(
            names.map { input(name: $0, session: 40) }
        )

        for name in names {
            XCTAssertTrue(
                render.tooltip.contains(name),
                "Hovering the strip must name \(name); it is the only way "
                    + "to tell which bar belongs to which account"
            )
        }
    }

    func testTheHeaderCountsTheAccounts() {
        let render = strip(
            (0..<3).map { input(name: "P\($0)", session: 10) }
        )

        XCTAssertTrue(render.tooltip.contains("3"))
        XCTAssertTrue(render.accessibilityLabel.contains("3"))
    }

    func testTheLabelNamesBothWindowsForEveryAccount() {
        let render = strip([
            input(name: "Work", session: 83, week: 40),
            input(name: "Personal", session: 12, week: 9)
        ])

        for figure in ["83%", "40%", "12%", "9%"] {
            XCTAssertTrue(
                render.accessibilityLabel.contains(figure),
                "\(figure) is missing from: \(render.accessibilityLabel)"
            )
        }
        XCTAssertTrue(render.accessibilityLabel.contains(sessionName()))
        XCTAssertTrue(render.accessibilityLabel.contains(weekName()))
        XCTAssertTrue(
            render.accessibilityLabel.contains(
                StatusBarUIManager.usageModeText(showRemaining: false)
            )
        )
    }

    /// The bar draws whichever window is tighter, so an unnamed number would
    /// change meaning between refreshes — and could fall while usage rises.
    func testTheWeekIsNamedWhenItIsTheTighterWindow() throws {
        let render = strip([input(name: "Work", session: 30, week: 91)])
        let line = try XCTUnwrap(
            render.tooltip.split(separator: "\n").map(String.init).last
        )

        XCTAssertTrue(
            line.contains("\(weekName()), 91%"),
            "The 91% the bar is drawn from must be named as the week: \(line)"
        )
        XCTAssertTrue(
            line.contains("\(sessionName()), 30%"),
            "and the session figure must still be said: \(line)"
        )
    }

    func testAWindowNobodyReadIsNamedAndSaidInWords() throws {
        let render = strip([input(name: "Work", session: nil, week: 60)])
        let noData = ProviderUILocalization.text(
            "menubar.accessibility.state.no_data",
            fallback: "no usage data"
        )
        let line = try XCTUnwrap(
            render.tooltip.split(separator: "\n").map(String.init).last
        )

        XCTAssertTrue(line.contains("\(sessionName()), \(noData)"))
        XCTAssertTrue(line.contains("\(weekName()), 60%"))
    }

    func testRemainingModeIsSaidInTheRemainingVocabulary() {
        let render = strip([
            input(name: "Work", session: 80, showRemaining: true)
        ])

        XCTAssertTrue(
            render.accessibilityLabel.contains(
                StatusBarUIManager.usageModeText(showRemaining: true)
            ),
            "A remaining figure must not be spoken as a used one"
        )
    }

    func testAnAccountWithNeitherWindowReadCollapsesToOneSentence() {
        let render = strip([
            input(name: "Work", session: nil, week: nil)
        ])
        let noData = ProviderUILocalization.text(
            "menubar.accessibility.state.no_data",
            fallback: "no usage data"
        )

        XCTAssertTrue(
            render.accessibilityLabel.contains(noData),
            "A dash on screen and a spoken 0% would be the same lie twice"
        )
        XCTAssertFalse(render.accessibilityLabel.contains("0%"))
    }

    func testTheCredentialSentenceComesFromAttentionStateTextAndDiffers() {
        let claudeCode = strip([
            input(name: "Work", session: 50, attention: .claudeCode)
        ])
        let claudeAI = strip([
            input(name: "Work", session: 50, attention: .claudeAI)
        ])

        let codeText = StatusBarUIManager.attentionStateText(.claudeCode)
        let aiText = StatusBarUIManager.attentionStateText(.claudeAI)
        XCTAssertNotEqual(
            codeText,
            aiText,
            "The two credentials are repaired on two different screens, so "
                + "the words must not be interchangeable"
        )
        XCTAssertTrue(claudeCode.accessibilityLabel.contains(codeText))
        XCTAssertTrue(claudeCode.tooltip.contains(codeText))
        XCTAssertTrue(claudeAI.accessibilityLabel.contains(aiText))
        XCTAssertFalse(claudeAI.accessibilityLabel.contains(codeText))
    }

    func testOnlyTheTroubledAccountCarriesTheCredentialSentence() {
        let render = strip([
            input(name: "Work", session: 50, attention: .claudeAI),
            input(name: "Personal", session: 50)
        ])
        let aiText = StatusBarUIManager.attentionStateText(.claudeAI)
        let lines = render.tooltip.split(separator: "\n").map(String.init)

        XCTAssertEqual(lines.count, 3, "One header line plus two accounts")
        XCTAssertTrue(lines[1].contains(aiText))
        XCTAssertFalse(lines[2].contains(aiText))
    }

    func testTheActiveAccountIsAnnouncedAsActive() {
        let render = strip([
            input(name: "Work", session: 50, isActive: true),
            input(name: "Personal", session: 50)
        ])
        let lines = render.tooltip.split(separator: "\n").map(String.init)

        let activeWording = StatusBarUIManager.profileAccessibilityLabel(
            "Work, \(sessionName()), 50% used, \(weekName()), no usage data",
            isActive: true
        )
        XCTAssertEqual(lines[1], activeWording)
        XCTAssertNotEqual(lines[1], lines[2])
    }

    func testTheTooltipAndTheLabelDescribeTheSameAccounts() {
        let inputs = [
            input(name: "Work", session: 83, week: 20, attention: .claudeCode),
            input(name: "Personal", session: nil),
            input(name: "Spare", session: 4, isActive: true)
        ]
        let render = strip(inputs)

        let tooltipLines = render.tooltip.split(separator: "\n").map(String.init)
        for line in tooltipLines {
            XCTAssertTrue(
                render.accessibilityLabel.contains(line),
                "The hovered and the spoken form must not drift: \(line)"
            )
        }
    }
}
