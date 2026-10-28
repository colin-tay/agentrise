// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

// Pins today's robot and scene motion as frame-by-frame traces in `Fixtures/motion/*.txt`.
//
// Sampling. `MotionTrace` steps a `SceneNode` tree in 1/60 s frames (frame n at 1000 + n/60 s) and samples it
// after each step; frame 0 is sampled after the first step (dt 0). The single-robot traces step a `RobotRig`'s
// root with `TweenEngine.step`. The scene trace drives a `SpriteKitDisplay` with `SKRenderer.update(atTime:)`:
// the display's `update(_:)` steps the `TowerSceneModel` (`step(dt:)`: transit, timers, then tweens) and
// mirrors it into SpriteKit, so the tethers' dashed paths are the ones the display actually draws.
//
// Node paths. Every node under the traced root is named by its path from the root: segments joined with
// `/`, each segment the node's `name`; a robot under the model's `actors` is `robot:<entity key>` (e.g.
// `actors/robot:s:A/rig/float/head`); an unnamed node is `#<index among its siblings>` (e.g. `leds/#3`); a name
// shared by several siblings gets `#<k>` appended for its k-th occurrence. The root itself is `robot` in the
// single-robot traces; in the scene trace the model's root is not recorded and paths start at its children. The
// tether nodes (children of `tethers`) are left out; see below.
//
// Fields, in order: position.x, position.y, zPosition, alpha, xScale, yScale, zRotation, isHidden (0/1), texture.
// Positions are each node's `position` in its parent's space (SpriteKit points, y up; top-level nodes are in scene
// coordinates). Numbers have 3 decimals (zPosition 5, so the 0.001 / 0.0005 / 0.0001 steps that stack a robot's
// parts show) with `.` as the decimal point; a negative zero is written without its sign.
//
// Texture identity (`TextureKeys`): `.` for a node that isn't a sprite, `-` for a sprite without a bitmap. A
// robot's part names the image it shows (`RobotRig.sourceImage(of:)`), looked up among every image the
// robot's `RobotArt` can make for the scene: `torso:<kind>:team<i>:lark<0|1>` (likewise `head`, `headOverlay`),
// `eyes-<face>` (calm draws focused's image), `halo`, `emoji:<prop>:<size>`, `door-sign`,
// `bubble:<text>:<colour>`, `bubble-glow:<text>:<colour>`, `name:<text>:<small 0|1>:<stripe colour>` (spaces as
// `_`, line breaks as `\n`). The header is `header:<its text>`. Anything else (background, cab, elevator label,
// LEDs, the report card) is `px:<w>x<h>:<SHA-256 prefix of its RGBA>`: in the scene trace read back from the
// display's texture with `SKTexture.cgImage()`, otherwise from the image itself; none of those draw text that
// differs between the macOS releases we record on (see the art baselines).
//
// File format. One line per frame: `f <frame>` then ` | `-separated entries `<path> <9 fields>`. To keep the files
// small a frame lists only the nodes whose formatted fields changed since the previous frame (frame 0 lists
// all), and `-<path>` for a node that went away; replaying the lines gives every node's full state at every
// frame, and that is what the test compares. Highlight tethers are separate lines, one per tether per frame:
// `t <frame> <tether node name> from <x> <y> ctrl <x> <y> to <x> <y> drawn <x0> <y0> <x1> <y1> box <x> <y> <w> <h>`.
// `from/ctrl/to` is the quad curve the model gives the display (`TowerSceneModel.tetherCurve`); `drawn` is the
// first and last point of the dashed path the display's shape holds and `box` its bounding box
// (`CGPath.applyWithBlock`, `boundingBoxOfPath`), so the dash phase shows there too.
//
// Comparison: same frames, same nodes per frame, numbers within 0.002 (zPosition within 0.00002), isHidden and
// texture equal, tether lines likewise. Re-record with `AGENTRISE_RECORD_MOTION=1 swift test --filter
// MotionSnapshotTests` (refused on CI). Every run also writes its traces to `.build/scene-snapshots/motion/`.
//
// Determinism: robots get fixed idle phases (`RobotRig(phase:)`, `TowerSceneModel.idlePhase` keyed by entity
// key), the model a fixed `clock`, sessions fixed ids and `Date`s, and the frames fixed times.

