//
//  ClaudeSwitchService.swift
//  Claude Usage
//
//  Switches the active Claude Code CLI account by setting CLAUDE_CONFIG_DIR
//  via tmux environment propagation and persisting the choice for new shells.
//  Also handles account directory creation, symlinks, and credential detection.
//

import Foundation

/// Manages CLI account switching using the claude-switch mechanism.
/// Each account has its own config directory at ~/.claude-accounts/<name>/
/// with per-account credentials while sharing settings via symlinks from ~/.claude/.
class ClaudeSwitchService {
    static let shared = ClaudeSwitchService()

    /// Files that are per-account and should NOT be symlinked from ~/.claude/
    private let perAccountFiles: Set<String> = [".credentials.json", ".claude.json"]

    /// Serial queue for all tmux operations — prevents race conditions when unlink
    /// and switch dispatch concurrently (unpropagate could otherwise win over propagate).
    private let tmuxQueue = DispatchQueue(label: "io.revenium.claude-usage.tmux", qos: .utility)

    private init() {}

    // MARK: - Paths

    private var accountsDir: URL {
        Constants.ClaudePaths.homeDirectory
            .appendingPathComponent(".claude-accounts")
    }

    private var tokensDir: URL {
        Constants.ClaudePaths.homeDirectory
            .appendingPathComponent(".claude-tokens")
    }

    private var lastAccountFile: URL {
        tokensDir.appendingPathComponent(".last-account")
    }

    private var claudeDir: URL {
        Constants.ClaudePaths.homeDirectory
            .appendingPathComponent(".claude")
    }

    /// The user-level ~/.claude.json where `claude mcp add` stores MCP server config.
    /// This is distinct from ~/.claude/.claude.json (inside the config directory).
    private var homeClaudeJson: URL {
        Constants.ClaudePaths.homeDirectory
            .appendingPathComponent(".claude.json")
    }

    private var mainSkillsDir: URL {
        claudeDir.appendingPathComponent("skills")
    }

    private var dotfilesSkillsDir: URL {
        Constants.ClaudePaths.homeDirectory
            .appendingPathComponent("dotfiles")
            .appendingPathComponent(".claude")
            .appendingPathComponent("skills")
    }

    /// Returns the full path for an account directory
    func accountDirectoryPath(for name: String) -> URL {
        accountsDir.appendingPathComponent(name)
    }

    /// Validates that the resolved account directory is within accountsDir.
    /// Throws if the name contains path traversal components.
    private func validatedAccountDir(for name: String) throws -> URL {
        let dir = accountsDir.appendingPathComponent(name).standardized
        guard dir.path.hasPrefix(accountsDir.standardized.path + "/") || dir == accountsDir.standardized else {
            throw ClaudeSwitchError.invalidAccountName(name)
        }
        return dir
    }

    // MARK: - Name Sanitization

    /// Converts a profile name to a filesystem-safe directory name.
    /// Lowercases, replaces non-alphanumeric characters with hyphens,
    /// collapses consecutive hyphens, and strips leading/trailing hyphens.
    func sanitizeProfileName(_ name: String) -> String {
        let lowered = name.lowercased()
        let replaced = lowered.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        let collapsed = replaced.replacingOccurrences(
            of: "-{2,}", with: "-",
            options: .regularExpression
        )
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? UUID().uuidString.prefix(8).lowercased() : trimmed
    }

    /// Returns the directory name that would be created for the given profile name,
    /// including any numeric suffix to avoid collisions. Used by UI to show accurate
    /// preview before linking. Returns the sanitized base name if resolution fails.
    func previewDirectoryName(for profileName: String) -> String {
        let base = sanitizeProfileName(profileName)
        return (try? resolveDirectoryName(baseName: base)) ?? base
    }

    // MARK: - Discovery

