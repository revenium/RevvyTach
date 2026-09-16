//
//  LiveClaudeProcessDetector.swift
//  Claude Usage
//
//  Answers one question: is a `claude` process right now relying on the
//  login of the account we are about to touch?
//

import Darwin
import Foundation

/// One running process, reduced to the three things that say which Claude
/// Code account it is using.
struct RunningProcessSnapshot: Equatable, Sendable {
    let processIdentifier: pid_t
    /// The executable path as the kernel reports it, e.g.
    /// `/Users/me/.local/share/claude/versions/2.1.270`.
    let executablePath: String
    /// `argv`, including `argv[0]`.
    let arguments: [String]
    let environment: [String: String]

    init(
        processIdentifier: pid_t,
        executablePath: String,
        arguments: [String],
        environment: [String: String]
    ) {
        self.processIdentifier = processIdentifier
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
    }
}

/// Where the detector gets its process list.
///
/// A protocol rather than a direct `sysctl` call so the matching rules can be
/// tested against processes that are staged rather than started. A test that
/// has to launch a real `claude` to check a string comparison is a test
/// nobody can run in CI.
protocol RunningProcessSource {
    func currentProcesses() throws -> [RunningProcessSnapshot]
}

enum RunningProcessSourceError: Error, Equatable {
    /// The kernel would not give us a process list at all.
    case enumerationFailed(String)
}

/// The production source: `proc_listallpids` for the pid list, then
/// `sysctl KERN_PROCARGS2` per pid for its argv and environment.
///
/// Deliberately not `ps`. `ps -E` on current macOS will not show another
/// process's environment without extra privilege, and shelling out once per
/// refresh tick to parse a text table is both slower and less exact.
/// `KERN_PROCARGS2` works for a process owned by the same user with no
/// entitlement, and this app is not sandboxed.
struct SysctlRunningProcessSource: RunningProcessSource {
    /// Only processes owned by this uid are considered. Another user's
    /// `claude` cannot be reading our account's Keychain item.
    private let userIdentifier: uid_t

    init(userIdentifier: uid_t = getuid()) {
        self.userIdentifier = userIdentifier
    }

    func currentProcesses() throws -> [RunningProcessSnapshot] {
        let pids = try allProcessIdentifiers()
        var snapshots: [RunningProcessSnapshot] = []
        snapshots.reserveCapacity(16)
        let maximumArgumentSize = Self.argumentAreaSize()

        for pid in pids where pid > 0 {
            guard ownedByCurrentUser(pid) else { continue }
            // A per-process read that fails is skipped rather than fatal:
            // processes exit between the pid list and this call all the time,
            // and a race with an exiting process must not be reported as the
            // whole scan failing.
            guard let snapshot = Self.snapshot(
                pid: pid,
                maximumArgumentSize: maximumArgumentSize
            ) else { continue }
            snapshots.append(snapshot)
        }
        return snapshots
    }

    private func allProcessIdentifiers() throws -> [pid_t] {
        let byteCount = proc_listallpids(nil, 0)
        guard byteCount > 0 else {
            throw RunningProcessSourceError.enumerationFailed(
                "proc_listallpids reported no processes (errno \(errno))"
            )
        }
        // Headroom: processes can start between the sizing call and the read.
        let capacity = Int(byteCount) / MemoryLayout<pid_t>.size + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let written = pids.withUnsafeMutableBufferPointer { buffer -> Int32 in
            proc_listallpids(
                buffer.baseAddress,
                Int32(buffer.count * MemoryLayout<pid_t>.size)
            )
        }
        guard written > 0 else {
            throw RunningProcessSourceError.enumerationFailed(
                "proc_listallpids returned \(written) (errno \(errno))"
            )
        }
        // `proc_listallpids` returns BYTES written, not a count of pids.
        // The surplus entries were the zero-filled tail and were skipped by
        // the `pid > 0` filter, so this was harmless — but it was also wrong,
        // and a non-zero byte pattern in that tail would have been read as a
        // process identifier.
        return Array(pids.prefix(Int(written) / MemoryLayout<pid_t>.size))
    }

    private func ownedByCurrentUser(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let read = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard read == size else { return false }
        return info.pbi_uid == userIdentifier
    }

    /// `kern.argmax` — the largest argument area the kernel will hand back.
    private static func argumentAreaSize() -> Int {
        var name: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var value: Int32 = 0
        var length = MemoryLayout<Int32>.size
        guard sysctl(&name, 2, &value, &length, nil, 0) == 0, value > 0 else {
            return 256 * 1024
        }
        return Int(value)
    }