import Testing
import AppKit
import CryptoKit
import Metal
import SpriteKit
@testable import AgentriseApp
@testable import Agentrise
@testable import AgentriseScene

/// Records a node subtree's state every 1/60 s frame (see the file header for the format).
@MainActor final class MotionTrace {
    static let fps = 60.0
    static let base: TimeInterval = 1000

    private let root: SceneNode
    /// The root's own path segment; nil = don't record the root, start paths at its children.
    private let rootName: String?
    /// Steps everything to a frame's time (`base` + seconds).
    private let advance: (TimeInterval) -> Void
    /// Path segments for particular nodes (robots under a model), looked up every frame.
    var label: @MainActor () -> [ObjectIdentifier: String] = { [:] }
    /// The rig a node is the root of (its parts' images are named after the rig's art).
    var rig: @MainActor (SceneNode) -> RobotRig? = { _ in nil }
    /// Extra lines for a frame (the tethers).
    var extra: @MainActor (Int) -> [String] = { _ in [] }
    /// Names the image a node draws.
    let textures: TextureKeys
    private(set) var lines: [String] = []
    private var last: [String: String] = [:]
    private(set) var frame = 0

    init(root: SceneNode, rootName: String?, textures: TextureKeys, rig: @escaping @MainActor (SceneNode) -> RobotRig? = { _ in nil },
         advance: @escaping (TimeInterval) -> Void) {
        self.root = root
        self.rootName = rootName
        self.textures = textures
        self.rig = rig
        self.advance = advance
        advance(Self.base)
        sample()
    }

    /// Steps a bare node tree with the tween engine, by the gaps between frame times.
    static func engine(_ root: SceneNode) -> (TimeInterval) -> Void {
        var last: TimeInterval?
        return { t in
            TweenEngine.step(root, dt: last.map { t - $0 } ?? 0)
            last = t
        }
    }

    /// Steps frame by frame up to and including `target`, sampling each one.
    func run(to target: Int) {
        while frame < target {
            frame += 1
            advance(Self.base + Double(frame) / Self.fps)
            sample()
        }
    }

    nonisolated static func number(_ v: CGFloat, decimals: Int = 3) -> String {
        let s = String(format: "%.\(decimals)f", Double(v))
        return s.hasPrefix("-") && s.dropFirst().allSatisfy({ $0 == "0" || $0 == "." }) ? String(s.dropFirst()) : s
    }

    /// As SpriteKit holds it: node properties are `Float`s there (the display hands them over as they are).
    private static func f(_ v: CGFloat) -> CGFloat { CGFloat(Float(v)) }

    func fields(_ n: SceneNode, robot: RobotRig?) -> String {
        let p = n.position, f = Self.f
        return [Self.number(f(p.x)), Self.number(f(p.y)), Self.number(f(n.zPosition), decimals: 5), Self.number(f(n.alpha)),
                Self.number(f(n.xScale)), Self.number(f(n.yScale)), Self.number(f(n.zRotation)), n.isHidden ? "1" : "0",
                textures.key(n, robot: robot, root: root)].joined(separator: " ")
    }

    private func sample() {
        var now: [(String, String)] = []
        let labels = label()
        func walk(_ n: SceneNode, _ path: String?, _ robot: RobotRig?) {
            let robot = rig(n) ?? robot
            if let path { now.append((path, fields(n, robot: robot))) }
            if n.name == "tethers", n.parent === root { return }
            var seen: [String: Int] = [:]
            for (i, c) in n.children.enumerated() {
                var seg: String
                if let l = labels[ObjectIdentifier(c)] { seg = l } else if let name = c.name, !name.isEmpty { seg = name } else { seg = "#\(i)" }
                let k = seen[seg, default: 0]
                seen[seg] = k + 1
                if k > 0 { seg += "#\(k)" }
                walk(c, path.map { "\($0)/\(seg)" } ?? seg, robot)
            }
        }
        walk(root, rootName, nil)
        var entries: [String] = []
        var present = Set<String>()
        for (path, f) in now {
            present.insert(path)
            if last[path] != f { entries.append("\(path) \(f)") }
            last[path] = f
        }
        for path in last.keys.sorted() where !present.contains(path) {
            entries.append("-\(path)")
            last[path] = nil
        }
        lines.append((["f \(frame)"] + entries).joined(separator: " | "))
        lines += extra(frame)
    }

