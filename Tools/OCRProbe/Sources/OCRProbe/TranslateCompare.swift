import Foundation
import MangaCore

/// 一种回复写法的汇总。耗时和 token 只统计所有写法都成功的页，免得某种写法失败的页拉低或抬高平均
struct ReplyFormatSummary: Codable {
    var replyFormat: String
    var requested: Int
    var succeeded: Int
    var failed: Int
    /// 成功的页里，重试了的次数（第 2、3 次才成功的各算 1、2 次）
    var retries: Int
    /// 用来比较耗时和 token 的页数（所有写法都成功）
    var comparedPages: Int
    var averageMs: Int
    var medianMs: Int
    var maxMs: Int
    var averageInputTokens: Int
    var averageOutputTokens: Int
    var averageCostUSD: Double?
    /// 模型漏掉的块（没有给这个编号的结果）
    var missingBlocks: Int
    /// 各类型的块数：对白、旁白、拟声词、标题、非剧情
    var kinds: [String: Int]
}

struct ReplyComparison: Codable {
    var summaries: [ReplyFormatSummary]
    var pages: [ComparedPage]
}

struct ComparedPage: Codable {
    struct Variant: Codable {
        var replyFormat: String
        var elapsedMs: Int
        var attempts: Int
        var outputTokens: Int?
        var error: String?
        var previewImage: String?
    }

    struct Block: Codable {
        var id: Int
        var ocrText: String
        /// 每种写法给出的类型和译文，顺序和 summaries 一致
        var kinds: [String]
        var translations: [String]
        /// full 写法里模型核对后的原文
        var source: String
    }

    var file: String
    var variants: [Variant]
    var blocks: [Block]
}

/// 输出 compare.json 和 compare.html：几种回复写法的速度、token、出错情况，以及每块译文并排对照
func writeReplyComparison(_ runs: [TranslateRun], to output: URL) throws {
    let comparison = makeComparison(runs)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try writeFile(encoder.encode(comparison), to: output.appendingPathComponent("compare.json"))
    try writeFile(Data(renderComparisonHTML(comparison, runs: runs).utf8), to: output.appendingPathComponent("compare.html"))
}

private func makeComparison(_ runs: [TranslateRun]) -> ReplyComparison {
    let files = runs.first?.pages.map(\.file) ?? []
    // 所有写法都发了请求并成功的页
    let comparable = Set(files.filter { file in
        runs.allSatisfy { run in run.pages.first { $0.file == file }.map { $0.usage != nil && $0.error == nil } ?? false }
    })

    let summaries = runs.map { run -> ReplyFormatSummary in
        let requested = run.pages.filter { !$0.blocks.isEmpty }
        let succeeded = requested.filter { $0.usage != nil && $0.error == nil }
        let compared = succeeded.filter { comparable.contains($0.file) }
        let times = compared.map(\.elapsedMs).sorted()
        let usages = compared.compactMap(\.usage)
        let costs = compared.compactMap(\.costUSD)
        func average(_ values: [Int]) -> Int { values.isEmpty ? 0 : values.reduce(0, +) / values.count }
        var kinds: [String: Int] = [:]
        for page in succeeded { for block in page.blocks { kinds[block.kind, default: 0] += 1 } }
        return ReplyFormatSummary(
            replyFormat: run.replyFormat, requested: requested.count, succeeded: succeeded.count,
            failed: requested.count - succeeded.count, retries: succeeded.reduce(0) { $0 + max(0, $1.attempts - 1) },
            comparedPages: compared.count, averageMs: average(times), medianMs: times.isEmpty ? 0 : times[times.count / 2],
            maxMs: times.last ?? 0, averageInputTokens: average(usages.map(\.inputTokens)),
            averageOutputTokens: average(usages.map(\.outputTokens)),
            averageCostUSD: costs.isEmpty ? nil : costs.reduce(0, +) / Double(costs.count),
            missingBlocks: kinds["missing"] ?? 0, kinds: kinds)
    }

    let pages = files.map { file -> ComparedPage in
        let variants = runs.compactMap { run in run.pages.first { $0.file == file }.map { (run.replyFormat, $0) } }
        let variantInfo = variants.map { format, page in
            ComparedPage.Variant(
                replyFormat: format, elapsedMs: page.elapsedMs, attempts: page.attempts,
                outputTokens: page.usage?.outputTokens, error: page.error,
                previewImage: page.previewImage.map { "\(format)/\($0)" })
        }
        let first = variants.first?.1.blocks ?? []
        let blocks = first.map { block in
            let matches = variants.map { _, page in page.blocks.first { $0.id == block.id } }
            return ComparedPage.Block(
                id: block.id, ocrText: block.ocrText, kinds: matches.map { $0?.kind ?? "missing" },
                translations: matches.map { $0?.translation ?? "" },
                source: variants.first { $0.0 == ReplyFormat.full.rawValue }?.1.blocks.first { $0.id == block.id }?.source ?? "")
        }
        return ComparedPage(file: file, variants: variantInfo, blocks: blocks)
    }
    return ReplyComparison(summaries: summaries, pages: pages)
}

