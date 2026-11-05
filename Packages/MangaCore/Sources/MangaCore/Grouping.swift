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

/// 把相距很近的文字区域和识别行合并成文字块，并按阅读顺序编号。
/// 字号差很多或一竖一横的文字不合并（比如封面的大标题和旁边的小字旁白），见 mergePieces
public func groupIntoBlocks(_ analysis: TextAnalysis, gapFactor: Double, order: ReadingOrder) -> [TextBlock] {
    // 检测到的文字区域常是横着跨过几列竖排字的长条，字号也按字符框算、和识别行的量法不同：
    // 只当"胶水"把同一个气泡的几列粘起来，不参与字号和方向的判断
    let regionPieces = analysis.regions.map { TextPiece(region: $0) }
    let linePieces = analysis.lines.map { TextPiece(line: $0.box.rect, text: $0.text) }
    let clusters = mergePieces(
        regionPieces + linePieces, pageCharacterSize: analysis.characterSize, gapFactor: gapFactor)
    let regions = clusters.map(\.rect)
    // 每行归到合并时它所在的那一块。不能按中心点落在哪个框里算：压在大字标志上的章节标签，中心点在标志的框里
    let linesByRegion = clusters.map { cluster in
        cluster.members.filter { $0 >= regionPieces.count }.sorted().map { analysis.lines[$0 - regionPieces.count] }
    }

    // 没认出字的块：面积不到 2×2 个字的多半是画面纹理被误检；有三成以上和别的块重叠的，
    // 是横跨在文字上的检测框（文字已经在别的块里），都丢掉
    let minEmptyArea = pow(analysis.characterSize * 2, 2)
    let kept = regions.indices.filter { index in
        if !linesByRegion[index].isEmpty { return true }
        let rect = regions[index]
        let area = rect.width * rect.height
        guard area >= minEmptyArea else { return false }
        let covered = regions.indices.reduce(CGFloat(0)) { total, other in
            guard other != index, !linesByRegion[other].isEmpty else { return total }
            let overlap = rect.intersection(regions[other])
            return overlap.isNull ? total : total + overlap.width * overlap.height
        }
        return covered < area * 0.3
    }
    let keptRects = kept.map { regions[$0] }
    return sortedInReadingOrder(keptRects, order: order).enumerated().map { position, index in
        makeBlock(id: position + 1, rect: keptRects[index], lines: linesByRegion[kept[index]])
    }
}

/// 待合并的一个文字框：检测到的文字区域，或识别出的一行（一列）
struct TextPiece {
    var rect: CGRect
    /// 字号估计，只有识别行有；检测区域为 nil
    var size: CGFloat?
    /// 很细长的识别行（三四个字以上）能看出排列方向；短的、检测区域看不出，为 nil
    var direction: TextDirection?

    /// 字号按"长边 ÷ 字数"估计：带注音的那一列（行）框会宽出将近一倍，短边不准。
    /// 识别时多认出几个字会把字号算小，所以结果限制在短边的 0.55～1 倍之间
    init(line rect: CGRect, text: String) {
        self.rect = rect
        let short = min(rect.width, rect.height)
        let long = max(rect.width, rect.height)
        let count = text.reduce(0.0) { total, character in
            character.isWhitespace ? total : total + (character.isASCII ? 0.5 : 1)
        }
        let pitch = count >= 2 ? long / count : short
        size = min(max(pitch, short * 0.55), short)
        direction = short > 0 && long >= short * 3.5 ? (rect.height > rect.width ? .vertical : .horizontal) : nil
    }

    init(region rect: CGRect) {
        self.rect = rect
    }
}

/// 合并到一起的一组文字框
struct TextCluster {
    var rect: CGRect
    /// 合并进来的文字框在输入里的序号
    var members: [Int]
    var sizes: [CGFloat]
    var verticalCount = 0
    var horizontalCount = 0

    init(_ piece: TextPiece, index: Int) {
        rect = piece.rect
        members = [index]
        sizes = piece.size.map { [$0] } ?? []
        add(direction: piece.direction)
    }

    /// 块里识别行字号的中位数；只有检测区域、没有识别行时为 nil
    var size: CGFloat? { sizes.isEmpty ? nil : sizes.sorted()[sizes.count / 2] }

    /// 大多数细长成员的方向；竖横差不多时看不出
    var direction: TextDirection? {
        if verticalCount > 0, verticalCount >= horizontalCount * 2 { return .vertical }
        if horizontalCount > 0, horizontalCount >= verticalCount * 2 { return .horizontal }
        return nil
    }

    /// 并入注音：只扩大范围，不改字号和方向。注音框常是横着的小条，算进方向会把竖排标题变成"看不出方向"
    mutating func attach(_ ruby: TextCluster) {
        rect = rect.union(ruby.rect)
        members += ruby.members
    }

    mutating func absorb(_ other: TextCluster) {
        rect = rect.union(other.rect)
        members += other.members
        sizes += other.sizes
        verticalCount += other.verticalCount
        horizontalCount += other.horizontalCount
    }

    private mutating func add(direction: TextDirection?) {
        if direction == .vertical { verticalCount += 1 }
        if direction == .horizontal { horizontalCount += 1 }
    }
}

