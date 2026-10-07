// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MusicTask",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "MusicTask", targets: ["MusicTask"])],
    targets: [
        .target(name: "AudioRealtime", linkerSettings: [.linkedFramework("CoreAudio")]),
        .target(name: "AppSettings"),
        .executableTarget(name: "MusicTask", dependencies: ["AudioRealtime", "AppSettings"]),
        .testTarget(name: "AudioRealtimeTests", dependencies: ["AudioRealtime"]),
        .testTarget(name: "AppSettingsTests", dependencies: ["AppSettings"])
    ]
)
