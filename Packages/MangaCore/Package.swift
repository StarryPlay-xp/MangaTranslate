// swift-tools-version: 6.0
import PackageDescription

// App 和 OCRProbe 共用的核心逻辑：文字识别、文字块合并、长图切段、编号图、大模型翻译
let package = Package(
    name: "MangaCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "MangaCore", targets: ["MangaCore"]),
    ],
    targets: [
        .target(name: "MangaCore"),
        .testTarget(name: "MangaCoreTests", dependencies: ["MangaCore"]),
    ]
)
