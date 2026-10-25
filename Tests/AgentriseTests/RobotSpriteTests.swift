// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Testing
import AppKit
import SpriteKit
import Metal
@testable import Agentrise

@MainActor
@Suite struct RobotSpriteTests {
    private let art = RobotArt(scale: 2.5)
    private let look = RobotLook(kind: .boss(.seniorDirector), teamIndex: 1, larkSession: false)

    private func robot(_ look: RobotLook? = nil) -> RobotSprite {
        let l = look ?? self.look
        return RobotSprite(look: l, teamColor: l.teamColor, art: art, phase: 0.7)
    }

    private func node(_ r: RobotSprite, _ name: String) -> SKNode {
        let n = r.childNode(withName: ".//" + name)
        #expect(n != nil, "missing \(name)")
        return n ?? SKNode()
    }

    @Test func buildsNamedParts() {
        let r = robot()
        for name in ["halo", "float", "torso", "head", "headOverlay", "eyes", "leftHand", "rightHand", "ears",
                     "ring", "prop", "pod", "bubble", "bubbleGlow", "name", "lark"] {
            #expect(r.childNode(withName: ".//" + name) != nil, "missing \(name)")
        }
        // The overlay (visor band / monocle) and the eyes turn with the head.
        #expect(node(r, "head").childNode(withName: "headOverlay") != nil)
        #expect(node(r, "head").childNode(withName: "eyes") != nil)
        #expect(node(r, "bubble").childNode(withName: "bubbleGlow") != nil)
    }

    @Test func partsAreSizedInDesignPoints() {
        let r = robot()
        #expect((node(r, "torso") as? SKSpriteNode)?.size == CGSize(width: 60, height: 84))
        #expect((node(r, "halo") as? SKSpriteNode)?.size == CGSize(width: 80, height: 96))
        // Head pivots at the neck (design y 14 + 34), eyes at their centre (14 + 19.5).
        let head = node(r, "head") as? SKSpriteNode
        #expect(abs((head?.anchorPoint.y ?? 0) - (1 - 48.0 / 84)) < 1e-6)
        #expect(head?.position == CGPoint(x: 0, y: 36))
        let eyes = node(r, "eyes") as? SKSpriteNode
        #expect(abs((eyes?.anchorPoint.y ?? 0) - (1 - 33.5 / 84)) < 1e-6)
    }

    @Test func idleLoopsRun() {
        let r = robot()
        for name in ["float", "leftHand", "rightHand", "ears", "ring", "eyes"] {
            #expect(node(r, name).action(forKey: "idle") != nil, "\(name) should idle")
        }
    }

    @Test func codingAnimatesHands() {
        let r = robot()
        r.setAction(.coding)
        #expect(r.action == .coding)
        #expect(node(r, "leftHand").action(forKey: "act") != nil)
        #expect(node(r, "rightHand").action(forKey: "act") != nil)
        // Typing replaces the hands' idle bob, as the old same-key-path animation did.
        #expect(node(r, "leftHand").action(forKey: "idle") == nil)
        #expect(!node(r, "prop").children.isEmpty)
    }

    @Test func browsingKeepsTheBobUnderASideways() {
        let r = robot()
        r.setAction(.browsing)
        // The old act moved translation.x, the bob translation.y: both ran.
        #expect(node(r, "leftHand").action(forKey: "act") != nil)
        #expect(node(r, "leftHand").action(forKey: "idle") != nil)
    }

    @Test func standbyClearsActionAndProps() {
        let r = robot()
        r.setAction(.coding)
        r.setAction(.standby)
        for name in ["leftHand", "rightHand", "head", "float"] {
            #expect(node(r, name).action(forKey: "act") == nil)
        }
        #expect(node(r, "leftHand").action(forKey: "idle") != nil)
        #expect(node(r, "leftHand").position == .zero)
        #expect(node(r, "prop").children.isEmpty)
    }

    @Test func sleepingAddsPodAndShrinksFloat() {
        let r = robot()
        #expect(node(r, "pod").isHidden)
        r.setAction(.sleeping)
        #expect(!node(r, "pod").isHidden)
        #expect(near(node(r, "float").xScale, 0.9, 1e-6))
        #expect(near(node(r, "float").yScale, 0.9, 1e-6))
        #expect(node(r, "prop").children.count == 2)   // two "z"s
        r.setAction(.standby)
        #expect(node(r, "pod").isHidden)
        #expect(node(r, "float").xScale == 1)
        #expect(node(r, "float").position == .zero)
    }

    @Test func waitingAtDoorReplacesTheBob() {
        let r = robot()
        r.setAction(.waitingAtDoor)
        #expect(node(r, "float").action(forKey: "act") != nil)
        #expect(node(r, "float").action(forKey: "idle") == nil)
        #expect(r.childNode(withName: ".//sign") != nil)
    }

