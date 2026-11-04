import Foundation

/// DeepSeek 的 Chat Completions 接口（OpenAI 兼容格式）
public struct DeepSeekClient: Sendable {
    public let apiKey: String
    public let endpoint = URL(string: "https://api.deepseek.com/chat/completions")!

    public init(apiKey: String) {
        self.apiKey = apiKey
    }

    public struct Usage: Codable, Sendable {
        public var promptTokens: Int
        public var completionTokens: Int
        public var promptCacheHitTokens: Int?
        public var promptCacheMissTokens: Int?

        public static let zero = Usage(
            promptTokens: 0, completionTokens: 0, promptCacheHitTokens: 0, promptCacheMissTokens: 0)

        public func adding(_ other: Usage) -> Usage {
            let hit = (promptCacheHitTokens ?? 0) + (other.promptCacheHitTokens ?? 0)
            return Usage(
                promptTokens: promptTokens + other.promptTokens,
                completionTokens: completionTokens + other.completionTokens,
                promptCacheHitTokens: hit,
                promptCacheMissTokens: promptTokens + other.promptTokens - hit)
        }
    }

    public struct Reply: Sendable {
        public var content: String
        public var usage: Usage?
    }

    public func complete(_ request: ChatRequest) async throws -> Reply {
        var urlRequest = URLRequest(url: endpoint, timeoutInterval: 180)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try request.jsonData()

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw DeepSeekError(status: status, message: Self.errorMessage(in: data))
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decoder.decode(ChatResponse.self, from: data)
        return Reply(content: decoded.choices.first?.message.content ?? "", usage: decoded.usage)
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { var content: String? }
            var message: Message
        }
        var choices: [Choice]
        var usage: Usage?
    }

    private static func errorMessage(in data: Data) -> String {
        struct Body: Decodable {
            struct Detail: Decodable { var message: String? }
            var error: Detail?
        }
        if let message = (try? JSONDecoder().decode(Body.self, from: data))?.error?.message {
            return message
        }
        return String(decoding: data.prefix(300), as: UTF8.self)
    }
}

public struct DeepSeekError: LocalizedError, Sendable {
    public let status: Int
    public let message: String

    /// 限流和服务端错误可以重试
    public var isRetryable: Bool { status == 429 || status >= 500 }
    /// Key 无效、余额不足时后面每页都会失败，应直接停止
    public var stopsWholeRun: Bool { status == 401 || status == 402 }

    public var errorDescription: String? {
        let reason = switch status {
        case 401: "API Key 无效"
        case 402: "账户余额不足"
        case 429: "请求太频繁，被限流"
        case 500...: "DeepSeek 服务端出错"
        default: "请求失败"
        }
        return "\(reason)（HTTP \(status)）：\(message)"
    }
}

public struct ChatRequest: Encodable, Sendable {
    public struct Message: Encodable, Sendable {
        public var role: String
        public var content: Content
    }

    public enum Content: Encodable, Sendable {
        case text(String)
        case parts([Part])

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let text): try container.encode(text)
            case .parts(let parts): try container.encode(parts)
            }
        }
    }

    public struct Part: Encodable, Sendable {
        public var type: String
        public var text: String?
        public var imageUrl: ImageURL?

        public static func text(_ text: String) -> Part { Part(type: "text", text: text) }

        /// detail 用 high 保留原图；low 会缩到 512×512，漫画上的字会糊掉。
        /// omitted 为 true 时不放图片内容，只用于保存请求示例
        public static func jpeg(_ data: Data, omitted: Bool = false) -> Part {
            let payload = omitted ? "<省略 \(data.count) 字节的图片>" : data.base64EncodedString()
            return Part(type: "image_url", imageUrl: ImageURL(url: "data:image/jpeg;base64," + payload, detail: "high"))
        }
    }

    public struct ImageURL: Encodable, Sendable {
        public var url: String
        public var detail: String
    }

    public struct ResponseFormat: Encodable, Sendable { public var type = "json_object" }
    public struct Thinking: Encodable, Sendable { public var type: String }

    public var model: String
    public var messages: [Message]
    public var responseFormat = ResponseFormat()
    public var thinking: Thinking
    public var maxTokens: Int
    public var stream = false

    public func jsonData(pretty: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        if pretty { encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] }
        return try encoder.encode(self)
    }
}

/// deepseek-flash 的官方价格（美元 / 百万 token），2026-11-04 核实，以后可能调整
public enum DeepSeekPricing {
    public struct Rates: Sendable {
        public var cacheHitInput: Double
        public var cacheMissInput: Double
        public var output: Double
    }

    public static let pricedModel = "deepseek-flash"
    public static let offPeak = Rates(cacheHitInput: 0.003, cacheMissInput: 0.15, output: 0.6)
    public static let peak = Rates(cacheHitInput: 0.006, cacheMissInput: 0.3, output: 1.2)

    /// 高峰时段：工作日 UTC 01–04 点和 06–10 点（北京时间 9–12 点、14–18 点）；这里没有扣除中国法定节假日
    public static func isPeak(_ date: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let weekday = calendar.component(.weekday, from: date)  // 1 是周日
        let hour = calendar.component(.hour, from: date)
        return (2...6).contains(weekday) && ((1..<4).contains(hour) || (6..<10).contains(hour))
    }

    public static func cost(of usage: DeepSeekClient.Usage, peak: Bool) -> Double {
        let rates = peak ? Self.peak : offPeak
        let hit = Double(usage.promptCacheHitTokens ?? 0)
        let miss = Double(usage.promptTokens) - hit
        return (hit * rates.cacheHitInput + miss * rates.cacheMissInput + Double(usage.completionTokens) * rates.output)
            / 1_000_000
    }
}
