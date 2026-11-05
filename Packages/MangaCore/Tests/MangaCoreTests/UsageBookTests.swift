import Foundation
import Testing

@testable import MangaCore

struct UsageBookTests {
    /// 固定在北京时间，结果不受运行测试的电脑时区影响
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()

    private func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: text)!
    }

    @Test func 同一天同一模型合并_按本地日期分天() {
        var book = UsageBook()
        let usage = LLMUsage(inputTokens: 1000, outputTokens: 100, cachedInputTokens: 200)
        // UTC 11-04 23:30 是北京时间 11-05 07:30
        book.add(usage, model: "deepseek-flash", costUSD: 0.0002, at: date("2026-11-04T23:30:00Z"), calendar: calendar)
        book.add(usage, model: "deepseek-flash", costUSD: 0.0003, at: date("2026-11-05T08:00:00Z"), calendar: calendar)
        book.add(
            LLMUsage(inputTokens: 500, outputTokens: 50), model: "deepseek-flash", costUSD: 0.0001,
            at: date("2026-11-03T08:00:00Z"), calendar: calendar)

        #expect(book.days.map(\.day) == ["2026-11-03", "2026-11-05"])
        let today = book.total(onDay: date("2026-11-05T10:00:00Z"), calendar: calendar)
        #expect(today.requests == 2)
        #expect(today.inputTokens == 2000)
        #expect(today.cachedInputTokens == 400)
        #expect(today.outputTokens == 200)
        #expect(abs(today.costUSD - 0.0005) < 1e-12)
        #expect(book.startedAt == date("2026-11-04T23:30:00Z"))
    }

    @Test func 本月和上月_跨年() {
        var book = UsageBook()
        let usage = LLMUsage(inputTokens: 100, outputTokens: 10)
        book.add(usage, model: "m", costUSD: 1, at: date("2025-12-31T10:00:00Z"), calendar: calendar)
        book.add(usage, model: "m", costUSD: 2, at: date("2026-01-01T10:00:00Z"), calendar: calendar)
        book.add(usage, model: "m", costUSD: 4, at: date("2026-01-20T10:00:00Z"), calendar: calendar)

        let now = date("2026-01-25T10:00:00Z")
        #expect(book.total(monthOf: now, calendar: calendar).costUSD == 6)
        #expect(book.total(monthOf: now, monthsAgo: 1, calendar: calendar).costUSD == 1)
        #expect(book.total().requests == 3)
        #expect(book.total().averageCostUSD == 7.0 / 3)
    }

    @Test func 删掉太早的记录() {
        var book = UsageBook()
        let usage = LLMUsage(inputTokens: 1, outputTokens: 1)
        book.add(usage, model: "m", costUSD: 0, at: date("2025-01-01T10:00:00Z"), calendar: calendar)
        book.add(usage, model: "m", costUSD: 0, at: date("2026-11-01T10:00:00Z"), calendar: calendar)
        book.removeDays(olderThan: 400, before: date("2026-11-05T10:00:00Z"), calendar: calendar)
        #expect(book.days.map(\.day) == ["2026-11-01"])
    }

    @Test func 账本可以存取() throws {
        var book = UsageBook()
        book.add(
            LLMUsage(inputTokens: 1460, outputTokens: 110, cachedInputTokens: 0), model: "deepseek-flash",
            costUSD: 0.000285, at: date("2026-11-05T02:00:00Z"), calendar: calendar)
        let decoded = try JSONDecoder().decode(UsageBook.self, from: JSONEncoder().encode(book))
        #expect(decoded == book)
    }

    @Test func 高峰时段单价翻倍() {
        let pricing = LLMPricing.deepSeekFlash
        let usage = LLMUsage(inputTokens: 1_000_000, outputTokens: 1_000_000, cachedInputTokens: 0)
        // 周四 UTC 02:00 是北京时间 10:00，高峰；UTC 12:00 是北京时间 20:00，闲时
        let peak = date("2026-11-05T02:00:00Z")
        let offPeak = date("2026-11-05T12:00:00Z")
        #expect(pricing.isPeak(peak))
        #expect(!pricing.isPeak(offPeak))
        #expect(abs(pricing.cost(of: usage, peak: false) - 0.75) < 1e-9)
        #expect(abs(pricing.cost(of: usage, peak: true) - 1.5) < 1e-9)
    }

    @Test func 费用和token的中文显示() {
        #expect(UsageFormat.usd(0) == "$0")
        #expect(UsageFormat.usd(0.000004) == "不到 $0.00001")
        #expect(UsageFormat.usd(0.00026) == "$0.00026")
        #expect(UsageFormat.usd(0.0031) == "$0.0031")
        #expect(UsageFormat.usd(0.1234) == "$0.123")
        #expect(UsageFormat.usd(12.345) == "$12.35")
        #expect(UsageFormat.tokens(9999) == "9999")
        #expect(UsageFormat.tokens(18_000) == "1.8 万")
        #expect(UsageFormat.tokens(520_000) == "52 万")
        #expect(UsageFormat.tokens(123_000_000) == "1.2 亿")
    }
}
