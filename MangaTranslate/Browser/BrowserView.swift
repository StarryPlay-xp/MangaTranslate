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
                StatusBanner(status: model.status)
                    .padding(.top, 8)
                    .animation(.default, value: model.status)
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
                        Task { await model.translateVisibleArea(settings: settings) }
                    } label: {
                        Label("翻译这一屏", systemImage: "character.bubble")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isTranslating)

                    Spacer()

                    moreMenu
                }
            }
            .onAppear { model.load(destination) }
            #if DEBUG
            .onChange(of: model.finishedLoads) { _, count in
                // 调试用：启动参数带 -autoTranslate 时，页面加载完自动翻译一次
                guard count == 1, ProcessInfo.processInfo.arguments.contains("-autoTranslate") else { return }
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
