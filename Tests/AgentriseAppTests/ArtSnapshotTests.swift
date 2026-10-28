// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

// Pins every bitmap the macOS scene bakes as a PNG baseline in `Fixtures/art/`.
//
// Each entry of `ArtSnapshotTests.shots` renders one image, takes its premultiplied RGBA bytes (sRGB, rows top
// first) and compares them with the decoded baseline, channel by channel, allowing a difference of 1. Robot
// parts, labels, bubbles, signs and emoji come straight from a fresh `RobotArt(scale: 2)`; building pieces
// from `BuildingArt` at scale 2 (both the portable recipes, drawn by `CGArtBackend` through `CGPen`) for a landscape (1200×800) and a portrait (700×1100) layout; the header,
// tooltip and report card, which only the scene bakes, from a `TowerScene` at backing scale 2 (the report is
// baked at the scene's robot-art scale, 2 × 1.25 = 2.5).
//
// Recording: `scripts/record-art-baselines.sh` (or `AGENTRISE_RECORD_ART=1 swift test --filter ArtSnapshotTests`)
// rewrites every baseline and `Fixtures/art/RECORDED.txt` (macOS and Xcode versions, SHA-256 of each PNG).
// Every run also writes what it rendered, with its own RECORDED.txt, to `.build/scene-snapshots/art/`; the CI
// macOS job uploads that folder when the tests fail, and CI's renders are the reference.
//
// When this Mac's macOS release (major.minor) differs from the recorded one, mismatches of images that draw text
// (`textBearingPrefixes`) are reported as known issues instead of failing; any other mismatch still fails, and
// `CI=true` never tolerates anything (nor records: AGENTRISE_RECORD_ART=1 fails there). The major version alone isn't enough: the system font's
// metrics changed between macOS 15.7 (CI) and 15.8, which moves Latin text widths by a few pixels.

import Testing
import AppKit
import CryptoKit
import ImageIO
import SpriteKit
import UniformTypeIdentifiers
@testable import AgentriseApp
@testable import Agentrise
@testable import AgentriseScene

// MARK: - Shared snapshot plumbing (also used by MotionSnapshotTests)

enum SnapshotPaths {
    /// The package root (this file is Tests/AgentriseAppTests/ArtSnapshotTests.swift).
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let fixtures = root.appendingPathComponent("Tests/AgentriseAppTests/Fixtures")
    /// What the last run rendered (uploaded by CI).
    static let actual = root.appendingPathComponent(".build/scene-snapshots")

    static func env(_ name: String) -> Bool { ProcessInfo.processInfo.environment[name] == "1" }
    static var onCI: Bool { ProcessInfo.processInfo.environment["CI"] == "true" }

