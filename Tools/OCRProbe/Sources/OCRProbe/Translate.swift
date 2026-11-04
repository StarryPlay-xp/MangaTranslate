import CoreGraphics
import Foundation

struct TranslateOptions {
    var samples: URL
    /// OCRProbe run 的输出目录，读取其中的 results.json
    var probe: URL
    var output: URL
    var model = DeepSeekPricing.pricedModel
    var limit: Int?
    var sendImage = true
    var thinking = false
    /// 只生成要发送的内容，不联网、不需要 API Key
    var dryRun = false

    init(parsing args: [String]) throws {
        var positional: [String] = []
        var iterator = args.makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--limit":
                guard let value = iterator.next().flatMap({ Int($0) }), value > 0 else {
                    throw ProbeError("--limit 后面要跟一个正整数，例如 3")
                }
                limit = value
            case "--model":
                guard let value = iterator.next() else { throw ProbeError("--model 后面要跟模型名") }
                model = value
            case "--text-only": sendImage = false
            case "--thinking": thinking = true
            case "--dry-run": dryRun = true
            default: positional.append(arg)
            }
        }
        guard positional.count == 3 else {
            throw ProbeError("用法：ocrprobe translate <样本目录> <识别结果目录> <输出目录> [--limit 3] [--text-only] [--thinking] [--dry-run]")
        }
        samples = URL(fileURLWithPath: positional[0])
        probe = URL(fileURLWithPath: positional[1])
        output = URL(fileURLWithPath: positional[2])
    }
}

struct GlossaryTerm: Codable, Sendable {
    var source: String
    var translation: String
}

struct TranslatedBlock: Codable, Sendable {
    var id: Int
    var box: Box
    var direction: TextDirection
    var ocrText: String
    /// 模型看图核对后的原文
    var source: String
    var translation: String
    /// dialogue / narration / sfx / noise；模型漏掉的编号记为 missing
    var kind: String
    /// 块内原文的字号估计（像素），作为译文字号的上限；没认出字的块为 nil
    var characterSize: Int?

    /// 需要在 App 里盖上译文的块
    var shouldOverlay: Bool { (kind == "dialogue" || kind == "narration") && !translation.isEmpty }
}

struct TranslatedPage: Codable, Sendable {
    var file: String
    var elapsedMs: Int
    var attempts: Int
    var peak: Bool
    var usage: DeepSeekClient.Usage?
    /// 只有用 deepseek-flash 时才估算
    var costUSD: Double?
    var blocks: [TranslatedBlock]
    var userPrompt: String
    var markedImage: String
    var previewImage: String?
    var error: String?
}

struct TranslateRun: Codable, Sendable {
    var model: String
    var sendImage: Bool
    var thinking: Bool
    var dryRun: Bool
    var pages: [TranslatedPage]
    var glossary: [GlossaryTerm]
}

func runTranslate(_ options: TranslateOptions) async throws {
    let resultsURL = options.probe.appendingPathComponent("results.json")
    guard let data = try? Data(contentsOf: resultsURL) else {
        throw ProbeError("找不到 \(resultsURL.path)，请先运行 ocrprobe run")
    }
    let allPages = try JSONDecoder().decode([PageResult].self, from: data)
    let pages = options.limit.map { Array(allPages.prefix($0)) } ?? allPages

    let client = options.dryRun ? nil : DeepSeekClient(apiKey: try readDeepSeekAPIKey())
    if options.dryRun {
        print("试运行：只生成要发送的内容，不联网。")
    } else {
        let content = options.sendImage ? "带编号框的图片和识别文字" : "识别文字"
        print("将把 \(pages.count) 页的\(content)发送到 DeepSeek（\(options.model)）。")
    }

    var glossary: [GlossaryTerm] = []
    var recentLines: [String: [String]] = [:]  // 按文件夹记录最近的译文，作为下一页的前文
    var results: [TranslatedPage] = []

    for (index, page) in pages.enumerated() {
        print("[\(index + 1)/\(pages.count)] \(page.file)", terminator: "")
        let folder = page.file.split(separator: "/").dropLast().joined(separator: "/")
        let image = try loadImage(at: options.samples.appendingPathComponent(page.file))
        let baseName = page.file.replacingOccurrences(of: "/", with: "__")

        let marked = try renderMarked(image: image, blocks: page.blocks)
        let markedData = try encodeImage(marked, format: .jpeg)
        let markedPath = "marked/\(baseName).jpg"
        try writeFile(markedData, to: options.output.appendingPathComponent(markedPath))

        let prompt = userPrompt(
            for: page, glossary: glossary, context: recentLines[folder] ?? [], sendImage: options.sendImage)
        var result = TranslatedPage(
            file: page.file, elapsedMs: 0, attempts: 0, peak: DeepSeekPricing.isPeak(Date()),
            blocks: page.blocks.map { untranslated($0) }, userPrompt: prompt, markedImage: markedPath)

        if page.blocks.isEmpty {
            print("  没有文字块，跳过")
        } else if options.dryRun {
            // 保存要发送的请求（图片内容省略），并把识别原文当作"译文"，用来检查预览图的排版
            let sample = makeRequest(options, prompt: prompt, image: markedData, omitImage: true)
            try writeFile(sample.jsonData(pretty: true), to: options.output.appendingPathComponent("requests/\(baseName).json"))
            result.blocks = page.blocks.map { block in
                var translated = untranslated(block)
                translated.translation = block.text.replacingOccurrences(of: "\n", with: " ")
                translated.kind = block.text.isEmpty ? "noise" : "dialogue"
                return translated
            }
            print("  已生成")
        } else if let client {
            let request = makeRequest(options, prompt: prompt, image: markedData, omitImage: false)
            let clock = ContinuousClock()
            let start = clock.now
            do {
                let response = try await requestTranslation(client, request)
                result.attempts = response.attempts
                result.usage = response.usage
                result.blocks = merge(page.blocks, with: response.output)
                for term in response.output.newTerms ?? [] where !term.source.isEmpty && !term.translation.isEmpty {
                    if !glossary.contains(where: { $0.source == term.source }) { glossary.append(term) }
                }
                let spoken = result.blocks.filter(\.shouldOverlay).map(\.translation)
                recentLines[folder] = Array(((recentLines[folder] ?? []) + spoken).suffix(12))
            } catch let error as DeepSeekError where error.stopsWholeRun {
                print("")
                throw error
            } catch {
                result.error = error.localizedDescription
            }
            result.elapsedMs = Int((start.duration(to: clock.now) / .milliseconds(1)).rounded())
            if options.model == DeepSeekPricing.pricedModel, let usage = result.usage {
                result.costUSD = DeepSeekPricing.cost(of: usage, peak: result.peak)
            }
            print(result.error.map { "  失败：\($0)" } ?? "  \(result.elapsedMs) ms")
        }

        if result.blocks.contains(where: \.shouldOverlay) {
            let preview = try renderTranslated(image: image, blocks: result.blocks, characterSize: CGFloat(page.characterSize))
            let previewPath = "preview/\(baseName).jpg"
            try writeImage(preview, to: options.output.appendingPathComponent(previewPath), format: .jpeg)
            result.previewImage = previewPath
        }
        results.append(result)
    }

    let run = TranslateRun(
        model: options.model, sendImage: options.sendImage, thinking: options.thinking, dryRun: options.dryRun,
        pages: results, glossary: glossary)
    try writeTranslateReport(run, to: options.output)
    print("完成。报告在 \(options.output.appendingPathComponent("report.html").path)")
}

