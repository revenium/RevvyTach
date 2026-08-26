//
//  StatusItemPositionSanitizerTests.swift
//  Claude UsageTests
//
//  Created by Claude Code on 2026-08-07.
//

import Cocoa
import XCTest
@testable import Claude_Usage

final class StatusItemPositionSanitizerTests: XCTestCase {
    private let keyPrefix = StatusItemPositionSanitizer.keyPrefix

    // MARK: - Pure logic: staleKeys(in:screenFrames:)

    func testInBoundsPositionIsKept() {
        let saved: [String: Any] = [
            keyPrefix + "claude-usage-tracker.profile.a": NSNumber(value: 500.0)
        ]
        let stale = StatusItemPositionSanitizer.staleKeys(
            in: saved,
            screenFrames: [CGRect(x: 0, y: 0, width: 1800, height: 1000)]
        )
        XCTAssertTrue(stale.isEmpty)
    }

    func testOutOfBoundsPositionIsRemoved() {
        // The exact shape reported on the real user machine: six items
        // stranded at x ~ 6633-6923 and one at 11728 on a 1800pt-wide screen.
        let saved: [String: Any] = [
            keyPrefix + "claude-usage-tracker.profile.a": NSNumber(value: 6633.0),
            keyPrefix + "claude-usage-tracker.profile.b": NSNumber(value: 6923.0),
            keyPrefix + "claude-usage-tracker.profile.c": NSNumber(value: 11728.0),
            keyPrefix + "claude-usage-tracker.profile.d": NSNumber(value: 500.0)
        ]
        let stale = StatusItemPositionSanitizer.staleKeys(
            in: saved,
            screenFrames: [CGRect(x: 0, y: 0, width: 1800, height: 1000)]
        )
        XCTAssertEqual(
            Set(stale),
            Set([
                keyPrefix + "claude-usage-tracker.profile.a",
                keyPrefix + "claude-usage-tracker.profile.b",
                keyPrefix + "claude-usage-tracker.profile.c"
            ])
        )
    }

    func testMultiScreenUnionIsRespected() {
        // A position that is off the primary screen but on a second,
        // differently-positioned screen must be kept, not reset.
        let saved: [String: Any] = [
            keyPrefix + "claude-usage-tracker.profile.a": NSNumber(value: 2500.0)
        ]
        let screenFrames = [
            CGRect(x: 0, y: 0, width: 1800, height: 1000),
            CGRect(x: 1800, y: 0, width: 1800, height: 1000)
        ]
        let stale = StatusItemPositionSanitizer.staleKeys(
            in: saved,
            screenFrames: screenFrames
        )
        XCTAssertTrue(
            stale.isEmpty,
            "A position inside the second screen's frame must be kept"
        )

        let outOfUnion: [String: Any] = [
            keyPrefix + "claude-usage-tracker.profile.a": NSNumber(value: 5000.0)
        ]
        let staleOutside = StatusItemPositionSanitizer.staleKeys(
            in: outOfUnion,
            screenFrames: screenFrames
        )
        XCTAssertEqual(
            staleOutside,
            [keyPrefix + "claude-usage-tracker.profile.a"]
        )
    }

    func testNoScreensIsSafeAndResetsNothing() {
        let saved: [String: Any] = [
            keyPrefix + "claude-usage-tracker.profile.a": NSNumber(value: 999_999.0)
        ]
        let stale = StatusItemPositionSanitizer.staleKeys(
            in: saved,
            screenFrames: []
        )
        XCTAssertTrue(
            stale.isEmpty,
            "With no screens attached we cannot tell off-screen from "
                + "on-screen; must never wipe positions"
        )
    }

    func testNonPositionKeysAreIgnored() {
        let saved: [String: Any] = [
            "SomeOtherAppSetting": NSNumber(value: 6633.0),
            keyPrefix + "claude-usage-tracker.profile.a": "not-a-number"
        ]
        let stale = StatusItemPositionSanitizer.staleKeys(
            in: saved,
            screenFrames: [CGRect(x: 0, y: 0, width: 1800, height: 1000)]
        )
        XCTAssertTrue(stale.isEmpty)
    }

    // MARK: - sanitize(defaults:screens:) integration

    func testSanitizeRemovesOnlyStaleKeysFromDefaults() throws {
        let (defaults, suiteName) = try HostedTestDefaults.defaults(
            "StatusItemPositionSanitizerTests"
        )
        HostedTestDefaults.reset(defaults, suiteName: suiteName)
        addTeardownBlock { HostedTestDefaults.finish(defaults, suiteName: suiteName) }

        let staleKey = keyPrefix + "claude-usage-tracker.profile.stale"
        let keptKey = keyPrefix + "claude-usage-tracker.profile.kept"
        defaults.set(6633.0, forKey: staleKey)
        defaults.set(500.0, forKey: keptKey)

        StatusItemPositionSanitizer.sanitize(
            defaults: defaults,
            screens: [] // real NSScreen instances aren't needed for this check
        )
        // No screens supplied: nothing should be removed regardless of value.
        XCTAssertEqual(defaults.object(forKey: staleKey) as? Double, 6633.0)
        XCTAssertEqual(defaults.object(forKey: keptKey) as? Double, 500.0)

        // Now sanitize against a real 1800pt-wide-equivalent screen frame.
        // We can't construct a fake NSScreen, so exercise the real
        // screens the test host has; combined with an explicit synthetic
        // fixture in the pure-logic tests above, this still proves the
        // wiring end to end without depending on a specific display size.
        StatusItemPositionSanitizer.sanitize(
            defaults: defaults,
            screens: NSScreen.screens
        )
        let union = NSScreen.screens.reduce(
            into: CGRect?.none
        ) { result, screen in
            result = result?.union(screen.frame) ?? screen.frame
        }
        if let union, !union.contains(CGPoint(x: 6633, y: union.minY)) {
            XCTAssertNil(
                defaults.object(forKey: staleKey),
                "Position outside the real test host's screen union must "
                    + "be removed"
            )
        }
        XCTAssertEqual(
            defaults.object(forKey: keptKey) as? Double,
            500.0,
            "An in-bounds position must never be touched"
        )
    }

    /// Displays need not be contiguous in the global coordinate space. A
    /// position in the gap between two monitors is on neither of them, so it
    /// is exactly as unreachable as one past the far edge — the case a
    /// single `minX...maxX` span silently reported as fine, leaving the item
    /// invisible while claiming it had been checked.
    func testPositionInGapBetweenNonContiguousDisplaysIsStale() {
        let screens = [
            CGRect(x: 0, y: 0, width: 1800, height: 1125),
            CGRect(x: 3000, y: 0, width: 1500, height: 1000)
        ]
        let saved: [String: Any] = [
            "NSStatusItem Preferred Position onLeftDisplay": 900.0,
            "NSStatusItem Preferred Position inTheGap": 2400.0,
            "NSStatusItem Preferred Position onRightDisplay": 3600.0,
            "NSStatusItem Preferred Position pastEverything": 11728.0
        ]

        let stale = StatusItemPositionSanitizer.staleKeys(
            in: saved,
            screenFrames: screens
        )

        XCTAssertEqual(
            stale,
            [
                "NSStatusItem Preferred Position inTheGap",
                "NSStatusItem Preferred Position pastEverything"
            ]
        )
    }
}
