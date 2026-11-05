import Foundation
import MangaCore

@main
struct OCRProbe {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        let command = args.isEmpty ? "" : args.removeFirst()
        do {
            switch command {
            case "run":
                try await runProbe(RunOptions(parsing: args))
            case "translate":
                try await runTranslate(TranslateOptions(parsing: args))
            case "ping":
                try await runPing(args)
            case "fixtures":
                guard args.count == 1 else { throw ProbeError("用法：ocrprobe fixtures <输出目录>") }
                try makeFixtures(in: URL(fileURLWithPath: args[0]))
            case "languages":
                print("Vision 文字识别支持的语言：")
                supportedRecognitionLanguages().forEach { print("  \($0)") }
            default:
                print(usage)
            }
        } catch {
            FileHandle.standardError.write(Data("出错：\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}

let usage = """
    ocrprobe：用 Apple Vision 识别漫画图片里的文字，再交给大模型翻译，生成标注图和 HTML 报告

    用法：
      ocrprobe run <输入目录> <输出目录> [--lang ja-JP,ko-KR] [--gap 0.6]
      ocrprobe translate <样本目录> <识别结果目录> <输出目录> [--limit 3] [--text-only] [--thinking] [--dry-run]
                         [--format openai|anthropic] [--base-url <地址>] [--model <模型名>] [--no-json-mode] [--timeout <秒>] [--no-key]
      ocrprobe ping [--format …] [--base-url …] [--model …]   测试连接：只发一条很短的文字请求
      ocrprobe fixtures <输出目录>     生成合成测试页
      ocrprobe languages               列出 Vision 支持的识别语言

    输入目录下的第一级子目录名决定默认语言：ko 开头按韩漫处理，其余按日漫处理。
    不指定模型服务时用 DeepSeek（deepseek-flash）。Key 从环境变量 LLM_API_KEY（或 DEEPSEEK_API_KEY）读取，
    没有就在终端里隐藏输入，不会保存；局域网地址默认不要 Key。
    """

struct ProbeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct RunOptions {
    var input: URL
    var output: URL
    /// nil 表示按子目录名自动选择
    var languages: [String]?
    /// 合并文字块时允许的间距，单位是字符大小
    var gapFactor: Double

    init(parsing args: [String]) throws {
        var positional: [String] = []
        var languages: [String]?
        var gapFactor = 0.6
        var iterator = args.makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--lang":
                guard let value = iterator.next() else {
                    throw ProbeError("--lang 后面要跟语言，例如 ja-JP 或 ja-JP,ko-KR")
                }
                languages = value.split(separator: ",").map { String($0) }
            case "--gap":
                guard let value = iterator.next().flatMap({ Double($0) }), value > 0 else {
                    throw ProbeError("--gap 后面要跟一个正数，例如 0.6")
                }
                gapFactor = value
            default:
                positional.append(arg)
            }
        }
        guard positional.count == 2 else {
            throw ProbeError("用法：ocrprobe run <输入目录> <输出目录> [--lang ja-JP] [--gap 0.6]")
        }
        input = URL(fileURLWithPath: positional[0])
        output = URL(fileURLWithPath: positional[1])
        self.languages = languages
        self.gapFactor = gapFactor
    }
}
