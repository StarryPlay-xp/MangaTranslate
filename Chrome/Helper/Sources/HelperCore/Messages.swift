import Foundation
import MangaCore

// 插件和小助手之间的消息。插件发来的每条消息都有 type；需要回复的带 id，小助手用 {type: "reply", id} 回复。
// 图片翻译按 job 推送事件：working（开始识别）→ partial（流式先贴的部分，可能多次）→ done 或 failed

/// 只看类型和编号，再按类型解码完整内容
struct Envelope: Decodable {
    var type: String
    var id: Int?
}

/// 查缓存：普通图片先查，命中就不用下载
struct LookupImageRequest: Decodable {
    var src: String
    var language: SourceLanguage
    var dryRun: Bool?
}

struct TranslateImageRequest: Decodable {
    var job: String
    /// 图片内容（base64）
    var image: String
    /// 图片地址；canvas 截图为空，缓存按截图内容算
    var src: String
    var isCanvas: Bool
    /// 页面的域名，术语表按它保存
    var host: String
    var language: SourceLanguage
    var dryRun: Bool?
}

struct TranslateScreenRequest: Decodable {
    var job: String
    /// 可视区域截图（base64）
    var image: String
    /// 截图时网页可视区域在文档中的位置（CSS 像素）
    var viewport: Viewport
    var host: String
    var language: SourceLanguage
    var dryRun: Bool?
}

struct CancelRequest: Decodable {
    var jobs: [String]
}

struct LookupTextRequest: Decodable {
    var texts: [String]
    var language: SourceLanguage
    var dryRun: Bool?
}

struct TranslateTextRequest: Decodable {
    var texts: [String]
    var host: String
    var language: SourceLanguage
    var dryRun: Bool?
}

/// 设置页编辑中的服务：新建时没有 id
struct ServiceDraft: Decodable {
    var id: UUID?
    var name: String
    var config: LLMServiceConfig
}

struct SaveServiceRequest: Decodable {
    var service: ServiceDraft
    /// 新填的 Key；为空或没有时保留原来的
    var key: String?
    /// 保存后设为当前服务
    var activate: Bool?
}

struct ServiceIDRequest: Decodable {
    var serviceID: UUID
}

struct SetKeyRequest: Decodable {
    var serviceID: UUID
    var key: String
}

struct SetSendImageRequest: Decodable {
    var sendImage: Bool
}

/// 测试连接：可以测还没保存的草稿，Key 没填时用已保存的
struct TestConnectionRequest: Decodable {
    var service: ServiceDraft
    var key: String?
}

// MARK: - 发给插件的消息

struct Reply<Result: Encodable>: Encodable {
    var type = "reply"
    var id: Int
    var ok = true
    var result: Result
}

struct ErrorReply: Encodable {
    var type = "reply"
    var id: Int
    var ok = false
    var error: String
    /// 服务不可用（Key 无效、余额不足、连不上），后面的请求也会失败
    var stopsAll = false
    /// 需要去设置里改模型服务才能解决
    var needsSettings = false
}

struct Empty: Encodable {}

struct JobEvent: Encodable {
    var type: String
    var job: String
    var items: [ImageOverlayItem]?
    var cached: Bool?
    var message: String?
    var stopsAll: Bool?
    var needsSettings: Bool?
    /// 自动翻译被关掉或取消了：去掉标记，之后可以重新排队
    var abandoned: Bool?

    static func working(_ job: String) -> JobEvent { JobEvent(type: "working", job: job) }

    static func partial(_ job: String, items: [ImageOverlayItem]) -> JobEvent {
        JobEvent(type: "partial", job: job, items: items)
    }

    static func done(_ job: String, items: [ImageOverlayItem], cached: Bool = false) -> JobEvent {
        JobEvent(type: "done", job: job, items: items, cached: cached)
    }

    static func failed(_ job: String, message: String, stopsAll: Bool = false, needsSettings: Bool = false)
        -> JobEvent
    {
        JobEvent(type: "failed", job: job, message: message, stopsAll: stopsAll, needsSettings: needsSettings)
    }

    static func abandoned(_ job: String) -> JobEvent {
        JobEvent(type: "failed", job: job, message: "已取消", abandoned: true)
    }
}

/// 整屏翻译的结果：译文已换算成网页文档坐标
struct ScreenEvent: Encodable {
    var type = "screenDone"
    var job: String
    var overlay: [OverlayItem]
    var blockCount: Int
}

struct ServiceInfo: Encodable {
    var id: UUID
    var name: String
    var config: LLMServiceConfig
    var hasKey: Bool
    var requiresKey: Bool
    var isLocal: Bool
    var hasPricing: Bool
}

struct PresetInfo: Encodable {
    var id: String
    var name: String
    var format: LLMAPIFormat
    var baseURL: String
    var model: String
    var requiresKey: Bool
}

struct SettingsResult: Encodable {
    var services: [ServiceInfo]
    var activeServiceID: UUID
    var sendImage: Bool
    var presets: [PresetInfo]
}

struct HelloResult: Encodable {
    var version: String
    var service: ServiceInfo
    /// 当前服务能用（不需要 Key 或已经填了 Key）
    var ready: Bool
    /// 同时处理几张图、同时发几个网页文字请求
    var imageLimit: Int
    var textLimit: Int
}

struct UsageTotalInfo: Encodable {
    var requests: Int
    var inputTokens: Int
    var cachedInputTokens: Int
    var outputTokens: Int
    var costUSD: Double

    init(_ total: UsageTotal) {
        requests = total.requests
        inputTokens = total.inputTokens
        cachedInputTokens = total.cachedInputTokens
        outputTokens = total.outputTokens
        costUSD = total.costUSD
    }
}

struct UsageResult: Encodable {
    var today: UsageTotalInfo
    var thisMonth: UsageTotalInfo
    var lastMonth: UsageTotalInfo
    var total: UsageTotalInfo
    /// 当前服务有没有价格（没有价格的服务不记账）
    var activeHasPricing: Bool
}

struct LookupImageResult: Encodable {
    var items: [ImageOverlayItem]?
}

struct TextResult: Encodable {
    var translations: [String?]
}

struct TestResult: Encodable {
    var message: String
}
