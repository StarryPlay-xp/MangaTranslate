import Foundation

/// 边收边解析：从还没收完的回复里，取出 "blocks" 数组中已经写完整的块（对象或数组写法都认）。
/// 只用来提前显示；整段收完后仍以 TranslationOutput.parse 的结果为准
struct PartialBlocksParser {
    private var bytes: [UInt8] = []
    /// 下一个要看的字节
    private var position = 0
    /// 找到 "blocks" 的 [ 之后才开始数层级
    private var insideBlocks = false
    private var finished = false
    /// 相对 blocks 数组的层级：1 是数组本身，2 以上在某一块里面
    private var depth = 0
    private var inString = false
    private var escaped = false
    private var elementStart: Int?
    private let decoder = JSONDecoder()

    private(set) var items: [TranslationOutput.Item] = []

    /// 追加一段文字，返回这次新取出的块
    mutating func append(_ text: String) -> [TranslationOutput.Item] {
        guard !finished else { return [] }
        bytes.append(contentsOf: text.utf8)
        if !insideBlocks && !findBlocksArray() { return [] }
        var found: [TranslationOutput.Item] = []
        while position < bytes.count {
            let byte = bytes[position]
            position += 1
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""):
                inString = true
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                if depth == 1 { elementStart = position - 1 }
                depth += 1
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                depth -= 1
                if depth == 1, let start = elementStart {
                    elementStart = nil
                    let element = Data(bytes[start..<position])
                    if let item = try? decoder.decode(TranslationOutput.Item.self, from: element) {
                        items.append(item)
                        found.append(item)
                    }
                } else if depth == 0 {
                    finished = true
                    return found
                }
            default:
                break
            }
        }
        return found
    }

    /// 找 "blocks" 后面的 [；找到时把位置移到 [ 之后
    private mutating func findBlocksArray() -> Bool {
        let key = Array(#""blocks""#.utf8)
        guard bytes.count >= key.count else { return false }
        for start in 0...(bytes.count - key.count) where bytes[start..<(start + key.count)].elementsEqual(key) {
            var index = start + key.count
            while index < bytes.count, bytes[index] == UInt8(ascii: " ") || bytes[index] == UInt8(ascii: ":")
                || bytes[index] == UInt8(ascii: "\n") || bytes[index] == UInt8(ascii: "\t") || bytes[index] == UInt8(ascii: "\r") {
                index += 1
            }
            guard index < bytes.count else { return false }
            guard bytes[index] == UInt8(ascii: "[") else { continue }
            position = index + 1
            insideBlocks = true
            depth = 1
            return true
        }
        return false
    }
}
