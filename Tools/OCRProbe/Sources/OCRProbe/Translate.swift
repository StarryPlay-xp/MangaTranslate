import CoreGraphics
import Foundation
import MangaCore

struct TranslateOptions {
    var samples: URL
    /// OCRProbe run 的输出目录，读取其中的 results.json
    var probe: URL
    var output: URL
    var service = ServiceOptions()
    var limit: Int?
    var sendImage = true
    /// 只生成要发送的内容，不联网、不需要 API Key
    var dryRun = false
    /// 模型回复的写法；写多个时每页轮流用各种写法各翻一次，生成对比报告
    var replyFormats: [ReplyFormat] = [.full]
    /// 流式请求：记录首字时间和第一块译文出来的时间（和 App 的自动翻译一样，但不对冲）
    var stream = false

    static let usage = "用法：ocrprobe translate <样本目录> <识别结果目录> <输出目录> [--limit 3] [--text-only] [--thinking] [--dry-run] [--reply-format full|nosource|compact|compact-source，逗号分隔可写多个] [--stream] \(ServiceOptions.usage)"

    init(parsing args: [String]) throws {
        var positional: [String] = []
        var iterator = try service.parse(args).makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--limit":
                guard let value = iterator.next().flatMap({ Int($0) }), value > 0 else {
                    throw ProbeError("--limit 后面要跟一个正整数，例如 3")
                }
                limit = value
            case "--text-only": sendImage = false
            case "--thinking": service.config.enableThinking = true
            case "--dry-run": dryRun = true
            case "--stream": stream = true
            case "--reply-format":
                let names = (iterator.next() ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                let formats = names.compactMap(ReplyFormat.init(rawValue:))
                guard !formats.isEmpty, formats.count == names.count else {
                    throw ProbeError("--reply-format 只能是 full、nosource、compact、compact-source，可以用逗号写多个，例如 full,compact-source")
                }
                replyFormats = formats.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
            default: positional.append(arg)
            }
        }
        guard positional.count == 3 else { throw ProbeError(Self.usage) }
        if !service.config.supportsImages { sendImage = false }
        samples = URL(fileURLWithPath: positional[0])
        probe = URL(fileURLWithPath: positional[1])
        output = URL(fileURLWithPath: positional[2])
    }
}

struct TranslatedPage: Codable, Sendable {
    var file: String
    var elapsedMs: Int
    var attempts: Int
    var peak: Bool
    var usage: LLMUsage?
    /// 只有知道价格的模型（目前是 deepseek-flash）才估算
    var costUSD: Double?
    var blocks: [TranslatedBlock]
    var userPrompt: String
    var markedImage: String
    var previewImage: String?
    var error: String?
    /// 流式请求时：从发出到收到第一个字、到取出第一块完整译文
    var firstTokenMs: Int?
    var firstBlockMs: Int?
    /// 终端里这一页后面显示的说明，不写进报告
    var note: String?

    enum CodingKeys: String, CodingKey {
        case file, elapsedMs, attempts, peak, usage, costUSD, blocks, userPrompt, markedImage, previewImage, error
        case firstTokenMs, firstBlockMs
    }
}

struct TranslateRun: Codable, Sendable {
    var format: String
    /// 模型回复的写法（ReplyFormat）
    var replyFormat: String
    var endpoint: String
    var model: String
    var sendImage: Bool
    var thinking: Bool
    var dryRun: Bool
    var stream = false
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

    let config = options.service.config
    let endpoint = try config.endpoint()
    // 试运行也要生成请求示例，所以总是建客户端；只有真的发请求时才要 Key
    let client = options.dryRun ? try config.makeClient(apiKey: "") : try options.service.makeClient()
    let formats = options.replyFormats
    // 对比几种写法时，每种写法的报告放在各自的子目录里，编号图共用一份
    let comparing = formats.count > 1
    if options.dryRun {
        print("试运行：只生成要发送的内容，不联网。")
    } else {
        let content = options.sendImage ? "带编号框的图片和识别文字" : "识别文字"
        let times = comparing ? "，每页按 \(formats.map(\.rawValue).joined(separator: "、")) 各翻一次（共 \(pages.count * formats.count) 次请求）" : ""
        print("将把 \(pages.count) 页的\(content)发送到 \(endpoint.absoluteString)（\(config.model)）\(times)。")
    }

    // 每种写法、每个文件夹（一部作品）各自积累术语和前文
    var memories: [ReplyFormat: [String: TranslationMemory]] = [:]
    var results: [ReplyFormat: [TranslatedPage]] = [:]
    let context = PageContext(options: options, client: client, pricing: config.pricing)

    for (index, page) in pages.enumerated() {
        print("[\(index + 1)/\(pages.count)] \(page.file)", terminator: "")
        let folder = page.file.split(separator: "/").dropLast().joined(separator: "/")
        let image = try loadImage(at: options.samples.appendingPathComponent(page.file))
        let baseName = page.file.replacingOccurrences(of: "/", with: "__")
        let marked = try renderMarked(image: image, blocks: page.blocks)
        let markedData = try MarkedImage.encode(marked)
        let markedPath = "marked/\(baseName).jpg"
        try writeFile(markedData, to: options.output.appendingPathComponent(markedPath))

        // 每页换一个先后顺序，免得某种写法总是第一个发、总碰上同样的网络状况
        let order = formats.indices.map { formats[($0 + index) % formats.count] }
        var notes: [String] = []
        for format in order {
            let output = comparing ? options.output.appendingPathComponent(format.rawValue) : options.output
            let memory = memories[format]?[folder] ?? TranslationMemory()
            let (result, translation) = try await context.translate(
                page, image: image, markedData: markedData, markedPath: comparing ? "../" + markedPath : markedPath,
                baseName: baseName, format: format, memory: memory, output: output)
            if let translation { memories[format, default: [:]][folder, default: TranslationMemory()].record(translation) }
            results[format, default: []].append(result)
            notes.append(result.note.map { comparing ? "\(format.rawValue) \($0)" : $0 } ?? "")
        }
        print("  " + notes.filter { !$0.isEmpty }.joined(separator: " · "))
    }

