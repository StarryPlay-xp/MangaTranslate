import CoreGraphics
import Foundation

/// 一屏截图的识别结果，以及要发给模型的编号图
public struct CapturedPage: Sendable {
    public var blocks: [TextBlock]
    public var markedJPEG: Data
    public var imageSize: CGSize
    public var characterSize: CGFloat
    /// 文字块编号 → 周围的纯色底色
    public var covers: [Int: CoverColor]
}

public enum ScreenCapture {
    /// 识别整张截图并画编号图（不切段）。不绑定主线程，App 调用时在后台执行
    public static func prepare(image: sending CGImage, language: SourceLanguage) async throws -> CapturedPage {
        let (analysis, blocks) = try await detectTextBlocks(in: image, language: language)
        return CapturedPage(
            blocks: blocks,
            markedJPEG: try MarkedImage.encode(renderMarked(image: image, blocks: blocks)),
            imageSize: CGSize(width: image.width, height: image.height),
            characterSize: analysis.characterSize,
            covers: ImagePipeline.coverColors(of: blocks, in: image, characterSize: analysis.characterSize))
    }
}

/// 网页可视区域在文档中的位置，单位是 CSS 像素
public struct Viewport: Codable, Sendable, Equatable {
    public var left: Double
    public var top: Double
    public var width: Double
    public var height: Double
    /// 版面宽度：iPad 转屏、调整窗口时会变，双指缩放不变
    public var layoutWidth: Double

    public init(left: Double, top: Double, width: Double, height: Double, layoutWidth: Double) {
        self.left = left
        self.top = top
        self.width = width
        self.height = height
        self.layoutWidth = layoutWidth
    }
}

/// "只翻译这一屏"贴到网页上的一处译文，坐标已换算成文档坐标
public struct OverlayItem: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var text: String
    public var vertical: Bool
    public var fontSize: Double
    /// 拟声词、标题这类大字：半透明小标签，不盖住原文
    public var label: Bool
    /// 盖住原文时铺的底色和字色（周围是纯色时取那个颜色）；没有时用白底黑字
    public var background: String?
    public var textColor: String?

    /// 小标签的字号上限（÷ 图片宽度）：字号本身跟这一页的对白一样，这里只防止整页都是大字时标签太大
    public static let labelFontRatio = 0.05
    /// 小标签的最小字号（CSS 像素），手机上看得清
    public static let labelMinFont = 13

    /// 把截图上的像素坐标换算到网页文档坐标；框向外扩一点，盖住原文的边缘
    public static func items(
        for blocks: [TranslatedBlock], imageSize: CGSize, characterSize: CGFloat, covers: [Int: CoverColor],
        viewport: Viewport
    ) -> [OverlayItem] {
        let scaleX = viewport.width / imageSize.width
        let scaleY = viewport.height / imageSize.height
        let padding = TextCover.padding(characterSize: characterSize)
        return blocks.filter(\.shouldOverlay).map { block in
            let rect = block.box.rect.insetBy(dx: -padding, dy: -padding)
            let fontSize = block.characterSize.map { CGFloat($0) } ?? characterSize
            let cover = covers[block.id]
            let label = block.showsAsLabel(cover: cover)
            let size = label ? min(fontSize, characterSize, imageSize.width * labelFontRatio) : fontSize
            return OverlayItem(
                x: viewport.left + rect.minX * scaleX,
                y: viewport.top + rect.minY * scaleY,
                width: rect.width * scaleX,
                height: rect.height * scaleY,
                text: block.translation,
                vertical: block.direction == .vertical,
                fontSize: max(size * scaleX, label ? CGFloat(labelMinFont) : 10),
                label: label, background: label ? nil : cover?.hex, textColor: label ? nil : cover?.textHex)
        }
    }
}
