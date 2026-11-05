import CoreGraphics
import Foundation
import Testing
@testable import MangaCore

struct CoverColorTests {
    /// 画一张测试图：draw 里的坐标原点在左上角，和识别框一致
    private func image(width: Int = 400, height: Int = 400, _ draw: (CGContext) -> Void) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        draw(context)
        return context.makeImage()!
    }

    private func fill(_ context: CGContext, _ rect: CGRect, gray: CGFloat) {
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(rect)
    }

    /// 文字框里画几道黑色笔画
    private func strokes(_ context: CGContext, in rect: CGRect, gray: CGFloat = 0) {
        for index in 0..<4 {
            fill(context, CGRect(x: rect.minX + CGFloat(index) * rect.width / 4, y: rect.minY, width: 6, height: rect.height), gray: gray)
        }
    }

    @Test func 白气泡里的字_底色是白色配黑字() throws {
        let text = CGRect(x: 120, y: 60, width: 160, height: 60)
        let picture = image { context in
            fill(context, CGRect(x: 0, y: 0, width: 400, height: 400), gray: 0.2)
            fill(context, CGRect(x: 80, y: 30, width: 240, height: 120), gray: 1)
            strokes(context, in: text)
        }
        let color = try #require(PixelGrid(image: picture)?.uniformColor(around: text, ring: 10))
        #expect(color.hex == "#ffffff")
        #expect(color.textHex == "#111111")
    }

    @Test func 黑底说明框里的白字_底色是黑色配白字() throws {
        let text = CGRect(x: 120, y: 260, width: 160, height: 60)
        let picture = image { context in
            fill(context, CGRect(x: 0, y: 0, width: 400, height: 400), gray: 1)
            fill(context, CGRect(x: 80, y: 230, width: 240, height: 120), gray: 0)
            strokes(context, in: text, gray: 1)
        }
        let color = try #require(PixelGrid(image: picture)?.uniformColor(around: text, ring: 10))
        #expect(color.hex == "#000000")
        #expect(color.textHex == "#ffffff")
    }

    @Test func 画面上的字_周围不是纯色() {
        let text = CGRect(x: 120, y: 120, width: 160, height: 60)
        let picture = image { context in
            // 每 6 像素换一次深浅的条纹，像画面里的线条和网点
            for x in stride(from: 0, to: 400, by: 6) {
                fill(context, CGRect(x: x, y: 0, width: 6, height: 400), gray: (x / 6).isMultiple(of: 2) ? 0.15 : 0.75)
            }
            strokes(context, in: text)
        }
        #expect(PixelGrid(image: picture)?.uniformColor(around: text, ring: 10) == nil)
    }

    @Test func 外圈压到气泡边框_不算纯色() {
        // 气泡刚好比文字框大一点，外圈有一半以上落在气泡外的画面上
        let text = CGRect(x: 120, y: 60, width: 160, height: 60)
        let picture = image { context in
            fill(context, CGRect(x: 0, y: 0, width: 400, height: 400), gray: 0)
            fill(context, CGRect(x: 118, y: 58, width: 164, height: 64), gray: 1)
        }
        #expect(PixelGrid(image: picture)?.uniformColor(around: text, ring: 12) == nil)
    }

    @Test func 大图先缩小再判断_坐标照样对得上() throws {
        // 宽 1440 的图缩到 720；文字在上半部分的白底里，下半部分是黑色
        let text = CGRect(x: 500, y: 200, width: 400, height: 120)
        let picture = image(width: 1440, height: 1000) { context in
            fill(context, CGRect(x: 0, y: 0, width: 1440, height: 500), gray: 1)
            fill(context, CGRect(x: 0, y: 500, width: 1440, height: 500), gray: 0)
            strokes(context, in: text)
        }
        let grid = try #require(PixelGrid(image: picture))
        #expect(grid.width == 720)
        #expect(grid.uniformColor(around: text, ring: 16)?.hex == "#ffffff")
        // 同样大小的框放到下半部分，是黑色：上下没有颠倒
        #expect(grid.uniformColor(around: text.offsetBy(dx: 0, dy: 500), ring: 16)?.hex == "#000000")
    }

    @Test func 扩边距离和以前一样() {
        #expect(TextCover.padding(characterSize: 8) == 4)
        #expect(TextCover.padding(characterSize: 40) == 10)
    }
}
