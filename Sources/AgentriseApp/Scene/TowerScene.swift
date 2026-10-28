// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import AppKit
import SpriteKit
import Agentrise

/// The SpriteKit tower. Layout and `Transit` coordinates are top-left origin (y down);
/// `scenePoint(_:)` flips them for SpriteKit when assigning to nodes.
final class TowerScene: SKScene {
    private(set) var geo: BuildingLayout
    let transit: Transit
    var onLayout: ((BuildingLayout) -> Void)?

    private let backgroundSprite = SKSpriteNode()
    private let cab = SKSpriteNode()
    private let elevatorLabel = SKSpriteNode()
    private let leds = SKNode()
    private let actors = SKNode()
    private let tethers = SKNode()
    private let tooltip = SKNode()
    /// The header copy, baked into a texture (an `SKLabelNode` re-laid out its text on every frame).
    private let header = SKSpriteNode()
    private var headerString: NSAttributedString?
    private var headerBakedScale: CGFloat = 0
    private var lastUpdate: TimeInterval?
    private var bakedScale: CGFloat = 0

    // Robots: one sprite per entity key ("s:<id>", "a:<id>:<sub>", "c:<id>:<contractor>").
    private var robots: [String: RobotSprite] = [:]
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
    private var reportTextures: [CGFloat: SKTexture] = [:]
    /// `transit.revision` the sprites were last put in place for (nil = never).
    private var syncedRevision: Int?
    /// The robot atlas version the sprites' textures were last bound against. Versions count per atlas
    /// (one per scale), so a scale change resets this.
    private var atlasVersion = -1
    /// LED sprites and their images, rebound with the robots when the atlas changes.
    private var ledSources: [(node: SKSpriteNode, image: CGImage)] = []
    private var ledImages: [NSColor: CGImage] = [:]
    private var ledImagesScale: CGFloat = 0

    /// A robot on its way out: (sub/contractor) to its boss, then to its floor's elevator door, then fading out.
    private struct Departure {
        let sprite: RobotSprite
        var leg: Leg
    }
    private enum Leg { case toBoss, toDoor, fading(TimeInterval) }

    static let fadeInDuration: TimeInterval = 0.4
    static let fadeOutDuration: TimeInterval = 0.5

    /// Z layers (the view sorts by zPosition only: `ignoresSiblingOrder`). Robots sit inside `actors` at
    /// `rank × robotZStep` (see `syncSprites`), so the header and tooltip stay far above them.
    private enum Z {
        static let background: CGFloat = 0, leds: CGFloat = 1, cab: CGFloat = 2, elevatorLabel: CGFloat = 2.5
        static let tethers: CGFloat = 3, actors: CGFloat = 4, header: CGFloat = 1_000, tooltip: CGFloat = 1_001
    }

