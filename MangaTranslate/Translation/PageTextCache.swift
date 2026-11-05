import CryptoKit
import Foundation
import MangaCore

/// 网页文字的译文缓存：原文 → 译文，按模型服务和原文语言分文件保存在 Caches/Translations 里，
/// 和图片译文缓存一起统计大小、一起清除。网站的菜单、按钮在各页反复出现，命中缓存就不用再花钱
final class PageTextCache {
    static let shared = PageTextCache()

    /// 提示词改了就加一，让旧缓存失效
    private static let version = 1
    /// 每个文件最多存这么多条，超出时丢掉最早的
    private static let capacity = 5000

    private struct Store: Codable {
        var keys: [String] = []
        var values: [String: String] = [:]
    }

    private var stores: [String: Store] = [:]

    /// 接口格式、完整请求地址、模型名和原文语言都算进去，换了任何一项都重新翻译
    static func context(language: SourceLanguage, service: LLMServiceConfig) -> String {
        let endpoint = (try? service.endpoint().absoluteString) ?? service.baseURL
        let parts = ["text-v\(version)", language.rawValue, service.format.rawValue, endpoint, service.model]
        let digest = SHA256.hash(data: Data(parts.joined(separator: "|").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func translation(of text: String, context: String) -> String? {
        store(for: context).values[text]
    }

    func save(_ pairs: [(source: String, translation: String)], context: String) {
        guard !pairs.isEmpty else { return }
        var store = store(for: context)
        for pair in pairs where store.values[pair.source] == nil {
            store.keys.append(pair.source)
            store.values[pair.source] = pair.translation
        }
        if store.keys.count > Self.capacity {
            let overflow = store.keys.count - Self.capacity
            for key in store.keys.prefix(overflow) { store.values[key] = nil }
            store.keys.removeFirst(overflow)
        }
        stores[context] = store
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(store).write(to: Self.fileURL(for: context), options: .atomic)
    }

    /// 文件已经由 TranslationCache.clear() 删掉，这里只清内存
    func clearMemory() {
        stores.removeAll()
    }

    private func store(for context: String) -> Store {
        if let store = stores[context] { return store }
        let loaded = (try? Data(contentsOf: Self.fileURL(for: context)))
            .flatMap { try? JSONDecoder().decode(Store.self, from: $0) } ?? Store()
        stores[context] = loaded
        return loaded
    }

    private static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Translations", isDirectory: true)
    }

    private static func fileURL(for context: String) -> URL {
        directory.appendingPathComponent("text-" + context + ".json")
    }
}
