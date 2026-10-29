// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import TowerKit

@Suite struct PortableProcessTests {
    @Test func ancestryFindsTheCurrentProcessByName() {
        let me = ProcessInfo.processInfo.processIdentifier
        let name = ProcessInfo.processInfo.processName
        #expect(ProcessAncestry.ancestor(named: String(name.prefix(8)), from: me) == me)
        #expect(ProcessAncestry.ancestor(named: "no-such-process", from: me) == nil)
    }

    @Test func parentPIDIsAnotherLiveProcess() {
        let p = ProcessAncestry.parentPID()
        #expect(p > 0)
        #expect(p != ProcessInfo.processInfo.processIdentifier)
    }

    #if os(Windows)
    @Test func windowsPathsFollowLocalAppData() {
        let env = ["LOCALAPPDATA": #"C:\Users\u\AppData\Local"#]
        #expect(TowerPaths.socketPath(environment: env).hasSuffix(#"AppData\Local\Agentrise\tower.sock"#))
        #expect(TowerPaths.hookBinaryURL(environment: env).lastPathComponent == "agentrise-hook.exe")
    }

    @Test func windowsPathsFallBackToUserProfile() {
        let env = ["USERPROFILE": #"C:\Users\u"#]
        #expect(TowerPaths.socketPath(environment: env).hasSuffix(#"Users\u\AppData\Local\Agentrise\tower.sock"#))
    }

    @Test func argumentsOfAChildProcess() throws {
        let child = Process()
        // ping itself rather than through cmd.exe, so terminating the child leaves no grandchild running.
        let root = ProcessInfo.processInfo.environment["SystemRoot"] ?? #"C:\Windows"#
        child.executableURL = URL(fileURLWithPath: root + #"\System32\PING.EXE"#)
        child.arguments = ["-n", "3", "127.0.0.1"]
        child.standardOutput = FileHandle.nullDevice
        try child.run()
        defer { child.terminate(); child.waitUntilExit() }
        let args = try #require(ProcessAncestry.arguments(of: child.processIdentifier))
        #expect(args.contains("-n"))
        #expect(args.contains("3"))
    }

    @Test func argumentsOfAnExitedProcessOrPidZeroAreNil() throws {
        let pid: Int32 = try {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: Self.systemRoot + #"\System32\cmd.exe"#)
            child.arguments = ["/d", "/c", "exit", "0"]
            try child.run()
            child.waitUntilExit()
            return child.processIdentifier
        }()
        #expect(ProcessAncestry.arguments(of: pid) == nil)
        #expect(ProcessAncestry.arguments(of: 0) == nil)
    }

    @Test func argumentWithSpacesQuotesAndChineseRoundTrips() throws {
        // cmd.exe /k stays alive reading its stdin, which this test holds open; `rem` ignores the argument.
        let tricky = #"say "hi" 你好 世界"#
        let child = Process()
        child.executableURL = URL(fileURLWithPath: Self.systemRoot + #"\System32\cmd.exe"#)
        child.arguments = ["/d", "/q", "/k", "rem", tricky]
        let input = Pipe()
        child.standardInput = input
        child.standardOutput = FileHandle.nullDevice
        try child.run()
        defer { child.terminate(); child.waitUntilExit() }
        let args = try #require(ProcessAncestry.arguments(of: child.processIdentifier))
        #expect(Array(args.dropFirst()) == ["/d", "/q", "/k", "rem", tricky])
    }

    private static var systemRoot: String { ProcessInfo.processInfo.environment["SystemRoot"] ?? #"C:\Windows"# }
    #endif
}