    // MARK: Motion, stepped headlessly with SKRenderer

    /// Drives a scene's actions without a view. `at(t)` advances to `t` seconds after the first frame.
    @MainActor private final class Stepper {
        let renderer = SKRenderer(device: MTLCreateSystemDefaultDevice()!)
        let scene = SKScene(size: CGSize(width: 200, height: 200))
        private let base: TimeInterval = 1000
        init(_ nodes: SKNode...) {
            renderer.scene = scene
            nodes.forEach(scene.addChild)
            renderer.update(atTime: base)
        }
        func at(_ t: TimeInterval) { renderer.update(atTime: base + t) }
    }

    private func near(_ a: CGFloat, _ b: CGFloat, _ tol: CGFloat = 0.02) -> Bool { abs(a - b) <= tol }

    @Test func bobMatchesTheOldKeyframes() {
        // phase 0: float [0, -2.5, 0] over 2.6 s, eased over the whole loop (peak at 1.3 s).
        let r = RobotSprite(look: look, teamColor: look.teamColor, art: art, phase: 0)
        let s = Stepper(r)
        let float = node(r, "float")
        s.at(1.3); #expect(near(float.position.y, 2.5))
        s.at(2.6); #expect(near(float.position.y, 0))
        // CA eased the whole 2.6 s loop, not each keyframe: at 0.65 s (a quarter) the progress is
        // caEase(0.25) ≈ 0.129 of the loop → 0.65 pt, where a per-segment ease would give 1.25 pt.
        s.at(2.6 + 0.65); #expect(near(float.position.y, 2.5 * 2 * CGFloat(RobotMotion.caEase(0.25))))
        #expect(near(float.position.y, 0.646))
    }

    @Test func phaseStartsMidLoop() {
        // The old `timeOffset = phase`: at t = 0 the bob is already 1.3 s in, i.e. at its peak.
        let r = RobotSprite(look: look, teamColor: look.teamColor, art: art, phase: 1.3)
        let s = Stepper(r)
        s.at(0.001); #expect(near(node(r, "float").position.y, 2.5))
        s.at(1.3); #expect(near(node(r, "float").position.y, 0))
    }

    @Test func blinkFollowsKeyTimes() {
        // scale.y [1, 1, 0.1, 1, 1] over 4 s at keyTimes [0, .46, .5, .54, 1]: shut at 2 s, open well before/after.
        let r = RobotSprite(look: look, teamColor: look.teamColor, art: art, phase: 0)
        let s = Stepper(r)
        let eyes = node(r, "eyes")
        s.at(1.5); #expect(near(eyes.yScale, 1))
        s.at(2.0); #expect(near(eyes.yScale, 0.1))
        s.at(2.5); #expect(near(eyes.yScale, 1))
    }

    @Test func waitingLongWavesFaster() {
        // float [0, -4] autoreversed over `speed`: 0.6 s normally, 0.28 s after a long wait.
        let slow = robot(), fast = robot()
        slow.setAction(.waitingAtDoor)
        fast.setAction(.waitingAtDoor, waitingLong: true)
        let s = Stepper(slow, fast)
        s.at(0.28)
        #expect(near(node(fast, "float").position.y, 4))
        #expect(node(slow, "float").position.y < 3)
        s.at(0.6)
        #expect(near(node(slow, "float").position.y, 4))
    }

    @Test func sleepingShiftsLikeTheOldTransform() {
        // Old floatGroup.transform = translate(3, 6) then scale 0.9 about the canvas centre, with the y
        // translation replaced on screen by the bob's `transform.translation.y` (see `sleepingFloatPosition`).
        let r = RobotSprite(look: look, teamColor: look.teamColor, art: art, phase: 0)
        r.setAction(.sleeping)
        let s = Stepper(r)
        s.at(2.6)   // bob back at rest
        #expect(near(node(r, "float").position.x, 2.7))
        #expect(near(node(r, "float").position.y, 4.2))
    }

    @Test func handsTypeAndReturnHome() {
        let r = RobotSprite(look: look, teamColor: look.teamColor, art: art, phase: 0)
        r.setAction(.coding)
        let s = Stepper(r)
        s.at(0.18)
        #expect(near(node(r, "leftHand").position.y, 2.5))
        r.setAction(.standby)
        #expect(node(r, "leftHand").position == .zero)
    }

    @Test func commandFailedShakesTheWholeRobotNotItsPosition() {
        let r = robot()
        r.position = CGPoint(x: 50, y: 60)
        r.setAction(.commandFailed)
        let s = Stepper(r)
        s.at(0.06)
        #expect(r.position == CGPoint(x: 50, y: 60))   // the scene owns `position`
        r.setAction(.standby)
        #expect(node(r, "rig").position == .zero)
    }

