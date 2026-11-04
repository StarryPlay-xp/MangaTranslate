import SwiftUI
import WebKit

/// 把 BrowserModel 持有的 WKWebView 放进 SwiftUI
struct WebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}
