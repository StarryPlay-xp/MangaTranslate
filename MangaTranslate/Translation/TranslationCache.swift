import CryptoKit
import Foundation
import MangaCore

nonisolated struct CachedImageTranslation: Codable, Sendable {
    var items: [ImageOverlayItem]
}

/// 已翻译图片的译文缓存，按图片地址和所用的模型服务保存在系统缓存目录。
/// 重看同一话时直接显示，不再调用模型；换了模型会重新翻译。手机空间不足时系统可能会清掉这些文件
enum TranslationCache {
    /// 提示词或贴字规则改了就加一，让旧缓存失效。
    /// 2：拟声词、标题也贴译文（旧缓存里没有这些块）
    private static let version = 2

    private static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Translations", isDirectory: true)
    }

    /// 接口格式、完整请求地址和模型名都算进去，换服务或换模型后才会重新翻译
    static func key(src: String, language: SourceLanguage, sendImage: Bool, service: LLMServiceConfig) -> String {
        let endpoint = (try? service.endpoint().absoluteString) ?? service.baseURL
        let parts = ["v\(version)", language.rawValue, "\(sendImage)", service.format.rawValue, endpoint, service.model, src]
        let digest = SHA256.hash(data: Data(parts.joined(separator: "|").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func load(_ key: String) -> CachedImageTranslation? {
        guard let data = try? Data(contentsOf: fileURL(for: key)) else { return nil }
        return try? JSONDecoder().decode(CachedImageTranslation.self, from: data)
    }

    static func save(_ translation: CachedImageTranslation, for key: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(translation).write(to: fileURL(for: key), options: .atomic)
    }

    static func sizeInBytes() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { total, file in
            total + ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    /// 网页文字的译文缓存也在这个目录里，一起清掉
    static func clear() {
        try? FileManager.default.removeItem(at: directory)
        PageTextCache.shared.clearMemory()
    }

    private static func fileURL(for key: String) -> URL {
        directory.appendingPathComponent(key + ".json")
    }
}