    /// Parses one process's `KERN_PROCARGS2` blob.
    ///
    /// The layout, which is not in any header: a 32-bit `argc`, then the
    /// executable path as a NUL-terminated string, then a run of padding
    /// NULs, then `argc` NUL-terminated argv strings, then the environment
    /// as NUL-terminated `KEY=VALUE` strings until the blob ends.
    static func snapshot(
        pid: pid_t,
        maximumArgumentSize: Int
    ) -> RunningProcessSnapshot? {
        var name: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var buffer = [UInt8](repeating: 0, count: maximumArgumentSize)
        var length = buffer.count
        let status = buffer.withUnsafeMutableBytes { raw -> Int32 in
            sysctl(&name, 3, raw.baseAddress, &length, nil, 0)
        }
        guard status == 0, length > MemoryLayout<Int32>.size else { return nil }
        buffer.removeSubrange(length..<buffer.count)
        return parse(argumentBlob: buffer, pid: pid)
    }

    static func parse(
        argumentBlob blob: [UInt8],
        pid: pid_t
    ) -> RunningProcessSnapshot? {
        let headerSize = MemoryLayout<Int32>.size
        guard blob.count > headerSize else { return nil }
        var argumentCount: Int32 = 0
        withUnsafeMutableBytes(of: &argumentCount) { destination in
            for index in 0..<headerSize {
                destination[index] = blob[index]
            }
        }
        guard argumentCount >= 0 else { return nil }

        var index = headerSize

        func readCString() -> String? {
            guard index < blob.count else { return nil }
            let start = index
            while index < blob.count, blob[index] != 0 { index += 1 }
            let bytes = Array(blob[start..<index])
            // Step past the terminator itself.
            if index < blob.count { index += 1 }
            return String(decoding: bytes, as: UTF8.self)
        }

        guard let executablePath = readCString() else { return nil }
        // The padding between the executable path and argv[0].
        while index < blob.count, blob[index] == 0 { index += 1 }

        var arguments: [String] = []
        for _ in 0..<Int(argumentCount) {
            guard index < blob.count, let argument = readCString() else { break }
            arguments.append(argument)
        }

        var environment: [String: String] = [:]
        while index < blob.count {
            guard let entry = readCString(), !entry.isEmpty else { continue }
            guard let separator = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[entry.startIndex..<separator])
            let value = String(entry[entry.index(after: separator)...])
            environment[key] = value
        }

        return RunningProcessSnapshot(
            processIdentifier: pid,
            executablePath: executablePath,
            arguments: arguments,
            environment: environment
        )
    }
}

/// Whether a `claude` process is currently relying on one account's login.
///
/// This is the guard that makes the rest of the fix possible. Anthropic
/// rotates a refresh token on every use, so spending one for an account a
/// `claude` process is holding in memory leaves that process with a token the
/// server has already retired — and the next thing the person sees is
/// "OAuth session expired and could not be refreshed" on a login they never
/// signed out of.
///
/// Every uncertainty resolves to "live". Refusing to touch an account that
/// turns out to be idle costs a delayed number on a menu bar; touching one
/// that turns out to be live costs a working sign-in.
final class LiveClaudeProcessDetector {
    /// The environment variable a `claude` process carries when it has been
    /// pointed at a linked account's configuration directory.
    static let configurationDirectoryVariable = "CLAUDE_CONFIG_DIR"

    private let source: RunningProcessSource
    private let cacheDuration: TimeInterval
    private let now: () -> Date
    private let defaultConfigurationDirectory: String
    private let log: (String) -> Void

    /// Guards the two cached fields below.
    ///
    /// This detector is one shared object reached from two independent
    /// execution contexts at once: the SwiftUI view body asks it on the main
    /// actor while `UsageRefreshEngine` asks it from a task group refreshing
    /// several profiles concurrently. Without this, two of those can write
    /// `cachedResult` at the same moment, which is a data race on
    /// reference-counted storage rather than merely a stale answer.
    private let cacheMutex = NSLock()
    private var cachedResult: Result<[RunningProcessSnapshot], Error>?
    private var cachedAt: Date?

    /// - Parameters:
    ///   - source: where the process list comes from. Injected so the
    ///     matching rules can be tested without starting a `claude`.
    ///   - cacheDuration: at most this long between scans. Five seconds is
    ///     Claude Code's own order of magnitude for "recently enough", and a
    ///     scan on every 30-second refresh tick per profile is otherwise
    ///     several full process sweeps a minute.
    ///   - defaultConfigurationDirectory: what "no account name" means —
    ///     `~/.claude` in production.
    init(
        source: RunningProcessSource = SysctlRunningProcessSource(),
        cacheDuration: TimeInterval = 5,
        now: @escaping () -> Date = Date.init,
        defaultConfigurationDirectory: String
            = Constants.ClaudePaths.claudeDirectory.path,
        log: @escaping (String) -> Void = { LoggingService.shared.logDebug($0) }
    ) {
        self.source = source
        self.cacheDuration = cacheDuration
        self.now = now
        self.defaultConfigurationDirectory = defaultConfigurationDirectory
        self.log = log
    }

