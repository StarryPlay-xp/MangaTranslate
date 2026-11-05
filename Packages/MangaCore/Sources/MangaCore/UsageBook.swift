import Foundation

/// 某一天里某个模型的用量合计。day 是设备本地时区的日期，形如 2026-11-05
public struct DailyUsage: Codable, Sendable, Equatable {
    public var day: String
    public var model: String
    /// 调用次数：每收到一次带用量的回复算一次，重试也算
    public var requests: Int
    /// 全部输入 token，包含缓存命中的部分
    public var inputTokens: Int
    public var cachedInputTokens: Int
    public var outputTokens: Int
    /// 按调用时的单价（闲时或高峰）算出的费用，美元
    public var costUSD: Double
}

/// 一段时间的用量合计
public struct UsageTotal: Sendable, Equatable {
    public var requests = 0
    public var inputTokens = 0
    public var cachedInputTokens = 0
    public var outputTokens = 0
    public var costUSD = 0.0

    public init() {}

    public var isEmpty: Bool { requests == 0 }

    /// 平均每次调用的费用
    public var averageCostUSD: Double { requests == 0 ? 0 : costUSD / Double(requests) }
}

/// 用量账本：按天、按模型汇总每次调用的 token 数和估算费用。只存合计，不存请求内容和图片
public struct UsageBook: Codable, Sendable, Equatable {
    public private(set) var days: [DailyUsage] = []
    /// 第一次记账的时间；清除后重新开始
    public private(set) var startedAt: Date?

    public init() {}

    public mutating func add(
        _ usage: LLMUsage, model: String, costUSD: Double, at date: Date, calendar: Calendar = .current
    ) {
        let day = Self.dayKey(for: date, calendar: calendar)
        if startedAt == nil { startedAt = date }
        let cached = usage.cachedInputTokens ?? 0
        if let index = days.firstIndex(where: { $0.day == day && $0.model == model }) {
            days[index].requests += 1
            days[index].inputTokens += usage.inputTokens
            days[index].cachedInputTokens += cached
            days[index].outputTokens += usage.outputTokens
            days[index].costUSD += costUSD
        } else {
            days.append(
                DailyUsage(
                    day: day, model: model, requests: 1, inputTokens: usage.inputTokens, cachedInputTokens: cached,
                    outputTokens: usage.outputTokens, costUSD: costUSD))
            days.sort { ($0.day, $0.model) < ($1.day, $1.model) }
        }
    }

    public func total(where include: (DailyUsage) -> Bool = { _ in true }) -> UsageTotal {
        days.filter(include).reduce(into: UsageTotal()) { total, day in
            total.requests += day.requests
            total.inputTokens += day.inputTokens
            total.cachedInputTokens += day.cachedInputTokens
            total.outputTokens += day.outputTokens
            total.costUSD += day.costUSD
        }
    }

    /// 某一天的合计
    public func total(onDay date: Date, calendar: Calendar = .current) -> UsageTotal {
        let key = Self.dayKey(for: date, calendar: calendar)
        return total { $0.day == key }
    }

    /// date 所在月份往前推 monthsAgo 个月的合计；0 是本月，1 是上月
    public func total(monthOf date: Date, monthsAgo: Int = 0, calendar: Calendar = .current) -> UsageTotal {
        guard let month = calendar.date(byAdding: .month, value: -monthsAgo, to: date) else { return UsageTotal() }
        let prefix = Self.monthKey(for: month, calendar: calendar) + "-"
        return total { $0.day.hasPrefix(prefix) }
    }

    /// 删掉 date 往前超过 keepingDays 天的记录，账本不会无限变大
    public mutating func removeDays(olderThan keepingDays: Int, before date: Date, calendar: Calendar = .current) {
        guard let cutoff = calendar.date(byAdding: .day, value: -keepingDays, to: date) else { return }
        let key = Self.dayKey(for: cutoff, calendar: calendar)
        days.removeAll { $0.day < key }
    }

    /// 补零的年月日，按字符串比较就是按日期先后比较
    public static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    public static func monthKey(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }
}

/// 用量的中文显示
public enum UsageFormat {
    /// 费用一般很小（一页约 $0.0003），按大小保留不同位数，至少留两位有效数字
    public static func usd(_ value: Double) -> String {
        switch value {
        case ..<0.000_000_5: "$0"
        case ..<0.000_01: "不到 $0.00001"
        case ..<0.001: String(format: "$%.5f", value)
        case ..<0.01: String(format: "$%.4f", value)
        case ..<1: String(format: "$%.3f", value)
        default: String(format: "$%.2f", value)
        }
    }

    /// token 数：一万以下写原数，往上用"万""亿"，保留一位小数
    public static func tokens(_ count: Int) -> String {
        switch count {
        case ..<10_000: "\(count)"
        case ..<100_000_000: trimmed(Double(count) / 10_000) + " 万"
        default: trimmed(Double(count) / 100_000_000) + " 亿"
        }
    }

    private static func trimmed(_ value: Double) -> String {
        let text = String(format: "%.1f", value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }
}
