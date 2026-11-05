import Foundation
import MangaCore
import Observation
import OSLog
import WebKit

/// 网页脚本报上来的一张候选图片
struct ImageCandidate: Decodable {
    var id: String
    /// canvas 画的页面没有地址，是空字符串
    var src: String
    /// 0 表示在屏幕上；正数表示离屏幕多远（CSS 像素）
    var distance: Double
    /// "canvas" 表示漫画画在 canvas 上（比如マガポケ），只能截取它在屏幕上的区域；其余是普通图片
    var kind: String?

    var isCanvas: Bool { kind == "canvas" }
}

/// canvas 在可视区域里的位置和可视区域的大小，单位是 CSS 像素
private struct CanvasFrame: Decodable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var viewWidth: Double
    var viewHeight: Double
}

/// 自动翻译关掉或暂停后，这张图还没发出的段不再发；去掉标记，之后重新排队
private struct Abandoned: Error {}

/// 一张图的翻译进度：长图的几段同时翻，每回来一段就把已有的译文先贴上去。
/// 同时记下各环节的耗时，翻完在日志里打一行，用来找出慢在哪里
private final class ImageJob {
    let isCanvas: Bool
    /// 网页第一次报上这张图的时间
    let seen: ContinuousClock.Instant
    let started = ContinuousClock.now
    var width = 0
    var height = 0
    var segmentCount = 0
    /// 还没有结果的段数（没有文字、跳过的段也算有结果）
    var unfinished = 0
    /// 第一个失败原因：之后还没发出的段不再发
    var failure: Error?
    /// 段序号 → 这一段的译文
    private var segmentItems: [Int: [ImageOverlayItem]] = [:]

    // 各环节耗时
    var fetch: Duration = .zero
    var recognition: Duration = .zero
    var gateWaits: [Duration] = []
    var requests: [Duration] = []
    /// 从网页报上来到第一次贴出译文
    private(set) var firstShown: Duration?

    init(isCanvas: Bool, seen: ContinuousClock.Instant) {
        self.isCanvas = isCanvas
        self.seen = seen
    }

    /// 按段的顺序排好的全部译文
    var items: [ImageOverlayItem] { segmentItems.keys.sorted().flatMap { segmentItems[$0] ?? [] } }

    func finish(_ index: Int, items: [ImageOverlayItem]) {
        segmentItems[index] = items
        unfinished -= 1
    }

    func skip() { unfinished -= 1 }

    func noteShown() {
        if firstShown == nil { firstShown = .now - seen }
    }

    /// 日志里的一行汇总，只有数字，不含图片地址和文字内容
    func summary(itemCount: Int) -> String {
        var parts = [
            "排队 \(seconds(started - seen))",
            "\(isCanvas ? "截图" : "下载") \(seconds(fetch))",
            "识别 \(seconds(recognition))（\(segmentCount) 段）",
        ]
        if let longest = requests.max(), let waited = gateWaits.max() {
            let average = requests.reduce(Duration.zero, +) / requests.count
            parts.append("模型 \(requests.count) 次，平均 \(seconds(average))，最慢 \(seconds(longest))")
            parts.append("等名额最长 \(seconds(waited))")
        }
        if segmentCount > 1, let firstShown { parts.append("首段贴出 \(seconds(firstShown))") }
        return "从发现到贴完 \(seconds(.now - seen))：" + parts.joined(separator: "，") + "；贴了 \(itemCount) 处"
    }
}

private func seconds(_ duration: Duration) -> String {
    String(format: "%.2f 秒", duration / .seconds(1))
}

/// 自动翻译：网页脚本报告屏幕附近的漫画图片，这里按离屏幕的远近排队。
/// 长图切成几段，识别完一段就交给模型，每翻好一段就先贴上；所有图片共用模型请求名额
///（云端同时 4 个请求，局域网里的本地模型一次 1 个）。翻译过的图存进缓存，再次出现时直接显示。
/// 画在 canvas 上的页面等它完整停在屏幕上后截取那块区域来翻译，按截图内容缓存
@Observable
final class AutoTranslator {
    /// 排队中和正在翻译的图片数，用来显示进度
    private(set) var pendingCount = 0

    @ObservationIgnored var settings: AppSettings?
    /// 有价格的模型（deepseek-flash）每次调用后在这里记账
    @ObservationIgnored weak var usage: UsageLedger?
    /// 单张图失败时的提示
    @ObservationIgnored var onError: ((String) -> Void)?
    /// 缺少 Key、Key 无效、余额不足、地址或模型不对、连不上服务时调用：自动翻译已经停下，需要用户处理。
    /// 第二个参数表示要不要去设置里处理（填写 Key、改地址或模型）
    @ObservationIgnored var onBlocked: ((String, Bool) -> Void)?

