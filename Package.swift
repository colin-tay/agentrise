// swift-tools-version:6.0
// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT
import PackageDescription

var products: [Product] = [
    .executable(name: "agentrise-hook", targets: ["TowerHook"]),
    .executable(name: "agentrise-sim", targets: ["TowerSim"]),
]
var targets: [Target] = [
    .target(name: "TowerKit"),
    .target(name: "Agentrise", dependencies: ["TowerKit"], swiftSettings: [.swiftLanguageMode(.v5)]),
    .target(name: "AgentriseScene", dependencies: ["Agentrise", "TowerKit"], swiftSettings: [.swiftLanguageMode(.v5)]),
    .executableTarget(name: "TowerHook", dependencies: ["TowerKit"]),
    .executableTarget(name: "TowerSim", dependencies: ["TowerKit"]),
    .testTarget(name: "AgentriseTests", dependencies: ["Agentrise", "TowerKit"],
                exclude: ["Fixtures"],   // read from the source tree via #filePath
                swiftSettings: [.swiftLanguageMode(.v5)]),
    .testTarget(name: "AgentriseSceneTests", dependencies: ["AgentriseScene", "Agentrise", "TowerKit"],
                swiftSettings: [.swiftLanguageMode(.v5)]),
]
#if os(macOS)
products.append(.executable(name: "Agentrise", targets: ["AgentriseApp"]))
targets += [
    // The Core Graphics art backend (`CGPen`, `CGArtBackend`): shared by the app, its tests and ArtGallery.
    .target(name: "AgentriseMacArt", dependencies: ["AgentriseScene"], swiftSettings: [.swiftLanguageMode(.v5)]),
    .executableTarget(name: "AgentriseApp", dependencies: ["Agentrise", "AgentriseScene", "AgentriseMacArt", "TowerKit"],
                      swiftSettings: [.swiftLanguageMode(.v5)]),
    // Renders `ComparisonScenes` to PNGs (CI puts them side by side with the Windows ones).
    .executableTarget(name: "ArtGallery", dependencies: ["AgentriseScene", "AgentriseMacArt"],
                      swiftSettings: [.swiftLanguageMode(.v5)]),
    .testTarget(name: "AgentriseAppTests", dependencies: ["AgentriseApp", "Agentrise", "AgentriseScene", "AgentriseMacArt", "TowerKit"],
                exclude: ["Fixtures"],   // read from the source tree via #filePath
                swiftSettings: [.swiftLanguageMode(.v5)]),
]
#endif
#if os(Windows)
// Direct2D/DirectWrite spike: draws a robot offscreen and writes it as a PNG (Windows CI only).
targets += [
    .target(name: "CD2DSpike"),
    .executableTarget(name: "D2DSpike", dependencies: ["CD2DSpike"],
                      swiftSettings: [.swiftLanguageMode(.v5)],
                      linkerSettings: [.linkedLibrary("d2d1"), .linkedLibrary("dwrite"),
                                       .linkedLibrary("windowscodecs"), .linkedLibrary("ole32")]),
]
// The Direct2D/DirectWrite art backend (`D2DPen`, `D2DArtBackend`) and its C declarations.
targets += [
    .target(name: "CDirect2D"),
    .target(name: "AgentriseWinArt", dependencies: ["CDirect2D", "AgentriseScene"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("d2d1"), .linkedLibrary("dwrite"),
                             .linkedLibrary("windowscodecs"), .linkedLibrary("ole32")]),
    .executableTarget(name: "ArtGallery", dependencies: ["AgentriseScene", "AgentriseWinArt"],
                      swiftSettings: [.swiftLanguageMode(.v5)]),
    .testTarget(name: "AgentriseWinTests", dependencies: ["AgentriseWin", "AgentriseWinArt", "AgentriseScene", "Agentrise", "TowerKit"],
                swiftSettings: [.swiftLanguageMode(.v5)]),
]
// The Windows app, `Agentrise.exe`: the shell (window, Direct2D display, panel, tray, single instance) is a library,
// so the tests can drive it; the executable is its `main.swift` plus the embedded manifest (Per-Monitor V2 DPI
// awareness, comctl32 v6), linked as a GUI program (no console window).
let manifest = Context.packageDirectory + "\\Sources\\AgentriseWinApp\\Agentrise.manifest"
products.append(.executable(name: "Agentrise", targets: ["AgentriseWinApp"]))
targets += [
    .target(name: "AgentriseWin", dependencies: ["AgentriseWinArt", "CDirect2D", "AgentriseScene", "Agentrise", "TowerKit"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("user32"), .linkedLibrary("gdi32"), .linkedLibrary("shell32"),
                             .linkedLibrary("advapi32"), .linkedLibrary("ole32"), .linkedLibrary("d2d1"),
                             .linkedLibrary("windowscodecs")]),
    .executableTarget(name: "AgentriseWinApp", dependencies: ["AgentriseWin"],
                      exclude: ["Agentrise.manifest"],
                      swiftSettings: [.swiftLanguageMode(.v5)],
                      linkerSettings: [.unsafeFlags(["-Xlinker", "/SUBSYSTEM:WINDOWS", "-Xlinker", "/ENTRY:mainCRTStartup",
                                                     "-Xlinker", "/MANIFEST:EMBED", "-Xlinker", "/MANIFESTINPUT:" + manifest])]),
]
#endif

let package = Package(
    name: "Agentrise",
    platforms: [.macOS(.v15)],
    products: products,
    targets: targets
)
