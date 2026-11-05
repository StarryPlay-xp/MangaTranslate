import Foundation
import MangaCore

/// 用户保存的一个模型服务：名称 + 连接参数。Key 不在这里，按 id 存在钥匙串里
nonisolated struct ModelService: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var config: LLMServiceConfig

    /// 从服务商预设新建
    init(preset: LLMProviderPreset) {
        name = preset.name
        config = preset.makeConfig()
    }

    /// 自己填地址的空白配置；本地小模型慢，默认等 5 分钟
    init(customFormat format: LLMAPIFormat) {
        name = ""
        config = LLMServiceConfig(format: format, baseURL: "", model: "", timeoutSeconds: 300)
    }

    init(id: UUID = UUID(), name: String, config: LLMServiceConfig) {
        self.id = id
        self.name = name
        self.config = config
    }

    /// 列表里的一行说明：格式 · 模型 · 主机名
    var summary: String {
        let host = (try? config.endpoint())?.host() ?? "地址未填写"
        let model = config.model.isEmpty ? "模型未填写" : config.model
        return "\(config.format.displayName) · \(model) · \(host)"
    }

    /// 地址匹配到要求 Key 的服务商（目前是 DeepSeek）时，没有 Key 就不发请求
    var requiresAPIKey: Bool { config.preset?.requiresAPIKey ?? false }

    /// 同时翻译几张图：局域网里的小模型一次只处理一张，免得排队超时
    var maxConcurrentRequests: Int { config.isLocalNetwork ? 1 : 2 }
}
