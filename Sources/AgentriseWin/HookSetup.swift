// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

#if os(Windows)
import Foundation
import WinSDK
import TowerKit
import Agentrise
import AgentriseScene

/// The DLL names a PE image (exe or DLL) imports: its import directory, then its delay-load directory, in order,
/// as written in the file. Nil when the data isn't a PE image.
package enum PEImports {
    package static func dlls(in d: Data) -> [String]? {
        let b = [UInt8](d)
        func u16(_ o: Int) -> Int? { o >= 0 && o + 2 <= b.count ? Int(b[o]) | Int(b[o + 1]) << 8 : nil }
        func u32(_ o: Int) -> Int? {
            guard o >= 0, o + 4 <= b.count else { return nil }
            return Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24
        }
        guard u16(0) == 0x5A4D, let pe = u32(0x3C), u32(pe) == 0x0000_4550,   // "MZ", "PE\0\0"
              let sections = u16(pe + 6), let optSize = u16(pe + 20) else { return nil }
        let opt = pe + 24
        let dirs: Int
        switch u16(opt) {
        case 0x20B: dirs = opt + 112   // PE32+
        case 0x10B: dirs = opt + 96    // PE32
        default: return nil
        }
        // RVA → file offset through the section table.
        let table = opt + optSize
        func offset(_ rva: Int) -> Int? {
            for i in 0..<sections {
                let s = table + i * 40
                guard let vsize = u32(s + 8), let va = u32(s + 12), let rawSize = u32(s + 16), let raw = u32(s + 20) else { return nil }
                if rva >= va, rva < va + max(vsize, rawSize) { return rva - va + raw }
            }
            return nil
        }
        func cString(_ rva: Int) -> String? {
            guard let o = offset(rva), o < b.count else { return nil }
            let end = b[o...].firstIndex(of: 0) ?? b.count
            return String(decoding: b[o..<end], as: UTF8.self)
        }
        var out: [String] = []
        // IMAGE_DIRECTORY_ENTRY_IMPORT (1): 20-byte descriptors, the name RVA at +12, ended by an all-zero one.
        if let rva = u32(dirs + 8), rva != 0, var o = offset(rva) {
            while let name = u32(o + 12), let first = u32(o + 16), name != 0 || first != 0 {
                if name != 0, let s = cString(name) { out.append(s) }
                o += 20
            }
        }
        // IMAGE_DIRECTORY_ENTRY_DELAY_IMPORT (13): 32-byte descriptors, the name RVA at +4.
        if let rva = u32(dirs + 13 * 8), rva != 0, var o = offset(rva) {
            while let name = u32(o + 4), name != 0 {
                if let s = cString(name) { out.append(s) }
                o += 32
            }
        }
        return out
    }
}

/// The files an exe needs besides the system's. Task 14's packaging uses the same function.
package enum RuntimeFiles {
    /// `exes` plus every DLL they import, transitively, that is found in `searchDirs` (the first directory that has
    /// it). A DLL found in none of them is the system's (kernel32, the UCRT's api-ms-win-* sets, the VC++ runtime
    /// installed with Windows) and is left out. Order: the exes, then DLLs as discovered.
    ///
    /// For the hook in a packaged build the search directory is the exe's own (the Swift runtime and Foundation DLLs
    /// sit next to `Agentrise.exe`); on a development machine those come from the toolchain on `PATH`, are not next
    /// to the exe, and the list is just the exe.
    package static func closure(of exes: [URL], searchDirs: [URL]) -> [URL] {
        var out = exes
        var seen = Set(exes.map { $0.lastPathComponent.lowercased() })
        var queue = exes
        while !queue.isEmpty {
            let file = queue.removeFirst()
            guard let data = try? Data(contentsOf: file), let names = PEImports.dlls(in: data) else { continue }
            for name in names where seen.insert(name.lowercased()).inserted {
                guard let found = searchDirs.map({ $0.appendingPathComponent(name) })
                    .first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { continue }
                out.append(found)
                queue.append(found)
            }
        }
        return out
    }
}

