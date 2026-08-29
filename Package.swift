// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MirrorDeck",
    platforms: [.macOS(.v14)],
    targets: [
        // Exposes native/include/mirror_bridge.h to Swift; the implementation
        // is linked from native/build/libMirrorCore.a (built by native/build.sh).
        .target(
            name: "CMirrorBridge",
            path: "Sources/CMirrorBridge",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "MirrorDeck",
            dependencies: ["CMirrorBridge"],
            path: "Sources/MirrorDeck",
            linkerSettings: [
                .unsafeFlags(["-Lnative/build"]),
                .linkedLibrary("MirrorCore"),
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("QuartzCore"),
            ]
        ),
    ]
)
