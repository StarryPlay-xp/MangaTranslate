import Foundation
import MangaCore

/// 下载网页里的漫画图片。请求带上网页的 Referer、User-Agent 和该图片域名的 Cookie，
/// 和浏览器自己加载这张图时发出的请求一样，避免被网站的防盗链拒绝
enum ImageLoader {
    nonisolated static func download(
        _ url: URL, referer: URL?, userAgent: String?, cookieHeader: String?
    ) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 30)
        request.httpShouldHandleCookies = false
        request.setValue("image/avif,image/webp,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        if let referer, referer.scheme?.hasPrefix("http") == true {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        }
        if let userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        if let cookieHeader { request.setValue(cookieHeader, forHTTPHeaderField: "Cookie") }

        let (data, response) = try await URLSession.shared.data(for: request)
        // file: 和 data: 地址没有 HTTP 状态码，直接用
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw MangaCoreError("图片下载失败（HTTP \(http.statusCode)）")
        }
        guard !data.isEmpty else { throw MangaCoreError("图片内容为空") }
        return data
    }

    /// 从 WKWebView 的 Cookie 里挑出这张图片的域名和路径能用的，拼成 Cookie 请求头
    static func cookieHeader(for url: URL, from cookies: [HTTPCookie]) -> String? {
        guard let host = url.host()?.lowercased() else { return nil }
        let isSecure = url.scheme == "https"
        let path = url.path().isEmpty ? "/" : url.path()
        let matching = cookies.filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let domainMatches = host == domain || host.hasSuffix("." + domain)
            return domainMatches && path.hasPrefix(cookie.path) && (isSecure || !cookie.isSecure)
        }
        return HTTPCookie.requestHeaderFields(with: matching)["Cookie"]
    }
}
