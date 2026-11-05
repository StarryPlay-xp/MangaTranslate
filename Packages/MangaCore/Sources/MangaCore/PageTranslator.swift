import Foundation

public struct GlossaryTerm: Codable, Sendable, Equatable {
    public var source: String
    public var translation: String

    public init(source: String, translation: String) {
        self.source = source
        self.translation = translation
    }

    enum CodingKeys: String, CodingKey { case source, translation }

    /// 平时是 {"source", "translation"}；精简写法（ReplyFormat.compact）里是 ["原文", "译名"]
    public init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            source = try container.decode(String.self, forKey: .source)
            translation = try container.decode(String.self, forKey: .translation)
        } else {
            var array = try decoder.unkeyedContainer()
            source = try array.decode(String.self)
            translation = try array.decode(String.self)
        }
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
    /// dialogue / narration / sfx / title / noise；模型漏掉的编号记为 missing
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

    /// 需要贴上译文的块
    public var shouldOverlay: Bool { Self.overlaidKinds.contains(kind) && !translation.isEmpty }

    /// 对白和旁白：盖住气泡里的原文，也记进前文
    public var isStory: Bool { kind == "dialogue" || kind == "narration" }

    private static let overlaidKinds: Set<String> = ["dialogue", "narration", "sfx", "title"]

    /// 拟声词、标题宣传语：用不挡画面的小标签显示，不盖住原文。
    /// 只看模型标的类型，不看字号：条漫里喊出来的台词字也很大，按字号判断会让同样的气泡一个盖住、一个贴标签
    public var showsAsLabel: Bool { kind == "sfx" || kind == "title" }
}

public struct PageTranslation: Sendable {
    public var blocks: [TranslatedBlock]
    public var newTerms: [GlossaryTerm]
    /// 包含重试在内的用量
    public var usage: LLMUsage
    public var attempts: Int
    /// 流式翻译时，成功那次从发出请求到收到第一个字的时间；普通请求为 nil
    public var firstToken: Duration? = nil
    /// 成功那次是对冲的第二份请求先出字
    public var hedged = false
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
        let spoken = page.blocks.filter { $0.isStory && !$0.translation.isEmpty }.map(\.translation)
        recentLines = Array((recentLines + spoken).suffix(12))
    }
}

/// 模型回复的写法。App 用 full；其余几种更短、生成更快，留给 OCRProbe 换模型时对比。
/// 2026-11 用 deepseek-flash 在 42 页样本上对比过两轮：
/// - 不抄原文的 nosource、compact 快 18%～26%，但人名、短句错得明显更多，错名还会写进术语表
/// - 照样抄原文的 compact-source 输出少 36%、只快约 11%（模型耗时大头是上传和读图），数字和短句错误仍比 full 多
/// 所以都没有采用
public enum ReplyFormat: String, CaseIterable, Sendable {
    /// 每块写出编号、核对后的原文、译文和类型
    case full
    /// 和 full 一样，但不再抄写原文
    case noSource = "nosource"
    /// 每块写成 [编号, 类型, 译文] 数组，也不抄写原文
    case compact
    /// 每块写成 [编号, 核对后的原文, 译文, 类型] 数组：照样先抄原文，只省掉键名，顺序和 full 一样
    case compactWithSource = "compact-source"
}

/// 组织提示词、调用模型并解析一页的翻译结果
public struct PageTranslator: Sendable {
    /// 把带编号框的图片发给模型；模型不支持看图时应传 false
    public var sendImage: Bool
    public var replyFormat: ReplyFormat

    public init(sendImage: Bool = true, replyFormat: ReplyFormat = .full) {
        self.sendImage = sendImage
        self.replyFormat = replyFormat
    }

    // 系统提示词保持不变：DeepSeek 等服务会自动缓存相同的开头部分，重复请求更便宜
    public static let systemPrompt = systemPrompt(for: .full)

    private static let instructions = """
        你是经验丰富的漫画汉化译者，负责把日漫、韩漫里的文字翻译成自然、口语化的简体中文。

        每次你会收到一页漫画里各个文字块的编号和本地 OCR 结果（可能有错字，也可能为空）。通常还会附上这页的图片，图上用红框和编号标出了这些文字块。

        翻译要求：
        1. 有图片时以图片为准：先看图核对每个编号框里的原文，纠正 OCR 的错误；OCR 为空时直接从图中读取。
        2. 结合画面、说话人和前文判断语气，译文要像中文漫画的台词，简短自然，不要逐字直译。
        3. 人名、地名、门派、招式等专有名词沿用术语表的译法；遇到术语表里没有的新专有名词，在 new_terms 里给出建议译名。
        4. 网站水印、广告、网址、界面按钮、页码等不属于剧情的文字，kind 填 "noise"，translation 留空。
        5. 拟声词 kind 填 "sfx"，translation 给出简短的中文拟声词。气泡里的台词哪怕字很大、是在喊叫，也是 dialogue。
        6. 作品标题、章节标题、宣传语、作者名等排成大字或艺术字的文字，kind 填 "title"，translation 给出简短的中文；和中文写法完全一样的（比如汉字人名），translation 留空。
        """

