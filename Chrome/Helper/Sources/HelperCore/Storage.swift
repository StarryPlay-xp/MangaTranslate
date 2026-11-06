import Foundation
import MangaCore
import Security

/// 小助手的数据放在哪里。都在这台 Mac 上，和 iPhone/iPad 上的 App 互不相通。
/// 设置了环境变量 MANGA_HELPER_HOME 时（只用于测试）全部放进那个目录，Key 也改存文件、不碰钥匙串
public struct HelperPaths: Sendable {
    /// 设置、术语、用量、日志
    public var support: URL
    /// 译文缓存
    public var caches: URL
    /// 测试时存 Key 的文件；正式使用时为 nil，Key 存在钥匙串
    public var testKeyFile: URL?

    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> HelperPaths {
        if let home = environment["MANGA_HELPER_HOME"], !home.isEmpty {
            let root = URL(fileURLWithPath: home, isDirectory: true)
            return HelperPaths(
                support: root.appendingPathComponent("support", isDirectory: true),
                caches: root.appendingPathComponent("caches", isDirectory: true),
                testKeyFile: root.appendingPathComponent("keys.json"))
        }
        let folder = "MangaTranslate Chrome"
        let manager = FileManager.default
        return HelperPaths(
            support: manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(folder, isDirectory: true),
            caches: manager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(folder, isDirectory: true),
            testKeyFile: nil)
    }

    public var settingsFile: URL { support.appendingPathComponent("settings.json") }
    public var memories: URL { support.appendingPathComponent("Memories", isDirectory: true) }
    public var usageFile: URL { support.appendingPathComponent("Usage/usage.json") }
    public var logFile: URL { support.appendingPathComponent("helper.log") }
    public var translations: URL { caches.appendingPathComponent("Translations", isDirectory: true) }
}

/// 用户保存的一个模型服务：名称 + 连接参数。Key 不在这里，按 id 单独保存
public struct ModelService: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var config: LLMServiceConfig

    public init(id: UUID = UUID(), name: String, config: LLMServiceConfig) {
        self.id = id
        self.name = name
        self.config = config
    }

    public init(preset: LLMProviderPreset) {
        self.init(name: preset.name, config: preset.makeConfig())
    }

    /// 地址匹配到要求 Key 的服务商（目前是 DeepSeek）时，没有 Key 就不发请求
    public var requiresAPIKey: Bool { config.preset?.requiresAPIKey ?? false }

    /// 网页文字翻译同时发出的请求数：局域网里的小模型一次只处理一个
    public var maxConcurrentRequests: Int { config.isLocalNetwork ? 1 : 2 }

    /// 翻译漫画图片时同时发出的模型请求数，和 App 一样：云端 4 个，局域网 1 个
    public var maxConcurrentImageRequests: Int { config.isLocalNetwork ? 1 : 4 }
}

/// 小助手的设置，存在 settings.json
public struct HelperSettings: Codable, Sendable, Equatable {
    public var services: [ModelService]
    public var activeServiceID: UUID
    /// 把编号图一起发给模型（模型不能看图时自动只发文字）
    public var sendImage: Bool

    public init(services: [ModelService], activeServiceID: UUID, sendImage: Bool = true) {
        self.services = services
        self.activeServiceID = activeServiceID
        self.sendImage = sendImage
    }

    /// 第一次使用：只有一个 DeepSeek
    public static func initial() -> HelperSettings {
        let deepSeek = ModelService(preset: .deepSeek)
        return HelperSettings(services: [deepSeek], activeServiceID: deepSeek.id)
    }

    public var activeService: ModelService {
        services.first { $0.id == activeServiceID } ?? services[0]
    }

    public var effectiveSendImage: Bool { sendImage && activeService.config.supportsImages }

    public static func load(from url: URL) -> HelperSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(HelperSettings.self, from: data),
              !settings.services.isEmpty
        else { return .initial() }
        return settings
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// 保存各个模型服务的 API Key
public protocol KeyStore: Sendable {
    func key(for serviceID: UUID) -> String?
    func setKey(_ key: String, for serviceID: UUID) throws
    func deleteKey(for serviceID: UUID)
}

public func makeKeyStore(paths: HelperPaths) -> any KeyStore {
    if let file = paths.testKeyFile { return FileKeyStore(file: file) }
    return KeychainKeyStore()
}

/// Mac 登录钥匙串里的通用密码。小助手没有签名，重新编译后第一次读取时 macOS 可能弹窗询问，选"始终允许"即可
public struct KeychainKeyStore: KeyStore {
    private static let service = "io.github.starryplay-xp.MangaTranslate.chrome"

    public init() {}

    private func query(for serviceID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: "llm-api-key-" + serviceID.uuidString,
        ]
    }

    public func key(for serviceID: UUID) -> String? {
        var query = query(for: serviceID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public func setKey(_ key: String, for serviceID: UUID) throws {
        SecItemDelete(query(for: serviceID) as CFDictionary)
        var query = query(for: serviceID)
        query[kSecValueData as String] = Data(key.utf8)
        query[kSecAttrLabel as String] = "漫译 Chrome 插件 API Key"
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw MangaCoreError("保存到钥匙串失败（错误码 \(status)）") }
    }

    public func deleteKey(for serviceID: UUID) {
        SecItemDelete(query(for: serviceID) as CFDictionary)
    }
}

/// 只用于测试：Key 存在测试目录里的一个文件（权限 600），不碰真实钥匙串
public struct FileKeyStore: KeyStore {
    let file: URL

    private func load() -> [String: String] {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    private func save(_ keys: [String: String]) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(keys).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    public func key(for serviceID: UUID) -> String? { load()[serviceID.uuidString] }

    public func setKey(_ key: String, for serviceID: UUID) throws {
        var keys = load()
        keys[serviceID.uuidString] = key
        try save(keys)
    }

    public func deleteKey(for serviceID: UUID) {
        var keys = load()
        keys[serviceID.uuidString] = nil
        try? save(keys)
    }
}
