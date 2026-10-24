import Testing
@testable import Agentrise

@Suite struct ElevatorDispatcherTests {
    /// 通过公开 API 让 rider 在 `from` 上车（call + arrive），返回上车后的 dispatcher。
    private func boarded(_ d: inout ElevatorDispatcher, rider: String, from: Int, to: Int) {
        d.call(rider: rider, from: from, to: to)
        _ = d.arrive(at: from)
    }

    @Test func singleRideGoesToPickupThenDropoff() {
        var d = ElevatorDispatcher()
        d.call(rider: "r1", from: 0, to: 3)
        #expect(d.nextStopFloor(cabFloor: 2) == 0)
        #expect(d.arrive(at: 0).board == ["r1"])
        #expect(d.nextStopFloor(cabFloor: 0) == 3)
        #expect(d.arrive(at: 3).alight == ["r1"])
        #expect(d.nextStopFloor(cabFloor: 3) == nil)
        #expect(d.direction == .idle)
    }

    @Test func picksUpSameDirectionOnTheWay() {
        var d = ElevatorDispatcher()
        boarded(&d, rider: "r1", from: 0, to: 3)
        d.call(rider: "r2", from: 1, to: 2)

        #expect(d.nextStopFloor(cabFloor: 0) == 1)
        let s1 = d.arrive(at: 1)
        #expect(s1.board == ["r2"] && s1.alight.isEmpty)

        #expect(d.nextStopFloor(cabFloor: 1) == 2)
        let s2 = d.arrive(at: 2)
        #expect(s2.alight == ["r2"])

        #expect(d.nextStopFloor(cabFloor: 2) == 3)
        #expect(d.arrive(at: 3).alight == ["r1"])
        #expect(d.nextStopFloor(cabFloor: 3) == nil)
    }

    @Test func skipsOppositeDirectionOnTheWay() {
        var d = ElevatorDispatcher()
        boarded(&d, rider: "r1", from: 0, to: 3)
        d.call(rider: "r2", from: 1, to: 0)

        #expect(d.nextStopFloor(cabFloor: 0) == 3)
        #expect(d.arrive(at: 3).alight == ["r1"])

        #expect(d.nextStopFloor(cabFloor: 3) == 1)
        #expect(d.arrive(at: 1).board == ["r2"])

        #expect(d.nextStopFloor(cabFloor: 1) == 0)
        #expect(d.arrive(at: 0).alight == ["r2"])
        #expect(d.nextStopFloor(cabFloor: 0) == nil)
    }

    @Test func respectsCapacity() {
        var d = ElevatorDispatcher(capacity: 2)
        d.call(rider: "r1", from: 0, to: 2)
        d.call(rider: "r2", from: 0, to: 2)
        d.call(rider: "r3", from: 0, to: 2)

        #expect(d.arrive(at: 0).board == ["r1", "r2"])
        #expect(d.waiting.map(\.rider) == ["r3"])
        // 满员时不应再为 r3 停靠本层
        #expect(d.nextStopFloor(cabFloor: 0) == 2)

        let drop = d.arrive(at: 2)
        #expect(Set(drop.alight) == ["r1", "r2"])
        #expect(d.nextStopFloor(cabFloor: 2) == 0)
        #expect(d.arrive(at: 0).board == ["r3"])
        #expect(d.nextStopFloor(cabFloor: 0) == 2)
    }

    @Test func retargetWhileRidingChangesDropoff() {
        var d = ElevatorDispatcher()
        boarded(&d, rider: "r1", from: 0, to: 3)
        d.retarget(rider: "r1", to: 1)
        #expect(d.nextStopFloor(cabFloor: 0) == 1)
        #expect(d.arrive(at: 1).alight == ["r1"])
        #expect(d.nextStopFloor(cabFloor: 1) == nil)
    }

    @Test func retargetWhileWaitingKeepsQueuePosition() {
        var d = ElevatorDispatcher()
        d.call(rider: "r1", from: 0, to: 1)
        d.call(rider: "r2", from: 0, to: 1)
        d.retarget(rider: "r1", to: 2)
        #expect(d.waiting.first?.rider == "r1")
        #expect(d.waiting.first?.to == 2)
    }

    @Test func sameFloorCallIsIgnored() {
        var d = ElevatorDispatcher()
        d.call(rider: "r1", from: 2, to: 2)
        #expect(d.waiting.isEmpty && d.riding.isEmpty)
        #expect(d.nextStopFloor(cabFloor: 0) == nil)
    }

    @Test func removeDropsRiderEverywhere() {
        var d = ElevatorDispatcher()
        boarded(&d, rider: "r1", from: 0, to: 3)
        d.call(rider: "r2", from: 1, to: 2)
        d.remove(rider: "r1")
        d.remove(rider: "r2")
        #expect(d.waiting.isEmpty && d.riding.isEmpty)
        #expect(d.nextStopFloor(cabFloor: 0) == nil)
    }

    @Test func duplicateCallRetargetsInsteadOfDuplicating() {
        var d = ElevatorDispatcher()
        d.call(rider: "r1", from: 0, to: 3)
        d.call(rider: "r1", from: 0, to: 2)
        #expect(d.waiting.count == 1 && d.waiting[0].to == 2)
    }

    @Test func clearResetsEverything() {
        var d = ElevatorDispatcher()
        boarded(&d, rider: "r1", from: 0, to: 3)
        d.call(rider: "r2", from: 1, to: 2)
        d.clear()
        #expect(d.waiting.isEmpty)
        #expect(d.riding.isEmpty)
        #expect(d.direction == .idle)
    }

    @Test func nextStopFloorIsPure() {
        var d = ElevatorDispatcher()
        d.call(rider: "r1", from: 1, to: 3)
        let before = d
        _ = d.nextStopFloor(cabFloor: 0)
        #expect(d.waiting == before.waiting)
        #expect(d.riding == before.riding)
        #expect(d.direction == before.direction)
    }
}
