import Foundation

public struct GlossaryTerm: Codable, Sendable, Equatable {
    public var source: String
    public var translation: String

    public init(source: String, translation: String) {
        self.source = source
        self.translation = translation
    }
}

public struct TranslatedBlock: Codable, Sendable {
    public var id: Int
    public var box: Box
    public var direction: TextDirection
    public var ocrText: String
    /// 模型看图核对后的原文
    public var source: String
    public var translation: String
    /// dialogue / narration / sfx / noise；模型漏掉的编号记为 missing
    public var kind: String
    /// 块内原文的字号估计（像素），作为译文字号的上限；没认出字的块为 nil
    public var characterSize: Int?

    /// 还没翻译的块：kind 为 missing，译文为空
    public init(untranslated block: TextBlock) {
        id = block.id
        box = block.box
        direction = block.direction
        ocrText = block.text
        source = ""
        translation = ""
        kind = "missing"
        // 横排取行高、竖排取列宽的中位数；Vision 的行框比字略大，打九折
        let sides = block.lines.map { block.direction == .vertical ? $0.box.width : $0.box.height }.sorted()
        characterSize = sides.isEmpty ? nil : Int(Double(sides[sides.count / 2]) * 0.9)
    }

    /// 试运行用：不调用模型，把识别原文当作"译文"，用来检查识别和贴字效果
    public static func dryRun(_ block: TextBlock) -> TranslatedBlock {
        var translated = TranslatedBlock(untranslated: block)
        translated.translation = block.text.replacingOccurrences(of: "\n", with: " ")
        translated.kind = block.text.isEmpty ? "noise" : "dialogue"
        return translated
    }

    /// 需要盖上译文的块
    public var shouldOverlay: Bool { (kind == "dialogue" || kind == "narration") && !translation.isEmpty }
}

public struct PageTranslation: Sendable {
    public var blocks: [TranslatedBlock]
    public var newTerms: [GlossaryTerm]
    /// 包含重试在内的用量
    public var usage: DeepSeekClient.Usage
    public var attempts: Int
}

/// 跨页记忆：术语表和最近的译文，让同一部作品前后译名和语气一致
public struct TranslationMemory: Codable, Sendable {
    public var glossary: [GlossaryTerm] = []
    public var recentLines: [String] = []

    public init() {}

    public mutating func record(_ page: PageTranslation) {
        for term in page.newTerms where !term.source.isEmpty && !term.translation.isEmpty {
            if !glossary.contains(where: { $0.source == term.source }) { glossary.append(term) }
        }
        let spoken = page.blocks.filter(\.shouldOverlay).map(\.translation)
        recentLines = Array((recentLines + spoken).suffix(12))
    }
}

/// 组织提示词、调用 DeepSeek 并解析一页的翻译结果
public struct PageTranslator: Sendable {
    public var model: String
    public var thinking: Bool
    public var sendImage: Bool

    public init(model: String = DeepSeekPricing.pricedModel, thinking: Bool = false, sendImage: Bool = true) {
        self.model = model
        self.thinking = thinking
        self.sendImage = sendImage
    }

    // 系统提示词保持不变，DeepSeek 会自动缓存相同的开头部分，重复请求更便宜
    public static let systemPrompt = """
        你是经验丰富的漫画汉化译者，负责把日漫、韩漫里的文字翻译成自然、口语化的简体中文。

        每次你会收到一页漫画里各个文字块的编号和本地 OCR 结果（可能有错字，也可能为空）。通常还会附上这页的图片，图上用红框和编号标出了这些文字块。

        翻译要求：
        1. 有图片时以图片为准：先看图核对每个编号框里的原文，纠正 OCR 的错误；OCR 为空时直接从图中读取。
        2. 结合画面、说话人和前文判断语气，译文要像中文漫画的台词，简短自然，不要逐字直译。
        3. 人名、地名、门派、招式等专有名词沿用术语表的译法；遇到术语表里没有的新专有名词，在 new_terms 里给出建议译名。
        4. 网站水印、广告、网址、界面按钮、页码等不属于剧情的文字，kind 填 "noise"，translation 留空。
        5. 拟声词 kind 填 "sfx"，translation 给出简短的中文拟声词。
        6. 框里其实没有文字时，kind 填 "noise"，source 和 translation 都留空。

        只输出 json，不要输出任何解释。每个编号都要出现且只出现一次，id 与编号一致。格式如下：
        {"blocks": [{"id": 1, "source": "核对后的原文", "translation": "中文译文", "kind": "dialogue"}], "new_terms": [{"source": "原文专有名词", "translation": "中文译名"}]}
        kind 只能是 dialogue（对白）、narration（旁白）、sfx（拟声词）、noise（非剧情文字）之一。
        """

