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

    private func input(
        name: String,
        sessionDisplay: Double?,
        showRemaining: Bool = false,
        isActive: Bool = false,
        attention: MenuBarAttentionSignal.Credential? = nil
    ) -> MenuBarIconRenderer.HealthStripProfileInput {
        MenuBarIconRenderer.HealthStripProfileInput(
            profileID: UUID(),
            profileName: name,
            sessionDisplay: sessionDisplay,
            status: .safe,
            showRemaining: showRemaining,
            isActive: isActive,
            attention: attention,
            numbersImage: nil
        )
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
            names.map { input(name: $0, sessionDisplay: 40) }
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
            (0..<3).map { input(name: "P\($0)", sessionDisplay: 10) }
        )

        XCTAssertTrue(render.tooltip.contains("3"))
        XCTAssertTrue(render.accessibilityLabel.contains("3"))
    }

    func testTheLabelStatesEachAccountsSessionValue() {
        let render = strip([
            input(name: "Work", sessionDisplay: 83),
            input(name: "Personal", sessionDisplay: 12)
        ])

        XCTAssertTrue(render.accessibilityLabel.contains("83%"))
        XCTAssertTrue(render.accessibilityLabel.contains("12%"))
        XCTAssertTrue(
            render.accessibilityLabel.contains(
                StatusBarUIManager.usageModeText(showRemaining: false)
            )
        )
    }

    func testRemainingModeIsSaidInTheRemainingVocabulary() {
        let render = strip([
            input(name: "Work", sessionDisplay: 80, showRemaining: true)
        ])

        XCTAssertTrue(
            render.accessibilityLabel.contains(
                StatusBarUIManager.usageModeText(showRemaining: true)
            ),
            "A remaining figure must not be spoken as a used one"
        )
    }

    func testAnAccountWithNoReadingIsSaidInWordsNotAsZeroPercent() {
        let render = strip([
            input(name: "Work", sessionDisplay: nil)
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
            input(name: "Work", sessionDisplay: 50, attention: .claudeCode)
        ])
        let claudeAI = strip([
            input(name: "Work", sessionDisplay: 50, attention: .claudeAI)
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
            input(name: "Work", sessionDisplay: 50, attention: .claudeAI),
            input(name: "Personal", sessionDisplay: 50)
        ])
        let aiText = StatusBarUIManager.attentionStateText(.claudeAI)
        let lines = render.tooltip.split(separator: "\n").map(String.init)

        XCTAssertEqual(lines.count, 3, "One header line plus two accounts")
        XCTAssertTrue(lines[1].contains(aiText))
        XCTAssertFalse(lines[2].contains(aiText))
    }

    func testTheActiveAccountIsAnnouncedAsActive() {
        let render = strip([
            input(name: "Work", sessionDisplay: 50, isActive: true),
            input(name: "Personal", sessionDisplay: 50)
        ])
        let lines = render.tooltip.split(separator: "\n").map(String.init)

        let activeWording = StatusBarUIManager.profileAccessibilityLabel(
            "Work, 50% used",
            isActive: true
        )
        XCTAssertEqual(lines[1], activeWording)
        XCTAssertNotEqual(lines[1], lines[2])
    }

    func testTheTooltipAndTheLabelDescribeTheSameAccounts() {
        let inputs = [
            input(name: "Work", sessionDisplay: 83, attention: .claudeCode),
            input(name: "Personal", sessionDisplay: nil),
            input(name: "Spare", sessionDisplay: 4, isActive: true)
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