    /// Lists available account names from ~/.claude-accounts/ that have credentials.
    /// Note: this is credential-filtered — directories without credentials are excluded.
    /// Use `allAccountDirectoryNames()` when credential state should not matter (e.g., MCP sync).
    func availableAccountNames() -> [String] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: accountsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return contents
            .filter { url in
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                guard isDir.boolValue else { return false }
                return hasCredentialFiles(in: url)
            }
            .map { $0.lastPathComponent }
            .sorted()
    }

    /// Returns the names of all account directories, regardless of credential state.
    /// Use for MCP sync which should propagate to all linked dirs, not just authenticated ones.
    private func allAccountDirectoryNames() -> [String] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: accountsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return contents
            .filter { url in
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                return isDir.boolValue
            }
            .map { $0.lastPathComponent }
            .sorted()
    }

    /// Checks whether an account name has a valid directory with credentials.
    /// Supports both .credentials.json (legacy) and .claude.json (v2.1.52+).
    func isValidAccountName(_ name: String) -> Bool {
        let dir = accountDirectoryPath(for: name)
        return hasCredentialFiles(in: dir)
    }

    /// Checks whether an account directory exists (even without credentials yet)
    func accountDirectoryExists(_ name: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: accountDirectoryPath(for: name).path,
            isDirectory: &isDir
        ) && isDir.boolValue
    }

    /// Returns the currently persisted account name, if any
    func currentAccountName() -> String? {
        guard let data = try? String(contentsOf: lastAccountFile, encoding: .utf8) else {
            return nil
        }
        let name = data.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    // MARK: - Linking

    /// Creates a dedicated CLI account directory for a profile and symlinks shared config.
    /// - Parameter profileName: The display name of the profile (will be sanitized)
    /// - Returns: Result with directory info and symlink count
    func linkAccount(profileName: String) throws -> LinkAccountResult {
        let dirName = sanitizeProfileName(profileName)

        // Resolve directory name (reuses existing directory if present)
        let finalDirName = try resolveDirectoryName(baseName: dirName)
        let finalAccountDir = accountDirectoryPath(for: finalDirName)
        let directoryAlreadyExisted = FileManager.default.fileExists(
            atPath: finalAccountDir.path
        )

        // Check if this is an existing directory that already has credentials
        let existingWithCreds = FileManager.default.fileExists(atPath: finalAccountDir.path)
            && hasCredentialFiles(in: finalAccountDir)

        // Clear stale symlinks only for credential-less directories (e.g., previous failed link)
        if FileManager.default.fileExists(atPath: finalAccountDir.path) && !existingWithCreds {
            clearStaleSymlinks(in: finalAccountDir)
        }

        // Create account directory (no-op if it already exists)
        try FileManager.default.createDirectory(
            at: finalAccountDir, withIntermediateDirectories: true)

        // Create tokens directory if needed
        if !FileManager.default.fileExists(atPath: tokensDir.path) {
            try FileManager.default.createDirectory(
                at: tokensDir, withIntermediateDirectories: true)
        }

        // Symlink shared config from ~/.claude/ (skips items that already exist)
        let (symlinkCount, skippedFiles) = try createSymlinks(
            from: claudeDir, to: finalAccountDir)

        let destClaudeJson = finalAccountDir.appendingPathComponent(".claude.json")

        // Only set up .claude.json for new directories — don't touch existing credentials
        if !existingWithCreds {
            // Copy .claude.json as a starting point if it exists (from ~/.claude/.claude.json)
            let sourceClaudeJson = claudeDir.appendingPathComponent(".claude.json")
            if FileManager.default.fileExists(atPath: sourceClaudeJson.path)
                && !FileManager.default.fileExists(atPath: destClaudeJson.path) {
                try FileManager.default.copyItem(at: sourceClaudeJson, to: destClaudeJson)
            }

            // Strip oauthAccount from the copy — user hasn't logged in to this account yet
            if FileManager.default.fileExists(atPath: destClaudeJson.path),
               let data = try? Data(contentsOf: destClaudeJson),
               var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                json.removeValue(forKey: "oauthAccount")
                if let cleaned = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
                    try? cleaned.write(to: destClaudeJson, options: .atomic)
                }
            }
        }

        // Merge mcpServers from ~/.claude.json (where `claude mcp add` stores config)
        // into the account's .claude.json so MCP servers carry over seamlessly.
        mergeMcpServersFromHome(into: destClaudeJson)

        LoggingService.shared.log(
            "ClaudeSwitchService: Linked account '\(finalDirName)' "
            + "(\(symlinkCount) symlinks, \(skippedFiles.count) skipped)")

        return LinkAccountResult(
            directoryName: finalDirName,
            directoryPath: finalAccountDir.path,
            symlinkCount: symlinkCount,
            skippedFiles: skippedFiles,
            createdNewDirectory: !directoryAlreadyExisted
        )
    }

    /// Removes an account directory and clears .last-account if it references this account.
    func unlinkAccount(directoryName: String) throws {
        let dir = try validatedAccountDir(for: directoryName)

        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }

        // Clear .last-account and unset tmux env if this was the active account
        if currentAccountName() == directoryName {
            try? FileManager.default.removeItem(at: lastAccountFile)
            unpropagateFromTmux()
        }

        LoggingService.shared.log(
            "ClaudeSwitchService: Unlinked account '\(directoryName)'")
    }

    // MARK: - Credential Detection

    /// Checks whether the linked directory has valid credentials.
    func checkForCredentials(directoryName: String) -> CredentialCheckResult {
        let dir = (try? validatedAccountDir(for: directoryName)) ?? accountDirectoryPath(for: directoryName)
        let credFile = dir.appendingPathComponent(".credentials.json")
        let claudeJson = dir.appendingPathComponent(".claude.json")

        let hasLegacy = FileManager.default.fileExists(atPath: credFile.path)
        let hasModern = hasOAuthAccountInClaudeJson(at: claudeJson)

        switch (hasLegacy, hasModern) {
        case (true, true): return .both
        case (true, false): return .legacyCredentials
        case (false, true): return .modernCredentials
        case (false, false): return .notFound
        }
    }

    /// Reads credentials JSON from the linked account directory.
    /// Tries .credentials.json first, falls back to extracting from .claude.json.
    ///
    /// Both branches now have to produce something that can actually
    /// authenticate. `.credentials.json` was previously returned verbatim on
    /// the strength of being a non-empty string — not even parsed — and this
    /// is the *first* source the re-sync button consults, so a file holding
    /// only MCP server logins, or a truncated one, was stored over a working
    /// credential and then read back as valid.
    func readLinkedAccountCredentials(directoryName: String) -> String? {
        let dir = (try? validatedAccountDir(for: directoryName)) ?? accountDirectoryPath(for: directoryName)

        // Try .credentials.json first
        let credFile = dir.appendingPathComponent(".credentials.json")
        if let data = try? Data(contentsOf: credFile),
           let json = String(data: data, encoding: .utf8),
           ClaudeCodeSyncService.carriesLogin(json) {
            return json
        }

        // Fall back to .claude.json — extract OAuth if present
        let claudeJson = dir.appendingPathComponent(".claude.json")
        if let data = try? Data(contentsOf: claudeJson),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let oauthAccount = parsed["oauthAccount"] as? [String: Any],
           let accessToken = oauthAccount["accessToken"] as? String,
           !accessToken.isEmpty {
            // Build credentials JSON safely using JSONSerialization (not string interpolation)
            //
            // Deliberately carries no `expiresAt` and no `refreshToken`,
            // because this source has neither. That makes it a credential the
            // app can use until the token stops working and can never renew,
            // so it stays the last resort it has always been.
            let dict: [String: Any] = ["claudeAiOauth": ["accessToken": accessToken]]
            if let jsonData = try? JSONSerialization.data(withJSONObject: dict),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                return jsonString
            }
        }

        return nil
    }

    // MARK: - Switching

    /// Switches the active CLI account by:
    /// 1. Writing the account name to ~/.claude-tokens/.last-account (shell auto-restore)
    /// 2. Setting CLAUDE_CONFIG_DIR in tmux global environment (propagates to new panes)
    func switchToAccount(_ accountName: String) throws {
        let configDir = try validatedAccountDir(for: accountName).path

        // Verify directory exists (don't require credentials — user may not have logged in yet)
        guard accountDirectoryExists(accountName) else {
            throw ClaudeSwitchError.invalidAccountName(accountName)
        }

        // Persist for shell auto-restore on new terminal startup
        try writeLastAccount(accountName)

        // Propagate to tmux (best-effort — tmux may not be running)
        propagateToTmux(configDir: configDir)

        LoggingService.shared.log(
            "ClaudeSwitchService: Switched CLI account to '\(accountName)' "
            + "(CLAUDE_CONFIG_DIR=\(configDir))")
    }

    // MARK: - MCP Server Sync

    /// Performs bidirectional MCP server sync: collects mcpServers from ~/.claude.json
    /// and ALL linked account directories, builds the union, and writes missing servers
    /// back to every source. Returns a detailed result of what changed where.
    func bidirectionalMcpSync() -> McpSyncResult {
        // 1. Collect MCPs from all sources
        // Use allAccountDirectoryNames so pre-login dirs (no credentials yet) are included.
        let accountNames = allAccountDirectoryNames()  // snapshot once — avoid TOCTOU
        var unionMcps: [String: Any] = [:]
        var sourceMcpSets: [(label: String, url: URL, mcps: [String: Any])] = []

        // Home ~/.claude.json
        if let mcps = readMcpServers(from: homeClaudeJson) {
            sourceMcpSets.append((label: "~/.claude.json", url: homeClaudeJson, mcps: mcps))
            for (name, config) in mcps where unionMcps[name] == nil {
                unionMcps[name] = config
            }
        }

        // Each account directory
        for accountName in accountNames {
            let accountJson = accountDirectoryPath(for: accountName)
                .appendingPathComponent(".claude.json")
            if let mcps = readMcpServers(from: accountJson) {
                sourceMcpSets.append((label: accountName, url: accountJson, mcps: mcps))
                for (name, config) in mcps where unionMcps[name] == nil {
                    unionMcps[name] = config
                }
            }
        }

        guard !unionMcps.isEmpty else {
            return McpSyncResult(changes: [])
        }

        // 2. Write missing servers back to each source
        var changes: [McpSyncResult.AccountChange] = []

        for source in sourceMcpSets {
            let missing = unionMcps.keys.filter { source.mcps[$0] == nil }
            guard !missing.isEmpty else { continue }

            let addedCount = writeMcpServers(unionMcps, into: source.url)
            if addedCount > 0 {
                changes.append(McpSyncResult.AccountChange(
                    accountName: source.label,
                    addedServers: missing.sorted()
                ))
            }
        }

        // Also handle sources that had NO mcpServers at all (not in sourceMcpSets)
        // — e.g., ~/.claude.json didn't exist or had no mcpServers key
        if !sourceMcpSets.contains(where: { $0.label == "~/.claude.json" }) {
            let added = writeMcpServers(unionMcps, into: homeClaudeJson)
            if added > 0 {
                changes.append(McpSyncResult.AccountChange(
                    accountName: "~/.claude.json",
                    addedServers: unionMcps.keys.sorted()
                ))
            }
        }
        for accountName in accountNames {
            if !sourceMcpSets.contains(where: { $0.label == accountName }) {
                let accountJson = accountDirectoryPath(for: accountName)
                    .appendingPathComponent(".claude.json")
                let added = writeMcpServers(unionMcps, into: accountJson)
                if added > 0 {
                    changes.append(McpSyncResult.AccountChange(
                        accountName: accountName,
                        addedServers: unionMcps.keys.sorted()
                    ))
                }
            }
        }

        if !changes.isEmpty {
            LoggingService.shared.log(
                "ClaudeSwitchService: Bidirectional MCP sync — "
                + "\(changes.reduce(0) { $0 + $1.addedServers.count }) server(s) across "
                + "\(changes.count) target(s)")
        }

        return McpSyncResult(changes: changes)
    }

    // MARK: - Skills Sync

    /// Syncs skills from ~/dotfiles/.claude/skills/ to ~/.claude/skills/, and ensures
    /// all account directories have a `skills` symlink pointing to ~/.claude/skills/.
    /// Because account dirs already symlink their skills/ to ~/.claude/skills/, syncing
    /// dotfiles → main propagates automatically to every account.
    func syncSkills() -> SkillsSyncResult {
        var changes: [SkillsSyncResult.AccountChange] = []

        // 1. Sync configured source (or dotfiles fallback) → ~/.claude/skills/
        let dotfilesAdded = syncSkillsFromSource()
        if !dotfilesAdded.isEmpty {
            changes.append(SkillsSyncResult.AccountChange(
                accountName: "~/.claude/skills",
                addedSkills: dotfilesAdded
            ))
        }

        // 2. Ensure each account dir has skills/ → ~/.claude/skills/
        let accountChanges = ensureAccountSkillsLinks()
        changes.append(contentsOf: accountChanges)

        if !changes.isEmpty {
            LoggingService.shared.log(
                "ClaudeSwitchService: Skills sync — "
                + "\(changes.reduce(0) { $0 + $1.addedSkills.count }) skill(s) across "
                + "\(changes.count) target(s)")
        }

        return SkillsSyncResult(changes: changes)
    }

    /// Symlinks entries from the configured source directory (or dotfiles fallback) into ~/.claude/skills/.
    private func syncSkillsFromSource() -> [String] {
        // Priority: user-configured path > dotfiles convention > skip
        let sourceDir: URL
        if let configured = SharedDataStore.shared.loadSkillsSourceDirectory() {
            sourceDir = URL(fileURLWithPath: configured)
        } else if FileManager.default.fileExists(atPath: dotfilesSkillsDir.path) {
            sourceDir = dotfilesSkillsDir
        } else {
            return []
        }

        guard let entries = try? FileManager.default.contentsOfDirectory(
                  at: sourceDir, includingPropertiesForKeys: nil, options: [])
        else { return [] }

        // Use lstat (attributesOfItem) to detect dangling symlinks that fileExists misses.
        // fileExists follows symlinks: returns false for a broken symlink, causing createDirectory
        // to fail with EEXIST because the dangling symlink node already occupies the path.
        let mainLstat = try? FileManager.default.attributesOfItem(atPath: mainSkillsDir.path)
        let mainExists = FileManager.default.fileExists(atPath: mainSkillsDir.path)
        if mainLstat == nil {
            // No node at all — create the directory
            do {
                try FileManager.default.createDirectory(
                    at: mainSkillsDir, withIntermediateDirectories: true)
            } catch {
                LoggingService.shared.log(
                    "ClaudeSwitchService: Failed to create skills dir: \(error.localizedDescription)")
                return []
            }
        } else if (mainLstat?[.type] as? FileAttributeType) == .typeSymbolicLink, !mainExists {
            // Dangling symlink (lstat found it, but stat/fileExists found no target) — remove and recreate
            do {
                try FileManager.default.removeItem(at: mainSkillsDir)
                try FileManager.default.createDirectory(
                    at: mainSkillsDir, withIntermediateDirectories: true)
            } catch {
                LoggingService.shared.log(
                    "ClaudeSwitchService: Failed to create skills dir: \(error.localizedDescription)")
                return []
            }
        }

        var added: [String] = []
        for entry in entries {
            let name = entry.lastPathComponent
            let dest = mainSkillsDir.appendingPathComponent(name)
            // attributesOfItem uses lstat — succeeds for broken symlinks too
            guard (try? FileManager.default.attributesOfItem(atPath: dest.path)) == nil else { continue }
            // Guard against relay: if the source entry is a symlink escaping sourceDir, skip it.
            let realEntry = entry.resolvingSymlinksInPath()
            let realSource = sourceDir.resolvingSymlinksInPath()
            guard realEntry.path.hasPrefix(realSource.path + "/") else {
                LoggingService.shared.log(
                    "ClaudeSwitchService: Skipping skill '\(name)' — symlink escapes source directory")
                continue
            }
            do {
                try FileManager.default.createSymbolicLink(at: dest, withDestinationURL: entry)
                added.append(name)
            } catch {
                LoggingService.shared.log(
                    "ClaudeSwitchService: Failed to link skill '\(name)' from source: "
                    + "\(error.localizedDescription)")
            }
        }
        return added.sorted()
    }

    /// Ensures every account directory has skills/ → ~/.claude/skills/.
    /// Accounts already pointing to the correct target are skipped.
    /// Accounts with a real skills/ directory get missing entries added as symlinks.
    /// Accounts with no skills/ entry get a direct symlink created.
    private func ensureAccountSkillsLinks() -> [SkillsSyncResult.AccountChange] {
        var changes: [SkillsSyncResult.AccountChange] = []
        for accountName in allAccountDirectoryNames() {
            // Use validatedAccountDir for path-containment safety, consistent with other sync methods.
            guard let accountDir = try? validatedAccountDir(for: accountName) else { continue }
            let skillsPath = accountDir.appendingPathComponent("skills")

            // Already a symlink — check it points to the right place.
            // Resolve relative targets against the symlink's containing directory to avoid
            // incorrect CWD-relative resolution.
            var shouldReplaceSymlink = false
            if let target = try? FileManager.default.destinationOfSymbolicLink(
                atPath: skillsPath.path) {
                let resolvedTarget: URL
                if target.hasPrefix("/") {
                    resolvedTarget = URL(fileURLWithPath: target).standardized
                } else {
                    resolvedTarget = skillsPath.deletingLastPathComponent()
                        .appendingPathComponent(target).standardized
                }
                if resolvedTarget == mainSkillsDir.standardized {
                    continue  // already correct
                }
                // Wrong-target symlink detected: bypass real-dir branch to avoid writing
                // skills into an unintended external directory.
                shouldReplaceSymlink = true
            }

            // Real directory exists — sync missing entries into it.
            // Skip this branch for wrong-target symlinks: fileExists follows the symlink,
            // so a valid external directory would pass the isDir check and receive writes.
            var isDir: ObjCBool = false
            if !shouldReplaceSymlink,
               FileManager.default.fileExists(atPath: skillsPath.path, isDirectory: &isDir),
               isDir.boolValue {
                let added = syncMissingSkillEntries(from: mainSkillsDir, to: skillsPath)
                if !added.isEmpty {
                    changes.append(SkillsSyncResult.AccountChange(
                        accountName: accountName, addedSkills: added))
                }
                continue
            }

            // skills/ absent or is a symlink pointing elsewhere — create/replace symlink.
            // Only remove symlink nodes; a regular file or other non-symlink at this path
            // is unexpected and must not be silently destroyed.
            let nodeAttrs = try? FileManager.default.attributesOfItem(atPath: skillsPath.path)
            if let nodeType = nodeAttrs?[.type] as? FileAttributeType,
               nodeType != .typeSymbolicLink {
                LoggingService.shared.log(
                    "ClaudeSwitchService: Skipping non-symlink node at skills path for '\(accountName)'")
                continue
            }
            try? FileManager.default.removeItem(at: skillsPath)
            do {
                try FileManager.default.createSymbolicLink(
                    at: skillsPath, withDestinationURL: mainSkillsDir)
                LoggingService.shared.log(
                    "ClaudeSwitchService: Created skills symlink for '\(accountName)'")
                changes.append(SkillsSyncResult.AccountChange(
                    accountName: accountName, addedSkills: ["(linked)"]))
            } catch {
                LoggingService.shared.log(
                    "ClaudeSwitchService: Failed to create skills symlink for '\(accountName)': "
                    + "\(error.localizedDescription)")
            }
        }
        return changes
    }

    /// Adds entries from `source` that are missing in `destination` as symlinks.
    /// Always points new symlinks at the source entry directly rather than following
    /// transitive symlink chains, which prevents relay of arbitrary link targets.
    private func syncMissingSkillEntries(from source: URL, to destination: URL) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: source, includingPropertiesForKeys: nil, options: [])
        else { return [] }

        var added: [String] = []
        for entry in entries {
            let name = entry.lastPathComponent
            let dest = destination.appendingPathComponent(name)
            guard (try? FileManager.default.attributesOfItem(atPath: dest.path)) == nil else { continue }

            do {
                // Point directly at the source entry (avoids propagating arbitrary symlink chains)
                try FileManager.default.createSymbolicLink(at: dest, withDestinationURL: entry)
                added.append(name)
            } catch {
                LoggingService.shared.log(
                    "ClaudeSwitchService: Failed to add skill '\(name)' to '\(destination.lastPathComponent)': "
                    + "\(error.localizedDescription)")
            }
        }
        return added.sorted()
    }

    // MARK: - Private Helpers

    /// Reads the mcpServers dictionary from a .claude.json file.
    private func readMcpServers(from url: URL) -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mcps = dict["mcpServers"] as? [String: Any],
              !mcps.isEmpty else {
            return nil
        }
        return mcps
    }

    /// Writes the union of MCP servers into a .claude.json file, preserving all other keys.
    /// Only adds servers that are missing. Returns the number of servers added.
    /// Skips the write entirely if an existing file cannot be parsed (avoids clobbering).
    @discardableResult
    private func writeMcpServers(_ unionMcps: [String: Any], into url: URL) -> Int {
        // Read or initialize destination — abort if file exists but can't be parsed
        var destDict: [String: Any] = [:]
        let fileExists = FileManager.default.fileExists(atPath: url.path)
        if fileExists {
            guard let data = try? Data(contentsOf: url),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                LoggingService.shared.log(
                    "ClaudeSwitchService: Skipping MCP write to \(url.lastPathComponent) "
                    + "— file exists but could not be parsed")
                return 0
            }
            destDict = parsed
        }

        var existingMcps = destDict["mcpServers"] as? [String: Any] ?? [:]
        var addedCount = 0
        for (name, config) in unionMcps where existingMcps[name] == nil {
            existingMcps[name] = config
            addedCount += 1
        }

        guard addedCount > 0 else { return 0 }

        destDict["mcpServers"] = existingMcps

        do {
            let jsonData = try JSONSerialization.data(
                withJSONObject: destDict, options: [.prettyPrinted, .sortedKeys])
            try jsonData.write(to: url, options: .atomic)
        } catch {
            LoggingService.shared.log(
                "ClaudeSwitchService: Failed to write MCP servers to \(url.lastPathComponent): "
                + "\(error.localizedDescription)")
            return 0
        }

        return addedCount
    }

    /// Merges mcpServers from ~/.claude.json into a single destination (used during linkAccount).
    @discardableResult
    private func mergeMcpServersFromHome(into destClaudeJson: URL) -> Int {
        guard let homeMcps = readMcpServers(from: homeClaudeJson) else { return 0 }
        return writeMcpServers(homeMcps, into: destClaudeJson)
    }

    private func hasCredentialFiles(in dir: URL) -> Bool {
        let credFile = dir.appendingPathComponent(".credentials.json")
        if FileManager.default.fileExists(atPath: credFile.path) {
            return true
        }
        // For .claude.json, verify it actually contains oauthAccount (not just a copied template)
        let claudeJson = dir.appendingPathComponent(".claude.json")
        return hasOAuthAccountInClaudeJson(at: claudeJson)
    }

    private func hasOAuthAccountInClaudeJson(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return parsed["oauthAccount"] != nil
    }

    private func resolveDirectoryName(baseName: String) throws -> String {
        // Always reuse an existing directory with the same name.
        // If it already has credentials, linkAccount will adopt it as-is.
        return baseName
    }

    private func createSymlinks(from source: URL, to destination: URL) throws -> (Int, [String]) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return (0, [])
        }

        var symlinkCount = 0
        var skippedFiles: [String] = []

        for item in contents {
            let name = item.lastPathComponent

            // Skip per-account files
            if perAccountFiles.contains(name) {
                skippedFiles.append(name)
                continue
            }

            let destPath = destination.appendingPathComponent(name)

            // Skip if already exists in destination
            if FileManager.default.fileExists(atPath: destPath.path) {
                skippedFiles.append(name)
                continue
            }

            do {
                try FileManager.default.createSymbolicLink(
                    at: destPath, withDestinationURL: item)
                symlinkCount += 1
            } catch {
                LoggingService.shared.log(
                    "ClaudeSwitchService: Failed to symlink \(name): \(error.localizedDescription)")
                skippedFiles.append(name)
            }
        }

        return (symlinkCount, skippedFiles)
    }

    private func writeLastAccount(_ name: String) throws {
        let dir = lastAccountFile.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
        }
        try name.write(to: lastAccountFile, atomically: true, encoding: .utf8)
    }

    private func unpropagateFromTmux() {
        let tmuxPaths = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        guard let tmuxPath = tmuxPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            LoggingService.shared.log("ClaudeSwitchService: tmux not found — skipping env unset")
            return
        }

        tmuxQueue.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tmuxPath)
            process.arguments = ["set-environment", "-gu", "CLAUDE_CONFIG_DIR"]
            process.standardOutput = Pipe()
            process.standardError = Pipe()

            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    LoggingService.shared.log(
                        "ClaudeSwitchService: tmux CLAUDE_CONFIG_DIR unset")
                } else {
                    LoggingService.shared.log(
                        "ClaudeSwitchService: tmux set-environment -gu failed "
                        + "(exit \(process.terminationStatus)) — ignored")
                }
            } catch {
                LoggingService.shared.log("ClaudeSwitchService: tmux unset command failed — ignored")
            }
        }
    }

    private func clearStaleSymlinks(in dir: URL) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []
        ) else { return }
        for item in contents {
            let vals = try? item.resourceValues(forKeys: [.isSymbolicLinkKey])
            if vals?.isSymbolicLink == true {
                try? FileManager.default.removeItem(at: item)
            }
        }
    }

    private func propagateToTmux(configDir: String) {
        let tmuxPaths = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        guard let tmuxPath = tmuxPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            LoggingService.shared.log("ClaudeSwitchService: tmux not found — skipping env propagation")
            return
        }

        // Fire-and-forget on serial queue: don't block the calling thread waiting for tmux
        tmuxQueue.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tmuxPath)
            process.arguments = ["set-environment", "-g", "CLAUDE_CONFIG_DIR", configDir]
            process.standardOutput = Pipe()
            process.standardError = Pipe()

            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    LoggingService.shared.log("ClaudeSwitchService: tmux environment propagated")
                } else {
                    LoggingService.shared.log(
                        "ClaudeSwitchService: tmux set-environment failed "
                        + "(exit \(process.terminationStatus)) — ignored")
                }
            } catch {
                LoggingService.shared.log("ClaudeSwitchService: tmux command failed — ignored")
            }
        }
    }
}

