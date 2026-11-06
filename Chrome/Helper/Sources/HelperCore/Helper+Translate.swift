import CoreGraphics
import Foundation
import MangaCore

/// 自动翻译被关掉或这张图被取消：还没发出的段不再发
struct Abandoned: Error {}

/// 一张图的翻译进度：长图的几段同时翻，每回来一段就先把已有的译文推给插件。
/// 只在 Helper actor 里使用（按 job 编号存在 jobs 里）
final class ImageJob {
    let started = ContinuousClock.now
    var cancelled = false
    var width = 0
    var height = 0
    var segmentCount = 0
    /// 还没有结果的段数（没有文字、跳过的段也算有结果）
    var unfinished = 0
    /// 第一个失败原因：之后还没发出的段不再发
    var failure: Error?
    /// 段序号 → 这一段的译文
    private var segmentItems: [Int: [ImageOverlayItem]] = [:]
    /// 段序号 → 这一段还在生成、已经收到的译文
    private var partialItems: [Int: [ImageOverlayItem]] = [:]
    /// 已经等到所有段的结果：之后不再推中途的译文
    var completed = false
    /// 已经约好一次中途推送，还没执行
    var partialScheduled = false

    // 各环节耗时
    var decode: Duration = .zero
    var recognition: Duration = .zero
    var requests: [Duration] = []
    var gateWaits: [Duration] = []
    var firstTokens: [Duration] = []
    var hedgedRequests = 0
    private(set) var firstShown: Duration?

    var items: [ImageOverlayItem] { segmentItems.keys.sorted().flatMap { segmentItems[$0] ?? [] } }

    /// 现在能贴出来的译文：翻完的段用最终结果，还在生成的段用已经收到的部分
    var displayItems: [ImageOverlayItem] {
        Set(segmentItems.keys).union(partialItems.keys).sorted().flatMap { segmentItems[$0] ?? partialItems[$0] ?? [] }
    }

    func finish(_ index: Int, items: [ImageOverlayItem]) {
        segmentItems[index] = items
        partialItems[index] = nil
        unfinished -= 1
    }

    func setPartial(_ index: Int, items: [ImageOverlayItem]) -> Bool {
        guard !completed, segmentItems[index] == nil else { return false }
        partialItems[index] = items
        return true
    }

    func noteShown() {
        if firstShown == nil { firstShown = .now - started }
    }

    /// 日志里的一行汇总，只有数字，不含图片地址和文字内容
    func summary(itemCount: Int) -> String {
        var parts = ["解码 \(seconds(decode))", "识别 \(seconds(recognition))（\(segmentCount) 段）"]
        if let longest = requests.max(), let waited = gateWaits.max() {
            let average = requests.reduce(Duration.zero, +) / requests.count
            parts.append("模型 \(requests.count) 次，平均 \(seconds(average))，最慢 \(seconds(longest))")
            parts.append("等名额最长 \(seconds(waited))")
        }
        if let fastest = firstTokens.min() { parts.append("首字最快 \(seconds(fastest))") }
        if hedgedRequests > 0 { parts.append("\(hedgedRequests) 次靠对冲") }
        if let firstShown { parts.append("第一处译文 \(seconds(firstShown))") }
        return "从收到到贴完 \(seconds(.now - started))：" + parts.joined(separator: "，") + "；贴了 \(itemCount) 处"
    }
}

extension Helper {
    // MARK: - 图片

    func lookupImage(_ request: LookupImageRequest) -> LookupImageResult {
        guard request.dryRun != true else { return LookupImageResult(items: nil) }
        let key = TranslationCache.key(
            src: request.src, language: request.language, sendImage: settings.effectiveSendImage,
            service: settings.activeService.config)
        return LookupImageResult(items: cache.load(key)?.items)
    }

