import Foundation
import Synchronization

/// 流式翻译的选项：边生成边贴出已经翻好的块；第一个字迟迟不来时再发一份请求
public struct StreamingOptions: Sendable {
    /// 过了这么久还没收到第一个字，就再发一份同样的请求，谁先出字用谁，另一份取消；nil 表示不对冲。
    /// 输掉的那份如果已经开始处理，服务端可能照样计费，但不会记进用量
    public var hedgeAfter: Duration?
    /// 每取出新的完整块就调用，参数是到目前为止翻好的块（没翻到的块不在里面）
    public var onPartial: (@Sendable ([TranslatedBlock]) async -> Void)?

    public init(hedgeAfter: Duration? = nil, onPartial: (@Sendable ([TranslatedBlock]) async -> Void)? = nil) {
        self.hedgeAfter = hedgeAfter
        self.onPartial = onPartial
    }
}

/// 拒绝流式参数（HTTP 400）的服务：之后都改用普通请求。只在内存里记，App 重启后再试一次
enum StreamingSupport {
    private static let unsupported = Mutex<Set<String>>([])

    private static func key(_ config: LLMServiceConfig) -> String {
        "\(config.format.rawValue)|\(config.baseURL)|\(config.model)"
    }

    static func isUnsupported(_ config: LLMServiceConfig) -> Bool {
        unsupported.withLock { $0.contains(key(config)) }
    }

    static func markUnsupported(_ config: LLMServiceConfig) {
        _ = unsupported.withLock { $0.insert(key(config)) }
    }
}

/// 一次流式请求（可能带一份对冲请求）的结果和耗时
struct StreamedReply {
    var reply: LLMReply
    /// 从发出请求到收到第一个字
    var firstToken: Duration
    /// 是对冲的第二份先出字
    var hedged: Bool
}

/// 两份请求谁先出字：先认领的赢，另一份出字时发现输了就退出
private actor StreamRace {
    private(set) var winner: Int?
    private var hedgeStarted = false
    private var closed = false

    func claim(_ index: Int) -> Bool {
        if winner == nil { winner = index }
        return winner == index
    }

    /// 还没有人出字、也没放弃时才发对冲请求
    func startHedge() -> Bool {
        guard winner == nil, !closed else { return false }
        hedgeStarted = true
        return true
    }

    /// 第 index 份失败了：它已经出过字，或者对冲还没发出，就放弃这一次（交给外面的重试）；否则等另一份
    func giveUp(afterFailureOf index: Int) -> Bool {
        guard winner == index || !hedgeStarted else { return false }
        closed = true
        return true
    }
}

private enum StreamRunResult: Sendable {
    case finished(LLMReply, index: Int, firstToken: Duration)
    case failed(Error, index: Int)
    /// 另一份先出字了
    case lost
    /// 对冲请求没有发出
    case skipped
}

extension PageTranslator {
    func streamedReply(
        _ request: LLMPrompt, blocks: [TextBlock], using client: any LLMClient, options: StreamingOptions
    ) async throws -> StreamedReply {
        let started = ContinuousClock.now
        let race = StreamRace()
        return try await withThrowingTaskGroup(of: StreamRunResult.self) { group in
            group.addTask { await run(0, request, blocks: blocks, client: client, options: options, race: race, started: started) }
            if let delay = options.hedgeAfter {
                group.addTask {
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled, await race.startHedge() else { return .skipped }
                    return await run(1, request, blocks: blocks, client: client, options: options, race: race, started: started)
                }
            }
            var firstError: Error?
            while let result = try await group.next() {
                switch result {
                case .finished(let reply, let index, let firstToken):
                    group.cancelAll()
                    return StreamedReply(reply: reply, firstToken: firstToken, hedged: index == 1)
                case .failed(let error, let index):
                    if await race.giveUp(afterFailureOf: index) {
                        group.cancelAll()
                        throw error
                    }
                    firstError = firstError ?? error
                case .lost, .skipped:
                    break
                }
            }
            throw firstError ?? MangaCoreError("没有收到回复")
        }
    }

    private func run(
        _ index: Int, _ request: LLMPrompt, blocks: [TextBlock], client: any LLMClient, options: StreamingOptions,
        race: StreamRace, started: ContinuousClock.Instant
    ) async -> StreamRunResult {
        var builder = StreamedReplyBuilder()
        var partial = PartialBlocksParser()
        var firstToken: Duration?
        do {
            for try await event in client.stream(request) {
                if case .text(let text) = event, firstToken == nil, !text.isEmpty {
                    guard await race.claim(index) else { return .lost }
                    firstToken = .now - started
                }
                builder.add(event)
                if firstToken != nil, case .text(let text) = event, let onPartial = options.onPartial,
                   !partial.append(text).isEmpty {
                    let output = TranslationOutput(blocks: partial.items, newTerms: nil)
                    await onPartial(Self.merge(blocks, with: output).filter { $0.kind != "missing" })
                }
            }
        } catch {
            return .failed(error, index: index)
        }
        if firstToken == nil {
            // 整段都没有文字：照样当作这一份的回复，之后解析失败会重试
            guard await race.claim(index) else { return .lost }
            firstToken = .now - started
        }
        return .finished(builder.reply, index: index, firstToken: firstToken ?? .zero)
    }
}
