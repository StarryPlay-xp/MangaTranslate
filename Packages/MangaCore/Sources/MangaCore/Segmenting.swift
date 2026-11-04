import CoreGraphics

/// 长条图（韩漫条漫常见）的切段规则。整张图直接交给模型会被压缩得太小，字看不清，所以切成几段分别处理。
public enum Segmenting {
    /// 高度不超过宽度的 2 倍时不切
    public static let maxSingleAspect: CGFloat = 2.0
    /// 每段高度约为宽度的 1.5 倍
    public static let segmentAspect: CGFloat = 1.5
    /// 相邻两段重叠 0.4 倍宽度，保证不太高的气泡至少完整出现在其中一段里
    public static let overlapAspect: CGFloat = 0.4

    /// 返回各段在原图中的位置（像素，左上角原点），从上到下排列
    public static func segmentRects(width: Int, height: Int) -> [CGRect] {
        let w = CGFloat(width)
        let h = CGFloat(height)
        guard w > 0, h > w * maxSingleAspect else {
            return [CGRect(x: 0, y: 0, width: w, height: h)]
        }
        let segmentHeight = (w * segmentAspect).rounded()
        let step = segmentHeight - (w * overlapAspect).rounded()
        var rects: [CGRect] = []
        var top: CGFloat = 0
        while true {
            if top + segmentHeight >= h {
                // 最后一段贴着底边，往上多取一些，避免切出很矮的一段
                let lastTop = max(0, h - segmentHeight)
                rects.append(CGRect(x: 0, y: lastTop, width: w, height: h - lastTop))
                break
            }
            rects.append(CGRect(x: 0, y: top, width: w, height: segmentHeight))
            top += step
        }
        return rects
    }

    /// 从第 index 段识别出的文字块里，挑出归这一段处理的块，并按顺序重新编号。
    /// - 碰到上下切口的块是被切断的，丢掉，由相邻段完整处理
    /// - 完整落在重叠区里的块两段都有，按中心点归属：重叠区上半归上一段，下半归下一段
    public static func ownedBlocks(_ blocks: [TextBlock], segmentIndex index: Int, in rects: [CGRect]) -> [TextBlock] {
        let rect = rects[index]
        let isFirst = index == 0
        let isLast = index == rects.count - 1
        let ownedTop: CGFloat = isFirst ? 0 : (rects[index - 1].maxY + rect.minY) / 2 - rect.minY
        let ownedBottom: CGFloat = isLast ? rect.height : (rect.maxY + rects[index + 1].minY) / 2 - rect.minY
        let edgeTolerance: CGFloat = 2

        let kept = blocks.filter { block in
            let box = block.box.rect
            if !isFirst && box.minY <= edgeTolerance { return false }
            if !isLast && box.maxY >= rect.height - edgeTolerance { return false }
            return box.midY >= ownedTop && box.midY < ownedBottom
        }
        return kept.enumerated().map { position, block in
            var renumbered = block
            renumbered.id = position + 1
            return renumbered
        }
    }
}

/// 把图片等比缩小到不超过 maxPixelCount 个像素；本来就够小时原样返回
public func scaledToFit(_ image: CGImage, maxPixelCount: Int) throws -> CGImage {
    let pixels = image.width * image.height
    guard pixels > maxPixelCount else { return image }
    let scale = (Double(maxPixelCount) / Double(pixels)).squareRoot()
    let width = max(1, Int(Double(image.width) * scale))
    let height = max(1, Int(Double(image.height) * scale))
    let context = try makeContext(width: width, height: height)
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let result = context.makeImage() else { throw MangaCoreError("缩小图片失败") }
    return result
}
