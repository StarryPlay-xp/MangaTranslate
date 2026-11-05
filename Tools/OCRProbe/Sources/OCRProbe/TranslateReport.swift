import Foundation
import MangaCore

/// 输出 results.json、glossary.json 和 report.html
func writeTranslateReport(_ run: TranslateRun, to output: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try writeFile(encoder.encode(run), to: output.appendingPathComponent("results.json"))
    try writeFile(encoder.encode(run.glossary), to: output.appendingPathComponent("glossary.json"))
    try writeFile(Data(renderTranslateHTML(run).utf8), to: output.appendingPathComponent("report.html"))
}

private func renderTranslateHTML(_ run: TranslateRun) -> String {
    let requested = run.pages.filter { $0.usage != nil }
    let failed = run.pages.filter { $0.error != nil }
    let usage = requested.compactMap(\.usage).reduce(LLMUsage.zero) { $0.adding($1) }
    let costs = requested.compactMap(\.costUSD)
    let totalCost = costs.reduce(0, +)
    let averageMs = requested.isEmpty ? 0 : requested.reduce(0) { $0 + $1.elapsedMs } / requested.count

    var summary: [String] = []
    if run.dryRun {
        summary.append("<p class=\"warn\">试运行：没有联网，“译文”一栏显示的是识别原文，只用来检查发送内容和预览排版。</p>")
    } else {
        let mode = (run.sendImage ? "图片 + 识别文字" : "仅识别文字") + (run.thinking ? "，开启思考" : "")
        summary.append("<p>模型 \(escapeHTML(run.model))（\(mode)） · \(escapeHTML(run.endpoint)) · 共 \(run.pages.count) 页，成功 \(requested.count) 页，失败 \(failed.count) 页 · 成功页平均 \(averageMs) ms</p>")
        let cached = usage.cachedInputTokens.map { "（其中缓存命中 \($0)）" } ?? ""
        summary.append("<p>token：输入 \(usage.inputTokens)\(cached) · 输出 \(usage.outputTokens)</p>")
        if !costs.isEmpty {
            summary.append(String(
                format: "<p>估算费用：共 $%.4f，平均每页 $%.5f（按 %@ 官方价，有高峰价的按请求时间计算；成功页的重试已计入，失败页没有计入）</p>",
                totalCost, totalCost / Double(costs.count), escapeHTML(run.model)))
        } else if !requested.isEmpty {
            summary.append("<p>这个模型没有价格数据，只统计 token，不估算费用。</p>")
        }
    }
    if !run.glossary.isEmpty {
        let terms = run.glossary.map { "\(escapeHTML($0.source)) → \(escapeHTML($0.translation))" }
        summary.append("<p>本次积累的术语：\(terms.joined(separator: "，"))</p>")
    }

    return """
        <!doctype html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <title>翻译验证报告</title>
        <style>
        body { font-family: -apple-system, "PingFang SC", sans-serif; margin: 24px; color: #222; }
        h2 { margin-top: 40px; font-size: 18px; }
        .meta { color: #666; font-size: 13px; }
        .warn { color: #b45309; }
        .error { color: #c00; }
        .images { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1fr); gap: 16px; }
        .images img { width: 100%; border: 1px solid #ddd; }
        .images figcaption { font-size: 13px; color: #666; margin-bottom: 4px; }
        figure { margin: 0; }
        table { border-collapse: collapse; width: 100%; font-size: 14px; margin-top: 12px; }
        th, td { border: 1px solid #ddd; padding: 6px 8px; text-align: left; vertical-align: top; }
        th { background: #f5f5f5; }
        tr.noise td, tr.missing td { color: #999; }
        </style>
        </head>
        <body>
        <h1>翻译验证报告</h1>
        \(summary.joined(separator: "\n"))
        \(run.pages.map(renderTranslatedPage).joined(separator: "\n"))
        </body>
        </html>
        """
}

private func renderTranslatedPage(_ page: TranslatedPage) -> String {
    func figure(_ path: String?, _ caption: String) -> String {
        guard let path else { return "<figure><figcaption>\(caption)</figcaption><p class=\"meta\">（无）</p></figure>" }
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return "<figure><figcaption>\(caption)</figcaption><a href=\"\(encoded)\" target=\"_blank\"><img src=\"\(encoded)\" alt=\"\"></a></figure>"
    }
    let kindNames = ["dialogue": "对白", "narration": "旁白", "sfx": "拟声词", "noise": "非剧情", "missing": "模型漏掉"]
    let rows = page.blocks.map { block in
        func cell(_ text: String) -> String { escapeHTML(text).replacingOccurrences(of: "\n", with: "<br>") }
        return "<tr class=\"\(block.kind)\"><td>\(block.id)</td><td>\(kindNames[block.kind] ?? cell(block.kind))</td><td>\(cell(block.ocrText))</td><td>\(cell(block.source))</td><td>\(cell(block.translation))</td></tr>"
    }

    var meta = ["耗时 \(page.elapsedMs) ms", page.peak ? "高峰时段" : "闲时"]
    if page.attempts > 1 { meta.append("重试后第 \(page.attempts) 次成功") }
    if let usage = page.usage { meta.append("输入 \(usage.inputTokens) / 输出 \(usage.outputTokens) token") }
    if let cost = page.costUSD { meta.append(String(format: "约 $%.5f", cost)) }

    return """
        <section>
        <h2>\(escapeHTML(page.file))</h2>
        <p class="meta">\(meta.joined(separator: " · "))</p>
        \(page.error.map { "<p class=\"error\">失败：\(escapeHTML($0))</p>" } ?? "")
        <div class="images">
        \(figure(page.markedImage, "发送给模型的图"))
        \(figure(page.previewImage, "译文预览（模拟 App 显示效果）"))
        </div>
        <table>
        <thead><tr><th>#</th><th>类型</th><th>本地识别</th><th>模型核对后的原文</th><th>译文</th></tr></thead>
        <tbody>
        \(rows.joined(separator: "\n"))
        </tbody>
        </table>
        <details><summary class="meta">发送的文字提示</summary><pre>\(escapeHTML(page.userPrompt))</pre></details>
        </section>
        """
}
