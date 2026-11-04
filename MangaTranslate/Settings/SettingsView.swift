import MangaCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var keyInput = ""
    @State private var keyMessage: String?

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section {
                    if settings.hasAPIKey {
                        Label("已保存", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    SecureField(settings.hasAPIKey ? "粘贴新的 Key 可替换旧的" : "粘贴 DeepSeek API Key", text: $keyInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("保存") { saveKey() }
                        .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if settings.hasAPIKey {
                        Button("删除 Key", role: .destructive) {
                            settings.deleteAPIKey()
                            keyMessage = "已删除"
                        }
                    }
                    if let keyMessage {
                        Text(keyMessage).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("DeepSeek API Key")
                } footer: {
                    Text("Key 只保存在这台设备的钥匙串里，不会随 iCloud 同步，也不会显示出来。")
                }

                Section {
                    Picker("原文语言", selection: $settings.sourceLanguage) {
                        ForEach(SourceLanguage.allCases, id: \.self) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                    Toggle("把截图发给模型", isOn: $settings.sendImage)
                    Toggle("试运行（不调用 DeepSeek）", isOn: $settings.dryRun)
                } header: {
                    Text("翻译")
                } footer: {
                    Text("发送截图时，模型会对照画面核对原文，译文更准确。试运行只在原位置显示识别出的原文，用来检查识别效果，不联网。")
                }

                Section {
                    LabeledContent("翻译模型", value: DeepSeekPricing.pricedModel)
                    LabeledContent("版本", value: Bundle.main.versionText)
                } header: {
                    Text("关于")
                } footer: {
                    Text("点“翻译这一屏”时，当前屏幕的截图（带编号框）和识别出的文字会发送到 DeepSeek（api.deepseek.com）。")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
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

extension Bundle {
    var versionText: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version)（\(build)）"
    }
}
