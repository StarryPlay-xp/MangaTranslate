import MangaCore
import SwiftUI

struct BrowserView: View {
    let destination: BrowserDestination
    @Environment(AppSettings.self) private var settings
    @Environment(BookmarkStore.self) private var bookmarks
    @State private var model = BrowserModel()

    var body: some View {
        WebView(webView: model.webView)
            .overlay(alignment: .top) {
                StatusBanner(status: model.bannerStatus)
                    .padding(.top, 8)
                    .animation(.default, value: model.bannerStatus)
            }
            .navigationTitle(model.title.isEmpty ? "加载中…" : model.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button {
                        model.webView.goBack()
                    } label: {
                        Image(systemName: "chevron.backward")
                    }
                    .disabled(!model.canGoBack)
                    .accessibilityLabel("后退")

                    Button {
                        model.webView.goForward()
                    } label: {
                        Image(systemName: "chevron.forward")
                    }
                    .disabled(!model.canGoForward)
                    .accessibilityLabel("前进")

                    Spacer()

                    Button {
                        settings.autoTranslate.toggle()
                    } label: {
                        Label(
                            settings.autoTranslate ? "自动翻译：开" : "自动翻译：关",
                            systemImage: settings.autoTranslate ? "character.bubble.fill" : "character.bubble")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(settings.autoTranslate ? Color("AccentColor") : Color.gray)

                    Spacer()

                    moreMenu
                }
            }
            .onAppear {
                model.attach(settings: settings)
                model.load(destination)
            }
            .onChange(of: settings.autoTranslate) { _, enabled in
                model.setAutoTranslate(enabled)
            }
            .onChange(of: settings.sourceLanguage) {
                model.retranslateAll()
            }
            #if DEBUG
            .onChange(of: model.finishedLoads) { _, count in
                // 调试用：启动参数带 -translateScreen 时，页面加载完执行一次"只翻译这一屏"
                guard count == 1, ProcessInfo.processInfo.arguments.contains("-translateScreen") else { return }
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    await model.translateVisibleArea(settings: settings)
                }
            }
            #endif
    }

    private var moreMenu: some View {
        @Bindable var settings = settings
        return Menu {
            Picker("原文语言", selection: $settings.sourceLanguage) {
                ForEach(SourceLanguage.allCases, id: \.self) { language in
                    Text(language.displayName).tag(language)
                }
            }
            Button("只翻译这一屏", systemImage: "rectangle.dashed") {
                Task { await model.translateVisibleArea(settings: settings) }
            }
            .disabled(model.isTranslatingScreen)
            Button("清除译文", systemImage: "eraser") { model.clearTranslations() }
            Button("刷新", systemImage: "arrow.clockwise") { model.webView.reload() }
            if let url = model.currentURL, url.scheme?.hasPrefix("http") == true {
                if bookmarks.contains(url) {
                    Button("移除书签", systemImage: "star.slash") { bookmarks.remove(url: url) }
                } else {
                    Button("加入书签", systemImage: "star") { bookmarks.add(title: model.title, url: url) }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("更多")
    }
}

/// 页面顶部的状态提示：进行中显示转圈，完成或失败显示图标
struct StatusBanner: View {
    let status: TranslationStatus

    var body: some View {
        switch status {
        case .idle:
            EmptyView()
        case .working(let text):
            banner(text) { ProgressView() }
        case .done(let text):
            banner(text) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
        case .failed(let text):
            banner(text) { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
        }
    }

    private func banner(_ text: String, @ViewBuilder icon: () -> some View) -> some View {
        HStack(spacing: 8) {
            icon()
            Text(text).font(.subheadline)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        .padding(.horizontal)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
