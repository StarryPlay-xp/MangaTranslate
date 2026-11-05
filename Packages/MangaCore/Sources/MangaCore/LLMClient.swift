import Foundation

/// 发给模型的一次请求，与接口格式无关
public struct LLMPrompt: Sendable {
    public var system: String
    public var user: String
    /// 附带的 JPEG 图片；nil 表示只发文字
    public var jpeg: Data?
    public var maxTokens: Int
    /// 只用于保存请求示例：图片内容换成占位文字
    public var omitsImageData: Bool

    public init(system: String, user: String, jpeg: Data? = nil, maxTokens: Int = 4096, omitsImageData: Bool = false) {
        self.system = system
        self.user = user
        self.jpeg = jpeg
        self.maxTokens = maxTokens
        self.omitsImageData = omitsImageData
    }

    func base64Image(_ data: Data) -> String {
        omitsImageData ? "<省略 \(data.count) 字节的图片>" : data.base64EncodedString()
    }
}

/// 一次请求的 token 用量。不同服务返回的字段不同，这里统一成输入、输出和缓存命中
public struct LLMUsage: Codable, Sendable, Equatable {
    /// 全部输入 token（包含缓存命中的部分）
    public var inputTokens: Int
    public var outputTokens: Int
    /// 输入里命中缓存的部分；服务没有返回时为 nil
    public var cachedInputTokens: Int?

    public init(inputTokens: Int, outputTokens: Int, cachedInputTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
    }

    public static let zero = LLMUsage(inputTokens: 0, outputTokens: 0)

    public func adding(_ other: LLMUsage) -> LLMUsage {
        let cached: Int? = cachedInputTokens == nil && other.cachedInputTokens == nil
            ? nil : (cachedInputTokens ?? 0) + (other.cachedInputTokens ?? 0)
        return LLMUsage(
            inputTokens: inputTokens + other.inputTokens, outputTokens: outputTokens + other.outputTokens,
            cachedInputTokens: cached)
    }
}

public struct LLMReply: Sendable {
    public var content: String
    public var usage: LLMUsage?

    public init(content: String, usage: LLMUsage?) {
        self.content = content
        self.usage = usage
    }
}

/// 大模型服务的客户端：把 LLMPrompt 编码成对应格式的请求，发出去，再取回文字和用量
public protocol LLMClient: Sendable {
    var config: LLMServiceConfig { get }
    /// 完整请求地址
    var endpoint: URL { get }
    /// 可以为空（本地服务一般不需要）；只放进请求头，不写进日志和错误信息
    var apiKey: String { get }
    /// 生成要发送的请求（包含请求头和请求体）
    func makeURLRequest(_ prompt: LLMPrompt) throws -> URLRequest
    /// 从 200 响应里取出文字和用量
    func parseReply(_ data: Data) throws -> LLMReply
    /// 发送请求；默认实现用 URLSession
    func complete(_ prompt: LLMPrompt) async throws -> LLMReply
    /// 打开流式输出的请求；默认和 makeURLRequest 一样（不流式）
    func makeStreamingURLRequest(_ prompt: LLMPrompt) throws -> URLRequest
    /// 解析流式回复里一条 data 的内容；默认什么都不取
    func parseStreamChunk(_ data: Data) throws -> [LLMStreamEvent]
    /// 边生成边返回文字片段，最后给出用量；默认实现读取 SSE，见 LLMStreaming.swift
    func stream(_ prompt: LLMPrompt) -> AsyncThrowingStream<LLMStreamEvent, Error>
}

extension LLMClient {
    /// 只有请求体，用来保存请求示例（图片可以省略）。不含请求头，所以不会带出 Key
    public func requestBody(_ prompt: LLMPrompt) throws -> Data {
        try makeURLRequest(prompt).httpBody ?? Data()
    }

    public func complete(_ prompt: LLMPrompt) async throws -> LLMReply {
        let request = try makeURLRequest(prompt)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            throw LLMServiceError.mapping(error, endpoint: endpoint, timeout: config.timeoutSeconds)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw LLMServiceError(status: status, message: LLMServiceError.message(in: data, hiding: apiKey))
        }
        return try parseReply(data)
    }

    /// 测试连接：只发一条很短的文字请求
    public func ping() async throws -> LLMReply {
        try await complete(LLMPrompt(
            system: "你在帮用户测试连接。只输出 json，不要输出任何解释。",
            user: #"请原样输出这个 json：{"ok": true}"#,
            maxTokens: 256))
    }
}

