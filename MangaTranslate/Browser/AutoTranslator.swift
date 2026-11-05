import Foundation
import MangaCore
import Observation
import OSLog
import WebKit

/// 网页脚本报上来的一张候选图片
struct ImageCandidate: Decodable {
    var id: String
    var src: String
    /// 0 表示在屏幕上；正数表示在屏幕下方多远（CSS 像素）
    var distance: Double
}

/// 自动翻译：网页脚本报告屏幕附近的漫画图片，这里按离屏幕的远近排队，同时最多翻译 2 张
///（局域网里的本地模型一次只翻 1 张）。翻译过的图存进缓存，再次出现时直接显示
@Observable
final class AutoTranslator {
    /// 排队中和正在翻译的图片数，用来显示进度
    private(set) var pendingCount = 0

    @ObservationIgnored var settings: AppSettings?
    /// 单张图失败时的提示
    @ObservationIgnored var onError: ((String) -> Void)?
    /// 缺少 Key、Key 无效、余额不足、地址或模型不对、连不上服务时调用：自动翻译已经停下，需要用户处理。
    /// 第二个参数表示要不要去设置里处理（填写 Key、改地址或模型）
    @ObservationIgnored var onBlocked: ((String, Bool) -> Void)?

    @ObservationIgnored private let webView: WKWebView
    @ObservationIgnored private let memoryBank: MemoryBank
    @ObservationIgnored private var enabled = false
    @ObservationIgnored private var queue: [ImageCandidate] = []
    @ObservationIgnored private var inFlight: Set<String> = []
    /// 已完成或已失败的图片，不再排队
    @ObservationIgnored private var handled: Set<String> = []
    /// 换页或清除译文时加一，丢弃旧页面上还没完成的结果
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var userAgent: String?
    /// 只记录数量和耗时，不记录图片地址和文字内容
    @ObservationIgnored private let logger = Logger(subsystem: "io.github.starryplay-xp.MangaTranslate", category: "auto")

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
        Task { _ = try? await webView.runIsolatedScript("window.__mangaTranslate?.setAuto(on)", arguments: ["on": enabled]) }
    }

    /// 新页面开始加载，旧页面的图片编号全部作废
    func pageDidCommit() {
        resetAll()
    }

    /// 页面加载完，注入的脚本已就绪，告诉它是否开启自动翻译
    func pageDidFinish() {
        if enabled { setEnabled(true) }
    }

    /// 清除译文后，所有图片都可以重新翻译
    func resetAll() {
        generation += 1
        queue.removeAll()
        inFlight.removeAll()
        handled.removeAll()
        updateCount()
    }

    /// 以最新一次扫描为准排队：已经滚走、不在范围内的图不再排队
    func receive(_ candidates: [ImageCandidate]) {
        guard enabled else { return }
        queue = candidates
            .filter { !inFlight.contains($0.id) && !handled.contains($0.id) }
            .sorted { $0.distance < $1.distance }
        pump()
    }

    // MARK: - 私有方法

    private func pump() {
        while enabled, inFlight.count < maxConcurrent, !queue.isEmpty {
            let next = queue.removeFirst()
            inFlight.insert(next.id)
            let generation = self.generation
            Task { await process(next, generation: generation) }
        }
        updateCount()
    }

    private func updateCount() {
        pendingCount = queue.count + inFlight.count
    }

    private func process(_ candidate: ImageCandidate, generation: Int) async {
        defer {
            if generation == self.generation { inFlight.remove(candidate.id) }
            pump()
        }
        guard let settings else { return }
        // 开始时就记下设置，翻译过程中用户改了设置也不影响这一张
        let language = settings.sourceLanguage
        let service = settings.activeService
        let sendImage = settings.effectiveSendImage
        let dryRun = settings.dryRun
        let cacheKey = TranslationCache.key(
            src: candidate.src, language: language, sendImage: sendImage, service: service.config)

        if !dryRun, let cached = TranslationCache.load(cacheKey) {
            logger.info("图片 \(candidate.id, privacy: .public)：命中缓存，\(cached.items.count) 处译文")
            await render(candidate.id, items: cached.items, generation: generation)
            return
        }
        var client: (any LLMClient)?
        if !dryRun {
            let apiKey = settings.apiKey(for: service.id)
            if apiKey == nil && service.requiresAPIKey {
                block("「\(service.name)」还没有填写 API Key，自动翻译已暂停", needsSettings: true)
                return
            }
            do {
                client = try service.config.makeClient(apiKey: apiKey)
            } catch {
                block("「\(service.name)」\(error.localizedDescription)，自动翻译已暂停", needsSettings: true)
                return
            }
        }

        await mark(candidate.id, state: "pending", generation: generation)
        let started = ContinuousClock.now
        do {
            let data = try await loadImage(candidate.src)
            let prepared = try await ImagePipeline.prepare(imageData: data, language: language)
            logger.info("图片 \(candidate.id, privacy: .public)：\(prepared.width)×\(prepared.height)，\(prepared.segments.count) 段有文字")
            let host = webView.url?.host() ?? "local"
            var items: [ImageOverlayItem] = []
            for segment in prepared.segments {
                guard generation == self.generation else { return }
                let blocks: [TranslatedBlock]
                if let client {
                    let translator = PageTranslator(sendImage: sendImage)
                    let prompt = translator.userPrompt(
                        blocks: segment.blocks, languageName: language.displayName,
                        readingOrder: language.readingOrder, memory: memoryBank.memory(for: host))
                    let result = try await translator.translate(
                        blocks: segment.blocks, prompt: prompt, markedImage: segment.markedJPEG, using: client)
                    memoryBank.record(result, host: host)
                    blocks = result.blocks
                } else {
                    blocks = segment.blocks.map(TranslatedBlock.dryRun)
                }
                items += ImageOverlayItem.items(
                    for: blocks, in: segment, imageWidth: prepared.width, imageHeight: prepared.height)
            }
            // 没有文字的图也缓存（结果为空），下次不用再识别
            if !dryRun {
                TranslationCache.save(CachedImageTranslation(items: items), for: cacheKey)
            }
            let seconds = (ContinuousClock.now - started) / .seconds(1)
            logger.info("图片 \(candidate.id, privacy: .public)：贴了 \(items.count) 处译文，用时 \(seconds, format: .fixed(precision: 1)) 秒")
            await render(candidate.id, items: items, generation: generation)
        } catch let error as LLMServiceError where error.stopsWholeRun {
            // 去掉“翻译中”角标，问题解决后这张图还能重新翻译
            await mark(candidate.id, state: nil, generation: generation)
            logger.error("图片 \(candidate.id, privacy: .public)：模型服务不可用，自动翻译暂停：\(error.localizedDescription, privacy: .public)")
            block(error.localizedDescription + "，自动翻译已暂停", needsSettings: error.needsSettings)
        } catch {
            logger.error("图片 \(candidate.id, privacy: .public) 翻译失败：\(error.localizedDescription, privacy: .public)")
            if generation == self.generation { handled.insert(candidate.id) }
            await mark(candidate.id, state: "failed", generation: generation)
            onError?(error.localizedDescription)
        }
    }

    /// 停止自动翻译并通知界面
    private func block(_ message: String, needsSettings: Bool) {
        guard enabled else { return }
        enabled = false
        queue.removeAll()
        updateCount()
        onBlocked?(message, needsSettings)
    }

    private func render(_ id: String, items: [ImageOverlayItem], generation: Int) async {
        guard generation == self.generation else { return }
        handled.insert(id)
        guard let json = try? String(decoding: JSONEncoder().encode(items), as: UTF8.self) else { return }
        _ = try? await webView.runIsolatedScript(
            "window.__mangaTranslate.renderImage(id, JSON.parse(json))", arguments: ["id": id, "json": json])
    }

    private func mark(_ id: String, state: String?, generation: Int) async {
        guard generation == self.generation else { return }
        let source = state == nil
            ? "window.__mangaTranslate.markState(id, null)"
            : "window.__mangaTranslate.markState(id, state)"
        _ = try? await webView.runIsolatedScript(source, arguments: ["id": id, "state": state ?? ""])
    }

    /// 先由 App 直接下载；blob: 地址或下载被拒绝时，退回让网页自己读取
    private func loadImage(_ src: String) async throws -> Data {
        guard let url = URL(string: src) else { throw MangaCoreError("图片地址无效") }
        if url.isFileURL {
            return try Data(contentsOf: url)
        }
        if url.scheme != "blob" {
            do {
                let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                return try await ImageLoader.download(
                    url, referer: webView.url, userAgent: await currentUserAgent(),
                    cookieHeader: ImageLoader.cookieHeader(for: url, from: cookies))
            } catch {
                // 继续尝试让网页自己读取
            }
        }
        let result = try await webView.runIsolatedScript(
            "return await window.__mangaTranslate.readImage(src)", arguments: ["src": src])
        guard let dataURL = result as? String, let comma = dataURL.firstIndex(of: ","),
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...]))
        else {
            throw MangaCoreError("读取图片失败")
        }
        return data
    }

    private func currentUserAgent() async -> String? {
        if userAgent == nil {
            userAgent = try? await webView.runIsolatedScript("return navigator.userAgent") as? String
        }
        return userAgent
    }
}
