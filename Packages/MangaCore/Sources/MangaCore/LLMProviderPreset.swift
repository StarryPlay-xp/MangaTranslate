import Foundation

/// 服务商预设：接口格式、地址、默认模型、专用参数和价格。
/// 用户的配置只要地址和格式与某个预设一致，就按这个预设发专用参数、估算费用。
/// 目前只有 DeepSeek；以后按成本挑服务商时，在 all 里加条目即可
public struct LLMProviderPreset: Sendable, Identifiable {
    /// 只有某个服务商才认的参数
    public enum Quirk: Sendable, Hashable {
        /// DeepSeek 的 thinking: {type: enabled/disabled}
        case deepSeekThinking
    }

    public var id: String
    public var name: String
    public var format: LLMAPIFormat
    public var baseURL: String
    public var defaultModel: String
    public var supportsImages: Bool
    public var jsonMode: Bool
    /// 必须填 Key 才能用；没填时直接提示，不发请求
    public var requiresAPIKey: Bool
    public var quirks: Set<Quirk>
    public var prices: [LLMPricing]

    public func pricing(for model: String) -> LLMPricing? {
        prices.first { $0.model == model }
    }

    public func makeConfig() -> LLMServiceConfig {
        LLMServiceConfig(
            format: format, baseURL: baseURL, model: defaultModel, supportsImages: supportsImages, jsonMode: jsonMode)
    }

    public static let deepSeek = LLMProviderPreset(
        id: "deepseek", name: "DeepSeek", format: .openAICompatible, baseURL: "https://api.deepseek.com",
        defaultModel: "deepseek-flash", supportsImages: true, jsonMode: true, requiresAPIKey: true,
        quirks: [.deepSeekThinking], prices: [.deepSeekFlash])

    public static let all: [LLMProviderPreset] = [.deepSeek]

    /// 格式相同、主机名相同就算匹配
    public static func matching(_ config: LLMServiceConfig) -> LLMProviderPreset? {
        guard let host = (try? config.endpoint())?.host()?.lowercased() else { return nil }
        return all.first { preset in
            preset.format == config.format && (try? preset.makeConfig().endpoint())?.host()?.lowercased() == host
        }
    }
}

/// 模型价格（美元 / 百万 token）
public struct LLMPricing: Sendable {
    public struct Rates: Sendable, Equatable {
        public var cacheHitInput: Double
        public var cacheMissInput: Double
        public var output: Double
    }

    public var model: String
    public var standard: Rates
    /// 有高峰价时才有
    public var peak: Rates?
    let peakSchedule: (@Sendable (Date) -> Bool)?

    public func isPeak(_ date: Date) -> Bool {
        peak != nil && (peakSchedule?(date) ?? false)
    }

    public func cost(of usage: LLMUsage, peak: Bool) -> Double {
        let rates = peak ? (self.peak ?? standard) : standard
        let hit = Double(usage.cachedInputTokens ?? 0)
        let miss = Double(usage.inputTokens) - hit
        return (hit * rates.cacheHitInput + miss * rates.cacheMissInput + Double(usage.outputTokens) * rates.output)
            / 1_000_000
    }

    /// deepseek-flash 的官方价格，2026-11-04 核实，以后可能调整。
    /// 高峰时段：工作日 UTC 01–04 点和 06–10 点（北京时间 9–12 点、14–18 点）；这里没有扣除中国法定节假日
    public static let deepSeekFlash = LLMPricing(
        model: "deepseek-flash",
        standard: Rates(cacheHitInput: 0.003, cacheMissInput: 0.15, output: 0.6),
        peak: Rates(cacheHitInput: 0.006, cacheMissInput: 0.3, output: 1.2),
        peakSchedule: { date in
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            let weekday = calendar.component(.weekday, from: date)  // 1 是周日
            let hour = calendar.component(.hour, from: date)
            return (2...6).contains(weekday) && ((1..<4).contains(hour) || (6..<10).contains(hour))
        })
}