    @ObservationIgnored private let webView: WKWebView
    @ObservationIgnored private let memoryBank: MemoryBank
    @ObservationIgnored private var enabled = false
    @ObservationIgnored private var queue: [ImageCandidate] = []
    /// 排队中的图第一次被网页报上来的时间，用来算"从发现到贴出"用了多久
    @ObservationIgnored private var firstSeen: [String: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    /// 已完成或已失败的图片，不再排队
    @ObservationIgnored private var handled: Set<String> = []
    /// 换页或清除译文时加一，丢弃旧页面上还没完成的结果
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var userAgent: String?
    /// 截图里没找到文字的 canvas 已经重新截过几次：可能截的时候还没画好
    @ObservationIgnored private var blankRetries: [String: Int] = [:]
    /// 第几次重截前等多久：先快后慢，网络慢时总共也能等 6 秒
    private static let blankRetryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(3)]
    /// 截图要先藏起译文层，同一时间只截一张
    @ObservationIgnored private var snapshotChain: Task<CGImage?, Never>?
    /// 所有图片共用的模型请求名额
    @ObservationIgnored private let requestGate = RequestGate()
    /// 文字识别名额：同时最多识别 2 段，免得提前翻的图抢走屏幕上这张的识别算力
    @ObservationIgnored private let recognitionGate = RequestGate()
    private static let maxConcurrentRecognitions = 2
    /// 只记录数量和耗时，不记录图片地址和文字内容
    @ObservationIgnored private let logger = Logger(subsystem: "io.github.starryplay-xp.MangaTranslate", category: "auto")
    /// 各环节耗时：在 Xcode 的调试输出或 Mac 的“控制台”App 里按 timing 分类筛选
    @ObservationIgnored private let timingLogger = Logger(
        subsystem: "io.github.starryplay-xp.MangaTranslate", category: "timing")

    /// 同时发出的模型请求数
    private var requestLimit: Int {
        guard let settings, !settings.dryRun else { return 2 }
        return settings.activeService.maxConcurrentImageRequests
    }

    /// 同时处理几张图（下载或截图、识别、等模型）：和请求名额一样多，至少 2 张，
    /// 前一张在等模型时下一张已经在识别
    private var maxConcurrentImages: Int { max(2, requestLimit) }

    init(webView: WKWebView, memoryBank: MemoryBank) {
        self.webView = webView
        self.memoryBank = memoryBank
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if !enabled {
            queue.removeAll()
            firstSeen.removeAll()
        }
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
        firstSeen.removeAll()
        inFlight.removeAll()
        handled.removeAll()
        blankRetries.removeAll()
        updateCount()
    }

    /// 以最新一次扫描为准排队：已经滚走、不在范围内的图不再排队
    func receive(_ candidates: [ImageCandidate]) {
        guard enabled else { return }
        queue = candidates
            .filter { !inFlight.contains($0.id) && !handled.contains($0.id) }
            .sorted { $0.distance < $1.distance }
        // 只保留还在排队的图的发现时间：滚出范围又回来的图重新计时
        let now = ContinuousClock.now
        firstSeen = Dictionary(queue.map { ($0.id, firstSeen[$0.id] ?? now) }, uniquingKeysWith: { first, _ in first })
        pump()
    }

    // MARK: - 私有方法

    private func pump() {
        while enabled, inFlight.count < maxConcurrentImages, !queue.isEmpty {
            let next = queue.removeFirst()
            let seen = firstSeen.removeValue(forKey: next.id) ?? .now
            inFlight.insert(next.id)
            let generation = self.generation
            Task { await process(next, seen: seen, generation: generation) }
        }
        updateCount()
    }

    private func updateCount() {
        pendingCount = queue.count + inFlight.count
    }

