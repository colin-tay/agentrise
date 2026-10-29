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
#endif

let package = Package(
    name: "Agentrise",
    platforms: [.macOS(.v15)],
    products: products,
    targets: targets
)
