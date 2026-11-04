import CoreGraphics
import Testing
@testable import MangaCore

struct SegmentingTests {
    @Test func 不够长的图不切() {
        let rects = Segmenting.segmentRects(width: 1000, height: 1400)
        #expect(rects == [CGRect(x: 0, y: 0, width: 1000, height: 1400)])
    }

    @Test func 长图切段覆盖全图且相邻段有足够重叠() {
        let rects = Segmenting.segmentRects(width: 800, height: 4000)
        #expect(rects.count > 1)
        #expect(rects.first?.minY == 0)
        #expect(rects.last?.maxY == 4000)
        for rect in rects {
            #expect(rect.height == 1200)
        }
        for (upper, lower) in zip(rects, rects.dropFirst()) {
            #expect(upper.maxY - lower.minY >= 320)
            #expect(lower.minY > upper.minY)
        }
    }

    @Test func 被切口切断的块丢掉_由下一段完整处理() {
        let rects = Segmenting.segmentRects(width: 800, height: 4000)
        // 一个原图中 y=1000…1240 的气泡：第 1 段（0…1200）里被切断，第 2 段（880…2080）里完整
        let cutInFirst = block(id: 1, y: 1000, height: 200)  // 第 1 段坐标，底边贴着 1200 的切口
        let wholeInSecond = block(id: 1, y: 1000 - Int(rects[1].minY), height: 240)

        #expect(Segmenting.ownedBlocks([cutInFirst], segmentIndex: 0, in: rects).isEmpty)
        #expect(Segmenting.ownedBlocks([wholeInSecond], segmentIndex: 1, in: rects).count == 1)
    }

    @Test func 完整落在重叠区的块只归一段() {
        let rects = Segmenting.segmentRects(width: 800, height: 4000)
        let overlapTop = rects[1].minY
        let overlapBottom = rects[0].maxY
        // 两个块都完整落在第 1、2 段的重叠区里：一个偏上，一个偏下
        let upperY = Int(overlapTop) + 10
        let lowerY = Int(overlapBottom) - 70
        let inFirst = [block(id: 1, y: upperY, height: 50), block(id: 2, y: lowerY, height: 50)]
        let inSecond = [
            block(id: 1, y: upperY - Int(overlapTop), height: 50),
            block(id: 2, y: lowerY - Int(overlapTop), height: 50),
        ]

        let ownedByFirst = Segmenting.ownedBlocks(inFirst, segmentIndex: 0, in: rects)
        let ownedBySecond = Segmenting.ownedBlocks(inSecond, segmentIndex: 1, in: rects)
        #expect(ownedByFirst.map(\.box.y) == [upperY])
        #expect(ownedBySecond.map(\.box.y) == [lowerY - Int(overlapTop)])
    }

    @Test func 保留下来的块重新编号() {
        let rects = [CGRect(x: 0, y: 0, width: 800, height: 1000)]
        let blocks = [block(id: 3, y: 100, height: 50), block(id: 7, y: 400, height: 50)]
        #expect(Segmenting.ownedBlocks(blocks, segmentIndex: 0, in: rects).map(\.id) == [1, 2])
    }

    @Test func 大图缩小到限定像素以内_小图不变() throws {
        let big = try makeContext(width: 2000, height: 3000).makeImage()!
        let scaled = try scaledToFit(big, maxPixelCount: 2_000_000)
        #expect(scaled.width * scaled.height <= 2_000_000)
        #expect(abs(Double(scaled.width) / Double(scaled.height) - 2000.0 / 3000.0) < 0.01)

        let small = try makeContext(width: 800, height: 1000).makeImage()!
        #expect(try scaledToFit(small, maxPixelCount: 2_000_000).width == 800)
    }

    private func block(id: Int, y: Int, height: Int) -> TextBlock {
        TextBlock(
            id: id, box: Box(CGRect(x: 100, y: y, width: 300, height: height)), direction: .horizontal,
            text: "테스트", confidence: 1, lines: [])
    }
}
