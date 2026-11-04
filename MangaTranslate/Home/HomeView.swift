import SwiftUI

enum BrowserDestination: Hashable {
    case web(URL)
    case demo
}

struct HomeView: View {
    @Environment(BookmarkStore.self) private var bookmarks
    @State private var path: [BrowserDestination] = []
    @State private var address = ""
    @State private var addressError: String?
    @State private var showingSettings = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section("打开网址") {
                    TextField("输入网址，例如 comic.naver.com", text: $address)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit(openAddress)
                    if let addressError {
                        Text(addressError).font(.footnote).foregroundStyle(.red)
                    }
                }

                Section("书签") {
                    if bookmarks.items.isEmpty {
                        Text("还没有书签。打开网页后，可以在右下角的菜单里加入书签。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(bookmarks.items) { bookmark in
                        NavigationLink(value: BrowserDestination.web(bookmark.url)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bookmark.title).lineLimit(1)
                                Text(bookmark.url.host() ?? bookmark.url.absoluteString)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .onDelete { bookmarks.remove(atOffsets: $0) }
                }

                Section {
                    NavigationLink(value: BrowserDestination.demo) {
                        Label("内置示例页", systemImage: "book.pages")
                    }
                } header: {
                    Text("示例")
                } footer: {
                    Text("示例页的图片是程序生成的测试页，可以先用它试试识别和翻译。")
                }
            }
            .navigationTitle("漫译")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("设置")
                }
            }
            .navigationDestination(for: BrowserDestination.self) { destination in
                BrowserView(destination: destination)
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            #if DEBUG
            .onAppear {
                // 调试用：启动参数带 -openDemo 时直接打开示例页
                if ProcessInfo.processInfo.arguments.contains("-openDemo"), path.isEmpty {
                    path.append(.demo)
                }
            }
            #endif
        }
    }

    private func openAddress() {
        guard let url = URL(userInput: address) else {
            addressError = "这不是有效的网址"
            return
        }
        addressError = nil
        path.append(.web(url))
    }
}

extension URL {
    /// 把用户输入补全成网址，没写协议时默认 https；只接受 http 和 https
    init?(userInput: String) {
        let text = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        let withScheme = text.contains("://") ? text : "https://" + text
        guard let url = URL(string: withScheme),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host(), host.contains(".")
        else {
            return nil
        }
        self = url
    }
}