    @Test func bubbleNilHides() {
        let r = robot()
        #expect(node(r, "bubble").isHidden)
        r.setBubble("等你回复", color: NSColor(hex: 0xFFC95C), pulse: true)
        #expect(!node(r, "bubble").isHidden)
        #expect(node(r, "bubbleGlow").action(forKey: "pulse") != nil)
        r.setBubble("思考中", color: .systemBlue, pulse: false)
        #expect(node(r, "bubbleGlow").action(forKey: "pulse") == nil)
        #expect(node(r, "bubbleGlow").alpha == 0)
        r.setBubble(nil, color: .systemBlue, pulse: false)
        #expect(node(r, "bubble").isHidden)
    }

    @Test func nameSitsUnderTheFeet() {
        let r = robot()
        r.setName("项目A\n资深总监")
        let name = node(r, "name") as? SKSpriteNode
        #expect(name?.texture != nil)
        #expect(name?.size == RobotArt.nameImageSize("项目A\n资深总监", small: false))
        // Old label top at design y 82 → 2 pt above the feet, minus the shadow padding.
        #expect(name.map { $0.frame.maxY } == 2 + RobotArt.namePadding)
    }

    @Test func dimSetsAlphaImmediately() {
        let r = robot()
        r.setDimmed(true)
        #expect(near(r.alpha, 0.18, 1e-6))
        #expect(!r.hasActions())
        r.setDimmed(false)
        #expect(r.alpha == 1)
    }

    @Test func fadeAndDimComposeInEitherOrder() {
        let r = robot()
        r.fade = 0.5
        #expect(r.alpha == 0.5)
        r.setDimmed(true)
        #expect(near(r.alpha, 0.5 * 0.18, 1e-6))
        r.fade = 1
        #expect(near(r.alpha, 0.18, 1e-6))
        r.fade = 0.25
        r.setDimmed(false)
        #expect(r.alpha == 0.25)
        // Re-baking keeps both.
        r.setDimmed(true)
        let copy = r.rebaked(with: RobotArt(scale: 1.25))
        #expect(copy.fade == 0.25 && copy.dimmed)
        #expect(near(copy.alpha, 0.25 * 0.18, 1e-6))
    }

    @Test func faceSwapUsesEyesTexture() {
        let r = robot()
        let eyes = node(r, "eyes") as? SKSpriteNode
        let focused = RobotSprite.texture(art.image(.eyes(.focused)))
        #expect(eyes?.texture === focused)        // calm reuses the focused image
        #expect(eyes?.alpha == 0.75)
        r.setFace(.happy)
        #expect(r.face == .happy)
        #expect(eyes?.texture !== focused)
        #expect(eyes?.alpha == 1)
        #expect(eyes?.action(forKey: "idle") == nil)   // only open eyes blink
        r.setFace(.focused)
        #expect(eyes?.texture === focused)
        #expect(eyes?.action(forKey: "idle") != nil)
    }

    @Test func texturesAreShared() {
        let a = robot(), b = robot()
        let ta = (node(a, "torso") as? SKSpriteNode)?.texture
        let tb = (node(b, "torso") as? SKSpriteNode)?.texture
        #expect(ta != nil && ta === tb)
    }

    @Test func larkBadgeToggles() {
        let r = robot()
        #expect(node(r, "lark").isHidden)
        r.setLarkBadge(true)
        #expect(!node(r, "lark").isHidden)
        r.setLarkBadge(false)
        #expect(node(r, "lark").isHidden)
    }

    @Test func scaleAndHitRect() {
        let scene = SKScene(size: CGSize(width: 400, height: 300))
        let r = robot()
        scene.addChild(r)
        r.position = CGPoint(x: 100, y: 50)
        r.setRobotScale(0.5)
        #expect(r.robotScale == 0.5)
        #expect(r.xScale == 0.5 && r.yScale == 0.5)
        #expect(r.hitRect == CGRect(x: 85, y: 50, width: 30, height: 42))
    }

    @Test func caEaseMatchesBezier() {
        #expect(abs(RobotMotion.caEase(0.5) - 0.5) < 1e-6)
        #expect(RobotMotion.caEase(0) == 0 && abs(RobotMotion.caEase(1) - 1) < 1e-6)
        for y in [0.1, 0.46, 0.54, 0.9] {
            #expect(abs(RobotMotion.caEase(RobotMotion.caEaseInverse(y)) - y) < 1e-4)
        }
    }

    @Test func caEaseTableTracksExactCurve() {
        var worst = 0.0
        for i in 0...4000 {
            let x = Double(i) / 4000
            worst = max(worst, abs(RobotMotion.caEase(x) - RobotMotion.caEaseExact(x)))
        }
        #expect(worst < 1e-4)
    }
}
