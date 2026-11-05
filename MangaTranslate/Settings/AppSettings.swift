import Foundation
import MangaCore
import Observation

/// App 的设置，保存在 UserDefaults；API Key 单独存在钥匙串里，这里只记录有没有
@Observable
final class AppSettings {
    private enum Keys {
        static let sourceLanguage = "sourceLanguage"
        static let autoTranslate = "autoTranslate"
        static let translatePageText = "translatePageText"
        static let sendImage = "sendImage"
        static let dryRun = "dryRun"
        static let modelServices = "modelServices"
        static let activeModelService = "activeModelService"
    }

    var sourceLanguage: SourceLanguage {
        didSet { UserDefaults.standard.set(sourceLanguage.rawValue, forKey: Keys.sourceLanguage) }
    }
    /// 浏览时自动翻译屏幕上和下方 1.5 屏以内的漫画图片
    var autoTranslate: Bool {
        didSet { UserDefaults.standard.set(autoTranslate, forKey: Keys.autoTranslate) }
    }
    /// 翻译网页上的日文、韩文文字（菜单、作品名、简介等），原地换成中文；关掉后恢复原文
    var translatePageText: Bool {
        didSet { UserDefaults.standard.set(translatePageText, forKey: Keys.translatePageText) }
    }
    /// 把带编号框的截图发给模型；关掉后只发识别出的文字。当前模型服务不支持看图时也只发文字
    var sendImage: Bool {
        didSet { UserDefaults.standard.set(sendImage, forKey: Keys.sendImage) }
    }
    /// 试运行：不调用模型，直接在原位置显示识别出的原文，用来检查识别效果
    var dryRun: Bool {
        didSet { UserDefaults.standard.set(dryRun, forKey: Keys.dryRun) }
    }

    /// 保存的模型服务，至少有一个
    private(set) var services: [ModelService]
    private(set) var activeServiceID: UUID
    /// 钥匙串里存了 Key 的模型服务
    private(set) var servicesWithKey: Set<UUID>

    /// 当前使用的模型服务
    var activeService: ModelService {
        services.first { $0.id == activeServiceID } ?? services[0]
    }

    /// 这次翻译实际要不要发图片
    var effectiveSendImage: Bool { sendImage && activeService.config.supportsImages }

    init() {
        let defaults = UserDefaults.standard
        sourceLanguage = defaults.string(forKey: Keys.sourceLanguage).flatMap(SourceLanguage.init(rawValue:)) ?? .japanese
        // 没设置过时默认开启；用 bool(forKey:) 读取，启动参数传入的 "YES"/"NO" 也能识别
        autoTranslate = defaults.object(forKey: Keys.autoTranslate) == nil ? true : defaults.bool(forKey: Keys.autoTranslate)
        translatePageText = defaults.bool(forKey: Keys.translatePageText)
        sendImage = defaults.object(forKey: Keys.sendImage) == nil ? true : defaults.bool(forKey: Keys.sendImage)
        dryRun = defaults.bool(forKey: Keys.dryRun)

        // 第一次启动（或从只支持 DeepSeek 的旧版升级）时，内置一份 DeepSeek 默认配置
        let saved = defaults.data(forKey: Keys.modelServices)
            .flatMap { try? JSONDecoder().decode([ModelService].self, from: $0) } ?? []
        let services = saved.isEmpty ? [ModelService(preset: .deepSeek)] : saved
        self.services = services
        let savedActive = defaults.string(forKey: Keys.activeModelService).flatMap(UUID.init(uuidString:))
        activeServiceID = services.contains { $0.id == savedActive } ? savedActive! : services[0].id
        servicesWithKey = Set(services.filter { KeychainStore.load(account: KeychainStore.account(for: $0.id)) != nil }.map(\.id))

        migrateLegacyKey()
        #if DEBUG
        applyDebugService()
        #endif
        persistServices()
    }

    // MARK: - 模型服务