    static func freshDirectory(_ url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

@MainActor
@Suite(.serialized) struct ArtSnapshotTests {
    static let scale: CGFloat = 2
    static let layouts: [(name: String, size: CGSize)] = [("landscape", CGSize(width: 1200, height: 800)),
                                                          ("portrait", CGSize(width: 700, height: 1100))]
    static let recordVar = "AGENTRISE_RECORD_ART"
    static var baselineDir: URL { SnapshotPaths.fixtures.appendingPathComponent("art") }
    static var actualDir: URL { SnapshotPaths.actual.appendingPathComponent("art") }

    struct Shot {
        let key: String
        let render: () -> CGImage
    }

    // MARK: The image list

    /// Every rank, with its raw value in kebab case ("senior-director").
    static let ranks: [(Rank, String)] = Rank.allCases.map { r in
        (r, r.rawValue.reduce(into: "") { s, c in s += c.isUppercase ? "-" + c.lowercased() : String(c) })
    }
    static let kinds: [(RobotKind, String)] = ranks.map { (RobotKind.boss($0.0), "boss-\($0.1)") } + [(.sub, "sub"), (.contractor, "contractor")]
    static let teams = [0, 1, 2]
    static let faces: [(RobotFace, String)] = [(.focused, "focused"), (.happy, "happy"), (.waiting, "waiting"),
                                               (.error, "error"), (.asleep, "asleep"), (.calm, "calm")]
    /// Every `Activity` case. The enum isn't `CaseIterable`, so the cases are chained by an exhaustive `switch`:
    /// a new case doesn't compile until it is added here.
    static let activities: [Activity] = {
        func next(_ a: Activity) -> Activity? {
            switch a {
            case .reading: return .searching
            case .searching: return .coding
            case .coding: return .runningCommand
            case .runningCommand: return .commandFailed
            case .commandFailed: return .browsing
            case .browsing: return .planning
            case .planning: return .delegating
            case .delegating: return .sendingLark
            case .sendingLark: return .thinking
            case .thinking: return .compacting
            case .compacting: return .waitingAtDoor
            case .waitingAtDoor: return .waitingForSubs
            case .waitingForSubs: return .reporting
            case .reporting: return .resting
            case .resting: return .standby
            case .standby: return .sleeping
            case .sleeping: return .briefing
            case .briefing: return .other
            case .other: return nil
            }
        }
        return Array(sequence(first: Activity.reading, next: next))
    }()
    /// Every emoji prop: (prop name, glyph, size), once per distinct glyph and size.
    static var emojiProps: [(name: String, glyph: String, size: CGFloat)] {
        var seen = Set<String>(), out: [(String, String, CGFloat)] = []
        for a in activities {
            for p in RobotMotion.props(a) {
                guard case let .emoji(s, size) = p.art, seen.insert("\(s)|\(size)").inserted else { continue }
                out.append((p.name, s, size))
            }
        }
        return out
    }

    static let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)
    /// Rank titles from the defaults, not `RankBook.current` (other suites change it).
    static func title(_ r: Rank) -> String { RankBook.defaults.title(r) }

    static func shots() -> [Shot] {
        var out: [Shot] = []
        let backend = CGArtBackend.shared
        let art = RobotArt(scale: scale, backend: backend)
        func add(_ key: String, _ render: @escaping () -> CGImage) { out.append(Shot(key: key, render: render)) }
        func add(_ key: String, _ render: @escaping () -> BakedImage) { add(key) { render().cgImage } }

        // Building.
        for (name, size) in layouts {
            let layout = BuildingLayout.make(size: size)
            add("building-background-\(name)") { BuildingArt.background(layout, scale: scale, backend: backend) }
            add("building-cab-\(name)") { BuildingArt.cab(layout, scale: scale, backend: backend) }
        }
        var ledColors: [UInt32] = []
        for spec in BuildingArt.ledSpecs(BuildingLayout.make(size: layouts[0].size)) {
            let hex = hexOf(NSColor(spec.color))
            guard !ledColors.contains(hex) else { continue }
            ledColors.append(hex)
            add(String(format: "building-led-%06x", hex)) { BuildingArt.led(color: spec.color, scale: scale, backend: backend) }
        }
        add("building-elevator-label") { BuildingArt.elevatorLabel(scale: scale, backend: backend) }

        // Robot parts that don't depend on the look.
        let plain: [(RobotPart, String)] = [(.halo, "halo"), (.leftHand, "left-hand"), (.rightHand, "right-hand"),
                                            (.ears, "ears"), (.ring, "ring"), (.pod, "pod"), (.larkBadge, "lark-badge")]
        for (part, name) in plain { add("robot-\(name)") { art.image(part) } }
        for (face, name) in faces { add("robot-eyes-\(name)") { art.image(.eyes(face)) } }
        // Parts drawn per look: every kind (every boss rank) in the first three team colours; bosses also with
        // the lark square (only bosses ever get `larkSession`).
        for (kind, kindName) in kinds {
            for team in teams {
                let isBoss = kind != .sub && kind != .contractor
                for lark in isBoss ? [false, true] : [false] {
                    let look = RobotLook(kind: kind, teamIndex: team, larkSession: lark)
                    let suffix = "\(kindName)-team\(team)\(lark ? "-lark" : "")"
                    add("robot-torso-\(suffix)") { art.image(.torso(look)) }
                    guard !lark else { continue }   // the lark square is on the torso only
                    add("robot-head-\(suffix)") { art.image(.head(look)) }
                    if look.hasHeadOverlay { add("robot-head-overlay-\(suffix)") { art.image(.headOverlay(look)) } }
                }
            }
        }
        // `.prop` is the glyph at the default 13 pt: once per distinct glyph.
        var propGlyphs = Set<String>()
        for (name, glyph, _) in emojiProps where propGlyphs.insert(glyph).inserted {
            add("robot-prop-\(name)") { art.image(.prop(glyph)) }
        }

        // Names: the scene's "<glyph> <title>\n<rank title>" for bosses (titles over 9 characters cut to
        // 8 + "…"), the plain small label for subs and contractors.
        func bossName(_ title: String, team: Int, rank: Rank) -> String {
            let t = title.count > 9 ? String(title.prefix(8)) + "…" : title
            return "\(Team.glyph(team)) \(t)\n\(Self.title(rank))"
        }
        for (rank, rankName) in ranks {
            add("name-stripe-\(rankName)") { art.name(bossName("修复登录", team: 0, rank: rank), small: false, stripe: rank.stripe) }
        }
        add("name-short-no-stripe") { art.name("⚡ 修复登录", small: false, stripe: nil) }
        add("name-long-truncated") {
            art.name(bossName("重构整个支付网关的回调处理逻辑", team: 1, rank: .seniorEngineer), small: false, stripe: Rank.seniorEngineer.stripe)
        }
        add("name-long-clipped") { art.name("✚ 一个特别特别特别特别特别特别长的名字", small: false, stripe: nil) }
        add("name-small-sub") { art.name("Explore", small: true, stripe: nil) }
        add("name-small-contractor") { art.name("外包·" + String("跑一遍完整的测试套件".prefix(10)), small: true, stripe: nil) }

        // Bubbles: every bubble the scene shows, plus a two-line one; glows for the pulsing ones.
        let bubbles: [(String, String, Color, Bool)] = [
            ("waiting", "等你回复", Color(hex: 0xFFC95C), true), ("done", "✓ 做完了", Color(hex: 0x1F8F57), false),
            ("error", "出错了", Color(hex: 0xD84545), true), ("working", Activity.coding.label, Color(hex: 0x24477A), false),
            ("two-lines", "等你回复\n第二行", Color(hex: 0xFFC95C), true)]
        for (name, text, color, glows) in bubbles {
            add("bubble-\(name)") { art.bubble(text, color: color) }
            if glows { add("bubble-glow-\(name)") { art.bubbleGlow(text, color: color) } }
        }
        add("door-sign") { art.doorSign() }

        // Emoji props at their own sizes.
        for (name, glyph, size) in emojiProps {
            add("emoji-\(name)-\(Self.sizeName(size))") { art.emoji(glyph, size: size) }
        }

        // Baked by the scene only.
        add("header-zero") { header(TowerCounts()) }
        add("header-busy") { header(TowerCounts(working: 3, waiting: 2, done: 1, subs: 4, contractors: 1, sleeping: 1, standby: 2)) }
        add("tooltip-working") {
            var s = session("w", title: "修复登录", status: .working, team: 0, rank: .seniorEngineer)
            s.subs = ["x": SubAgent(id: "x", type: "Explore", activity: .coding, startedAt: fixedDate)]
            s.delivered = 3; s.failedSubs = 1
            return tooltip(s)
        }
        add("tooltip-waiting-lark") {
            var s = session("l", title: "回复飞书里的一个特别长的问题标题", status: .waiting, team: 1, rank: .seniorDirector)
            s.source = .lark
            s.waitingSummary = "要不要合并这个 PR？"
            return tooltip(s)
        }
        add("report") { report() }
        return out
    }

    static func sizeName(_ s: CGFloat) -> String { s == s.rounded() ? "\(Int(s))pt" : "\(s)pt" }

    static func hexOf(_ c: NSColor) -> UInt32 {
        let s = c.usingColorSpace(.sRGB) ?? c
        func b(_ v: CGFloat) -> UInt32 { UInt32((v * 255).rounded()) }
        return b(s.redComponent) << 16 | b(s.greenComponent) << 8 | b(s.blueComponent)
    }

    /// A session with fixed dates. The tooltip's minutes count from the real clock (`showTooltip` passes no
    /// date), so `statusSince` is "now": the box always reads "0 分钟".
    static func session(_ id: String, title: String, status: SessionStatus, team: Int, rank: Rank) -> Session {
        Session(id: id, title: title, source: .desktop(hostSessionId: nil), rank: rank, status: status,
                activity: .coding, teamIndex: team, statusSince: fixedDate, lastActivityAt: fixedDate)
    }

    static func scene() -> TowerScene {
        let scene = TowerScene(size: layouts[0].size)
        scene.clock = { fixedDate }
        scene.backingScaleChanged(scale)
        return scene
    }

    static func header(_ counts: TowerCounts) -> CGImage {
        let scene = scene()
        scene.setHeader(counts)
        return (scene.childNode(withName: "header") as! SKSpriteNode).texture!.cgImage()
    }

    static func tooltip(_ s: Session) -> CGImage {
        var s = s
        s.statusSince = Date()
        let scene = scene()
        scene.render([s], animated: false)
        scene.showTooltip(s.id, at: CGPoint(x: 100, y: 100))
        return (scene.childNode(withName: "tooltip")!.children.first as! SKSpriteNode).texture!.cgImage()
    }

    /// The card a finished sub carries back to its boss.
    static func report() -> CGImage {
        let scene = scene()
        var s = session("b", title: "带小弟", status: .working, team: 0, rank: .seniorEngineer)
        s.subs = ["x": SubAgent(id: "x", type: "Explore", activity: .coding, startedAt: fixedDate)]
        scene.render([s], animated: false)
        scene.noteSubResult(sessionId: "b", subId: "x", success: true)
        s.subs = [:]
        scene.render([s])
        return (scene.robot("a:b:x")!.childNode(withName: "report") as! SKSpriteNode).texture!.cgImage()
    }

    // MARK: Pixels and PNGs

    struct Pixels: Equatable {
        let width: Int, height: Int
        let bytes: [UInt8]
    }

    /// Premultiplied RGBA in sRGB, top row first: the format `CGArtBackend` bakes in.
    static func pixels(_ image: CGImage) -> Pixels {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGArtBackend.colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setBlendMode(.copy)
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return Pixels(width: w, height: h, bytes: bytes)
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    static func readPNG(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// The largest per-channel difference, or nil when the sizes differ.
    static func maxDifference(_ a: Pixels, _ b: Pixels) -> Int? {
        guard a.width == b.width, a.height == b.height else { return nil }
        var m = 0
        for i in 0..<a.bytes.count { m = max(m, abs(Int(a.bytes[i]) - Int(b.bytes[i]))) }
        return m
    }

    // MARK: RECORDED.txt

    static var macOSMajor: Int { ProcessInfo.processInfo.operatingSystemVersion.majorVersion }

    static var macOSVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// "Xcode 16.4 (16F6)", or the Command Line Tools when there is no Xcode.
    static var xcodeVersion: String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["xcodebuild", "-version"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return "unknown" }
        p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard p.terminationStatus == 0 else { return "none (Command Line Tools)" }
        let lines = text.split(separator: "\n").map(String.init)
        return lines.count >= 2 ? "\(lines[0]) (\(lines[1].replacingOccurrences(of: "Build version ", with: "")))" : lines.first ?? "unknown"
    }

    static func recordedText(files: [String], in dir: URL) throws -> String {
        var s = "# Art baselines: written by scripts/record-art-baselines.sh; the reference is CI's macOS job.\n"
        s += "macos-major: \(macOSMajor)\nmacos: \(macOSVersion)\nxcode: \(xcodeVersion)\nscale: \(Int(scale))\n"
        for f in files.sorted() {
            let digest = SHA256.hash(data: try Data(contentsOf: dir.appendingPathComponent(f)))
            s += "\(digest.map { String(format: "%02x", $0) }.joined())  \(f)\n"
        }
        return s
    }

    /// This Mac's macOS release, "major.minor".
    static var macOSRelease: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)"
    }

