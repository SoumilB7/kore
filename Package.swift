// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Kore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "KoreCore", targets: ["KoreCore"]),
        .executable(name: "Kore", targets: ["Kore"]),
        .executable(name: "kore-cli", targets: ["kore-cli"]),
    ],
    targets: [
        .target(name: "KoreCore"),
        .executableTarget(name: "Kore", dependencies: ["KoreCore"]),
        .executableTarget(name: "kore-cli", dependencies: ["KoreCore"]),
    ]
)
