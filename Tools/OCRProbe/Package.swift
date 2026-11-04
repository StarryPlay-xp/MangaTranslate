// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OCRProbe",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../../Packages/MangaCore"),
    ],
    targets: [
        .executableTarget(
            name: "ocrprobe",
            dependencies: [.product(name: "MangaCore", package: "MangaCore")],
            path: "Sources/OCRProbe"),
    ]
)
