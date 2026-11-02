// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import AppKit
import SpriteKit
import os
import Agentrise
import AgentriseScene
import AgentriseMacArt

/// What the window needs from a tower view (a seam for test doubles). The app model drives the scene itself
/// (`TowerAppModel` renders `model` directly, animated unless the view is paused).
protocol TowerDisplay: AnyObject {
    var onClickSession: ((String) -> Void)? { get set }
    var onHoverSession: ((String?) -> Void)? { get set }
    var onLayout: ((BuildingLayout) -> Void)? { get set }
    func highlight(_ sessionId: String?)
    func setOccluded(_ o: Bool)
    func snapshot() -> CGImage?
}

/// The SpriteKit tower view: hosts the `SpriteKitDisplay` that draws the portable `TowerSceneModel`.
final class TowerView: SKView, TowerDisplay {
    var onClickSession: ((String) -> Void)? {
        get { model.onClickSession }
        set { model.onClickSession = newValue }
    }
    var onHoverSession: ((String?) -> Void)? {
        get { model.onHoverSession }
        set { model.onHoverSession = newValue }
    }
    /// Assigning delivers the current layout right away: the model may already have been laid out
    /// for this size, and the window would otherwise never learn where the panel goes.
    var onLayout: ((BuildingLayout) -> Void)? {
        didSet { onLayout?(model.geo) }
    }

    let model: TowerSceneModel
    let display: SpriteKitDisplay

    /// Robots are baked at this backing scale until the view is in a window.
    static let fallbackScale: CGFloat = 2

    override init(frame: NSRect) {
        model = TowerSceneModel(size: frame.size, scale: Self.fallbackScale, art: CGArtBackend.shared)
        display = SpriteKitDisplay(model: model)
        super.init(frame: frame)
        ignoresSiblingOrder = true
        allowsTransparency = false
        display.onLayout = { [weak self] in self?.onLayout?($0) }
        presentScene(display)
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

    /// View points (bottom-left origin) → the model's layout coordinates (top-left origin).
    private func layoutPoint(of event: NSEvent) -> CGPoint {
        model.layoutPoint(convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) { model.hover(at: layoutPoint(of: event)) }
    override func mouseExited(with event: NSEvent) { model.hover(at: nil) }
    override func mouseDown(with event: NSEvent) { model.click(at: layoutPoint(of: event)) }

    /// Robots rendered before the view had a window were baked at the fallback scale.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let w = window { display.backingScaleChanged(w.backingScaleFactor) }
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        if window != nil {
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.checkFrames() }
            RunLoop.main.add(t, forMode: .common)
            watchdogTimer = t
        }
    }

    // MARK: Stalls

    private static let log = Logger(subsystem: "io.github.colin-tay.agentrise", category: "render")
    private var watchdog = FrameWatchdog()
    private var watchdogTimer: Timer?

    /// Restarts drawing when SpriteKit stopped delivering frames to the visible, unpaused view (see `FrameWatchdog`).
    func checkFrames(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let due = !isPaused && window?.occlusionState.contains(.visible) == true
        guard watchdog.shouldRestart(lastFrame: display.lastFrameAt, framesDue: due, now: now) else { return }
        Self.log.notice("no frames for \(FrameWatchdog.stallAfter, privacy: .public)s while visible: restarting the display link")
        isPaused = true
        isPaused = false
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let w = window { display.backingScaleChanged(w.backingScaleFactor) }
    }

    func highlight(_ sessionId: String?) { model.highlight(sessionId) }

    /// A fully occluded window needs no frames (the model doesn't step either); everything else keeps running.
    func setOccluded(_ o: Bool) { isPaused = o }

    func snapshot() -> CGImage? {
        display.sync()
        return texture(from: display)?.cgImage()
    }
}
