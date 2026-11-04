// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OCRProbe",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "ocrprobe", path: "Sources/OCRProbe"),
    ]
)
