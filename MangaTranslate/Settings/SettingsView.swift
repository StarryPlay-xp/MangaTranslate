import MangaCore
import SwiftUI
import WebKit

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(BookmarkStore.self) private var bookmarks
    @Environment(ReadingHistory.self) private var history
    @Environment(\.dismiss) private var dismiss
    @State private var cacheSize = TranslationCache.sizeInBytes()
    @State private var storageMessage: String?
    @State private var editing: ServiceEditorTarget?
    @State private var confirmingHistoryClear = false
    @State private var confirmingWebDataClear = false
    /// 存了网页数据的网站个数；还没查完时为 nil
    @State private var websiteCount: Int?
    @State private var clearingWebData = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        servicesSection
                        translationSection
                        storageSection
                            .id(Self.storageAnchor)
                        aboutSection
                    }
                    .padding(Theme.pageMargin)
                    .padding(.bottom, 24)
                }
                #if DEBUG
                .task { await applyDebugFocus(proxy) }
                #endif
            }
            .background(Theme.paper)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .fontWeight(.heavy)
                }
            }
            .navigationDestination(item: $editing) { target in
                switch target {
                case .edit(let id):
                    if let service = settings.services.first(where: { $0.id == id }) {
                        ServiceEditorView(service: service, isNew: false)
                    }
                case .new(let service):
                    ServiceEditorView(service: service, isNew: true)
                }
            }
            #if DEBUG
            .onAppear {
                // 调试用：-openServiceEditor 直接打开当前模型服务的编辑页
                if ProcessInfo.processInfo.arguments.contains("-openServiceEditor") {
                    editing = .edit(settings.activeServiceID)
                }
            }
            #endif
        }
        .tint(Theme.magenta)
    }

    private static let storageAnchor = "storage"

    #if DEBUG
    /// 调试用：-settingsFocus storage 滚到"存储"区块；clearHistory、clearWebData 再弹出对应的确认框
    private func applyDebugFocus(_ proxy: ScrollViewProxy) async {
        guard let focus = UserDefaults.standard.string(forKey: "settingsFocus") else { return }
        try? await Task.sleep(for: .milliseconds(400))
        proxy.scrollTo(Self.storageAnchor, anchor: .top)
        try? await Task.sleep(for: .milliseconds(400))
        confirmingHistoryClear = focus == "clearHistory"
        confirmingWebDataClear = focus == "clearWebData"
    }
    #endif

    // MARK: - 模型服务

    private var servicesSection: some View {
        SettingsSection(
            "模型服务",
            note: "点一项设为当前使用，翻译都交给它。可以保存多个，换着用来比较译文；局域网里自己部署的模型（Ollama、LM Studio、vLLM 等）也能接。Key 存在这台设备的钥匙串里，不随 iCloud 同步。"
        ) {
            ForEach(settings.services) { service in
                serviceRow(service)
                InkDivider()
            }
            Menu {
                ForEach(LLMProviderPreset.all) { preset in
                    Button(preset.name) { editing = .new(ModelService(preset: preset)) }
                }
                Button("OpenAI 兼容格式（自己填地址）") { editing = .new(ModelService(customFormat: .openAICompatible)) }
                Button("Anthropic 格式（自己填地址）") { editing = .new(ModelService(customFormat: .anthropic)) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .black))
                    Text("添加模型服务")
                        .font(.system(size: 16, weight: .heavy))
                    Spacer()
                }
                .foregroundStyle(Theme.ink)
                .padding(14)
                .contentShape(Rectangle())
            }
        }
    }

    private func serviceRow(_ service: ModelService) -> some View {
        let active = service.id == settings.activeServiceID
        let missingKey = service.requiresAPIKey && !settings.hasAPIKey(for: service.id)
        return HStack(spacing: 12) {
            Button {
                settings.selectService(service.id)
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Rectangle()
                            .fill(active ? Theme.magenta : Theme.paper)
                        Rectangle()
                            .strokeBorder(Theme.ink, lineWidth: Theme.line)
                        if active {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .black))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(service.name)
                            .font(.system(size: 16, weight: .heavy))
                            .foregroundStyle(Theme.ink)
                        Text(service.summary)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        if missingKey {
                            Text("还没有填写 API Key")
                                .font(.system(size: 12, weight: .heavy))
                                .foregroundStyle(Theme.magenta)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(active ? .isSelected : [])
            .accessibilityHint("设为当前使用的模型服务")

            Button("编辑") { editing = .edit(service.id) }
                .buttonStyle(InkButtonStyle())
        }
        .padding(14)
    }

    // MARK: - 翻译

    private var translationSection: some View {
        @Bindable var settings = settings
        let imageDetail = settings.activeService.config.supportsImages
            ? "模型会对照画面核对原文，译文更准确"
            : "当前模型服务设成了不支持看图，只会发识别出的文字"
        return SettingsSection("翻译") {
            SettingsField("原文语言") {
                InkSegmented(
                    selection: $settings.sourceLanguage,
                    options: SourceLanguage.allCases.map { ($0, $0.displayName) })
            }
            InkDivider()
            SettingsToggleRow(
                title: "自动翻译", detail: "浏览时翻译屏幕上和下方 1.5 屏以内的漫画图片，滑到时译文通常已经准备好",
                isOn: $settings.autoTranslate)
            InkDivider()
            SettingsToggleRow(title: "把图片发给模型", detail: imageDetail, isOn: $settings.sendImage)
            InkDivider()
            SettingsToggleRow(
                title: "试运行", detail: "不调用模型，在原位置显示识别出的原文，用来检查识别效果", isOn: $settings.dryRun)
        }
    }

    // MARK: - 存储

    private var storageSection: some View {
        SettingsSection("存储", note: storageMessage ?? "翻译过的图片会按模型服务分别缓存译文，重看时直接显示、不再花钱；换了模型会重新翻译。术语记忆按网站保存人名等专有名词的译法，让前后译名一致。网页数据是各网站的登录状态、Cookie 和缓存，清除后要重新登录。") {
            storageRow("译文缓存", value: ByteCountFormatter.string(fromByteCount: Int64(cacheSize), countStyle: .file)) {
                TranslationCache.clear()
                cacheSize = TranslationCache.sizeInBytes()
                storageMessage = "已清除译文缓存"
            }
            InkDivider()
            storageRow("术语记忆", value: nil) {
                MemoryBank.clearAll()
                storageMessage = "已清除术语记忆，重新打开网页后生效"
            }
            InkDivider()
            storageRow("阅读记录", value: history.recent?.url.host() ?? "没有记录") {
                confirmingHistoryClear = true
            }
            .confirmationDialog("清除阅读记录？", isPresented: $confirmingHistoryClear, titleVisibility: .visible) {
                Button("清除阅读记录", role: .destructive) {
                    history.clear()
                    ThumbnailStore.removeUnused(bookmarks: bookmarks, history: history)
                    storageMessage = "已清除阅读记录"
                }
            } message: {
                Text("首页的「继续看」会清空，看过的页面里不在书架上的封面也会删掉。书架不受影响。")
            }
            InkDivider()
            storageRow("网页数据", value: webDataValue, disabled: clearingWebData) {
                confirmingWebDataClear = true
            }
            .confirmationDialog("清除网页数据？", isPresented: $confirmingWebDataClear, titleVisibility: .visible) {
                Button("清除网页数据", role: .destructive) {
                    Task { await clearWebData() }
                }
            } message: {
                Text("会删掉所有网站的 Cookie、缓存和本地存储：登录过的漫画网站都要重新登录，网站里的偏好设置也会恢复默认。书架、阅读记录和译文缓存不受影响。")
            }
        }
        .task { await countWebsites() }
    }

    private var webDataValue: String? {
        if clearingWebData { return "正在清除…" }
        return websiteCount.map { $0 == 0 ? "没有数据" : "\($0) 个网站" }
    }

    private func countWebsites() async {
        let records = await WKWebsiteDataStore.default().dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        websiteCount = records.count
    }

    /// 阅读页的 WKWebView 用的是默认数据存储，清掉它就是清掉网站的 Cookie、缓存和本地存储；
    /// App 自己下载漫画图片时的 HTTP 缓存在 URLCache.shared，也一起清掉
    private func clearWebData() async {
        clearingWebData = true
        await WKWebsiteDataStore.default().removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        URLCache.shared.removeAllCachedResponses()
        await countWebsites()
        clearingWebData = false
        storageMessage = "已清除网页数据，网站需要重新登录；正在看的网页刷新后生效"
    }

    // MARK: - 关于

    private var aboutSection: some View {
        let service = settings.activeService
        let host = (try? service.config.endpoint())?.host() ?? "地址未填写"
        return SettingsSection(
            "关于", note: "翻译时，漫画图片（带编号框）和识别出的文字会发送到你配置的地址，当前是 \(host)。不发图片时只发文字。"
        ) {
            infoRow("当前服务", value: service.name)
            InkDivider()
            infoRow("模型", value: service.config.model.isEmpty ? "未填写" : service.config.model)
            InkDivider()
            infoRow("版本", value: Bundle.main.versionText)
        }
    }

    // MARK: - 组件

    private func storageRow(
        _ title: String, value: String?, disabled: Bool = false, clear: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 16, weight: .heavy))
                .foregroundStyle(Theme.ink)
            if let value {
                Text(value)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.muted)
            }
            Spacer()
            Button("清除", action: clear)
                .buttonStyle(InkButtonStyle())
                .disabled(disabled)
                .opacity(disabled ? 0.45 : 1)
        }
        .padding(14)
    }

    private func infoRow(_ title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 16, weight: .heavy))
                .foregroundStyle(Theme.ink)
            Spacer()
            Text(value)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(14)
    }
}

/// 设置页里要打开的编辑页
enum ServiceEditorTarget: Hashable {
    case edit(UUID)
    case new(ModelService)
}

/// 墨线分段选择：选中的一格填墨色
struct InkSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                let selected = option.0 == selection
                Button {
                    selection = option.0
                } label: {
                    Text(option.1)
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(selected ? Theme.paper : Theme.ink)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(selected ? Theme.ink : Theme.paper)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                if index < options.count - 1 {
                    Rectangle().fill(Theme.ink).frame(width: Theme.line)
                }
            }
        }
        .overlay(Rectangle().strokeBorder(Theme.ink, lineWidth: Theme.line))
    }
}

extension Bundle {
    var versionText: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version)（\(build)）"
    }
}
