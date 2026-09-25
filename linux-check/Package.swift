// swift-tools-version:5.9
import PackageDescription

// Offline check harness. Compiles the app's platform-independent sources on
// Linux against minimal stand-ins for the Apple frameworks, so concurrency and
// type errors surface here in seconds instead of in a cloud build. It proves
// nothing about the real SDK's behaviour — only that the code type-checks and
// that the pure logic (wire format, pre-roll, tail, token expiry) is correct.
// Run with ./run.sh, which copies the sources in.
let package = Package(
    name: "BeautyRadioLinuxCheck",
    targets: [
        .target(name: "AVFoundation", path: "Stubs/AVFoundation"),
        .target(name: "PushToTalk", dependencies: ["AVFoundation"], path: "Stubs/PushToTalk"),
        .target(name: "Security", path: "Stubs/Security"),
        .target(name: "Combine", path: "Stubs/Combine"),
        .target(
            name: "BeautyRadio",
            dependencies: ["AVFoundation", "PushToTalk", "Security", "Combine"],
            path: "Sources/BeautyRadio",
            swiftSettings: [.unsafeFlags(["-swift-version", "6"])]
        ),
        .testTarget(name: "BeautyRadioLinuxTests", dependencies: ["BeautyRadio"], path: "Tests/BeautyRadioLinuxTests")
    ]
)