    /// 和 App 的 AutoTranslator.process 同样的流程：切段 → 逐段识别 → 识别完一段就交给模型 →
    /// 流式先推已经翻好的块 → 全部完成后写缓存、推 done
    func translateImage(_ request: TranslateImageRequest) async {
        let jobID = request.job
        let dryRun = request.dryRun ?? false
        // 开始时就记下设置，翻译过程中改了设置也不影响这一张
        let service = settings.activeService
        let sendImage = settings.effectiveSendImage
        let language = request.language
        let job = ImageJob()
        jobs[jobID] = job
        defer { jobs[jobID] = nil }

        do {
            let decodeStarted = ContinuousClock.now
            let image = try await decodeBase64Image(request.image)
            job.decode = .now - decodeStarted
            // canvas 没有图片地址，缓存按截图内容算
            let source = request.isCanvas
                ? "canvas:" + (await ImagePipeline.contentFingerprint(of: image)) : request.src
            let cacheKey = TranslationCache.key(
                src: source, language: language, sendImage: sendImage, service: service.config)
            if !dryRun, let cached = cache.load(cacheKey) {
                send(JobEvent.done(jobID, items: cached.items, cached: true))
                return
            }
            let client: (any LLMClient)? = dryRun ? nil : try makeClient(for: service)
            send(JobEvent.working(jobID))

            let rects = Segmenting.segmentRects(width: image.width, height: image.height)
            job.width = image.width
            job.height = image.height
            job.segmentCount = rects.count
            job.unfinished = rects.count
            let config = service.config
            let host = request.host

            // 按顺序逐段识别；识别完一段就交给模型，模型翻这一段时接着识别下一段
            var requests: [Task<Void, Never>] = []
            for index in rects.indices {
                guard job.failure == nil else { break }
                guard !job.cancelled else {
                    job.failure = Abandoned()
                    break
                }
                let segment: PreparedSegment?
                do {
                    segment = try await recognize(index, of: rects, in: image, language: language, job: job)
                } catch {
                    job.failure = error
                    break
                }
                guard let segment else {
                    job.unfinished -= 1
                    continue
                }
                requests.append(Task {
                    await self.translateSegment(
                        segment, index: index, jobID: jobID, client: client, language: language,
                        sendImage: sendImage, config: config, host: host)
                })
            }
            for request in requests { await request.value }
            job.completed = true
            if job.cancelled { throw Abandoned() }
            if let failure = job.failure { throw failure }
            let items = job.items
            // 没有文字的图也缓存（结果为空），下次不用再识别
            if !dryRun { cache.save(CachedImageTranslation(items: items), for: cacheKey) }
            send(JobEvent.done(jobID, items: items))
            job.noteShown()
            HelperLog.write("图片（\(job.width)×\(job.height)）\(job.summary(itemCount: items.count))")
        } catch {
            report(error, job: jobID)
        }
    }

    func report(_ error: Error, job jobID: String) {
        switch error {
        case let blocked as Blocked:
            send(JobEvent.failed(jobID, message: blocked.message, stopsAll: true, needsSettings: true))
        case let error as LLMServiceError where error.stopsWholeRun:
            HelperLog.write("模型服务不可用：\(error.localizedDescription)")
            send(JobEvent.failed(
                jobID, message: error.localizedDescription, stopsAll: true, needsSettings: error.needsSettings))
        case is Abandoned:
            send(JobEvent.abandoned(jobID))
        default:
            HelperLog.write("翻译失败：\(error.localizedDescription)")
            send(JobEvent.failed(jobID, message: error.localizedDescription))
        }
    }

    /// 识别一段，和其他图共用识别名额
    func recognize(
        _ index: Int, of rects: [CGRect], in image: CGImage, language: SourceLanguage, job: ImageJob
    ) async throws -> PreparedSegment? {
        await recognitionGate.acquire(limit: Self.maxConcurrentRecognitions)
        defer { recognitionGate.release() }
        let started = ContinuousClock.now
        let segment = try await ImagePipeline.prepareSegment(index, of: rects, in: image, language: language)
        job.recognition += .now - started
        return segment
    }

