import CoreGraphics
import Foundation
import MangaCore

struct PageResult: Codable, Sendable {
    /// 相对输入目录的路径
    var file: String
    var languages: [String]
    var readingOrder: ReadingOrder
    var width: Int
    var height: Int
    var elapsedMs: Int
    var regionCount: Int
    var lineCount: Int
    /// 估计的单字边长（像素），合并和过滤文字块都以它为单位
    var characterSize: Int
    var blocks: [TextBlock]
    /// 标注图，相对输出目录的路径
    var annotatedImage: String
}

func runProbe(_ options: RunOptions) async throws {
    let files = try findImages(in: options.input)
    guard !files.isEmpty else {
        throw ProbeError("在 \(options.input.path) 里没有找到图片（支持 png、jpg、jpeg、heic、webp）")
    }

    var pages: [PageResult] = []
    for (index, relativePath) in files.enumerated() {
        print("[\(index + 1)/\(files.count)] \(relativePath)")
        let image = try loadImage(at: options.input.appendingPathComponent(relativePath))
        let (languages, order) = profile(for: relativePath, override: options.languages)

        let clock = ContinuousClock()
        let start = clock.now
        let analysis = try await analyzeText(in: image, languages: languages)
        let blocks = groupIntoBlocks(analysis, gapFactor: options.gapFactor, order: order)
        let elapsed = start.duration(to: clock.now)

        let annotatedPath = "annotated/" + relativePath.replacingOccurrences(of: "/", with: "__") + ".jpg"
        let annotated = try renderAnnotated(image: image, analysis: analysis, blocks: blocks)
        try writeImage(annotated, to: options.output.appendingPathComponent(annotatedPath), format: .jpeg)

        pages.append(PageResult(
            file: relativePath,
            languages: languages,
            readingOrder: order,
            width: image.width,
            height: image.height,
            elapsedMs: Int((elapsed / .milliseconds(1)).rounded()),
            regionCount: analysis.regions.count,
            lineCount: analysis.lines.count,
            characterSize: Int(analysis.characterSize.rounded()),
            blocks: blocks,
            annotatedImage: annotatedPath))
    }

    try writeReport(pages, to: options.output)
    print("完成：共 \(pages.count) 页。报告在 \(options.output.appendingPathComponent("report.html").path)")
}

/// 递归找出目录下的图片，返回相对路径
private func findImages(in directory: URL) throws -> [String] {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue,
          let enumerator = FileManager.default.enumerator(
              at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    else {
        throw ProbeError("找不到目录 \(directory.path)")
    }
    let extensions: Set<String> = ["png", "jpg", "jpeg", "heic", "webp"]
    let basePath = directory.resolvingSymlinksInPath().path
    var result: [String] = []
    for case let url as URL in enumerator where extensions.contains(url.pathExtension.lowercased()) {
        result.append(String(url.resolvingSymlinksInPath().path.dropFirst(basePath.count + 1)))
    }
    return result.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
}

/// 按第一级子目录名决定识别语言和阅读顺序：ko 开头按韩漫处理，其余按日漫处理
private func profile(for relativePath: String, override: [String]?) -> (languages: [String], order: ReadingOrder) {
    let components = relativePath.split(separator: "/")
    let isKorean = components.count > 1 && components[0].lowercased().hasPrefix("ko")
    let languages = override ?? (isKorean ? ["ko-KR"] : ["ja-JP"])
    return (languages, isKorean ? .leftToRight : .rightToLeft)
}