    var text: String { lines.joined(separator: "\n") + "\n" }

    // MARK: Replay and compare

    struct Replayed {
        /// Per frame: every node's fields.
        var frames: [[String: [String]]] = []
        /// Per frame: tether lines (fields after the frame number).
        var tethers: [[String]] = []
    }

    static func replay(_ text: String) -> Replayed {
        var r = Replayed()
        var state: [String: [String]] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("f ") {
                let parts = line.components(separatedBy: " | ")
                for e in parts.dropFirst() {
                    if e.hasPrefix("-") { state[String(e.dropFirst())] = nil; continue }
                    let f = e.split(separator: " ").map(String.init)
                    state[f[0]] = Array(f.dropFirst())
                }
                r.frames.append(state)
                r.tethers.append([])
            } else if line.hasPrefix("t "), !r.tethers.isEmpty {
                r.tethers[r.tethers.count - 1].append(line.split(separator: " ").dropFirst(2).joined(separator: " "))
            }
        }
        return r
    }

    /// Mismatches between two traces (at most `limit`), numbers within `tolerance`.
    static func differences(_ got: String, _ want: String, tolerance: Double = 0.002, zTolerance: Double = 0.00002,
                            limit: Int = 20) -> [String] {
        let a = replay(got), b = replay(want)
        var out: [String] = []
        func note(_ s: String) { if out.count < limit { out.append(s) } }
        if a.frames.count != b.frames.count { note("\(a.frames.count) frames, baseline \(b.frames.count)") }
        /// Numbers within `tolerance` (`zTolerance` for a node's zPosition, field 2), anything else equal.
        func same(_ x: [String], _ y: [String], node: Bool) -> Bool {
            guard x.count == y.count else { return false }
            for (i, (p, q)) in zip(x, y).enumerated() where p != q {
                let tol = node && i == 2 ? zTolerance : tolerance
                guard !(node && i >= 7), let u = Double(p), let v = Double(q), abs(u - v) <= tol + 1e-9 else { return false }
            }
            return true
        }
        for i in 0..<min(a.frames.count, b.frames.count) {
            let fa = a.frames[i], fb = b.frames[i]
            for path in Set(fa.keys).union(fb.keys).sorted() {
                switch (fa[path], fb[path]) {
                case let (x?, y?):
                    if !same(x, y, node: true) { note("frame \(i) \(path): \(x.joined(separator: " ")), baseline \(y.joined(separator: " "))") }
                case (nil, _?): note("frame \(i) \(path): missing")
                case (_?, nil): note("frame \(i) \(path): not in the baseline")
                default: break
                }
            }
            let ta = a.tethers[i], tb = b.tethers[i]
            if ta.count != tb.count { note("frame \(i): \(ta.count) tethers, baseline \(tb.count)"); continue }
            for (x, y) in zip(ta, tb) {
                let xs = x.split(separator: " ").map(String.init), ys = y.split(separator: " ").map(String.init)
                if !same(xs, ys, node: false) { note("frame \(i) tether: \(x), baseline \(y)") }
            }
        }
        return out
    }
}

/// Stable names for the images nodes draw (see the file header).
@MainActor final class TextureKeys {
    /// Names (text, small) and stripes the scenario's robots can carry.
    private let names: [(text: String, small: Bool, stripe: Color?)]
    private let header: () -> String?
    /// The texture a display drew for a node (scene traces); nil reads the node's own image.
    private let displayed: ((SceneNode) -> SKTexture?)?
    private var byImage: [ObjectIdentifier: String] = [:]
    /// Keeps the named images alive, so their identifiers stay theirs (and `RobotArt` hands out these objects).
    private var images: [BakedImage] = []
    private var arts: [ObjectIdentifier: RobotArt] = [:]
    private var byObject: [ObjectIdentifier: (object: AnyObject, key: String)] = [:]

