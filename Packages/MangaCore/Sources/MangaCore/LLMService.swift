import Foundation

/// 大模型服务的接口格式
public enum LLMAPIFormat: String, Codable, Sendable, CaseIterable {
    /// OpenAI 兼容的 Chat Completions：DeepSeek、Ollama、LM Studio、vLLM 等大多数服务都支持
    case openAICompatible = "openai"
    /// Anthropic Messages
    case anthropic

    public var displayName: String {
        switch self {
        case .openAICompatible: "OpenAI 兼容"
        case .anthropic: "Anthropic"
        }
    }
}

/// 一个模型服务的连接参数（不含 API Key，Key 由调用方单独保管）
public struct LLMServiceConfig: Codable, Sendable, Hashable {
    public var format: LLMAPIFormat
    /// 用户填写的请求地址，可以带或不带 /v1、结尾斜杠，也可以直接填完整地址
    public var baseURL: String
    public var model: String
    /// 模型能不能看图；不能时只发识别出的文字
    public var supportsImages: Bool
    /// OpenAI 兼容格式下发送 response_format: json_object。有的模型不支持，可以关掉，靠提示词要求输出 json
    public var jsonMode: Bool
    /// 等待一次回复的最长时间（秒）。本地小模型慢，可以调长
    public var timeoutSeconds: Double
    /// 只对 DeepSeek 生效：开启思考模式（更慢、更贵）。其他服务不发送任何思考参数
    public var enableThinking: Bool

    public init(
        format: LLMAPIFormat, baseURL: String, model: String, supportsImages: Bool = true, jsonMode: Bool = true,
        timeoutSeconds: Double = 180, enableThinking: Bool = false
    ) {
        self.format = format
        self.baseURL = baseURL
        self.model = model
        self.supportsImages = supportsImages
        self.jsonMode = jsonMode
        self.timeoutSeconds = timeoutSeconds
        self.enableThinking = enableThinking
    }

    // 以后加字段时，旧数据里没有的字段用默认值
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decode(LLMAPIFormat.self, forKey: .format)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        model = try container.decode(String.self, forKey: .model)
        supportsImages = try container.decodeIfPresent(Bool.self, forKey: .supportsImages) ?? true
        jsonMode = try container.decodeIfPresent(Bool.self, forKey: .jsonMode) ?? true
        timeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? 180
        enableThinking = try container.decodeIfPresent(Bool.self, forKey: .enableThinking) ?? false
    }

    /// 最终的完整请求地址；地址填得不对时抛出错误
    public func endpoint() throws -> URL {
        try LLMEndpoint.resolve(baseURL, format: format)
    }

    /// 请求地址是不是本机或局域网（本地部署的模型）
    public var isLocalNetwork: Bool {
        guard let host = (try? endpoint())?.host() else { return false }
        return LLMEndpoint.isLocalHost(host)
    }

    /// 地址匹配的服务商预设（目前只有 DeepSeek），用来决定专用参数和价格
    public var preset: LLMProviderPreset? { LLMProviderPreset.matching(self) }

    /// 能估算费用时返回价格，否则只显示 token 数
    public var pricing: LLMPricing? { preset?.pricing(for: model) }

    public func makeClient(apiKey: String?) throws -> any LLMClient {
        let endpoint = try endpoint()
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch format {
        case .openAICompatible: return OpenAICompatibleClient(config: self, endpoint: endpoint, apiKey: key)
        case .anthropic: return AnthropicClient(config: self, endpoint: endpoint, apiKey: key)
        }
    }
}

/// 把用户填的地址整理成完整的请求地址
public enum LLMEndpoint {
    /// - OpenAI 兼容：只填了主机名就补 /v1/chat/completions；带了路径（如 /v1、/api/paas/v4）就只补 /chat/completions
    /// - Anthropic：补成 {地址}/v1/messages；已经带 /v1 的不会重复
    /// - 已经是完整地址的保持不变；没写 http(s):// 时，局域网地址按 http，其他按 https
    public static func resolve(_ input: String, format: LLMAPIFormat) throws -> URL {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw MangaCoreError("还没有填写请求地址") }
        if !text.contains("://") {
            let host = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
            let hostOnly = URLComponents(string: "http://" + host)?.host ?? host
            text = (isLocalHost(hostOnly) ? "http://" : "https://") + text
        }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else {
            throw MangaCoreError("请求地址格式不对，例如 https://api.deepseek.com 或 http://192.168.1.10:11434/v1")
        }
        components.scheme = scheme
        components.query = nil
        components.fragment = nil

        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        let lowered = path.lowercased()
        switch format {
        case .openAICompatible:
            if lowered.hasSuffix("/chat/completions") {
                // 已经是完整地址
            } else if path.isEmpty {
                path = "/v1/chat/completions"
            } else {
                path += "/chat/completions"
            }
        case .anthropic:
            if lowered.hasSuffix("/messages") {
                // 已经是完整地址
            } else if lowered.hasSuffix("/v1") {
                path += "/messages"
            } else {
                path += "/v1/messages"
            }
        }
        components.path = path
        guard let url = components.url else { throw MangaCoreError("请求地址格式不对") }
        return url
    }

    /// 本机、局域网地址：localhost、.local、没有点的主机名、私有 IP 段
    public static func isLocalHost(_ rawHost: String) -> Bool {
        var host = rawHost.lowercased()
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".localhost") { return true }
        if host.contains(":") {
            // IPv6：回环、链路本地、唯一本地地址
            return host == "::1" || host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd")
        }
        let parts = host.split(separator: ".").map(String.init)
        let numbers = parts.compactMap { UInt8($0) }
        if parts.count == 4, numbers.count == 4 {
            switch (numbers[0], numbers[1]) {
            case (10, _), (127, _), (192, 168), (169, 254): return true
            case (172, 16...31): return true
            default: return false
            }
        }
        // 没有点的主机名（如 my-mac）只能是局域网里的机器
        return !host.contains(".")
    }
}
