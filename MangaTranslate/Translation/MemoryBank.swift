import Foundation
import MangaCore

/// 按网站保存术语表和最近的译文，下次打开同一网站的下一话时继续沿用，译名保持一致
final class MemoryBank {
    private var memories: [String: TranslationMemory] = [:]

    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Memories", isDirectory: true)
    }

    func memory(for host: String) -> TranslationMemory {
        if let memory = memories[host] { return memory }
        let loaded = (try? Data(contentsOf: Self.fileURL(for: host)))
            .flatMap { try? JSONDecoder().decode(TranslationMemory.self, from: $0) } ?? TranslationMemory()
        memories[host] = loaded
        return loaded
    }

    func record(_ translation: PageTranslation, host: String) {
        var memory = memory(for: host)
        memory.record(translation)
        memories[host] = memory
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(memory).write(to: Self.fileURL(for: host), options: .atomic)
    }

    static func clearAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// 网站域名里只保留字母、数字、点和横线，作为文件名
    private static func fileURL(for host: String) -> URL {
        let safe = String(host.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" })
        return directory.appendingPathComponent((safe.isEmpty ? "local" : safe) + ".json")
    }
}
