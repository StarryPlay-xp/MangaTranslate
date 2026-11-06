import CryptoKit
import Foundation
import MangaCore

// 下面几个存储都只在 Helper actor 里使用，规则和 App 里的同名类型一致，只是目录换成小助手自己的

struct CachedImageTranslation: Codable, Sendable {
    var items: [ImageOverlayItem]
}

/// 已翻译图片的译文缓存，按图片地址（canvas 按截图内容）和所用的模型服务保存
final class TranslationCache {
    /// 和 App 的 TranslationCache.version 保持一致：提示词或贴字规则改了就一起加一
    static let version = 4

    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    /// 接口格式、完整请求地址和模型名都算进去，换服务或换模型后才会重新翻译
    static func key(src: String, language: SourceLanguage, sendImage: Bool, service: LLMServiceConfig) -> String {
        let endpoint = (try? service.endpoint().absoluteString) ?? service.baseURL
        let parts = ["v\(version)", language.rawValue, "\(sendImage)", service.format.rawValue, endpoint, service.model, src]
        return sha256Hex(parts.joined(separator: "|"))
    }

    func load(_ key: String) -> CachedImageTranslation? {
        guard let data = try? Data(contentsOf: fileURL(for: key)) else { return nil }
        return try? JSONDecoder().decode(CachedImageTranslation.self, from: data)
    }

    func save(_ translation: CachedImageTranslation, for key: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(translation).write(to: fileURL(for: key), options: .atomic)
    }

    private func fileURL(for key: String) -> URL {
        directory.appendingPathComponent(key + ".json")
    }
}

/// 按网站保存术语表和最近的译文，下次看同一网站时继续沿用，译名保持一致
final class MemoryBank {
    private var memories: [String: TranslationMemory] = [:]
    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    func memory(for host: String) -> TranslationMemory {
        if let memory = memories[host] { return memory }
        let loaded = (try? Data(contentsOf: fileURL(for: host)))
            .flatMap { try? JSONDecoder().decode(TranslationMemory.self, from: $0) } ?? TranslationMemory()
        memories[host] = loaded
        return loaded
    }

    func record(_ translation: PageTranslation, host: String) {
        var memory = memory(for: host)
        memory.record(translation)
        memories[host] = memory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(memory).write(to: fileURL(for: host), options: .atomic)
    }

    /// 网站域名里只保留字母、数字、点和横线，作为文件名
    private func fileURL(for host: String) -> URL {
        let safe = String(host.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" })
        return directory.appendingPathComponent((safe.isEmpty ? "local" : safe) + ".json")
    }
}

/// 网页文字的译文缓存：原文 → 译文，按模型服务和原文语言分文件保存，和图片译文缓存放在同一个目录
final class PageTextCache {
    /// 和 App 的 PageTextCache.version 保持一致
    static let version = 1
    /// 每个文件最多存这么多条，超出时丢掉最早的
    static let capacity = 5000

    private struct Store: Codable {
        var keys: [String] = []
        var values: [String: String] = [:]
    }

    private var stores: [String: Store] = [:]
    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    static func context(language: SourceLanguage, service: LLMServiceConfig) -> String {
        let endpoint = (try? service.endpoint().absoluteString) ?? service.baseURL
        return sha256Hex(["text-v\(version)", language.rawValue, service.format.rawValue, endpoint, service.model]
            .joined(separator: "|"))
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
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(store).write(to: fileURL(for: context), options: .atomic)
    }

    private func store(for context: String) -> Store {
        if let store = stores[context] { return store }
        let loaded = (try? Data(contentsOf: fileURL(for: context)))
            .flatMap { try? JSONDecoder().decode(Store.self, from: $0) } ?? Store()
        stores[context] = loaded
        return loaded
    }

    private func fileURL(for context: String) -> URL {
        directory.appendingPathComponent("text-" + context + ".json")
    }
}

/// DeepSeek 用量账本：只给有价格的模型（目前是 deepseek-flash）记账，只存每天的合计
final class UsageLedger {
    private(set) var book: UsageBook
    private let file: URL
    /// 只留最近这么多天，够看上个月和更早一点的累计
    private static let keepingDays = 400

    init(file: URL) {
        self.file = file
        var book = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(UsageBook.self, from: $0) }
            ?? UsageBook()
        book.removeDays(olderThan: Self.keepingDays, before: .now)
        self.book = book
    }

    func record(_ usage: LLMUsage, config: LLMServiceConfig, at date: Date = .now) {
        guard let pricing = config.pricing else { return }
        book.add(usage, model: config.model, costUSD: pricing.cost(of: usage, peak: pricing.isPeak(date)), at: date)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try? JSONEncoder().encode(book).write(to: file, options: .atomic)
    }

    func clear() {
        book = UsageBook()
        try? FileManager.default.removeItem(at: file)
    }
}

/// 限制同时进行的任务数（模型请求、文字识别），多出来的按先来后到排队。
/// 只在 Helper actor 里使用；上限在每次申请时传入，切换模型服务后从下一次申请起生效
final class RequestGate {
    private var running = 0
    private var limit = 1
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// 在调用方的 actor 上等待，不离开 Helper actor
    func acquire(limit: Int, isolation: isolated (any Actor)? = #isolation) async {
        self.limit = max(1, limit)
        if running < self.limit, waiting.isEmpty {
            running += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        running -= 1
        while running < limit, !waiting.isEmpty {
            running += 1
            waiting.removeFirst().resume()
        }
    }
}

func sha256Hex(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}
