// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation
import CoreGraphics

enum TransitPhase: Equatable { case idle, walking, waiting, riding }

/// 行人移动系统：同层步行、跨层走到电梯门口等候、乘坐轿厢、出门走向目标。
/// 纯逻辑（只依赖 CoreGraphics），由场景每帧调用 `step(dt)` 推进；坐标为布局坐标（左上原点）。
final class Transit {
    private struct Walker {
        var position: CGPoint
        var phase: TransitPhase
        /// 剩余路点（不含当前位置）及每段对应速度（pt/s）。
        var path: [CGPoint] = []
        var speeds: [CGFloat] = []
        var target: CGPoint
        /// 已被 dispatcher 接上车、正从门口走进轿厢（phase 仍为 `.waiting`）。
        var boarding = false
    }

    static let maxStep: TimeInterval = 0.1
    static let capacity = 4
    static let doorDwell: TimeInterval = 0.6
    static let cabSpeedPerUnit: CGFloat = 260

    private(set) var layout: BuildingLayout
    private(set) var cabPosition: CGPoint
    /// 开门计时未完，或还有乘客正在走进轿厢。
    var cabDoorsOpen: Bool { doorTimer > 0 || anyoneBoarding }
    var onArrive: ((String) -> Void)?
    private(set) var tripCount = 0
    /// Bumped whenever a reported position (a walker's or the cab's) may have changed, so the scene can
    /// skip frames in which nothing moved.
    private(set) var revision = 0

    private var walkers: [String: Walker] = [:]
    /// 插入顺序，保证每帧处理顺序（从而呼叫顺序）确定。
    private var order: [String] = []
    private var dispatcher = ElevatorDispatcher(capacity: Transit.capacity)
    /// 轿厢最近一次停靠的楼层。
    private var cabFloor = 3
    /// 轿厢正驶向的楼层；一旦确定，到站前不再改变（避免井道中途来回摆动）。
    private var cabTarget: Int?
    private var doorTimer: TimeInterval = 0
    /// Walkers with `boarding` set (kept in step with it, so the per-frame check is O(1)).
    private var boarders: Set<String> = []

    init(layout: BuildingLayout) {
        self.layout = layout
        self.cabPosition = layout.elevatorStop(floor: 3)
    }

    // MARK: - 查询

    func position(of id: String) -> CGPoint? {
        guard let w = walkers[id] else { return nil }
        return w.phase == .riding ? cabPosition : w.position
    }

    func phase(of id: String) -> TransitPhase? { walkers[id]?.phase }

    /// The floor the cab is at, or is travelling to (the next stop).
    var cabHeading: Int { cabTarget ?? cabFloor }

    func target(of id: String) -> CGPoint? { walkers[id]?.target }

    // MARK: - 指令

    /// 无动画放置/吸附；会取消该行人的电梯请求，不触发 `onArrive`。
    func place(_ id: String, at p: CGPoint) {
        dispatcher.remove(rider: id)
        if walkers[id] == nil { order.append(id) }
        walkers[id] = Walker(position: p, phase: .idle, target: p)
        boarders.remove(id)
        revision += 1
    }

    /// 从当前位置出发去 `target`：同层直走，跨层走电梯。未知 id 视为在目标处放置。
    func send(_ id: String, to target: CGPoint) {
        guard var w = walkers[id] else { place(id, at: target); return }
        w.target = target
        let targetFloor = layout.floorOf(target)
        switch w.phase {
        case .idle, .walking:
            route(&w, from: w.position)
        case .waiting:
            if targetFloor == layout.floorOf(w.position) {
                dispatcher.remove(rider: id)
                w.boarding = false
                boarders.remove(id)
                route(&w, from: w.position)
            } else {
                dispatcher.retarget(rider: id, to: targetFloor)
            }
        case .riding:
            dispatcher.retarget(rider: id, to: targetFloor)
        }
        walkers[id] = w
        revision += 1
    }

    func remove(_ id: String) {
        dispatcher.remove(rider: id)
        walkers[id] = nil
        boarders.remove(id)
        order.removeAll { $0 == id }
        revision += 1
    }

    /// 换布局：清空电梯，所有人吸附到新目标（不在 `targets` 里的吸附到原目标）。
    func relayout(_ layout: BuildingLayout, targets: [String: CGPoint]) {
        self.layout = layout
        dispatcher.clear()
        cabTarget = nil
        doorTimer = 0
        cabPosition = layout.elevatorStop(floor: cabFloor)
        boarders.removeAll()
        revision += 1
        for id in order {
            guard let w = walkers[id] else { continue }
            let p = targets[id] ?? w.target
            walkers[id] = Walker(position: p, phase: .idle, target: p)
        }
    }

    // MARK: - 推进

