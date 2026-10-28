// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation
#if canImport(Darwin)
import Darwin
#elseif os(Windows)
import WinSDK
#endif

public enum TowerPaths {
#if os(Windows)
    /// `%LOCALAPPDATA%\Agentrise`, or `%USERPROFILE%\AppData\Local\Agentrise` when that isn't set.
    private static func supportPath(_ environment: [String: String]) -> String {
        var base: String
        if let local = environment["LOCALAPPDATA"], !local.isEmpty {
            base = local
        } else {
            var profile = environment["USERPROFILE"] ?? ""
            if profile.isEmpty { profile = NSHomeDirectory() }
            while profile.hasSuffix("\\") || profile.hasSuffix("/") { profile.removeLast() }
            base = profile + "\\AppData\\Local"
        }
        while base.hasSuffix("\\") || base.hasSuffix("/") { base.removeLast() }
        return base + "\\Agentrise"
    }
    public static func supportDir(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        URL(fileURLWithPath: supportPath(environment), isDirectory: true)
    }
    public static func socketPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        supportPath(environment) + "\\tower.sock"
    }
    public static func hookBinaryURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        URL(fileURLWithPath: supportPath(environment) + "\\bin\\agentrise-hook.exe")
    }
#else
    public static func supportDir(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/Agentrise", isDirectory: true)
    }
    public static func socketPath(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        supportDir(home: home).appendingPathComponent("tower.sock").path
    }
    public static func hookBinaryURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        supportDir(home: home).appendingPathComponent("bin/agentrise-hook")
    }
#endif
}

#if os(Windows)
// Winsock values spelled out here: their headers define them through macros Swift may not import.
private let afUnix: Int32 = 1                                  // AF_UNIX, ws2def.h
private let sockStream: Int32 = 1                              // SOCK_STREAM
private let solSocket: Int32 = 0xffff                          // SOL_SOCKET
private let soError: Int32 = 0x1007                            // SO_ERROR
private let fionbio = Int32(bitPattern: 0x8004_667E)           // FIONBIO = _IOW('f', 126, u_long)
private let pollOut: Int16 = 0x0010                            // POLLOUT = POLLWRNORM
private let pollErrOrHup: Int16 = 0x0001 | 0x0002              // POLLERR | POLLHUP
private let wsaWouldBlock: Int32 = 10035                       // WSAEWOULDBLOCK
private let invalidSocket = SOCKET.max                         // INVALID_SOCKET = ~0
/// `sizeof(sockaddr_un)` from afunix.h: `ADDRESS_FAMILY sun_family` + `char sun_path[108]`.
private let sunPathOffset = 2
private let sockaddrUnSize = sunPathOffset + 108

/// Winsock needs `WSAStartup` once per process before the first socket call.
private let winsockReady: Bool = {
    var data = WSADATA()
    return WSAStartup(0x0202, &data) == 0                      // MAKEWORD(2, 2)
}()

/// The bytes of an afunix.h `sockaddr_un` for `path`, written as UTF-8.
private func makeAddress(_ path: String) -> [UInt8]? {
    let bytes = Array(path.utf8)
    guard bytes.count < sockaddrUnSize - sunPathOffset else { return nil }
    var addr = [UInt8](repeating: 0, count: sockaddrUnSize)
    addr[0] = UInt8(afUnix & 0xff)                             // little-endian ADDRESS_FAMILY
    addr[1] = UInt8((afUnix >> 8) & 0xff)
    addr.replaceSubrange(sunPathOffset..<(sunPathOffset + bytes.count), with: bytes)
    return addr
}

private func withSockaddr<R>(_ addr: [UInt8], _ body: (UnsafePointer<sockaddr>, Int32) -> R) -> R {
    addr.withUnsafeBytes { raw in
        body(raw.baseAddress!.assumingMemoryBound(to: sockaddr.self), Int32(raw.count))
    }
}

