// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Agentrise",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "agentrise-hook", targets: ["TowerHook"]),
        .executable(name: "Agentrise", targets: ["Agentrise"]),
        .executable(name: "agentrise-sim", targets: ["TowerSim"]),
    ],
    targets: [
        .target(name: "TowerKit"),
        .executableTarget(name: "TowerHook", dependencies: ["TowerKit"]),
        .executableTarget(name: "Agentrise", dependencies: ["TowerKit"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "TowerSim", dependencies: ["TowerKit"]),
        .testTarget(name: "AgentriseTests", dependencies: ["Agentrise"],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
