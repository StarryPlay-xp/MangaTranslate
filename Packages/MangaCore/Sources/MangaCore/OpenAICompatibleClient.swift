import Foundation

/// OpenAI 兼容的 Chat Completions：{地址}/chat/completions，Bearer 鉴权，Key 可以为空
public struct OpenAICompatibleClient: LLMClient {
    public let config: LLMServiceConfig
    public let endpoint: URL
    public let apiKey: String

    public init(config: LLMServiceConfig, endpoint: URL, apiKey: String) {
        self.config = config
        self.endpoint = endpoint
        self.apiKey = apiKey
    }

    public func makeURLRequest(_ prompt: LLMPrompt) throws -> URLRequest {
        try makeURLRequest(prompt, streaming: false)
    }

    /// 打开 stream，并要求在最后一条里附上用量（include_usage），用来记账
    public func makeStreamingURLRequest(_ prompt: LLMPrompt) throws -> URLRequest {
        try makeURLRequest(prompt, streaming: true)
    }

    private func makeURLRequest(_ prompt: LLMPrompt, streaming: Bool) throws -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: config.timeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        var body = body(for: prompt)
        if streaming {
            body.stream = true
            body.streamOptions = .init(includeUsage: true)
        }
        request.httpBody = try encoder.encode(body)
        return request
    }

    /// 每条是 {"choices": [{"delta": {"content": "…"}}]}；带 include_usage 时最后一条 choices 为空、带 usage
    public func parseStreamChunk(_ data: Data) throws -> [LLMStreamEvent] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let chunk = try? decoder.decode(StreamChunk.self, from: data) else { return [] }
        var events: [LLMStreamEvent] = []
        let text = chunk.choices?.compactMap { $0.delta?.content?.text }.joined() ?? ""
        if !text.isEmpty { events.append(.text(text)) }
        if let usage = chunk.usage {
            events.append(.usage(
                input: usage.promptTokens, output: usage.completionTokens,
                cached: usage.promptCacheHitTokens ?? usage.promptTokensDetails?.cachedTokens))
        }
        return events
    }

    func body(for prompt: LLMPrompt) -> Body {
        let userContent: Body.Content
        if let jpeg = prompt.jpeg {
            // detail 用 high 保留原图；low 会缩到 512×512，漫画上的字会糊掉
            let image = Body.ImageURL(url: "data:image/jpeg;base64," + prompt.base64Image(jpeg), detail: "high")
            userContent = .parts([.init(type: "text", text: prompt.user), .init(type: "image_url", imageUrl: image)])
        } else {
            // 纯文字用字符串，兼容不支持多段内容的本地服务
            userContent = .text(prompt.user)
        }
        var body = Body(
            model: config.model,
            messages: [.init(role: "system", content: .text(prompt.system)), .init(role: "user", content: userContent)])
        // OpenAI 官方的新模型不再接受 max_tokens，只认 max_completion_tokens；其他兼容服务大多只认 max_tokens
        if endpoint.host()?.lowercased() == "api.openai.com" {
            body.maxCompletionTokens = prompt.maxTokens
        } else {
            body.maxTokens = prompt.maxTokens
        }
        if config.jsonMode { body.responseFormat = .init(type: "json_object") }
        if config.preset?.quirks.contains(.deepSeekThinking) == true {
            // DeepSeek 默认开启思考，翻译用不着，显式关掉更快更便宜
            body.thinking = .init(type: config.enableThinking ? "enabled" : "disabled")
        }
        return body
    }

    public func parseReply(_ data: Data) throws -> LLMReply {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded: Response
        do {
            decoded = try decoder.decode(Response.self, from: data)
        } catch {
            throw MangaCoreError("返回的内容不是 Chat Completions 格式，请确认接口格式选对了")
        }
        let usage = decoded.usage.map { usage in
            LLMUsage(
                inputTokens: usage.promptTokens ?? 0, outputTokens: usage.completionTokens ?? 0,
                // DeepSeek 用 prompt_cache_hit_tokens，OpenAI 用 prompt_tokens_details.cached_tokens
                cachedInputTokens: usage.promptCacheHitTokens ?? usage.promptTokensDetails?.cachedTokens)
        }
        return LLMReply(content: decoded.choices.first?.message.content?.text ?? "", usage: usage)
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    struct Body: Encodable {
        struct Message: Encodable {
            var role: String
            var content: Content
        }

        enum Content: Encodable {
            case text(String)
            case parts([Part])

            func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case .text(let text): try container.encode(text)
                case .parts(let parts): try container.encode(parts)
                }
            }
        }

        struct Part: Encodable {
            var type: String
            var text: String?
            var imageUrl: ImageURL?
        }

        struct ImageURL: Encodable {
            var url: String
            var detail: String
        }

        struct ResponseFormat: Encodable { var type: String }
        struct Thinking: Encodable { var type: String }
        struct StreamOptions: Encodable { var includeUsage: Bool }

        var model: String
        var messages: [Message]
        var maxTokens: Int?
        var maxCompletionTokens: Int?
        var stream = false
        var streamOptions: StreamOptions?
        var responseFormat: ResponseFormat?
        var thinking: Thinking?
    }

    private struct StreamChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { var content: FlexibleText? }
            var delta: Delta?
        }

        var choices: [Choice]?
        var usage: Response.Usage?
    }

    private struct Response: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { var content: FlexibleText? }
            var message: Message
        }

        struct Usage: Decodable {
            struct Details: Decodable { var cachedTokens: Int? }
            var promptTokens: Int?
            var completionTokens: Int?
            var promptCacheHitTokens: Int?
            var promptTokensDetails: Details?
        }

        var choices: [Choice]
        var usage: Usage?
    }

    /// content 一般是字符串，少数服务返回 [{type: text, text}] 数组
    private struct FlexibleText: Decodable {
        var text: String

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                text = string
            } else {
                struct Part: Decodable { var text: String? }
                text = try container.decode([Part].self).compactMap(\.text).joined()
            }
        }
    }
}
