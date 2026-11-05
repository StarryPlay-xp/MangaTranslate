import Foundation
import MangaCore
import Observation
import OSLog
import WebKit

/// 网页脚本报上来的一段待翻译文字
struct PageTextItem: Decodable {
    var id: String
    var text: String
    /// 0 表示在屏幕上；正数表示离屏幕多远（CSS 像素）
    var distance: Double
}

/// 网页文字翻译：PageTextScript 报告屏幕附近含日文、韩文的文字，这里先查缓存，
/// 没有缓存的按离屏幕的远近排队，每次请求合并几十段一起发给当前模型服务，同时最多 2 个请求
///（局域网里的本地模型一次 1 个），再把译文交回网页原地替换
@Observable
final class PageTextTranslator {
    /// 排队中和正在翻译的段数，用来显示进度
    private(set) var pendingCount = 0

    @ObservationIgnored var settings: AppSettings?
    @ObservationIgnored weak var usage: UsageLedger?
    /// 一批文字失败时的提示，参数是原因
    @ObservationIgnored var onError: ((String) -> Void)?
    /// 缺少 Key、Key 无效、余额不足、连不上服务时调用：网页文字翻译已经停下。第二个参数表示要不要去设置里处理
    @ObservationIgnored var onBlocked: ((String, Bool) -> Void)?

    @ObservationIgnored private let webView: WKWebView
    @ObservationIgnored private let memoryBank: MemoryBank
    @ObservationIgnored private let cache = PageTextCache.shared
    @ObservationIgnored private var enabled = false
    /// 当前文档的编号，由网页脚本生成；换页后旧页面的结果不再贴上
    @ObservationIgnored private var document: String?
    @ObservationIgnored private var queue: [PageTextItem] = []
    @ObservationIgnored private var inFlightCount = 0
    @ObservationIgnored private var inFlightItems = 0
    /// 换页、换服务时加一，丢弃还没完成的结果
    @ObservationIgnored private var generation = 0
    /// 只记录数量和耗时，不记录网页文字
    @ObservationIgnored private let logger = Logger(subsystem: "io.github.starryplay-xp.MangaTranslate", category: "pageText")

    private var maxConcurrent: Int {
        guard let settings, !settings.dryRun else { return 2 }
        return settings.activeService.maxConcurrentRequests
    }

    init(webView: WKWebView, memoryBank: MemoryBank) {
        self.webView = webView
        self.memoryBank = memoryBank
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if !enabled { queue.removeAll() }
        updateCount()
        Task { _ = try? await webView.runIsolatedScript("window.__mangaPageText?.setEnabled(on)", arguments: ["on": enabled]) }
    }

    /// 新页面开始加载，旧页面的文字编号全部作废
    func pageDidCommit() {
        generation += 1
        document = nil
        queue.removeAll()
        updateCount()
    }

    /// 页面加载完时再同步一次开关：后退、前进时 WebKit 可能直接恢复缓存的旧页面，脚本不会重新就绪，
    /// 它记着的还是离开时的开关状态
    func pageDidFinish() {
        let enabled = enabled
        Task { _ = try? await webView.runIsolatedScript("window.__mangaPageText?.setEnabled(on)", arguments: ["on": enabled]) }
    }

    /// 网页脚本就绪（每个新文档一次），开着的话让它开始找文字
    func scriptReady(document: String) {
        self.document = document
        if enabled { setEnabled(true) }
    }

    /// 换了模型服务或原文语言：网页恢复原文后按新设置重新翻译
    func reset() {
        generation += 1
        queue.removeAll()
        updateCount()
        Task { _ = try? await webView.runIsolatedScript("window.__mangaPageText?.reset()") }
    }

    func receive(document: String, items: [PageTextItem]) {
        guard enabled, let settings else { return }
        // 换页后第一次报文字时脚本已经就绪，以它报上来的文档为准
        if self.document != document {
            generation += 1
            queue.removeAll()
            self.document = document
        }
        var hits: [[String: String]] = []
        var misses: [PageTextItem] = []
        if settings.dryRun {
            misses = items
        } else {
            let context = PageTextCache.context(language: settings.sourceLanguage, service: settings.activeService.config)
            for item in items {
                if let translation = cache.translation(of: WebTextTranslator.singleLine(item.text), context: context) {
                    hits.append(["id": item.id, "text": translation])
                } else {
                    misses.append(item)
                }
            }
        }
        if !hits.isEmpty {
            logger.info("网页文字：\(hits.count) 段命中缓存")
            apply(hits, document: document, generation: generation)
        }
        // 新报上来的和还在排队的一起按远近排，近的先翻
        queue = (queue + misses).sorted { $0.distance < $1.distance }
        pump()
    }

    // MARK: - 私有方法

