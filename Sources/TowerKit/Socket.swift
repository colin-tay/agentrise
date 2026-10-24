import Foundation
import Darwin

public enum TowerPaths {
    public static func supportDir(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/Agentrise", isDirectory: true)
    }
    public static func socketPath(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        supportDir(home: home).appendingPathComponent("tower.sock").path
    }
    public static func hookBinaryURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        supportDir(home: home).appendingPathComponent("bin/agentrise-hook")
    }
}

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
