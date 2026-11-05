import CoreGraphics
import Foundation
import Testing
@testable import MangaCore

struct StreamParsingTests {
    @Test func SSE只取data行() {
        var parser = SSELineParser()
        #expect(parser.data(in: ": keep-alive") == nil)
        #expect(parser.data(in: "event: message_start") == nil)
        #expect(parser.data(in: #"data: {"a":1}"#) == #"{"a":1}"#)
        #expect(parser.data(in: #"data:{"b":2}"#) == #"{"b":2}"#)
        #expect(!parser.isDone)
        #expect(parser.data(in: "data: [DONE]") == nil)
        #expect(parser.isDone)
    }

    @Test func OpenAI兼容格式的流式数据() throws {
        let client = OpenAICompatibleClient(
            config: LLMServiceConfig(format: .openAICompatible, baseURL: "https://api.deepseek.com", model: "deepseek-flash"),
            endpoint: URL(string: "https://api.deepseek.com/v1/chat/completions")!, apiKey: "k")
        let text = #"{"choices":[{"index":0,"delta":{"content":"{\"blocks\""}}]}"#
        #expect(try client.parseStreamChunk(Data(text.utf8)) == [.text(#"{"blocks""#)])
        let usage = #"{"choices":[],"usage":{"prompt_tokens":1500,"completion_tokens":300,"prompt_cache_hit_tokens":600}}"#
        #expect(try client.parseStreamChunk(Data(usage.utf8)) == [.usage(input: 1500, output: 300, cached: 600)])
        // 流式请求要打开 stream 并要求附上用量
        let body = try #require(try client.makeStreamingURLRequest(LLMPrompt(system: "s", user: "u")).httpBody)
        let json = String(decoding: body, as: UTF8.self)
        #expect(json.contains(#""stream":true"#))
        #expect(json.contains(#""stream_options":{"include_usage":true}"#))
        let plain = String(decoding: try #require(try client.makeURLRequest(LLMPrompt(system: "s", user: "u")).httpBody), as: UTF8.self)
        #expect(plain.contains(#""stream":false"#) && !plain.contains("stream_options"))
    }

    @Test func Anthropic格式的流式数据() throws {
        let client = AnthropicClient(
            config: LLMServiceConfig(format: .anthropic, baseURL: "https://api.anthropic.com", model: "m"),
            endpoint: URL(string: "https://api.anthropic.com/v1/messages")!, apiKey: "k")
        func parse(_ text: String) throws -> [LLMStreamEvent] { try client.parseStreamChunk(Data(text.utf8)) }
        #expect(try parse(#"{"type":"message_start","message":{"usage":{"input_tokens":100,"cache_read_input_tokens":50,"output_tokens":1}}}"#)
            == [.usage(input: 150, output: 1, cached: 50)])
        #expect(try parse(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"你好"}}"#) == [.text("你好")])
        #expect(try parse(#"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"想"}}"#).isEmpty)
        #expect(try parse(#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":42}}"#)
            == [.usage(input: nil, output: 42, cached: nil)])
        #expect(try parse(#"{"type":"ping"}"#).isEmpty)
        #expect(throws: LLMServiceError.self) { try parse(#"{"type":"message_delta","delta":{"stop_reason":"refusal"}}"#) }
        do {
            _ = try parse(#"{"type":"error","error":{"type":"overloaded_error","message":"busy"}}"#)
            Issue.record("应该抛出过载错误")
        } catch let error as LLMServiceError {
            #expect(error.status == 529 && error.isRetryable)
        }
    }

    @Test func 用量分两次给时合并() {
        var builder = StreamedReplyBuilder()
        builder.add(.usage(input: 150, output: 1, cached: 50))
        builder.add(.text("ab"))
        builder.add(.text("c"))
        builder.add(.usage(input: nil, output: 42, cached: nil))
        #expect(builder.reply.content == "abc")
        #expect(builder.reply.usage == LLMUsage(inputTokens: 150, outputTokens: 42, cachedInputTokens: 50))
        #expect(StreamedReplyBuilder().reply.usage == nil)
    }

