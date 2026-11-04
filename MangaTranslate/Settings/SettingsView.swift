import MangaCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var keyInput = ""
    @State private var keyMessage: String?
    @State private var cacheSize = TranslationCache.sizeInBytes()
    @State private var storageMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    keySection
                    translationSection
                    storageSection
                    aboutSection
                }
                .padding(Theme.pageMargin)
                .padding(.bottom, 24)
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
        }
        .tint(Theme.magenta)
    }

    // MARK: - DeepSeek API Key

    private var keySection: some View {
        section("DeepSeek API Key", note: "在 DeepSeek 开放平台创建 Key 后粘贴到这里。Key 存在这台设备的钥匙串里，不随 iCloud 同步，也不会显示出来。") {
            HStack(spacing: 10) {
                Image(systemName: settings.hasAPIKey ? "checkmark.seal.fill" : "key")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(settings.hasAPIKey ? Theme.magenta : Theme.muted)
                Text(settings.hasAPIKey ? "已保存" : "还没有填写")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(Theme.ink)
                Spacer()
                if settings.hasAPIKey {
                    Button("删除", role: .destructive) {
                        settings.deleteAPIKey()
                        keyMessage = "已删除"
                    }
                    .font(.system(size: 15, weight: .heavy))
                }
            }
            .padding(14)
            divider
            VStack(alignment: .leading, spacing: 10) {
                SecureField(settings.hasAPIKey ? "粘贴新的 Key 可替换旧的" : "粘贴 DeepSeek API Key", text: $keyInput)
                    .font(.system(size: 16, weight: .medium))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    .overlay(Rectangle().strokeBorder(Theme.ink, lineWidth: Theme.thinLine))
                HStack {
                    if let keyMessage {
                        Text(keyMessage)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Button("保存 Key", action: saveKey)
                        .buttonStyle(InkButtonStyle(prominent: true))
                        .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .opacity(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
                }
            }
            .padding(14)
        }
    }

    // MARK: - 翻译

    private var translationSection: some View {
        @Bindable var settings = settings
        return section("翻译") {
            VStack(alignment: .leading, spacing: 10) {
                Text("原文语言")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(Theme.ink)
                InkSegmented(
                    selection: $settings.sourceLanguage,
                    options: SourceLanguage.allCases.map { ($0, $0.displayName) })
            }
            .padding(14)
            divider
            toggleRow("自动翻译", detail: "浏览时翻译屏幕上和下方 1.5 屏以内的漫画图片，滑到时译文通常已经准备好", isOn: $settings.autoTranslate)
            divider
            toggleRow("把图片发给模型", detail: "模型会对照画面核对原文，译文更准确", isOn: $settings.sendImage)
            divider
            toggleRow("试运行", detail: "不调用 DeepSeek，在原位置显示识别出的原文，用来检查识别效果", isOn: $settings.dryRun)
        }
    }

    // MARK: - 存储

    private var storageSection: some View {
        section("存储", note: storageMessage ?? "翻译过的图片会缓存译文，重看时直接显示、不再花钱。术语记忆按网站保存人名等专有名词的译法，让前后译名一致。") {
            storageRow("译文缓存", value: ByteCountFormatter.string(fromByteCount: Int64(cacheSize), countStyle: .file)) {
                TranslationCache.clear()
                cacheSize = TranslationCache.sizeInBytes()
                storageMessage = "已清除译文缓存"
            }
            divider
            storageRow("术语记忆", value: nil) {
                MemoryBank.clearAll()
                storageMessage = "已清除术语记忆，重新打开网页后生效"
            }
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
        section("关于", note: "翻译时，漫画图片（带编号框）和识别出的文字会发送到 DeepSeek（api.deepseek.com）。") {
            infoRow("翻译模型", value: DeepSeekPricing.pricedModel)
            divider
            infoRow("版本", value: Bundle.main.versionText)
        }
    }

    // MARK: - 组件

    private var divider: some View {
        Rectangle().fill(Theme.ink).frame(height: Theme.thinLine)
    }

    private func section<Content: View>(_ title: String, note: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.sectionTitle)
                .foregroundStyle(Theme.ink)
            VStack(alignment: .leading, spacing: 0, content: content)
                .panel()
            if let note {
                Text(note)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func toggleRow(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(Theme.ink)
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(Theme.magenta)
        .padding(14)
    }

    private func storageRow(_ title: String, value: String?, clear: @escaping () -> Void) -> some View {
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
        }
        .padding(14)
    }

    private func infoRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 16, weight: .heavy))
                .foregroundStyle(Theme.ink)
            Spacer()
            Text(value)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.muted)
        }
        .padding(14)
    }

    private func saveKey() {
        do {
            try settings.saveAPIKey(keyInput)
            keyInput = ""
            keyMessage = "已保存到钥匙串"
        } catch {
            keyMessage = error.localizedDescription
        }
    }
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
