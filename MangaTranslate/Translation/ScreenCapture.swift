import CoreGraphics
import Foundation
import MangaCore

/// 一屏截图的识别结果，以及要发给模型的编号图
nonisolated struct CapturedPage: Sendable {
    var blocks: [TextBlock]
    var markedJPEG: Data
    var imageSize: CGSize
    var characterSize: CGFloat
}

enum ScreenCapture {
    /// 识别文字和画编号图比较耗时，放到后台执行，避免卡住界面
    @concurrent
    nonisolated static func prepare(image: sending CGImage, language: SourceLanguage) async throws -> CapturedPage {
        let (analysis, blocks) = try await detectTextBlocks(in: image, language: language)
        return CapturedPage(
            blocks: blocks,
            markedJPEG: try MarkedImage.encode(renderMarked(image: image, blocks: blocks)),
            imageSize: CGSize(width: image.width, height: image.height),
            characterSize: analysis.characterSize)
    }
}
