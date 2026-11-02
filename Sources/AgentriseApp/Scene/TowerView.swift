// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import AppKit
import SpriteKit
import Metal
import QuartzCore
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

/// The tower view: draws the `SpriteKitDisplay` of the portable `TowerSceneModel` into its Metal layer with an
/// `SKRenderer`, one frame per tick of the view's own display link.
///
/// Not an `SKView`: its frame clock broke after display changes in three ways (no frames after a display wake;
/// a frame time far in the future after an external display was unplugged, so it skipped every frame; frames
/// still due but never drawn), and nothing outside SpriteKit could restart it. The view's display link
/// (`NSView.displayLink`) follows the window from screen to screen, and frame times are the media clock's.
final class TowerView: NSView, TowerDisplay {
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
    /// SpriteKit's own default for an `SKView`.
    static let framesPerSecond: Float = 60

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let renderer: SKRenderer
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private var link: CADisplayLink?

    /// No frames run (a covered window); the scene keeps its state.
    var isPaused = false {
        didSet { link?.isPaused = isPaused }
    }

    override init(frame: NSRect) {
        model = TowerSceneModel(size: frame.size, scale: Self.fallbackScale, art: CGArtBackend.shared)
        display = SpriteKitDisplay(model: model)
        device = MTLCreateSystemDefaultDevice()!
        queue = device.makeCommandQueue()!
        renderer = SKRenderer(device: device)
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        updateDrawableSize()
        renderer.ignoresSiblingOrder = true
        renderer.scene = display
        display.onLayout = { [weak self] in self?.onLayout?($0) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer {
        let l = CAMetalLayer()
        l.device = device
        l.pixelFormat = .bgra8Unorm
        l.framebufferOnly = true
        l.isOpaque = true
        l.contentsScale = Self.fallbackScale
        return l
    }

    override var isOpaque: Bool { true }

    // MARK: Size and scale

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // The scene (scale mode `.fill`) is as big as the view; the drawable is that in pixels.
        if newSize.width >= 1, newSize.height >= 1 { display.size = newSize }
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        guard let metalLayer = layer as? CAMetalLayer else { return }   // not yet made during `super.init`
        let s = metalLayer.contentsScale
        metalLayer.drawableSize = CGSize(width: max(1, bounds.width * s), height: max(1, bounds.height * s))
    }

    /// Robots rendered before the view had a window were baked at the fallback scale.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let w = window { backingScaleChanged(w.backingScaleFactor) }
        startFrames()
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        if window != nil {
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.checkFrames() }
            RunLoop.main.add(t, forMode: .common)
            watchdogTimer = t
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let w = window { backingScaleChanged(w.backingScaleFactor) }
    }

    private func backingScaleChanged(_ scale: CGFloat) {
        metalLayer.contentsScale = scale
        updateDrawableSize()
        display.backingScaleChanged(scale)
    }

    // MARK: Frames

    /// A new display link for the view's window (none without one).
    private func startFrames() {
        link?.invalidate()
        link = nil
        guard window != nil else { return }
        let l = displayLink(target: self, selector: #selector(frame(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: Self.framesPerSecond / 2, maximum: Self.framesPerSecond,
                                                     preferred: Self.framesPerSecond)
        l.isPaused = isPaused
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func frame(_ link: CADisplayLink) {
        renderer.update(atTime: CACurrentMediaTime())
        guard let drawable = metalLayer.nextDrawable() else { return }
        draw(into: drawable.texture) { $0.present(drawable) }
    }

    /// Renders the scene as it stands into `texture` (sized like the drawable).
    private func draw(into texture: MTLTexture, finish: (MTLCommandBuffer) -> Void) {
        guard let buffer = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = Self.clearColor
        renderer.render(withViewport: CGRect(x: 0, y: 0, width: texture.width, height: texture.height),
                        commandBuffer: buffer, renderPassDescriptor: pass)
        finish(buffer)
        buffer.commit()
    }

    private static let clearColor: MTLClearColor = {
        let c = NSColor(hex: 0x0A0E26).usingColorSpace(.sRGB)!
        return MTLClearColor(red: Double(c.redComponent), green: Double(c.greenComponent), blue: Double(c.blueComponent), alpha: 1)
    }()

    // MARK: Stalls

    private static let log = Logger(subsystem: "io.github.colin-tay.agentrise", category: "render")
    private var watchdog = FrameWatchdog()
    private var watchdogTimer: Timer?

    /// Starts a new display link when the visible, unpaused view got no frames (see `FrameWatchdog`).
    func checkFrames(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let due = !isPaused && window?.occlusionState.contains(.visible) == true
        guard watchdog.shouldRestart(lastFrame: display.lastFrameAt, framesDue: due, now: now) else { return }
        Self.log.notice("no frames for \(FrameWatchdog.stallAfter, privacy: .public)s while visible: restarting the display link")
        startFrames()
    }

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

    // MARK: TowerDisplay

    func highlight(_ sessionId: String?) { model.highlight(sessionId) }

    /// A fully occluded window needs no frames (the model doesn't step either); everything else keeps running.
    func setOccluded(_ o: Bool) { isPaused = o }

    /// The scene as it stands, at the drawable's size.
    func snapshot() -> CGImage? {
        display.sync()
        let size = metalLayer.drawableSize
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(size.width), height: Int(size.height), mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .managed
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        var done: MTLCommandBuffer?
        draw(into: texture) { buffer in
            buffer.makeBlitCommandEncoder().map { $0.synchronize(resource: texture); $0.endEncoding() }
            done = buffer
        }
        guard let buffer = done else { return nil }
        buffer.waitUntilCompleted()
        let row = texture.width * 4
        var pixels = [UInt8](repeating: 0, count: row * texture.height)
        texture.getBytes(&pixels, bytesPerRow: row, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        guard let data = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: texture.width, height: texture.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: row,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: data, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
