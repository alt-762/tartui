// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "TartUI",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TartUI", targets: ["TartUI"])
    ],
    targets: [
        .target(
            name: "TartKit",
            path: "Sources/TartKit"
        ),
        .executableTarget(
            name: "TartUI",
            dependencies: ["TartKit"],
            path: "Sources/TartUI"
        ),
        .testTarget(
            name: "TartKitTests",
            dependencies: ["TartKit"],
            path: "Tests/TartKitTests"
        )
    ]
)