    private static let kindList =
        "kind 只能是 dialogue（对白）、narration（旁白）、sfx（拟声词）、title（标题、宣传语等大字）、noise（非剧情文字）之一。"

    /// 三种写法只有第 7 条和最后的格式说明不同
    public static func systemPrompt(for format: ReplyFormat) -> String {
        let emptyRule: String
        let reply: String
        switch format {
        case .full:
            emptyRule = "7. 框里其实没有文字时，kind 填 \"noise\"，source 和 translation 都留空。"
            reply = """
                只输出 json，不要输出任何解释。每个编号都要出现且只出现一次，id 与编号一致。格式如下：
                {"blocks": [{"id": 1, "source": "核对后的原文", "translation": "中文译文", "kind": "dialogue"}], "new_terms": [{"source": "原文专有名词", "translation": "中文译名"}]}
                \(kindList)
                """
        case .noSource:
            emptyRule = "7. 框里其实没有文字时，kind 填 \"noise\"，translation 留空。"
            reply = """
                只输出 json，不要输出任何解释，也不要抄写原文。每个编号都要出现且只出现一次，id 与编号一致。格式如下：
                {"blocks": [{"id": 1, "translation": "中文译文", "kind": "dialogue"}], "new_terms": [{"source": "原文专有名词", "translation": "中文译名"}]}
                \(kindList)
                """
        case .compact:
            emptyRule = "7. 框里其实没有文字时，kind 填 \"noise\"，translation 留空。"
            reply = """
                只输出 json，不要输出任何解释，也不要抄写原文。每个编号都要出现且只出现一次。格式如下：
                {"blocks": [[1, "dialogue", "中文译文"], [2, "noise", ""]], "new_terms": [["原文专有名词", "中文译名"]]}
                blocks 里每一项依次是编号、kind、translation；new_terms 里每一项依次是原文和译名，没有就写 []。
                \(kindList)
                """
        case .compactWithSource:
            emptyRule = "7. 框里其实没有文字时，kind 填 \"noise\"，source 和 translation 都留空。"
            reply = """
                只输出 json，不要输出任何解释。每个编号都要出现且只出现一次。格式如下：
                {"blocks": [[1, "核对后的原文", "中文译文", "dialogue"], [2, "", "", "noise"]], "new_terms": [["原文专有名词", "中文译名"]]}
                blocks 里每一项依次是编号、source（核对后的原文）、translation、kind；new_terms 里每一项依次是原文和译名，没有就写 []。
                \(kindList)
                """
        }
        return instructions + "\n" + emptyRule + "\n\n" + reply
    }

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
    public func makePrompt(prompt: String, markedImage: Data, omitImage: Bool = false) -> LLMPrompt {
        LLMPrompt(
            system: Self.systemPrompt(for: replyFormat), user: prompt, jpeg: sendImage ? markedImage : nil,
            maxTokens: 4096,
            omitsImageData: omitImage)
    }

    /// 发送请求并解析 json；网络错误、限流、空白或不合法的返回最多重试 3 次。
    /// onUsage 在每次收到带用量的回复后调用，包括之后解析失败、要重试的那几次，用来记账。
    /// 传了 streaming 就边生成边返回（见 PageTranslator+Streaming.swift）；服务拒绝流式参数时自动改用普通请求
    public func translate(
        blocks: [TextBlock], prompt: String, markedImage: Data, using client: any LLMClient,
        onUsage: (@Sendable (LLMUsage) async -> Void)? = nil, streaming: StreamingOptions? = nil
    ) async throws -> PageTranslation {
        let request = makePrompt(prompt: prompt, markedImage: markedImage)
        var usage = LLMUsage.zero
        var lastError: Error = MangaCoreError("未知错误")
        for attempt in 1...3 {
            let streams = streaming != nil && !StreamingSupport.isUnsupported(client.config)
            do {
                let reply: LLMReply
                var streamed: StreamedReply?
                if streams, let streaming {
                    streamed = try await streamedReply(request, blocks: blocks, using: client, options: streaming)
                    reply = streamed!.reply
                } else {
                    reply = try await client.complete(request)
                }
                if let replyUsage = reply.usage {
                    usage = usage.adding(replyUsage)
                    await onUsage?(replyUsage)
                }
                let output = try TranslationOutput.parse(reply.content)
                return PageTranslation(
                    blocks: Self.merge(blocks, with: output), newTerms: output.newTerms ?? [],
                    usage: usage, attempts: attempt, firstToken: streamed?.firstToken, hedged: streamed?.hedged ?? false)
            } catch let error as LLMServiceError where error.status == 400 && streams {
                // 可能是服务不认 stream 参数：记下来，马上改用普通请求再试（真是别的原因的话，普通请求会再报一次）
                StreamingSupport.markUnsupported(client.config)
                lastError = error
            } catch let error as LLMServiceError where !error.isRetryable {
                throw error
            } catch {
                lastError = error
                if attempt < 3 { try await Task.sleep(for: .seconds(2 * attempt)) }
            }
        }
        throw lastError
    }

