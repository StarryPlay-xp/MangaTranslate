import Foundation
import MangaCore
import Observation

/// DeepSeek 用量账本：每次调用有价格的模型（目前只有 deepseek-flash）后，记下 token 数和按官方价估算的费用。
/// 只存每天的合计，不存请求内容；其他模型服务没有价格，不记账。存在 Application Support/Usage/usage.json
@Observable
final class UsageLedger {
    private(set) var book: UsageBook
    /// 放了调试用示例数据时不写文件，免得示例数据混进真实账本
    private var persists = true

    /// 只留最近这么多天，够看上个月和更早一点的累计
    private static let keepingDays = 400

    init() {
        var book = Self.load() ?? UsageBook()
        book.removeDays(olderThan: Self.keepingDays, before: .now)
        self.book = book
        #if DEBUG
        // 调试用：-seedUsage 放一些示例用量，方便截图检查设置页
        if ProcessInfo.processInfo.arguments.contains("-seedUsage") { seedForPreview() }
        #endif
    }

    /// 记一次调用；没有价格的模型直接忽略
    func record(_ usage: LLMUsage, config: LLMServiceConfig, at date: Date = .now) {
        guard let pricing = config.pricing else { return }
        let cost = pricing.cost(of: usage, peak: pricing.isPeak(date))
        book.add(usage, model: config.model, costUSD: cost, at: date)
        save()
    }

    func clear() {
        book = UsageBook()
        guard persists else { return }
        try? FileManager.default.removeItem(at: Self.fileURL)
    }

    var today: UsageTotal { book.total(onDay: .now) }
    var thisMonth: UsageTotal { book.total(monthOf: .now) }
    var lastMonth: UsageTotal { book.total(monthOf: .now, monthsAgo: 1) }
    var allTime: UsageTotal { book.total() }

    // MARK: - 存取

    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Usage", isDirectory: true)
            .appendingPathComponent("usage.json")
    }

    private static func load() -> UsageBook? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(UsageBook.self, from: data)
    }

    private func save() {
        guard persists else { return }
        let url = Self.fileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try? JSONEncoder().encode(book).write(to: url, options: .atomic)
    }

    #if DEBUG
    /// 往前 40 天每天放几次调用；只改内存，之后也不写文件
    private func seedForPreview() {
        persists = false
        book = UsageBook()
        let config = LLMProviderPreset.deepSeek.makeConfig()
        guard let pricing = config.pricing else { return }
        for daysAgo in (0..<40).reversed() {
            guard let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now) else { continue }
            for index in 0..<(3 + daysAgo % 5) {
                let usage = LLMUsage(
                    inputTokens: 1400 + index * 37, outputTokens: 95 + index * 11, cachedInputTokens: index * 120)
                book.add(usage, model: config.model, costUSD: pricing.cost(of: usage, peak: index % 3 == 0), at: date)
            }
        }
    }
    #endif
}
