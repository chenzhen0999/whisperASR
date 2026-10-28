// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "WhisperASR",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Lightweight, pure-Swift HTTP server (no transitive deps) used to expose
        // the local OpenAI-compatible transcription API.
        .package(url: "https://github.com/swhitty/FlyingFox.git", from: "0.26.0"),
        // Core ML / ANE runtime for NVIDIA Nemotron streaming ASR models.
        // Vendored FluidAudio 0.17.7 (commit 503b4bd1) with WhisperASR patches:
        // dtype/stride-aware logits argmax (fixes vDSP_maxvi crash) + blank-rescue guard.
        // See Vendor/FluidAudio/WHISPERASR_PATCHES.md.
        .package(path: "Vendor/FluidAudio", traits: []),
        // Open-source Pyannote community-1 diarization from Argmax.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.1"),
    ],
    targets: [
        .binaryTarget(
            name: "CWhisper",
            path: "Frameworks/CWhisper.xcframework"
        ),
        .executableTarget(
            name: "WhisperASR",
            dependencies: [
                "CWhisper",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "SpeakerKit", package: "argmax-oss-swift"),
                .product(name: "FlyingFox", package: "FlyingFox"),
                .product(name: "FlyingSocks", package: "FlyingFox"),
            ],
            path: "Sources",
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Foundation"),
                .linkedLibrary("c++"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("WebKit"),
            ]
        ),
        .testTarget(
            name: "WhisperASRTests",
            dependencies: ["WhisperASR"],
            path: "Tests/WhisperASRTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