    public func userPrompt(
        blocks: [TextBlock], languageName: String, readingOrder: ReadingOrder, memory: TranslationMemory
    ) -> String {
        let order = readingOrder == .rightToLeft ? "日漫，从右到左、从上到下" : "条漫，从上到下"
        var lines = ["语言：\(languageName)；阅读顺序：\(order)"]
        lines.append(memory.glossary.isEmpty ? "术语表：（暂无）" : "术语表：")
        lines += memory.glossary.map { "- \($0.source) → \($0.translation)" }
        if !memory.recentLines.isEmpty {
            lines.append("前文（之前几页的译文，按顺序）：")
            lines += memory.recentLines.map { "- \($0)" }
        }
        if !sendImage {
            lines.append("本次没有附图片：只能根据 OCR 结果翻译，可以按上下文修正明显的错字。")
        }
        lines.append("本页文字块（编号：OCR 结果）：")
        lines += blocks.map { block in
            "\(block.id)：" + (block.text.isEmpty ? "（空）" : block.text.replacingOccurrences(of: "\n", with: " / "))
        }
        return lines.joined(separator: "\n")
    }

    /// markedImage 为带编号框的 JPEG；sendImage 为 false 时不会附上
    public func makeRequest(prompt: String, markedImage: Data, omitImage: Bool = false) -> ChatRequest {
        let parts: [ChatRequest.Part] =
            sendImage ? [.text(prompt), .jpeg(markedImage, omitted: omitImage)] : [.text(prompt)]
        return ChatRequest(
            model: model,
            messages: [
                .init(role: "system", content: .text(Self.systemPrompt)),
                .init(role: "user", content: .parts(parts)),
            ],
            thinking: .init(type: thinking ? "enabled" : "disabled"),
            maxTokens: 4096)
    }

    /// 发送请求并解析 json；网络错误、限流、空白或不合法的返回最多重试 3 次
    public func translate(
        blocks: [TextBlock], prompt: String, markedImage: Data, using client: DeepSeekClient
    ) async throws -> PageTranslation {
        let request = makeRequest(prompt: prompt, markedImage: markedImage)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        var usage = DeepSeekClient.Usage.zero
        var lastError: Error = MangaCoreError("未知错误")
        for attempt in 1...3 {
            do {
                let reply = try await client.complete(request)
                if let replyUsage = reply.usage { usage = usage.adding(replyUsage) }
                let content = reply.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !content.isEmpty else { throw MangaCoreError("返回内容为空") }
                let output = try decoder.decode(TranslationOutput.self, from: Data(content.utf8))
                return PageTranslation(
                    blocks: Self.merge(blocks, with: output), newTerms: output.newTerms ?? [],
                    usage: usage, attempts: attempt)
            } catch let error as DeepSeekError where !error.isRetryable {
                throw error
            } catch {
                lastError = error
                if attempt < 3 { try await Task.sleep(for: .seconds(2 * attempt)) }
            }
        }
        throw lastError
    }

    private static func merge(_ blocks: [TextBlock], with output: TranslationOutput) -> [TranslatedBlock] {
        let items = Dictionary(output.blocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return blocks.map { block in
            var translated = TranslatedBlock(untranslated: block)
            if let item = items[block.id] {
                translated.source = item.source
                translated.translation = item.translation
                translated.kind = item.kind
            }
            return translated
        }
    }
}

/// 模型返回的 json
private struct TranslationOutput: Decodable {
    struct Item: Decodable {
        var id: Int
        var source: String
        var translation: String
        var kind: String

        enum CodingKeys: String, CodingKey { case id, source, translation, kind }

        // 模型偶尔会把 id 写成字符串，或者省略空字段，这里都兼容
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let number = try? container.decode(Int.self, forKey: .id) {
                id = number
            } else if let text = try? container.decode(String.self, forKey: .id), let number = Int(text) {
                id = number
            } else {
                throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "id 不是数字")
            }
            source = (try? container.decodeIfPresent(String.self, forKey: .source)) ?? ""
            translation = (try? container.decodeIfPresent(String.self, forKey: .translation)) ?? ""
            kind = (try? container.decodeIfPresent(String.self, forKey: .kind)) ?? "dialogue"
        }
    }

    var blocks: [Item]
    var newTerms: [GlossaryTerm]?
}
