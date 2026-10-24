import Testing
import CoreGraphics
@testable import Agentrise

@Suite struct LayoutTests {
    @Test func portraitLayoutHasFourFloorsAndCenteredElevator() {
        let layout = BuildingLayout.make(size: CGSize(width: 1080, height: 1900))
        #expect(layout.floors.keys.sorted() == [0, 1, 2, 3])
        #expect(abs(layout.elevator.midX - layout.building.midX) < 0.5)
        #expect(layout.orientation == .portrait)
    }

    @Test func elevatorDoorSitsOutsideShaftOnTheFloor() {
        let layout = BuildingLayout.make(size: CGSize(width: 1080, height: 1900))
        let left = layout.elevatorDoor(floor: 2, side: .left)
        let right = layout.elevatorDoor(floor: 2, side: .right)
        #expect(left.x == layout.elevator.minX - 14)
        #expect(right.x == layout.elevator.maxX + 14)
        #expect(left.y == layout.floors[2]!.maxY - 18)
        #expect(right.y == layout.floors[2]!.maxY - 18)
    }

    @Test func floorOfUsesFloorBandsNotNearestMidline() {
        let layout = BuildingLayout.make(size: CGSize(width: 1080, height: 1900))
        for (room, floor) in [(Room.meeting, 3), (.desks, 2), (.intel, 2), (.pantry, 1), (.serverRoom, 1), (.sleepPods, 0)] {
            let r = layout.rooms[room]![0]
            #expect(layout.floorOf(CGPoint(x: r.midX, y: r.maxY - 4)) == floor, "\(room)")
        }
        for f in 0...3 { #expect(layout.floorOf(layout.elevatorDoor(floor: f, side: .left)) == f) }
    }
}