// MARK: - Result Types

struct LinkAccountResult {
    let directoryName: String
    let directoryPath: String
    let symlinkCount: Int
    let skippedFiles: [String]
    let createdNewDirectory: Bool
}

struct McpSyncResult {
    struct AccountChange: Identifiable {
        let accountName: String
        let addedServers: [String]
        var id: String { accountName }
    }
    let changes: [AccountChange]
    var totalSynced: Int { changes.reduce(0) { $0 + $1.addedServers.count } }
    var hasChanges: Bool { totalSynced > 0 }
}

struct SkillsSyncResult {
    struct AccountChange: Identifiable {
        let accountName: String
        let addedSkills: [String]
        var id: String { accountName }
    }
    let changes: [AccountChange]
    var totalSynced: Int { changes.reduce(0) { $0 + $1.addedSkills.count } }
    var hasChanges: Bool { totalSynced > 0 }
}

enum CredentialCheckResult {
    case notFound
    case legacyCredentials
    case modernCredentials
    case both

    var hasCredentials: Bool {
        switch self {
        case .notFound: return false
        default: return true
        }
    }
}

// MARK: - Errors

enum ClaudeSwitchError: LocalizedError {
    case invalidAccountName(String)
    case directoryCreationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidAccountName(let name):
            return "No CLI account directory found for '\(name)'. "
                 + "Expected ~/.claude-accounts/\(name)/"
        case .directoryCreationFailed(let path):
            return "Failed to create account directory at \(path)"
        }
    }
}
