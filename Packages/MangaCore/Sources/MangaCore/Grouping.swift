import CoreGraphics
import Foundation

public enum ReadingOrder: String, Codable, Sendable {
    /// 日漫：从上到下，同一行内从右到左
    case rightToLeft
    /// 韩漫条漫：从上到下，同一行内从左到右
    case leftToRight
}

/// 漫画的原文语言，决定 Vision 的识别语言和文字块的阅读顺序
public enum SourceLanguage: String, Codable, Sendable, CaseIterable {
    case japanese
    case korean

    public var recognitionLanguages: [String] { self == .japanese ? ["ja-JP"] : ["ko-KR"] }
    public var readingOrder: ReadingOrder { self == .japanese ? .rightToLeft : .leftToRight }
    public var displayName: String { self == .japanese ? "日语" : "韩语" }
}

public enum TextDirection: String, Codable, Sendable {
    case vertical, horizontal
}

/// 合并后的文字块，通常对应一个气泡或一段旁白；App 里每块对应一处译文
public struct TextBlock: Codable, Sendable {
    /// 按阅读顺序的编号，从 1 开始
    public var id: Int
    public var box: Box
    public var direction: TextDirection
    /// 块内各行按阅读顺序拼接；为空表示只检测到位置、没认出字
    public var text: String
    /// 块内识别结果的平均置信度；没认出字时为 nil
    public var confidence: Double?
    public var lines: [TextLine]
}

/// 把相距很近的文字区域和识别行合并成文字块，并按阅读顺序编号
public func groupIntoBlocks(_ analysis: TextAnalysis, gapFactor: Double, order: ReadingOrder) -> [TextBlock] {
    let gap = analysis.characterSize * gapFactor
    let regions = mergeNearby(analysis.regions + analysis.lines.map(\.box.rect), gap: gap)

    var linesByRegion = Array(repeating: [TextLine](), count: regions.count)
    for line in analysis.lines {
        let center = CGPoint(x: line.box.rect.midX, y: line.box.rect.midY)
        if let index = regions.firstIndex(where: { $0.contains(center) }) {
            linesByRegion[index].append(line)
        }
    }

    // 没认出字、面积又不到 2×2 个字的块，多半是画面纹理被误检，丢掉
    let minEmptyArea = pow(analysis.characterSize * 2, 2)
    let kept = regions.indices.filter { index in
        !linesByRegion[index].isEmpty || regions[index].width * regions[index].height >= minEmptyArea
    }
    let keptRects = kept.map { regions[$0] }
    return sortedInReadingOrder(keptRects, order: order).enumerated().map { position, index in
        makeBlock(id: position + 1, rect: keptRects[index], lines: linesByRegion[kept[index]])
    }
}

/// 反复合并外扩 gap 后相交的矩形，直到没有可合并的为止
private func mergeNearby(_ rects: [CGRect], gap: CGFloat) -> [CGRect] {
    var merged = rects.filter { !$0.isEmpty }
    var changed = true
    while changed {
        changed = false
        var i = 0
        while i < merged.count {
            var j = i + 1
            while j < merged.count {
                if merged[i].insetBy(dx: -gap, dy: -gap).intersects(merged[j]) {
                    merged[i] = merged[i].union(merged[j])
                    merged.remove(at: j)
                    changed = true
                } else {
                    j += 1
                }
            }
            i += 1
        }
    }
    return merged
}

/// 先按纵向位置分行（与当前行纵向重叠超过自身 30% 的算同一行），行内再按阅读方向排
private func sortedInReadingOrder(_ rects: [CGRect], order: ReadingOrder) -> [Int] {
    var rows: [[Int]] = []
    var rowBottoms: [CGFloat] = []
    for index in rects.indices.sorted(by: { rects[$0].minY < rects[$1].minY }) {
        let rect = rects[index]
        if let last = rows.indices.last, rect.minY < rowBottoms[last] - rect.height * 0.3 {
            rows[last].append(index)
            rowBottoms[last] = max(rowBottoms[last], rect.maxY)
        } else {
            rows.append([index])
            rowBottoms.append(rect.maxY)
        }
    }
    return rows.flatMap { row in
        row.sorted { a, b in
            order == .rightToLeft ? rects[a].maxX > rects[b].maxX : rects[a].minX < rects[b].minX
        }
    }
}

private func makeBlock(id: Int, rect: CGRect, lines: [TextLine]) -> TextBlock {
    let verticalLines = lines.filter { $0.box.height > $0.box.width }.count
    let isVertical = lines.isEmpty ? rect.height > rect.width * 1.3 : verticalLines * 2 > lines.count
    // 竖排：列从右往左读；横排：行从上往下读
    let ordered = lines.sorted { a, b in
        isVertical ? a.box.rect.maxX > b.box.rect.maxX : a.box.rect.minY < b.box.rect.minY
    }
    let confidence = lines.isEmpty ? nil : lines.map(\.confidence).reduce(0, +) / Double(lines.count)
    return TextBlock(
        id: id,
        box: Box(rect),
        direction: isVertical ? .vertical : .horizontal,
        text: ordered.map(\.text).joined(separator: "\n"),
        confidence: confidence,
        lines: ordered)
}
