// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT
//
// Agentrise.exe: the Windows app (see `WinApp` in AgentriseWin, and AppOptions for the command line).

#if os(Windows)
import Foundation
import WinSDK
import AgentriseWin

// Before any window: Per-Monitor V2 DPI awareness (the manifest's, or set here if it's missing).
let dpiAwareness = Startup.ensureDpiAwareness()
// The UI thread is a single-threaded apartment (shell, tray and dialogs need one); art baking on this thread stays
// in it (D2DArtBackend.joinCOM keeps an existing apartment).
_ = OleInitialize(nil)

let options = AppOptions.parse(CommandLine.arguments)
let paths = AppPaths(dataDir: options.dataDir)
try? FileManager.default.createDirectory(at: paths.support, withIntermediateDirectories: true)
Log.file = paths.logFile
Log.write("Agentrise \(AppInfo.version) start: \(CommandLine.arguments.dropFirst().joined(separator: " "))")
Log.write("startup: \(dpiAwareness); comctl32 \(Startup.comctl32Version() ?? "unknown")")

if let agent = options.installHooks {
    // Installs hooks without asking (CI's smoke test, scripts); independent of a running instance.
    exit(HookCommandLine.run(agent, paths: paths))
}

if options.smokeSecond {
    // Only the single-instance check (secondInstanceDefersToFirst, CI): defer to a running instance, or say there is none.
    if SingleInstance.acquire() == nil {
        let signalled = SingleInstance.signalFirstInstance(timeout: options.retry)
        Log.write("smoke-second: another instance runs (window \(signalled ? "signalled" : "not found")); exiting")
        exit(0)
    }
    Log.write("smoke-second: no other instance")
    exit(3)
}

guard let instance = SingleInstance.acquire() else {
    // Agentrise already runs: bring its window forward and leave.
    let signalled = SingleInstance.signalFirstInstance(timeout: options.retry)
    Log.write("second instance: \(signalled ? "showed the running one" : "the running one has no window yet"); exiting")
    exit(0)
}

let app = WinApp(options: options, paths: paths, instance: instance)
exit(app.run())
#else
// Agentrise.exe is Windows only; on macOS the app is AgentriseApp.
#endif
