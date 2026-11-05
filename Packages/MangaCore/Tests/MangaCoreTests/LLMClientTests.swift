import CoreGraphics
import Foundation
import Testing
@testable import MangaCore

struct EndpointTests {
    @Test(arguments: [
        ("https://api.deepseek.com", "https://api.deepseek.com/v1/chat/completions"),
        ("https://api.deepseek.com/", "https://api.deepseek.com/v1/chat/completions"),
        ("https://api.deepseek.com/v1", "https://api.deepseek.com/v1/chat/completions"),
        ("https://api.deepseek.com/v1/", "https://api.deepseek.com/v1/chat/completions"),
        ("https://api.deepseek.com/chat/completions", "https://api.deepseek.com/chat/completions"),
        ("  http://192.168.1.10:11434  ", "http://192.168.1.10:11434/v1/chat/completions"),
        ("192.168.1.10:1234/v1", "http://192.168.1.10:1234/v1/chat/completions"),
        ("localhost:8000", "http://localhost:8000/v1/chat/completions"),
        ("api.example.com/v1", "https://api.example.com/v1/chat/completions"),
        ("https://open.bigmodel.cn/api/paas/v4", "https://open.bigmodel.cn/api/paas/v4/chat/completions"),
        ("https://example.com/v1beta/openai/", "https://example.com/v1beta/openai/chat/completions"),
    ])
    func OpenAI兼容地址拼接(input: String, expected: String) throws {
        #expect(try LLMEndpoint.resolve(input, format: .openAICompatible).absoluteString == expected)
    }

    @Test(arguments: [
        ("https://api.anthropic.com", "https://api.anthropic.com/v1/messages"),
        ("https://api.anthropic.com/", "https://api.anthropic.com/v1/messages"),
        ("https://api.anthropic.com/v1", "https://api.anthropic.com/v1/messages"),
        ("https://api.anthropic.com/v1/messages", "https://api.anthropic.com/v1/messages"),
        ("https://api.deepseek.com/anthropic", "https://api.deepseek.com/anthropic/v1/messages"),
        ("http://127.0.0.1:8765/", "http://127.0.0.1:8765/v1/messages"),
    ])
    func Anthropic地址拼接(input: String, expected: String) throws {
        #expect(try LLMEndpoint.resolve(input, format: .anthropic).absoluteString == expected)
    }

    @Test func 地址填错时报错() {
        #expect(throws: MangaCoreError.self) { try LLMEndpoint.resolve("", format: .openAICompatible) }
        #expect(throws: MangaCoreError.self) { try LLMEndpoint.resolve("ftp://example.com", format: .anthropic) }
    }

    @Test func 局域网地址判断() {
        for host in ["localhost", "127.0.0.1", "192.168.1.10", "10.0.0.2", "172.20.1.1", "my-mac", "nas.local", "::1"] {
            #expect(LLMEndpoint.isLocalHost(host), "\(host)")
        }
        for host in ["api.deepseek.com", "8.8.8.8", "172.32.0.1", "example.local.com"] {
            #expect(!LLMEndpoint.isLocalHost(host), "\(host)")
        }
    }

    @Test func 旧数据缺少字段时用默认值() throws {
        let json = #"{"format":"anthropic","baseURL":"http://localhost:8080","model":"m"}"#
        let config = try JSONDecoder().decode(LLMServiceConfig.self, from: Data(json.utf8))
        #expect(config.supportsImages && config.jsonMode && !config.enableThinking)
        #expect(config.timeoutSeconds == 180)
        #expect(config.isLocalNetwork)
    }

    @Test func DeepSeek预设匹配和价格() {
        let deepSeek = LLMProviderPreset.deepSeek.makeConfig()
        #expect(deepSeek.preset?.id == "deepseek")
        #expect(deepSeek.pricing?.model == "deepseek-flash")

        var otherModel = deepSeek
        otherModel.model = "deepseek-other"
        #expect(otherModel.preset != nil && otherModel.pricing == nil)

        let local = LLMServiceConfig(format: .openAICompatible, baseURL: "http://192.168.1.2:11434", model: "qwen")
        #expect(local.preset == nil && local.pricing == nil)

        // 格式不同不算同一个服务
        var anthropicFormat = deepSeek
        anthropicFormat.format = .anthropic
        #expect(anthropicFormat.preset == nil)
    }