    private func process(_ candidate: ImageCandidate, seen: ContinuousClock.Instant, generation: Int) async {
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
        let job = ImageJob(isCanvas: candidate.isCanvas, seen: seen)

        // canvas 先截图：缓存按截图内容算。截不到说明已经翻走了，去掉标记，等它再停到屏幕上
        var snapshot: CGImage?
        var cacheSource = candidate.src
        if candidate.isCanvas {
            let fetchStarted = ContinuousClock.now
            guard let image = await snapshotCanvas(candidate.id) else {
                await mark(candidate.id, state: nil, generation: generation)
                return
            }
            snapshot = image
            cacheSource = "canvas:" + (await ImagePipeline.contentFingerprint(of: image))
            job.fetch = .now - fetchStarted
        }
        let cacheKey = TranslationCache.key(
            src: cacheSource, language: language, sendImage: sendImage, service: service.config)

        if !dryRun, let cached = TranslationCache.load(cacheKey) {
            logger.info("图片 \(candidate.id, privacy: .public)：命中缓存，\(cached.items.count) 处译文")
            await render(candidate, items: cached.items, generation: generation)
            let line = "命中缓存，从发现到贴出 \(seconds(.now - seen))"
            timingLogger.info("图片 \(candidate.id, privacy: .public)：\(line, privacy: .public)")
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
        do {
            let image: CGImage
            if let snapshot {
                image = snapshot
            } else {
                let fetchStarted = ContinuousClock.now
                image = try await ImagePipeline.decode(try await loadImage(candidate.src))
                job.fetch = .now - fetchStarted
            }
            let rects = Segmenting.segmentRects(width: image.width, height: image.height)
            job.width = image.width
            job.height = image.height
            job.segmentCount = rects.count
            job.unfinished = rects.count
            let host = webView.url?.host() ?? "local"
            let config = service.config
            let client = client

            // 按顺序逐段识别；识别完一段就交给模型，模型翻这一段时接着识别下一段
            var requests: [Task<Void, Never>] = []
            for index in rects.indices {
                guard generation == self.generation, job.failure == nil else { break }
                guard enabled else {
                    job.failure = Abandoned()
                    break
                }
                let segment: PreparedSegment?
                do {
                    segment = try await recognize(
                        index, of: rects, in: image, language: language, id: candidate.id, job: job)
                } catch {
                    job.failure = error
                    break
                }
                guard let segment else {
                    job.skip()
                    continue
                }
                requests.append(Task {
                    await translate(
                        segment, index: index, of: candidate, job: job, client: client, language: language,
                        sendImage: sendImage, config: config, host: host, generation: generation)
                })
            }
            for request in requests { await request.value }
            guard generation == self.generation else { return }
            if let failure = job.failure { throw failure }
            let items = job.items
            // 没有文字的图也缓存（结果为空），下次不用再识别
            if !dryRun {
                TranslationCache.save(CachedImageTranslation(items: items), for: cacheKey)
            }
            await render(candidate, items: items, generation: generation)
            job.noteShown()
            let summary = job.summary(itemCount: items.count)
            timingLogger.info("图片 \(candidate.id, privacy: .public)（\(job.width)×\(job.height)）\(summary, privacy: .public)")
        } catch let error as LLMServiceError where error.stopsWholeRun {
            // 去掉“翻译中”角标，问题解决后这张图还能重新翻译
            await mark(candidate.id, state: nil, generation: generation)
            logger.error("图片 \(candidate.id, privacy: .public)：模型服务不可用，自动翻译暂停：\(error.localizedDescription, privacy: .public)")
            block(error.localizedDescription + "，自动翻译已暂停", needsSettings: error.needsSettings)
        } catch is Abandoned {
            await mark(candidate.id, state: nil, generation: generation)
        } catch {
            logger.error("图片 \(candidate.id, privacy: .public) 翻译失败：\(error.localizedDescription, privacy: .public)")
            if generation == self.generation { handled.insert(candidate.id) }
            await mark(candidate.id, state: "failed", generation: generation)
            onError?(error.localizedDescription)
        }
    }

    /// 识别一段，和其他图共用识别名额
    private func recognize(
        _ index: Int, of rects: [CGRect], in image: CGImage, language: SourceLanguage, id: String, job: ImageJob
    ) async throws -> PreparedSegment? {
        await recognitionGate.acquire(limit: Self.maxConcurrentRecognitions)
        defer { recognitionGate.release() }
        let started = ContinuousClock.now
        let segment = try await ImagePipeline.prepareSegment(index, of: rects, in: image, language: language)
        let took = ContinuousClock.now - started
        job.recognition += took
        if rects.count > 1 {
            let line = "第 \(index + 1)/\(rects.count) 段：识别 \(seconds(took))，\(segment?.blocks.count ?? 0) 块"
            timingLogger.info("图片 \(id, privacy: .public) \(line, privacy: .public)")
        }
        return segment
    }

    /// 把一段交给模型，和其他图共用请求名额。这张图还有别的段没翻完时，先把已经翻好的贴上去
    private func translate(
        _ segment: PreparedSegment, index: Int, of candidate: ImageCandidate, job: ImageJob,
        client: (any LLMClient)?, language: SourceLanguage, sendImage: Bool, config: LLMServiceConfig,
        host: String, generation: Int
    ) async {
        let blocks: [TranslatedBlock]
        if let client {
            let waitStarted = ContinuousClock.now
            await requestGate.acquire(limit: requestLimit)
            // 排队期间换了页、别的段已经失败或自动翻译停了，就不再发
            guard generation == self.generation, job.failure == nil, enabled else {
                if generation == self.generation, job.failure == nil { job.failure = Abandoned() }
                requestGate.release()
                return
            }
            let waited = ContinuousClock.now - waitStarted
            let requestStarted = ContinuousClock.now
            let translator = PageTranslator(sendImage: sendImage)
            let prompt = translator.userPrompt(
                blocks: segment.blocks, languageName: language.displayName,
                readingOrder: language.readingOrder, memory: memoryBank.memory(for: host))
            let ledger = usage
            let result: PageTranslation
            do {
                result = try await translator.translate(
                    blocks: segment.blocks, prompt: prompt, markedImage: segment.markedJPEG, using: client,
                    onUsage: { await ledger?.record($0, config: config) })
            } catch {
                requestGate.release()
                if job.failure == nil { job.failure = error }
                return
            }
            requestGate.release()
            let took = ContinuousClock.now - requestStarted
            job.gateWaits.append(waited)
            job.requests.append(took)
            let line = "第 \(index + 1)/\(job.segmentCount) 段：等名额 \(seconds(waited))，模型 \(seconds(took))"
                + "（第 \(result.attempts) 次成功，输入 \(result.usage.inputTokens)、输出 \(result.usage.outputTokens) token）"
            timingLogger.info("图片 \(candidate.id, privacy: .public) \(line, privacy: .public)")
            memoryBank.record(result, host: host)
            blocks = result.blocks
        } else {
            blocks = segment.blocks.map(TranslatedBlock.dryRun)
        }
        guard generation == self.generation, job.failure == nil else { return }
        let items = ImageOverlayItem.items(for: blocks, in: segment, imageWidth: job.width, imageHeight: job.height)
        job.finish(index, items: items)
        // 最后一段由 process 统一贴上并写缓存
        if job.unfinished > 0, !items.isEmpty {
            await renderPartial(candidate.id, items: job.items, generation: generation)
            job.noteShown()
        }
    }

    /// 停止自动翻译并通知界面
    private func block(_ message: String, needsSettings: Bool) {
        guard enabled else { return }
        enabled = false
        queue.removeAll()
        firstSeen.removeAll()
        updateCount()
        onBlocked?(message, needsSettings)
    }

    /// 长图还有段没翻完：先贴上已经翻好的，角标保持"翻译中"
    private func renderPartial(_ id: String, items: [ImageOverlayItem], generation: Int) async {
        guard generation == self.generation,
              let json = try? String(decoding: JSONEncoder().encode(items), as: UTF8.self)
        else { return }
        _ = try? await webView.runIsolatedScript(
            "window.__mangaTranslate.renderImage(id, JSON.parse(json)); window.__mangaTranslate.markState(id, 'pending')",
            arguments: ["id": id, "json": json])
    }

    private func render(_ candidate: ImageCandidate, items: [ImageOverlayItem], generation: Int) async {
        guard generation == self.generation else { return }
        let id = candidate.id
        // canvas 没找到文字可能是还没画好（截到空白或加载图），过一会儿再截，最多再截三次
        let retries = blankRetries[id, default: 0]
        if candidate.isCanvas, items.isEmpty, retries < Self.blankRetryDelays.count {
            blankRetries[id] = retries + 1
            await mark(id, state: "waiting", generation: generation)
            let delay = Self.blankRetryDelays[retries]
            Task { [weak self] in
                try? await Task.sleep(for: delay)
                await self?.mark(id, state: nil, generation: generation)
            }
            return
        }
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

    /// 截取 canvas 当前在屏幕上的区域。截图前藏起译文层，免得把贴上去的中文也截进去；
    /// canvas 已经不完整在屏幕上（翻走了、被移除）时返回 nil
    private func snapshotCanvas(_ id: String) async -> CGImage? {
        let previous = snapshotChain
        let task = Task { [webView] () -> CGImage? in
            _ = await previous?.value
            guard let json = try? await webView.runIsolatedScript(
                "return window.__mangaTranslate.prepareSnapshot(id)", arguments: ["id": id]) as? String
            else {
                return nil
            }
            // 网页已经藏起译文层，下面不管成败都要放出来
            let frame = try? JSONDecoder().decode(CanvasFrame.self, from: Data(json.utf8))
            var snapshot: UIImage?
            if frame != nil {
                let configuration = WKSnapshotConfiguration()
                configuration.afterScreenUpdates = true
                snapshot = try? await webView.takeSnapshot(configuration: configuration)
            }
            _ = try? await webView.runIsolatedScript("window.__mangaTranslate.show()")
            guard let frame, let image = snapshot?.cgImage, frame.viewWidth > 0, frame.viewHeight > 0 else { return nil }
            // 截图是整个可视区域，按比例换算到像素再裁出 canvas
            let scaleX = Double(image.width) / frame.viewWidth
            let scaleY = Double(image.height) / frame.viewHeight
            let rect = CGRect(
                x: frame.x * scaleX, y: frame.y * scaleY, width: frame.width * scaleX, height: frame.height * scaleY
            ).integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard rect.width >= 100, rect.height >= 100 else { return nil }
            return image.cropping(to: rect)
        }
        snapshotChain = task
        return await task.value
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