/// Copies `agentrise-hook.exe` and the DLLs it needs from next to `Agentrise.exe` to `%LOCALAPPDATA%\Agentrise\bin\`
/// (spec §5.9), so the hooks keep working when the user moves or deletes the unzipped folder.
///
/// A file is copied only when the destination's bytes differ (an upgrade, or a downgrade). A hook that is running at
/// that moment keeps its exe and DLLs open, and Windows won't overwrite an image in use, but it does let one be
/// renamed: the old file is moved aside (`<name>.old-<id>`, deleted on a later run) and the new one moved in. Every
/// failure after the old file was moved aside moves it back, so `bin\` never loses a file; a file that could not be
/// replaced counts as locked and the caller tries again later. A crash in between leaves only `<name>.old-<id>`,
/// which the next run moves back before anything else.
package struct HookHelperFiles {
    package static let hookExe = "agentrise-hook.exe"

    /// The file operations a replace is made of (tests inject failures).
    package struct FileOps {
        /// `CopyFileW` (its handles are not inheritable).
        package var copy: (_ from: String, _ to: String) -> Bool = { f, t in withWide(f) { s in withWide(t) { CopyFileW(s, $0, false) } } }
        /// `MoveFileExW` with `WRITE_THROUGH`, and `REPLACE_EXISTING` when `replace`.
        package var move: (_ from: String, _ to: String, _ replace: Bool) -> Bool = { f, t, replace in
            let flags = DWORD(MOVEFILE_WRITE_THROUGH) | (replace ? DWORD(MOVEFILE_REPLACE_EXISTING) : 0)
            return withWide(f) { s in withWide(t) { MoveFileExW(s, $0, flags) } }
        }
        package var delete: (String) -> Bool = { p in withWide(p) { DeleteFileW($0) } }
        package init() {}
    }

    /// Where `Agentrise.exe` (and so `agentrise-hook.exe`) is.
    package let sourceDir: URL
    package let binDir: URL
    package var ops = FileOps()

    package init(sourceDir: URL, binDir: URL) { self.sourceDir = sourceDir; self.binDir = binDir }

    /// The directory of this process's exe.
    package static func appDir() -> URL { URL(fileURLWithPath: Autostart.currentExe()).deletingLastPathComponent() }

    package var source: URL { sourceDir.appendingPathComponent(Self.hookExe) }
    package var installed: URL { binDir.appendingPathComponent(Self.hookExe) }
    /// The path written into the agents' hook entries.
    package var hookPath: String { SafeFile.nativePath(of: installed) }

    /// The hook and its DLLs next to the app (`RuntimeFiles.closure`, searched in the app's directory only).
    package func files() -> [URL] { RuntimeFiles.closure(of: [source], searchDirs: [sourceDir]) }

    package struct Result: Equatable {
        package var copied: [String] = []
        package var locked: [String] = []
        package var upToDate: Bool { copied.isEmpty && locked.isEmpty }
    }

    /// Brings `bin\` up to date. Throws `InstallerError.missingHelper` when the app has no hook next to it.
    @discardableResult
    package func sync() throws -> Result {
        guard FileManager.default.fileExists(atPath: source.path) else { throw InstallerError.missingHelper }
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        recoverAndClean()
        var r = Result()
        for f in files() {
            let dest = binDir.appendingPathComponent(f.lastPathComponent)
            if Self.sameBytes(f, dest) { continue }
            if replace(dest, with: f) { r.copied.append(f.lastPathComponent) } else { r.locked.append(f.lastPathComponent) }
        }
        return r
    }

    /// Whether the hook was installed before: it is in `bin\`, or only its moved-aside copy is (a crash mid-replace).
    package var wasInstalled: Bool {
        if FileManager.default.fileExists(atPath: installed.path) { return true }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: binDir.path)) ?? []
        return names.contains { $0.hasPrefix(Self.hookExe + ".old-") }
    }

    /// At app start: only when the hook was installed before, bring it up to date. Nil when nothing is installed.
    /// Throws what `sync` throws (the caller retries).
    package func refreshIfInstalled() throws -> Result? {
        guard wasInstalled else { return nil }
        return try sync()
    }

    static func sameBytes(_ a: URL, _ b: URL) -> Bool {
        let fm = FileManager.default
        guard let sa = (try? fm.attributesOfItem(atPath: a.path))?[.size] as? NSNumber,
              let sb = (try? fm.attributesOfItem(atPath: b.path))?[.size] as? NSNumber, sa == sb else { return false }
        return (try? Data(contentsOf: a)) == (try? Data(contentsOf: b))
    }

    /// Copies `src` next to `dest`, then moves it over `dest`; when `dest` is in use, moves `dest` aside first. On any
    /// failure `dest` is as it was (moved back if it had been moved aside) and the temporary copy is gone.
    func replace(_ dest: URL, with src: URL) -> Bool {
        let d = SafeFile.nativePath(of: dest)
        let tmp = d + ".new-" + UUID().uuidString.prefix(8)
        guard ops.copy(SafeFile.nativePath(of: src), tmp) else { _ = ops.delete(tmp); return false }
        if ops.move(tmp, d, true) { return true }
        let aside = d + ".old-" + UUID().uuidString.prefix(8)
        guard ops.move(d, aside, false) else { _ = ops.delete(tmp); return false }
        if ops.move(tmp, d, true) { return true }
        // Roll back: the old file goes back where it was.
        if !ops.move(aside, d, false) { _ = ops.move(aside, d, true) }
        _ = ops.delete(tmp)
        return false
    }

    /// A file only found moved aside (a crash between the two moves) goes back; then old copies an update moved aside
    /// and temporary copies are deleted (those still in use stay until a later run).
    private func recoverAndClean() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: binDir.path)) ?? []
        let dir = SafeFile.nativePath(of: binDir)
        for n in names where n.contains(".old-") {
            let original = String(n[..<n.range(of: ".old-")!.lowerBound])
            if !FileManager.default.fileExists(atPath: binDir.appendingPathComponent(original).path) {
                _ = ops.move(dir + "\\" + n, dir + "\\" + original, false)
            }
        }
        let left = (try? FileManager.default.contentsOfDirectory(atPath: binDir.path)) ?? []
        for n in left where n.contains(".old-") || n.contains(".new-") { _ = ops.delete(dir + "\\" + n) }
    }
}