    @Test func 价格按高峰和缓存计算() {
        let usage = LLMUsage(inputTokens: 1_000_000, outputTokens: 1_000_000, cachedInputTokens: 500_000)
        let pricing = LLMPricing.deepSeekFlash
        #expect(abs(pricing.cost(of: usage, peak: false) - (0.0015 + 0.075 + 0.6)) < 1e-9)
        #expect(abs(pricing.cost(of: usage, peak: true) - (0.003 + 0.15 + 1.2)) < 1e-9)
        // 2026-11-04 是周三，UTC 2 点在高峰，UTC 5 点不在
        let peak = ISO8601DateFormatter().date(from: "2026-11-04T02:30:00Z")!
        let offPeak = ISO8601DateFormatter().date(from: "2026-11-04T05:30:00Z")!
        #expect(pricing.isPeak(peak) && !pricing.isPeak(offPeak))
    }
}

struct RequestEncodingTests {
    private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])

    private func json(_ request: URLRequest) throws -> [String: Any] {
        let body = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    @Test func OpenAI兼容_带图片和JSON模式() throws {
        let client = try LLMProviderPreset.deepSeek.makeConfig().makeClient(apiKey: " test-key ")
        let request = try client.makeURLRequest(LLMPrompt(system: "系统", user: "用户", jpeg: jpeg, maxTokens: 4096))
        #expect(request.url?.absoluteString == "https://api.deepseek.com/v1/chat/completions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
        #expect(request.timeoutInterval == 180)

        let body = try json(request)
        #expect(body["model"] as? String == "deepseek-flash")
        #expect(body["max_tokens"] as? Int == 4096)
        #expect(body["max_completion_tokens"] == nil)
        #expect(body["stream"] as? Bool == false)
        #expect((body["response_format"] as? [String: String])?["type"] == "json_object")
        #expect((body["thinking"] as? [String: String])?["type"] == "disabled")

        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[0]["content"] as? String == "系统")
        let parts = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(parts[0]["type"] as? String == "text")
        #expect(parts[0]["text"] as? String == "用户")
        let image = try #require(parts[1]["image_url"] as? [String: String])
        #expect(parts[1]["type"] as? String == "image_url")
        #expect(image["url"] == "data:image/jpeg;base64," + jpeg.base64EncodedString())
        #expect(image["detail"] == "high")
    }

    @Test func OpenAI兼容_本地服务不带Key和DeepSeek参数() throws {
        let config = LLMServiceConfig(
            format: .openAICompatible, baseURL: "http://192.168.1.10:11434/v1", model: "qwen2.5vl",
            jsonMode: false, timeoutSeconds: 600)
        let client = try config.makeClient(apiKey: nil)
        let request = try client.makeURLRequest(LLMPrompt(system: "系统", user: "用户"))
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.timeoutInterval == 600)
        let body = try json(request)
        #expect(body["response_format"] == nil)
        #expect(body["thinking"] == nil)
        // 纯文字时 content 用字符串
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages[1]["content"] as? String == "用户")
    }

    @Test func OpenAI官方用max_completion_tokens() throws {
        let config = LLMServiceConfig(format: .openAICompatible, baseURL: "https://api.openai.com/v1", model: "m")
        let body = try json(try config.makeClient(apiKey: "k").makeURLRequest(LLMPrompt(system: "s", user: "u")))
        #expect(body["max_completion_tokens"] as? Int == 4096)
        #expect(body["max_tokens"] == nil)
    }

    @Test func Anthropic_请求头和请求体() throws {
        let config = LLMServiceConfig(format: .anthropic, baseURL: "https://api.anthropic.com", model: "claude-test")
        let request = try config.makeClient(apiKey: "test-key")
            .makeURLRequest(LLMPrompt(system: "系统", user: "用户", jpeg: jpeg, maxTokens: 4096))
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "test-key")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)

        let body = try json(request)
        #expect(body["model"] as? String == "claude-test")
        #expect(body["max_tokens"] as? Int == 4096)
        #expect(body["system"] as? String == "系统")
        #expect(body["response_format"] == nil && body["thinking"] == nil && body["stream"] == nil)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages[0]["role"] as? String == "user")
        let blocks = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(blocks[0]["type"] as? String == "image")
        let source = try #require(blocks[0]["source"] as? [String: String])
        #expect(source == ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()])
        #expect(blocks[1]["type"] as? String == "text")
        #expect(blocks[1]["text"] as? String == "用户")
    }

    @Test func Anthropic_第三方服务用兼容版本且Key可以为空() throws {
        let config = LLMServiceConfig(format: .anthropic, baseURL: "http://localhost:8765", model: "m")
        let request = try config.makeClient(apiKey: "").makeURLRequest(LLMPrompt(system: "s", user: "u"))
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
        let messages = try json(request)["messages"] as? [[String: Any]]
        let blocks = try #require(messages?.first?["content"] as? [[String: Any]])
        #expect(blocks.count == 1)
    }

    @Test func 请求示例可以省略图片内容() throws {
        let client = try LLMProviderPreset.deepSeek.makeConfig().makeClient(apiKey: "secret-key")
        let body = String(decoding: try client.requestBody(
            LLMPrompt(system: "s", user: "u", jpeg: jpeg, omitsImageData: true)), as: UTF8.self)
        #expect(body.contains("<省略 4 字节的图片>"))
        #expect(!body.contains("secret-key"))
    }
}

