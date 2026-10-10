// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ulular",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "ulular", targets: ["Ulular"])],
    targets: [
        .target(name: "AudioRealtime", linkerSettings: [.linkedFramework("CoreAudio")]),
        .target(name: "AppSettings"),
        .executableTarget(name: "Ulular", dependencies: ["AudioRealtime", "AppSettings"]),
        .testTarget(name: "AudioRealtimeTests", dependencies: ["AudioRealtime"]),
        .testTarget(name: "AppSettingsTests", dependencies: ["AppSettings"])
    ]
)
