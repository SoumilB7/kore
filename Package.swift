// swift-tools-version: 6.0
import PackageDescription

/// Release builds optimise for size: a UI app gains nothing measurable from -O's larger code.
let releaseForSize: [SwiftSetting] = [.unsafeFlags(["-Osize"], .when(configuration: .release))]

let package = Package(
    name: "Kore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "KoreCore", targets: ["KoreCore"]),
        .executable(name: "Kore", targets: ["Kore"]),
        .executable(name: "kore-cli", targets: ["kore-cli"]),
    ],
    targets: [
        .target(name: "KoreCore", swiftSettings: releaseForSize),
        .executableTarget(name: "Kore", dependencies: ["KoreCore"], swiftSettings: releaseForSize),
        .executableTarget(name: "kore-cli", dependencies: ["KoreCore"], swiftSettings: releaseForSize),
    ]
)
