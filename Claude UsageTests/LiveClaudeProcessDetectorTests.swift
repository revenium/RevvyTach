import XCTest
@testable import Claude_Usage

/// A process list that is staged rather than started.
///
/// Not `private`: `ClaudeCodeSyncServiceTests` stages the same processes to
/// exercise the write chokepoint, and two copies of this would let the two
/// suites disagree about what "a running claude" looks like.
struct StubRunningProcessSource: RunningProcessSource {
    var processes: [RunningProcessSnapshot] = []
    var failure: Error?

    func currentProcesses() throws -> [RunningProcessSnapshot] {
        if let failure { throw failure }
        return processes
    }
}

extension RunningProcessSnapshot {
    /// A `claude` pointed at one account's configuration directory.
    static func claude(
        pid: pid_t = 4242,
        configurationDirectory: String?,
        executablePath: String = "/opt/homebrew/bin/claude"
    ) -> RunningProcessSnapshot {
        var environment = ["HOME": NSHomeDirectory()]
        if let configurationDirectory {
            environment["CLAUDE_CONFIG_DIR"] = configurationDirectory
        }
        return RunningProcessSnapshot(
            processIdentifier: pid,
            executablePath: executablePath,
            arguments: [executablePath],
            environment: environment
        )
    }
}

extension RunningProcessSnapshot {
    /// Anything that is not Claude Code but inherited the variable — which,
    /// on a real machine, is most of what carries it: RevvyTach sets it
    /// tmux-wide, so every pane and everything it spawns has it.
    static func inheritedTheVariable(
        pid: pid_t = 5150,
        configurationDirectory: String,
        executablePath: String = "/opt/homebrew/bin/node"
    ) -> RunningProcessSnapshot {
        RunningProcessSnapshot(
            processIdentifier: pid,
            executablePath: executablePath,
            arguments: [executablePath, "server.js"],
            environment: ["CLAUDE_CONFIG_DIR": configurationDirectory]
        )
    }

    /// An npm install: a shebang script, so the executable and `argv[0]` are
    /// the interpreter and the identity is in `argv[1]`.
    static func npmClaude(
        pid: pid_t = 6161,
        configurationDirectory: String?
    ) -> RunningProcessSnapshot {
        var environment: [String: String] = [:]
        if let configurationDirectory {
            environment["CLAUDE_CONFIG_DIR"] = configurationDirectory
        }
        return RunningProcessSnapshot(
            processIdentifier: pid,
            executablePath: "/opt/homebrew/Cellar/node/24.0.0/bin/node",
            arguments: [
                "node",
                "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js",
                "--continue"
            ],
            environment: environment
        )
    }
}

extension LiveClaudeProcessDetector {
    /// A detector that will never report anything as live. The default for
    /// tests about something other than liveness.
    static func stubbedIdle(
        defaultConfigurationDirectory: String = "/tmp/no-such-claude-home"
    ) -> LiveClaudeProcessDetector {
        LiveClaudeProcessDetector(
            source: StubRunningProcessSource(),
            defaultConfigurationDirectory: defaultConfigurationDirectory,
            log: { _ in }
        )
    }
}

/// The guard the whole token-race fix rests on: before spending an account's
/// refresh token, establish that no `claude` process is relying on it.
///
/// `HostedAppTestCase`, and every detector retained for the process
/// lifetime, for the reason that type documents: the app target uses
/// main-actor default isolation, and releasing one of its actor-isolated
/// objects from the XCTest thunk trips a runtime allocator bug that aborts
/// the host.
final class LiveClaudeProcessDetectorTests: HostedAppTestCase {
    private let account = "/Users/tester/.claude-accounts/work"
    private let defaultHome = "/Users/tester/.claude"

    @MainActor
    private func detector(
        _ processes: [RunningProcessSnapshot],
        failure: Error? = nil,
        cacheDuration: TimeInterval = 5,
        now: @escaping () -> Date = Date.init
    ) -> LiveClaudeProcessDetector {
        retain(LiveClaudeProcessDetector(
            source: StubRunningProcessSource(
                processes: processes,
                failure: failure
            ),
            cacheDuration: cacheDuration,
            now: now,
            defaultConfigurationDirectory: defaultHome,
            log: { _ in }
        ))
    }

    // MARK: - The environment pointer

    @MainActor
    func testAProcessPointedAtTheAccountIsLive() {
        let subject = detector([
            .claude(configurationDirectory: account)
        ])
        XCTAssertTrue(subject.isLive(configurationDirectory: account))
    }

    @MainActor
    func testAProcessPointedSomewhereElseIsNotLiveForThisAccount() {
        let subject = detector([
            .claude(
                configurationDirectory: "/Users/tester/.claude-accounts/personal"
            )
        ])
        XCTAssertFalse(subject.isLive(configurationDirectory: account))
    }

    @MainActor
    func testNoProcessesAtAllMeansIdle() {
        XCTAssertFalse(detector([]).isLive(configurationDirectory: account))
    }

