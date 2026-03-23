// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Spheris360LiveStitch",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "Spheris360LiveStitchLib",
            path: "Sources/Spheris360LiveStitchLib",
            resources: [
                .process("GridShaders.metal"),
                .process("RemapCompute.metal"),
                .process("StitchShaders.metal"),
            ]
        ),
        .executableTarget(
            name: "Spheris360LiveStitch",
            dependencies: ["Spheris360LiveStitchLib"],
            path: "Sources/Spheris360LiveStitch"
        ),
    ]
)