struct ReplyParsingTests {
    private let deepSeek = try! LLMProviderPreset.deepSeek.makeConfig().makeClient(apiKey: "k")
    private let anthropic = try! LLMServiceConfig(format: .anthropic, baseURL: "http://localhost:1", model: "m")
        .makeClient(apiKey: "k")

    @Test func OpenAI兼容_DeepSeek缓存用量() throws {
        let data = Data(#"""
            {"choices":[{"message":{"role":"assistant","content":"{\"blocks\":[]}"}}],
             "usage":{"prompt_tokens":1460,"completion_tokens":110,"prompt_cache_hit_tokens":1024,"prompt_cache_miss_tokens":436}}
            """#.utf8)
        let reply = try deepSeek.parseReply(data)
        #expect(reply.content == #"{"blocks":[]}"#)
        #expect(reply.usage == LLMUsage(inputTokens: 1460, outputTokens: 110, cachedInputTokens: 1024))
    }

    @Test func OpenAI兼容_OpenAI缓存字段和没有用量() throws {
        let withDetails = Data(#"""
            {"choices":[{"message":{"content":"hi"}}],"usage":{"prompt_tokens":10,"completion_tokens":2,"prompt_tokens_details":{"cached_tokens":8}}}
            """#.utf8)
        #expect(try deepSeek.parseReply(withDetails).usage == LLMUsage(inputTokens: 10, outputTokens: 2, cachedInputTokens: 8))

        let noUsage = Data(#"{"choices":[{"message":{"content":[{"type":"text","text":"a"},{"type":"text","text":"b"}]}}]}"#.utf8)
        let reply = try deepSeek.parseReply(noUsage)
        #expect(reply.content == "ab")
        #expect(reply.usage == nil)

        #expect(throws: MangaCoreError.self) { try deepSeek.parseReply(Data(#"{"content":[]}"#.utf8)) }
    }

    @Test func Anthropic_只取text块并合计输入() throws {
        let data = Data(#"""
            {"id":"msg_1","type":"message","role":"assistant",
             "content":[{"type":"thinking","thinking":""},{"type":"text","text":"{\"blocks\":"},{"type":"text","text":"[]}"}],
             "stop_reason":"end_turn",
             "usage":{"input_tokens":100,"output_tokens":20,"cache_read_input_tokens":1000,"cache_creation_input_tokens":50}}
            """#.utf8)
        let reply = try anthropic.parseReply(data)
        #expect(reply.content == #"{"blocks":[]}"#)
        #expect(reply.usage == LLMUsage(inputTokens: 1150, outputTokens: 20, cachedInputTokens: 1000))
    }

    @Test func Anthropic_拒绝回答不重试() {
        let data = Data(#"{"content":[],"stop_reason":"refusal","usage":{"input_tokens":1,"output_tokens":0}}"#.utf8)
        #expect {
            try anthropic.parseReply(data)
        } throws: { error in
            (error as? LLMServiceError)?.kind == .refused && (error as? LLMServiceError)?.isRetryable == false
        }
    }

    @Test func 错误信息兼容多种格式并遮住Key() {
        let anthropicError = Data(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#.utf8)
        #expect(LLMServiceError.message(in: anthropicError, hiding: "") == "Overloaded")
        let ollama = Data(#"{"error":"model \"qwen\" not found, try pulling it first"}"#.utf8)
        #expect(LLMServiceError.message(in: ollama, hiding: "").hasPrefix("model \"qwen\" not found"))
        let vllm = Data(#"{"object":"error","message":"bad request","code":400}"#.utf8)
        #expect(LLMServiceError.message(in: vllm, hiding: "") == "bad request")
        let leaked = Data(#"{"error":{"message":"Incorrect API key provided: sk-abc123***wxyz. And my-secret-key-123"}}"#.utf8)
        let message = LLMServiceError.message(in: leaked, hiding: "my-secret-key-123")
        #expect(!message.contains("abc123") && !message.contains("my-secret-key-123"))
    }

    @Test func 错误分类() {
        #expect(LLMServiceError(status: 529, message: "").isRetryable)
        #expect(LLMServiceError(status: 429, message: "").isRetryable)
        #expect(!LLMServiceError(status: 400, message: "").isRetryable)
        #expect(!LLMServiceError(status: 400, message: "").stopsWholeRun)
        #expect(LLMServiceError(status: 404, message: "").stopsWholeRun)
        #expect(LLMServiceError(status: 404, message: "").needsSettings)
        #expect(LLMServiceError(status: 402, message: "").stopsWholeRun)
        #expect(!LLMServiceError(status: 402, message: "").needsSettings)
        #expect(LLMServiceError(kind: .unreachable, message: "").stopsWholeRun)
        #expect(!LLMServiceError(kind: .timedOut, message: "").isRetryable)
        let format = LLMServiceError(status: 400, message: "response_format is not supported")
        #expect(format.localizedDescription.contains("JSON 模式"))
        #expect(!LLMServiceError(status: 500, message: "x").localizedDescription.contains("DeepSeek"))
    }

    @Test func 连不上时给出局域网提示() throws {
        let endpoint = URL(string: "http://192.168.1.10:11434/v1/chat/completions")!
        let unreachable = LLMServiceError.mapping(URLError(.cannotConnectToHost), endpoint: endpoint, timeout: 60)
        let error = try #require(unreachable as? LLMServiceError)
        #expect(error.kind == .unreachable && error.message.contains("本地网络"))
        let lost = LLMServiceError.mapping(URLError(.networkConnectionLost), endpoint: endpoint, timeout: 60)
        #expect(lost is URLError)
    }
}

struct TranslationParsingTests {
    @Test(arguments: [
        #"{"blocks":[{"id":1,"source":"あ","translation":"啊","kind":"dialogue"}],"new_terms":[]}"#,
        "```json\n{\"blocks\":[{\"id\":1,\"source\":\"あ\",\"translation\":\"啊\",\"kind\":\"dialogue\"}]}\n```",
        "<think>先看图……{随便写的}</think>\n{\"blocks\":[{\"id\":\"1\",\"source\":\"あ\",\"translation\":\"啊\"}]}",
        "好的，翻译如下：\n{\"blocks\":[{\"id\":1,\"source\":\"あ\",\"translation\":\"啊\",\"kind\":\"dialogue\"}]}\n希望有帮助。",
        #"[{"id":1,"source":"あ","translation":"啊","kind":"dialogue"}]"#,
    ])
    func 容错解析(content: String) throws {
        let output = try TranslationOutput.parse(content)
        #expect(output.blocks.count == 1)
        #expect(output.blocks[0].id == 1)
        #expect(output.blocks[0].translation == "啊")
        #expect(output.blocks[0].kind == "dialogue")
    }

    @Test func 没有json时报错() {
        #expect(throws: MangaCoreError.self) { try TranslationOutput.parse("   ") }
        #expect(throws: MangaCoreError.self) { try TranslationOutput.parse("对不起，我看不清这张图。") }
        #expect(throws: MangaCoreError.self) { try TranslationOutput.parse("<think>还没想完") }
    }

    @Test func 测试连接的回复检查() {
        #expect(LLMJSON.containsJSON("```json\n{\"ok\": true}\n```"))
        #expect(!LLMJSON.containsJSON("OK"))
    }
}

/// 不联网的假客户端：按顺序返回预设的结果
private final class ScriptedClient: LLMClient, @unchecked Sendable {
    let config = LLMServiceConfig(format: .openAICompatible, baseURL: "http://localhost:1", model: "mock")
    let endpoint = URL(string: "http://localhost:1/v1/chat/completions")!
    let apiKey = ""
    private let lock = NSLock()
    private var results: [Result<LLMReply, Error>]
    private(set) var calls = 0

    init(_ results: [Result<LLMReply, Error>]) { self.results = results }

    func makeURLRequest(_ prompt: LLMPrompt) throws -> URLRequest { URLRequest(url: endpoint) }
    func parseReply(_ data: Data) throws -> LLMReply { LLMReply(content: "", usage: nil) }

    func complete(_ prompt: LLMPrompt) async throws -> LLMReply {
        let next: Result<LLMReply, Error> = lock.withLock {
            calls += 1
            return results.removeFirst()
        }
        return try next.get()
    }
}

private actor UsageCollector {
    private(set) var items: [LLMUsage] = []
    func add(_ usage: LLMUsage) { items.append(usage) }
}

struct PageTranslatorTests {
    private let blocks = [1, 2].map { id in
        TextBlock(
            id: id, box: Box(CGRect(x: 10, y: id * 100, width: 200, height: 50)), direction: .horizontal,
            text: "원문\(id)", confidence: 1, lines: [])
    }

    @Test func 代码块里的json也能翻译_漏掉的编号记为missing() async throws {
        let content = "```json\n{\"blocks\":[{\"id\":1,\"source\":\"원문\",\"translation\":\"原文\",\"kind\":\"dialogue\"}],\"new_terms\":[{\"source\":\"철수\",\"translation\":\"哲洙\"}]}\n```"
        let client = ScriptedClient([.success(LLMReply(content: content, usage: LLMUsage(inputTokens: 5, outputTokens: 3)))])
        let result = try await PageTranslator(sendImage: false)
            .translate(blocks: blocks, prompt: "p", markedImage: Data(), using: client)
        #expect(result.blocks.map(\.translation) == ["原文", ""])
        #expect(result.blocks.map(\.kind) == ["dialogue", "missing"])
        #expect(result.newTerms == [GlossaryTerm(source: "철수", translation: "哲洙")])
        #expect(result.usage == LLMUsage(inputTokens: 5, outputTokens: 3))
        #expect(result.attempts == 1)
    }

    @Test func 不合法的回复会重试_用量累计() async throws {
        let good = #"{"blocks":[{"id":2,"source":"s","translation":"t","kind":"narration"}]}"#
        let client = ScriptedClient([
            .success(LLMReply(content: "这不是 json", usage: LLMUsage(inputTokens: 10, outputTokens: 1))),
            .success(LLMReply(content: good, usage: LLMUsage(inputTokens: 10, outputTokens: 2))),
        ])
        let reported = UsageCollector()
        let result = try await PageTranslator()
            .translate(blocks: blocks, prompt: "p", markedImage: Data(), using: client, onUsage: { await reported.add($0) })
        #expect(result.attempts == 2)
        #expect(result.usage == LLMUsage(inputTokens: 20, outputTokens: 3))
        #expect(result.blocks[1].translation == "t")
        // 解析失败的那次也花了钱，记账回调要收到两次
        #expect(await reported.items == [LLMUsage(inputTokens: 10, outputTokens: 1), LLMUsage(inputTokens: 10, outputTokens: 2)])
    }

    @Test func 不可重试的错误直接抛出() async {
        let client = ScriptedClient([.failure(LLMServiceError(status: 401, message: "bad key"))])
        await #expect(throws: LLMServiceError.self) {
            try await PageTranslator().translate(blocks: blocks, prompt: "p", markedImage: Data(), using: client)
        }
        #expect(client.calls == 1)
    }

    @Test func 不发图片时请求里没有图() {
        let prompt = PageTranslator(sendImage: false).makePrompt(prompt: "p", markedImage: Data([1, 2, 3]))
        #expect(prompt.jpeg == nil)
        #expect(PageTranslator(sendImage: true).makePrompt(prompt: "p", markedImage: Data([1])).jpeg != nil)
    }
}