    static func merge(_ blocks: [TextBlock], with output: TranslationOutput) -> [TranslatedBlock] {
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
struct TranslationOutput: Decodable {
    struct Item: Decodable {
        var id: Int
        var source: String
        var translation: String
        var kind: String

        enum CodingKeys: String, CodingKey { case id, source, translation, kind }

        // 模型偶尔会把 id 写成字符串，或者省略空字段，这里都兼容
        init(from decoder: Decoder) throws {
            guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
                // 精简写法：[编号, kind, 译文]，或带原文的 [编号, 原文, 译文, kind]
                var array = try decoder.unkeyedContainer()
                let withSource = array.count == 4
                if let number = try? array.decode(Int.self) {
                    id = number
                } else if let text = try? array.decode(String.self), let number = Int(text) {
                    id = number
                } else {
                    throw DecodingError.dataCorruptedError(in: array, debugDescription: "id 不是数字")
                }
                if withSource {
                    source = (try? array.decode(String.self)) ?? ""
                    translation = (try? array.decode(String.self)) ?? ""
                    kind = (try? array.decode(String.self)) ?? "dialogue"
                } else {
                    source = ""
                    kind = (try? array.decode(String.self)) ?? "dialogue"
                    translation = (try? array.decode(String.self)) ?? ""
                }
                return
            }
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

    init(blocks: [Item], newTerms: [GlossaryTerm]?) {
        self.blocks = blocks
        self.newTerms = newTerms
    }

    /// 容错解析：去掉思考过程和 ```json 代码块，截取其中的 json；
    /// 模型直接返回编号数组（没有外层 blocks）时也能识别
    static func parse(_ content: String) throws -> TranslationOutput {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MangaCoreError("返回内容为空")
        }
        for candidate in LLMJSON.candidates(in: content) {
            let data = Data(candidate.utf8)
            if let output = try? decoder.decode(TranslationOutput.self, from: data) { return output }
            if let items = try? decoder.decode([Item].self, from: data) {
                return TranslationOutput(blocks: items, newTerms: nil)
            }
        }
        throw MangaCoreError("返回的内容里没有找到有效的 json")
    }
}

/// 从模型回复里找出 json 文本
public enum LLMJSON {
    /// 按可能性从高到低排列的候选文本
    public static func candidates(in content: String) -> [String] {
        let text = stripThinking(content).trimmingCharacters(in: .whitespacesAndNewlines)
        var results = [text]
        if let fenced = fencedBlock(in: text) { results.append(fenced) }
        for (open, close) in [("{", "}"), ("[", "]")] {
            if let start = text.firstIndex(of: Character(open)), let end = text.lastIndex(of: Character(close)),
               start < end {
                results.append(String(text[start...end]))
            }
        }
        var seen = Set<String>()
        return results.filter { seen.insert($0).inserted }
    }

    /// 回复里有没有能解析的 json 对象或数组
    public static func containsJSON(_ content: String) -> Bool {
        candidates(in: content).contains { candidate in
            guard let data = candidate.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data)
            else { return false }
            return object is [String: Any] || object is [Any]
        }
    }

    /// 去掉本地推理模型放在正文里的 <think>…</think>；只有开头标签、没有结束标签时去掉整段
    public static func stripThinking(_ content: String) -> String {
        var text = content
        for tag in ["think", "thinking"] {
            while let open = text.range(of: "<\(tag)>") {
                if let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex) {
                    text.removeSubrange(open.lowerBound..<close.upperBound)
                } else {
                    text.removeSubrange(open.lowerBound..<text.endIndex)
                }
            }
        }
        return text
    }

    private static func fencedBlock(in text: String) -> String? {
        guard let open = text.range(of: "```") else { return nil }
        // 跳过 ```json 这样的语言标记，到行尾为止
        let afterOpen = text[open.upperBound...]
        let bodyStart = afterOpen.firstIndex(of: "\n").map { text.index(after: $0) } ?? open.upperBound
        guard let close = text.range(of: "```", range: bodyStart..<text.endIndex) else { return nil }
        return String(text[bodyStart..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
