import Darwin
import Foundation

/// 优先读环境变量 DEEPSEEK_API_KEY；没有就在终端里提示输入（输入时不显示，也不会保存）
func readDeepSeekAPIKey() throws -> String {
    if let key = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
       !key.isEmpty {
        return key
    }
    var buffer = [CChar](repeating: 0, count: 512)
    guard readpassphrase("请粘贴 DeepSeek API Key（输入时不会显示）：", &buffer, buffer.count, RPP_REQUIRE_TTY) != nil else {
        throw ProbeError("没有读到 API Key。请在终端里运行，或先设置环境变量 DEEPSEEK_API_KEY")
    }
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    let key = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { throw ProbeError("API Key 为空") }
    return key
}
