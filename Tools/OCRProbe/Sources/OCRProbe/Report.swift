import Foundation

/// 输出 results.json（下一步发给 DeepSeek 时使用）和 report.html（人工查看）
func writeReport(_ pages: [PageResult], to output: URL) throws {
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(pages).write(to: output.appendingPathComponent("results.json"))
    try renderHTML(pages).write(to: output.appendingPathComponent("report.html"), atomically: true, encoding: .utf8)
}

private func renderHTML(_ pages: [PageResult]) -> String {
    let blockCount = pages.reduce(0) { $0 + $1.blocks.count }
    let emptyCount = pages.reduce(0) { total, page in total + page.blocks.filter { $0.text.isEmpty }.count }
    let averageMs = pages.isEmpty ? 0 : pages.reduce(0) { $0 + $1.elapsedMs } / pages.count
    return """
        <!doctype html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <title>文字识别验证报告</title>
        <style>
        body { font-family: -apple-system, "PingFang SC", sans-serif; margin: 24px; color: #222; }
        h2 { margin-top: 40px; font-size: 18px; }
        .meta { color: #666; font-size: 13px; }
        .legend span { display: inline-block; margin-right: 16px; padding-left: 6px; border-left: 4px solid; }
        .page { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1fr); gap: 20px; align-items: start; }
        .page img { width: 100%; border: 1px solid #ddd; }
        table { border-collapse: collapse; width: 100%; font-size: 14px; }
        th, td { border: 1px solid #ddd; padding: 6px 8px; text-align: left; vertical-align: top; }
        th { background: #f5f5f5; }
        .miss { color: #c00; }
        </style>
        </head>
        <body>
        <h1>文字识别验证报告</h1>
        <p>共 \(pages.count) 页 · 文字块 \(blockCount) 个（其中 \(emptyCount) 个只检测到位置、没认出字） · 平均每页 \(averageMs) ms</p>
        <p class="legend">
        <span style="border-color:#00b34d">绿框 + 编号：文字块（App 里每块对应一处译文）</span>
        <span style="border-color:#e61a1a">红框 + 编号：检测到文字但没认出内容</span>
        <span style="border-color:#1a66ff">蓝框：识别出文字的行</span>
        <span style="border-color:#ff8c00">橙框：检测到的文字区域</span>
        </p>
        \(pages.map(renderPage).joined(separator: "\n"))
        </body>
        </html>
        """
}

private func renderPage(_ page: PageResult) -> String {
    let order = page.readingOrder == .rightToLeft ? "从右到左" : "从左到右"
    let imagePath = page.annotatedImage.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? page.annotatedImage
    let rows = page.blocks.map { block in
        let text = block.text.isEmpty
            ? "<span class=\"miss\">（没认出字）</span>"
            : escapeHTML(block.text).replacingOccurrences(of: "\n", with: "<br>")
        let direction = block.direction == .vertical ? "竖排" : "横排"
        let confidence = block.confidence.map { String(format: "%.2f", $0) } ?? "—"
        return "<tr><td>\(block.id)</td><td>\(direction)</td><td>\(text)</td><td>\(confidence)</td></tr>"
    }
    return """
        <section>
        <h2>\(escapeHTML(page.file))</h2>
        <p class="meta">语言 \(page.languages.joined(separator: ", ")) · 阅读顺序 \(order) · \(page.width)×\(page.height) · 耗时 \(page.elapsedMs) ms · 单字约 \(page.characterSize) px · 文字区域 \(page.regionCount) · 识别行 \(page.lineCount) · 文字块 \(page.blocks.count)</p>
        <div class="page">
        <a href="\(imagePath)" target="_blank"><img src="\(imagePath)" alt=""></a>
        <table>
        <thead><tr><th>#</th><th>方向</th><th>识别结果</th><th>置信度</th></tr></thead>
        <tbody>
        \(rows.joined(separator: "\n"))
        </tbody>
        </table>
        </div>
        </section>
        """
}

func escapeHTML(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}