    /// Whether some `claude` process is using this configuration directory.
    ///
    /// - Parameter configurationDirectory: the account's directory, e.g.
    ///   `~/.claude-accounts/work` or `~/.claude` for the default account.
    /// - Returns: `true` when a match is found, and `true` again when the
    ///   scan could not be completed.
    func isLive(
        configurationDirectory: String,
        bypassCache: Bool = false
    ) -> Bool {
        let target = Self.canonical(configurationDirectory)
        let isDefaultAccount = target
            == Self.canonical(defaultConfigurationDirectory)

        let processes: [RunningProcessSnapshot]
        do {
            processes = try cachedProcesses(bypassCache: bypassCache)
        } catch {
            log(
                "Could not enumerate running processes, so the account at "
                + "\(configurationDirectory) is treated as in use: \(error)"
            )
            return true
        }

        for process in processes {
            if Self.process(
                process,
                usesConfigurationDirectory: target,
                isDefaultAccount: isDefaultAccount
            ) {
                log(
                    "Claude Code process \(process.processIdentifier) is "
                    + "using \(configurationDirectory)"
                )
                return true
            }
        }
        return false
    }

    /// Drops the cached scan. Used by tests and by anything that has just
    /// changed which processes ought to exist.
    func invalidateCache() {
        cacheMutex.lock()
        defer { cacheMutex.unlock() }
        cachedResult = nil
        cachedAt = nil
    }

    private func cachedProcesses(
        bypassCache: Bool = false
    ) throws -> [RunningProcessSnapshot] {
        // Held across the scan as well as the read: two callers arriving
        // together then take one scan between them rather than two, and
        // neither can see the cache half-written.
        cacheMutex.lock()
        defer { cacheMutex.unlock() }
        // A guarded renewal replay asks again while holding its account
        // lock: a CLI may have started since the ordinary five-second scan.
        // Bypass and refresh the cache under this same mutex, rather than
        // invalidating first and opening a second race between those calls.
        if !bypassCache, let cachedResult, let cachedAt,
           now().timeIntervalSince(cachedAt) < cacheDuration {
            return try cachedResult.get()
        }
        let result = Result { try source.currentProcesses() }
        cachedResult = result
        cachedAt = now()
        return try result.get()
    }

    // MARK: - Matching

    static func process(
        _ process: RunningProcessSnapshot,
        usesConfigurationDirectory target: String,
        isDefaultAccount: Bool
    ) -> Bool {
        // It must be Claude Code. Carrying `CLAUDE_CONFIG_DIR` is not
        // evidence of that, and treating it as evidence was badly wrong on a
        // real machine: RevvyTach itself runs
        // `tmux set-environment -g CLAUDE_CONFIG_DIR <dir>`, so every pane
        // opened afterwards and everything it spawns inherits the variable.
        // Measured across seven linked accounts, three had node, python, uv
        // or a language-server process carrying it with no `claude` anywhere
        // near them — and those three would have been refused a refresh
        // forever, then shown as asleep forever, because the processes
        // holding the variable are long-lived.
        guard looksLikeClaudeCode(process) else { return false }

        let declared = process.environment[configurationDirectoryVariable]

        if let declared, !declared.isEmpty {
            // An explicit pointer answers the question either way: a `claude`
            // that names a different directory is not using this one.
            return canonical(declared) == target
        }

        // No pointer at all. Claude Code then uses `~/.claude`, so such a
        // process is live for the default account and for no other.
        return isDefaultAccount
    }

    /// Whether a process is the `claude` CLI.
    ///
    /// Three signals, because the CLI is installed three ways.
    ///
    /// A Homebrew install leaves an executable literally named `claude`. The
    /// native installer runs a versioned binary under
    /// `~/.local/share/claude/versions/<version>`, whose own file name is the
    /// version string and tells you nothing. And an npm install is a shebang
    /// script, so the executable and `argv[0]` are the interpreter — `node`
    /// or `bun` — and the only thing that says "Claude Code" is
    /// `argv[1]`, the path to `@anthropic-ai/claude-code/cli.js`.
    ///
    /// Every argument is scanned rather than only the first, which is what
    /// the npm case needs, and a `cli.js` is accepted only when its own path
    /// names Claude Code — an unrelated `cli.js` is not this.
    static func looksLikeClaudeCode(
        _ process: RunningProcessSnapshot
    ) -> Bool {
        for candidate in [process.executablePath] + process.arguments {
            let name = (candidate as NSString).lastPathComponent
            if name == "claude" { return true }
            if candidate.contains("/claude/versions/") { return true }
            if candidate.contains("/claude-code/") { return true }
            if name == "cli.js",
               candidate.lowercased().contains("claude") {
                return true
            }
        }
        return false
    }

    /// One spelling for one directory.
    ///
    /// Three things make the same directory look like two different strings
    /// across two processes: a `~` that one side expanded and the other did
    /// not, a trailing slash, and Unicode that is decomposed in a path read
    /// off the filesystem and composed in one typed into a shell. Claude
    /// Code normalises to NFC before hashing the path into its Keychain
    /// service name, so NFC is the spelling both programs already agree on.
    static func canonical(_ path: String) -> String {
        var expanded = (path as NSString).expandingTildeInPath
        while expanded.count > 1, expanded.hasSuffix("/") {
            expanded.removeLast()
        }
        return expanded.precomposedStringWithCanonicalMapping
    }
}
