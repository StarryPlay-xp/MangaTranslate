import Foundation
import Observation

struct Bookmark: Codable, Hashable, Identifiable {
    var id = UUID()
    var title: String
    var url: URL
}

/// 书签保存在 UserDefaults 里
@Observable
final class BookmarkStore {
    private static let key = "bookmarks"
    private(set) var items: [Bookmark]

    init() {
        let data = UserDefaults.standard.data(forKey: Self.key)
        items = data.flatMap { try? JSONDecoder().decode([Bookmark].self, from: $0) } ?? []
    }

    func contains(_ url: URL) -> Bool {
        items.contains { $0.url == url }
    }

    func add(title: String, url: URL) {
        guard !contains(url) else { return }
        items.append(Bookmark(title: title.isEmpty ? (url.host() ?? url.absoluteString) : title, url: url))
        save()
    }

    func remove(url: URL) {
        items.removeAll { $0.url == url }
        save()
    }

    func remove(atOffsets offsets: IndexSet) {
        items.remove(atOffsets: offsets)
        save()
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(items), forKey: Self.key)
    }
}
