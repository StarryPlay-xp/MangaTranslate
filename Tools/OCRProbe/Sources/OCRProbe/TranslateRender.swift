import CoreGraphics
import CoreText

/// 发给 DeepSeek 的图：每个文字块外围画红框，左上角外侧标编号，尽量不盖住原文
func renderMarked(image: CGImage, blocks: [TextBlock]) throws -> CGImage {
    let pageSize = CGSize(width: image.width, height: image.height)
    let context = try makeContext(width: image.width, height: image.height)
    context.draw(image, in: CGRect(origin: .zero, size: pageSize))

    let unit = max(1, pageSize.width / 600)
    let red = rgb(0.95, 0.1, 0.2)
    for block in blocks {
        let rect = block.box.rect.insetBy(dx: -unit * 4, dy: -unit * 4)
        context.setStrokeColor(red)
        context.setLineWidth(unit * 2.5)
        context.stroke(flipped(rect, pageHeight: pageSize.height))
        let radius = unit * 11
        drawBadge(
            "\(block.id)", at: CGPoint(x: rect.minX - radius * 0.4, y: rect.minY - radius * 0.4),
            color: red, radius: radius, in: context, pageSize: pageSize)
    }

    guard let result = context.makeImage() else { throw ProbeError("生成编号图失败") }
    return result
}

/// 模拟 App 里的显示效果：白底盖住原文，再把译文排进同一位置。
/// 字号上限优先用块自己的字号估计，没有时用整页的 characterSize
func renderTranslated(image: CGImage, blocks: [TranslatedBlock], characterSize: CGFloat) throws -> CGImage {
    let pageSize = CGSize(width: image.width, height: image.height)
    let context = try makeContext(width: image.width, height: image.height)
    context.draw(image, in: CGRect(origin: .zero, size: pageSize))

    let padding = max(4, characterSize * 0.25)
    for block in blocks where block.shouldOverlay {
        let rect = block.box.rect.insetBy(dx: -padding, dy: -padding)
        let shape = flipped(rect, pageHeight: pageSize.height)
        let corner = min(padding, shape.width / 2, shape.height / 2)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.addPath(CGPath(roundedRect: shape, cornerWidth: corner, cornerHeight: corner, transform: nil))
        context.fillPath()
        drawFittedText(
            block.translation, in: rect.insetBy(dx: padding / 2, dy: padding / 2),
            vertical: block.direction == .vertical,
            maxSize: max(block.characterSize.map { CGFloat($0) } ?? characterSize, 12),
            context: context, pageHeight: pageSize.height)
    }

    guard let result = context.makeImage() else { throw ProbeError("生成译文预览图失败") }
    return result
}

/// 在 rect 内用尽量大的字号排下全部文字（不超过原文字号），横排时上下居中
private func drawFittedText(
    _ text: String, in rect: CGRect, vertical: Bool, maxSize: CGFloat, context: CGContext, pageHeight: CGFloat
) {
    let frameAttributes = vertical ? verticalFrameAttributes() : nil
    let black = CGColor(gray: 0, alpha: 1)
    func framesetter(size: CGFloat) -> (CTFramesetter, Int) {
        let string = attributedText(
            text, fontName: "PingFangSC-Semibold", size: size, color: black, vertical: vertical, centered: true)
        return (CTFramesetterCreateWithAttributedString(string), string.length)
    }
    func fits(size: CGFloat) -> Bool {
        let (setter, length) = framesetter(size: size)
        let path = CGPath(rect: flipped(rect, pageHeight: pageHeight), transform: nil)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, frameAttributes)
        return CTFrameGetVisibleStringRange(frame).length == length
    }

    var low: CGFloat = 6
    var high = maxSize
    if fits(size: high) {
        low = high
    } else {
        for _ in 0..<10 {
            let middle = (low + high) / 2
            if fits(size: middle) { low = middle } else { high = middle }
        }
    }

    let (setter, _) = framesetter(size: low)
    var target = rect
    if !vertical {
        let needed = CTFramesetterSuggestFrameSizeWithConstraints(
            setter, CFRange(location: 0, length: 0), nil,
            CGSize(width: rect.width, height: .greatestFiniteMagnitude), nil)
        let height = min(rect.height, needed.height.rounded(.up) + 2)
        target = CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
    }
    let path = CGPath(rect: flipped(target, pageHeight: pageHeight), transform: nil)
    let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, frameAttributes)
    context.textMatrix = .identity
    CTFrameDraw(frame, context)
}
