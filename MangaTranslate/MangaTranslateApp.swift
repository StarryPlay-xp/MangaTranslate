import SwiftUI

@main
struct MangaTranslateApp: App {
    @State private var settings = AppSettings()
    @State private var bookmarks = BookmarkStore()
    @State private var history = ReadingHistory()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(settings)
                .environment(bookmarks)
                .environment(history)
        }
    }
}
