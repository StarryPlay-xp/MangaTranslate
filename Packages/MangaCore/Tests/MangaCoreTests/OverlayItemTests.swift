import CoreGraphics
import Foundation
import Testing
@testable import MangaCore

/// 译文框坐标换算：图片模式按原图比例，整屏模式换算成网页文档坐标
struct OverlayItemTests {
    private func block(
        id: Int = 1, kind: String = "dialogue", rect: CGRect, direction: TextDirection = .horizontal,
        characterSize: Int? = 20
    ) -> TranslatedBlock {
        let source = TextBlock(
            id: id, box: Box(rect), direction: direction, text: "原文", confidence: 1, lines: [])
        var block = TranslatedBlock(untranslated: source)
        block.kind = kind
        block.translation = "译文"
        block.characterSize = characterSize
        return block
    }

    @Test func 图片模式_段内坐标加上段的位置再按原图比例换算() throws {
        // 1000×3000 的长图，第二段从 y=1000 开始；字号 20 → 外扩 5 像素
        let segment = PreparedSegment(
            rect: CGRect(x: 0, y: 1000, width: 1000, height: 1500), blocks: [], markedJPEG: Data(),
            characterSize: 20, covers: [1: CoverColor(red: 255, green: 255, blue: 255)])
        let items = ImageOverlayItem.items(
            for: [block(rect: CGRect(x: 100, y: 200, width: 300, height: 100))], in: segment,
            imageWidth: 1000, imageHeight: 3000)
        let item = try #require(items.first)
        #expect(abs(item.x - 0.095) < 1e-9)
        #expect(abs(item.y - 1195.0 / 3000) < 1e-9)
        #expect(abs(item.width - 0.31) < 1e-9)
        #expect(abs(item.height - 110.0 / 3000) < 1e-9)
        #expect(abs(item.fontScale - 0.02) < 1e-9)
        #expect(item.label == false)
        #expect(item.background == "#ffffff")
        #expect(item.textColor == "#111111")
    }

    @Test func 图片模式_画面上的拟声词贴小标签_不铺底色_噪声不贴() {
        let segment = PreparedSegment(
            rect: CGRect(x: 0, y: 0, width: 800, height: 1000), blocks: [], markedJPEG: Data(), characterSize: 20)
        let items = ImageOverlayItem.items(
            for: [
                block(id: 1, kind: "sfx", rect: CGRect(x: 10, y: 10, width: 200, height: 200), characterSize: 90),
                block(id: 2, kind: "noise", rect: CGRect(x: 10, y: 300, width: 100, height: 40)),
            ],
            in: segment, imageWidth: 800, imageHeight: 1000)
        #expect(items.count == 1)
        #expect(items[0].label == true)
        #expect(items[0].background == nil)
        // 小标签字号不超过这一段的对白字号
        #expect(abs(items[0].fontScale - 20.0 / 800) < 1e-9)
    }

    @Test func 整屏模式_截图像素按可视区域换算成文档坐标() throws {
        // 截图 2 倍像素：2000×1600 对应 1000×800 的可视区域，页面已向下滚了 500
        let viewport = Viewport(left: 0, top: 500, width: 1000, height: 800, layoutWidth: 1000)
        let items = OverlayItem.items(
            for: [block(rect: CGRect(x: 200, y: 400, width: 400, height: 100), characterSize: 40)],
            imageSize: CGSize(width: 2000, height: 1600), characterSize: 40, covers: [:], viewport: viewport)
        let item = try #require(items.first)
        // 字号 40 → 外扩 10 像素
        #expect(item.x == 95)
        #expect(item.y == 695)
        #expect(item.width == 210)
        #expect(item.height == 60)
        #expect(item.fontSize == 20)
        #expect(item.label == false)
    }
}