    /// 把一段交给模型，和其他图共用请求名额。这张图还有别的段没翻完时，先把已经翻好的推给插件
    func translateSegment(
        _ segment: PreparedSegment, index: Int, jobID: String, client: (any LLMClient)?, language: SourceLanguage,
        sendImage: Bool, config: LLMServiceConfig, host: String
    ) async {
        guard let job = jobs[jobID] else { return }
        let blocks: [TranslatedBlock]
        if let client {
            let waitStarted = ContinuousClock.now
            await requestGate.acquire(limit: requestLimit(dryRun: false))
            // 排队期间这张图被取消、别的段已经失败，就不再发
            guard job.failure == nil, !job.cancelled else {
                if job.failure == nil { job.failure = Abandoned() }
                requestGate.release()
                return
            }
            job.gateWaits.append(.now - waitStarted)
            let requestStarted = ContinuousClock.now
            let translator = PageTranslator(sendImage: sendImage)
            let prompt = translator.userPrompt(
                blocks: segment.blocks, languageName: language.displayName,
                readingOrder: language.readingOrder, memory: memoryBank.memory(for: host))
            // 边生成边推已经翻好的块；第一个字 4 秒还没来就再发一份（局域网服务不对冲）
            let streaming = StreamingOptions(
                hedgeAfter: config.isLocalNetwork ? nil : Self.hedgeAfter,
                onPartial: { [weak self] blocks in
                    await self?.partialArrived(blocks, index: index, segment: segment, jobID: jobID)
                })
            let result: PageTranslation
            do {
                result = try await translator.translate(
                    blocks: segment.blocks, prompt: prompt, markedImage: segment.markedJPEG, using: client,
                    onUsage: { [weak self] usage in await self?.recordUsage(usage, config: config) },
                    streaming: streaming)
            } catch {
                requestGate.release()
                if job.failure == nil { job.failure = error }
                return
            }
            requestGate.release()
            job.requests.append(.now - requestStarted)
            if let firstToken = result.firstToken { job.firstTokens.append(firstToken) }
            if result.hedged { job.hedgedRequests += 1 }
            memoryBank.record(result, host: host)
            blocks = result.blocks
        } else {
            await requestGate.acquire(limit: requestLimit(dryRun: true))
            requestGate.release()
            blocks = segment.blocks.map(TranslatedBlock.dryRun)
        }
        guard job.failure == nil, !job.cancelled else { return }
        let items = ImageOverlayItem.items(for: blocks, in: segment, imageWidth: job.width, imageHeight: job.height)
        job.finish(index, items: items)
        // 最后一段由 translateImage 统一推 done 并写缓存
        if job.unfinished > 0, !items.isEmpty {
            send(JobEvent.partial(jobID, items: job.displayItems))
            job.noteShown()
        }
    }

    func recordUsage(_ usage: LLMUsage, config: LLMServiceConfig) {
        self.usage.record(usage, config: config)
    }

