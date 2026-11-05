import SwiftUI

enum BrowserDestination: Hashable {
    case web(URL)
    /// 从"继续看"打开，加载完后回到上次的位置
    case resume(URL, scrollY: Double)
    case demo
}

struct HomeView: View {
    @Environment(BookmarkStore.self) private var bookmarks
    @Environment(ReadingHistory.self) private var history
    @Environment(AppSettings.self) private var settings
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var path: [BrowserDestination] = []
    @State private var address = ""
    @State private var showingSettings = false

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    header
                    addressBubble
                    if let recent = history.recent {
                        continueSection(recent)
                    }
                    SiteSection(onOpen: openSite)
                    shelfSection
                }
                .padding(.horizontal, Theme.pageMargin)
                // iPad 上不铺满屏幕，居中成一栏
                .frame(maxWidth: Theme.contentMaxWidth + Theme.pageMargin * 2)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.paper)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: BrowserDestination.self) { destination in
                BrowserView(destination: destination)
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            #if DEBUG
            .onAppear {
                let arguments = ProcessInfo.processInfo.arguments
                // 调试用：-seedShelf 往书架放几条示例书签，方便截图检查界面
                if arguments.contains("-seedShelf"), bookmarks.items.isEmpty {
                    seedShelfForPreview()
                }
                // 调试用：启动参数带 -openDemo 时直接打开示例页，带 -openSettings 时打开设置，
                // -openURL <网址> 直接打开那个网页
                if let address = UserDefaults.standard.string(forKey: "openURL"), let url = URL(string: address),
                   path.isEmpty {
                    path.append(.web(url))
                }
                if arguments.contains("-openDemo"), path.isEmpty {
                    path.append(.demo)
                }
                if arguments.contains("-openSettings") {
                    showingSettings = true
                }
            }
            #endif
        }
        .tint(Theme.magenta)
    }

    // MARK: - 标题

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("漫译")
                    .font(.mangaTitle)
                    .foregroundStyle(Theme.ink)
                Text("打开漫画网页，边看边翻成中文")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.muted)
            }
            Spacer()
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 18, weight: .bold))
            }
            .buttonStyle(InkIconButtonStyle())
            .accessibilityLabel("设置")
        }
        .padding(.top, 12)
    }

    // MARK: - 地址栏：做成对话气泡

    private var addressBubble: some View {
        let bubble = SpeechBubble(cornerRadius: 26, tailHeight: 11, tailWidth: 16, tailPosition: 0.84, tailLean: 0.7)
        return HStack(spacing: 8) {
            TextField("输入网址或搜索漫画", text: $address)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.ink)
                .keyboardType(.webSearch)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit(openAddress)
            Button(action: openAddress) {
                Image(systemName: "arrow.right")
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Theme.magenta))
                    .overlay(Circle().strokeBorder(Theme.ink, lineWidth: 2))
            }
            .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
            .opacity(address.trimmingCharacters(in: .whitespaces).isEmpty ? 0.45 : 1)
            .accessibilityLabel("打开网址")
        }
        .padding(.leading, 20)
        .padding(.trailing, 7)
        .padding(.top, 7)
        .padding(.bottom, 7 + 11)
        .background(bubble.fill(Theme.paper))
        .overlay(bubble.stroke(Theme.ink, style: StrokeStyle(lineWidth: Theme.line, lineJoin: .round)))
    }

    // MARK: - 继续看

    private func continueSection(_ recent: RecentPage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("继续看")
                .font(.sectionTitle)
                .foregroundStyle(Theme.ink)
            Button {
                path.append(.resume(recent.url, scrollY: recent.scrollY))
            } label: {
                continueCard(recent)
                    .panel(shadow: true)
                    .padding(.trailing, 6)
            }
            .buttonStyle(PanelButtonStyle())
            .contextMenu {
                Button("从继续看里移除", systemImage: "xmark", role: .destructive) {
                    history.clear()
                    ThumbnailStore.removeUnused(bookmarks: bookmarks, history: history)
                }
            }
        }
    }

    /// 手机上封面在上、文字在下；iPad 上封面在左、文字在右，免得封面被拉成一长条
    @ViewBuilder
    private func continueCard(_ recent: RecentPage) -> some View {
        let caption = VStack(alignment: .leading, spacing: 5) {
            Text(recent.title.isEmpty ? (recent.url.host() ?? "上次看的页面") : recent.title)
                .font(.system(size: 18, weight: .heavy))
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text("\(recent.url.host() ?? "")，\(Self.relative(recent.visitedAt))看到这里")
                .font(.panelCaption)
                .foregroundStyle(Theme.muted)
        }
        if isWide {
            HStack(spacing: 0) {
                PageCover(url: recent.url)
                    .frame(width: 320)
                Rectangle().fill(Theme.ink).frame(width: Theme.line)
                caption
                    .padding(18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(height: 200)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                PageCover(url: recent.url)
                    .frame(height: 190)
                Rectangle().fill(Theme.ink).frame(height: Theme.line)
                caption
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// iPad 全屏或较宽的窗口
    private var isWide: Bool { sizeClass == .regular }

    // MARK: - 书架

    private var shelfSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("书架")
                .font(.sectionTitle)
                .foregroundStyle(Theme.ink)
            VStack(spacing: Theme.gutter) {
                if bookmarks.items.isEmpty {
                    Text("看到喜欢的漫画，在阅读页点右上角的星标，就会放到这里。")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .overlay(
                            Rectangle().strokeBorder(Theme.ink, style: StrokeStyle(lineWidth: Theme.thinLine, dash: [6, 5])))
                }
                ForEach(Array(shelfRows.enumerated()), id: \.offset) { index, row in
                    PanelRow(fractions: shelfFractions(row: index), spacing: Theme.gutter) {
                        ForEach(row) { bookmark in
                            Button {
                                path.append(.web(bookmark.url))
                            } label: {
                                ShelfPanel(bookmark: bookmark)
                            }
                            .buttonStyle(PanelButtonStyle())
                            .contextMenu {
                                Button("移出书架", systemImage: "trash", role: .destructive) {
                                    bookmarks.remove(url: bookmark.url)
                                    ThumbnailStore.removeUnused(bookmarks: bookmarks, history: history)
                                }
                            }
                        }
                    }
                    .frame(height: isWide ? 240 : 210)
                }
                demoPanel
            }
        }
    }

    /// 书签手机上两个一行，iPad 上三个一行
    private var shelfRows: [[Bookmark]] {
        let columns = isWide ? 3 : 2
        return stride(from: 0, to: bookmarks.items.count, by: columns).map {
            Array(bookmarks.items[$0..<min($0 + columns, bookmarks.items.count)])
        }
    }

    /// 各格宽度的比例，隔行换一下宽格的位置，排出分镜的错落感
    private func shelfFractions(row: Int) -> [CGFloat] {
        let even = row.isMultiple(of: 2)
        if isWide {
            return even ? [0.42, 0.29, 0.29] : [0.29, 0.29, 0.42]
        }
        return even ? [0.58, 0.42] : [0.42, 0.58]
    }

    private var demoPanel: some View {
        Button {
            path.append(.demo)
        } label: {
            HStack(spacing: 0) {
                ZStack {
                    Halftone(spacing: 6, maxDot: 3)
                    Text("例")
                        .font(.system(size: 30, weight: .black))
                        .foregroundStyle(Theme.ink)
                }
                .frame(width: 86)
                Rectangle().fill(Theme.ink).frame(width: Theme.line)
                VStack(alignment: .leading, spacing: 3) {
                    Text("示例页")
                        .font(.panelTitle)
                        .foregroundStyle(Theme.ink)
                    Text("用程序生成的测试页，先试试识别和翻译")
                        .font(.panelCaption)
                        .foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 86)
            .panel()
        }
        .buttonStyle(PanelButtonStyle())
    }

    /// 像网址就打开，不像网址就用 Google 搜索
    private func openAddress() {
        guard let url = URL.addressBarDestination(address) else { return }
        path.append(.web(url))
    }

    /// 打开韩漫网站时原文语言切到韩语，日漫网站切到日语
    private func openSite(_ site: MangaSite) {
        settings.sourceLanguage = site.language
        path.append(.web(site.url))
    }

    private static func relative(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named).locale(Locale(identifier: "zh-Hans")))
    }

    #if DEBUG
    private func seedShelfForPreview() {
        let samples: [(String, String, String?)] = [
            ("示例日漫 第 12 话", "https://example.com/manga/12", "demo-ja"),
            ("示例条漫 第 3 话", "https://example.org/webtoon/3", "demo-long"),
            ("示例韩漫 第 7 话", "https://example.net/comic/7", "demo-ko"),
            ("还没有封面的书签", "https://manga.example/series/1", nil),
        ]
        for (title, address, image) in samples.reversed() {
            guard let url = URL(string: address) else { continue }
            if let image, let path = Bundle.main.path(forResource: image, ofType: "png"), let cover = UIImage(contentsOfFile: path) {
                ThumbnailStore.save(cover, for: url)
            }
            bookmarks.add(title: title, url: url)
        }
        if let url = URL(string: "https://example.com/manga/12") {
            history.update(title: "示例日漫 第 12 话", url: url, scrollY: 1200)
        }
    }
    #endif
}