/// Installing Agentrise's hooks on Windows: the helper into `bin\`, then the agents' JSON through the shared
/// `HookFile` (preview first, a backup per macOS's naming, only Agentrise's own entries added or removed).
package struct WinHookInstaller {
    package let paths: AppPaths
    package let helper: HookHelperFiles

    package init(paths: AppPaths, sourceDir: URL = HookHelperFiles.appDir()) {
        self.paths = paths
        helper = HookHelperFiles(sourceDir: sourceDir, binDir: paths.binDir)
    }

    /// Claude Code: `%USERPROFILE%\.claude\settings.json`, exec form (facts §2, §3).
    package var claude: HookFile { HookPlan.claude(settings: paths.claudeSettings, platform: .windows(.exec)) }
    /// Codex: `%USERPROFILE%\.codex\hooks.json`, `commandWindows` (facts §4).
    package var codex: HookFile { HookPlan.codex(codexHome: paths.codexHome, platform: .windows(.exec)) }

    package func file(_ agent: AgentKind) -> HookFile { agent == .codex ? codex : claude }

    /// Whether Codex is on this machine (its home exists), as macOS Settings decides whether to show it.
    package var codexPresent: Bool { FileManager.default.fileExists(atPath: paths.codexHome.path) }

    package func isInstalled(_ agent: AgentKind) -> Bool { file(agent).isInstalled() }

    /// The file as it will be after installing.
    package func preview(_ agent: AgentKind) throws -> String { try file(agent).preview(hookPath: helper.hookPath) }

    package struct HelperLocked: LocalizedError {
        package var errorDescription: String? { "agentrise-hook 正在运行，没能更新它，请稍后再试" }
    }

    package struct CodexMissing: LocalizedError {
        package let codexHome: String
        package var errorDescription: String? { "这台电脑上没有 Codex（找不到 \(codexHome)），没有写入 hooks.json" }
    }

    /// Copies the helper, then merges the entries in. Returns the backup of the previous file, if there was one.
    /// Codex's hooks are only written where Codex is (its home exists): its home is never created.
    @discardableResult
    package func install(_ agent: AgentKind) throws -> URL? {
        if agent == .codex, !codexPresent { throw CodexMissing(codexHome: SafeFile.nativePath(of: paths.codexHome)) }
        let r = try helper.sync()
        // A hook still running keeps an old copy only if it could not even be moved aside; with no copy at all the
        // entries would point at nothing.
        if !r.locked.isEmpty, !FileManager.default.fileExists(atPath: helper.installed.path) { throw HelperLocked() }
        try FileManager.default.createDirectory(at: file(agent).url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try file(agent).install(hookPath: helper.hookPath)
    }

    package func uninstall(_ agent: AgentKind) throws { try file(agent).uninstall() }
}
#endif
