import MangaCore
import Observation
import UIKit
import WebKit

enum TranslationStatus: Equatable {
    case idle
    case working(String)
    case done(String)
    case failed(String)
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
    /// 每次页面加载完成加一，调试时用来触发翻译
    private(set) var finishedLoads = 0
    private(set) var status: TranslationStatus = .idle

    var isTranslatingScreen: Bool {
        if case .working = status { true } else { false }
    }

    /// 页面顶部要显示的提示：优先显示一次性的状态，其次显示自动翻译的进度
    var bannerStatus: TranslationStatus {
        if status != .idle { return status }
        if autoTranslator.pendingCount > 0 { return .working("自动翻译中，还有 \(autoTranslator.pendingCount) 张图") }
        return .idle
    }

    @ObservationIgnored private weak var settings: AppSettings?
    @ObservationIgnored private let memoryBank: MemoryBank
    @ObservationIgnored private let messageProxy: ScriptMessageProxy
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var statusResetTask: Task<Void, Never>?

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

        autoTranslator.onError = { [weak self] message in self?.setStatus(.failed(message)) }
        autoTranslator.onBlocked = { [weak self] message in
            self?.settings?.autoTranslate = false
            self?.setStatus(.failed(message))
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
        ]
    }

    func attach(settings: AppSettings) {
        self.settings = settings
        autoTranslator.settings = settings
        autoTranslator.setEnabled(settings.autoTranslate)
    }

    func load(_ destination: BrowserDestination) {
        guard !hasLoaded else { return }
        hasLoaded = true
        switch destination {
        case .web(let url):
            webView.load(URLRequest(url: url))
        case .demo:
            guard var page = Bundle.main.url(forResource: "demo", withExtension: "html") else {
                setStatus(.failed("找不到示例页"))
                return
            }
            let folder = page.deletingLastPathComponent()
            #if DEBUG
            // 调试用：启动参数 -demoAnchor ko 或 long 直接跳到对应示例
            if let anchor = UserDefaults.standard.string(forKey: "demoAnchor"),
               let anchored = URL(string: page.absoluteString + "#" + anchor) {
                page = anchored
            }
            #endif
            webView.loadFileURL(page, allowingReadAccessTo: folder)
        }
    }

    func setAutoTranslate(_ enabled: Bool) {
        autoTranslator.setEnabled(enabled)
        setStatus(.done(enabled ? "已开启自动翻译" : "已关闭自动翻译"))
    }

    /// 清除全部译文，并关闭自动翻译（否则译文会马上从缓存里重新出现）
    func clearTranslations() {
        settings?.autoTranslate = false
        autoTranslator.setEnabled(false)
        autoTranslator.resetAll()
        Task {
            _ = try? await webView.runIsolatedScript("window.__mangaTranslate?.clear()")
            setStatus(.done("已清除译文"))
        }
    }

    /// 换了原文语言后，已经翻译过的图按新语言重新翻译
    func retranslateAll() {
        autoTranslator.resetAll()
        Task { _ = try? await webView.runIsolatedScript("window.__mangaTranslate?.clear()") }
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
        let started = ContinuousClock.now
        setStatus(.working("正在截取画面…"))
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

            setStatus(.working("正在识别文字…"))
            let page = try await ScreenCapture.prepare(image: image, language: settings.sourceLanguage)
            guard !page.blocks.isEmpty else {
                setStatus(.done("这一屏没有找到文字"))
                return
            }

            let translated: [TranslatedBlock]
            if settings.dryRun {
                translated = page.blocks.map(TranslatedBlock.dryRun)
            } else {
                guard let apiKey = KeychainStore.load() else {
                    throw MangaCoreError("请先在设置里填写 DeepSeek API Key")
                }
                setStatus(.working("正在翻译 \(page.blocks.count) 处文字…"))
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
            let summary = items.isEmpty ? "这一屏没有需要翻译的台词" : String(format: "已翻译 %d 处，用时 %.1f 秒", items.count, seconds)
            setStatus(.done(settings.dryRun ? "试运行：" + summary : summary))
        } catch {
            _ = try? await webView.runIsolatedScript("window.__mangaTranslate?.show()")
            setStatus(.failed(error.localizedDescription))
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        autoTranslator.pageDidCommit()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishedLoads += 1
        autoTranslator.pageDidFinish()
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

    private func reportLoadError(_ error: Error) {
        // 用户点了别的链接导致上一次加载被取消，不算错误
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        setStatus(.failed("网页加载失败：\(error.localizedDescription)"))
    }

    /// 完成和失败的提示过几秒自动消失
    private func setStatus(_ newStatus: TranslationStatus) {
        status = newStatus
        statusResetTask?.cancel()
        let delay: Duration
        switch newStatus {
        case .done: delay = .seconds(2)
        case .failed: delay = .seconds(6)
        case .idle, .working: return
        }
        statusResetTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.status == newStatus else { return }
            self.status = .idle
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