// 系统提示词保持不变，DeepSeek 会自动缓存相同的开头部分，重复请求更便宜
private let systemPrompt = """
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

private func userPrompt(for page: PageResult, glossary: [GlossaryTerm], context: [String], sendImage: Bool) -> String {
    let language = page.languages.contains { $0.hasPrefix("ko") } ? "韩语" : "日语"
    let order = page.readingOrder == .rightToLeft ? "日漫，从右到左、从上到下" : "条漫，从上到下"
    var lines = ["语言：\(language)；阅读顺序：\(order)"]
    lines.append(glossary.isEmpty ? "术语表：（暂无）" : "术语表：")
    lines += glossary.map { "- \($0.source) → \($0.translation)" }
    if !context.isEmpty {
        lines.append("前文（之前几页的译文，按顺序）：")
        lines += context.map { "- \($0)" }
    }
    if !sendImage {
        lines.append("本次没有附图片：只能根据 OCR 结果翻译，可以按上下文修正明显的错字。")
    }
    lines.append("本页文字块（编号：OCR 结果）：")
    lines += page.blocks.map { block in
        "\(block.id)：" + (block.text.isEmpty ? "（空）" : block.text.replacingOccurrences(of: "\n", with: " / "))
    }
    return lines.joined(separator: "\n")
}

private func makeRequest(_ options: TranslateOptions, prompt: String, image: Data, omitImage: Bool) -> ChatRequest {
    let parts: [ChatRequest.Part] = options.sendImage ? [.text(prompt), .jpeg(image, omitted: omitImage)] : [.text(prompt)]
    return ChatRequest(
        model: options.model,
        messages: [
            .init(role: "system", content: .text(systemPrompt)),
            .init(role: "user", content: .parts(parts)),
        ],
        thinking: .init(type: options.thinking ? "enabled" : "disabled"),
        maxTokens: 4096)
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

/// 发送请求并解析 json；网络错误、限流、空白或不合法的返回最多重试 3 次
private func requestTranslation(
    _ client: DeepSeekClient, _ request: ChatRequest
) async throws -> (output: TranslationOutput, usage: DeepSeekClient.Usage, attempts: Int) {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    var usage = DeepSeekClient.Usage.zero
    var lastError: Error = ProbeError("未知错误")
    for attempt in 1...3 {
        do {
            let reply = try await client.complete(request)
            if let replyUsage = reply.usage { usage = usage.adding(replyUsage) }
            let content = reply.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { throw ProbeError("返回内容为空") }
            return (try decoder.decode(TranslationOutput.self, from: Data(content.utf8)), usage, attempt)
        } catch let error as DeepSeekError where !error.isRetryable {
            throw error
        } catch {
            lastError = error
            if attempt < 3 { try await Task.sleep(for: .seconds(2 * attempt)) }
        }
    }
    throw lastError
}

private func untranslated(_ block: TextBlock) -> TranslatedBlock {
    TranslatedBlock(
        id: block.id, box: block.box, direction: block.direction, ocrText: block.text,
        source: "", translation: "", kind: "missing", characterSize: estimatedCharacterSize(of: block))
}

/// 横排取行高、竖排取列宽的中位数；Vision 的行框比字略大，打九折
private func estimatedCharacterSize(of block: TextBlock) -> Int? {
    let sides = block.lines.map { block.direction == .vertical ? $0.box.width : $0.box.height }.sorted()
    guard !sides.isEmpty else { return nil }
    return Int(Double(sides[sides.count / 2]) * 0.9)
}

private func merge(_ blocks: [TextBlock], with output: TranslationOutput) -> [TranslatedBlock] {
    let items = Dictionary(output.blocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return blocks.map { block in
        var translated = untranslated(block)
        if let item = items[block.id] {
            translated.source = item.source
            translated.translation = item.translation
            translated.kind = item.kind
        }
        return translated
    }
}