private let formatNames = [
    "full": "full（现在的写法）", "nosource": "nosource（不抄原文）", "compact": "compact（数组写法）",
    "compact-source": "compact-source（数组写法，照样抄原文）",
]
private let kindNames = [
    "dialogue": "对白", "narration": "旁白", "sfx": "拟声词", "title": "标题大字", "noise": "非剧情", "missing": "模型漏掉",
]

private func renderComparisonHTML(_ comparison: ReplyComparison, runs: [TranslateRun]) -> String {
    func cell(_ text: String) -> String { escapeHTML(text).replacingOccurrences(of: "\n", with: "<br>") }
    let headers = comparison.summaries.map { "<th>\(escapeHTML(formatNames[$0.replyFormat] ?? $0.replyFormat))</th>" }.joined()
    func row(_ title: String, _ value: (ReplyFormatSummary) -> String) -> String {
        "<tr><th>\(title)</th>" + comparison.summaries.map { "<td>\(value($0))</td>" }.joined() + "</tr>"
    }
    let kindOrder = ["dialogue", "narration", "sfx", "title", "noise"]
    let summaryRows = [
        row("成功 / 请求页数") { "\($0.succeeded) / \($0.requested)" },
        row("失败页数") { "\($0.failed)" },
        row("重试次数") { "\($0.retries)" },
        row("参与比较的页数") { "\($0.comparedPages)（所有写法都成功的页）" },
        row("平均耗时") { "\($0.averageMs) ms" },
        row("耗时中位数") { "\($0.medianMs) ms" },
        row("最慢一页") { "\($0.maxMs) ms" },
        row("平均输入 token") { "\($0.averageInputTokens)" },
        row("平均输出 token") { "\($0.averageOutputTokens)" },
        row("平均每页费用") { $0.averageCostUSD.map { String(format: "$%.5f", $0) } ?? "（无价格数据）" },
        row("模型漏掉的块") { "\($0.missingBlocks)" },
        row("各类型块数") { summary in
            kindOrder.map { "\(kindNames[$0]!) \(summary.kinds[$0] ?? 0)" }.joined(separator: "，")
        },
    ].joined(separator: "\n")

    let pageSections = comparison.pages.map { page -> String in
        let meta = page.variants.map { variant in
            let name = escapeHTML(variant.replyFormat)
            if let error = variant.error { return "\(name)：<span class=\"error\">失败：\(escapeHTML(error))</span>" }
            if variant.attempts == 0 { return "\(name)：未请求" }
            let retry = variant.attempts > 1 ? "，第 \(variant.attempts) 次成功" : ""
            let tokens = variant.outputTokens.map { "，输出 \($0) token" } ?? ""
            let preview = variant.previewImage.map { path in
                " <a href=\"\(path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)\" target=\"_blank\">预览</a>"
            } ?? ""
            return "\(name)：\(variant.elapsedMs) ms\(tokens)\(retry)\(preview)"
        }.joined(separator: " · ")
        let rows = page.blocks.map { block -> String in
            // 类型和 full 不一样的格子标出来
            let cells = zip(block.kinds, block.translations).map { kind, translation in
                let differs = kind != block.kinds.first
                let label = kindNames[kind] ?? kind
                return "<td class=\"\(kind)\(differs ? " differs" : "")\"><span class=\"kind\">\(cell(label))</span> \(cell(translation))</td>"
            }.joined()
            return "<tr><td>\(block.id)</td><td>\(cell(block.ocrText))</td><td>\(cell(block.source))</td>\(cells)</tr>"
        }.joined(separator: "\n")
        return """
            <section>
            <h2>\(escapeHTML(page.file))</h2>
            <p class="meta">\(meta)</p>
            <table>
            <thead><tr><th>#</th><th>本地识别</th><th>full 核对后的原文</th>\(headers)</tr></thead>
            <tbody>
            \(rows)
            </tbody>
            </table>
            </section>
            """
    }.joined(separator: "\n")

    let model = runs.first.map { "\(escapeHTML($0.model)) · \(escapeHTML($0.endpoint))" } ?? ""
    return """
        <!doctype html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <title>回复写法对比</title>
        <style>
        body { font-family: -apple-system, "PingFang SC", sans-serif; margin: 24px; color: #222; }
        h2 { margin-top: 36px; font-size: 17px; }
        .meta { color: #666; font-size: 13px; }
        .error { color: #c00; }
        table { border-collapse: collapse; width: 100%; font-size: 14px; margin-top: 10px; }
        th, td { border: 1px solid #ddd; padding: 6px 8px; text-align: left; vertical-align: top; }
        th { background: #f5f5f5; }
        .kind { color: #888; font-size: 12px; }
        td.noise, td.missing { color: #999; }
        td.differs { background: #fff4d6; }
        </style>
        </head>
        <body>
        <h1>回复写法对比</h1>
        <p class="meta">\(model) · 每页按轮换的顺序把各种写法各翻一次；每种写法各自积累术语和前文。黄色格子表示类型和 full 不一样。</p>
        <table>
        <thead><tr><th></th>\(headers)</tr></thead>
        <tbody>
        \(summaryRows)
        </tbody>
        </table>
        <p class="meta">各写法的完整报告（含编号图和译文预览）：\(runs.map { "<a href=\"\($0.replyFormat)/report.html\">\(escapeHTML($0.replyFormat))</a>" }.joined(separator: "、"))</p>
        \(pageSections)
        </body>
        </html>
        """
}