    /// The release ("major.minor") from the `macos:` line of the baselines' RECORDED.txt.
    static var recordedRelease: String? {
        guard let text = try? String(contentsOf: baselineDir.appendingPathComponent("RECORDED.txt"), encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("macos: ") }) else { return nil }
        return line.dropFirst("macos: ".count).split(separator: ".").prefix(2).joined(separator: ".")
    }

    // MARK: The test

    @Test func everyShotHasAUniqueKey() {
        let keys = Self.shots().map(\.key)
        #expect(Set(keys).count == keys.count)
    }

    /// Keys of the images that draw text (Latin or CJK). Text rendering changes between macOS releases, so on a
    /// local Mac whose release differs from RECORDED.txt only these may differ (as known issues); any other image
    /// that differs still fails. Bubble glows, the cab, LEDs, report, pod, halo and the plain robot parts draw no text.
    static let textBearingPrefixes = [
        "building-background-",     // floor tags and room titles
        "building-elevator-label",  // 电梯
        "robot-torso-boss-",        // the team glyph on the neck pendant (and 飞 on lark torsos)
        "robot-lark-badge",         // 飞
        "robot-prop-",              // emoji
        "emoji-",                   // emoji
        "name-",                    // name labels
        "bubble-done", "bubble-error", "bubble-two-lines", "bubble-waiting", "bubble-working",   // not the glows
        "door-sign",                // ?
        "header-",                  // the header copy
        "tooltip-",                 // the detail box
    ]

    static func drawsText(_ key: String) -> Bool { textBearingPrefixes.contains { key.hasPrefix($0) } }

    @Test func textBearingKeysAreRealKeys() {
        let keys = Self.shots().map(\.key)
        for prefix in Self.textBearingPrefixes { #expect(keys.contains { $0.hasPrefix(prefix) }, "\(prefix)") }
        #expect(!Self.drawsText("bubble-glow-waiting"))
        #expect(!Self.drawsText("robot-head-sub-team0"))
        #expect(!Self.drawsText("report"))
    }

    @Test func artMatchesBaselines() throws {
        let record = SnapshotPaths.env(Self.recordVar)
        if record && SnapshotPaths.onCI {
            Issue.record("\(Self.recordVar)=1 on CI: CI only compares against the baselines, it never records them.")
            return
        }
        let shots = Self.shots()
        try SnapshotPaths.freshDirectory(Self.actualDir)
        if record { try FileManager.default.createDirectory(at: Self.baselineDir, withIntermediateDirectories: true) }

        var problems: [(key: String, text: String)] = []
        var missing: [String] = []
        for shot in shots {
            let file = shot.key + ".png"
            let image = shot.render()
            try Self.writePNG(image, to: Self.actualDir.appendingPathComponent(file))
            let baseline = Self.baselineDir.appendingPathComponent(file)
            if record {
                try Self.writePNG(image, to: baseline)
                continue
            }
            guard let expected = Self.readPNG(baseline) else { missing.append(file); continue }
            // Compare the PNG round trip of both: PNG stores straight alpha, so the rendered bytes go through
            // the same un-premultiply / premultiply as the baseline's.
            let got = Self.pixels(Self.readPNG(Self.actualDir.appendingPathComponent(file))!)
            let want = Self.pixels(expected)
            if let d = Self.maxDifference(got, want) {
                if d > 1 { problems.append((shot.key, "\(file): a channel differs by \(d)")) }
            } else {
                problems.append((shot.key, "\(file): \(got.width)×\(got.height) px, baseline \(want.width)×\(want.height) px"))
            }
        }
        let files = shots.map { $0.key + ".png" }
        try Self.recordedText(files: files, in: Self.actualDir)
            .write(to: Self.actualDir.appendingPathComponent("RECORDED.txt"), atomically: true, encoding: .utf8)
        if record {
            try Self.recordedText(files: files, in: Self.baselineDir)
                .write(to: Self.baselineDir.appendingPathComponent("RECORDED.txt"), atomically: true, encoding: .utf8)
            // Baselines nobody renders any more.
            let stale = (try FileManager.default.contentsOfDirectory(atPath: Self.baselineDir.path))
                .filter { $0.hasSuffix(".png") && !files.contains($0) }
            for f in stale { try FileManager.default.removeItem(at: Self.baselineDir.appendingPathComponent(f)) }
            return
        }

        if !missing.isEmpty {
            Issue.record("""
                \(missing.count) art baseline(s) missing (\(missing.prefix(5).joined(separator: ", "))…). \
                Record them with scripts/record-art-baselines.sh (AGENTRISE_RECORD_ART=1 swift test --filter ArtSnapshotTests).
                """)
        }
        guard !problems.isEmpty else { return }
        // Another macOS release than the baselines' (never on CI): text may render differently, so a differing
        // image that draws text is a known issue. Everything else still fails.
        let otherRelease = !SnapshotPaths.onCI && Self.recordedRelease.map { $0 != Self.macOSRelease } == true
        let tolerated = otherRelease ? problems.filter { Self.drawsText($0.key) } : []
        let failing = otherRelease ? problems.filter { !Self.drawsText($0.key) } : problems
        if !failing.isEmpty {
            Issue.record(Comment(rawValue: """
                \(failing.count) image(s) differ from Fixtures/art (renders in \(Self.actualDir.path)):
                \(failing.map(\.text).joined(separator: "\n"))
                """))
        }
        if !tolerated.isEmpty {
            withKnownIssue("Baselines were recorded on macOS \(Self.recordedRelease ?? "?"), this is macOS \(Self.macOSRelease): text renders differently.") {
                Issue.record(Comment(rawValue: tolerated.map(\.text).joined(separator: "\n")))
            }
        }
    }
}
