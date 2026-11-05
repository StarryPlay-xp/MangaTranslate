import Foundation

/// 流式回复里的一条消息
public enum LLMStreamEvent: Sendable, Equatable {
    /// 新生成的一段文字
    case text(String)
    /// 用量。Anthropic 分两次给（开头给输入，结尾给输出），没给的字段是 nil，后来的覆盖先前的
    case usage(input: Int?, output: Int?, cached: Int?)
}

/// 把 SSE（Server-Sent Events）的一行行文字整理成 data 内容。
/// 只认 data: 行；冒号开头的注释行（DeepSeek 排队时发的 keep-alive）、event: 等其他行都跳过
public struct SSELineParser: Sendable {
    public init() {}

    /// 返回这一行的 data 内容；收到 [DONE] 时返回 nil 并把 isDone 设为 true
    public mutating func data(in line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        var payload = line.dropFirst(5)
        if payload.first == " " { payload = payload.dropFirst() }
        if payload == "[DONE]" {
            isDone = true
            return nil
        }
        return payload.isEmpty ? nil : String(payload)
    }

    public private(set) var isDone = false
}

/// 把流式消息累计成完整回复
public struct StreamedReplyBuilder: Sendable {
    public private(set) var content = ""
    private var input: Int?
    private var output: Int?
    private var cached: Int?

    public init() {}

    public mutating func add(_ event: LLMStreamEvent) {
        switch event {
        case .text(let text):
            content += text
        case .usage(let input, let output, let cached):
            self.input = input ?? self.input
            self.output = output ?? self.output
            self.cached = cached ?? self.cached
        }
    }

    /// 服务没给用量时 usage 为 nil
    public var reply: LLMReply {
        let usage = input == nil && output == nil
            ? nil : LLMUsage(inputTokens: input ?? 0, outputTokens: output ?? 0, cachedInputTokens: cached)
        return LLMReply(content: content, usage: usage)
    }
}

extension LLMClient {
    public func makeStreamingURLRequest(_ prompt: LLMPrompt) throws -> URLRequest {
        try makeURLRequest(prompt)
    }

    public func parseStreamChunk(_ data: Data) throws -> [LLMStreamEvent] { [] }

    public func stream(_ prompt: LLMPrompt) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await readStream(prompt, into: continuation)
                    continuation.finish()
                } catch let error as URLError {
                    continuation.finish(throwing: LLMServiceError.mapping(error, endpoint: endpoint, timeout: config.timeoutSeconds))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // 读的人不要了（取消、对冲输了），连同网络请求一起停掉
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func readStream(
        _ prompt: LLMPrompt, into continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation
    ) async throws {
        let request = try makeStreamingURLRequest(prompt)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let isEventStream = http?.value(forHTTPHeaderField: "Content-Type")?.contains("text/event-stream") ?? false
        guard status == 200, isEventStream else {
            // 出错，或者服务不支持流式、直接回了完整的 json：读完整个回复，按普通回复处理
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            guard status == 200 else {
                throw LLMServiceError(status: status, message: LLMServiceError.message(in: data, hiding: apiKey))
            }
            let reply = try parseReply(data)
            continuation.yield(.text(reply.content))
            if let usage = reply.usage {
                continuation.yield(.usage(input: usage.inputTokens, output: usage.outputTokens, cached: usage.cachedInputTokens))
            }
            return
        }
        var parser = SSELineParser()
        for try await line in bytes.lines {
            if let payload = parser.data(in: line) {
                for event in try parseStreamChunk(Data(payload.utf8)) { continuation.yield(event) }
            }
            if parser.isDone { break }
        }
    }
}
