// swift-tools-version:5.9
import PackageDescription

//  UI target
//  Xcode  `swift build` Command Line Tools
// scripts/build-app.sh  swiftc
let package = Package(
    name: "Pipkin",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "pipkin", targets: ["pipkin"]),
    ],
    targets: [
        .executableTarget(name: "pipkin"),
        .testTarget(
            name: "PipkinTests",
            dependencies: ["pipkin"]
        ),
    ]
)
