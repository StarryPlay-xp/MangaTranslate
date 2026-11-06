import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

/// 一张图里需要翻译的一段（短图就是整张图）
public struct PreparedSegment: Sendable {
    /// 这一段在原图中的位置
    public var rect: CGRect
    /// 段内坐标
    public var blocks: [TextBlock]
    /// 发给模型的编号图
    public var markedJPEG: Data
    public var characterSize: CGFloat
    /// 文字块编号 → 周围的纯色底色；周围是画面的块没有
    public var covers: [Int: CoverColor]

    public init(
        rect: CGRect, blocks: [TextBlock], markedJPEG: Data, characterSize: CGFloat, covers: [Int: CoverColor] = [:]
    ) {
        self.rect = rect
        self.blocks = blocks
        self.markedJPEG = markedJPEG
        self.characterSize = characterSize
        self.covers = covers
    }
}

/// 逐段处理一张图：识别完一段就可以先交给模型，不用等整张长图都识别完。
/// 这里的函数都不绑定主线程，App（默认主线程）调用时会在后台执行
public enum ImagePipeline {
    /// 解码下载到的图片（多帧图只取第一帧）
    public static func decode(_ data: Data) async throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw MangaCoreError("无法解码图片")
        }
        return image
    }

    /// 识别第 index 段并画出编号图；这一段里没有归它处理的文字时返回 nil
    public static func prepareSegment(
        _ index: Int, of rects: [CGRect], in image: CGImage, language: SourceLanguage
    ) async throws -> PreparedSegment? {
        let rect = rects[index]
        guard let crop = image.cropping(to: rect) else { return nil }
        let (analysis, blocks) = try await detectTextBlocks(in: crop, language: language)
        let owned = Segmenting.ownedBlocks(blocks, segmentIndex: index, in: rects)
        guard !owned.isEmpty else { return nil }
        return PreparedSegment(
            rect: rect, blocks: owned, markedJPEG: try MarkedImage.encode(renderMarked(image: crop, blocks: owned)),
            characterSize: analysis.characterSize,
            covers: coverColors(of: owned, in: crop, characterSize: analysis.characterSize))
    }

    /// 每个文字块周围是不是纯色（白气泡、黑底说明框）：是的话盖住时铺同样的颜色
    public static func coverColors(of blocks: [TextBlock], in image: CGImage, characterSize: CGFloat)
        -> [Int: CoverColor]
    {
        guard let grid = PixelGrid(image: image) else { return [:] }
        let ring = TextCover.padding(characterSize: characterSize)
        var covers: [Int: CoverColor] = [:]
        for block in blocks {
            covers[block.id] = grid.uniformColor(around: block.box.rect, ring: ring)
        }
        return covers
    }

    /// 截图内容的指纹，用作缓存键：canvas 画的页面没有图片地址，同样的画面算出同样的值。
    /// 重新画到一块自己的位图里再算，裁剪出来的 CGImage 可能还连着整张截图的数据
    public static func contentFingerprint(of image: CGImage) async -> String {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            return UUID().uuidString
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pixels = context.data else { return UUID().uuidString }
        let digest = SHA256.hash(data: UnsafeRawBufferPointer(start: pixels, count: context.bytesPerRow * height))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// 贴在一张图片上的一处译文。坐标和字号都是相对图片原始尺寸的比例，图片显示大小变了也能对齐
public struct ImageOverlayItem: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var text: String
    public var vertical: Bool
    /// 字号 ÷ 图片原始宽度
    public var fontScale: Double
    /// 拟声词、标题这类大字：贴一个不挡画面的半透明小标签，不盖住原文。旧缓存里没有这个字段
    public var label: Bool?
    /// 盖住原文时铺的底色和字色（周围是纯色时取那个颜色）；没有时用白底黑字
    public var background: String?
    public var textColor: String?

    public init(
        x: Double, y: Double, width: Double, height: Double, text: String, vertical: Bool, fontScale: Double,
        label: Bool? = nil, background: String? = nil, textColor: String? = nil
    ) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.text = text
        self.vertical = vertical
        self.fontScale = fontScale
        self.label = label
        self.background = background
        self.textColor = textColor
    }

    public static func items(
        for blocks: [TranslatedBlock], in segment: PreparedSegment, imageWidth: Int, imageHeight: Int
    ) -> [ImageOverlayItem] {
        let width = Double(imageWidth)
        let height = Double(imageHeight)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let padding = TextCover.padding(characterSize: segment.characterSize)
        return blocks.filter(\.shouldOverlay).map { block in
            // 框向外扩一点，盖住原文的边缘；再从段内坐标换算回整张图
            let rect = block.box.rect
                .insetBy(dx: -padding, dy: -padding)
                .offsetBy(dx: segment.rect.minX, dy: segment.rect.minY)
                .intersection(bounds)
            let fontSize = block.characterSize.map { CGFloat($0) } ?? segment.characterSize
            // 小标签和这一段的对白一样大（整段字号多半就是对白的字号），原文更小时跟着原文
            let cover = segment.covers[block.id]
            let label = block.showsAsLabel(cover: cover)
            return ImageOverlayItem(
                x: rect.minX / width, y: rect.minY / height,
                width: rect.width / width, height: rect.height / height,
                text: block.translation, vertical: block.direction == .vertical,
                fontScale: (label ? min(fontSize, segment.characterSize) : fontSize) / width,
                label: label, background: label ? nil : cover?.hex, textColor: label ? nil : cover?.textHex)
        }
    }
}
