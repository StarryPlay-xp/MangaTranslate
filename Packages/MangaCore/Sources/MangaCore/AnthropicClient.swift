import Foundation

/// Anthropic Messages：{地址}/v1/messages，请求头 x-api-key 和 anthropic-version，system 放在顶层，必须带 max_tokens
public struct AnthropicClient: LLMClient {
    public let config: LLMServiceConfig
    public let endpoint: URL
    public let apiKey: String

    /// Anthropic 官方用最新的 API 版本；兼容 Anthropic 格式的第三方服务大多按 2023-06-01 实现。
    /// 这里发的请求不含两个版本之间有差别的字段（temperature、top_p、top_k、document 等），所以效果相同
    static let officialVersion = "2026-10-21"
    static let compatibleVersion = "2023-06-01"

    public init(config: LLMServiceConfig, endpoint: URL, apiKey: String) {
        self.config = config
        self.endpoint = endpoint
        self.apiKey = apiKey
    }

    public func makeURLRequest(_ prompt: LLMPrompt) throws -> URLRequest {
        try makeURLRequest(prompt, streaming: false)
    }

    public func makeStreamingURLRequest(_ prompt: LLMPrompt) throws -> URLRequest {
        try makeURLRequest(prompt, streaming: true)
    }

    private func makeURLRequest(_ prompt: LLMPrompt, streaming: Bool) throws -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: config.timeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let official = endpoint.host()?.lowercased() == "api.anthropic.com"
        request.setValue(official ? Self.officialVersion : Self.compatibleVersion, forHTTPHeaderField: "anthropic-version")
        if !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var body = body(for: prompt)
        if streaming { body.stream = true }
        request.httpBody = try encoder.encode(body)
        return request
    }

    /// 事件按 type 区分：message_start 带输入用量，content_block_delta 带文字，message_delta 带输出用量和结束原因
    public func parseStreamChunk(_ data: Data) throws -> [LLMStreamEvent] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let event = try? decoder.decode(StreamEvent.self, from: data) else { return [] }
        switch event.type {
        case "message_start":
            guard let usage = event.message?.usage else { return [] }
            let cacheRead = usage.cacheReadInputTokens ?? 0
            let cacheWrite = usage.cacheCreationInputTokens ?? 0
            return [.usage(
                input: (usage.inputTokens ?? 0) + cacheRead + cacheWrite, output: usage.outputTokens,
                cached: usage.cacheReadInputTokens)]
        case "content_block_delta":
            // 思考过程（thinking_delta）不要
            guard event.delta?.type == "text_delta", let text = event.delta?.text, !text.isEmpty else { return [] }
            return [.text(text)]
        case "message_delta":
            if event.delta?.stopReason == "refusal" {
                throw LLMServiceError(kind: .refused, message: "模型拒绝处理这一页")
            }
            return event.usage?.outputTokens.map { [.usage(input: nil, output: $0, cached: nil)] } ?? []
        case "error":
            // 过载（overloaded_error）按 529 处理，可以重试
            let overloaded = event.error?.type == "overloaded_error"
            throw LLMServiceError(status: overloaded ? 529 : 500, message: event.error?.message ?? "")
        default:
            return []
        }
    }

    func body(for prompt: LLMPrompt) -> Body {
        var blocks: [Body.Block] = []
        if let jpeg = prompt.jpeg {
            // 图片放在文字前面
            blocks.append(.init(
                type: "image", source: .init(type: "base64", mediaType: "image/jpeg", data: prompt.base64Image(jpeg))))
        }
        blocks.append(.init(type: "text", text: prompt.user))
        return Body(
            model: config.model, maxTokens: prompt.maxTokens, system: prompt.system,
            messages: [.init(role: "user", content: blocks)])
    }

    public func parseReply(_ data: Data) throws -> LLMReply {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded: Response
        do {
            decoded = try decoder.decode(Response.self, from: data)
        } catch {
            throw MangaCoreError("返回的内容不是 Anthropic Messages 格式，请确认接口格式选对了")
        }
        if decoded.stopReason == "refusal" {
            throw LLMServiceError(kind: .refused, message: "模型拒绝处理这一页")
        }
        // content 里可能先有 thinking 块，只取 text 块
        let text = decoded.content.filter { $0.type == "text" }.compactMap(\.text).joined()
        let usage = decoded.usage.map { usage in
            // input_tokens 不含缓存读写的部分，这里加回去，统一成"全部输入"
            let cacheRead = usage.cacheReadInputTokens ?? 0
            let cacheWrite = usage.cacheCreationInputTokens ?? 0
            return LLMUsage(
                inputTokens: (usage.inputTokens ?? 0) + cacheRead + cacheWrite, outputTokens: usage.outputTokens ?? 0,
                cachedInputTokens: usage.cacheReadInputTokens)
        }
        return LLMReply(content: text, usage: usage)
    }

    struct Body: Encodable {
        struct Message: Encodable {
            var role: String
            var content: [Block]
        }

        struct Block: Encodable {
            var type: String
            var text: String?
            var source: Source?
        }

        struct Source: Encodable {
            var type: String
            var mediaType: String
            var data: String
        }

        var model: String
        var maxTokens: Int
        var system: String
        var messages: [Message]
        var stream: Bool?
    }

    private struct StreamEvent: Decodable {
        struct Message: Decodable { var usage: Response.Usage? }
        struct Delta: Decodable {
            var type: String?
            var text: String?
            var stopReason: String?
        }
        struct ErrorInfo: Decodable {
            var type: String?
            var message: String?
        }

        var type: String
        var message: Message?
        var delta: Delta?
        var usage: Response.Usage?
        var error: ErrorInfo?
    }

    private struct Response: Decodable {
        struct Block: Decodable {
            var type: String
            var text: String?
        }

        struct Usage: Decodable {
            var inputTokens: Int?
            var outputTokens: Int?
            var cacheReadInputTokens: Int?
            var cacheCreationInputTokens: Int?
        }

        var content: [Block]
        var stopReason: String?
        var usage: Usage?
    }
}
