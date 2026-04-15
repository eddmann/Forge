import Foundation

/// Generic installer for agent hook settings files (Claude Code, Codex, etc.).
///
/// All current consumers share the same shape:
/// ```
/// { "hooks": { <event>: [ { "matcher"?: "...", "hooks": [{"type":"command","command":"..."}] }, ... ] } }
/// ```
///
/// Forge identifies its own hook entries by substring-matching `ownershipMarker`
/// against the `command` field. Install/uninstall preserves any user-authored
/// hooks; only Forge-owned entries are pruned before our hooks are added back.
struct AgentHookInstaller {
    /// Substring used to identify a hook command as Forge-managed.
    let ownershipMarker: String

    /// Additional substrings that mark hook entries as Forge-owned. Used to
    /// recognise legacy formats so reinstall cleans them up even after we've
    /// changed the primary marker string.
    let legacyMarkers: [String]

    init(ownershipMarker: String, legacyMarkers: [String] = []) {
        self.ownershipMarker = ownershipMarker
        self.legacyMarkers = legacyMarkers
    }

    private func commandIsOwned(_ command: String) -> Bool {
        if command.contains(ownershipMarker) { return true }
        return legacyMarkers.contains { command.contains($0) }
    }

    /// Inspect the settings file and report whether any Forge-managed hook is present.
    func isInstalled(settingsURL: URL) -> Bool {
        guard let settings = readSettings(at: settingsURL),
              let hooksDict = settings["hooks"] as? [String: Any]
        else { return false }
        return scanForOwnedCommand(in: hooksDict)
    }

    /// Merge the given hook groups into the settings file. Removes any existing
    /// Forge-owned entries (identified by `ownershipMarker`) before adding ours,
    /// preserving user-authored hooks.
    ///
    /// Throws only if the file exists but cannot be parsed as a JSON object.
    /// A nonexistent file is created.
    func install(settingsURL: URL, hooks: [String: [[String: Any]]]) throws {
        try ensureParentDirectory(for: settingsURL)
        var settings = try (readOrThrow(at: settingsURL)) ?? [:]

        var existingHooks = settings["hooks"] as? [String: Any] ?? [:]
        for (event, newGroups) in hooks {
            var groups = existingHooks[event] as? [[String: Any]] ?? []
            groups.removeAll { groupContainsOwnedCommand($0) }
            groups.append(contentsOf: newGroups)
            existingHooks[event] = groups
        }
        settings["hooks"] = existingHooks

        try writeSettings(settings, to: settingsURL)
    }

    /// Remove every Forge-owned hook entry from the settings file. User hooks
    /// are preserved. Empty event arrays are removed; an empty `hooks` dict is
    /// removed entirely.
    func uninstall(settingsURL: URL) throws {
        guard var settings = try readOrThrow(at: settingsURL),
              var existingHooks = settings["hooks"] as? [String: Any]
        else { return }

        for event in Array(existingHooks.keys) {
            guard var groups = existingHooks[event] as? [[String: Any]] else { continue }
            groups.removeAll { groupContainsOwnedCommand($0) }
            if groups.isEmpty {
                existingHooks.removeValue(forKey: event)
            } else {
                existingHooks[event] = groups
            }
        }

        if existingHooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = existingHooks
        }

        try writeSettings(settings, to: settingsURL)
    }

    // MARK: - Helpers

    private func scanForOwnedCommand(in hooksDict: [String: Any]) -> Bool {
        for (_, value) in hooksDict {
            guard let groups = value as? [[String: Any]] else { continue }
            for group in groups where groupContainsOwnedCommand(group) {
                return true
            }
        }
        return false
    }

    private func groupContainsOwnedCommand(_ group: [String: Any]) -> Bool {
        guard let entries = group["hooks"] as? [[String: Any]] else { return false }
        return entries.contains { entry in
            guard let command = entry["command"] as? String else { return false }
            return commandIsOwned(command)
        }
    }

    private func readSettings(at url: URL) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: url.path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    /// Returns nil if the file doesn't exist; throws if it exists but isn't a JSON object.
    private func readOrThrow(at url: URL) throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [:] }
        let parsed = try JSONSerialization.jsonObject(with: data)
        guard let object = parsed as? [String: Any] else {
            throw AgentHookInstallerError.notAJSONObject(url)
        }
        return object
    }

    private func ensureParentDirectory(for url: URL) throws {
        let dir = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    private func writeSettings(_ settings: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
    }
}

enum AgentHookInstallerError: Error, LocalizedError {
    case notAJSONObject(URL)

    var errorDescription: String? {
        switch self {
        case let .notAJSONObject(url):
            "Settings file at \(url.path) is not a JSON object."
        }
    }
}
