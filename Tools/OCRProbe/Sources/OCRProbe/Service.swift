import Darwin
import Foundation
import MangaCore

/// translate 和 ping 共用的模型服务参数。默认是 DeepSeek（deepseek-flash）
struct ServiceOptions {
    var config = LLMProviderPreset.deepSeek.makeConfig()
    /// 不要 Key（本地服务）；局域网地址默认就不要
    var noKey = false
    private var modelGiven = false
    private var baseURLGiven = false

    static let usage = "[--format openai|anthropic] [--base-url <地址>] [--model <模型名>] [--no-json-mode] [--timeout <秒>] [--no-key]"

    /// 取出认识的参数，其余原样返回
    mutating func parse(_ args: [String]) throws -> [String] {
        var rest: [String] = []
        var iterator = args.makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--format":
                guard let value = iterator.next(), let format = LLMAPIFormat(rawValue: value) else {
                    throw ProbeError("--format 后面要跟 openai 或 anthropic")
                }
                config.format = format
            case "--base-url":
                guard let value = iterator.next() else { throw ProbeError("--base-url 后面要跟请求地址") }
                config.baseURL = value
                baseURLGiven = true
            case "--model":
                guard let value = iterator.next() else { throw ProbeError("--model 后面要跟模型名") }
                config.model = value
                modelGiven = true
            case "--no-json-mode": config.jsonMode = false
            case "--timeout":
                guard let value = iterator.next().flatMap({ Double($0) }), value > 0 else {
                    throw ProbeError("--timeout 后面要跟秒数，例如 300")
                }
                config.timeoutSeconds = value
            case "--no-key": noKey = true
            default: rest.append(arg)
            }
        }
        if config.format == .anthropic && !baseURLGiven {
            throw ProbeError("用 Anthropic 格式时要用 --base-url 指定地址，例如 https://api.anthropic.com")
        }
        if (baseURLGiven || config.format != .openAICompatible) && !modelGiven && config.preset == nil {
            throw ProbeError("换了地址或格式时要用 --model 指定模型名")
        }
        _ = try config.endpoint()
        return rest
    }

    func makeClient() throws -> any LLMClient {
        try config.makeClient(apiKey: try readAPIKey())
    }

    /// 优先读环境变量 LLM_API_KEY（DeepSeek 也认 DEEPSEEK_API_KEY）；没有就在终端里提示输入，输入时不显示，也不会保存。
    /// 局域网地址或加了 --no-key 时不要 Key
    private func readAPIKey() throws -> String {
        let environment = ProcessInfo.processInfo.environment
        var names = ["LLM_API_KEY"]
        if config.preset?.id == LLMProviderPreset.deepSeek.id { names.append("DEEPSEEK_API_KEY") }
        for name in names {
            if let key = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
                return key
            }
        }
        if noKey || config.isLocalNetwork { return "" }
        var buffer = [CChar](repeating: 0, count: 512)
        let host = (try? config.endpoint().host()) ?? "模型服务"
        guard readpassphrase("请粘贴 \(host) 的 API Key（输入时不会显示，直接回车表示不用 Key）：", &buffer, buffer.count, RPP_REQUIRE_TTY) != nil
        else {
            throw ProbeError("没有读到 API Key。请在终端里运行，或先设置环境变量 LLM_API_KEY")
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 测试连接：只发一条很短的文字请求
func runPing(_ args: [String]) async throws {
    var service = ServiceOptions()
    let rest = try service.parse(args)
    guard rest.isEmpty else { throw ProbeError("用法：ocrprobe ping \(ServiceOptions.usage)") }
    let client = try service.makeClient()
    print("向 \(client.endpoint.absoluteString)（\(service.config.model)）发送一条测试请求…")
    let clock = ContinuousClock()
    let start = clock.now
    let reply = try await client.ping()
    let ms = Int((start.duration(to: clock.now) / .milliseconds(1)).rounded())
    print("成功，用时 \(ms) ms。回复：\(reply.content.prefix(200))")
    if let usage = reply.usage { print("token：输入 \(usage.inputTokens) / 输出 \(usage.outputTokens)") }
}
