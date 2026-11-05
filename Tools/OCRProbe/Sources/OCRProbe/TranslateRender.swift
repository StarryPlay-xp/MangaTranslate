import CoreGraphics
import CoreText
import MangaCore

/// 模拟 App 里的显示效果：对白、旁白用白底盖住原文，再把译文排进同一位置；
/// 拟声词、标题这类大字在原文左上角贴半透明小标签，不盖住原文。
/// 字号上限优先用块自己的字号估计，没有时用整页的 characterSize
func renderTranslated(image: CGImage, blocks: [TranslatedBlock], characterSize: CGFloat) throws -> CGImage {
    let pageSize = CGSize(width: image.width, height: image.height)
    let context = try makeContext(width: image.width, height: image.height)
    context.draw(image, in: CGRect(origin: .zero, size: pageSize))

    let padding = max(4, characterSize * 0.25)
    for block in blocks where block.shouldOverlay {
        if block.showsAsLabel(imageWidth: pageSize.width, fallbackCharacterSize: characterSize) {
            drawLabel(block, characterSize: characterSize, pageSize: pageSize, context: context)
            continue
        }
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

/// 小标签：和 App 一样，字号不超过页宽的 3.2%，最宽为原文宽度和页宽 35% 里较大的那个，超出页面时往回挪
private func drawLabel(_ block: TranslatedBlock, characterSize: CGFloat, pageSize: CGSize, context: CGContext) {
    let original = block.box.rect
    let fontSize = max(min(block.characterSize.map { CGFloat($0) } ?? characterSize, pageSize.width * 0.032), 12)
    let maxWidth = min(max(original.width, pageSize.width * 0.35), pageSize.width * 0.9)
    let string = attributedText(
        block.translation, fontName: "PingFangSC-Semibold", size: fontSize, color: CGColor(gray: 0.07, alpha: 1),
        vertical: false, centered: false)
    let setter = CTFramesetterCreateWithAttributedString(string)
    let inset = CGSize(width: fontSize * 0.4, height: fontSize * 0.1)
    let textSize = CTFramesetterSuggestFrameSizeWithConstraints(
        setter, CFRange(location: 0, length: 0), nil,
        CGSize(width: maxWidth - inset.width * 2, height: .greatestFiniteMagnitude), nil)
    let width = textSize.width.rounded(.up) + inset.width * 2 + 2
    let height = textSize.height.rounded(.up) + inset.height * 2 + 2
    let x = max(0, min(original.minX, pageSize.width - width))
    let y = max(0, min(original.minY, pageSize.height - height))
    let rect = CGRect(x: x, y: y, width: width, height: height)

    let shape = flipped(rect, pageHeight: pageSize.height)
    let corner = min(fontSize * 0.35, shape.height / 2)
    let path = CGPath(roundedRect: shape, cornerWidth: corner, cornerHeight: corner, transform: nil)
    context.setFillColor(CGColor(gray: 1, alpha: 0.82))
    context.addPath(path)
    context.fillPath()
    context.setStrokeColor(CGColor(gray: 0, alpha: 0.18))
    context.setLineWidth(1)
    context.addPath(path)
    context.strokePath()

    let textRect = rect.insetBy(dx: inset.width, dy: inset.height)
    let frame = CTFramesetterCreateFrame(
        setter, CFRange(location: 0, length: 0), CGPath(rect: flipped(textRect, pageHeight: pageSize.height), transform: nil),
        nil)
    context.textMatrix = .identity
    CTFrameDraw(frame, context)
}
