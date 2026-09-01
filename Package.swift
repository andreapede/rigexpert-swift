// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RigXSwift",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RigXCore", targets: ["RigXCore"]),
        .library(name: "RigXIO", targets: ["RigXIO"]),
        .library(name: "RigXTransport", targets: ["RigXTransport"]),
    ],
    targets: [
        .executableTarget(
            name: "RigXSwiftApp",
            dependencies: ["RigXCore", "RigXIO", "RigXTransport"]
        ),
        .executableTarget(
            name: "rigx-probe",
            dependencies: ["RigXCore", "RigXIO", "RigXTransport"]
        ),
        .target(name: "RigXCore"),
        .target(name: "RigXIO", dependencies: ["RigXCore"]),
        .target(name: "RigXTransport", dependencies: ["RigXCore"]),
        .testTarget(name: "RigXCoreTests", dependencies: ["RigXCore"]),
        .testTarget(name: "RigXSwiftAppTests", dependencies: ["RigXSwiftApp"]),
        .testTarget(name: "RigXTransportTests", dependencies: ["RigXTransport"]),
        .testTarget(
            name: "RigXIOTests",
            dependencies: ["RigXIO"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
