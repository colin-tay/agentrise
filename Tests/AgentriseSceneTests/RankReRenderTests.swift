// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Testing
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import Agentrise
@testable import AgentriseScene

@Suite struct RankReRenderTests {
    private func session(_ rank: Rank) -> Session {
        Session(id: "a", title: "任务 a", source: .desktop(hostSessionId: nil), rank: rank, status: .working,
                activity: .coding, teamIndex: 0, statusSince: Date(), lastActivityAt: Date())
    }

    private func part(_ r: RobotRig, _ name: String) -> SceneNode? { r.root.childNode(withName: ".//\(name)") }

    @Test func rankChangeRedrawsTheSameRobotInPlace() {
        let model = makeModel(CGSize(width: 1200, height: 800))
        model.render([session(.seniorEngineer)], animated: false)
        let before = model.robot("s:a")
        #expect(before?.look.rank == .seniorEngineer)
        let pos = before?.root.position, headBefore = part(before!, "head")?.image, torsoBefore = part(before!, "torso")?.image
        #expect(part(before!, "headOverlay")?.isHidden == true)
        let targetBefore = model.transit.target(of: "s:a")

        model.render([session(.seniorExpert)], animated: false)
        let after = model.robot("s:a")
        #expect(after === before)
        #expect(after?.look.rank == .seniorExpert)
        #expect(after?.root.position == pos)
        #expect(model.transit.target(of: "s:a") == targetBefore)
        #expect(part(after!, "head")?.image !== headBefore)
        #expect(part(after!, "torso")?.image !== torsoBefore)
        #expect(part(after!, "headOverlay")?.isHidden == false)
        #expect(part(after!, "headOverlay")?.image != nil)
        #expect(after?.root.alpha == 1)

        // And back: the monocle goes away again.
        model.render([session(.seniorEngineer)], animated: false)
        #expect(model.robot("s:a") === before)
        #expect(part(before!, "headOverlay")?.isHidden == true)
        #expect(part(before!, "headOverlay")?.image == nil)
    }

    @Test func sameRankKeepsTheArtUntouched() {
        let model = makeModel(CGSize(width: 1200, height: 800))
        model.render([session(.seniorExpert)], animated: false)
        let r = model.robot("s:a")!
        let head = part(r, "head")?.image
        let baked = model.bakeCount
        model.render([session(.seniorExpert)], animated: false)
        #expect(model.robot("s:a") === r)
        #expect(part(r, "head")?.image === head)
        #expect(model.bakeCount == baked)
    }
}
