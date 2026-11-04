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

/// 浏览器页面的状态，以及"翻译这一屏"的完整流程
@Observable
final class BrowserModel: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    private(set) var title = ""
    private(set) var currentURL: URL?
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    /// 每次页面加载完成加一，调试时用来触发自动翻译
    private(set) var finishedLoads = 0
    private(set) var status: TranslationStatus = .idle

    var isTranslating: Bool {
        if case .working = status { true } else { false }
    }

    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    /// 按网站分别积累术语表和前文
    @ObservationIgnored private var memories: [String: TranslationMemory] = [:]
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var statusResetTask: Task<Void, Never>?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(WKUserScript(
            source: OverlayScript.source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        // 不自动加安全区边距，这样截图区域和网页的可视区域一一对应
        webView.scrollView.contentInsetAdjustmentBehavior = .never

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
            // 调试用：启动参数 -demoAnchor ko 直接跳到韩漫示例
            if let anchor = UserDefaults.standard.string(forKey: "demoAnchor"),
               let anchored = URL(string: page.absoluteString + "#" + anchor) {
                page = anchored
            }
            #endif
            webView.loadFileURL(page, allowingReadAccessTo: folder)
        }
    }

    func clearTranslations() {
        Task {
            _ = try? await runScript("window.__mangaTranslate?.clear()")
            setStatus(.idle)
        }
    }

    /// 截取当前屏幕 → 本地识别文字 → DeepSeek 翻译 → 把译文贴回网页原位置
    func translateVisibleArea(settings: AppSettings) async {
        guard !isTranslating else { return }
        let started = ContinuousClock.now
        setStatus(.working("正在截取画面…"))
        do {
            try await ensureOverlayScript()
            // 截图前先藏起旧译文，免得把自己贴上去的中文也识别进去
            try await runScript("window.__mangaTranslate.hide()")
            let viewport = try await readViewport()
            let configuration = WKSnapshotConfiguration()
            configuration.afterScreenUpdates = true
            let snapshot = try await webView.takeSnapshot(configuration: configuration)
            try await runScript("window.__mangaTranslate.show()")
            guard let image = snapshot.cgImage else { throw MangaCoreError("截图失败") }

            setStatus(.working("正在识别文字…"))
            let page = try await ScreenCapture.prepare(image: image, language: settings.sourceLanguage)
            guard !page.blocks.isEmpty else {
                setStatus(.done("这一屏没有找到文字"))
                return
            }

            let translated: [TranslatedBlock]
            if settings.dryRun {
                translated = page.blocks.map(Self.dryRunBlock)
            } else {
                guard let apiKey = KeychainStore.load() else {
                    throw MangaCoreError("请先在设置里填写 DeepSeek API Key")
                }
                setStatus(.working("正在翻译 \(page.blocks.count) 处文字…"))
                let memoryKey = webView.url?.host() ?? "local"
                let translator = PageTranslator(sendImage: settings.sendImage)
                let prompt = translator.userPrompt(
                    blocks: page.blocks, languageName: settings.sourceLanguage.displayName,
                    readingOrder: settings.sourceLanguage.readingOrder, memory: memories[memoryKey] ?? TranslationMemory())
                let result = try await translator.translate(
                    blocks: page.blocks, prompt: prompt, markedImage: page.markedJPEG,
                    using: DeepSeekClient(apiKey: apiKey))
                memories[memoryKey, default: TranslationMemory()].record(result)
                translated = result.blocks
            }

            let items = OverlayItem.items(
                for: translated, imageSize: page.imageSize, characterSize: page.characterSize, viewport: viewport)
            let json = String(decoding: try JSONEncoder().encode(items), as: UTF8.self)
            try await runScript(
                "window.__mangaTranslate.clearRegion(top, bottom); window.__mangaTranslate.render(JSON.parse(json));",
                arguments: ["top": viewport.top, "bottom": viewport.top + viewport.height, "json": json])

            let seconds = (ContinuousClock.now - started) / .seconds(1)
            let summary = items.isEmpty ? "这一屏没有需要翻译的台词" : String(format: "已翻译 %d 处，用时 %.1f 秒", items.count, seconds)
            setStatus(.done(settings.dryRun ? "试运行：" + summary : summary))
        } catch {
            _ = try? await runScript("window.__mangaTranslate?.show()")
            setStatus(.failed(error.localizedDescription))
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishedLoads += 1
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
        case .done: delay = .seconds(3)
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
        let ready = try await runScript("return window.__mangaTranslate !== undefined") as? Bool ?? false
        if !ready {
            try await runScript(OverlayScript.source)
        }
    }

    private func readViewport() async throws -> Viewport {
        guard let json = try await runScript(Viewport.readScript) as? String else {
            throw MangaCoreError("读取网页位置失败")
        }
        return try JSONDecoder().decode(Viewport.self, from: Data(json.utf8))
    }

    /// 在独立的 content world 里执行脚本；source 是函数体，需要返回值时写 return
    @discardableResult
    private func runScript(_ source: String, arguments: [String: Any] = [:]) async throws -> Any? {
        try await webView.callAsyncJavaScript(source, arguments: arguments, in: nil, contentWorld: .defaultClient)
    }

    private static func dryRunBlock(_ block: TextBlock) -> TranslatedBlock {
        var translated = TranslatedBlock(untranslated: block)
        translated.translation = block.text.replacingOccurrences(of: "\n", with: " ")
        translated.kind = block.text.isEmpty ? "noise" : "dialogue"
        return translated
    }
}
