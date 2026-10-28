// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation
import TowerKit
import AgentriseScene

/// Adds or removes Agentrise's async hooks in ~/.claude/settings.json and ~/.codex/hooks.json, and nothing else.
/// The JSON merging is `HookFile` / `HookPlan`; this side knows the Mac's paths and the app bundle.
enum HookInstaller {
    static let settingsURL = HookPlan.claudeSettingsURL(home: FileManager.default.homeDirectoryForCurrentUser)

    /// `$CODEX_HOME` when set, else ~/.codex.
    static func codexHome(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        HookPlan.codexHome(env: env, home: FileManager.default.homeDirectoryForCurrentUser)
    }

    static let claude = HookPlan.claude(home: FileManager.default.homeDirectoryForCurrentUser)
    static let codex = HookPlan.codex(codexHome: codexHome())

    static func entry(hookPath: String) -> [String: Any] { claude.entry(hookPath: hookPath) }

    static func read(_ url: URL = settingsURL) throws -> (obj: [String: Any], raw: Data?) {
        try HookFile(url: url, events: claude.events, command: claude.command, backupTag: claude.backupTag).read()
    }

    static func merged(_ settings: [String: Any], hookPath: String) throws -> [String: Any] {
        try claude.merged(settings, hookPath: hookPath)
    }

    static func removed(_ settings: [String: Any]) throws -> [String: Any] { try claude.removed(settings) }

    static func isInstalled() -> Bool { claude.isInstalled() }

    /// Copies the helper out of the app bundle to a stable path.
    static func installHelper() throws -> String {
        let dest = TowerPaths.hookBinaryURL()
        let candidates = [Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/agentrise-hook"),
                          Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("agentrise-hook")]
        guard let src = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { throw InstallerError.missingHelper }
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: src, to: dest)
        chmod(dest.path, 0o755)
        return dest.path
    }

    static func preview() throws -> String { try claude.preview(hookPath: TowerPaths.hookBinaryURL().path) }

    @discardableResult
    static func install() throws -> URL? {
        let path = try installHelper()
        return try claude.install(hookPath: path)
    }

    static func uninstall() throws { try claude.uninstall() }

    /// Codex: copies the helper, then merges into hooks.json. Codex still has to trust the hooks (`CodexAppServer`).
    @discardableResult
    static func installCodex() throws -> URL? {
        let path = try installHelper()
        return try codex.install(hookPath: path)
    }

    static func previewCodex() throws -> String { try codex.preview(hookPath: TowerPaths.hookBinaryURL().path) }
}