    /// 按 1～7 个字符切开，模拟逐段到达
    private func chunks(_ text: String) -> [String] {
        var result: [String] = []
        var rest = Substring(text)
        var size = 1
        while !rest.isEmpty {
            result.append(String(rest.prefix(size)))
            rest = rest.dropFirst(size)
            size = size % 7 + 1
        }
        return result
    }

    @Test func 边收边解析逐块取出() {
        let reply = "```json\n" + #"{"blocks": [{"id": 1, "source": "「行くぞ}」", "translation": "说\"走\"{吧", "kind": "dialogue"}, {"id": 2, "source": "", "translation": "", "kind": "noise"}], "new_terms": [{"source": "a", "translation": "b"}]}"# + "\n```"
        var parser = PartialBlocksParser()
        var counts: [Int] = []
        for piece in chunks(reply) {
            if !parser.append(piece).isEmpty { counts.append(parser.items.count) }
        }
        #expect(counts == [1, 2])
        #expect(parser.items.map(\.id) == [1, 2])
        #expect(parser.items[0].translation == #"说"走"{吧"#)
        #expect(parser.items[0].source == "「行くぞ}」")
        // new_terms 里的对象不当成块
        #expect(parser.items.count == 2)
    }

    @Test func 边收边解析认数组写法() {
        var parser = PartialBlocksParser()
        for piece in chunks(#"{"blocks":[[1,"dialogue","你好"],["2","sfx","咚"]],"new_terms":[]}"#) { _ = parser.append(piece) }
        #expect(parser.items.map(\.id) == [1, 2])
        #expect(parser.items.map(\.kind) == ["dialogue", "sfx"])
    }
}

/// 不联网的流式假客户端：每次调用按顺序用一份剧本
private final class StreamingClient: LLMClient, @unchecked Sendable {
    struct Script {
        var firstDelay: Duration = .zero
        var chunks: [String] = []
        var chunkDelay: Duration = .milliseconds(5)
        var usage: LLMUsage?
        var error: Error?
    }

    let config: LLMServiceConfig
    let endpoint = URL(string: "http://localhost:1/v1/chat/completions")!
    let apiKey = ""
    private let lock = NSLock()
    private var scripts: [Script]
    private let completeReply: LLMReply?
    private(set) var streamCalls = 0
    private(set) var completeCalls = 0

    /// id 用来区分服务：哪些服务不支持流式是全局记的，测试之间不能互相影响
    init(id: String, scripts: [Script], completeReply: LLMReply? = nil) {
        config = LLMServiceConfig(format: .openAICompatible, baseURL: "http://\(id).test", model: "mock")
        self.scripts = scripts
        self.completeReply = completeReply
    }

    func makeURLRequest(_ prompt: LLMPrompt) throws -> URLRequest { URLRequest(url: endpoint) }
    func parseReply(_ data: Data) throws -> LLMReply { LLMReply(content: "", usage: nil) }

    func complete(_ prompt: LLMPrompt) async throws -> LLMReply {
        lock.withLock { completeCalls += 1 }
        guard let completeReply else { throw MangaCoreError("没有准备普通回复") }
        return completeReply
    }