    init(names: [(text: String, small: Bool, stripe: Color?)], header: @escaping () -> String? = { nil },
         displayed: ((SceneNode) -> SKTexture?)? = nil) {
        self.names = names
        self.header = header
        self.displayed = displayed
    }

    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "|", with: "/")
    }

    static func hex(_ c: Color?) -> String { c.map { String(format: "%06x", ArtSnapshotTests.hexOf(NSColor($0))) } ?? "-" }

    /// Every bubble the scene shows: an activity label on blue, or a status on its colour.
    static let bubbles: [(String, Color)] = ArtSnapshotTests.activities.map { ($0.label, Color(hex: 0x24477A)) } + [
        ("等你回复", Color(hex: 0xFFC95C)), ("✓ 做完了", Color(hex: 0x1F8F57)), ("出错了", Color(hex: 0xD84545))]

    private func name(_ image: BakedImage, _ key: String) {
        guard byImage[ObjectIdentifier(image)] == nil else { return }
        byImage[ObjectIdentifier(image)] = key
        images.append(image)
    }

    /// Names every image `art` can make for the scenario (once per art).
    private func register(_ art: RobotArt) {
        guard arts[ObjectIdentifier(art)] == nil else { return }
        arts[ObjectIdentifier(art)] = art
        let plain: [(RobotPart, String)] = [(.halo, "halo"), (.leftHand, "leftHand"), (.rightHand, "rightHand"),
                                            (.ears, "ears"), (.ring, "ring"), (.pod, "pod"), (.larkBadge, "larkBadge")]
        for (part, key) in plain { name(art.image(part), key) }
        // `.calm` shares `.focused`'s image: name it after `.focused`.
        for (face, key) in ArtSnapshotTests.faces where face != .calm { name(art.image(.eyes(face)), "eyes-\(key)") }
        for (kind, kindName) in ArtSnapshotTests.kinds {
            for team in ArtSnapshotTests.teams {
                for lark in [false, true] {
                    let look = RobotLook(kind: kind, teamIndex: team, larkSession: lark)
                    let suffix = "\(kindName):team\(team):lark\(lark ? 1 : 0)"
                    name(art.image(.torso(look)), "torso:\(suffix)")
                    name(art.image(.head(look)), "head:\(suffix)")
                    if look.hasHeadOverlay { name(art.image(.headOverlay(look)), "headOverlay:\(suffix)") }
                }
            }
        }
        for (prop, glyph, size) in ArtSnapshotTests.emojiProps {
            name(art.emoji(glyph, size: size), "emoji:\(prop):\(ArtSnapshotTests.sizeName(size))")
        }
        name(art.doorSign(), "door-sign")
        for (text, color) in Self.bubbles {
            name(art.bubble(text, color: color), "bubble:\(Self.clean(text)):\(Self.hex(color))")
            name(art.bubbleGlow(text, color: color), "bubble-glow:\(Self.clean(text)):\(Self.hex(color))")
        }
        for n in names {
            name(art.name(n.text, small: n.small, stripe: n.stripe), "name:\(Self.clean(n.text)):\(n.small ? 1 : 0):\(Self.hex(n.stripe))")
        }
    }

    /// `root`: the traced tree's root (the header is its direct child).
    func key(_ node: SceneNode, robot: RobotRig?, root: SceneNode) -> String {
        guard node.isSprite else { return "." }
        if let robot, let image = robot.sourceImage(of: node) {
            register(robot.art)
            return byImage[ObjectIdentifier(image)] ?? "unnamed:" + Self.digest(ArtSnapshotTests.pixels(image.cgImage))
        }
        guard node.image != nil || node.drawing != nil else { return "-" }
        if node.name == "header", node.parent === root, let h = header() { return "header:" + Self.clean(h) }
        let object: AnyObject
        let pixels: () -> CGImage
        if let displayed, let t = displayed(node) {
            object = t
            pixels = { t.cgImage() }
        } else if let img = node.image {
            object = img
            pixels = { img.cgImage }
        } else {
            let d = node.drawing!
            object = d
            pixels = { d.bake(with: CGArtBackend.shared).cgImage }
        }
        if let k = byObject[ObjectIdentifier(object)], k.object === object { return k.key }
        let key = "px:" + Self.digest(ArtSnapshotTests.pixels(pixels()))
        byObject[ObjectIdentifier(object)] = (object, key)
        return key
    }

    static func digest(_ p: ArtSnapshotTests.Pixels) -> String {
        "\(p.width)x\(p.height):" + SHA256.hash(data: Data(p.bytes)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
@Suite(.serialized) struct MotionSnapshotTests {
    static let recordVar = "AGENTRISE_RECORD_MOTION"
    static var baselineDir: URL { SnapshotPaths.fixtures.appendingPathComponent("motion") }
    static var actualDir: URL { SnapshotPaths.actual.appendingPathComponent("motion") }
    static let robotSeconds = 6.0
    static let sceneSeconds = 20.0
    static let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Single robots

    static let robotName = (text: "⚡ 修复登录\n高级工程师", small: false, stripe: Optional(Rank.seniorEngineer.stripe))

    /// A boss (senior engineer, team 0) at robot-art scale 2.5, as the model bakes them at 2×.
    static func robot(phase: TimeInterval) -> RobotRig {
        let look = RobotLook(kind: .boss(.seniorEngineer), teamIndex: 0, larkSession: false)
        let r = RobotRig(look: look, teamColor: look.teamColor, art: RobotArt(scale: 2.5), phase: phase)
        r.setName(robotName.text)
        r.root.position = CGPoint(x: 100, y: 40)
        return r
    }

    static func robotTrace(_ setup: (RobotRig) -> Void, phase: TimeInterval = 0) -> String {
        let r = robot(phase: phase)
        setup(r)
        let trace = MotionTrace(root: r.root, rootName: "robot", textures: TextureKeys(names: [robotName]),
                                rig: { $0 === r.root ? r : nil }, advance: MotionTrace.engine(r.root))
        trace.run(to: Int(robotSeconds * MotionTrace.fps))
        return trace.text
    }

    static func robotScenarios() -> [(name: String, trace: () -> String)] {
        var out: [(String, () -> String)] = []
        for a in ArtSnapshotTests.activities {
            out.append(("robot-\(a.rawValue)", { robotTrace { $0.setAction(a) } }))
        }
        out.append(("robot-waitingAtDoor-long", { robotTrace { $0.setAction(.waitingAtDoor, waitingLong: true) } }))
        for p in [0.0, 0.37] {
            out.append(("robot-idle-phase\(String(format: "%.2f", p))", { robotTrace({ _ in }, phase: p) }))
        }
        out.append(("robot-bubble-pulse", { robotTrace { $0.setBubble("等你回复", color: Color(hex: 0xFFC95C), pulse: true) } }))
        return out
    }

    // MARK: The whole scene

    static func session(_ id: String, title: String, status: SessionStatus, activity: Activity, team: Int, rank: Rank) -> Session {
        Session(id: id, title: title, source: .desktop(hostSessionId: nil), rank: rank, status: status,
                activity: activity, teamIndex: team, statusSince: fixedDate, lastActivityAt: fixedDate)
    }

    /// 20 s from an empty building: A walks in to the desks (2F); B walks in to wait at the CEO's door (3F);
    /// A takes the elevator to the archive (1F); A's two subs and a contractor walk in; hovering A dims B and
    /// ties A's team together; A is promoted (re-baked in place); sub x hands in its report and leaves, sub y
    /// fails and leaves, the contractor leaves; B's session ends and B walks out.
    static func sceneTrace() -> String {
        let model = TowerSceneModel(size: CGSize(width: 1200, height: 800), scale: 2, art: CGArtBackend.shared, clock: { fixedDate })
        // Fixed per robot, so the traces don't depend on the order robots are created in.
        let phases: [String: TimeInterval] = ["s:A": 0, "s:B": 0.37, "a:A:x": 0.9, "a:A:y": 1.3, "c:A:c": 1.75]
        model.idlePhase = { phases[$0] ?? 0 }
        let display = SpriteKitDisplay(model: model)
        // `.resizeFill` would size the scene to the view-less renderer's (empty) viewport; in the app the view
        // is the scene's size, where every scale mode leaves the scene as it is.
        display.scaleMode = .fill
        model.setHeader(TowerCounts(working: 1, waiting: 1))

        var a = session("A", title: "修复登录", status: .working, activity: .coding, team: 0, rank: .seniorEngineer)
        let b = session("B", title: "等你看", status: .waiting, activity: .coding, team: 1, rank: .newGrad)
        let keys = ["s:A", "s:B", "a:A:x", "a:A:y", "c:A:c"]

        // The names the scene can give these robots (bosses at any rank: A is promoted).
        var names: [(text: String, small: Bool, stripe: Color?)] = [("Explore", true, nil), ("Plan", true, nil), ("外包·跑测试", true, nil)]
        for s in [a, b] {
            for r in Rank.allCases { names.append(("\(Team.glyph(s.teamIndex)) \(s.title)\n\(r.title)", false, r.stripe)) }
        }
        model.render([], animated: false)
        let renderer = SKRenderer(device: MTLCreateSystemDefaultDevice()!)
        renderer.scene = display
        let textures = TextureKeys(names: names, header: { model.headerText },
                                   displayed: { display.skNode(for: $0).flatMap { ($0 as? SKSpriteNode)?.texture } })
        let trace = MotionTrace(root: model.root, rootName: nil, textures: textures,
                                rig: { n in keys.lazy.compactMap { model.robot($0) }.first { $0.root === n } },
                                advance: { renderer.update(atTime: $0) })
        trace.label = {
            var m: [ObjectIdentifier: String] = [:]
            for k in keys { if let r = model.robot(k) { m[ObjectIdentifier(r.root)] = "robot:\(k)" } }
            return m
        }
        trace.extra = { frame in
            model.tethers.map { t -> String in
                let name = t.node.name ?? ""
                guard let c = model.tetherCurve(from: "s:A", to: t.key) else { return "t \(frame) \(name) none" }
                func xy(_ p: CGPoint) -> String { "\(MotionTrace.number(p.x)) \(MotionTrace.number(p.y))" }
                var line = "t \(frame) \(name) from \(xy(c.from)) ctrl \(xy(c.control)) to \(xy(c.to))"
                // What the display's shape actually holds: the dashed copy of that curve.
                guard let path = (display.skNode(for: t.node) as? SKShapeNode)?.path else { return line + " drawn none" }
                var first: CGPoint?, last: CGPoint?
                path.applyWithBlock { e in
                    let el = e.pointee
                    let count: Int
                    switch el.type {
                    case .moveToPoint, .addLineToPoint: count = 1
                    case .addQuadCurveToPoint: count = 2
                    case .addCurveToPoint: count = 3
                    case .closeSubpath: count = 0
                    @unknown default: count = 0
                    }
                    guard count > 0 else { return }
                    if first == nil { first = el.points[0] }
                    last = el.points[count - 1]
                }
                let box = path.boundingBoxOfPath
                line += " drawn \(xy(first ?? .zero)) \(xy(last ?? .zero)) box \(xy(box.origin)) \(xy(CGPoint(x: box.width, y: box.height)))"
                return line
            }
        }
        func at(_ seconds: Double, _ change: () -> Void) {
            trace.run(to: Int((seconds * MotionTrace.fps).rounded()) - 1)
            change()
        }
        at(0.5) { model.render([a], animated: true) }
        at(1.0) { model.render([a, b], animated: true) }
        at(4.0) { a.activity = .reading; model.render([a, b], animated: true) }
        at(5.0) {
            a.subs = ["x": SubAgent(id: "x", type: "Explore", activity: .coding, startedAt: fixedDate),
                      "y": SubAgent(id: "y", type: "Plan", activity: .searching, startedAt: fixedDate + 1)]
            a.contractors = ["c": Contractor(id: "c", description: "跑测试", startedAt: fixedDate)]
            model.render([a, b], animated: true)
        }
        at(7.0) { model.highlight("A") }
        at(9.0) { a.rank = .seniorDirector; model.render([a, b], animated: true) }
        at(11.0) {
            model.noteSubResult(sessionId: "A", subId: "x", success: true)
            a.subs["x"] = nil
            model.render([a, b], animated: true)
        }
        at(12.0) { a.contractors = [:]; model.render([a, b], animated: true) }
        at(13.0) {
            model.noteSubResult(sessionId: "A", subId: "y", success: false)
            a.subs = [:]
            model.render([a, b], animated: true)
        }
        at(14.0) { model.render([a], animated: true) }
        trace.run(to: Int(sceneSeconds * MotionTrace.fps))
        precondition(display.size == CGSize(width: 1200, height: 800), "the renderer resized the scene")
        return trace.text
    }

    static func scenarios() -> [(name: String, trace: () -> String)] {
        robotScenarios() + [("scene-lifecycle", { sceneTrace() })]
    }

    // MARK: The test

    @Test func motionMatchesBaselines() throws {
        let record = SnapshotPaths.env(Self.recordVar)
        if record && SnapshotPaths.onCI {
            Issue.record("\(Self.recordVar)=1 on CI: CI only compares against the baselines, it never records them.")
            return
        }
        try SnapshotPaths.freshDirectory(Self.actualDir)
        if record { try FileManager.default.createDirectory(at: Self.baselineDir, withIntermediateDirectories: true) }
        var failures: [String] = []
        for (name, make) in Self.scenarios() {
            let file = name + ".txt"
            let text = make()
            try text.write(to: Self.actualDir.appendingPathComponent(file), atomically: true, encoding: .utf8)
            let baseline = Self.baselineDir.appendingPathComponent(file)
            if record {
                try text.write(to: baseline, atomically: true, encoding: .utf8)
                continue
            }
            guard let want = try? String(contentsOf: baseline, encoding: .utf8) else {
                failures.append("\(file): no baseline. Record with AGENTRISE_RECORD_MOTION=1 swift test --filter MotionSnapshotTests")
                continue
            }
            let diffs = MotionTrace.differences(text, want)
            if !diffs.isEmpty { failures.append("\(file):\n  " + diffs.joined(separator: "\n  ")) }
        }
        if !failures.isEmpty {
            Issue.record(Comment(rawValue: "Motion differs from Fixtures/motion (traces in \(Self.actualDir.path)):\n" + failures.joined(separator: "\n")))
        }
    }

    /// The same scenario twice in one process gives the same trace, and the comparison notices a nudge.
    @Test func tracesAreDeterministicAndCompared() {
        let a = Self.robotTrace { $0.setAction(.coding) }, b = Self.robotTrace { $0.setAction(.coding) }
        #expect(a == b)
        #expect(MotionTrace.differences(a, b).isEmpty)
        let nudged = a.replacingOccurrences(of: "robot/rig/float/leftHand 0.000", with: "robot/rig/float/leftHand 0.010")
        #expect(nudged != a)
        #expect(!MotionTrace.differences(nudged, a).isEmpty)
        // A part's z order (0.001 steps) and its image are compared too.
        let zSwapped = a.replacingOccurrences(of: " 0.00800 ", with: " 0.00900 ")
        #expect(zSwapped != a)
        #expect(!MotionTrace.differences(zSwapped, a).isEmpty)
        let retextured = a.replacingOccurrences(of: "eyes-focused", with: "eyes-happy")
        #expect(retextured != a)
        #expect(!MotionTrace.differences(retextured, a).isEmpty)
    }
}
