// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation
import CommonCrypto
import CoreGraphics

struct BarkMessage: Equatable {
    var title = "Agentrise"
    var body: String
    var group = "Agentrise"
}

/// When to push to the phone: only "done", "waiting" and "error", only when the CEO is away,
/// never for Feishu sessions, once per session and status within the dedupe window.
struct BarkPolicy {
    var dedupeWindow: TimeInterval = 600
    private var lastSent: [String: Date] = [:]

    mutating func message(for effect: TowerEffect, session: Session?, isAway: Bool, now: Date) -> BarkMessage? {
        guard case let .statusChanged(id, _, to) = effect, let s = session, !s.isHidden, !s.isLark, isAway else { return nil }
        let body: String
        switch to {
        case .done: body = "「\(s.title)」做完了"
        case .waiting: body = "「\(s.title)」在等你回复"
        case .error: body = "「\(s.title)」出错了"
        default: return nil
        }
        let key = "\(id)|\(to.rawValue)"
        // A long-running session finishes round after round; "done" is worth one push an hour.
        let window = to == .done ? 3600 : dedupeWindow
        if let last = lastSent[key], now.timeIntervalSince(last) < window { return nil }
        lastSent[key] = now
        return BarkMessage(body: body)
    }
}

struct BarkConfig {
    var server: String
    var deviceKey: String
    var encryptionKey: String   // 32 ASCII chars, AES-256
    var iv: String              // 16 ASCII chars
    var awayThreshold: TimeInterval

    var isUsable: Bool { !deviceKey.isEmpty }
    var encrypts: Bool { encryptionKey.utf8.count == 32 }

    /// Stored in a file only this user can read (not the keychain: ad-hoc signed rebuilds
    /// would make macOS ask for the login password after every update).
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Agentrise/bark.json")

    static func load() -> BarkConfig {
        var c = BarkConfig(server: "https://api.day.app", deviceKey: "", encryptionKey: "", iv: "", awayThreshold: 180)
        if let d = try? Data(contentsOf: fileURL), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            c.server = o["server"] as? String ?? c.server
            c.deviceKey = o["deviceKey"] as? String ?? ""
            c.encryptionKey = o["encryptionKey"] as? String ?? ""
            c.iv = o["iv"] as? String ?? ""
            c.awayThreshold = o["awaySeconds"] as? Double ?? 180
        }
        return c
    }

    func save() {
        let o: [String: Any] = ["server": server, "deviceKey": deviceKey, "encryptionKey": encryptionKey, "iv": iv, "awaySeconds": awayThreshold]
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted]) else { return }
        let dir = Self.fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(atPath: Self.fileURL.path, contents: d, attributes: [.posixPermissions: 0o600])
        chmod(Self.fileURL.path, 0o600)
    }
}

enum BarkCrypto {
    static func encrypt(_ plain: Data, key: String, iv: String) -> String? {
        let k = Array(key.utf8), v = Array(iv.utf8)
        guard k.count == 32, v.count == 16 else { return nil }
        var out = [UInt8](repeating: 0, count: plain.count + kCCBlockSizeAES128)
        var moved = 0
        let status = plain.withUnsafeBytes { p in
            CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    k, k.count, v, p.baseAddress, plain.count, &out, out.count, &moved)
        }
        guard status == kCCSuccess else { return nil }
        return Data(out.prefix(moved)).base64EncodedString()
    }
}

enum BarkClient {
    static func send(_ m: BarkMessage, config: BarkConfig) async throws {
        let base = config.server.hasSuffix("/") ? String(config.server.dropLast()) : config.server
        guard let url = URL(string: "\(base)/\(config.deviceKey)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        let payload: [String: Any] = ["title": m.title, "body": m.body, "group": m.group, "sound": "glass"]
        if config.encrypts {
            let json = try JSONSerialization.data(withJSONObject: payload)
            // A fresh IV for every push, sent alongside the ciphertext (as Bark's docs ask).
            let iv = String((0..<16).map { _ in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
            guard let ct = BarkCrypto.encrypt(json, key: config.encryptionKey, iv: iv) else { return }
            // Encode the values only: base64 has '+', '/' and '='.
            let allowed = CharacterSet.alphanumerics
            let enc = { (v: String) in v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v }
            let body = "ciphertext=\(enc(ct))&iv=\(enc(iv))"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data(body.utf8)
        } else {
            req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        }
        let (_, resp) = try await URLSession.shared.data(for: req)
        if let h = resp as? HTTPURLResponse, h.statusCode >= 300 {
            throw NSError(domain: "Bark", code: h.statusCode, userInfo: [NSLocalizedDescriptionKey: "Bark 返回 \(h.statusCode)"])
        }
    }
}

enum AwayDetector {
    static var screenLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true
    }

    static func isAway(threshold: TimeInterval) -> Bool {
        if let dict = CGSessionCopyCurrentDictionary() as? [String: Any], dict["CGSSessionScreenIsLocked"] as? Bool == true { return true }
        let anyInput = CGEventType(rawValue: ~0)!
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        return idle >= threshold
    }
}
/// Collects pushes for a minute and sends them as one notification, logging each send.
final class BarkBatcher {
    private var pending: [BarkMessage] = []
    private var scheduled = false
    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Agentrise/bark.log")

    func enqueue(_ m: BarkMessage, config: @escaping () -> BarkConfig) {
        pending.append(m)
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self else { return }
            self.scheduled = false
            let batch = self.pending
            self.pending.removeAll()
            guard !batch.isEmpty else { return }
            let msg = batch.count == 1 ? batch[0]
                : BarkMessage(body: "\(batch.count) 个会话有动静：" + batch.map(\.body).joined(separator: "；"))
            let cfg = config()
            Task {
                var result = "ok"
                do { try await BarkClient.send(msg, config: cfg) } catch { result = "failed: \(error.localizedDescription)" }
                Self.log("\(msg.body) [\(cfg.encrypts ? "encrypted" : "plain")] \(result)")
            }
        }
    }

    static func log(_ line: String) {
        let f = ISO8601DateFormatter(); f.timeZone = .current
        let text = "\(f.string(from: Date())) \(line)\n"
        if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close() }
        else { try? Data(text.utf8).write(to: logURL) }
    }
}

import AppKit
import Agentrise

/// Plays a sound on the Mac when an agent needs a look, so the CEO looks up from the phone.
/// Different sounds per status; bursts within 2 seconds play once (the most urgent wins).
final class DeskChime {
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "deskChime") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "deskChime") }
    }
    private var pending: SessionStatus?
    private var lastPlayed: [String: Date] = [:]

    func ring(sessionId: String, status: SessionStatus, now: Date = Date()) {
        guard Self.enabled, !AwayDetector.screenLocked else { return }
        let key = "\(sessionId)|\(status.rawValue)"
        if let t = lastPlayed[key], now.timeIntervalSince(t) < 30 { return }
        lastPlayed[key] = now
        let rank: (SessionStatus?) -> Int = { $0 == .error ? 3 : $0 == .waiting ? 2 : $0 == .done ? 1 : 0 }
        let first = pending == nil
        if rank(status) > rank(pending) { pending = status }
        guard first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, let s = self.pending else { return }
            self.pending = nil
            Self.play(s)
        }
    }

    static func play(_ s: SessionStatus) {
        let name: String
        switch s {
        case .waiting: name = "Glass"      // 等你回复
        case .error: name = "Basso"        // 出错了
        default: name = "Hero"             // 做完了
        }
        NSSound(named: NSSound.Name(name))?.play()
    }
}