    /// A trailing slash is the same directory. One side of this comparison is
    /// whatever the person typed in a shell; the other is a path this app
    /// built.
    @MainActor
    func testATrailingSlashIsTheSameDirectory() {
        let subject = detector([
            .claude(configurationDirectory: account + "/")
        ])
        XCTAssertTrue(subject.isLive(configurationDirectory: account))
        XCTAssertTrue(subject.isLive(configurationDirectory: account + "/"))
    }

    /// `CLAUDE_CONFIG_DIR=~/.claude-accounts/work` reaches the process
    /// unexpanded when it is set without shell expansion.
    @MainActor
    func testATildeIsExpandedBeforeComparing() {
        let expanded = ("~/.claude-accounts/work" as NSString)
            .expandingTildeInPath
        let subject = detector([
            .claude(configurationDirectory: "~/.claude-accounts/work")
        ])
        XCTAssertTrue(subject.isLive(configurationDirectory: expanded))
    }

    /// Claude Code normalises the path to NFC before hashing it into its
    /// Keychain service name, so NFC is the spelling both programs agree on.
    /// A path read off the filesystem arrives decomposed.
    @MainActor
    func testDecomposedAndComposedUnicodeAreTheSameDirectory() {
        let composed = "/Users/tester/.claude-accounts/café"
        let decomposed = composed.decomposedStringWithCanonicalMapping
        // Swift's own `==` already treats these as one string; the bytes are
        // what differ, and the bytes are what a hashed Keychain service name
        // is built from.
        XCTAssertNotEqual(Array(composed.utf8), Array(decomposed.utf8))
        let subject = detector([
            .claude(configurationDirectory: decomposed)
        ])
        XCTAssertTrue(subject.isLive(configurationDirectory: composed))
    }

    /// The variable is not evidence of a `claude`. RevvyTach itself runs
    /// `tmux set-environment -g CLAUDE_CONFIG_DIR`, so every pane opened
    /// afterwards and everything it spawns inherits it. Measured across seven
    /// linked accounts on the maintainer's machine, three carried the
    /// variable on node, python or a language server with no `claude`
    /// anywhere near them — and those three would have been refused a refresh
    /// forever, then shown as asleep forever.
    @MainActor
    func testAnUnrelatedProcessCarryingTheVariableIsNotLive() {
        let subject = detector([
            .inheritedTheVariable(configurationDirectory: account)
        ])
        XCTAssertFalse(subject.isLive(configurationDirectory: account))
    }

    /// The same directory, with a real `claude` among the noise.
    @MainActor
    func testAClaudeAmongInheritingProcessesIsStillLive() {
        let subject = detector([
            .inheritedTheVariable(configurationDirectory: account),
            .inheritedTheVariable(
                pid: 5151,
                configurationDirectory: account,
                executablePath: "/usr/bin/python3"
            ),
            .claude(configurationDirectory: account)
        ])
        XCTAssertTrue(subject.isLive(configurationDirectory: account))
    }

    /// An npm install is `node cli.js`: the executable and `argv[0]` are the
    /// interpreter, and the only thing that says Claude Code is `argv[1]`.
    /// Missing it spent the token of every account on that class of install.
    @MainActor
    func testAnNpmInstalledClaudeIsRecognised() {
        XCTAssertTrue(
            detector([.npmClaude(configurationDirectory: account)])
                .isLive(configurationDirectory: account)
        )
        XCTAssertTrue(
            detector([.npmClaude(configurationDirectory: nil)])
                .isLive(configurationDirectory: defaultHome)
        )
    }

    /// An unrelated `cli.js` is not Claude Code.
    @MainActor
    func testAnUnrelatedNodeScriptIsNotClaudeCode() {
        let subject = detector([
            RunningProcessSnapshot(
                processIdentifier: 7,
                executablePath: "/usr/local/bin/node",
                arguments: ["node", "/opt/tools/vendor/cli.js"],
                environment: ["CLAUDE_CONFIG_DIR": account]
            )
        ])
        XCTAssertFalse(subject.isLive(configurationDirectory: account))
    }

    // MARK: - The default account

    /// A `claude` started with no `CLAUDE_CONFIG_DIR` is using `~/.claude`,
    /// and cannot be matched by the environment rule at all.
    @MainActor
    func testAPlainClaudeIsLiveForTheDefaultAccount() {
        let subject = detector([
            .claude(configurationDirectory: nil)
        ])
        XCTAssertTrue(subject.isLive(configurationDirectory: defaultHome))
    }

    /// The native installer runs a versioned binary whose own name is the
    /// version string.
    @MainActor
    func testTheVersionedInstallPathCountsAsClaudeCode() {
        let subject = detector([
            .claude(
                configurationDirectory: nil,
                executablePath:
                    "/Users/tester/.local/share/claude/versions/2.1.270"
            )
        ])
        XCTAssertTrue(subject.isLive(configurationDirectory: defaultHome))
    }

    /// The default-account rule must not make every process a match.
    @MainActor
    func testAnUnrelatedProcessIsNotTheDefaultAccount() {
        let subject = detector([
            RunningProcessSnapshot(
                processIdentifier: 9,
                executablePath: "/usr/bin/ssh",
                arguments: ["ssh", "example.com"],
                environment: [:]
            )
        ])
        XCTAssertFalse(subject.isLive(configurationDirectory: defaultHome))
    }

