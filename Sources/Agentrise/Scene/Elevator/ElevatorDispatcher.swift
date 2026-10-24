import Foundation

enum TravelDirection { case up, down, idle }

struct ElevatorRequest: Equatable {
    let rider: String
    var from: Int
    var to: Int

    /// 该请求想去的方向（from == to 的请求不会存在）。
    var direction: TravelDirection { to > from ? .up : .down }
}

struct ElevatorStop: Equatable {
    let floor: Int
    let alight: [String]
    let board: [String]
}

/// 电梯集体控制（collective control）调度器：纯逻辑，不含任何 UI / 时间。
/// 楼层为整数（0 = B1 … 3 = 3F）。
struct ElevatorDispatcher {
    let capacity: Int
    /// 按呼叫先后排列的等候者。
    private(set) var waiting: [ElevatorRequest] = []
    private(set) var riding: [ElevatorRequest] = []
    private(set) var direction: TravelDirection = .idle

    init(capacity: Int = 4) {
        self.capacity = capacity
    }

    // MARK: - 请求管理

    /// from == to 时忽略；同一 rider 重复呼叫视为 retarget（等候中保留队列位置）。
    mutating func call(rider: String, from: Int, to: Int) {
        guard from != to else { return }
        if let i = riding.firstIndex(where: { $0.rider == rider }) {
            riding[i].to = to
        } else if let i = waiting.firstIndex(where: { $0.rider == rider }) {
            waiting[i].from = from
            waiting[i].to = to
        } else {
            waiting.append(ElevatorRequest(rider: rider, from: from, to: to))
        }
    }

    /// 等待中改 to（保留队列位置）；乘坐中改 to。等待中改成与 from 相同则视为取消。
    mutating func retarget(rider: String, to: Int) {
        if let i = riding.firstIndex(where: { $0.rider == rider }) {
            riding[i].to = to
        } else if let i = waiting.firstIndex(where: { $0.rider == rider }) {
            if waiting[i].from == to {
                waiting.remove(at: i)
            } else {
                waiting[i].to = to
            }
        }
    }

    mutating func remove(rider: String) {
        waiting.removeAll { $0.rider == rider }
        riding.removeAll { $0.rider == rider }
    }

    mutating func clear() {
        waiting.removeAll()
        riding.removeAll()
        direction = .idle
    }

    // MARK: - 调度

    /// 轿厢下一个应停靠的楼层；没有任务返回 nil。纯查询。
    func nextStopFloor(cabFloor: Int) -> Int? {
        if riding.isEmpty {
            return waiting.first?.from
        }
        let primary: TravelDirection = direction == .down ? .down : .up
        let secondary: TravelDirection = primary == .up ? .down : .up
        return scan(from: cabFloor, heading: primary) ?? scan(from: cabFloor, heading: secondary)
    }

    /// 到达 `floor`：先下后上，并更新 direction。
    mutating func arrive(at floor: Int) -> ElevatorStop {
        // 1. 下车
        let alighted = riding.filter { $0.to == floor }
        riding.removeAll { $0.to == floor }

        // 2. 决定新方向
        if !riding.isEmpty {
            let current: TravelDirection = direction == .down ? .down : .up
            let hasAhead = riding.contains { isAhead($0.to, of: floor, heading: current) }
            direction = hasAhead ? current : (current == .up ? .down : .up)
        } else if let first = waiting.first(where: { $0.from == floor }) {
            direction = first.direction
        } else if let first = waiting.first {
            direction = first.from > floor ? .up : .down
        } else {
            direction = .idle
        }

        // 3. 上车：本层同方向的等候者，按先后，直到满员
        var boarded: [String] = []
        if direction != .idle {
            var i = 0
            while i < waiting.count, riding.count < capacity {
                if waiting[i].from == floor, waiting[i].direction == direction {
                    boarded.append(waiting[i].rider)
                    riding.append(waiting.remove(at: i))
                } else {
                    i += 1
                }
            }
        }

        return ElevatorStop(floor: floor, alight: alighted.map(\.rider), board: boarded)
    }

    // MARK: - 私有

    private func isAhead(_ f: Int, of cab: Int, heading: TravelDirection) -> Bool {
        heading == .up ? f > cab : f < cab
    }

    /// 从 cabFloor（含）沿 heading 方向找最近的停靠楼层：
    /// 有人下车，或有同方向等候者且（下车后）有空位。
    private func scan(from cabFloor: Int, heading: TravelDirection) -> Int? {
        let all = (waiting + riding).flatMap { [$0.from, $0.to] } + [cabFloor]
        let floors = all.min()!...all.max()!
        let step = heading == .up ? 1 : -1
        var f = cabFloor
        while floors.contains(f) {
            let alightCount = riding.filter { $0.to == f }.count
            if alightCount > 0 { return f }
            let hasRoom = riding.count - alightCount < capacity
            if hasRoom, waiting.contains(where: { $0.from == f && $0.direction == heading }) {
                return f
            }
            f += step
        }
        return nil
    }
}