    /// 流式翻译收到了新的完整块：记下来，稍等一下再推，连续到达的几块合成一次
    func partialArrived(_ blocks: [TranslatedBlock], index: Int, segment: PreparedSegment, jobID: String) {
        guard let job = jobs[jobID], job.failure == nil, !job.cancelled else { return }
        let items = ImageOverlayItem.items(for: blocks, in: segment, imageWidth: job.width, imageHeight: job.height)
        guard !items.isEmpty, job.setPartial(index, items: items), !job.partialScheduled else { return }
        job.partialScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: Self.partialDelay)
            await self?.flushPartial(jobID)
        }
    }

    func flushPartial(_ jobID: String) {
        guard let job = jobs[jobID] else { return }
        job.partialScheduled = false
        guard !job.completed, !job.cancelled, job.failure == nil else { return }
        send(JobEvent.partial(jobID, items: job.displayItems))
        job.noteShown()
    }

    // MARK: - 只翻译这一屏

    /// 和 App 的 translateVisibleArea 一样：整张截图识别（不切段）、一次请求，结果换算成网页文档坐标
    func translateScreen(_ request: TranslateScreenRequest) async {
        let jobID = request.job
        let dryRun = request.dryRun ?? false
        let service = settings.activeService
        let sendImage = settings.effectiveSendImage
        let language = request.language
        do {
            let image = try await decodeBase64Image(request.image)
            let page = try await ScreenCapture.prepare(image: image, language: language)
            guard !page.blocks.isEmpty else {
                send(ScreenEvent(job: jobID, overlay: [], blockCount: 0))
                return
            }
            let translated: [TranslatedBlock]
            if dryRun {
                translated = page.blocks.map(TranslatedBlock.dryRun)
            } else {
                let client = try makeClient(for: service)
                send(JobEvent.working(jobID))
                let translator = PageTranslator(sendImage: sendImage)
                let prompt = translator.userPrompt(
                    blocks: page.blocks, languageName: language.displayName, readingOrder: language.readingOrder,
                    memory: memoryBank.memory(for: request.host))
                let config = service.config
                let result = try await translator.translate(
                    blocks: page.blocks, prompt: prompt, markedImage: page.markedJPEG, using: client,
                    onUsage: { [weak self] usage in await self?.recordUsage(usage, config: config) })
                memoryBank.record(result, host: request.host)
                translated = result.blocks
            }
            let items = OverlayItem.items(
                for: translated, imageSize: page.imageSize, characterSize: page.characterSize, covers: page.covers,
                viewport: request.viewport)
            send(ScreenEvent(job: jobID, overlay: items, blockCount: page.blocks.count))
        } catch {
            report(error, job: jobID)
        }
    }

    // MARK: - 网页文字

    func lookupText(_ request: LookupTextRequest) -> TextResult {
        guard request.dryRun != true else { return TextResult(translations: request.texts.map { _ in nil }) }
        let context = PageTextCache.context(language: request.language, service: settings.activeService.config)
        return TextResult(translations: request.texts.map {
            textCache.translation(of: WebTextTranslator.singleLine($0), context: context)
        })
    }

    /// 一批网页文字：同样的文字只翻一次，译文和 texts 一一对应，模型漏掉的为 null
    func translateText(_ request: TranslateTextRequest, id: Int) async {
        let service = settings.activeService
        let language = request.language
        var texts: [String] = []
        for text in request.texts.map(WebTextTranslator.singleLine) where !texts.contains(text) {
            texts.append(text)
        }
        do {
            let translations: [String?]
            if request.dryRun == true {
                // 试运行不调用模型：给原文加上括号，用来检查找字和替换是否正常
                translations = texts.map { "〔\($0)〕" }
            } else {
                let client = try makeClient(for: service)
                let config = service.config
                let started = ContinuousClock.now
                translations = try await WebTextTranslator().translate(
                    texts: texts, languageName: language.displayName,
                    glossary: memoryBank.memory(for: request.host).glossary, using: client,
                    onUsage: { [weak self] usage in await self?.recordUsage(usage, config: config) })
                HelperLog.write("网页文字：翻译了 \(texts.count) 段，用时 \(seconds(.now - started))")
                let pairs = zip(texts, translations).compactMap { source, translation in
                    translation.map { (source: source, translation: $0) }
                }
                textCache.save(pairs, context: PageTextCache.context(language: language, service: config))
            }
            let lookup = Dictionary(zip(texts, translations), uniquingKeysWith: { first, _ in first })
            reply(id, TextResult(translations: request.texts.map { lookup[WebTextTranslator.singleLine($0)] ?? nil }))
        } catch let blocked as Blocked {
            fail(id, blocked.message, stopsAll: true, needsSettings: true)
        } catch let error as LLMServiceError where error.stopsWholeRun {
            fail(id, error.localizedDescription, stopsAll: true, needsSettings: error.needsSettings)
        } catch {
            HelperLog.write("网页文字：\(request.texts.count) 段翻译失败：\(error.localizedDescription)")
            fail(id, error.localizedDescription)
        }
    }
}
