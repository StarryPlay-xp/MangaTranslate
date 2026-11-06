import CoreGraphics
import Foundation
import MangaCore

/// 小助手的主体：收插件的消息、识别、翻译、回复。所有状态都在这个 actor 里，按消息到达的顺序处理，
/// 耗时的翻译另开任务，不挡住后面的消息
public actor Helper {
    public static let version = "1"

    let paths: HelperPaths
    let writer: MessageWriter
    let keys: any KeyStore
    var settings: HelperSettings
    let cache: TranslationCache
    let memoryBank: MemoryBank
    let textCache: PageTextCache
    let usage: UsageLedger

    /// 所有图片共用的模型请求名额（云端 4、局域网 1、试运行 2）
    let requestGate = RequestGate()
    /// 文字识别名额：同时最多识别 2 段，免得提前翻的图抢走屏幕上这张的识别算力
    let recognitionGate = RequestGate()
    static let maxConcurrentRecognitions = 2
    /// 第一个字过了这么久还没来，就再发一份同样的请求
    static let hedgeAfter: Duration = .seconds(4)
    /// 收到新的块后等这么久再推送，连续到达的几块合成一次
    static let partialDelay: Duration = .milliseconds(80)

    /// 正在翻译的图片
    var jobs: [String: ImageJob] = [:]
    /// 上次预先连接的时间，30 秒内不重复
    var lastWarmUp: ContinuousClock.Instant?

    public init(paths: HelperPaths, writer: MessageWriter) {
        self.paths = paths
        self.writer = writer
        keys = makeKeyStore(paths: paths)
        settings = HelperSettings.load(from: paths.settingsFile)
        // 第一次启动就把默认设置写下来：服务编号要固定，Key 按编号保存
        if !FileManager.default.fileExists(atPath: paths.settingsFile.path) {
            try? settings.save(to: paths.settingsFile)
        }
        cache = TranslationCache(directory: paths.translations)
        memoryBank = MemoryBank(directory: paths.memories)
        textCache = PageTextCache(directory: paths.translations)
        usage = UsageLedger(file: paths.usageFile)
    }

    // MARK: - 分发

    public func handle(_ data: Data) {
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(Envelope.self, from: data) else {
            HelperLog.write("收到无法解析的消息（\(data.count) 字节）")
            return
        }
        let id = envelope.id ?? 0
        do {
            switch envelope.type {
            case "hello":
                reply(id, hello())
            case "getSettings":
                reply(id, settingsResult())
            case "saveService":
                reply(id, try saveService(decoder.decode(SaveServiceRequest.self, from: data)))
            case "deleteService":
                reply(id, try deleteService(decoder.decode(ServiceIDRequest.self, from: data).serviceID))
            case "setActive":
                reply(id, try setActive(decoder.decode(ServiceIDRequest.self, from: data).serviceID))
            case "setKey":
                let request = try decoder.decode(SetKeyRequest.self, from: data)
                try keys.setKey(request.key.trimmingCharacters(in: .whitespacesAndNewlines), for: request.serviceID)
                reply(id, settingsResult())
            case "clearKey":
                keys.deleteKey(for: try decoder.decode(ServiceIDRequest.self, from: data).serviceID)
                reply(id, settingsResult())
            case "setSendImage":
                settings.sendImage = try decoder.decode(SetSendImageRequest.self, from: data).sendImage
                try settings.save(to: paths.settingsFile)
                reply(id, settingsResult())
            case "testConnection":
                let request = try decoder.decode(TestConnectionRequest.self, from: data)
                Task { await testConnection(request, id: id) }
            case "usage":
                reply(id, usageResult())
            case "clearUsage":
                usage.clear()
                reply(id, usageResult())
            case "warmup":
                warmUp()
                reply(id, Empty())
            case "lookupImage":
                reply(id, lookupImage(try decoder.decode(LookupImageRequest.self, from: data)))
            case "translateImage":
                let request = try decoder.decode(TranslateImageRequest.self, from: data)
                Task { await translateImage(request) }
            case "translateScreen":
                let request = try decoder.decode(TranslateScreenRequest.self, from: data)
                Task { await translateScreen(request) }
            case "cancel":
                for job in try decoder.decode(CancelRequest.self, from: data).jobs { jobs[job]?.cancelled = true }
            case "lookupText":
                reply(id, lookupText(try decoder.decode(LookupTextRequest.self, from: data)))
            case "translateText":
                let request = try decoder.decode(TranslateTextRequest.self, from: data)
                Task { await translateText(request, id: id) }
            default:
                fail(id, "小助手不认识这条消息（\(envelope.type)），请更新小助手")
            }
        } catch {
            fail(id, error.localizedDescription)
        }
    }

    func reply(_ id: Int, _ result: some Encodable) {
        writer.send(Reply(id: id, result: result))
    }

    func fail(_ id: Int, _ message: String, stopsAll: Bool = false, needsSettings: Bool = false) {
        writer.send(ErrorReply(id: id, error: message, stopsAll: stopsAll, needsSettings: needsSettings))
    }

    func send(_ event: some Encodable) {
        writer.send(event)
    }

    // MARK: - 设置

    func serviceInfo(_ service: ModelService) -> ServiceInfo {
        ServiceInfo(
            id: service.id, name: service.name, config: service.config, hasKey: keys.key(for: service.id) != nil,
            requiresKey: service.requiresAPIKey, isLocal: service.config.isLocalNetwork,
            hasPricing: service.config.pricing != nil)
    }

    func hello() -> HelloResult {
        let service = settings.activeService
        let info = serviceInfo(service)
        return HelloResult(
            version: Self.version, service: info, ready: info.hasKey || !service.requiresAPIKey,
            imageLimit: service.maxConcurrentImageRequests, textLimit: service.maxConcurrentRequests)
    }

    func settingsResult() -> SettingsResult {
        SettingsResult(
            services: settings.services.map(serviceInfo), activeServiceID: settings.activeServiceID,
            sendImage: settings.sendImage,
            presets: LLMProviderPreset.all.map { preset in
                PresetInfo(
                    id: preset.id, name: preset.name, format: preset.format, baseURL: preset.baseURL,
                    model: preset.defaultModel, requiresKey: preset.requiresAPIKey)
            })
    }

    func saveService(_ request: SaveServiceRequest) throws -> SettingsResult {
        let draft = request.service
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        var config = draft.config
        config.baseURL = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        config.model = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !config.model.isEmpty else { throw MangaCoreError("请填写模型名") }
        _ = try config.endpoint()
        let service = ModelService(
            id: draft.id ?? UUID(), name: name.isEmpty ? config.model : name, config: config)
        if let index = settings.services.firstIndex(where: { $0.id == service.id }) {
            settings.services[index] = service
        } else {
            settings.services.append(service)
        }
        if request.activate == true { settings.activeServiceID = service.id }
        if let key = request.key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            try keys.setKey(key, for: service.id)
        }
        try settings.save(to: paths.settingsFile)
        return settingsResult()
    }

    func deleteService(_ serviceID: UUID) throws -> SettingsResult {
        guard settings.services.count > 1 else { throw MangaCoreError("至少要保留一个模型服务") }
        settings.services.removeAll { $0.id == serviceID }
        keys.deleteKey(for: serviceID)
        if settings.activeServiceID == serviceID { settings.activeServiceID = settings.services[0].id }
        try settings.save(to: paths.settingsFile)
        return settingsResult()
    }

    func setActive(_ serviceID: UUID) throws -> SettingsResult {
        guard settings.services.contains(where: { $0.id == serviceID }) else { throw MangaCoreError("找不到这个模型服务") }
        settings.activeServiceID = serviceID
        try settings.save(to: paths.settingsFile)
        return settingsResult()
    }

    func usageResult() -> UsageResult {
        let book = usage.book
        return UsageResult(
            today: UsageTotalInfo(book.total(onDay: .now)),
            thisMonth: UsageTotalInfo(book.total(monthOf: .now)),
            lastMonth: UsageTotalInfo(book.total(monthOf: .now, monthsAgo: 1)),
            total: UsageTotalInfo(book.total()),
            activeHasPricing: settings.activeService.config.pricing != nil)
    }

    func testConnection(_ request: TestConnectionRequest, id: Int) async {
        let config = request.service.config
        let typed = request.key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let key = typed.isEmpty ? request.service.id.flatMap { keys.key(for: $0) } : typed
        let started = ContinuousClock.now
        do {
            let reply = try await config.makeClient(apiKey: key).ping()
            let seconds = (ContinuousClock.now - started) / .seconds(1)
            if let replyUsage = reply.usage { usage.record(replyUsage, config: config) }
            self.reply(id, TestResult(message: Self.describe(reply, seconds: seconds, pricing: config.pricing)))
        } catch {
            fail(id, error.localizedDescription)
        }
    }

    static func describe(_ reply: LLMReply, seconds: Double, pricing: LLMPricing?) -> String {
        var text = seconds < 0.1 ? "连接成功，用时不到 0.1 秒。" : String(format: "连接成功，用时 %.1f 秒。", seconds)
        let content = LLMJSON.stripThinking(reply.content).trimmingCharacters(in: .whitespacesAndNewlines)
        if content.isEmpty {
            text += "不过模型没有回复文字，可能只输出了思考过程。"
        } else {
            text += "模型回复：" + (content.count > 80 ? content.prefix(80) + "…" : content)
            if !LLMJSON.containsJSON(content) {
                text += "\n注意：回复里没有 json，翻译时可能解析失败。"
            }
        }
        if let usage = reply.usage {
            text += "\n输入 \(usage.inputTokens) / 输出 \(usage.outputTokens) token"
            if let pricing {
                text += String(format: "，约 $%.6f", pricing.cost(of: usage, peak: pricing.isPeak(Date())))
            }
        }
        return text
    }

    /// 先和模型服务建立连接、完成加密握手，第一张图发请求时直接复用。只发不带 Key、不带内容的 HEAD
    func warmUp() {
        guard let url = try? settings.activeService.config.endpoint() else { return }
        if let lastWarmUp, ContinuousClock.now - lastWarmUp < .seconds(30) { return }
        lastWarmUp = .now
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "HEAD"
        Task.detached { _ = try? await URLSession.shared.data(for: request) }
    }

    // MARK: - 模型客户端

    struct Blocked: Error {
        var message: String
    }

    /// 当前服务的客户端；缺 Key 或地址不对时抛出 Blocked（自动翻译应整体停下）
    func makeClient(for service: ModelService) throws -> any LLMClient {
        let key = keys.key(for: service.id)
        if key == nil && service.requiresAPIKey {
            throw Blocked(message: "「\(service.name)」还没有填写 API Key")
        }
        do {
            return try service.config.makeClient(apiKey: key)
        } catch {
            throw Blocked(message: "「\(service.name)」\(error.localizedDescription)")
        }
    }

    func requestLimit(dryRun: Bool) -> Int {
        dryRun ? 2 : settings.activeService.maxConcurrentImageRequests
    }
}

func decodeBase64Image(_ text: String) async throws -> CGImage {
    // data URL 也能直接传进来
    let base64 = text.range(of: "base64,").map { String(text[$0.upperBound...]) } ?? text
    guard let data = Data(base64Encoded: base64) else { throw MangaCoreError("图片数据不完整") }
    return try await ImagePipeline.decode(data)
}

func seconds(_ duration: Duration) -> String {
    String(format: "%.2f 秒", duration / .seconds(1))
}
