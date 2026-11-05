import MangaCore
import SwiftUI

struct BrowserView: View {
    let destination: BrowserDestination
    @Environment(AppSettings.self) private var settings
    @Environment(BookmarkStore.self) private var bookmarks
    @Environment(ReadingHistory.self) private var history
    @Environment(UsageLedger.self) private var usage
    @Environment(\.dismiss) private var dismiss
    @State private var model = BrowserModel()
    @State private var showingSettings = false

    var body: some View {
        WebView(webView: model.webView)
            .ignoresSafeArea(edges: .bottom)
            .background(Theme.paper)
            .overlay(alignment: .top) {
                topBar
                    .offset(y: model.chromeHidden ? -120 : 0)
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 12) {
                    if let message = model.message {
                        MessageBubble(
                            message: message,
                            onOpenSettings: {
                                model.dismissMessage()
                                showingSettings = true
                            },
                            onDismiss: model.dismissMessage)
                        .transition(.scale(scale: 0.9, anchor: .bottom).combined(with: .opacity))
                    }
                    bottomBar
                        .offset(y: model.chromeHidden ? 140 : 0)
                }
                .padding(.bottom, 6)
            }
            .animation(.snappy(duration: 0.28), value: model.chromeHidden)
            .animation(.snappy(duration: 0.25), value: model.message)
            .toolbar(.hidden, for: .navigationBar)
            .sensoryFeedback(.selection, trigger: settings.autoTranslate)
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .onAppear {
                model.attach(settings: settings, history: history, bookmarks: bookmarks, usage: usage)
                model.load(destination)
            }
            .onDisappear {
                Task { await model.saveReadingProgress(captureCover: true) }
            }
            .onChange(of: settings.autoTranslate) { _, enabled in
                model.setAutoTranslate(enabled)
            }
            .onChange(of: settings.sourceLanguage) {
                model.retranslateAll()
            }
            // 换了模型服务（或改了它的地址、模型）后按新服务重新翻译；之前用过的服务有缓存，切回去直接显示
            .onChange(of: settings.activeService) {
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

    // MARK: - 顶栏：返回书架、标题、加入书架

    private var topBar: some View {
        HStack(spacing: 4) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .heavy))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("返回书架")

            Text(model.title.isEmpty ? "加载中…" : model.title)
                .font(.system(size: 15, weight: .heavy))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if model.canBookmark, let url = model.currentURL {
                let saved = bookmarks.contains(url)
                Button {
                    Task { await model.toggleBookmark() }
                } label: {
                    Image(systemName: saved ? "star.fill" : "star")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(saved ? Theme.magenta : Theme.ink)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(saved ? "移出书架" : "加入书架")
            }
        }
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 4)
        .background(Theme.paper)
        .overlay(Rectangle().strokeBorder(Theme.ink, lineWidth: Theme.line))
        .padding(.horizontal, 12)
        .padding(.top, 2)
    }

    // MARK: - 底栏：前进后退、翻译开关、更多

    private var bottomBar: some View {
        HStack(spacing: 0) {
            barButton("chevron.backward", label: "后退", enabled: model.canGoBack) { model.webView.goBack() }
            barButton("chevron.forward", label: "前进", enabled: model.canGoForward) { model.webView.goForward() }
            Spacer(minLength: 0)
            moreMenu
        }
        .padding(.horizontal, 10)
        .frame(height: 54)
        .background(Capsule().fill(Theme.bar))
        .overlay(Capsule().strokeBorder(Theme.tone.opacity(0.6), lineWidth: 1))
        .overlay {
            TranslateToggle(isOn: settings.autoTranslate, isBusy: model.isBusy) {
                settings.autoTranslate.toggle()
            }
            .offset(y: -8)
        }
        .padding(.horizontal, 20)
    }

    private func barButton(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color.white.opacity(enabled ? 1 : 0.3))
                .frame(width: 46, height: 46)
        }
        .disabled(!enabled)
        .accessibilityLabel(label)
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
            Button("设置", systemImage: "gearshape") { showingSettings = true }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 18, weight: .black))
                .foregroundStyle(Color.white)
                .frame(width: 46, height: 46)
        }
        .accessibilityLabel("更多")
    }
}