/// Deletes a file (including an AF_UNIX socket's reparse-point file) by its native path.
private func deleteFile(_ path: String) {
    _ = path.withCString(encodedAs: UTF16.self) { DeleteFileW($0) }
}

public enum SocketClient {
    /// Sends one line and returns quickly whether or not anyone is listening.
    @discardableResult
    public static func send(_ line: Data, to path: String, timeoutMs: Int32 = 200) -> Bool {
        guard winsockReady, let addr = makeAddress(path) else { return false }
        let s = socket(afUnix, sockStream, 0)
        guard s != invalidSocket else { return false }
        defer { closesocket(s) }
        var nonBlocking: u_long = 1
        guard ioctlsocket(s, fionbio, &nonBlocking) == 0 else { return false }   // a blocking socket could stall the agent
        let rc = withSockaddr(addr) { connect(s, $0, $1) }
        if rc != 0 {
            guard WSAGetLastError() == wsaWouldBlock else { return false }
            var pfd = WSAPOLLFD(fd: s, events: pollOut, revents: 0)
            guard WSAPoll(&pfd, 1, timeoutMs) == 1, pfd.revents & pollErrOrHup == 0 else { return false }
            var err: Int32 = 0
            var len = Int32(MemoryLayout<Int32>.size)
            let got = withUnsafeMutableBytes(of: &err) { raw in
                getsockopt(s, solSocket, soError, raw.baseAddress!.assumingMemoryBound(to: CChar.self), &len)
            }
            guard got == 0, err == 0 else { return false }
        }
        var sent = 0
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while sent < line.count {
            let n = line.withUnsafeBytes { buf in
                Int(WinSDK.send(s, buf.baseAddress!.advanced(by: sent).assumingMemoryBound(to: CChar.self),
                                Int32(line.count - sent), 0))
            }
            if n > 0 { sent += n; continue }
            if n < 0, WSAGetLastError() == wsaWouldBlock, Date() < deadline {
                var pfd = WSAPOLLFD(fd: s, events: pollOut, revents: 0)
                _ = WSAPoll(&pfd, 1, 50)
                continue
            }
            return false
        }
        return true
    }
}

/// Listens on a Unix socket and hands back each line. Windows: one thread blocks in `accept`,
/// one thread per connection blocks in `recv`; `onLine` calls are serialised like the macOS queue.
public final class SocketServer: @unchecked Sendable {
    private let path: String
    private let onLine: (Data) -> Void
    private let lock = NSLock()
    private var stopped = false
    private let deliverLock = NSLock()

    public init(path: String, onLine: @escaping (Data) -> Void) throws {
        self.path = path
        self.onLine = onLine
        guard winsockReady else { throw NSError(domain: "Agentrise", code: 2) }
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        deleteFile(path)
        guard let addr = makeAddress(path) else { throw NSError(domain: "Agentrise", code: 1) }
        let s = socket(afUnix, sockStream, 0)
        guard s != invalidSocket else { throw NSError(domain: "Agentrise", code: 2) }
        guard withSockaddr(addr, { bind(s, $0, $1) }) == 0 else {
            closesocket(s)
            throw NSError(domain: "Agentrise", code: 3)
        }
        guard listen(s, 64) == 0 else {
            closesocket(s)
            deleteFile(path)
            throw NSError(domain: "Agentrise", code: 4)
        }
        let acceptor = Thread { [self] in acceptLoop(s) }
        acceptor.name = "agentrise.socket.accept"
        acceptor.start()
    }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    /// Owns the listening socket: only this thread closes it, so `accept` never runs on a
    /// handle value that `stop()` already closed and Windows may have handed to someone else.
    private func acceptLoop(_ s: SOCKET) {
        defer { closesocket(s) }
        while !isStopped {
            let client = accept(s, nil, nil)
            if isStopped {                                     // woken by stop()'s own connect
                if client != invalidSocket { closesocket(client) }
                return
            }
            if client == invalidSocket {
                Thread.sleep(forTimeInterval: 0.05)            // transient failure: don't spin
                continue
            }
            let reader = Thread { [self] in serve(client) }
            reader.name = "agentrise.socket.client"
            reader.start()
        }
    }

