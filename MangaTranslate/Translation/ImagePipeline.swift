import CoreGraphics
import Foundation
import ImageIO
import MangaCore

/// 一张图里需要翻译的一段（短图就是整张图）
nonisolated struct PreparedSegment: Sendable {
    /// 这一段在原图中的位置
    var rect: CGRect
    /// 段内坐标
    var blocks: [TextBlock]
    /// 发给模型的编号图
    var markedJPEG: Data
    var characterSize: CGFloat
}

nonisolated struct PreparedImage: Sendable {
    var width: Int
    var height: Int
    /// 只包含有文字的段
    var segments: [PreparedSegment]
}

enum ImagePipeline {
    /// 编号图最多 200 万像素：DeepSeek 等模型本来就会缩到约 1300×1300，再大只是浪费流量
    nonisolated static let maxMarkedPixels = 2_000_000

    /// 解码、切段、识别、画编号图都在后台执行
    @concurrent
    nonisolated static func prepare(imageData: Data, language: SourceLanguage) async throws -> PreparedImage {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw MangaCoreError("无法解码图片")
        }
        let rects = Segmenting.segmentRects(width: image.width, height: image.height)
        var segments: [PreparedSegment] = []
        for (index, rect) in rects.enumerated() {
            guard let crop = image.cropping(to: rect) else { continue }
            let (analysis, blocks) = try await detectTextBlocks(in: crop, language: language)
            let owned = Segmenting.ownedBlocks(blocks, segmentIndex: index, in: rects)
            guard !owned.isEmpty else { continue }
            let marked = try scaledToFit(renderMarked(image: crop, blocks: owned), maxPixelCount: maxMarkedPixels)
            segments.append(PreparedSegment(
                rect: rect, blocks: owned, markedJPEG: try encodeImage(marked, format: .jpeg),
                characterSize: analysis.characterSize))
        }
        return PreparedImage(width: image.width, height: image.height, segments: segments)
    }
}

/// 贴在一张图片上的一处译文。坐标和字号都是相对图片原始尺寸的比例，图片显示大小变了也能对齐
nonisolated struct ImageOverlayItem: Codable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var text: String
    var vertical: Bool
    /// 字号 ÷ 图片原始宽度
    var fontScale: Double

    static func items(for blocks: [TranslatedBlock], in segment: PreparedSegment, imageWidth: Int, imageHeight: Int)
        -> [ImageOverlayItem]
    {
        let width = Double(imageWidth)
        let height = Double(imageHeight)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let padding = max(4, segment.characterSize * 0.25)
        return blocks.filter(\.shouldOverlay).map { block in
            // 框向外扩一点，盖住原文的边缘；再从段内坐标换算回整张图
            let rect = block.box.rect
                .insetBy(dx: -padding, dy: -padding)
                .offsetBy(dx: segment.rect.minX, dy: segment.rect.minY)
                .intersection(bounds)
            let fontSize = block.characterSize.map { CGFloat($0) } ?? segment.characterSize
            return ImageOverlayItem(
                x: rect.minX / width, y: rect.minY / height,
                width: rect.width / width, height: rect.height / height,
                text: block.translation, vertical: block.direction == .vertical,
                fontScale: fontSize / width)
        }
    }
}