public struct LLMServiceError: LocalizedError, Sendable {
    public enum Kind: Sendable, Equatable {
        /// 服务返回了非 200 的状态码
        case http(Int)
        /// 连不上服务（服务没启动、地址错、没有网络、证书不受信任）
        case unreachable
        /// 对非局域网地址用了 http://，被系统拦下
        case insecureHTTP
        /// 等太久没有返回
        case timedOut
        /// 模型拒绝回答
        case refused
    }

    public let kind: Kind
    public let message: String

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }

    public init(status: Int, message: String) {
        self.init(kind: .http(status), message: message)
    }

    public var status: Int? {
        if case .http(let status) = kind { status } else { nil }
    }

    /// 限流、服务端出错（包括 Anthropic 的 529 过载）可以重试
    public var isRetryable: Bool {
        guard let status else { return false }
        return status == 408 || status == 409 || status == 429 || status >= 500
    }

    /// Key 无效、余额不足、地址或模型不对、连不上时，后面每页都会失败，应直接停止
    public var stopsWholeRun: Bool {
        switch kind {
        case .http(let status): [401, 402, 403, 404].contains(status)
        case .unreachable, .insecureHTTP: true
        case .timedOut, .refused: false
        }
    }

    /// 需要去设置里改模型服务（Key、地址、模型名）才能解决
    public var needsSettings: Bool {
        switch kind {
        case .http(let status): [401, 403, 404].contains(status)
        case .unreachable, .insecureHTTP: true
        case .timedOut, .refused: false
        }
    }

    public var errorDescription: String? {
        guard let status else { return message }
        let reason = switch status {
        case 400: "请求被拒绝"
        case 401: "API Key 无效或没有填写"
        case 402: "账户余额不足"
        case 403: "没有权限使用这个服务或模型"
        case 404: "找不到接口或模型，请检查请求地址和模型名"
        case 413: "请求内容太大"
        case 429: "请求太频繁，被限流"
        case 529: "模型服务繁忙"
        case 500...: "模型服务出错"
        default: "请求失败"
        }
        var text = "\(reason)（HTTP \(status)）"
        if !message.isEmpty { text += "：\(message)" }
        if status == 400, message.localizedCaseInsensitiveContains("response_format") {
            text += "。可以在模型服务里关掉 JSON 模式再试"
        }
        return text
    }

    /// 把明确是"连不上""太慢""被系统拦下"的网络错误换成可读的说明；其他网络错误（如连接中断）原样返回，由调用方重试
    static func mapping(_ error: URLError, endpoint: URL, timeout: Double) -> Error {
        let host = endpoint.host() ?? endpoint.absoluteString
        switch error.code {
        case .timedOut:
            return LLMServiceError(
                kind: .timedOut, message: "等了 \(Int(timeout)) 秒还没有返回。模型太慢的话，可以在模型服务里把超时调长")
        case .appTransportSecurityRequiresSecureConnection:
            return LLMServiceError(kind: .insecureHTTP, message: "\(host) 不是局域网地址，只能用 https:// 访问")
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet,
             .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
            // 系统的说明一般自带句号，去掉再放进括号
            let reason = error.localizedDescription.trimmingCharacters(in: CharacterSet(charactersIn: "。.！!").union(.whitespaces))
            var text = "连不上 \(host)（\(reason)）"
            if LLMEndpoint.isLocalHost(host) {
                text += "。请确认模型服务已启动并允许局域网访问、手机和电脑连着同一个 Wi-Fi，并允许漫译访问本地网络"
            }
            return LLMServiceError(kind: .unreachable, message: text)
        default:
            return error
        }
    }

    /// 从错误响应里取出说明。兼容 OpenAI / Anthropic 的 {"error": {"message"}}、
    /// Ollama 的 {"error": "…"}、vLLM 的 {"message": "…"}；最后把 Key 遮住
    static func message(in data: Data, hiding apiKey: String) -> String {
        var text = String(decoding: data.prefix(300), as: UTF8.self)
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
                text = message
            } else if let message = object["error"] as? String {
                text = message
            } else if let message = object["message"] as? String {
                text = message
            } else if let message = object["detail"] as? String {
                text = message
            }
        }
        return redact(text, apiKey: apiKey)
    }

    static func redact(_ text: String, apiKey: String) -> String {
        var result = text
        if apiKey.count >= 4 { result = result.replacingOccurrences(of: apiKey, with: "***") }
        // 有的服务会在报错里回显部分 Key（如 sk-abc…xyz），一并遮住
        if let pattern = try? NSRegularExpression(pattern: #"sk-[A-Za-z0-9_\-\*\.]{4,}"#) {
            let range = NSRange(result.startIndex..., in: result)
            result = pattern.stringByReplacingMatches(in: result, range: range, withTemplate: "sk-***")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
