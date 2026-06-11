// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TranscribeBar",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TranscribeCore", targets: ["TranscribeCore"]),
        .executable(name: "transcribe-core", targets: ["transcribe-core"]),
        .executable(name: "TranscribeApp", targets: ["TranscribeApp"]),
    ],
    targets: [
        // Pure logic + AVFoundation segmenting + URLSession transcription. No UI.
        .target(name: "TranscribeCore"),
        // Headless CLI: `transcribe` (the §12 go/no-go gate) and `selftest` (merge tests).
        .executableTarget(name: "transcribe-core", dependencies: ["TranscribeCore"]),
        // The SwiftUI menu-bar app (packaged into Transcribe.app at §13.5).
        .executableTarget(name: "TranscribeApp", dependencies: ["TranscribeCore"]),
        // NOTE: deterministic merge tests live in TranscribeCore/Selftest.swift and run via
        // `swift run transcribe-core selftest` (no XCTest, so they work without full Xcode).
    ]
)
