// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AntScopeKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AntScopeCore", targets: ["AntScopeCore"]),
        .library(name: "AntScopeIO", targets: ["AntScopeIO"]),
        .library(name: "AntScopeTransport", targets: ["AntScopeTransport"]),
    ],
    targets: [
        .executableTarget(
            name: "AntScopeApp",
            dependencies: ["AntScopeCore", "AntScopeIO", "AntScopeTransport"]
        ),
        .executableTarget(
            name: "antscope-probe",
            dependencies: ["AntScopeCore", "AntScopeIO", "AntScopeTransport"]
        ),
        .target(name: "AntScopeCore"),
        .target(name: "AntScopeIO", dependencies: ["AntScopeCore"]),
        .target(name: "AntScopeTransport", dependencies: ["AntScopeCore"]),
        .testTarget(name: "AntScopeCoreTests", dependencies: ["AntScopeCore"]),
        .testTarget(name: "AntScopeTransportTests", dependencies: ["AntScopeTransport"]),
        .testTarget(
            name: "AntScopeIOTests",
            dependencies: ["AntScopeIO"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
