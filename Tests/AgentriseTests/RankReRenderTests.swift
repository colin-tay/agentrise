import Testing
import AppKit
import SpriteKit
@testable import Agentrise

@MainActor
@Suite struct RankReRenderTests {
    private func session(_ rank: Rank) -> Session {
        Session(id: "a", title: "任务 a", source: .desktop(hostSessionId: nil), rank: rank, status: .working,
                activity: .coding, teamIndex: 0, statusSince: Date(), lastActivityAt: Date())
    }

    private func part(_ r: RobotSprite, _ name: String) -> SKSpriteNode? { r.childNode(withName: "//\(name)") as? SKSpriteNode }

    @Test func rankChangeRedrawsTheSameRobotInPlace() {
        let scene = TowerScene(size: CGSize(width: 1200, height: 800))
        scene.render([session(.seniorEngineer)], animated: false)
        let before = scene.robot("s:a")
        #expect(before?.look.rank == .seniorEngineer)
        let pos = before?.position, headBefore = part(before!, "head")?.texture, torsoBefore = part(before!, "torso")?.texture
        #expect(part(before!, "headOverlay")?.isHidden == true)
        let targetBefore = scene.transit.target(of: "s:a")

        scene.render([session(.seniorExpert)], animated: false)
        let after = scene.robot("s:a")
        #expect(after === before)
        #expect(after?.look.rank == .seniorExpert)
        #expect(after?.position == pos)
        #expect(scene.transit.target(of: "s:a") == targetBefore)
        #expect(part(after!, "head")?.texture !== headBefore)
        #expect(part(after!, "torso")?.texture !== torsoBefore)
        #expect(part(after!, "headOverlay")?.isHidden == false)
        #expect(part(after!, "headOverlay")?.texture != nil)
        #expect(after?.alpha == 1)

        // And back: the monocle goes away again.
        scene.render([session(.seniorEngineer)], animated: false)
        #expect(scene.robot("s:a") === before)
        #expect(part(before!, "headOverlay")?.isHidden == true)
    }

    @Test func sameRankKeepsTheArtUntouched() {
        let scene = TowerScene(size: CGSize(width: 1200, height: 800))
        scene.render([session(.seniorExpert)], animated: false)
        let r = scene.robot("s:a")!
        let head = part(r, "head")?.texture
        scene.render([session(.seniorExpert)], animated: false)
        #expect(scene.robot("s:a") === r)
        #expect(part(r, "head")?.texture === head)
    }
}
