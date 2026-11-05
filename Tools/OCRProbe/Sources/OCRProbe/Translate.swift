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

    static let usage = "用法：ocrprobe translate <样本目录> <识别结果目录> <输出目录> [--limit 3] [--text-only] [--thinking] [--dry-run] \(ServiceOptions.usage)"

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
}

struct TranslateRun: Codable, Sendable {
    var format: String
    var endpoint: String
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

    let config = options.service.config
    let endpoint = try config.endpoint()
    // 试运行也要生成请求示例，所以总是建客户端；只有真的发请求时才要 Key
    let client = options.dryRun ? try config.makeClient(apiKey: "") : try options.service.makeClient()
    let pricing = config.pricing
    if options.dryRun {
        print("试运行：只生成要发送的内容，不联网。")
    } else {
        let content = options.sendImage ? "带编号框的图片和识别文字" : "识别文字"
        print("将把 \(pages.count) 页的\(content)发送到 \(endpoint.absoluteString)（\(config.model)）。")
    }

    let translator = PageTranslator(sendImage: options.sendImage)
    var memories: [String: TranslationMemory] = [:]  // 每个文件夹算一部作品，各自积累术语和前文
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

        let memory = memories[folder] ?? TranslationMemory()
        let languageName = page.languages.contains { $0.hasPrefix("ko") } ? "韩语" : "日语"
        let prompt = translator.userPrompt(
            blocks: page.blocks, languageName: languageName, readingOrder: page.readingOrder, memory: memory)
        var result = TranslatedPage(
            file: page.file, elapsedMs: 0, attempts: 0, peak: pricing?.isPeak(Date()) ?? false,
            blocks: page.blocks.map { TranslatedBlock(untranslated: $0) }, userPrompt: prompt, markedImage: markedPath)

        if page.blocks.isEmpty {
            print("  没有文字块，跳过")
        } else if options.dryRun {
            // 保存要发送的请求（图片内容省略），并把识别原文当作"译文"，用来检查预览图的排版
            let sample = translator.makePrompt(prompt: prompt, markedImage: markedData, omitImage: true)
            try writeFile(prettyJSON(try client.requestBody(sample)), to: options.output.appendingPathComponent("requests/\(baseName).json"))
            result.blocks = page.blocks.map(TranslatedBlock.dryRun)
            print("  已生成")
        } else {
            let clock = ContinuousClock()
            let start = clock.now
            do {
                let translation = try await translator.translate(
                    blocks: page.blocks, prompt: prompt, markedImage: markedData, using: client)
                result.attempts = translation.attempts
                result.usage = translation.usage
                result.blocks = translation.blocks
                memories[folder, default: TranslationMemory()].record(translation)
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
        format: config.format.rawValue, endpoint: endpoint.absoluteString, model: config.model,
        sendImage: options.sendImage, thinking: config.enableThinking && config.preset != nil, dryRun: options.dryRun,
        pages: results, glossary: memories.keys.sorted().flatMap { memories[$0]!.glossary })
    try writeTranslateReport(run, to: options.output)
    print("完成。报告在 \(options.output.appendingPathComponent("report.html").path)")
}

/// 请求示例按缩进、键名排序保存，方便核对
private func prettyJSON(_ data: Data) throws -> Data {
    let object = try JSONSerialization.jsonObject(with: data)
    return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
}
