import SwiftUI
import UIKit

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

    /// 地址栏的输入：像网址就打开，不像网址（比如漫画名）就交给 Google 搜索
    static func addressBarDestination(_ input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = URL(userInput: text) { return url }
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: text)]
        return components?.url
    }

    /// 地址栏里显示的网址：去掉协议和 www.，首页不带结尾的斜杠
    var addressBarText: String {
        guard let scheme = scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            return isFileURL ? "内置示例页" : absoluteString
        }
        var host = host() ?? ""
        if host.hasPrefix("www.") { host.removeFirst(4) }
        var text = host
        if let port { text += ":\(port)" }
        let path = path(percentEncoded: false)
        if path != "/" { text += path }
        if let query = query(percentEncoded: false), !query.isEmpty { text += "?" + query }
        return text
    }
}

/// 阅读页顶栏中间的地址栏：平时显示网页标题和网址，点一下进入编辑，可以改网址或输入关键词搜索。
/// 长按可以复制网址
struct AddressBar: View {
    let title: String
    let url: URL?
    let isLoading: Bool
    @Binding var isEditing: Bool
    let onOpen: (URL) -> Void

    @State private var text = ""
    @State private var selection: TextSelection?
    @FocusState private var focused: Bool

    var body: some View {
        if isEditing {
            editor
        } else {
            display
        }
    }

    // MARK: - 平时：标题和网址

    private var display: some View {
        Button(action: beginEditing) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title.isEmpty ? (isLoading ? "加载中…" : (url?.host() ?? "")) : title)
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if isLoading {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(Theme.muted)
                    } else if url?.scheme == "https" {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9, weight: .bold))
                    }
                    Text(url?.addressBarText ?? "")
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("地址栏")
        .accessibilityValue(url?.addressBarText ?? "")
        .accessibilityHint("编辑网址或搜索")
        .contextMenu {
            if let url, url.scheme?.hasPrefix("http") == true {
                Button("复制网址", systemImage: "doc.on.doc") {
                    UIPasteboard.general.url = url
                }
            }
            Button("编辑网址", systemImage: "pencil", action: beginEditing)
        }
    }

    // MARK: - 编辑：输入框、清空和取消

    private var editor: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                TextField("输入网址或搜索", text: $text, selection: $selection)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .keyboardType(.webSearch)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($focused)
                    .onSubmit(submit)
                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.tone)
                            .frame(width: 30, height: 36)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清空")
                }
            }
            .padding(.leading, 12)
            .frame(height: 36)
            .background(Theme.tone.opacity(0.35))

            Button("取消", action: endEditing)
                .font(.system(size: 15, weight: .heavy))
                .foregroundStyle(Theme.ink)
                .frame(minWidth: 44, minHeight: 44)
        }
        .padding(.leading, 6)
        .onAppear {
            text = url.flatMap { $0.scheme?.hasPrefix("http") == true ? $0.absoluteString : nil } ?? ""
            focused = true
        }
        // 刚获得焦点时全选，直接输入就会替换掉原来的网址
        .onChange(of: focused) { _, isFocused in
            if isFocused {
                selection = TextSelection(range: text.startIndex..<text.endIndex)
            } else {
                endEditing()
            }
        }
    }

    private func beginEditing() {
        isEditing = true
    }

    private func endEditing() {
        focused = false
        isEditing = false
    }

    private func submit() {
        guard let destination = URL.addressBarDestination(text) else { return }
        endEditing()
        onOpen(destination)
    }
}