    func hasAPIKey(for id: UUID) -> Bool { servicesWithKey.contains(id) }

    func apiKey(for id: UUID) -> String? {
        KeychainStore.load(account: KeychainStore.account(for: id))
    }

    /// 新增或更新；新增的服务自动设为当前使用
    func saveService(_ service: ModelService) {
        if let index = services.firstIndex(where: { $0.id == service.id }) {
            services[index] = service
        } else {
            services.append(service)
            activeServiceID = service.id
        }
        persistServices()
    }

    func selectService(_ id: UUID) {
        guard services.contains(where: { $0.id == id }) else { return }
        activeServiceID = id
        persistServices()
    }

    /// 删除服务和它的 Key；只剩一个时不能删
    func deleteService(_ id: UUID) {
        guard services.count > 1 else { return }
        deleteAPIKey(for: id)
        services.removeAll { $0.id == id }
        if activeServiceID == id { activeServiceID = services[0].id }
        persistServices()
    }

    func saveAPIKey(_ key: String, for id: UUID) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try KeychainStore.save(trimmed, account: KeychainStore.account(for: id))
        servicesWithKey.insert(id)
    }

    func deleteAPIKey(for id: UUID) {
        KeychainStore.delete(account: KeychainStore.account(for: id))
        servicesWithKey.remove(id)
    }

    private func persistServices() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(services) { defaults.set(data, forKey: Keys.modelServices) }
        defaults.set(activeServiceID.uuidString, forKey: Keys.activeModelService)
    }

    /// 旧版的 DeepSeek Key 搬到第一个还没有 Key 的 DeepSeek 配置里，老用户升级后不用重填。
    /// 搬成功才删除旧的；中途失败的话下次启动会再搬一次
    private func migrateLegacyKey() {
        guard let legacy = KeychainStore.load(account: KeychainStore.legacyAccount) else { return }
        var target = services.first { $0.config.preset?.id == LLMProviderPreset.deepSeek.id && !hasAPIKey(for: $0.id) }
        if target == nil, !services.contains(where: { $0.config.preset?.id == LLMProviderPreset.deepSeek.id }) {
            let deepSeek = ModelService(preset: .deepSeek)
            services.append(deepSeek)
            target = deepSeek
        }
        guard let target else {
            // DeepSeek 配置都已经有 Key 了，旧的不再需要
            KeychainStore.delete(account: KeychainStore.legacyAccount)
            return
        }
        do {
            try saveAPIKey(legacy, for: target.id)
            KeychainStore.delete(account: KeychainStore.legacyAccount)
        } catch {
            // 留着旧 Key，下次启动再试
        }
    }

    #if DEBUG
    /// 调试用：启动参数 -debugService "openai|http://127.0.0.1:8765|mock-model" 添加（或更新）一个调试服务并设为当前使用；
    /// -debugServiceKey 给它存一把假 Key，用来检查请求头。只给本机的模拟服务用
    private func applyDebugService() {
        let defaults = UserDefaults.standard
        guard let spec = defaults.string(forKey: "debugService") else { return }
        let parts = spec.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, let format = LLMAPIFormat(rawValue: parts[0]) else { return }
        let name = "调试 · \(format.displayName)"
        var service = services.first { $0.name == name } ?? ModelService(customFormat: format)
        service.name = name
        service.config.baseURL = parts[1]
        service.config.model = parts[2]
        service.config.supportsImages = !parts.dropFirst(3).contains("text")
        service.config.jsonMode = !parts.dropFirst(3).contains("nojson")
        service.config.timeoutSeconds = 60
        if let index = services.firstIndex(where: { $0.id == service.id }) {
            services[index] = service
        } else {
            services.append(service)
        }
        activeServiceID = service.id
        if let key = defaults.string(forKey: "debugServiceKey") {
            try? saveAPIKey(key, for: service.id)
        }
    }
    #endif
}
