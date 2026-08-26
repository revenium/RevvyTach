//
//  GitHubServiceContributorCacheTests.swift
//  Claude UsageTests
//
//  Created by Claude Code on 2026-08-14.
//

import XCTest

@testable import Claude_Usage

final class GitHubServiceContributorCacheTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let (testDefaults, testSuiteName) = try HostedTestDefaults.defaults(
            "GitHubServiceContributorCacheTests"
        )
        suiteName = testSuiteName
        defaults = testDefaults
        HostedTestDefaults.reset(defaults, suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        HostedTestDefaults.finish(defaults, suiteName: suiteName)
        defaults = nil
        suiteName = nil
        try super.tearDownWithError()
    }

    private func contributor(_ login: String) -> Contributor {
        Contributor(
            login: login,
            id: abs(login.hashValue % 100_000),
            avatarUrl: "https://example.test/\(login).png",
            htmlUrl: "https://example.test/\(login)",
            contributions: 1
        )
    }

    private enum StubError: Error { case rateLimited }

    func testSuccessfulFetchStoresCacheAndFreshCacheSkipsRemote() async throws {
        var remoteCalls = 0
        let service = GitHubService(
            defaults: defaults,
            remoteFetch: {
                remoteCalls += 1
                return [self.contributor("alice")]
            }
        )

        let first = try await service.fetchContributors()
        XCTAssertEqual(first.map(\.login), ["alice"])
        XCTAssertEqual(remoteCalls, 1)

        // Second call inside the freshness window never touches the remote.
        let second = try await service.fetchContributors()
        XCTAssertEqual(second.map(\.login), ["alice"])
        XCTAssertEqual(remoteCalls, 1)
    }

    func testRemoteFailureFallsBackToStaleCache() async throws {
        // Populate the cache, timestamped two days ago so it is stale.
        let twoDaysAgo = Date(timeIntervalSinceNow: -2 * 24 * 60 * 60)
        let seeder = GitHubService(
            defaults: defaults,
            remoteFetch: { [self.contributor("bob")] },
            now: { twoDaysAgo }
        )
        _ = try await seeder.fetchContributors()

        var remoteCalls = 0
        let service = GitHubService(
            defaults: defaults,
            remoteFetch: {
                remoteCalls += 1
                throw StubError.rateLimited
            }
        )

        // Stale cache means the remote IS consulted, and its failure falls
        // back to the stale list instead of surfacing an error.
        let result = try await service.fetchContributors()
        XCTAssertEqual(result.map(\.login), ["bob"])
        XCTAssertEqual(remoteCalls, 1)
    }

    func testRemoteFailureWithoutCacheThrows() async {
        let service = GitHubService(
            defaults: defaults,
            remoteFetch: { throw StubError.rateLimited }
        )

        do {
            _ = try await service.fetchContributors()
            XCTFail("expected the remote error to surface")
        } catch {
            XCTAssertTrue(error is StubError)
        }
    }

    func testRemoteSuccessRefreshesStaleCache() async throws {
        let twoDaysAgo = Date(timeIntervalSinceNow: -2 * 24 * 60 * 60)
        let seeder = GitHubService(
            defaults: defaults,
            remoteFetch: { [self.contributor("old")] },
            now: { twoDaysAgo }
        )
        _ = try await seeder.fetchContributors()

        let service = GitHubService(
            defaults: defaults,
            remoteFetch: { [self.contributor("new")] }
        )

        let result = try await service.fetchContributors()
        XCTAssertEqual(result.map(\.login), ["new"])

        // The refreshed cache now serves without the remote.
        var remoteCalls = 0
        let reader = GitHubService(
            defaults: defaults,
            remoteFetch: {
                remoteCalls += 1
                return []
            }
        )
        let cached = try await reader.fetchContributors()
        XCTAssertEqual(cached.map(\.login), ["new"])
        XCTAssertEqual(remoteCalls, 0)
    }
}
