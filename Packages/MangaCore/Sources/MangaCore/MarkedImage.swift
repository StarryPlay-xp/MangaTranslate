import CoreGraphics

/// 发给 DeepSeek 的图：每个文字块外围画红框，左上角外侧标编号，尽量不盖住原文
public func renderMarked(image: CGImage, blocks: [TextBlock]) throws -> CGImage {
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

    guard let result = context.makeImage() else { throw MangaCoreError("生成编号图失败") }
    return result
}