    /// 推进 dt 秒。按裁定：超过 0.1 秒的部分直接丢弃（不切片补算）。
    func step(_ dt: TimeInterval) {
        let dt = min(Transit.maxStep, max(0, dt))
        guard dt > 0 else { return }
        var arrived: [(id: String, target: CGPoint)] = []
        for id in order {
            guard var w = walkers[id] else { continue }
            if w.boarding {
                revision += 1
                if walk(&w, dt: dt) {
                    w.boarding = false
                    boarders.remove(id)
                    w.phase = .riding
                }
                walkers[id] = w
                continue
            }
            guard w.phase == .walking else { continue }
            revision += 1
            if walk(&w, dt: dt) {
                let floor = layout.floorOf(w.position)
                let targetFloor = layout.floorOf(w.target)
                if floor == targetFloor {
                    w.phase = .idle
                    w.position = w.target
                    arrived.append((id, w.target))
                } else {
                    w.phase = .waiting
                    dispatcher.call(rider: id, from: floor, to: targetFloor)
                }
            }
            walkers[id] = w
        }
        stepCab(dt)
        // 前一个回调可能已 remove / 重新 send 了后面的人：只对仍停在该目标的人回调。
        for a in arrived {
            guard let w = walkers[a.id], w.phase == .idle, w.target == a.target else { continue }
            onArrive?(a.id)
        }
    }

    // MARK: - 私有

    private var anyoneBoarding: Bool { !boarders.isEmpty }

    /// 给行人规划从 `from` 出发的路径：同层直达目标，跨层先去本层电梯门口。
    private func route(_ w: inout Walker, from: CGPoint) {
        let floor = layout.floorOf(from)
        let end = floor == layout.floorOf(w.target)
            ? w.target
            : layout.elevatorDoor(floor: floor, side: layout.doorSide(for: from))
        w.position = from
        w.phase = .walking
        w.path = [end]
        w.speeds = [Transit.walkSpeed(from, end)]
    }

    /// 单段步行速度：距离 / min(1.5, 0.35 + 距离/700)。
    private static func walkSpeed(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let d = hypot(b.x - a.x, b.y - a.y)
        guard d > 0 else { return 1 }
        return d / min(1.5, 0.35 + d / 700)
    }

    /// 沿路径前进 dt；走完返回 true。
    private func walk(_ w: inout Walker, dt: TimeInterval) -> Bool {
        var t = CGFloat(dt)
        while t > 0, let next = w.path.first {
            let speed = w.speeds.first ?? 1
            let dx = next.x - w.position.x, dy = next.y - w.position.y
            let d = hypot(dx, dy)
            let need = d / speed
            if need <= t {
                w.position = next
                t -= need
                w.path.removeFirst()
                w.speeds.removeFirst()
            } else {
                let k = speed * t / d
                w.position = CGPoint(x: w.position.x + dx * k, y: w.position.y + dy * k)
                t = 0
            }
        }
        return w.path.isEmpty
    }

    /// 轿厢状态机：门开计时 → 关门后选下一站（到站前锁定）→ 匀速移动 → 到站开门、上下客。
    private func stepCab(_ dt: TimeInterval) {
        if doorTimer > 0 {
            doorTimer = max(0, doorTimer - dt)
            return
        }
        // 实际停靠时间 = max(0.6 s, 最后一位乘客走进轿厢的时间)。
        if anyoneBoarding { return }
        if cabTarget == nil {
            cabTarget = dispatcher.nextStopFloor(cabFloor: cabFloor)
        }
        guard let floor = cabTarget else { return }
        let stop = layout.elevatorStop(floor: floor)
        let dy = stop.y - cabPosition.y
        let travel = Transit.cabSpeedPerUnit * layout.unit * CGFloat(dt)
        revision += 1
        if abs(dy) > travel {
            cabPosition = CGPoint(x: stop.x, y: cabPosition.y + (dy > 0 ? travel : -travel))
            return
        }
        cabPosition = stop
        cabFloor = floor
        cabTarget = nil
        let result = dispatcher.arrive(at: floor)
        tripCount += 1
        doorTimer = Transit.doorDwell
        // 下车：从轿厢走到本层门口，再走向目标。
        for id in result.alight {
            guard var w = walkers[id] else { continue }
            let door = layout.elevatorDoor(floor: floor, side: layout.doorSide(for: w.target))
            w.position = stop
            w.phase = .walking
            w.path = [door, w.target]
            w.speeds = [Transit.walkSpeed(stop, door), Transit.walkSpeed(door, w.target)]
            walkers[id] = w
        }
        // 上车：从门口走进轿厢，走到后才变为 `.riding`。
        for id in result.board {
            guard var w = walkers[id] else { continue }
            w.boarding = true
            boarders.insert(id)
            w.path = [stop]
            w.speeds = [Transit.walkSpeed(w.position, stop)]
            walkers[id] = w
        }
    }
}
