import MangaCore
import Observation
import UIKit
import WebKit

/// 阅读页底部弹出的提示气泡
struct BrowserMessage: Equatable, Identifiable {
    enum Kind: Equatable {
        /// 用户主动操作后的进度，不会自动消失
        case progress
        /// 操作结果，很快消失
        case info
        case error
        /// 需要去设置里处理（填写或更换 Key）
        case needsSettings
    }

    let id = UUID()
    var kind: Kind
    var text: String
}

/// 浏览器页面的状态，以及"只翻译这一屏"的流程；自动翻译交给 AutoTranslator
@Observable
final class BrowserModel: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    let autoTranslator: AutoTranslator
    private(set) var title = ""
    private(set) var currentURL: URL?
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    /// 往下滑时收起上下工具栏，往上滑或回到顶部时再出现
    private(set) var chromeHidden = false
    private(set) var message: BrowserMessage?
    private(set) var isTranslatingScreen = false
    /// 每次页面加载完成加一，调试时用来触发翻译
    private(set) var finishedLoads = 0

    /// 翻译按钮上要不要显示"正在翻译"
    var isBusy: Bool { isTranslatingScreen || autoTranslator.pendingCount > 0 }

    @ObservationIgnored private weak var settings: AppSettings?
    @ObservationIgnored private weak var history: ReadingHistory?
    @ObservationIgnored private let memoryBank: MemoryBank
    @ObservationIgnored private let messageProxy: ScriptMessageProxy
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var messageTask: Task<Void, Never>?
    /// 当前提示气泡里累计的失败张数，合并成一条提示
    @ObservationIgnored private var failureCount = 0
    @ObservationIgnored private var lastOffsetY: CGFloat = 0
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    @ObservationIgnored private var lastThumbnailAt = Date.distantPast
    @ObservationIgnored private var pendingRestoreY: Double?

    override init() {
        let configuration = WKWebViewConfiguration()
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(
            source: OverlayScript.source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        let proxy = ScriptMessageProxy()
        controller.add(proxy, contentWorld: .defaultClient, name: OverlayScript.messageHandlerName)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let memoryBank = MemoryBank()
        self.webView = webView
        self.messageProxy = proxy
        self.memoryBank = memoryBank
        autoTranslator = AutoTranslator(webView: webView, memoryBank: memoryBank)
        super.init()

        messageProxy.receiver = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        // 不自动加安全区边距，这样截图区域和网页的可视区域一一对应
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = .clear

        autoTranslator.onError = { [weak self] reason in
            guard let self else { return }
            failureCount += 1
            show(.error, failureCount == 1
                ? "有一张图没翻译成功：\(reason)"
                : "\(failureCount) 张图没翻译成功，可以在菜单里清除译文后重试")
        }
        autoTranslator.onBlocked = { [weak self] reason, needsSettings in
            self?.settings?.autoTranslate = false
            self?.show(needsSettings ? .needsSettings : .error, reason)
        }

        // WKWebView 的这些属性变化都在主线程通知
        observations = [
            webView.observe(\.title) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.title = webView.title ?? "" }
            },
            webView.observe(\.url) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.currentURL = webView.url }
            },
            webView.observe(\.canGoBack) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.canGoBack = webView.canGoBack }
            },
            webView.observe(\.canGoForward) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.canGoForward = webView.canGoForward }
            },
            webView.scrollView.observe(\.contentOffset) { [weak self] scrollView, _ in
                MainActor.assumeIsolated { self?.didScroll(scrollView) }
            },
        ]
    }

    func attach(settings: AppSettings, history: ReadingHistory) {
        self.settings = settings
        self.history = history
        autoTranslator.settings = settings
        autoTranslator.setEnabled(settings.autoTranslate)
    }

    func load(_ destination: BrowserDestination) {
        guard !hasLoaded else { return }
        hasLoaded = true
        switch destination {
        case .web(let url):
            webView.load(URLRequest(url: url))
        case .resume(let url, let scrollY):
            pendingRestoreY = scrollY > 0 ? scrollY : nil
            webView.load(URLRequest(url: url))
        case .demo:
            guard var page = Bundle.main.url(forResource: "demo", withExtension: "html") else {
                show(.error, "找不到示例页")
                return
            }
            let folder = page.deletingLastPathComponent()
            #if DEBUG
            // 调试用：启动参数 -demoAnchor ko、long 或 long-end 直接跳到对应示例
            if let anchor = UserDefaults.standard.string(forKey: "demoAnchor"),
               let anchored = URL(string: page.absoluteString + "#" + anchor) {
                page = anchored
            }
            #endif
            webView.loadFileURL(page, allowingReadAccessTo: folder)
        }
    }

    var canBookmark: Bool { currentURL?.scheme?.hasPrefix("http") == true }

    func toggleBookmark(in bookmarks: BookmarkStore) async {
        guard let url = currentURL, canBookmark else { return }
        if bookmarks.contains(url) {
            bookmarks.remove(url: url)
            show(.info, "已移出书架")
        } else {
            if let thumbnail = await captureThumbnail() { ThumbnailStore.save(thumbnail, for: url) }
            bookmarks.add(title: title, url: url)
            show(.info, "已加入书架")
        }
    }

    func setAutoTranslate(_ enabled: Bool) {
        autoTranslator.setEnabled(enabled)
        if enabled, message?.kind == .needsSettings { dismissMessage() }
    }

    /// 清除全部译文，并关闭自动翻译（否则译文会马上从缓存里重新出现）
    func clearTranslations() {
        settings?.autoTranslate = false
        autoTranslator.setEnabled(false)
        autoTranslator.resetAll()
        Task {
            _ = try? await webView.runIsolatedScript("window.__mangaTranslate?.clear()")
            show(.info, "已清除译文，自动翻译已关闭")
        }
    }

    /// 换了原文语言后，已经翻译过的图按新语言重新翻译
    func retranslateAll() {
        autoTranslator.resetAll()
        Task { _ = try? await webView.runIsolatedScript("window.__mangaTranslate?.clear()") }
    }

    /// 离开阅读页时记下看到哪里，并更新封面
    func saveReadingProgress(captureCover: Bool) async {
        guard let url = webView.url, url.scheme?.hasPrefix("http") == true else { return }
        let scale = max(webView.scrollView.zoomScale, 0.01)
        history?.update(title: title, url: url, scrollY: webView.scrollView.contentOffset.y / scale)
        guard captureCover else { return }
        lastThumbnailAt = Date()
        if let thumbnail = await captureThumbnail() { ThumbnailStore.save(thumbnail, for: url) }
    }

    func dismissMessage() {
        messageTask?.cancel()
        message = nil
        failureCount = 0
    }

    func receiveScriptMessage(_ body: String) {
        struct Message: Decodable {
            var type: String
            var items: [ImageCandidate]?
        }
        guard let message = try? JSONDecoder().decode(Message.self, from: Data(body.utf8)) else { return }
        if message.type == "candidates" {
            autoTranslator.receive(message.items ?? [])
        }
    }

    /// 只翻译这一屏：截取当前屏幕 → 本地识别文字 → DeepSeek 翻译 → 把译文贴回网页原位置。
    /// 用于漫画不是普通图片（比如画在 canvas 上）的网站
    func translateVisibleArea(settings: AppSettings) async {
        guard !isTranslatingScreen else { return }
        isTranslatingScreen = true
        defer { isTranslatingScreen = false }
        let started = ContinuousClock.now
        show(.progress, "正在识别这一屏…")
        do {
            try await ensureOverlayScript()
            // 截图前先藏起旧译文，免得把自己贴上去的中文也识别进去
            try await webView.runIsolatedScript("window.__mangaTranslate.hide()")
            let viewport = try await readViewport()
            let configuration = WKSnapshotConfiguration()
            configuration.afterScreenUpdates = true
            let snapshot = try await webView.takeSnapshot(configuration: configuration)
            try await webView.runIsolatedScript("window.__mangaTranslate.show()")
            guard let image = snapshot.cgImage else { throw MangaCoreError("截图失败") }

            let page = try await ScreenCapture.prepare(image: image, language: settings.sourceLanguage)
            guard !page.blocks.isEmpty else {
                show(.info, "这一屏没有找到文字")
                return
            }

            let translated: [TranslatedBlock]
            if settings.dryRun {
                translated = page.blocks.map(TranslatedBlock.dryRun)
            } else {
                guard let apiKey = KeychainStore.load() else {
                    show(.needsSettings, "还没有填写 DeepSeek API Key")
                    return
                }
                show(.progress, "正在翻译这一屏的 \(page.blocks.count) 处文字…")
                let host = webView.url?.host() ?? "local"
                let translator = PageTranslator(sendImage: settings.sendImage)
                let prompt = translator.userPrompt(
                    blocks: page.blocks, languageName: settings.sourceLanguage.displayName,
                    readingOrder: settings.sourceLanguage.readingOrder, memory: memoryBank.memory(for: host))
                let result = try await translator.translate(
                    blocks: page.blocks, prompt: prompt, markedImage: page.markedJPEG,
                    using: DeepSeekClient(apiKey: apiKey))
                memoryBank.record(result, host: host)
                translated = result.blocks
            }

            let items = OverlayItem.items(
                for: translated, imageSize: page.imageSize, characterSize: page.characterSize, viewport: viewport)
            let json = String(decoding: try JSONEncoder().encode(items), as: UTF8.self)
            try await webView.runIsolatedScript(
                "window.__mangaTranslate.clearRegion(top, bottom); window.__mangaTranslate.render(JSON.parse(json));",
                arguments: ["top": viewport.top, "bottom": viewport.top + viewport.height, "json": json])

            let seconds = (ContinuousClock.now - started) / .seconds(1)
            show(.info, items.isEmpty
                ? "这一屏没有需要翻译的台词"
                : String(format: "这一屏翻译了 %d 处，用时 %.1f 秒", items.count, seconds))
        } catch let error as DeepSeekError where error.status == 401 {
            _ = try? await webView.runIsolatedScript("window.__mangaTranslate?.show()")
            show(.needsSettings, error.localizedDescription)
        } catch {
            _ = try? await webView.runIsolatedScript("window.__mangaTranslate?.show()")
            show(.error, error.localizedDescription)
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        autoTranslator.pageDidCommit()
        chromeHidden = false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishedLoads += 1
        autoTranslator.pageDidFinish()
        if let url = webView.url { history?.update(title: title, url: url) }
        if let y = pendingRestoreY {
            pendingRestoreY = nil
            Task { await restoreScroll(to: y) }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        reportLoadError(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        reportLoadError(error)
    }

    // MARK: - WKUIDelegate

    /// 网页要求在新窗口打开链接时，直接在当前页面打开
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    // MARK: - 私有方法

    /// 往下滑超过一点距离就收起工具栏，往上滑或接近顶部就放出来；停下 1 秒后记下阅读位置
    private func didScroll(_ scrollView: UIScrollView) {
        let y = scrollView.contentOffset.y
        let delta = y - lastOffsetY
        if y < 40 {
            chromeHidden = false
            lastOffsetY = y
        } else if abs(delta) > 14 {
            let hide = delta > 0
            if chromeHidden != hide { chromeHidden = hide }
            lastOffsetY = y
        }

        progressTask?.cancel()
        progressTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            // 封面最多 10 秒更新一次，截图也要花时间
            await saveReadingProgress(captureCover: Date().timeIntervalSince(lastThumbnailAt) > 10)
        }
    }

    /// 回到上次看到的位置。网页内容可能还在加载、高度不够，最多试 10 次
    private func restoreScroll(to y: Double) async {
        for _ in 0..<10 {
            let reached = try? await webView.runIsolatedScript("""
                const ready = document.documentElement.scrollHeight >= y + window.innerHeight * 0.5;
                if (ready) window.scrollTo(0, y);
                return ready;
                """, arguments: ["y": y]) as? Bool
            if reached == true { return }
            try? await Task.sleep(for: .milliseconds(500))
        }
        _ = try? await webView.runIsolatedScript("window.scrollTo(0, y)", arguments: ["y": y])
    }

    private func captureThumbnail() async -> UIImage? {
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = 360
        return try? await webView.takeSnapshot(configuration: configuration)
    }

    private func reportLoadError(_ error: Error) {
        // 用户点了别的链接导致上一次加载被取消，不算错误
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        show(.error, "网页打不开：\(error.localizedDescription)")
    }

    /// 显示提示气泡；进度提示不自动消失，其余几秒后消失
    private func show(_ kind: BrowserMessage.Kind, _ text: String) {
        let newMessage = BrowserMessage(kind: kind, text: text)
        message = newMessage
        if kind == .error || kind == .needsSettings { chromeHidden = false }
        messageTask?.cancel()
        let duration: Duration
        switch kind {
        case .progress: return
        case .info: duration = .seconds(1.8)
        case .error: duration = .seconds(4)
        case .needsSettings: duration = .seconds(8)
        }
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self, self.message?.id == newMessage.id else { return }
            self.dismissMessage()
        }
    }

    private func ensureOverlayScript() async throws {
        let ready = try await webView.runIsolatedScript("return window.__mangaTranslate !== undefined") as? Bool ?? false
        if !ready {
            try await webView.runIsolatedScript(OverlayScript.source)
        }
    }

    private func readViewport() async throws -> Viewport {
        guard let json = try await webView.runIsolatedScript(Viewport.readScript) as? String else {
            throw MangaCoreError("读取网页位置失败")
        }
        return try JSONDecoder().decode(Viewport.self, from: Data(json.utf8))
    }
}

/// WKUserContentController 会强引用消息处理者，用这个中间对象弱引用 BrowserModel，避免循环引用
final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var receiver: BrowserModel?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? String else { return }
        receiver?.receiveScriptMessage(body)
    }
}