    func stream(_ prompt: LLMPrompt) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let script = lock.withLock {
            streamCalls += 1
            return scripts.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Task.sleep(for: script.firstDelay)
                    if let error = script.error { throw error }
                    for chunk in script.chunks {
                        continuation.yield(.text(chunk))
                        try await Task.sleep(for: script.chunkDelay)
                    }
                    if let usage = script.usage {
                        continuation.yield(.usage(input: usage.inputTokens, output: usage.outputTokens, cached: nil))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private actor PartialRecorder {
    private(set) var counts: [Int] = []
    func add(_ blocks: [TranslatedBlock]) { counts.append(blocks.count) }
}

struct StreamingTranslateTests {
    private let blocks = [1, 2, 3].map { id in
        TextBlock(
            id: id, box: Box(CGRect(x: 10, y: id * 100, width: 200, height: 50)), direction: .horizontal,
            text: "원문\(id)", confidence: 1, lines: [])
    }
    private let reply = #"{"blocks":[{"id":1,"source":"a","translation":"一","kind":"dialogue"},{"id":2,"source":"b","translation":"二","kind":"dialogue"},{"id":3,"source":"c","translation":"三","kind":"narration"}],"new_terms":[]}"#

    private func pieces(_ size: Int = 20) -> [String] {
        stride(from: 0, to: reply.count, by: size).map { start in
            let from = reply.index(reply.startIndex, offsetBy: start)
            let to = reply.index(from, offsetBy: min(size, reply.distance(from: from, to: reply.endIndex)))
            return String(reply[from..<to])
        }
    }

    @Test func 每翻好一块就回调_最后结果完整() async throws {
        let client = StreamingClient(id: "partial", scripts: [.init(chunks: pieces(), usage: LLMUsage(inputTokens: 9, outputTokens: 7))])
        let recorder = PartialRecorder()
        let result = try await PageTranslator().translate(
            blocks: blocks, prompt: "p", markedImage: Data(), using: client,
            streaming: StreamingOptions(onPartial: { await recorder.add($0) }))
        #expect(await recorder.counts == [1, 2, 3])
        #expect(result.blocks.map(\.translation) == ["一", "二", "三"])
        #expect(result.usage == LLMUsage(inputTokens: 9, outputTokens: 7))
        #expect(result.firstToken != nil && !result.hedged)
        #expect(client.completeCalls == 0)
    }

    @Test func 第一个字迟迟不来就对冲_先出字的胜出() async throws {
        let client = StreamingClient(id: "hedge", scripts: [
            .init(firstDelay: .seconds(3), chunks: pieces()),
            .init(chunks: pieces()),
        ])
        let started = ContinuousClock.now
        let result = try await PageTranslator().translate(
            blocks: blocks, prompt: "p", markedImage: Data(), using: client,
            streaming: StreamingOptions(hedgeAfter: .milliseconds(100)))
        #expect(result.hedged)
        #expect(client.streamCalls == 2)
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(result.blocks.map(\.translation) == ["一", "二", "三"])
    }

    @Test func 很快出字就不对冲() async throws {
        let client = StreamingClient(id: "fast", scripts: [.init(chunks: pieces()), .init(chunks: pieces())])
        let result = try await PageTranslator().translate(
            blocks: blocks, prompt: "p", markedImage: Data(), using: client,
            streaming: StreamingOptions(hedgeAfter: .milliseconds(300)))
        #expect(!result.hedged)
        #expect(client.streamCalls == 1)
    }

    @Test func 对冲前就失败的不可重试错误直接抛出() async {
        let client = StreamingClient(id: "badkey", scripts: [.init(error: LLMServiceError(status: 401, message: "bad key"))])
        await #expect(throws: LLMServiceError.self) {
            try await PageTranslator().translate(
                blocks: blocks, prompt: "p", markedImage: Data(), using: client,
                streaming: StreamingOptions(hedgeAfter: .seconds(1)))
        }
        #expect(client.streamCalls == 1)
    }

    @Test func 服务拒绝流式参数时改用普通请求() async throws {
        let client = StreamingClient(
            id: "nostream", scripts: [.init(error: LLMServiceError(status: 400, message: "unknown field stream_options"))],
            completeReply: LLMReply(content: reply, usage: nil))
        let first = try await PageTranslator().translate(
            blocks: blocks, prompt: "p", markedImage: Data(), using: client, streaming: StreamingOptions())
        #expect(first.blocks.map(\.translation) == ["一", "二", "三"])
        #expect(first.firstToken == nil)
        // 之后直接用普通请求，不再试流式
        _ = try await PageTranslator().translate(
            blocks: blocks, prompt: "p", markedImage: Data(), using: client, streaming: StreamingOptions())
        #expect(client.streamCalls == 1)
        #expect(client.completeCalls == 2)
    }
}
