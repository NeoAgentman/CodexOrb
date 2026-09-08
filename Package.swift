// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CodexOrb",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "CodexOrb", targets: ["CodexOrb"]),
        .library(name: "CodexOrbCore", targets: ["CodexOrbCore"]),
    ],
    targets: [
        .target(name: "CodexOrbCore", resources: [.copy("Resources/Tools")]),
        .executableTarget(
            name: "CodexOrb",
            dependencies: ["CodexOrbCore"]),
        .executableTarget(
            name: "CodexOrbCoreChecks",
            dependencies: ["CodexOrbCore"]),
    ])
