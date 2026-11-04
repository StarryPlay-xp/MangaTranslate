import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// 工具内部统一用左上角为原点的像素坐标；CoreGraphics 画布以左下角为原点，绘制前用 flipped 转换。

enum ImageFormat {
    case png, jpeg

    var typeIdentifier: CFString {
        switch self {
        case .png: UTType.png.identifier as CFString
        case .jpeg: UTType.jpeg.identifier as CFString
        }
    }
}

func loadImage(at url: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
        throw ProbeError("无法读取图片 \(url.lastPathComponent)")
    }
    return image
}

func encodeImage(_ image: CGImage, format: ImageFormat) throws -> Data {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, format.typeIdentifier, 1, nil) else {
        throw ProbeError("无法编码图片")
    }
    let options = [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary
    CGImageDestinationAddImage(destination, image, options)
    guard CGImageDestinationFinalize(destination) else { throw ProbeError("无法编码图片") }
    return data as Data
}

func writeImage(_ image: CGImage, to url: URL, format: ImageFormat) throws {
    try writeFile(encodeImage(image, format: format), to: url)
}

func writeFile(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}

func makeContext(width: Int, height: Int) throws -> CGContext {
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
              data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
              space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else {
        throw ProbeError("无法创建 \(width)×\(height) 的画布")
    }
    return context
}

func flipped(_ rect: CGRect, pageHeight: CGFloat) -> CGRect {
    CGRect(x: rect.minX, y: pageHeight - rect.maxY, width: rect.width, height: rect.height)
}

func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CGColor {
    CGColor(srgbRed: red, green: green, blue: blue, alpha: 1)
}

func attributedText(
    _ text: String, fontName: String, size: CGFloat, color: CGColor, vertical: Bool = false, centered: Bool = false
) -> NSAttributedString {
    var attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(fontName as CFString, size, nil),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ]
    if vertical {
        attributes[NSAttributedString.Key(kCTVerticalFormsAttributeName as String)] = true
    }
    if centered {
        var alignment = CTTextAlignment.center
        let style = withUnsafeBytes(of: &alignment) { buffer in
            var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: buffer.count, value: buffer.baseAddress!)
            return CTParagraphStyleCreate(&setting, 1)
        }
        attributes[NSAttributedString.Key(kCTParagraphStyleAttributeName as String)] = style
    }
    return NSAttributedString(string: text, attributes: attributes)
}

/// 竖排文字的排版属性：列从右往左排
func verticalFrameAttributes() -> CFDictionary {
    [kCTFrameProgressionAttributeName as String: CTFrameProgression.rightToLeft.rawValue] as CFDictionary
}

/// 画一个带编号的圆点，超出图片边缘时往里挪；point 为左上角原点坐标
func drawBadge(
    _ text: String, at point: CGPoint, color: CGColor, radius: CGFloat, in context: CGContext, pageSize: CGSize
) {
    let x = min(max(point.x, radius), pageSize.width - radius)
    let y = pageSize.height - min(max(point.y, radius), pageSize.height - radius)
    context.setFillColor(color)
    context.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))

    let line = CTLineCreateWithAttributedString(
        attributedText(text, fontName: "Helvetica-Bold", size: radius * 1.1, color: CGColor(gray: 1, alpha: 1)))
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    context.textMatrix = .identity
    context.textPosition = CGPoint(x: x - bounds.width / 2 - bounds.minX, y: y - bounds.height / 2 - bounds.minY)
    CTLineDraw(line, context)
}
