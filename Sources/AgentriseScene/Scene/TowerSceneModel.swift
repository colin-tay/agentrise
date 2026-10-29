// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Agentrise

/// The tower: who stands where, who walks, rides, fades and dims, as a `SceneNode` tree that a platform
/// display draws (`SpriteKitDisplay` on macOS). The display calls `step(dt:)` once per frame and then copies
/// the tree; it owns no logic. Layout and `Transit` coordinates are top-left origin (y down); `scenePoint(_:)`
/// flips them into the tree's SpriteKit convention (y up).
///
/// Nodes, bottom to top: `background`, `leds`, `cab`, `elevatorLabel`, `tethers`, `actors` (one `RobotRig` root
/// per robot), `header`, `tooltip`. Bitmaps are baked only when something they show changes (a robot's look, a
/// name or bubble, the size or scale, the header copy, the tooltip): frames only step tweens and move nodes.
package final class TowerSceneModel {
    package let root = SceneNode()
    package private(set) var geo: BuildingLayout
    package let transit: Transit
    /// Backing scale (pixels per point) the building, header and tooltip are drawn at; robots at 1.25 × that.
    package private(set) var scale: CGFloat
    /// Scene size in points (the layout's).
    package var size: CGSize { geo.size }

    private let backend: CountingBackend
    /// Every bitmap the model asked for: `ArtBackend.bake` calls (robot parts, labels, bubbles, LEDs) plus each
    /// `ArtDrawing` it made (the display draws each of those once). Constant while nothing changes.
    package var bakeCount: Int { backend.bakes + drawings }
    private var drawings = 0

    private let background = SceneNode(name: "background", sprite: true)
    private let cab = SceneNode(name: "cab", sprite: true)
    private let elevatorLabel = SceneNode(name: "elevatorLabel", sprite: true)
    private let leds = SceneNode(name: "leds")
    private let actors = SceneNode(name: "actors")
    private let tetherLayer = SceneNode(name: "tethers")
    private let tooltip = SceneNode(name: "tooltip")
    /// The header copy, drawn into a bitmap (an `SKLabelNode` re-laid out its text on every frame).
    private let header = SceneNode(name: "header", sprite: true)
    private var headerRuns: [TextRun]?
    private var headerBakedScale: CGFloat = 0

    // Robots: one rig per entity key ("s:<id>", "a:<id>:<sub>", "c:<id>:<contractor>").
    private var robots: [String: RobotRig] = [:]
    private var owner: [String: String] = [:]           // entity key → session id
    private var signatures: [String: String] = [:]
    private var lastSessions: [Session] = []
    private var pendingResults: [String: Bool] = [:]    // sub entity key → success
    private var departing: [String: Departure] = [:]
    private var fadingIn: [String: TimeInterval] = [:]  // entity key → seconds since the fade-in began
    private var hasRendered = false
    /// Stable per-key creation order: the draw-order tie-break for robots at the same height.
    private var drawOrder: [String: Int] = [:]
    private var nextDrawOrder = 0
    private var reportDrawings: [CGFloat: ArtDrawing] = [:]
    /// `transit.revision` the robots were last put in place for (nil = never).
    private var syncedRevision: Int?
    /// The atlas version the robots last queued their images for.
    private var atlasVersion = -1
    private var ledImages: [Color: BakedImage] = [:]
    private var ledImagesScale: CGFloat = 0

    /// A robot on its way out: (sub/contractor) to its boss, then to its floor's elevator door, then fading out.
    private struct Departure {
        let rig: RobotRig
        var leg: Leg
    }
    private enum Leg { case toBoss, toDoor, fading(TimeInterval) }

    package static let fadeInDuration: TimeInterval = 0.4
    package static let fadeOutDuration: TimeInterval = 0.5

    /// Z layers (the display sorts by zPosition only). Robots sit inside `actors` at `rank × robotZStep` (see
    /// `syncRobots`), so the header and tooltip stay far above them.
    private enum Z {
        static let background: CGFloat = 0, leds: CGFloat = 1, cab: CGFloat = 2, elevatorLabel: CGFloat = 2.5
        static let tethers: CGFloat = 3, actors: CGFloat = 4, header: CGFloat = 1_000, tooltip: CGFloat = 1_001
    }

    /// Injectable for tests.
    package var clock: () -> Date
    /// The idle-loop phase a new robot starts at, by entity key (random, so robots don't bob in step).
    /// Injectable for tests: the motion baselines need fixed phases.
    package var idlePhase: (_ key: String) -> TimeInterval = { _ in .random(in: 0...2.6) }

    package init(size: CGSize, scale: CGFloat, art: ArtBackend, clock: @escaping () -> Date = Date.init) {
        let size = CGSize(width: max(1, size.width), height: max(1, size.height))
        geo = BuildingLayout.make(size: size)
        transit = Transit(layout: geo)
        self.scale = scale
        self.clock = clock
        backend = CountingBackend(art)
        self.art = RobotArt(scale: scale * 1.25, backend: backend)
        atlas = TextureAtlas(backend: art)

        background.anchorPoint = .zero
        background.zPosition = Z.background
        cab.zPosition = Z.cab
        elevatorLabel.zPosition = Z.elevatorLabel
        leds.zPosition = Z.leds
        actors.zPosition = Z.actors
        tetherLayer.zPosition = Z.tethers
        tooltip.zPosition = Z.tooltip
        header.zPosition = Z.header
        header.anchorPoint = CGPoint(x: 0, y: 1)   // top-left, where the label's top-left alignment put the text
        for n in [background, leds, cab, elevatorLabel, tetherLayer, actors, header, tooltip] { root.addChild(n) }
        transit.onArrive = { [weak self] in self?.arrived($0) }
        relayout()
    }

    // MARK: Coordinates

    /// Layout (top-left origin) → scene (bottom-left origin).
    package func scenePoint(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: size.height - p.y) }
    package func layoutPoint(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: size.height - p.y) }

    // MARK: Layout

    /// The view's size or backing scale changed. A new size re-lays the building out (robots leaving are
    /// dropped, everyone else snaps to their slots); a new scale re-bakes the building and every robot.
    package func resize(to size: CGSize, scale: CGFloat) {
        let size = CGSize(width: max(1, size.width), height: max(1, size.height))
        let sizeChanged = size != geo.size, scaleChanged = scale != self.scale
        guard sizeChanged || scaleChanged else { return }
        self.scale = scale
        if sizeChanged {
            relayout(size)
        } else {
            bake()
            rebuildLeds()
        }
        if scaleChanged { rebakeRobots() }
    }

    private func relayout(_ size: CGSize? = nil) {
        // Room inference for `.thinking` needs the old layout's rooms with the old coordinates.
        let list = entities(lastSessions)
        geo = BuildingLayout.make(size: size ?? geo.size)
        for key in departing.keys { finishDeparture(key) }
        for (key, _) in fadingIn { robot(key)?.fade = 1 }
        fadingIn.removeAll()
        transit.relayout(geo, targets: slotTargets(list).mapValues(\.point))
        bake()
        rebuildLeds()
        placeHeader()
        placeCab()
        signatures.removeAll()
        if hasRendered { place(animated: false) }
    }

    private func draw(_ size: CGSize, scale: CGFloat, _ recipe: @escaping (Pen) -> Void) -> ArtDrawing {
        drawings += 1
        return ArtDrawing(size: size, scale: scale, draw: recipe)
    }

    private func bake() {
        if art.scale != artScale {
            // The old scale's art (and atlas) go once its robots are re-baked.
            art = RobotArt(scale: artScale, backend: backend)
            atlas = TextureAtlas(backend: backend.inner)
            atlasVersion = -1
            reportDrawings.removeAll()
        }
        let layout = geo
        background.drawing = draw(layout.size, scale: scale) { BuildingArt.drawBackground(layout, pen: $0) }
        background.size = layout.size
        background.position = .zero
        cab.drawing = draw(BuildingArt.cabSize(layout), scale: scale) { BuildingArt.drawCab(layout, pen: $0) }
        cab.size = BuildingArt.cabSize(layout)
        let labelSize = BuildingArt.elevatorLabelSize(backend)
        elevatorLabel.drawing = draw(labelSize, scale: scale) { BuildingArt.drawElevatorLabel(size: labelSize, pen: $0) }
        elevatorLabel.size = labelSize
        elevatorLabel.position = scenePoint(CGPoint(x: layout.elevator.midX, y: layout.elevator.midY))
        bakeHeader()
    }

    /// LEDs draw from the robot atlas (one batch instead of one draw per LED).
    private func rebuildLeds() {
        leds.removeAllChildren()
        if ledImagesScale != scale { ledImages.removeAll(); ledImagesScale = scale }   // same images on resize
        for spec in BuildingArt.ledSpecs(geo) {
            let image = ledImages[spec.color] ?? BuildingArt.led(color: spec.color, scale: scale, backend: backend)
            ledImages[spec.color] = image
            let led = SceneNode(sprite: true)
            led.image = image
            led.size = CGSize(width: 4, height: 4)
            atlas.want(image)
            led.position = scenePoint(spec.center)
            // The old CABasicAnimation: opacity 1 → 0.2, autoreversing, linear.
            led.run(.repeatForever(.sequence([.fadeAlpha(to: 0.2, duration: spec.period), .fadeAlpha(to: 1, duration: spec.period)])))
            leds.addChild(led)
        }
    }

    /// The cab body hangs 14 pt above the floor stop that `Transit.cabPosition` reports.
    private func placeCab() {
        let p = transit.cabPosition
        let sp = scenePoint(CGPoint(x: p.x, y: p.y - 14))
        if cab.position != sp { cab.position = sp }
    }

    // MARK: Frames

    /// One frame: move everyone, run the fade timers, put the robots where `Transit` says, then run the tweens
    /// and the tethers' flow (SpriteKit's order: `update`, then actions) and pack newly baked images into the atlas.
    package func step(dt: TimeInterval) {
        tick(dt)
        TweenEngine.step(root, dt: max(0, dt))
        flowTethers(dt)
        bindAtlas()
    }

    /// Runs the scene for `seconds` in 1/60 s frames (tests).
    package func advance(by seconds: TimeInterval) {
        var left = seconds
        while left > 1e-9 {
            let dt = min(1.0 / 60, left)
            step(dt: dt)
            left -= dt
        }
    }

    private func tick(_ dt: TimeInterval) {
        if let due = nextTimedChange, clock() >= due, hasRendered { place(animated: true) }
        let dt = min(Transit.maxStep, max(0, dt))
        transit.step(dt)
        if dt > 0 {
            for (key, t) in fadingIn {
                let e = t + dt
                robot(key)?.fade = CGFloat(min(1, e / Self.fadeInDuration))
                fadingIn[key] = e >= Self.fadeInDuration ? nil : e
            }
            for (key, d) in departing {
                guard case let .fading(t) = d.leg else { continue }
                let e = t + dt
                if e >= Self.fadeOutDuration { finishDeparture(key); continue }
                d.rig.fade = min(d.rig.fade, CGFloat(1 - e / Self.fadeOutDuration))
                departing[key]?.leg = .fading(e)
            }
        }
        // Nothing walked, rode or was placed: the robots are already where Transit says.
        if transit.revision != syncedRevision {
            syncRobots()
            placeCab()
        }
    }

    /// The current scale's atlas: robot parts and LEDs, packed for batched drawing. Held here (not looked up
    /// per frame); a new scale gets a new one.
    package private(set) var atlas: TextureAtlas

    /// Packs newly baked images into the atlas. When its version changes (new images, or a reset), every robot
    /// and LED asks for its images again, so anything a reset dropped comes back on the next commit.
    private func bindAtlas() {
        atlas.commit()
        guard atlas.version != atlasVersion else { return }
        atlasVersion = atlas.version
        requeueAtlas()
    }

    /// Every robot and LED queues the images it shows on the atlas again.
    private func requeueAtlas() {
        for (_, r) in robots { r.requeue() }
        for (_, d) in departing { d.rig.requeue() }
        for l in leds.children { if let img = l.image { atlas.want(img) } }
    }

    // MARK: Header

    package func setHeader(_ c: TowerCounts) {
        var runs: [TextRun] = []
        func add(_ t: String, _ color: Color, bold: Bool = false) {
            runs.append(TextRun(t, font: FontSpec(size: 12, weight: bold ? .heavy : .medium), color: color))
        }
        add("AGENTRISE    ", Color(r: 1, g: 1, b: 1), bold: true)
        add("在岗 \(c.working)    ", Color(hex: 0x9FB3FF))
        add("等你 \(c.waiting)    ", Color(hex: 0xFFC95C), bold: c.waiting > 0)
        add("完成 \(c.done)    ", Color(hex: 0x6FF0A8))
        add("待命 \(c.standby)    ", Color(hex: 0x9FB3FF))
        add("小弟 \(c.subs) · 外包 \(c.contractors)    ", Color(hex: 0x9FB3FF))
        add("睡觉 \(c.sleeping)", Color(hex: 0xB8B0FF))
        guard runs != headerRuns else { return }
        headerRuns = runs
        headerBakedScale = 0
        bakeHeader()
    }

    /// The header's plain text (for tests).
    package var headerText: String { headerRuns?.map(\.text).joined() ?? "" }

    /// Draws the header copy (when the copy or the scale changed).
    private func bakeHeader() {
        placeHeader()
        guard let runs = headerRuns, headerBakedScale != scale else { return }
        headerBakedScale = scale
        let m = backend.measure(runs, maxWidth: .infinity, maxLines: 0)
        let size = CGSize(width: max(1, ceil(m.width)), height: max(1, ceil(m.height)))
        header.drawing = draw(size, scale: scale) { $0.textLine(runs, in: CGRect(origin: .zero, size: size), truncatesTail: false) }
        header.size = size
    }

    private func placeHeader() { header.position = scenePoint(CGPoint(x: 14, y: 9)) }

    // MARK: Robots

    private struct Entity {
        var key: String
        var sessionId: String
        var kind: RobotKind
        var room: Room
        var activity: Activity
        var order: Int
        var name: String
        var face: RobotFace
        var bubble: (String, Color, Bool)?
        var larkBadge: Bool
        var waitingLong: Bool
    }

    /// The robot for an entity key, including one that is on its way out.
    package func robot(_ key: String) -> RobotRig? { robots[key] ?? departing[key]?.rig }

    package func noteSubResult(sessionId: String, subId: String, success: Bool) { pendingResults["a:\(sessionId):\(subId)"] = success }

    /// The first render of a scene places everyone without animation; later ones walk, ride and fade.
    /// A render without animation means no frames are running (a hidden, minimised or covered window), so nothing
    /// commits the atlas: its queue is cut back to the images still on screen, instead of holding every name and
    /// bubble baked while the window was away (on Windows, closed to the tray for days). The next frame packs them.
    package func render(_ sessions: [Session], animated: Bool) {
        lastSessions = sessions
        place(animated: animated && hasRendered)
        hasRendered = true
        if !animated {
            atlas.dropPending()
            requeueAtlas()
        }
    }

    /// The room whose (slightly enlarged) rect holds a point — where a robot "currently" is.
    private func room(at p: CGPoint?) -> Room? {
        guard let p else { return nil }
        return geo.rooms.first { $0.value.contains { $0.insetBy(dx: -4, dy: -20).contains(p) } }?.key
    }

    /// How long a finished robot stands at the CEO's door with its report before going for coffee.
    package static let reportDuration: TimeInterval = 20 * 60
    /// After this long at the door, a waiting robot waves more urgently.
    package static let waitingLongAfter: TimeInterval = 600
    /// The next moment an entity changes room or pose purely because time passed; the controller only
    /// renders on change, so the scene re-places itself then.
    private var nextTimedChange: Date?

    private func entities(_ sessions: [Session]) -> [Entity] {
        var out: [Entity] = []
        let now = clock()
        var due: Date?
        func dueAt(_ d: Date) { if d > now, due.map({ d < $0 }) ?? true { due = d } }
        defer { nextTimedChange = due }
        for s in sessions.sorted(by: { $0.teamIndex < $1.teamIndex }) where !s.isHidden {
            let current = room(at: transit.target(of: "s:\(s.id)"))
            let room: Room
            var face: RobotFace = .focused
            var bubble: (String, Color, Bool)? = nil
            var act = s.activity
            switch s.status {
            case .waiting: room = .ceoOffice; face = .waiting; act = .waitingAtDoor
                bubble = ("等你回复", Color(hex: 0xFFC95C), true)
            case .done:
                // Report to the CEO first, then rest in the pantry.
                let reportEnds = s.statusSince.addingTimeInterval(Self.reportDuration)
                if now < reportEnds { room = .ceoOffice; act = .reporting; dueAt(reportEnds) } else { room = .pantry; act = .resting }
                face = .happy
                bubble = ("✓ 做完了", Color(hex: 0x1F8F57), false)
            case .error: room = .serverRoom; face = .error; act = .commandFailed
                bubble = ("出错了", Color(hex: 0xD84545), true)
            case .standby: room = .desks; face = .calm; act = .standby
            case .sleeping: room = .sleepPods; face = .asleep; act = .sleeping
            case .working:
                room = ActivityMap.room(for: s.activity) ?? current ?? .desks
                if s.transientErrorAt != nil { face = .error; act = .commandFailed }
                bubble = (s.activity.label, Color(hex: 0x24477A), false)
            }
            let waitingLong = s.status == .waiting && now.timeIntervalSince(s.statusSince) > Self.waitingLongAfter
            if s.status == .waiting, !waitingLong { dueAt(s.statusSince.addingTimeInterval(Self.waitingLongAfter + 0.001)) }
            let title = s.title.count > 9 ? String(s.title.prefix(8)) + "…" : s.title
            out.append(Entity(key: "s:\(s.id)", sessionId: s.id, kind: .boss(s.rank), room: room, activity: act, order: s.teamIndex * 100,
                              name: "\(Team.glyph(s.teamIndex)) \(title)\n\(s.rank.title)", face: face, bubble: bubble,
                              larkBadge: s.larkSent, waitingLong: waitingLong))
            for (i, sub) in s.subs.values.sorted(by: { $0.startedAt < $1.startedAt }).enumerated() {
                let key = "a:\(s.id):\(sub.id)"
                let sr = ActivityMap.room(for: sub.activity) ?? self.room(at: transit.target(of: key)) ?? .meeting
                out.append(Entity(key: key, sessionId: s.id, kind: .sub, room: sr, activity: sub.activity, order: s.teamIndex * 100 + 1 + i,
                                  name: sub.type.isEmpty ? "小弟" : String(sub.type.prefix(12)), face: .focused, bubble: nil, larkBadge: false, waitingLong: false))
            }
            for (i, c) in s.contractors.values.sorted(by: { $0.startedAt < $1.startedAt }).enumerated() {
                out.append(Entity(key: "c:\(s.id):\(c.id)", sessionId: s.id, kind: .contractor, room: .serverRoom, activity: .runningCommand, order: s.teamIndex * 100 + 50 + i,
                                  name: "外包·" + String(c.description.prefix(10)), face: .focused, bubble: nil, larkBadge: false, waitingLong: false))
            }
        }
        return out
    }

    /// Slot (bottom centre, layout coordinates) and robot scale for every entity, room by room.
    private func slotTargets(_ list: [Entity]) -> [String: (point: CGPoint, scale: CGFloat)] {
        let base = CGSize(width: 60 * geo.unit, height: 84 * geo.unit)
        var targets: [String: (point: CGPoint, scale: CGFloat)] = [:]
        for room in Room.allCases {
            let members = list.filter { $0.room == room }.sorted { $0.order < $1.order }
            guard !members.isEmpty else { continue }
            let (pts, scale) = SlotAllocator.slots(in: geo.rooms[room] ?? [], count: members.count, base: base, minCellWidth: 104 * geo.unit)
            for (m, p) in zip(members, pts) {
                let k: CGFloat = m.kind == .sub || m.kind == .contractor ? 0.62 : 1
                targets[m.key] = (p, geo.unit * scale * k)
            }
        }
        return targets
    }

    /// Robot parts bake at the building's scale × 1.25.
    private var artScale: CGFloat { scale * 1.25 }
    /// The current scale's robot art.
    private var art: RobotArt

    /// Swaps every robot (staying or leaving) for a copy baked at the current scale; positions, alpha,
    /// state and `Transit` are untouched, and a leaving sub gets its report card back.
    private func rebakeRobots() {
        func swap(_ old: RobotRig) -> RobotRig {
            let new = old.rebaked(with: art)
            new.atlas = atlas
            if old.root.childNode(withName: "report") != nil { attachReport(to: new) }
            old.root.removeFromParent()
            actors.addChild(new.root)
            return new
        }
        for key in robots.keys.sorted() { robots[key] = swap(robots[key]!) }
        for key in departing.keys.sorted() { departing[key] = Departure(rig: swap(departing[key]!.rig), leg: departing[key]!.leg) }
    }

    private func place(animated: Bool) {
        let list = entities(lastSessions)
        let sessionsById = Dictionary(lastSessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let targets = slotTargets(list)
        let wanted = Set(list.map(\.key))
        if !animated {
            // No frames are coming (a covered window renders without animation) or none are wanted: nobody
            // walks out, so anything on its way out or fading in is finished now instead of piling up.
            for key in departing.keys.sorted() where !wanted.contains(key) { finishDeparture(key) }
            for key in fadingIn.keys.sorted() { robot(key)?.fade = 1 }
            fadingIn.removeAll()
        }
        for key in robots.keys.sorted() where !wanted.contains(key) {
            if animated { depart(key, wanted: wanted) } else { discard(key) }
        }
        for e in list {
            guard let (pt, scale) = targets[e.key], let s = sessionsById[e.sessionId] else { continue }
            let rig: RobotRig
            var isNew = false
            let look = RobotLook(kind: e.kind, teamIndex: s.teamIndex, larkSession: e.kind != .sub && e.kind != .contractor && s.isLark)
            if let r = robots[e.key] {
                rig = r
            } else if let d = departing.removeValue(forKey: e.key) {
                // Back before it left: drop the report and fade back in from wherever the fade-out got to.
                rig = d.rig
                rig.root.childNode(withName: "report")?.removeFromParent()
                if !animated { rig.fade = 1 } else if rig.fade < 1 { fadingIn[e.key] = Double(rig.fade) * Self.fadeInDuration }
                robots[e.key] = rig
                owner[e.key] = e.sessionId
            } else {
                rig = RobotRig(look: look, teamColor: Team.color(s.teamIndex), art: art, phase: idlePhase(e.key))
                rig.atlas = atlas
                robots[e.key] = rig
                owner[e.key] = e.sessionId
                drawOrder[e.key] = nextDrawOrder
                nextDrawOrder += 1
                actors.addChild(rig.root)
                isNew = true
            }
            // A rank changed in Settings: redraw the robot where it stands (no new entrance).
            if !isNew, rig.look.kind != look.kind { rig.setLook(look, name: e.name) }
            let sig = "\(e.name)|\(e.face)|\(e.activity)|\(e.waitingLong)|\(e.bubble?.0 ?? "")|\(e.larkBadge)|\(pt.x),\(pt.y)|\(scale)"
            if !isNew, signatures[e.key] == sig { continue }
            signatures[e.key] = sig
            rig.setName(e.name)
            rig.setFace(e.face)
            rig.setAction(e.activity, waitingLong: e.activity == .waitingAtDoor && e.waitingLong)
            rig.setBubble(e.bubble?.0, color: e.bubble?.1 ?? Color(r: 0, g: 0, b: 0, a: 0), pulse: e.bubble?.2 ?? false)
            rig.setLarkBadge(e.larkBadge)
            if rig.robotScale != scale { rig.setRobotScale(scale) }
            if isNew {
                if animated {
                    // Arrive by the elevator: appear at the target floor's door, fade in, walk to the slot.
                    transit.place(e.key, at: geo.elevatorDoor(floor: geo.floorOf(pt), side: geo.doorSide(for: pt)))
                    transit.send(e.key, to: pt)
                    rig.fade = 0
                    fadingIn[e.key] = 0
                } else {
                    transit.place(e.key, at: pt)
                }
            } else if let t = transit.target(of: e.key), hypot(t.x - pt.x, t.y - pt.y) <= 1.5 {
                continue
            } else if animated {
                transit.send(e.key, to: pt)
            } else {
                transit.place(e.key, at: pt)
            }
        }
        syncRobots()
        applyHighlight()
    }

    /// Subs and contractors walk back to their boss (a sub carrying its report, or smoking if it failed),
    /// then everyone leaves by their floor's elevator door and fades out.
    private func depart(_ key: String, wanted: Set<String>) {
        guard let rig = robots.removeValue(forKey: key) else { return }
        signatures[key] = nil
        let sid = owner.removeValue(forKey: key) ?? ""
        let success = pendingResults.removeValue(forKey: key) ?? true
        if !success {
            rig.setFace(.error)
            rig.setAction(.commandFailed)
        } else if key.hasPrefix("a:") {
            rig.setFace(.happy)
            attachReport(to: rig)
        }
        let boss = "s:\(sid)"
        if key.hasPrefix("a:") || key.hasPrefix("c:"), wanted.contains(boss), let b = transit.target(of: boss) {
            departing[key] = Departure(rig: rig, leg: .toBoss)
            transit.send(key, to: CGPoint(x: b.x + 22, y: b.y))
        } else {
            departing[key] = Departure(rig: rig, leg: .toDoor)
            sendToDoor(key)
        }
    }

    /// Removes a robot at once, with no walk or fade (a non-animated render).
    private func discard(_ key: String) {
        guard let rig = robots.removeValue(forKey: key) else { return }
        signatures[key] = nil
        owner[key] = nil
        pendingResults[key] = nil
        fadingIn[key] = nil
        drawOrder[key] = nil
        rig.root.removeAllTweens()
        rig.root.removeFromParent()
        transit.remove(key)
    }

    private func sendToDoor(_ key: String) {
        guard let p = transit.position(of: key) else { finishDeparture(key); return }
        // A rider mid-shaft exits at the stop the cab is heading to; the floor under the cab may be the one it just left.
        let floor = transit.phase(of: key) == .riding ? transit.cabHeading : geo.floorOf(p)
        transit.send(key, to: geo.elevatorDoor(floor: floor, side: geo.doorSide(for: p)))
    }

    private func arrived(_ key: String) {
        guard let d = departing[key] else { return }
        switch d.leg {
        case .toBoss:
            departing[key]?.leg = .toDoor
            sendToDoor(key)
        case .toDoor:
            fadingIn[key] = nil
            departing[key]?.leg = .fading(0)
        case .fading:
            break
        }
    }

    private func finishDeparture(_ key: String) {
        guard let d = departing.removeValue(forKey: key) else { return }
        fadingIn[key] = nil
        drawOrder[key] = nil
        d.rig.root.removeAllTweens()
        d.rig.root.removeFromParent()
        transit.remove(key)
    }

    /// Robots follow `Transit`. Draw order: robots are ranked by layout y (lower on screen in front), ties —
    /// riders sharing the cab, robots waiting at the same door — broken by a stable per-key creation order,
    /// and each rank gets its own `robotZStep` band. A robot's parts span < 0.015 above its own z, so no
    /// two robots' parts can interleave, whatever their positions.
    private func syncRobots() {
        var placed: [(y: CGFloat, order: Int, node: SceneNode)] = []
        placed.reserveCapacity(robots.count + departing.count)
        func sync(_ key: String, _ rig: RobotRig) {
            guard let p = transit.position(of: key) else { return }
            let sp = scenePoint(p)
            if rig.root.position != sp { rig.root.position = sp }
            placed.append((p.y, drawOrder[key] ?? 0, rig.root))
        }
        for (key, rig) in robots { sync(key, rig) }
        for (key, d) in departing { sync(key, d.rig) }
        placed.sort { ($0.y, $0.order) < ($1.y, $1.order) }
        for (i, r) in placed.enumerated() {
            let z = CGFloat(i) * Self.robotZStep
            if r.node.zPosition != z { r.node.zPosition = z }
        }
        syncedRevision = transit.revision
    }

    /// z distance between consecutive robots: more than a robot's own part span (0.015).
    package static let robotZStep: CGFloat = 0.02

    // MARK: Report

    /// The old report card a finished sub carries back: 10×13, 0xBFE8FF, corner 2, glow 0x7CC4FF radius 5,
    /// centred at design point (52, 58) and drawn above the whole robot.
    private func attachReport(to rig: RobotRig) {
        guard rig.root.childNode(withName: "report") == nil else { return }
        let n = SceneNode(name: "report", sprite: true)
        n.drawing = reportDrawing()
        n.size = Self.reportImageSize
        n.position = RobotMotion.robotPoint(CGPoint(x: 52, y: 58))
        n.zPosition = 0.0145
        rig.root.addChild(n)
    }

    private static let reportPadding: CGFloat = 8
    private static var reportImageSize: CGSize { CGSize(width: 10 + 2 * reportPadding, height: 13 + 2 * reportPadding) }

    private func reportDrawing() -> ArtDrawing {
        let scale = artScale
        if let d = reportDrawings[scale] { return d }
        let pad = Self.reportPadding
        let d = draw(Self.reportImageSize, scale: scale) { pen in
            pen.shadowed(offset: .zero, blur: 5, color: Color(hex: 0x7CC4FF)) {
                pen.fill(.roundedRect(CGRect(x: pad, y: pad, width: 10, height: 13), radius: 2), Color(hex: 0xBFE8FF))
            }
        }
        reportDrawings[scale] = d
        return d
    }

    // MARK: Hit testing, hover, click

    package var onClickSession: ((String) -> Void)?
    package var onHoverSession: ((String?) -> Void)?

    /// The session highlighted by the pointer or by the panel (the old `hovered`).
    private var hovered: String?
    package private(set) var tooltipLines: [String] = []
    private var tooltipSignature = ""

    /// The session whose robot is under a layout point: the 60×84 box of every robot standing in the
    /// scene (not the ones leaving); with several hits, the one whose middle is closest to the point.
    package func sessionId(at layoutPoint: CGPoint) -> String? {
        let p = scenePoint(layoutPoint)
        var best: (key: String, d: CGFloat)?
        for (key, rig) in robots where rig.hitRect.contains(p) {
            let at = rig.root.position
            let d = hypot(at.x - p.x, at.y + 42 * rig.robotScale - p.y)
            if best == nil || d < best!.d || (d == best!.d && key < best!.key) { best = (key, d) }
        }
        return best.flatMap { owner[$0.key] }
    }

    /// The pointer moved to a layout point (nil = it left the view): highlight, tooltip and panel follow.
    /// Returns the session under the pointer and the tooltip shown for it.
    @discardableResult
    package func hover(at layoutPoint: CGPoint?) -> (sessionId: String?, tooltip: SceneNode?) {
        let sid = layoutPoint.flatMap { sessionId(at: $0) }
        if sid != hovered {
            highlight(sid)
            onHoverSession?(sid)
        }
        return (sid, showTooltip(sid, at: layoutPoint ?? .zero))
    }

    package func click(at layoutPoint: CGPoint) {
        if let sid = sessionId(at: layoutPoint) { onClickSession?(sid) }
    }

    // MARK: Highlight and tethers

    /// A dashed line from the highlighted boss to one of its subs or contractors. `phase` is the dash phase the
    /// flow is at (−24 pt per 1.2 s, see `flowTethers`); the display draws the line from `tetherCurve`.
    package final class Tether {
        package let node: SceneNode
        package let bossKey: String, key: String
        package let color: Color
        package fileprivate(set) var phase: CGFloat = 0
        /// Seconds into the current flow cycle (nil until the first frame).
        fileprivate var elapsed: TimeInterval?

        fileprivate init(bossKey: String, key: String, color: Color) {
            node = SceneNode(name: TowerSceneModel.tetherPrefix + key)
            self.bossKey = bossKey
            self.key = key
            self.color = color
        }
    }

    /// The highlighted team's tethers (their nodes hang off `tethers`).
    package private(set) var tethers: [Tether] = []

    /// Dims everyone not on the session's team and ties its subs and contractors to the boss with flowing
    /// dashed lines. Robots on their way out keep fading and are left alone.
    package func highlight(_ sessionId: String?) {
        hovered = sessionId
        applyHighlight()
    }

    private func applyHighlight() {
        // The highlighted session left the list (e.g. its panel row vanished, so no hover-out will come):
        // drop the highlight, tell the panel and take the tooltip down.
        if let sid = hovered, !lastSessions.contains(where: { $0.id == sid }) {
            hovered = nil
            onHoverSession?(nil)
            showTooltip(nil, at: .zero)
        }
        for (key, rig) in robots { rig.setDimmed(hovered != nil && owner[key] != hovered) }
        guard let sid = hovered, let s = lastSessions.first(where: { $0.id == sid }), robots["s:\(sid)"] != nil else {
            clearTethers()
            return
        }
        let bossKey = "s:\(sid)"
        let keys = robots.keys.sorted().filter { owner[$0] == sid && $0 != bossKey }
        // Unchanged set: keep the nodes, so a re-render doesn't restart the flow.
        if tethers.map(\.key) == keys { return }
        clearTethers()
        for key in keys {
            let t = Tether(bossKey: bossKey, key: key, color: Team.color(s.teamIndex))
            tetherLayer.addChild(t.node)
            tethers.append(t)
        }
    }

    private func clearTethers() {
        tetherLayer.removeAllChildren()
        tethers.removeAll()
    }

    /// The old lineDashPhase animation 0 → −24 over 1.2 s, repeating, on the clock SpriteKit gave the custom
    /// action that ran it (measured with `SKRenderer`): a tether's first frame is at 0 s; elapsed time reaches the
    /// block rounded to `Float`; a cycle ends when that `Float` time reaches the `Float` period, and the next
    /// starts from what is left over (never below 0).
    private func flowTethers(_ dt: TimeInterval) {
        let period = Double(Float(Self.tetherPeriod))
        for t in tethers {
            var e = t.elapsed.map { $0 + max(0, dt) } ?? 0
            while Float(e) >= Float(period) { e = max(0, e - period) }
            t.elapsed = e
            t.phase = -24 * (CGFloat(Float(e)) / CGFloat(Self.tetherPeriod))
        }
    }

    package static let tetherPrefix = "tether:"
    private static let tetherPeriod: TimeInterval = 1.2

    /// The tether's quad curve from the boss's head to a robot's chest, in scene coordinates (nil while either
    /// is gone). The display dashes it; the motion baselines record it.
    package func tetherCurve(from bossKey: String, to key: String) -> (from: CGPoint, control: CGPoint, to: CGPoint)? {
        guard let bp = transit.position(of: bossKey), let bs = robot(bossKey)?.robotScale,
              let rp = transit.position(of: key), let rs = robot(key)?.robotScale else { return nil }
        let b = CGPoint(x: bp.x, y: bp.y - 40 * bs), p = CGPoint(x: rp.x, y: rp.y - 30 * rs)
        return (scenePoint(b), scenePoint(CGPoint(x: (b.x + p.x) / 2, y: min(b.y, p.y) - 40)), scenePoint(p))
    }

    // MARK: Tooltip

    /// The old detail box's text, one string per line.
    package static func tooltipLines(for s: Session, now: Date = Date()) -> [String] {
        let status: String
        switch s.status {
        case .working: status = "干活中 · \(s.activity.label)"
        case .waiting: status = "等你回复" + (s.waitingSummary.map { "：\($0)" } ?? "")
        case .done: status = "做完了"
        case .error: status = "出错了" + (s.waitingSummary.map { "（\($0)）" } ?? "")
        case .standby: status = "待命"
        case .sleeping: status = "睡觉中"
        }
        let mins = Int(now.timeIntervalSince(s.statusSince) / 60)
        let src: String
        switch s.source {
        case .desktop: src = "Claude App"
        case .lark: src = "飞书"
        case .terminal: src = "终端"
        }
        var lines = ["\(Team.glyph(s.teamIndex)) \(s.title)", "\(s.rank.title) · \(src)", "\(status) · \(mins) 分钟",
                     "小弟 \(s.subs.count) 在岗 · 已交付 \(s.delivered) · 失败 \(s.failedSubs)"]
        if s.capabilities.contains(.contractors) { lines.append("外包 \(s.contractors.count) 在岗 · 已完成 \(s.contractorsDone)") }
        return lines
    }

    /// Shows the detail box for a session next to a layout point, or removes it at once (no fade: the old
    /// fade-out left boxes stuck on screen). Returns the box.
    @discardableResult
    package func showTooltip(_ sid: String?, at p: CGPoint) -> SceneNode? {
        guard let sid, let s = lastSessions.first(where: { $0.id == sid }) else {
            tooltip.removeAllChildren()
            tooltipLines = []
            tooltipSignature = ""
            return nil
        }
        let lines = Self.tooltipLines(for: s)
        let signature = "\(lines.joined(separator: "\n"))|\(s.teamIndex)|\(scale)"
        let box: SceneNode
        if signature == tooltipSignature, let existing = tooltip.children.first {
            box = existing
        } else {
            tooltip.removeAllChildren()
            box = SceneNode(sprite: true)
            let (size, recipe) = Self.tooltipArt(lines, color: Team.color(s.teamIndex), measure: backend)
            box.drawing = draw(size, scale: scale, recipe)
            box.size = size
            box.anchorPoint = CGPoint(x: 0, y: 1)   // top-left, like the old layer in the flipped view
            tooltip.addChild(box)
            tooltipLines = lines
            tooltipSignature = signature
        }
        var o = CGPoint(x: p.x + 14, y: p.y + 14)
        if o.x + box.size.width > size.width { o.x = p.x - box.size.width - 10 }
        if o.y + box.size.height > size.height { o.y = p.y - box.size.height - 10 }
        box.position = scenePoint(o)
        return box
    }

    /// 0x0A0E26 at 0.95, a 1 pt team-colour border inside a corner radius of 8; the first line 12 pt bold
    /// white, the rest 10.5 pt regular 0xC9D2FF, 2 pt apart; at most 320 pt wide.
    package static func tooltipArt(_ lines: [String], color: Color, measure m: TextMeasuring) -> (CGSize, (Pen) -> Void) {
        struct Row { var run: TextRun; var rect: CGRect }
        var rows: [Row] = []
        var y: CGFloat = 8, w: CGFloat = 0
        for (i, line) in lines.enumerated() {
            let font = FontSpec(size: i == 0 ? 12 : 10.5, weight: i == 0 ? .bold : .regular)
            let box = ArtKit.labelSize(line, font: font, using: m)
            let run = TextRun(line, font: font, color: i == 0 ? Color(r: 1, g: 1, b: 1) : Color(hex: 0xC9D2FF))
            rows.append(Row(run: run, rect: CGRect(x: 10, y: y, width: box.width, height: box.height)))
            y += box.height + 2
            w = max(w, box.width)
        }
        let size = CGSize(width: min(w + 20, 320), height: y + 6)
        return (size, { pen in
            let outer = CGRect(origin: .zero, size: size)
            pen.fill(.roundedRect(outer, radius: 8), Color(hex: 0x0A0E26, alpha: 0.95))
            pen.stroke(.roundedRect(outer.insetBy(dx: 0.5, dy: 0.5), radius: 7.5), color, width: 1)
            for r in rows {
                var rect = r.rect
                rect.size.width = min(rect.width, size.width - 20)   // truncate rather than spill over the border
                pen.textLine([r.run], in: rect, truncatesTail: true)
            }
        })
    }
}

/// Forwards to the real backend and counts its bakes (`TowerSceneModel.bakeCount`).
private final class CountingBackend: ArtBackend {
    let inner: ArtBackend
    private(set) var bakes = 0

    init(_ inner: ArtBackend) { self.inner = inner }

    func bake(size: CGSize, scale: CGFloat, _ draw: (Pen) -> Void) -> BakedImage {
        bakes += 1
        return inner.bake(size: size, scale: scale, draw)
    }

    func rgba(_ img: BakedImage) -> [UInt8] { inner.rgba(img) }

    func measure(_ runs: [TextRun], maxWidth: CGFloat, maxLines: Int) -> CGSize {
        inner.measure(runs, maxWidth: maxWidth, maxLines: maxLines)
    }
}