    /// A plain `claude` says nothing about a linked account — it is using
    /// `~/.claude`, and refusing to refresh every other account because one
    /// default-account session exists would stop the app working at all.
    @MainActor
    func testAPlainClaudeDoesNotMakeALinkedAccountLive() {
        let subject = detector([
            .claude(configurationDirectory: nil)
        ])
        XCTAssertFalse(subject.isLive(configurationDirectory: account))
    }

    /// A `claude` that names `~/.claude` explicitly is the default account
    /// just as much as one that names nothing.
    @MainActor
    func testAnExplicitPointerAtTheDefaultHomeIsLive() {
        let subject = detector([
            .claude(configurationDirectory: defaultHome)
        ])
        XCTAssertTrue(subject.isLive(configurationDirectory: defaultHome))
    }

    // MARK: - Fail closed

    /// The whole point. An answer we cannot produce must never read as "go
    /// ahead and spend that refresh token": being wrong in that direction
    /// costs someone a working sign-in, and being wrong the other way costs a
    /// delayed percentage.
    @MainActor
    func testAFailedScanReportsLive() {
        let subject = detector(
            [],
            failure: RunningProcessSourceError.enumerationFailed("denied")
        )
        XCTAssertTrue(subject.isLive(configurationDirectory: account))
        XCTAssertTrue(subject.isLive(configurationDirectory: defaultHome))
    }

    // MARK: - Caching

    @MainActor
    func testTheScanIsCachedWithinTheCacheWindow() throws {
        final class CountingSource: RunningProcessSource {
            var calls = 0
            func currentProcesses() throws -> [RunningProcessSnapshot] {
                calls += 1
                return []
            }
        }
        let source = CountingSource()
        var clock = Date(timeIntervalSince1970: 1_000)
        let subject = retain(
            LiveClaudeProcessDetector(
                source: source,
                cacheDuration: 5,
                now: { clock },
                defaultConfigurationDirectory: defaultHome,
                log: { _ in }
            )
        )
        _ = retain(source)

        _ = subject.isLive(configurationDirectory: account)
        _ = subject.isLive(configurationDirectory: account)
        clock = clock.addingTimeInterval(4)
        _ = subject.isLive(configurationDirectory: account)
        XCTAssertEqual(source.calls, 1, "Within 5s the scan must be reused")

        clock = clock.addingTimeInterval(2)
        _ = subject.isLive(configurationDirectory: account)
        XCTAssertEqual(source.calls, 2, "Past 5s the scan must be retaken")
    }

    // MARK: - Parsing what the kernel actually hands back

    /// `KERN_PROCARGS2` has no header describing it: a 32-bit `argc`, the
    /// executable path, padding NULs, `argc` argv strings, then the
    /// environment. Getting the padding step wrong silently produces an
    /// empty environment, which would make every account read as idle.
    @MainActor
    func testTheKernelArgumentBlobParsesIntoArgvAndEnvironment() throws {
        var blob: [UInt8] = []
        var argumentCount: Int32 = 2
        withUnsafeBytes(of: &argumentCount) { blob.append(contentsOf: $0) }

        func append(_ string: String) {
            blob.append(contentsOf: Array(string.utf8))
            blob.append(0)
        }

        append("/opt/homebrew/bin/claude")
        // The kernel pads to an alignment boundary before argv[0].
        blob.append(contentsOf: [0, 0, 0])
        append("claude")
        append("--continue")
        append("CLAUDE_CONFIG_DIR=/Users/tester/.claude-accounts/work")
        append("PATH=/usr/bin")

        let snapshot = try XCTUnwrap(
            SysctlRunningProcessSource.parse(argumentBlob: blob, pid: 77)
        )
        XCTAssertEqual(snapshot.processIdentifier, 77)
        XCTAssertEqual(snapshot.executablePath, "/opt/homebrew/bin/claude")
        XCTAssertEqual(snapshot.arguments, ["claude", "--continue"])
        XCTAssertEqual(
            snapshot.environment["CLAUDE_CONFIG_DIR"],
            "/Users/tester/.claude-accounts/work"
        )
        XCTAssertEqual(snapshot.environment["PATH"], "/usr/bin")
    }

    /// The real machine, not a fixture. This asserts nothing about what is
    /// running — it asserts that the enumeration works at all under the app's
    /// entitlements, because a source that always threw would make the
    /// detector report every account as live forever and nothing would ever
    /// refresh again.
    @MainActor
    func testTheRealProcessSourceCanEnumerateThisProcess() throws {
        let processes = try SysctlRunningProcessSource().currentProcesses()
        XCTAssertFalse(processes.isEmpty)
        let ourselves = processes.first {
            $0.processIdentifier == ProcessInfo.processInfo.processIdentifier
        }
        let us = try XCTUnwrap(
            ourselves,
            "The scan must at least find the process doing the scanning"
        )
        XCTAssertFalse(us.executablePath.isEmpty)
        XCTAssertFalse(
            us.environment.isEmpty,
            "An empty environment means the padding step is wrong, and every "
            + "account would read as idle"
        )
    }
}