    override init(size: CGSize) {
        let size = CGSize(width: max(1, size.width), height: max(1, size.height))
        geo = BuildingLayout.make(size: size)
        transit = Transit(layout: geo)
        super.init(size: size)
        scaleMode = .resizeFill
        anchorPoint = .zero
        backgroundColor = NSColor(hex: 0x0A0E26)

        backgroundSprite.name = "background"
        backgroundSprite.anchorPoint = .zero
        backgroundSprite.zPosition = Z.background
        cab.name = "cab"
        cab.zPosition = Z.cab
        elevatorLabel.name = "elevatorLabel"
        elevatorLabel.zPosition = Z.elevatorLabel
        leds.name = "leds"
        leds.zPosition = Z.leds
        actors.name = "actors"
        actors.zPosition = Z.actors
        tethers.name = "tethers"
        tethers.zPosition = Z.tethers
        tooltip.name = "tooltip"
        tooltip.zPosition = Z.tooltip
        header.name = "header"
        header.zPosition = Z.header
        header.anchorPoint = CGPoint(x: 0, y: 1)   // top-left, where the label's top-left alignment put the text
        for n in [backgroundSprite, leds, cab, elevatorLabel, tethers, actors, header, tooltip] as [SKNode] { addChild(n) }
        transit.onArrive = { [weak self] in self?.arrived($0) }
        relayout()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Coordinates

    /// Layout (top-left origin) → scene (bottom-left origin).
    func scenePoint(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: size.height - p.y) }
    func layoutPoint(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: size.height - p.y) }

    // MARK: Layout

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        guard size.width >= 1, size.height >= 1, size != geo.size else { return }
        relayout()
        onLayout?(geo)
    }

    /// The backing scale of the hosting window changed (e.g. dragged to another display, or the view
    /// entered its first window after robots were made at the fallback scale): rebake the building and
    /// every robot. `scale` overrides the window's factor (the view passes it; tests have no window).
    func backingScaleChanged(_ scale: CGFloat? = nil) {
        if let scale { displayScale = scale }
        guard currentScale != bakedScale else { return }
        bake()
        rebuildLeds()
        rebakeRobots()
        // The new scale has its own atlas, whose versions start over.
        atlasVersion = -1
    }

    private var displayScale: CGFloat?
    private var currentScale: CGFloat { displayScale ?? view?.window?.backingScaleFactor ?? 2 }

    /// New size: rebake, drop robots that were leaving, snap everyone else to their slots in the new layout.
    private func relayout() {
        // Room inference for `.thinking` needs the old layout's rooms with the old coordinates.
        let list = entities(lastSessions)
        geo = BuildingLayout.make(size: size)
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

    private func bake() {
        let scale = currentScale
        bakedScale = scale
        if art.scale != artScale {
            art = RobotArt.shared(scale: artScale)   // the old scale's art goes once its robots are re-baked
            reportTextures.removeAll()
        }
        backgroundSprite.texture = BuildingArt.background(geo, scale: scale)
        backgroundSprite.size = size
        backgroundSprite.position = .zero
        let body = BuildingArt.cabBody(geo), m = BuildingArt.cabMargin
        cab.texture = BuildingArt.cab(geo, scale: scale)
        cab.size = CGSize(width: body.width + 2 * m, height: body.height + 2 * m)
        elevatorLabel.texture = BuildingArt.elevatorLabel(scale: scale)
        elevatorLabel.size = BuildingArt.elevatorLabelSize
        elevatorLabel.position = scenePoint(CGPoint(x: geo.elevator.midX, y: geo.elevator.midY))
        bakeHeader()
        scheduleRelief()
    }

    /// LEDs draw from the robot atlas (one batch instead of one draw per LED).
    private func rebuildLeds() {
        leds.removeAllChildren()
        ledSources.removeAll()
        let scale = bakedScale
        if ledImagesScale != scale { ledImages.removeAll(); ledImagesScale = scale }   // same images on resize
        let atlas = art.atlas
        for spec in BuildingArt.ledSpecs(geo) {
            let image = ledImages[spec.color] ?? BuildingArt.led(color: spec.color, scale: scale)
            ledImages[spec.color] = image
            let led = SKSpriteNode(texture: atlas.texture(for: image), size: CGSize(width: 4, height: 4))
            ledSources.append((led, image))
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

    override func update(_ currentTime: TimeInterval) {
        let dt = lastUpdate.map { currentTime - $0 } ?? 0
        lastUpdate = currentTime
        tick(dt)
    }

    /// Runs the scene for `seconds` in 1/60 s frames without a view (tests).
    func advance(by seconds: TimeInterval) {
        var left = seconds
        while left > 1e-9 {
            let dt = min(1.0 / 60, left)
            tick(dt)
            left -= dt
        }
    }

    /// One frame: move everyone, run the fade timers, then put the sprites where `Transit` says.
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
                d.sprite.fade = min(d.sprite.fade, CGFloat(1 - e / Self.fadeOutDuration))
                departing[key]?.leg = .fading(e)
            }
        }
        // Nothing walked, rode or was placed: the sprites are already where Transit says.
        if transit.revision != syncedRevision {
            syncSprites()
            placeCab()
        }
        bindAtlas()
        if let due = reliefDue {
            reliefDue = due - dt
            if due - dt <= 0 {
                ArtKit.releaseFreedPixels()
                reliefRuns += 1
                // Textures made while this one was pending may not have been uploaded (and freed) yet: once more.
                reliefDue = reliefRearm ? Self.reliefDelay : nil
                reliefRearm = false
            }
        }
    }

    /// Seconds until memory freed by uploaded textures goes back to the system (nil = nothing pending).
    private var reliefDue: TimeInterval?
    /// A texture was made after `reliefDue` was armed.
    private var reliefRearm = false
    /// How many reliefs ran. For tests.
    private(set) var reliefRuns = 0
    /// Textures made from raw pixels free them once SpriteKit has uploaded them (on a later render), but malloc
    /// keeps big freed blocks cached (and counted in the footprint) until asked to let go: do that `reliefDelay`
    /// after an upload. During a burst (a live resize rebakes the background every frame) it runs at most once
    /// per `reliefDelay`, and once more after the burst, so the last upload's pixels are returned too.
    /// (Cheap: well under 1 ms.)
    private func scheduleRelief() {
        if reliefDue == nil { reliefDue = Self.reliefDelay } else { reliefRearm = true }
    }
    static let reliefDelay: TimeInterval = 0.5

    /// Packs newly baked robot images into the shared atlas and moves every robot onto it, so their parts
    /// draw in a few batches. Runs once per frame; it only does work when new images appeared.
    private func bindAtlas() {
        let atlas = art.atlas
        if atlas.commit() { scheduleRelief() }   // re-rendered pages free their pixels after the upload
        guard atlas.version != atlasVersion else { return }
        atlasVersion = atlas.version
        for (_, r) in robots { r.rebindTextures() }
        for (_, d) in departing { d.sprite.rebindTextures() }
        for l in ledSources { l.node.texture = atlas.texture(for: l.image) }
    }

    // MARK: Header

    func setHeader(_ c: TowerCounts) {
        let s = NSMutableAttributedString()
        func add(_ t: String, _ color: NSColor, bold: Bool = false) {
            s.append(NSAttributedString(string: t, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: bold ? .heavy : .medium), .foregroundColor: color]))
        }
        add("AGENTRISE    ", .white, bold: true)
        add("在岗 \(c.working)    ", NSColor(hex: 0x9FB3FF))
        add("等你 \(c.waiting)    ", NSColor(hex: 0xFFC95C), bold: c.waiting > 0)
        add("完成 \(c.done)    ", NSColor(hex: 0x6FF0A8))
        add("待命 \(c.standby)    ", NSColor(hex: 0x9FB3FF))
        add("小弟 \(c.subs) · 外包 \(c.contractors)    ", NSColor(hex: 0x9FB3FF))
        add("睡觉 \(c.sleeping)", NSColor(hex: 0xB8B0FF))
        guard s != headerString else { return }
        headerString = s
        headerBakedScale = 0
        bakeHeader()
    }

    /// The header's plain text (for tests).
    var headerText: String { headerString?.string ?? "" }

    /// Renders the header copy into the header sprite's texture (when the copy or the scale changed).
    private func bakeHeader() {
        placeHeader()
        guard let s = headerString, headerBakedScale != bakedScale, bakedScale > 0 else { return }
        headerBakedScale = bakedScale
        let r = s.boundingRect(with: CGSize(width: 10_000, height: 100), options: [.usesLineFragmentOrigin])
        let size = CGSize(width: max(1, ceil(r.width)), height: max(1, ceil(r.height)))
        header.texture = ArtKit.texture(size: size, scale: bakedScale) { ctx in
            ArtKit.draw(s, in: CGRect(origin: .zero, size: size), ctx: ctx)
        }
        scheduleRelief()
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
        var bubble: (String, NSColor, Bool)?
        var larkBadge: Bool
        var waitingLong: Bool
    }

    /// The robot for an entity key, including one that is on its way out.
    func robot(_ key: String) -> RobotSprite? { robots[key] ?? departing[key]?.sprite }

    func noteSubResult(sessionId: String, subId: String, success: Bool) { pendingResults["a:\(sessionId):\(subId)"] = success }

    /// The first render of a scene places everyone without animation; later ones walk, ride and fade.
    func render(_ sessions: [Session], animated: Bool = true) {
        lastSessions = sessions
        place(animated: animated && hasRendered)
        hasRendered = true
    }

    /// The room whose (slightly enlarged) rect holds a point — where a robot "currently" is.
    private func room(at p: CGPoint?) -> Room? {
        guard let p else { return nil }
        return geo.rooms.first { $0.value.contains { $0.insetBy(dx: -4, dy: -20).contains(p) } }?.key
    }

    /// How long a finished robot stands at the CEO's door with its report before going for coffee.
    static let reportDuration: TimeInterval = 20 * 60
    /// After this long at the door, a waiting robot waves more urgently.
    static let waitingLongAfter: TimeInterval = 600
    /// Injectable for tests.
    var clock: () -> Date = Date.init
    /// The idle-loop phase a new robot starts at, by entity key (random, so robots don't bob in step).
    /// Injectable for tests: the motion baselines need fixed phases.
    var idlePhase: (_ key: String) -> TimeInterval = { _ in .random(in: 0...2.6) }
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
            var bubble: (String, NSColor, Bool)? = nil
            var act = s.activity
            switch s.status {
            case .waiting: room = .ceoOffice; face = .waiting; act = .waitingAtDoor
                bubble = ("等你回复", NSColor(hex: 0xFFC95C), true)
            case .done:
                // Report to the CEO first, then rest in the pantry.
                let reportEnds = s.statusSince.addingTimeInterval(Self.reportDuration)
                if now < reportEnds { room = .ceoOffice; act = .reporting; dueAt(reportEnds) } else { room = .pantry; act = .resting }
                face = .happy
                bubble = ("✓ 做完了", NSColor(hex: 0x1F8F57), false)
            case .error: room = .serverRoom; face = .error; act = .commandFailed
                bubble = ("出错了", NSColor(hex: 0xD84545), true)
            case .standby: room = .desks; face = .calm; act = .standby
            case .sleeping: room = .sleepPods; face = .asleep; act = .sleeping
            case .working:
                room = ActivityMap.room(for: s.activity) ?? current ?? .desks
                if s.transientErrorAt != nil { face = .error; act = .commandFailed }
                bubble = (s.activity.label, NSColor(hex: 0x24477A), false)
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
    private var artScale: CGFloat { bakedScale * 1.25 }
    /// The current scale's robot art (and atlas). Held here so it lives while no robot uses it (the LEDs do).
    private var art = RobotArt.shared(scale: 2.5)

    /// Swaps every robot (staying or leaving) for a copy baked at the current scale; positions, alpha,
    /// state and `Transit` are untouched, and a leaving sub gets its report card back.
    private func rebakeRobots() {
        func swap(_ old: RobotSprite) -> RobotSprite {
            let new = old.rebaked(with: art)
            if old.childNode(withName: "report") != nil { attachReport(to: new) }
            old.removeFromParent()
            actors.addChild(new)
            return new
        }
        for (key, old) in robots { robots[key] = swap(old) }
        for (key, d) in departing { departing[key] = Departure(sprite: swap(d.sprite), leg: d.leg) }
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
            let sprite: RobotSprite
            var isNew = false
            let look = RobotLook(kind: e.kind, teamIndex: s.teamIndex, larkSession: e.kind != .sub && e.kind != .contractor && s.isLark)
            if let r = robots[e.key] {
                sprite = r
            } else if let d = departing.removeValue(forKey: e.key) {
                // Back before it left: drop the report and fade back in from wherever the fade-out got to.
                sprite = d.sprite
                sprite.childNode(withName: "report")?.removeFromParent()
                if !animated { sprite.fade = 1 } else if sprite.fade < 1 { fadingIn[e.key] = Double(sprite.fade) * Self.fadeInDuration }
                robots[e.key] = sprite
                owner[e.key] = e.sessionId
            } else {
                sprite = RobotSprite(look: look, teamColor: Team.color(s.teamIndex), art: art, phase: idlePhase(e.key))
                robots[e.key] = sprite
                owner[e.key] = e.sessionId
                drawOrder[e.key] = nextDrawOrder
                nextDrawOrder += 1
                actors.addChild(sprite)
                isNew = true
            }
            // A rank changed in Settings: redraw the robot where it stands (no new entrance).
            if !isNew, sprite.look.kind != look.kind { sprite.setLook(look) }
            let sig = "\(e.name)|\(e.face)|\(e.activity)|\(e.waitingLong)|\(e.bubble?.0 ?? "")|\(e.larkBadge)|\(pt.x),\(pt.y)|\(scale)"
            if !isNew, signatures[e.key] == sig { continue }
            signatures[e.key] = sig
            sprite.setName(e.name)
            sprite.setFace(e.face)
            sprite.setAction(e.activity, waitingLong: e.activity == .waitingAtDoor && e.waitingLong)
            sprite.setBubble(e.bubble?.0, color: e.bubble?.1 ?? .clear, pulse: e.bubble?.2 ?? false)
            sprite.setLarkBadge(e.larkBadge)
            if sprite.robotScale != scale { sprite.setRobotScale(scale) }
            if isNew {
                if animated {
                    // Arrive by the elevator: appear at the target floor's door, fade in, walk to the slot.
                    transit.place(e.key, at: geo.elevatorDoor(floor: geo.floorOf(pt), side: geo.doorSide(for: pt)))
                    transit.send(e.key, to: pt)
                    sprite.fade = 0
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
        syncSprites()
        applyHighlight()
    }

    /// Subs and contractors walk back to their boss (a sub carrying its report, or smoking if it failed),
    /// then everyone leaves by their floor's elevator door and fades out.
    private func depart(_ key: String, wanted: Set<String>) {
        guard let sprite = robots.removeValue(forKey: key) else { return }
        signatures[key] = nil
        let sid = owner.removeValue(forKey: key) ?? ""
        let success = pendingResults.removeValue(forKey: key) ?? true
        if !success {
            sprite.setFace(.error)
            sprite.setAction(.commandFailed)
        } else if key.hasPrefix("a:") {
            sprite.setFace(.happy)
            attachReport(to: sprite)
        }
        let boss = "s:\(sid)"
        if key.hasPrefix("a:") || key.hasPrefix("c:"), wanted.contains(boss), let b = transit.target(of: boss) {
            departing[key] = Departure(sprite: sprite, leg: .toBoss)
            transit.send(key, to: CGPoint(x: b.x + 22, y: b.y))
        } else {
            departing[key] = Departure(sprite: sprite, leg: .toDoor)
            sendToDoor(key)
        }
    }

    /// Removes a robot at once, with no walk or fade (a non-animated render).
    private func discard(_ key: String) {
        guard let sprite = robots.removeValue(forKey: key) else { return }
        signatures[key] = nil
        owner[key] = nil
        pendingResults[key] = nil
        fadingIn[key] = nil
        drawOrder[key] = nil
        sprite.removeAllActions()
        sprite.removeFromParent()
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
        d.sprite.removeAllActions()
        d.sprite.removeFromParent()
        transit.remove(key)
    }

    /// Sprites follow `Transit`. Draw order: robots are ranked by layout y (lower on screen in front), ties —
    /// riders sharing the cab, robots waiting at the same door — broken by a stable per-key creation order,
    /// and each rank gets its own `robotZStep` band. A robot's parts span < 0.015 above its own z, so no
    /// two robots' parts can interleave, whatever their positions.
    private func syncSprites() {
        var placed: [(y: CGFloat, order: Int, sprite: RobotSprite)] = []
        placed.reserveCapacity(robots.count + departing.count)
        func sync(_ key: String, _ sprite: RobotSprite) {
            guard let p = transit.position(of: key) else { return }
            let sp = scenePoint(p)
            if sprite.position != sp { sprite.position = sp }
            placed.append((p.y, drawOrder[key] ?? 0, sprite))
        }
        for (key, sprite) in robots { sync(key, sprite) }
        for (key, d) in departing { sync(key, d.sprite) }
        placed.sort { ($0.y, $0.order) < ($1.y, $1.order) }
        for (i, r) in placed.enumerated() {
            let z = CGFloat(i) * Self.robotZStep
            if r.sprite.zPosition != z { r.sprite.zPosition = z }
        }
        syncedRevision = transit.revision
    }

    /// z distance between consecutive robots: more than a robot's own part span (0.015).
    static let robotZStep: CGFloat = 0.02

    // MARK: Report

    /// The old report card a finished sub carries back: 10×13, 0xBFE8FF, corner 2, glow 0x7CC4FF radius 5,
    /// centred at design point (52, 58) and drawn above the whole robot.
    private func attachReport(to sprite: RobotSprite) {
        guard sprite.childNode(withName: "report") == nil else { return }
        let n = SKSpriteNode(texture: reportTexture(), size: Self.reportImageSize)
        n.name = "report"
        n.position = RobotMotion.robotPoint(CGPoint(x: 52, y: 58))
        n.zPosition = 0.0145
        sprite.addChild(n)
    }

    private static let reportPadding: CGFloat = 8
    private static var reportImageSize: CGSize { CGSize(width: 10 + 2 * reportPadding, height: 13 + 2 * reportPadding) }

    private func reportTexture() -> SKTexture {
        let scale = artScale
        if let t = reportTextures[scale] { return t }
        let pad = Self.reportPadding
        let t = ArtKit.texture(size: Self.reportImageSize, scale: scale) { ctx in
            ctx.setShadow(offset: .zero, blur: ArtKit.shadowBlur(radius: 5, scale: scale), color: NSColor(hex: 0x7CC4FF).cgColor)
            ctx.addPath(CGPath(roundedRect: CGRect(x: pad, y: pad, width: 10, height: 13), cornerWidth: 2, cornerHeight: 2, transform: nil))
            ctx.setFillColor(NSColor(hex: 0xBFE8FF).cgColor)
            ctx.fillPath()
        }
        reportTextures[scale] = t
        return t
    }

    // MARK: Hit testing, hover, click

    var onClickSession: ((String) -> Void)?
    var onHoverSession: ((String?) -> Void)?

    /// The session highlighted by the pointer or by the panel (the old `hovered`).
    private var hovered: String?
    private(set) var tooltipLines: [String] = []
    private var tooltipSignature = ""

    /// The session whose robot is under a layout point: the 60×84 box of every robot standing in the
    /// scene (not the ones leaving); with several hits, the one whose middle is closest to the point.
    func sessionId(at layoutPoint: CGPoint) -> String? {
        let p = scenePoint(layoutPoint)
        var best: (key: String, d: CGFloat)?
        for (key, sprite) in robots where sprite.hitRect.contains(p) {
            let d = hypot(sprite.position.x - p.x, sprite.position.y + 42 * sprite.robotScale - p.y)
            if best == nil || d < best!.d || (d == best!.d && key < best!.key) { best = (key, d) }
        }
        return best.flatMap { owner[$0.key] }
    }

    /// The pointer moved to a layout point (nil = it left the view): highlight, tooltip and panel follow.
    func hover(at layoutPoint: CGPoint?) {
        let sid = layoutPoint.flatMap { sessionId(at: $0) }
        if sid != hovered {
            highlight(sid)
            onHoverSession?(sid)
        }
        showTooltip(sid, at: layoutPoint ?? .zero)
    }

    func click(at layoutPoint: CGPoint) {
        if let sid = sessionId(at: layoutPoint) { onClickSession?(sid) }
    }

    // MARK: Highlight and tethers

    /// Dims everyone not on the session's team and ties its subs and contractors to the boss with flowing
    /// dashed lines. Robots on their way out keep fading and are left alone.
    func highlight(_ sessionId: String?) {
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
        for (key, sprite) in robots { sprite.setDimmed(hovered != nil && owner[key] != hovered) }
        guard let sid = hovered, let s = lastSessions.first(where: { $0.id == sid }), robots["s:\(sid)"] != nil else {
            tethers.removeAllChildren()
            return
        }
        let bossKey = "s:\(sid)"
        let keys = robots.keys.sorted().filter { owner[$0] == sid && $0 != bossKey }
        // Unchanged set: keep the nodes, so a re-render doesn't restart the flow.
        if tethers.children.compactMap(\.name) == keys.map({ Self.tetherPrefix + $0 }) { return }
        tethers.removeAllChildren()
        for key in keys {
            let n = SKShapeNode()
            n.name = Self.tetherPrefix + key
            n.strokeColor = Team.color(s.teamIndex)
            n.lineWidth = 2
            n.glowWidth = 2
            n.path = tetherPath(from: bossKey, to: key, phase: 0)
            // The old lineDashPhase animation 0 → -24 over 1.2 s, repeating. The path is rebuilt on every
            // frame, so the line also follows robots that are walking or riding.
            n.run(.repeatForever(.customAction(withDuration: Self.tetherPeriod) { [weak self] node, t in
                guard let self, let shape = node as? SKShapeNode, let key = shape.name?.dropFirst(Self.tetherPrefix.count) else { return }
                shape.path = self.tetherPath(from: bossKey, to: String(key), phase: -24 * (t / CGFloat(Self.tetherPeriod))) ?? shape.path
            }))
            tethers.addChild(n)
        }
    }

    private static let tetherPrefix = "tether:"
    private static let tetherPeriod: TimeInterval = 1.2
    private static let dash: [CGFloat] = [6, 6]

    /// The tether's quad curve from the boss's head to a robot's chest, in scene coordinates (nil while either
    /// is gone). `tetherPath` dashes it; the motion baselines record it.
    func tetherCurve(from bossKey: String, to key: String) -> (from: CGPoint, control: CGPoint, to: CGPoint)? {
        guard let bp = transit.position(of: bossKey), let bs = robot(bossKey)?.robotScale,
              let rp = transit.position(of: key), let rs = robot(key)?.robotScale else { return nil }
        let b = CGPoint(x: bp.x, y: bp.y - 40 * bs), p = CGPoint(x: rp.x, y: rp.y - 30 * rs)
        return (scenePoint(b), scenePoint(CGPoint(x: (b.x + p.x) / 2, y: min(b.y, p.y) - 40)), scenePoint(p))
    }

    /// The old curve from the boss's head to a robot's chest (layout coordinates, then flipped), dashed.
    private func tetherPath(from bossKey: String, to key: String, phase: CGFloat) -> CGPath? {
        guard let c = tetherCurve(from: bossKey, to: key) else { return nil }
        let path = CGMutablePath()
        path.move(to: c.from)
        path.addQuadCurve(to: c.to, control: c.control)
        // Dash phases are periodic; keep ours positive.
        let period = Self.dash.reduce(0, +)
        var ph = phase.truncatingRemainder(dividingBy: period)
        if ph < 0 { ph += period }
        return path.copy(dashingWithPhase: ph, lengths: Self.dash)
    }

    // MARK: Tooltip

    /// The old detail box's text, one string per line.
    static func tooltipLines(for s: Session, now: Date = Date()) -> [String] {
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
    /// fade-out left boxes stuck on screen).
    func showTooltip(_ sid: String?, at p: CGPoint) {
        guard let sid, let s = lastSessions.first(where: { $0.id == sid }) else {
            tooltip.removeAllChildren()
            tooltipLines = []
            tooltipSignature = ""
            return
        }
        let lines = Self.tooltipLines(for: s)
        let scale = currentScale
        let signature = "\(lines.joined(separator: "\n"))|\(s.teamIndex)|\(scale)"
        let box: SKSpriteNode
        if signature == tooltipSignature, let existing = tooltip.children.first as? SKSpriteNode {
            box = existing
        } else {
            tooltip.removeAllChildren()
            let (texture, size) = Self.tooltipTexture(lines, color: Team.color(s.teamIndex), scale: scale)
            box = SKSpriteNode(texture: texture, size: size)
            scheduleRelief()
            box.anchorPoint = CGPoint(x: 0, y: 1)   // top-left, like the old layer in the flipped view
            tooltip.addChild(box)
            tooltipLines = lines
            tooltipSignature = signature
        }
        var o = CGPoint(x: p.x + 14, y: p.y + 14)
        if o.x + box.size.width > size.width { o.x = p.x - box.size.width - 10 }
        if o.y + box.size.height > size.height { o.y = p.y - box.size.height - 10 }
        box.position = scenePoint(o)
    }

    /// 0x0A0E26 at 0.95, a 1 pt team-colour border inside a corner radius of 8; the first line 12 pt bold
    /// white, the rest 10.5 pt regular 0xC9D2FF, 2 pt apart; at most 320 pt wide.
    private static func tooltipTexture(_ lines: [String], color: NSColor, scale: CGFloat) -> (SKTexture, CGSize) {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        struct Row { var text: NSAttributedString; var rect: CGRect }
        var rows: [Row] = []
        var y: CGFloat = 8, w: CGFloat = 0
        for (i, line) in lines.enumerated() {
            let size: CGFloat = i == 0 ? 12 : 10.5
            let weight: NSFont.Weight = i == 0 ? .bold : .regular
            let box = ArtKit.labelSize(line, size: size, weight: weight)
            let text = NSAttributedString(string: line, attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: weight),
                .foregroundColor: i == 0 ? NSColor.white : NSColor(hex: 0xC9D2FF), .paragraphStyle: para])
            rows.append(Row(text: text, rect: CGRect(x: 10, y: y, width: box.width, height: box.height)))
            y += box.height + 2
            w = max(w, box.width)
        }
        let size = CGSize(width: min(w + 20, 320), height: y + 6)
        let texture = ArtKit.texture(size: size, scale: scale) { ctx in
            let outer = CGRect(origin: .zero, size: size)
            ctx.addPath(CGPath(roundedRect: outer, cornerWidth: 8, cornerHeight: 8, transform: nil))
            ctx.setFillColor(NSColor(hex: 0x0A0E26, alpha: 0.95).cgColor)
            ctx.fillPath()
            ctx.addPath(CGPath(roundedRect: outer.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 7.5, cornerHeight: 7.5, transform: nil))
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(1)
            ctx.strokePath()
            for r in rows {
                var rect = r.rect
                rect.size.width = min(rect.width, size.width - 20)   // truncate rather than spill over the border
                ArtKit.draw(r.text, in: rect, ctx: ctx)
            }
        }
        return (texture, size)
    }
}