    var runs: [TranslateRun] = []
    for format in formats {
        let run = TranslateRun(
            format: config.format.rawValue, replyFormat: format.rawValue, endpoint: endpoint.absoluteString,
            model: config.model, sendImage: options.sendImage, thinking: config.enableThinking && config.preset != nil,
            dryRun: options.dryRun, stream: options.stream, pages: results[format] ?? [],
            glossary: (memories[format] ?? [:]).keys.sorted().flatMap { memories[format]![$0]!.glossary })
        try writeTranslateReport(run, to: comparing ? options.output.appendingPathComponent(format.rawValue) : options.output)
        runs.append(run)
    }
    if comparing {
        try writeReplyComparison(runs, to: options.output)
        print("完成。对比报告在 \(options.output.appendingPathComponent("compare.html").path)")
    } else {
        print("完成。报告在 \(options.output.appendingPathComponent("report.html").path)")
    }
}

/// 翻译一页要用到的固定参数
private struct PageContext {
    var options: TranslateOptions
    var client: any LLMClient
    var pricing: LLMPricing?

    /// 用一种回复写法翻译一页，返回报告里的一页和成功时的翻译结果（用来积累术语和前文）
    func translate(
        _ page: PageResult, image: CGImage, markedData: Data, markedPath: String, baseName: String,
        format: ReplyFormat, memory: TranslationMemory, output: URL
    ) async throws -> (TranslatedPage, PageTranslation?) {
        let translator = PageTranslator(sendImage: options.sendImage, replyFormat: format)
        let languageName = page.languages.contains { $0.hasPrefix("ko") } ? "韩语" : "日语"
        let prompt = translator.userPrompt(
            blocks: page.blocks, languageName: languageName, readingOrder: page.readingOrder, memory: memory)
        var result = TranslatedPage(
            file: page.file, elapsedMs: 0, attempts: 0, peak: pricing?.isPeak(Date()) ?? false,
            blocks: page.blocks.map { TranslatedBlock(untranslated: $0) }, userPrompt: prompt, markedImage: markedPath)
        var translation: PageTranslation?

        if page.blocks.isEmpty {
            result.note = "没有文字块，跳过"
        } else if options.dryRun {
            // 保存要发送的请求（图片内容省略），并把识别原文当作"译文"，用来检查预览图的排版
            let sample = translator.makePrompt(prompt: prompt, markedImage: markedData, omitImage: true)
            try writeFile(prettyJSON(try client.requestBody(sample)), to: output.appendingPathComponent("requests/\(baseName).json"))
            result.blocks = page.blocks.map(TranslatedBlock.dryRun)
            result.note = "已生成"
        } else {
            let clock = ContinuousClock()
            let start = clock.now
            let firstBlock = FirstMoment()
            let streaming = options.stream
                ? StreamingOptions(onPartial: { _ in await firstBlock.mark(clock.now - start) }) : nil
            do {
                let done = try await translator.translate(
                    blocks: page.blocks, prompt: prompt, markedImage: markedData, using: client, streaming: streaming)
                result.firstTokenMs = done.firstToken.map(milliseconds)
                result.firstBlockMs = await firstBlock.value.map(milliseconds)
                result.attempts = done.attempts
                result.usage = done.usage
                result.blocks = done.blocks
                translation = done
            } catch let error as LLMServiceError where error.stopsWholeRun {
                print("")
                throw error
            } catch {
                result.error = error.localizedDescription
            }
            result.elapsedMs = Int((start.duration(to: clock.now) / .milliseconds(1)).rounded())
            if let pricing, let usage = result.usage {
                result.costUSD = pricing.cost(of: usage, peak: result.peak)
            }
            let firstToken = result.firstTokenMs.map { "（首字 \($0) ms）" } ?? ""
            result.note = result.error.map { "失败：\($0)" } ?? "\(result.elapsedMs) ms\(firstToken)"
        }

        if result.blocks.contains(where: \.shouldOverlay) {
            let preview = try renderTranslated(image: image, blocks: result.blocks, characterSize: CGFloat(page.characterSize))
            let previewPath = "preview/\(baseName).jpg"
            try writeImage(preview, to: output.appendingPathComponent(previewPath), format: .jpeg)
            result.previewImage = previewPath
        }
        return (result, translation)
    }
}

/// 流式请求里第一次发生某件事的时间
private actor FirstMoment {
    private(set) var value: Duration?
    func mark(_ duration: Duration) { if value == nil { value = duration } }
}

private func milliseconds(_ duration: Duration) -> Int {
    Int((duration / .milliseconds(1)).rounded())
}

/// 请求示例按缩进、键名排序保存，方便核对
private func prettyJSON(_ data: Data) throws -> Data {
    let object = try JSONSerialization.jsonObject(with: data)
    return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
}
