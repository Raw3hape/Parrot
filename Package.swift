// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Parrot",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "0.18.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.3"),
        // Vendored SpeexDSP for acoustic echo cancellation. Kept in sync with
        // project.yml (the xcodegen source of truth) so `swift build` works too.
        .package(path: "Vendor/CSpeexDSP"),
    ],
    targets: [
        .executableTarget(
            name: "Parrot",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "CSpeexDSP", package: "CSpeexDSP"),
            ],
            path: "Parrot",
            exclude: [
                "Assets.xcassets",
                "Info.plist",
                "Parrot.entitlements",
                "QwenHelper.entitlements",
            ],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "ParrotTests",
            dependencies: ["Parrot"],
            path: "Tests/ParrotTests"
        ),
    ]
)
