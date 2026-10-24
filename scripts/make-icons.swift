// Renders assets/*.svg into PNGs and Resources/AppIcon.icns.
// Usage: swift scripts/make-icons.swift   (run from the repo root)
import AppKit

func render(_ svg: String, size: Int, to path: String) throws {
    guard let image = NSImage(contentsOfFile: svg) else { throw NSError(domain: "make-icons", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot load \(svg)"]) }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let fm = FileManager.default
for size in [64, 256, 512] { try render("assets/logo.svg", size: size, to: "assets/logo-\(size).png") }

let iconset = NSTemporaryDirectory() + "AppIcon.iconset"
try? fm.removeItem(atPath: iconset)
try fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render("assets/appicon.svg", size: base, to: "\(iconset)/icon_\(base)x\(base).png")
    try render("assets/appicon.svg", size: base * 2, to: "\(iconset)/icon_\(base)x\(base)@2x.png")
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset, "-o", "Resources/AppIcon.icns"]
try p.run(); p.waitUntilExit()
guard p.terminationStatus == 0 else { fatalError("iconutil failed") }
print("wrote assets/logo-{64,256,512}.png and Resources/AppIcon.icns")
