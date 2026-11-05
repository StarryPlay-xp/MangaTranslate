import Foundation

/// 网页文字翻译：把同一个网页上的一批短文字（菜单、按钮、作品名、简介、评论）翻成简体中文。
/// 和漫画翻译共用模型服务、术语表和记账，但不发图片
public struct WebTextTranslator: Sendable {
    /// 每次请求最多带多少段、多少字，太长的回复容易被截断或超时
    public static let maxItemsPerRequest = 40
    public static let maxCharactersPerRequest = 1500

    /// 解析失败、限流时第一次重试前等多久，之后每次多等一倍
    public var retryDelay: Duration

    public init(retryDelay: Duration = .seconds(2)) {
        self.retryDelay = retryDelay
    }

    // 系统提示词保持不变：DeepSeek 等服务会自动缓存相同的开头部分，重复请求更便宜
    public static let systemPrompt = """
        你是网页翻译助手，负责把日语、韩语网页上的文字翻译成自然、简洁的简体中文，让不懂日语和韩语的读者看懂网站。

        每次你会收到同一个网页上的若干段文字，每段前面有编号，按在页面上出现的顺序排列。它们来自网站的菜单、按钮、作品名、简介、公告和评论，可以结合前后文理解。

        翻译要求：
        1. 菜单、按钮、标签译成中文网站上常见的说法，简短为主，例如「ログイン」译成「登录」，「무료」译成「免费」。
        2. 作品名、人名等专有名词沿用术语表的译法；术语表里没有的，有通行中文译名就用通行译名，没有就意译或音译。
        3. 已经是简体中文的文字，以及网址、邮箱、代码、纯数字和日期，原样返回。
        4. 只输出译文本身，不要添加解释、注音、引号或原文，也不要合并、拆分编号。

        只输出 json，不要输出任何解释。每个编号都要出现且只出现一次，格式如下：
        {"items": [{"id": 1, "text": "中文译文"}]}
        """

    /// 编号从 1 开始，与 texts 的顺序一致；原文里的换行换成空格
    public func userPrompt(texts: [String], languageName: String, glossary: [GlossaryTerm]) -> String {
        var lines = ["原文语言：多为\(languageName)"]
        lines.append(glossary.isEmpty ? "术语表：（暂无）" : "术语表：")
        lines += glossary.map { "- \($0.source) → \($0.translation)" }
        lines.append("待翻译的文字（编号：原文）：")
        for (index, text) in texts.enumerated() {
            lines.append("\(index + 1)：" + Self.singleLine(text))
        }
        return lines.joined(separator: "\n")
    }

    /// 估计需要的输出 token：中文译文大约每个原文字符 1.5 个 token，再留出 json 的格式开销
    func maxTokens(for texts: [String]) -> Int {
        let characters = texts.reduce(0) { $0 + $1.count }
        return min(max(Int(Double(characters) * 1.5) + texts.count * 12 + 256, 1024), 8192)
    }

    /// 翻译一批文字，返回和 texts 一一对应的译文；模型漏掉的编号为 nil。
    /// 网络错误、限流、空白或不合法的回复最多重试 3 次；onUsage 在每次收到带用量的回复后调用，用来记账
    public func translate(
        texts: [String], languageName: String, glossary: [GlossaryTerm], using client: any LLMClient,
        onUsage: (@Sendable (LLMUsage) async -> Void)? = nil
    ) async throws -> [String?] {
        guard !texts.isEmpty else { return [] }
        let prompt = LLMPrompt(
            system: Self.systemPrompt,
            user: userPrompt(texts: texts, languageName: languageName, glossary: glossary),
            maxTokens: maxTokens(for: texts))
        var lastError: Error = MangaCoreError("未知错误")
        for attempt in 1...3 {
            do {
                let reply = try await client.complete(prompt)
                if let usage = reply.usage { await onUsage?(usage) }
                let output = try Self.parse(reply.content)
                return texts.indices.map { index in
                    output[index + 1].flatMap { text in
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        return trimmed.isEmpty ? nil : trimmed
                    }
                }
            } catch let error as LLMServiceError where !error.isRetryable {
                throw error
            } catch {
                lastError = error
                if attempt < 3 { try await Task.sleep(for: retryDelay * attempt) }
            }
        }
        throw lastError
    }

    /// 容错解析：{"items": [{"id", "text"}]}、直接返回的数组，以及 {"1": "…"} 这样按编号的对象都能识别
    static func parse(_ content: String) throws -> [Int: String] {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MangaCoreError("返回内容为空")
        }
        for candidate in LLMJSON.candidates(in: content) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(candidate.utf8)) else { continue }
            if let dictionary = object as? [String: Any] {
                if let items = (dictionary["items"] ?? dictionary["translations"]) as? [Any],
                   let result = parseItems(items) {
                    return result
                }
                let numbered = dictionary.compactMap { key, value -> (Int, String)? in
                    guard let id = Int(key), let text = value as? String else { return nil }
                    return (id, text)
                }
                if !numbered.isEmpty { return Dictionary(numbered, uniquingKeysWith: { first, _ in first }) }
            } else if let items = object as? [Any], let result = parseItems(items) {
                return result
            }
        }
        throw MangaCoreError("返回的内容里没有找到有效的 json")
    }

    /// 每项要有 id（数字或数字字符串）和 text（也接受 translation）
    private static func parseItems(_ items: [Any]) -> [Int: String]? {
        var result: [Int: String] = [:]
        for case let item as [String: Any] in items {
            let id = (item["id"] as? Int) ?? (item["id"] as? String).flatMap { Int($0) }
            guard let id, let text = (item["text"] ?? item["translation"]) as? String else { continue }
            if result[id] == nil { result[id] = text }
        }
        return result.isEmpty ? nil : result
    }

    /// 网页里的换行和连续空白在显示时本来就会合并成一个空格
    public static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