    private func pump() {
        while enabled, inFlightCount < maxConcurrent, !queue.isEmpty, let document {
            var batch: [PageTextItem] = []
            var characters = 0
            var distinct = Set<String>()
            while let next = queue.first {
                let text = WebTextTranslator.singleLine(next.text)
                let isNew = !distinct.contains(text)
                if !batch.isEmpty, isNew,
                   distinct.count >= WebTextTranslator.maxItemsPerRequest
                    || characters + text.count > WebTextTranslator.maxCharactersPerRequest {
                    break
                }
                queue.removeFirst()
                batch.append(next)
                if isNew {
                    distinct.insert(text)
                    characters += text.count
                }
            }
            inFlightCount += 1
            inFlightItems += batch.count
            let generation = self.generation
            Task { await process(batch, document: document, generation: generation) }
        }
        updateCount()
    }

    private func updateCount() {
        pendingCount = queue.count + inFlightItems
    }

    private func process(_ batch: [PageTextItem], document: String, generation: Int) async {
        defer {
            inFlightCount -= 1
            inFlightItems -= batch.count
            pump()
        }
        guard let settings else { return }
        // 开始时就记下设置，翻译过程中用户改了设置也不影响这一批
        let language = settings.sourceLanguage
        let service = settings.activeService
        let dryRun = settings.dryRun

        // 同样的文字（比如每部作品下面的"免费"）只翻译一次
        var texts: [String] = []
        for item in batch {
            let text = WebTextTranslator.singleLine(item.text)
            if !texts.contains(text) { texts.append(text) }
        }

        let translations: [String?]
        if dryRun {
            // 试运行不调用模型：给原文加上括号，用来检查找字和替换是否正常
            translations = texts.map { "〔\($0)〕" }
        } else {
            let apiKey = settings.apiKey(for: service.id)
            if apiKey == nil && service.requiresAPIKey {
                block("「\(service.name)」还没有填写 API Key，网页文字翻译已暂停", needsSettings: true)
                return
            }
            let client: any LLMClient
            do {
                client = try service.config.makeClient(apiKey: apiKey)
            } catch {
                block("「\(service.name)」\(error.localizedDescription)，网页文字翻译已暂停", needsSettings: true)
                return
            }
            let started = ContinuousClock.now
            let host = webView.url?.host() ?? "local"
            let ledger = usage
            let config = service.config
            do {
                translations = try await WebTextTranslator().translate(
                    texts: texts, languageName: language.displayName,
                    glossary: memoryBank.memory(for: host).glossary, using: client,
                    onUsage: { await ledger?.record($0, config: config) })
            } catch let error as LLMServiceError where error.stopsWholeRun {
                logger.error("网页文字：模型服务不可用，暂停：\(error.localizedDescription, privacy: .public)")
                block(error.localizedDescription + "，网页文字翻译已暂停", needsSettings: error.needsSettings)
                return
            } catch {
                logger.error("网页文字：\(batch.count) 段翻译失败：\(error.localizedDescription, privacy: .public)")
                await markFailed(batch.map(\.id), document: document, generation: generation)
                if generation == self.generation { onError?(error.localizedDescription) }
                return
            }
            let seconds = (ContinuousClock.now - started) / .seconds(1)
            logger.info("网页文字：翻译了 \(texts.count) 段，用时 \(seconds, format: .fixed(precision: 1)) 秒")
            let pairs = zip(texts, translations).compactMap { source, translation in
                translation.map { (source: source, translation: $0) }
            }
            cache.save(pairs, context: PageTextCache.context(language: language, service: config))
        }

        let lookup = Dictionary(zip(texts, translations), uniquingKeysWith: { first, _ in first })
        var results: [[String: String]] = []
        var missing: [String] = []
        for item in batch {
            if let translation = lookup[WebTextTranslator.singleLine(item.text)] ?? nil {
                results.append(["id": item.id, "text": translation])
            } else {
                missing.append(item.id)
            }
        }
        apply(results, document: document, generation: generation)
        // 模型漏掉的编号保持原文
        await markFailed(missing, document: document, generation: generation)
    }

    private func apply(_ results: [[String: String]], document: String, generation: Int) {
        guard !results.isEmpty, generation == self.generation,
              let data = try? JSONEncoder().encode(results) else { return }
        let json = String(decoding: data, as: UTF8.self)
        Task {
            _ = try? await webView.runIsolatedScript(
                "window.__mangaPageText?.apply(doc, JSON.parse(json))", arguments: ["doc": document, "json": json])
        }
    }

    private func markFailed(_ ids: [String], document: String, generation: Int) async {
        guard !ids.isEmpty, generation == self.generation else { return }
        _ = try? await webView.runIsolatedScript(
            "window.__mangaPageText?.failed(doc, ids)", arguments: ["doc": document, "ids": ids])
    }

    /// 停止网页文字翻译并通知界面
    private func block(_ message: String, needsSettings: Bool) {
        guard enabled else { return }
        enabled = false
        queue.removeAll()
        updateCount()
        onBlocked?(message, needsSettings)
    }
}
