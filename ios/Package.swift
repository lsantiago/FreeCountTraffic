// swift-tools-version: 5.9
import PackageDescription

// SwiftPM package that xtool (https://github.com/xtool-org/xtool) can build into an iOS app:
//   xtool dev            (from this folder, with `scripts/export-models.sh` run once)
// CI builds the same sources through XcodeGen + xcodebuild (see project.yml and ../.github/workflows/ios.yml).
let package = Package(
    name: "FreeCountTraffic",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "FreeCountTraffic", targets: ["FreeCountTraffic"]),
        .library(name: "TrafficCore", targets: ["TrafficCore"]),
    ],
    targets: [
        // Pure Swift counting / tracking / speed logic (port of the Android Kotlin core).
        .target(name: "TrafficCore"),
        .target(
            name: "FreeCountTraffic",
            dependencies: ["TrafficCore"],
            resources: [
                .copy("Resources/yolo11n.mlpackage"),
                .copy("Resources/yolo11s.mlpackage"),
                .copy("Resources/yolo11m.mlpackage"),
            ]
        ),
        .testTarget(name: "TrafficCoreTests", dependencies: ["TrafficCore"]),
    ]
)
