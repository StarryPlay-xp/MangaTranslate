import SwiftUI
import WebKit

/// 把 BrowserModel 持有的 WKWebView 放进 SwiftUI
struct WebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}

extension WKWebView {
    /// 在注入脚本所在的独立 content world 里执行；source 是函数体，需要返回值时写 return，可以 await
    @discardableResult
    func runIsolatedScript(_ source: String, arguments: [String: Any] = [:]) async throws -> Any? {
        try await callAsyncJavaScript(source, arguments: arguments, in: nil, contentWorld: .defaultClient)
    }
}
