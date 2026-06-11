// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SystemAudioRecorder",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "SystemAudioRecorder",
            path: "Sources/SystemAudioRecorder"
        )
    ]
)
