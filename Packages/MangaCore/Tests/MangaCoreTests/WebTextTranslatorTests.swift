import Foundation
import Testing
@testable import MangaCore

/// 不联网的假客户端：按顺序返回预设的结果，并记下收到的请求
private final class ScriptedClient: LLMClient, @unchecked Sendable {
    let config = LLMServiceConfig(format: .openAICompatible, baseURL: "http://localhost:1", model: "mock")
    let endpoint = URL(string: "http://localhost:1/v1/chat/completions")!
    let apiKey = ""
    private let lock = NSLock()
    private var results: [Result<LLMReply, Error>]
    private(set) var prompts: [LLMPrompt] = []

    init(_ results: [Result<LLMReply, Error>]) { self.results = results }

    func makeURLRequest(_ prompt: LLMPrompt) throws -> URLRequest { URLRequest(url: endpoint) }
    func parseReply(_ data: Data) throws -> LLMReply { LLMReply(content: "", usage: nil) }

    func complete(_ prompt: LLMPrompt) async throws -> LLMReply {
        let next: Result<LLMReply, Error> = lock.withLock {
            prompts.append(prompt)
            return results.removeFirst()
        }
        return try next.get()
    }
}

private actor UsageCollector {
    private(set) var items: [LLMUsage] = []
    func add(_ usage: LLMUsage) { items.append(usage) }
}

struct WebTextTranslatorTests {
    private let translator = WebTextTranslator(retryDelay: .milliseconds(1))

    @Test func 提示词按编号列出原文_换行合并成空格() {
        let prompt = translator.userPrompt(
            texts: ["ログイン", "最新話が\n  無料で読めます"], languageName: "日语",
            glossary: [GlossaryTerm(source: "怪獣8号", translation: "怪兽8号")])
        #expect(prompt.contains("原文语言：多为日语"))
        #expect(prompt.contains("- 怪獣8号 → 怪兽8号"))
        #expect(prompt.contains("1：ログイン\n2：最新話が 無料で読めます"))
        #expect(WebTextTranslator.systemPrompt.contains("json"))
    }

    @Test func 几种回复格式都能解析() throws {
        #expect(try WebTextTranslator.parse(#"{"items":[{"id":1,"text":"登录"},{"id":"2","text":"免费"}]}"#)
            == [1: "登录", 2: "免费"])
        #expect(try WebTextTranslator.parse("```json\n[{\"id\": 1, \"translation\": \"登录\"}]\n```") == [1: "登录"])
        #expect(try WebTextTranslator.parse(#"{"1": "登录", "2": "免费"}"#) == [1: "登录", 2: "免费"])
        #expect(throws: MangaCoreError.self) { try WebTextTranslator.parse("好的，翻译如下：登录") }
        #expect(throws: MangaCoreError.self) { try WebTextTranslator.parse("  ") }
    }

    @Test func 结果按原文顺序返回_漏掉和空白的编号为nil() async throws {
        let content = #"{"items":[{"id":3,"text":"排行榜"},{"id":1,"text":" 登录 "},{"id":2,"text":""}]}"#
        let client = ScriptedClient([.success(LLMReply(content: content, usage: nil))])
        let result = try await translator.translate(
            texts: ["ログイン", "無料", "ランキング", "検索"], languageName: "日语", glossary: [], using: client)
        #expect(result == ["登录", nil, "排行榜", nil])
        #expect(client.prompts.first?.jpeg == nil)
    }

    @Test func 不合法的回复会重试_每次用量都记账() async throws {
        let client = ScriptedClient([
            .success(LLMReply(content: "这不是 json", usage: LLMUsage(inputTokens: 10, outputTokens: 1))),
            .success(LLMReply(content: #"{"items":[{"id":1,"text":"登录"}]}"#, usage: LLMUsage(inputTokens: 10, outputTokens: 2))),
        ])
        let reported = UsageCollector()
        let result = try await translator.translate(
            texts: ["로그인"], languageName: "韩语", glossary: [], using: client, onUsage: { await reported.add($0) })
        #expect(result == ["登录"])
        #expect(client.prompts.count == 2)
        #expect(await reported.items == [LLMUsage(inputTokens: 10, outputTokens: 1), LLMUsage(inputTokens: 10, outputTokens: 2)])
    }

    @Test func 不可重试的错误直接抛出() async {
        let client = ScriptedClient([.failure(LLMServiceError(status: 402, message: "余额不足"))])
        await #expect(throws: LLMServiceError.self) {
            try await translator.translate(texts: ["로그인"], languageName: "韩语", glossary: [], using: client)
        }
        #expect(client.prompts.count == 1)
    }

    @Test func 输出token上限随原文长度增加() {
        let short = translator.maxTokens(for: ["ログイン"])
        let long = translator.maxTokens(for: [String](repeating: String(repeating: "あ", count: 37), count: 40))
        #expect(short == 1024)
        #expect(long > short && long <= 8192)
    }
}
