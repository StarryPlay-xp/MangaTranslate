import CoreGraphics
import Foundation

/// 译文盖住原文时铺的底色。文字周围一圈是纯色（白气泡、黑底说明框、纯色块）时，
/// 用同样的颜色盖住、再配上看得清的字色，看起来就像直接把字换成了中文
public struct CoverColor: Codable, Sendable, Equatable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public var hex: String { String(format: "#%02x%02x%02x", red, green, blue) }

    /// 按人眼亮度判断：浅色底配黑字，深色底配白字
    public var isLight: Bool {
        0.299 * Double(red) + 0.587 * Double(green) + 0.114 * Double(blue) >= 140
    }

    public var textHex: String { isLight ? "#111111" : "#ffffff" }
}

public enum TextCover {
    /// 盖住原文时框向外扩的距离（原图像素），把原文的边缘也盖住
    public static func padding(characterSize: CGFloat) -> CGFloat { max(4, characterSize * 0.25) }
}

/// 一张图的像素，用来判断某块文字周围是不是纯色。图宽超过 maxWidth 时先缩小，
/// 网点、JPEG 噪点也会被平均掉一些
public struct PixelGrid: Sendable {
    let width: Int
    let height: Int
    /// 原图坐标乘以它得到网格坐标
    let scale: CGFloat
    /// RGBA，每像素 4 字节
    let pixels: [UInt8]

    /// 周围一圈至少要有这么多成的像素是同一种颜色
    static let uniformShare = 0.8
    /// 文字框里（字和字之间）至少要有这么多成的像素也是这个颜色：笔画最多占框里的一半左右
    static let innerShare = 0.4
    /// 每个通道和主色相差不超过这么多，算同一种颜色
    static let tolerance = 28

    public init?(image: CGImage, maxWidth: Int = 720) {
        guard image.width > 0, image.height > 0 else { return nil }
        let scale = min(1, CGFloat(maxWidth) / CGFloat(image.width))
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.width = width
        self.height = height
        self.scale = scale
        self.pixels = pixels
    }

    /// rect（原图坐标）外面 ring 宽的一圈里，八成以上的像素是同一种颜色，文字框里字和字之间也是这个颜色时，
    /// 返回这个颜色，也就是盖住原文时要铺的那块底色。周围是画面、网点，或者外圈压到了气泡外面时返回 nil
    public func uniformColor(around rect: CGRect, ring: CGFloat) -> CoverColor? {
        let inner = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
        let thickness = max(ring * scale, 2)
        let outer = inner.insetBy(dx: -thickness, dy: -thickness)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !outer.isNull, outer.width >= 1, outer.height >= 1 else { return nil }

        // 外圈像素：在外框里、不在文字框里
        var samples: [(Int, Int, Int)] = []
        let x0 = Int(outer.minX.rounded(.down)), x1 = Int(outer.maxX.rounded(.up))
        let y0 = Int(outer.minY.rounded(.down)), y1 = Int(outer.maxY.rounded(.up))
        // 像素太多时隔几个取一个，最多取几千个
        let area = (x1 - x0) * (y1 - y0)
        let step = max(1, Int((Double(area) / 6000).squareRoot()))
        for y in stride(from: max(y0, 0), to: min(y1, height), by: step) {
            for x in stride(from: max(x0, 0), to: min(x1, width), by: step) {
                let point = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                if inner.contains(point) { continue }
                let offset = (y * width + x) * 4
                samples.append((Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2])))
            }
        }
        guard samples.count >= 20 else { return nil }

        // 先按每通道 16 级粗分，找出最多的那一档，再看有多少像素和这一档的平均色接近
        var bins: [Int: (count: Int, r: Int, g: Int, b: Int)] = [:]
        for (r, g, b) in samples {
            let key = (r >> 4) << 8 | (g >> 4) << 4 | (b >> 4)
            let bin = bins[key] ?? (0, 0, 0, 0)
            bins[key] = (bin.count + 1, bin.r + r, bin.g + g, bin.b + b)
        }
        guard let top = bins.values.max(by: { $0.count < $1.count }) else { return nil }
        let mean = (top.r / top.count, top.g / top.count, top.b / top.count)
        var close = 0
        var sum = (0, 0, 0)
        for (r, g, b) in samples
        where abs(r - mean.0) <= Self.tolerance && abs(g - mean.1) <= Self.tolerance && abs(b - mean.2) <= Self.tolerance {
            close += 1
            sum = (sum.0 + r, sum.1 + g, sum.2 + b)
        }
        guard Double(close) >= Double(samples.count) * Self.uniformShare else { return nil }
        let color = (sum.0 / close, sum.1 / close, sum.2 / close)

        // 文字框里：气泡刚好只比字大一点时，外圈落在气泡外面，框里的底色和外圈对不上
        var innerCount = 0
        var innerClose = 0
        let innerStep = max(1, Int((Double(inner.width * inner.height) / 3000).squareRoot()))
        for y in stride(from: max(Int(inner.minY), 0), to: min(Int(inner.maxY.rounded(.up)), height), by: innerStep) {
            for x in stride(from: max(Int(inner.minX), 0), to: min(Int(inner.maxX.rounded(.up)), width), by: innerStep) {
                let offset = (y * width + x) * 4
                innerCount += 1
                if abs(Int(pixels[offset]) - color.0) <= Self.tolerance
                    && abs(Int(pixels[offset + 1]) - color.1) <= Self.tolerance
                    && abs(Int(pixels[offset + 2]) - color.2) <= Self.tolerance {
                    innerClose += 1
                }
            }
        }
        guard innerCount == 0 || Double(innerClose) >= Double(innerCount) * Self.innerShare else { return nil }
        return CoverColor(red: UInt8(color.0), green: UInt8(color.1), blue: UInt8(color.2))
    }
}

extension TranslatedBlock {
    /// 纯色底上的字不管是什么类型都用同色盖住，看起来像直接换了字；
    /// 只有画面上（周围不是纯色）的拟声词、标题贴小标签。画面上的对白、旁白仍然用白底盖住，保证看得清
    public func showsAsLabel(cover: CoverColor?) -> Bool { cover == nil && showsAsLabel }
}
