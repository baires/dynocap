// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "microvm",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "microvm", targets: ["microvm"]),
    ],
    targets: [
        .target(name: "MicroVMCore", path: "Sources/MicroVMCore"),
        .target(
            name: "MicroVMVZ",
            dependencies: ["MicroVMCore"],
            path: "Sources/MicroVMVZ"
        ),
        .executableTarget(
            name: "microvm",
            dependencies: ["MicroVMCore", "MicroVMVZ"],
            path: "Sources/microvm"
        ),
        .testTarget(
            name: "MicroVMCoreTests",
            dependencies: ["MicroVMCore", "MicroVMVZ"],
            path: "Tests/MicroVMCoreTests"
        ),
    ]
)
