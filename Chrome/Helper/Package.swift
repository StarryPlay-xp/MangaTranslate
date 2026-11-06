// swift-tools-version: 6.0
import PackageDescription

// 漫译 Chrome 插件的 Mac 小助手：由 Chrome 通过 Native Messaging 启动，
// 用 MangaCore 识别图片文字、调用模型翻译，把译文交回插件
let package = Package(
    name: "MangaHelper",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "manga-translate-helper", targets: ["MangaHelper"]),
    ],
    dependencies: [
        .package(path: "../../Packages/MangaCore"),
    ],
    targets: [
        .target(name: "HelperCore", dependencies: [.product(name: "MangaCore", package: "MangaCore")]),
        .executableTarget(name: "MangaHelper", dependencies: ["HelperCore"]),
        .testTarget(name: "HelperCoreTests", dependencies: ["HelperCore"]),
    ]
)