/// 字号相差超过这个倍数的两组文字不合并。带注音的那一列识别框会宽出八成左右，留出一点余量
let maxMergeSizeRatio: CGFloat = 2.0

/// 先把注音假名这类比旁边小很多、紧贴并排的小字并进去；再反复合并相距很近、字号接近、方向一致的文字框，
/// 直到没有可合并的为止。大面积重叠、字号接近的（同一段字的不同检测结果）不管方向都合并
func mergePieces(_ pieces: [TextPiece], pageCharacterSize: CGFloat, gapFactor: Double) -> [TextCluster] {
    var clusters = pieces.enumerated().filter { !$0.element.rect.isEmpty }.map { TextCluster($0.element, index: $0.offset) }

    // 间距和以前一样按整页字号算。按块自己的字号放大的话，相隔不远的两段大字会连成一块
    let gap = pageCharacterSize * gapFactor
    func overlapsHeavily(_ a: TextCluster, _ b: TextCluster) -> Bool {
        let overlap = a.rect.intersection(b.rect)
        guard !overlap.isNull else { return false }
        let smaller = min(a.rect.width * a.rect.height, b.rect.width * b.rect.height)
        return smaller > 0 && overlap.width * overlap.height >= smaller * 0.5
    }
    func similarSize(_ a: TextCluster, _ b: TextCluster) -> Bool {
        guard let first = a.size, let second = b.size else { return true }
        return max(first, second) / max(min(first, second), 1) <= maxMergeSizeRatio
    }
    func compatible(_ a: TextCluster, _ b: TextCluster) -> Bool {
        guard similarSize(a, b) else { return false }
        if let first = a.direction, let second = b.direction, first != second { return false }
        return true
    }
    func near(_ a: TextCluster, _ b: TextCluster) -> Bool {
        a.rect.insetBy(dx: -gap, dy: -gap).intersects(b.rect)
    }

    // 先处理注音：字号不超过正文、不到旁边那块 0.6 倍、紧贴着它（不超过自身半个字）、
    // 又和它并排（在它的上下或左右范围内）的小字，并进最近的那一块。
    // 注音常和旁边的对白一样大，不先并进大字的话，会在下面和对白合成一块，再把大字和对白串起来。
    // 紧挨着大号拟声词的短对白（比如「きゃっ。」）字号比正文大、也不和拟声词并排，不会被当成注音
    var attachments: [(small: Int, target: Int)] = []
    for index in clusters.indices {
        let small = clusters[index]
        guard let smallSize = small.size, smallSize <= pageCharacterSize * 1.2 else { continue }
        let best = clusters.indices
            .filter { other in
                guard other != index, let size = clusters[other].size else { return false }
                // 注音和大字平行：竖排字旁边是竖着的注音，一竖一横的不是
                if let first = small.direction, let second = clusters[other].direction, first != second { return false }
                return smallSize <= size * 0.6 && distance(small.rect, clusters[other].rect) <= smallSize * 0.5
                    && alongside(small.rect, clusters[other].rect, direction: small.direction)
            }
            .min { distance(small.rect, clusters[$0].rect) < distance(small.rect, clusters[$1].rect) }
        if let best { attachments.append((index, best)) }
    }
    let smalls = Set(attachments.map(\.small))
    var removed = Set<Int>()
    for (small, target) in attachments where !smalls.contains(target) {
        clusters[target].attach(clusters[small])
        removed.insert(small)
    }
    clusters = clusters.indices.filter { !removed.contains($0) }.map { clusters[$0] }

    var changed = true
    while changed {
        changed = false
        var i = 0
        while i < clusters.count {
            var j = i + 1
            while j < clusters.count {
                let a = clusters[i]
                let b = clusters[j]
                // 字号差很多又重叠的，是一段字压在另一段字上（比如章节标签压在作品标志上），不合并
                if (overlapsHeavily(a, b) && similarSize(a, b)) || (near(a, b) && compatible(a, b)) {
                    clusters[i].absorb(b)
                    clusters.remove(at: j)
                    changed = true
                } else {
                    j += 1
                }
            }
            i += 1
        }
    }

    return clusters
}

/// 注音和大字并排：竖着的注音在大字左右两侧，上下有八成以上落在大字的范围内；
/// 横着的注音在大字上下方，左右有八成以上落在大字的范围内；看不出方向的两种都行
private func alongside(_ small: CGRect, _ target: CGRect, direction: TextDirection?) -> Bool {
    let xOverlap = min(small.maxX, target.maxX) - max(small.minX, target.minX)
    let yOverlap = min(small.maxY, target.maxY) - max(small.minY, target.minY)
    let beside = yOverlap >= small.height * 0.8
    let above = xOverlap >= small.width * 0.8
    switch direction {
    case .vertical: return beside
    case .horizontal: return above
    case nil: return beside || above
    }
}

/// 两个矩形边缘之间的最短距离，相交时为 0
private func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
    let dx = max(0, max(a.minX, b.minX) - min(a.maxX, b.maxX))
    let dy = max(0, max(a.minY, b.minY) - min(a.maxY, b.maxY))
    return (dx * dx + dy * dy).squareRoot()
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
