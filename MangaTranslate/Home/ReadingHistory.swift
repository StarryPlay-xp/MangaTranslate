import CryptoKit
import Foundation
import Observation
import UIKit

/// 最近看的一页，首页"继续看"用它回到上次的位置
struct RecentPage: Codable, Equatable {
    var title: String
    var url: URL
    /// 上次看到的位置（CSS 像素）
    var scrollY: Double
    var visitedAt: Date
}

/// 阅读记录，保存在 UserDefaults；只记录 http/https 网页，示例页不记
@Observable
final class ReadingHistory {
    private static let key = "recentPage"
    private(set) var recent: RecentPage?

    init() {
        recent = UserDefaults.standard.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(RecentPage.self, from: $0) }
    }

    func update(title: String, url: URL, scrollY: Double? = nil) {
        guard url.scheme?.hasPrefix("http") == true else { return }
        let sameURL = recent?.url == url
        let page = RecentPage(
            title: title.isEmpty ? (sameURL ? recent?.title ?? "" : "") : title,
            url: url,
            scrollY: scrollY ?? (sameURL ? recent?.scrollY ?? 0 : 0),
            visitedAt: Date())
        guard page.title != recent?.title || page.url != recent?.url || page.scrollY != recent?.scrollY else { return }
        recent = page
        UserDefaults.standard.set(try? JSONEncoder().encode(page), forKey: Self.key)
    }

    /// 清除阅读记录；封面要另外调用 ThumbnailStore.removeUnused 清理
    func clear() {
        recent = nil
        UserDefaults.standard.removeObject(forKey: Self.key)
    }
}

extension ThumbnailStore {
    /// 删掉书架和「继续看」都不再用的封面。
    /// 每次离开阅读页都会给那一页存封面，而记录只留最近一页，所以移出书架、「继续看」换了一页、
    /// 清除阅读记录之后都要清一次，不然封面会越积越多
    static func removeUnused(bookmarks: BookmarkStore, history: ReadingHistory) {
        removeAll(except: bookmarks.items.map(\.url) + [history.recent?.url].compactMap { $0 })
    }
}

/// 页面缩略图，按网址存在 Application Support；书架和"继续看"的封面都用它
enum ThumbnailStore {
    private static let cache = NSCache<NSString, UIImage>()

    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Thumbnails", isDirectory: true)
    }

    static func image(for url: URL) -> UIImage? {
        let key = fileName(for: url) as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = UIImage(contentsOfFile: directory.appendingPathComponent(key as String).path) else {
            return nil
        }
        cache.setObject(image, forKey: key)
        return image
    }

    static func save(_ image: UIImage, for url: URL) {
        guard let data = image.jpegData(compressionQuality: 0.8) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = fileName(for: url)
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
        cache.setObject(image, forKey: name as NSString)
    }

    static func remove(for url: URL) {
        let name = fileName(for: url)
        cache.removeObject(forKey: name as NSString)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }

    /// 删掉除这些网址以外的全部缩略图
    static func removeAll(except kept: [URL]) {
        let keptNames = Set(kept.map(fileName(for:)))
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where !keptNames.contains(file.lastPathComponent) {
            cache.removeObject(forKey: file.lastPathComponent as NSString)
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func fileName(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined() + ".jpg"
    }
}
