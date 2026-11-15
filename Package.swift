// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "dynocap",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "dynocap", targets: ["dynocap"]),
    ],
    targets: [
        .target(name: "DynoCapCore", path: "Sources/DynoCapCore"),
        .target(
            name: "DynoCapVZ",
            dependencies: ["DynoCapCore"],
            path: "Sources/DynoCapVZ"
        ),
        .executableTarget(
            name: "dynocap",
            dependencies: ["DynoCapCore", "DynoCapVZ"],
            path: "Sources/dynocap"
        ),
        .testTarget(
            name: "DynoCapCoreTests",
            dependencies: ["DynoCapCore", "DynoCapVZ", "dynocap"],
            path: "Tests/DynoCapCoreTests"
        ),
    ]
)