    private func deliver(_ line: Data) {
        deliverLock.lock(); defer { deliverLock.unlock() }
        onLine(line)
    }

    /// Same line rules as the macOS read handler.
    private func serve(_ client: SOCKET) {
        defer { closesocket(client) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = Int(chunk.withUnsafeMutableBytes { raw in
                recv(client, raw.baseAddress!.assumingMemoryBound(to: CChar.self), Int32(raw.count), 0)
            })
            if n <= 0 {
                if !buffer.isEmpty, buffer.count <= EventSlimmer.maxLineBytes { deliver(buffer) }
                return
            }
            buffer.append(chunk, count: n)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                if line.count <= EventSlimmer.maxLineBytes { deliver(Data(line)) }
                buffer.removeSubrange(buffer.startIndex...nl)
            }
            if buffer.count > EventSlimmer.maxLineBytes * 2 { buffer.removeAll() }
        }
    }

    public func stop() {
        lock.lock()
        let wasStopped = stopped
        stopped = true
        lock.unlock()
        guard !wasStopped else { return }
        SocketClient.send(Data(), to: path)                    // wake the blocked accept; it closes the listener
        deleteFile(path)
    }
}
#else
private func makeAddress(_ path: String) -> sockaddr_un? {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
    }
    return addr
}

public enum SocketClient {
    /// Sends one line and returns quickly whether or not anyone is listening.
    @discardableResult
    public static func send(_ line: Data, to path: String, timeoutMs: Int32 = 200) -> Bool {
        guard var addr = makeAddress(path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN else { return false }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&pfd, 1, timeoutMs) == 1 else { return false }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
            guard err == 0 else { return false }
        }
        var sent = 0
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while sent < line.count {
            let n = line.withUnsafeBytes { buf in
                write(fd, buf.baseAddress!.advanced(by: sent), line.count - sent)
            }
            if n > 0 { sent += n; continue }
            if errno == EAGAIN, Date() < deadline {
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = poll(&pfd, 1, 50)
                continue
            }
            return false
        }
        return true
    }
}

/// Listens on a Unix socket only the current user can open and hands back each line.
public final class SocketServer: @unchecked Sendable {
    private let path: String
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "agentrise.socket")
    private let onLine: (Data) -> Void

    public init(path: String, onLine: @escaping (Data) -> Void) throws {
        self.path = path
        self.onLine = onLine
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        chmod(dir, 0o700)
        var st = stat()
        if lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK, st.st_uid == geteuid() {
            unlink(path)
        }
        guard var addr = makeAddress(path) else { throw NSError(domain: "Agentrise", code: 1) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "Agentrise", code: 2) }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { close(fd); throw NSError(domain: "Agentrise", code: 3) }
        chmod(path, 0o600)
        listen(fd, 64)
        listenFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptOne() }
        src.setCancelHandler { close(fd) }
        src.resume()
        acceptSource = src
    }

    private func acceptOne() {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        var one: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let src = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
        var buffer = Data()
        src.setEventHandler { [weak self] in
            var chunk = [UInt8](repeating: 0, count: 8192)
            let n = read(client, &chunk, chunk.count)
            if n <= 0 {
                if !buffer.isEmpty, buffer.count <= EventSlimmer.maxLineBytes { self?.onLine(buffer) }
                src.cancel()
                return
            }
            buffer.append(chunk, count: n)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                if line.count <= EventSlimmer.maxLineBytes { self?.onLine(Data(line)) }
                buffer.removeSubrange(buffer.startIndex...nl)
            }
            if buffer.count > EventSlimmer.maxLineBytes * 2 { buffer.removeAll() }
        }
        src.setCancelHandler { close(client) }
        src.resume()
    }

    public func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        unlink(path)
    }
}
#endif
