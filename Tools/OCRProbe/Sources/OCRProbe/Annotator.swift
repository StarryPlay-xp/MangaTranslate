import CoreGraphics
import MangaCore

/// 在原图上画出识别结果：橙框为检测到的文字区域，蓝框为识别出文字的行，
/// 绿框加编号为合并后的文字块，红框加编号为没认出字的文字块
func renderAnnotated(image: CGImage, analysis: TextAnalysis, blocks: [TextBlock]) throws -> CGImage {
    let pageSize = CGSize(width: image.width, height: image.height)
    let context = try makeContext(width: image.width, height: image.height)
    context.draw(image, in: CGRect(origin: .zero, size: pageSize))

    // 线宽和编号大小随图片宽度缩放
    let unit = max(1, pageSize.width / 600)
    func stroke(_ rect: CGRect, _ color: CGColor, _ lineWidth: CGFloat) {
        context.setStrokeColor(color)
        context.setLineWidth(lineWidth)
        context.stroke(flipped(rect, pageHeight: pageSize.height))
    }

    for region in analysis.regions {
        stroke(region, rgb(1, 0.55, 0), unit)
    }
    for line in analysis.lines {
        stroke(line.box.rect, rgb(0.1, 0.4, 1), unit * 1.5)
    }
    for block in blocks {
        let color = block.text.isEmpty ? rgb(0.9, 0.1, 0.1) : rgb(0, 0.7, 0.3)
        stroke(block.box.rect.insetBy(dx: -unit * 3, dy: -unit * 3), color, unit * 3)
        drawBadge(
            "\(block.id)", at: CGPoint(x: block.box.rect.maxX, y: block.box.rect.minY),
            color: color, radius: unit * 12, in: context, pageSize: pageSize)
    }

    guard let result = context.makeImage() else { throw ProbeError("生成标注图失败") }
    return result
}
