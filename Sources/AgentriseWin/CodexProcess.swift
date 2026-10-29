// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

#if os(Windows)
import Foundation
import WinSDK
import Agentrise
import AgentriseScene

/// How to start Codex on this machine (facts §5).
package enum CodexLaunch: Equatable {
    /// A real `codex.exe`, started directly.
    case exe(String)
    /// Only npm's `codex.cmd` shim: `cmd.exe /d /s /c ""<shim>" <args>"` (CreateProcess can't start a .cmd).
    case cmdShim(String)

    /// Looks, in order, for the standalone `codex.exe` (on `PATH`, then the installer's
    /// `%LOCALAPPDATA%\Programs\OpenAI\Codex\bin` and `%USERPROFILE%\.codex\packages\standalone\current\bin`), npm's
    /// vendored `codex.exe`, and last npm's `codex.cmd` on `PATH`. `isFile` is injectable for tests.
    package static func locate(env: [String: String] = ProcessInfo.processInfo.environment,
                               isFile: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> CodexLaunch? {
        func v(_ name: String) -> String? {
            env.first { $0.key.uppercased() == name }?.value.trimmingCharacters(in: .whitespaces).nilIfEmpty
        }
        func join(_ dir: String, _ rest: String) -> String {
            var d = dir
            while d.hasSuffix("\\") || d.hasSuffix("/") { d.removeLast() }
            return d + "\\" + rest
        }
        let pathDirs = (v("PATH") ?? "").split(separator: ";").map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }
            .filter { !$0.isEmpty }
        var exes = pathDirs.map { join($0, "codex.exe") }
        if let local = v("LOCALAPPDATA") { exes.append(join(local, "Programs\\OpenAI\\Codex\\bin\\codex.exe")) }
        if let profile = v("USERPROFILE") { exes.append(join(profile, ".codex\\packages\\standalone\\current\\bin\\codex.exe")) }
        if let roaming = v("APPDATA") {
            exes.append(join(roaming, "npm\\node_modules\\@openai\\codex\\node_modules\\@openai\\codex-win32-x64\\vendor\\x86_64-pc-windows-msvc\\bin\\codex.exe"))
        }
        if let exe = exes.first(where: isFile) { return .exe(exe) }
        if let shim = pathDirs.map({ join($0, "codex.cmd") }).first(where: isFile) { return .cmdShim(shim) }
        return nil
    }

    /// The application CreateProcess starts and its full command line.
    package func commandLine(_ arguments: [String], comSpec: String? = nil) -> (application: String, line: String) {
        switch self {
        case .exe(let exe):
            return (exe, ([exe] + arguments).map(CodexProcess.quoted).joined(separator: " "))
        case .cmdShim(let shim):
            let cmd = comSpec ?? "C:\\Windows\\System32\\cmd.exe"
            // /s: cmd strips the outer quotes and runs the rest as written.
            let inner = ([shim] + arguments).map(CodexProcess.quoted).joined(separator: " ")
            return (cmd, "\(CodexProcess.quoted(cmd)) /d /s /c \"\(inner)\"")
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// `codex app-server` (or any child speaking line-delimited JSON-RPC on stdio), started without a console window.
///
/// - Only its three pipe ends are inherited (`PROC_THREAD_ATTRIBUTE_HANDLE_LIST`), so it never holds a file the app
///   is replacing (see `SafeFile`).
/// - It runs in a job object with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`: closing the job (in `close()`, or Windows
///   closing it when the app dies, however it dies) ends it and everything it started (`cmd.exe → node.exe →
///   codex.exe` for npm's shim).
/// - Every call shares one overall deadline, like the macOS `StdioRPC`.
package final class CodexProcess: RPCTransport {
    package let pid: UInt32
    private let process: HANDLE
    private let job: HANDLE
    private var stdinWrite: HANDLE?
    private let stdoutRead: HANDLE
    private let cond = NSCondition()
    private var buffer = Data()
    private var lines: [Data] = []
    private var eof = false
    private let readerDone = DispatchSemaphore(value: 0)
    private let deadline: Date
    private var nextId = 1
    private var closed = false

    package struct SpawnFailure: LocalizedError {
        package let step: String
        package let code: DWORD
        package var errorDescription: String? { "无法启动 codex（\(step)，Win32 错误 \(code)）" }
    }

    /// Starts `application` with the full `commandLine`, `environment` replacing the app's (nil: inherit).
    package init(application: String, commandLine: String, environment: [String: String]? = nil, timeout: TimeInterval = 15) throws {
        deadline = Date().addingTimeInterval(timeout)
        var sa = SECURITY_ATTRIBUTES(nLength: DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size), lpSecurityDescriptor: nil, bInheritHandle: true)
        var inRead: HANDLE?, inWrite: HANDLE?, outRead: HANDLE?, outWrite: HANDLE?
        guard CreatePipe(&inRead, &inWrite, &sa, 0) else { throw SpawnFailure(step: "CreatePipe", code: GetLastError()) }
        guard CreatePipe(&outRead, &outWrite, &sa, 0) else {
            let e = GetLastError(); CloseHandle(inRead); CloseHandle(inWrite)
            throw SpawnFailure(step: "CreatePipe", code: e)
        }
        // The app's ends stay in the app.
        SetHandleInformation(inWrite, DWORD(HANDLE_FLAG_INHERIT), 0)
        SetHandleInformation(outRead, DWORD(HANDLE_FLAG_INHERIT), 0)
        let nul = withWide("NUL") {
            CreateFileW($0, DWORD(0x4000_0000) /* GENERIC_WRITE */, DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE), &sa,
                        DWORD(OPEN_EXISTING), 0, nil)
        }
        func closeChildEnds() {
            CloseHandle(inRead); CloseHandle(outWrite)
            if let nul, nul != INVALID_HANDLE_VALUE { CloseHandle(nul) }
        }
        func fail(_ step: String) -> SpawnFailure {
            let e = GetLastError()
            closeChildEnds(); CloseHandle(inWrite); CloseHandle(outRead)
            return SpawnFailure(step: step, code: e)
        }
        guard let nul, nul != INVALID_HANDLE_VALUE else { throw fail("NUL") }

        // Inherit exactly these three handles.
        var attrSize: SIZE_T = 0
        _ = InitializeProcThreadAttributeList(nil, 1, 0, &attrSize)
        let attrMemory = UnsafeMutableRawPointer.allocate(byteCount: Int(attrSize), alignment: 16)
        defer { attrMemory.deallocate() }
        let attrs = LPPROC_THREAD_ATTRIBUTE_LIST(attrMemory)
        guard InitializeProcThreadAttributeList(attrs, 1, 0, &attrSize) else { throw fail("InitializeProcThreadAttributeList") }
        defer { DeleteProcThreadAttributeList(attrs) }
        let inherited = UnsafeMutablePointer<HANDLE?>.allocate(capacity: 3)
        defer { inherited.deallocate() }
        inherited[0] = inRead; inherited[1] = outWrite; inherited[2] = nul
        let handleList = DWORD_PTR(0x0002_0002)   // PROC_THREAD_ATTRIBUTE_HANDLE_LIST
        guard UpdateProcThreadAttribute(attrs, 0, handleList, inherited, SIZE_T(MemoryLayout<HANDLE?>.stride * 3), nil, nil) else {
            throw fail("UpdateProcThreadAttribute")
        }

        var si = STARTUPINFOEXW()
        si.StartupInfo.cb = DWORD(MemoryLayout<STARTUPINFOEXW>.size)
        si.StartupInfo.dwFlags = DWORD(STARTF_USESTDHANDLES)
        si.StartupInfo.hStdInput = inRead
        si.StartupInfo.hStdOutput = outWrite
        si.StartupInfo.hStdError = nul
        si.lpAttributeList = attrs
        var pi = PROCESS_INFORMATION()
        var line = Array(commandLine.utf16) + [0]
        var envBlock = environment.map(Self.environmentBlock)
        let flags = DWORD(CREATE_NO_WINDOW) | DWORD(EXTENDED_STARTUPINFO_PRESENT) | DWORD(CREATE_SUSPENDED) | DWORD(CREATE_UNICODE_ENVIRONMENT)
        let started: Bool = withWide(application) { app in
            withUnsafeMutablePointer(to: &si) { ex in
                ex.withMemoryRebound(to: STARTUPINFOW.self, capacity: 1) { startup in
                    if envBlock != nil {
                        return envBlock!.withUnsafeMutableBytes {
                            CreateProcessW(app, &line, nil, nil, true, flags, $0.baseAddress, nil, startup, &pi)
                        }
                    }
                    return CreateProcessW(app, &line, nil, nil, true, flags, nil, nil, startup, &pi)
                }
            }
        }
        guard started else { throw fail("CreateProcessW") }
        closeChildEnds()
        envBlock = nil

        // The job: it dies with the app.
        guard let job = CreateJobObjectW(nil, nil) else {
            let e = GetLastError()
            TerminateProcess(pi.hProcess, 1); CloseHandle(pi.hThread); CloseHandle(pi.hProcess)
            CloseHandle(inWrite); CloseHandle(outRead)
            throw SpawnFailure(step: "CreateJobObjectW", code: e)
        }
        var limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
        limits.BasicLimitInformation.LimitFlags = DWORD(JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE)
        let limited = SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits,
                                              DWORD(MemoryLayout<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>.size))
        guard limited, AssignProcessToJobObject(job, pi.hProcess) else {
            let e = GetLastError()
            TerminateProcess(pi.hProcess, 1); CloseHandle(pi.hThread); CloseHandle(pi.hProcess); CloseHandle(job)
            CloseHandle(inWrite); CloseHandle(outRead)
            throw SpawnFailure(step: "AssignProcessToJobObject", code: e)
        }
        ResumeThread(pi.hThread)
        CloseHandle(pi.hThread)
        self.job = job
        process = pi.hProcess!
        pid = pi.dwProcessId
        stdinWrite = inWrite
        stdoutRead = outRead!

        // Holds the process object until the pipe ends (the child exited or `close()` ended it).
        let reader = Thread { self.readLoop() }
        reader.name = "codex app-server stdout"
        reader.start()
    }

    /// Starts `codex app-server` (or `arguments`) the way `launch` says.
    package convenience init(launch: CodexLaunch, arguments: [String] = ["app-server"], environment: [String: String]? = nil,
                             timeout: TimeInterval = 15) throws {
        let env = environment ?? ProcessInfo.processInfo.environment
        let comSpec = env.first { $0.key.uppercased() == "COMSPEC" }?.value
        let (app, line) = launch.commandLine(arguments, comSpec: comSpec)
        try self.init(application: app, commandLine: line, environment: environment, timeout: timeout)
    }

    deinit { close() }

    /// `initialize`, then the `initialized` notification.
    package func handshake(version: String) throws {
        _ = try call("initialize", ["clientInfo": ["name": "agentrise", "version": version]])
        try send(["jsonrpc": "2.0", "method": "initialized"])
    }

    package func call(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        let id = nextId; nextId += 1
        try send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        while true {
            let line = try nextLine()
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  (obj["id"] as? NSNumber)?.intValue == id, obj["method"] == nil else { continue }
            if let err = obj["error"] {
                throw CodexRPCError.rpc(((err as? [String: Any])?["message"] as? String) ?? "\(err)")
            }
            if let r = obj["result"] as? [String: Any] { return r }
            if obj["result"] is NSNull { return [:] }
            throw CodexRPCError.unexpectedResponse
        }
    }

    /// Ends the server: its stdin closes, then after up to a second the job (and with it every process in it) is
    /// closed. Safe to call twice.
    package func close() {
        guard !closed else { return }
        closed = true
        if let w = stdinWrite { CloseHandle(w); stdinWrite = nil }
        _ = WaitForSingleObject(process, 1000)
        TerminateJobObject(job, 1)
        CloseHandle(job)   // KILL_ON_JOB_CLOSE, in case termination was refused
        // The reader ends once every write end of its pipe is gone (the child's went with it).
        if readerDone.wait(timeout: .now() + 2) == .success { CloseHandle(stdoutRead) }
        CloseHandle(process)
    }

    private func send(_ obj: [String: Any]) throws {
        guard let w = stdinWrite else { throw CodexRPCError.closed }
        let d = try JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) + Data("\n".utf8)
        let ok = d.withUnsafeBytes { buf -> Bool in
            var offset = 0
            while offset < buf.count {
                var n: DWORD = 0
                guard WriteFile(w, buf.baseAddress! + offset, DWORD(buf.count - offset), &n, nil), n > 0 else { return false }
                offset += Int(n)
            }
            return true
        }
        if !ok { throw CodexRPCError.closed }
    }

    private func readLoop() {
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            var n: DWORD = 0
            let ok = chunk.withUnsafeMutableBytes { ReadFile(stdoutRead, $0.baseAddress, DWORD($0.count), &n, nil) }
            cond.lock()
            if !ok || n == 0 {
                eof = true
                cond.broadcast()
                cond.unlock()
                break
            }
            buffer.append(contentsOf: chunk[0..<Int(n)])
            while let nl = buffer.firstIndex(of: 0x0A) {
                var line = buffer.subdata(in: buffer.startIndex..<nl)
                if line.last == 0x0D { line.removeLast() }
                lines.append(line)
                buffer.removeSubrange(buffer.startIndex...nl)
            }
            cond.broadcast()
            cond.unlock()
        }
        readerDone.signal()
    }

    private func nextLine() throws -> Data {
        cond.lock(); defer { cond.unlock() }
        while lines.isEmpty {
            if eof { throw CodexRPCError.closed }
            if !cond.wait(until: deadline), lines.isEmpty, !eof { throw CodexRPCError.timedOut }
        }
        return lines.removeFirst()
    }

    /// One argument as `CommandLineToArgvW` (and the C runtime) reads it back.
    package static func quoted(_ arg: String) -> String {
        if !arg.isEmpty, !arg.contains(where: { " \t\n\u{0B}\"".contains($0) }) { return arg }
        var out = "\""
        var slashes = 0
        for c in arg {
            if c == "\\" { slashes += 1; continue }
            if c == "\"" {
                out += String(repeating: "\\", count: slashes * 2 + 1) + "\""
            } else {
                out += String(repeating: "\\", count: slashes) + String(c)
            }
            slashes = 0
        }
        return out + String(repeating: "\\", count: slashes * 2) + "\""
    }

    /// `KEY=value\0…\0\0` in UTF-16, sorted case-insensitively as Windows expects.
    static func environmentBlock(_ env: [String: String]) -> [UInt16] {
        var out: [UInt16] = []
        for (k, v) in env.sorted(by: { $0.key.uppercased() < $1.key.uppercased() }) where !k.isEmpty && !k.contains("=") {
            out += Array("\(k)=\(v)".utf16) + [0]
        }
        return out + [0]
    }
}

extension CodexAppServer {
    /// Starts `codex app-server` for these paths (Codex's home is passed as `CODEX_HOME`, so a `--data-dir` run asks
    /// about its own hooks.json), runs `body`, and always ends the server. Blocks: call it off the UI thread.
    package static func withLocal<T>(paths: AppPaths, timeout: TimeInterval = 15,
                                     locate: () -> CodexLaunch? = { CodexLaunch.locate() },
                                     _ body: (CodexAppServer) throws -> T) throws -> T {
        guard let launch = locate() else { throw CodexRPCError.binaryNotFound }
        var env = ProcessInfo.processInfo.environment
        for k in env.keys where k.uppercased() == "CODEX_HOME" { env[k] = nil }
        env["CODEX_HOME"] = SafeFile.nativePath(of: paths.codexHome)
        let rpc = try CodexProcess(launch: launch, environment: env, timeout: timeout)
        defer { rpc.close() }
        try rpc.handshake(version: AppInfo.version)
        return try body(CodexAppServer(transport: rpc, hooksFile: paths.codexHooks, cwd: SafeFile.nativePath(of: paths.home)))
    }
}
#endif
