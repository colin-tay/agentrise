// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Testing
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import Agentrise
@testable import AgentriseScene

@Suite struct RobotRigTests {
    private let art = RobotArt(scale: 2.5, backend: RecordingBackend())
    private let look = RobotLook(kind: .boss(.seniorDirector), teamIndex: 1, larkSession: false)

    private func robot(_ look: RobotLook? = nil, phase: TimeInterval = 0.7) -> RobotRig {
        let l = look ?? self.look
        return RobotRig(look: l, teamColor: l.teamColor, art: art, phase: phase)
    }

    private func node(_ r: RobotRig, _ name: String) -> SceneNode {
        let n = r.root.childNode(withName: ".//" + name)
        #expect(n != nil, "missing \(name)")
        return n ?? SceneNode()
    }

    @Test func buildsNamedParts() {
        let r = robot()
        for name in ["halo", "float", "torso", "head", "headOverlay", "eyes", "leftHand", "rightHand", "ears",
                     "ring", "prop", "pod", "bubble", "bubbleGlow", "name", "lark"] {
            #expect(r.root.childNode(withName: ".//" + name) != nil, "missing \(name)")
        }
        // The overlay (visor band / monocle) and the eyes turn with the head.
        #expect(node(r, "head").childNode(withName: "headOverlay") != nil)
        #expect(node(r, "head").childNode(withName: "eyes") != nil)
        #expect(node(r, "bubble").childNode(withName: "bubbleGlow") != nil)
        // Containers are plain nodes; parts are sprites.
        #expect(!node(r, "rig").isSprite && !node(r, "float").isSprite && !node(r, "prop").isSprite)
        #expect(node(r, "torso").isSprite && node(r, "bubbleGlow").isSprite)
        // The halo takes the team colour.
        #expect(node(r, "halo").color == look.teamColor && node(r, "halo").colorBlendFactor == 1)
    }

    @Test func partsAreSizedInDesignPoints() {
        let r = robot()
        #expect(node(r, "torso").size == CGSize(width: 60, height: 84))
        #expect(node(r, "halo").size == CGSize(width: 80, height: 96))
        // Head pivots at the neck (design y 14 + 34), eyes at their centre (14 + 19.5).
        let head = node(r, "head")
        #expect(abs(head.anchorPoint.y - (1 - 48.0 / 84)) < 1e-6)
        #expect(head.position == CGPoint(x: 0, y: 36))
        #expect(abs(node(r, "eyes").anchorPoint.y - (1 - 33.5 / 84)) < 1e-6)
    }

    @Test func idleLoopsRun() {
        let r = robot()
        for name in ["float", "leftHand", "rightHand", "ears", "ring", "eyes"] {
            #expect(node(r, name).hasTween(forKey: "idle"), "\(name) should idle")
        }
    }

    @Test func codingAnimatesHands() {
        let r = robot()
        r.setAction(.coding)
        #expect(r.action == .coding)
        #expect(node(r, "leftHand").hasTween(forKey: "act"))
        #expect(node(r, "rightHand").hasTween(forKey: "act"))
        // Typing replaces the hands' idle bob, as the old same-key-path animation did.
        #expect(!node(r, "leftHand").hasTween(forKey: "idle"))
        #expect(!node(r, "prop").children.isEmpty)
    }

    @Test func browsingKeepsTheBobUnderASideways() {
        let r = robot()
        r.setAction(.browsing)
        // The old act moved translation.x, the bob translation.y: both ran.
        #expect(node(r, "leftHand").hasTween(forKey: "act"))
        #expect(node(r, "leftHand").hasTween(forKey: "idle"))
    }

    @Test func standbyClearsActionAndProps() {
        let r = robot()
        r.setAction(.coding)
        r.setAction(.standby)
        for name in ["leftHand", "rightHand", "head", "float"] {
            #expect(!node(r, name).hasTween(forKey: "act"))
        }
        #expect(node(r, "leftHand").hasTween(forKey: "idle"))
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
        #expect(node(r, "float").hasTween(forKey: "act"))
        #expect(!node(r, "float").hasTween(forKey: "idle"))
        #expect(r.root.childNode(withName: ".//sign") != nil)
    }

    // MARK: Motion, stepped by the tween engine

    /// Drives a rig's tweens. `at(t)` advances to `t` seconds after the first frame.
    private final class Stepper {
        private let roots: [SceneNode]
        private var now: TimeInterval = 0
        init(_ rigs: RobotRig...) {
            roots = rigs.map(\.root)
            for r in roots { TweenEngine.step(r, dt: 0) }
        }
        func at(_ t: TimeInterval) {
            for r in roots { TweenEngine.step(r, dt: t - now) }
            now = t
        }
    }

    private func near(_ a: CGFloat, _ b: CGFloat, _ tol: CGFloat = 0.02) -> Bool { abs(a - b) <= tol }

    @Test func bobMatchesTheOldKeyframes() {
        // phase 0: float [0, -2.5, 0] over 2.6 s, eased over the whole loop (peak at 1.3 s).
        let r = robot(phase: 0)
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
        let r = robot(phase: 1.3)
        let s = Stepper(r)
        s.at(0.001); #expect(near(node(r, "float").position.y, 2.5))
        s.at(1.3); #expect(near(node(r, "float").position.y, 0))
    }

