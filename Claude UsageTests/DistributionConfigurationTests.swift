import Sparkle
import XCTest
@testable import Claude_Usage

final class DistributionConfigurationTests: XCTestCase {
    private var validProductionInfo: [String: Any] {
        [
            "ReveniumUpdateChannel": "production",
            "CFBundleIdentifier": "com.revenium.RevvyTach",
            "SUFeedURL": SparkleUpdateConfiguration.productionFeedURL.absoluteString,
            "SUPublicEDKey": Data(repeating: 7, count: 32).base64EncodedString()
        ]
    }

    func testValidProductionConfigurationIsEnabled() {
        let configuration = SparkleUpdateConfiguration.evaluate(
            infoDictionary: validProductionInfo
        )

        XCTAssertEqual(
            configuration.state,
            .enabled(feedURL: SparkleUpdateConfiguration.productionFeedURL)
        )
    }

    func testDevelopmentBuildCannotEnableProductionFeed() {
        var info = validProductionInfo
        info["ReveniumUpdateChannel"] = "development"

        XCTAssertFalse(
            SparkleUpdateConfiguration.evaluate(infoDictionary: info).isEnabled
        )
    }

    func testExplicitDebugTestingChannelRequiresHTTPSFeedAndKey() {
        var info = validProductionInfo
        info["ReveniumUpdateChannel"] = "testing"
        info["SUFeedURL"] = "https://updates.example.test/appcast.xml"

        XCTAssertTrue(
            SparkleUpdateConfiguration.evaluate(infoDictionary: info).isEnabled
        )

        info["SUFeedURL"] = "http://updates.example.test/appcast.xml"
        XCTAssertFalse(
            SparkleUpdateConfiguration.evaluate(infoDictionary: info).isEnabled
        )
    }

    func testProductionBuildRejectsNonReveniumFeed() {
        var info = validProductionInfo
        info["SUFeedURL"] = "https://example.invalid/appcast.xml"

        XCTAssertFalse(
            SparkleUpdateConfiguration.evaluate(infoDictionary: info).isEnabled
        )
    }

    func testProductionBuildRejectsMissingOrMalformedPublicKey() {
        for publicKey in ["", "not-base64", Data(repeating: 1, count: 31).base64EncodedString()] {
            var info = validProductionInfo
            info["SUPublicEDKey"] = publicKey

            XCTAssertFalse(
                SparkleUpdateConfiguration.evaluate(infoDictionary: info).isEnabled
            )
        }
    }

    func testProductionBuildRejectsChangedBundleIdentity() {
        var info = validProductionInfo
        info["CFBundleIdentifier"] = "io.revenium.RevvyTach"

        XCTAssertFalse(
            SparkleUpdateConfiguration.evaluate(infoDictionary: info).isEnabled
        )
    }

    func testLegacyFeedOverrideIsRemovedBeforeUpdaterConstruction() throws {
        let (defaults, suiteName) = try HostedTestDefaults.defaults(
            "DistributionConfigurationTests"
        )
        HostedTestDefaults.reset(defaults, suiteName: suiteName)
        defer { HostedTestDefaults.finish(defaults, suiteName: suiteName) }
        defaults.set(
            "https://example.invalid/legacy-appcast.xml",
            forKey: SparkleUpdateConfiguration.legacyFeedOverrideDefaultsKey
        )

        SparkleUpdateConfiguration.clearLegacyFeedOverride(in: defaults)

        XCTAssertNil(
            defaults.object(
                forKey: SparkleUpdateConfiguration.legacyFeedOverrideDefaultsKey
            )
        )
    }

    func testUnstartedSparkleControllerIsSafeWithoutFeedOrKey() {
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        XCTAssertFalse(controller.updater.canCheckForUpdates)
    }

    func testUpgradeIdentityRemainsStable() {
        XCTAssertEqual(
            SparkleUpdateConfiguration.productionBundleIdentifier,
            "com.revenium.RevvyTach"
        )
        XCTAssertEqual(
            Constants.appGroupIdentifier,
            "group.com.claudeusagetracker.shared"
        )
    }
}
