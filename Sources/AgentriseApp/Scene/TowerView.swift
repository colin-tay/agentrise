// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import AppKit
import SpriteKit
import Agentrise

/// What the window and the controller need from a tower view (a seam for test doubles).
protocol TowerDisplay: AnyObject {
    var onClickSession: ((String) -> Void)? { get set }
    var onHoverSession: ((String?) -> Void)? { get set }
    var onLayout: ((BuildingLayout) -> Void)? { get set }
    func render(_ sessions: [Session])
    func setHeader(_ c: TowerCounts)
    func highlight(_ sessionId: String?)
    func noteSubResult(sessionId: String, subId: String, success: Bool)
    func setOccluded(_ o: Bool)
    func snapshot() -> CGImage?
}

/// The SpriteKit tower view.
final class TowerView: SKView, TowerDisplay {
    var onClickSession: ((String) -> Void)? {
        get { towerScene.onClickSession }
        set { towerScene.onClickSession = newValue }
    }
    var onHoverSession: ((String?) -> Void)? {
        get { towerScene.onHoverSession }
        set { towerScene.onHoverSession = newValue }
    }
    /// Assigning delivers the current layout right away: the scene may already have been laid out
    /// for this size, and the window would otherwise never learn where the panel goes.
    var onLayout: ((BuildingLayout) -> Void)? {
        didSet { onLayout?(towerScene.geo) }
    }

    let towerScene: TowerScene

    override init(frame: NSRect) {
        towerScene = TowerScene(size: frame.size)
        super.init(frame: frame)
        ignoresSiblingOrder = true
        allowsTransparency = false
        towerScene.onLayout = { [weak self] in self?.onLayout?($0) }
        presentScene(towerScene)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Mouse

    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    /// View points (bottom-left origin) → the scene's layout coordinates (top-left origin).
    private func layoutPoint(of event: NSEvent) -> CGPoint {
        towerScene.layoutPoint(convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) { towerScene.hover(at: layoutPoint(of: event)) }
    override func mouseExited(with event: NSEvent) { towerScene.hover(at: nil) }
    override func mouseDown(with event: NSEvent) { towerScene.click(at: layoutPoint(of: event)) }

    /// Robots rendered before the view had a window were baked at the fallback scale.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let w = window { towerScene.backingScaleChanged(w.backingScaleFactor) }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        towerScene.backingScaleChanged(window?.backingScaleFactor)
    }

    /// While the window is covered no frames run, so departures and fade-ins would never finish: render
    /// without animation then (robots that are gone vanish at once).
    func render(_ sessions: [Session]) { towerScene.render(sessions, animated: !isPaused) }
    func setHeader(_ c: TowerCounts) { towerScene.setHeader(c) }
    func highlight(_ sessionId: String?) { towerScene.highlight(sessionId) }
    func noteSubResult(sessionId: String, subId: String, success: Bool) {
        towerScene.noteSubResult(sessionId: sessionId, subId: subId, success: success)
    }

    /// A fully occluded window needs no frames; everything else keeps running.
    func setOccluded(_ o: Bool) { isPaused = o }

    func snapshot() -> CGImage? { texture(from: towerScene)?.cgImage() }
}