    @Test func blinkFollowsKeyTimes() {
        // scale.y [1, 1, 0.1, 1, 1] over 4 s at keyTimes [0, .46, .5, .54, 1]: shut at 2 s, open well before/after.
        let r = robot(phase: 0)
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
        let r = robot(phase: 0)
        r.setAction(.sleeping)
        let s = Stepper(r)
        s.at(2.6)   // bob back at rest
        #expect(near(node(r, "float").position.x, 2.7))
        #expect(near(node(r, "float").position.y, 4.2))
    }

    @Test func handsTypeAndReturnHome() {
        let r = robot(phase: 0)
        r.setAction(.coding)
        let s = Stepper(r)
        s.at(0.18)
        #expect(near(node(r, "leftHand").position.y, 2.5))
        r.setAction(.standby)
        #expect(node(r, "leftHand").position == .zero)
    }

    @Test func commandFailedShakesTheWholeRobotNotItsPosition() {
        let r = robot()
        r.root.position = CGPoint(x: 50, y: 60)
        r.setAction(.commandFailed)
        let s = Stepper(r)
        s.at(0.06)
        #expect(r.root.position == CGPoint(x: 50, y: 60))   // the scene owns `position`
        r.setAction(.standby)
        #expect(node(r, "rig").position == .zero)
    }

    @Test func bubbleNilHides() {
        let r = robot()
        #expect(node(r, "bubble").isHidden)
        r.setBubble("等你回复", color: Color(hex: 0xFFC95C), pulse: true)
        #expect(!node(r, "bubble").isHidden)
        #expect(node(r, "bubbleGlow").hasTween(forKey: "pulse"))
        r.setBubble("思考中", color: Color(hex: 0x24477A), pulse: false)
        #expect(!node(r, "bubbleGlow").hasTween(forKey: "pulse"))
        #expect(node(r, "bubbleGlow").alpha == 0)
        r.setBubble(nil, color: Color(hex: 0x24477A), pulse: false)
        #expect(node(r, "bubble").isHidden)
    }

    @Test func nameSitsUnderTheFeet() {
        let r = robot()
        r.setName("项目A\n资深总监")
        let name = node(r, "name")
        #expect(name.image != nil)
        #expect(name.size == art.nameImageSize("项目A\n资深总监", small: false))
        // Old label top at design y 82 → 2 pt above the feet, minus the shadow padding.
        #expect(name.frame.maxY == 2 + RobotArt.namePadding)
    }

    @Test func dimSetsAlphaImmediately() {
        let r = robot()
        r.setDimmed(true)
        #expect(near(r.root.alpha, 0.18, 1e-6))
        #expect(!r.root.hasTweens)
        r.setDimmed(false)
        #expect(r.root.alpha == 1)
    }

    @Test func fadeAndDimComposeInEitherOrder() {
        let r = robot()
        r.fade = 0.5
        #expect(r.root.alpha == 0.5)
        r.setDimmed(true)
        #expect(near(r.root.alpha, 0.5 * 0.18, 1e-6))
        r.fade = 1
        #expect(near(r.root.alpha, 0.18, 1e-6))
        r.fade = 0.25
        r.setDimmed(false)
        #expect(r.root.alpha == 0.25)
        // Re-baking keeps both.
        r.setDimmed(true)
        let copy = r.rebaked(with: RobotArt(scale: 1.25, backend: RecordingBackend()))
        #expect(copy.fade == 0.25 && copy.dimmed)
        #expect(near(copy.root.alpha, 0.25 * 0.18, 1e-6))
    }

    @Test func faceSwapUsesEyesImage() {
        let r = robot()
        let eyes = node(r, "eyes")
        let focused = art.image(.eyes(.focused))
        #expect(eyes.image === focused)           // calm reuses the focused image
        #expect(r.sourceImage(of: eyes) === focused)
        #expect(eyes.alpha == 0.75)
        r.setFace(.happy)
        #expect(r.face == .happy)
        #expect(eyes.image !== focused)
        #expect(eyes.alpha == 1)
        #expect(!eyes.hasTween(forKey: "idle"))   // only open eyes blink
        r.setFace(.focused)
        #expect(eyes.image === focused)
        #expect(eyes.hasTween(forKey: "idle"))
    }

    @Test func imagesAreShared() {
        let a = robot(), b = robot()
        let ta = node(a, "torso").image, tb = node(b, "torso").image
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
        let r = robot()
        r.root.position = CGPoint(x: 100, y: 50)
        r.setRobotScale(0.5)
        #expect(r.robotScale == 0.5)
        #expect(r.root.xScale == 0.5 && r.root.yScale == 0.5)
        #expect(r.hitRect == CGRect(x: 85, y: 50, width: 30, height: 42))
    }

    /// Every image a rig shows is handed to its atlas, so the display can draw it from a shared page.
    @Test func boundImagesAreQueuedOnTheAtlas() {
        let atlas = TextureAtlas(backend: art.backend)
        let r = robot()
        r.atlas = atlas
        r.setName("项目A\n资深总监")
        #expect(atlas.commit())
        #expect(atlas.isPacked(art.image(.torso(look))))
        #expect(atlas.isPacked(node(r, "name").image!))
        r.setFace(.happy)
        #expect(atlas.commit())
        #expect(atlas.isPacked(art.image(.eyes(.happy))))
    }
}
