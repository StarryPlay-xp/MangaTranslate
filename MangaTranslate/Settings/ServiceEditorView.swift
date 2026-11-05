import MangaCore
import SwiftUI

/// 新增或编辑一个模型服务。改动点右上角"保存"后才生效，粘贴的 Key 也是那时才写进钥匙串
struct ServiceEditorView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    let isNew: Bool
    @State private var draft: ModelService
    @State private var keyInput = ""
    @State private var keyMessage: String?
    @State private var test: ConnectionTest = .idle
    @State private var confirmingDelete = false

    private enum ConnectionTest: Equatable {
        case idle
        case running
        case succeeded(String)
        case failed(String)
    }

    private static let timeoutOptions: [(Double, String)] = [
        (60, "1 分钟"), (180, "3 分钟"), (300, "5 分钟"), (600, "10 分钟"),
    ]

    init(service: ModelService, isNew: Bool) {
        _draft = State(initialValue: service)
        self.isNew = isNew
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    basicsSection
                    addressSection
                    keySection.id("key")
                    capabilitySection.id("capability")
                    testSection.id("test")
                    if !isNew { deleteSection }
                }
                .padding(Theme.pageMargin)
                .padding(.bottom, 24)
            }
            #if DEBUG
            .onAppear {
                // 调试用：-debugScrollTo key|capability|test 打开后滚到对应区块，方便截图
                if let anchor = UserDefaults.standard.string(forKey: "debugScrollTo") {
                    Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        proxy.scrollTo(anchor, anchor: .top)
                    }
                }
            }
            #endif
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.paper)
        .navigationTitle(isNew ? "添加模型服务" : "编辑模型服务")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存", action: save)
                    .fontWeight(.heavy)
                    .disabled(validationError != nil)
            }
        }
        .confirmationDialog("删除「\(draft.name)」？", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                settings.deleteService(draft.id)
                dismiss()
            }
        } message: {
            Text("它的 API Key 也会从钥匙串里删除。")
        }
        #if DEBUG
        .onAppear {
            // 调试用：-runConnectionTest 打开编辑页后自动测试一次连接
            if ProcessInfo.processInfo.arguments.contains("-runConnectionTest"), test == .idle { runTest() }
        }
        #endif
    }

    // MARK: - 名称和格式

    private var basicsSection: some View {
        SettingsSection(
            "名称和格式",
            note: "DeepSeek、Ollama、LM Studio、vLLM 等大多数服务都用 OpenAI 兼容格式；Claude 和兼容 Anthropic 的服务选 Anthropic。"
        ) {
            SettingsField("名称") {
                TextField("例如：家里电脑上的 Qwen", text: $draft.name)
                    .inkTextField()
            }
            InkDivider()
            SettingsField("接口格式") {
                InkSegmented(
                    selection: $draft.config.format,
                    options: LLMAPIFormat.allCases.map { ($0, $0.displayName) })
            }
        }
    }

    // MARK: - 地址和模型

    private var addressSection: some View {
        SettingsSection("地址和模型", note: addressNote) {
            SettingsField("请求地址") {
                TextField(addressPlaceholder, text: $draft.config.baseURL)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .inkTextField()
            }
            InkDivider()
            SettingsField("模型名") {
                TextField("例如 deepseek-flash、qwen2.5vl:7b", text: $draft.config.model)
                    .inkTextField()
            }
            InkDivider()
            VStack(alignment: .leading, spacing: 6) {
                Text("完整请求地址")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(Theme.muted)
                switch endpointResult {
                case .success(let url):
                    Text(url.absoluteString)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .failure(let error):
                    Text(error.localizedDescription)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.magenta)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
        }
    }

    private var addressPlaceholder: String {
        draft.config.format == .anthropic ? "https://api.anthropic.com" : "https://api.deepseek.com"
    }

    private var addressNote: String {
        var lines: [String] = []
        if case .success(let url) = endpointResult {
            let local = LLMEndpoint.isLocalHost(url.host() ?? "")
            if url.scheme == "http" && !local {
                lines.append("只有局域网地址可以用 http://，其他地址请改用 https://，否则系统会拦下请求。")
            }
            if local {
                lines.append("局域网服务一次只翻译一张图。手机和电脑要连同一个 Wi-Fi，服务要允许局域网访问（例如 Ollama 要设置 OLLAMA_HOST=0.0.0.0）；第一次连接时系统会询问是否允许漫译访问本地网络。")
            }
        }
        if lines.isEmpty {
            lines.append("带不带 /v1、结尾有没有斜杠都可以，App 会补全，上面显示的就是实际发送的地址。本地服务示例：Ollama http://电脑IP:11434，LM Studio http://电脑IP:1234，vLLM http://电脑IP:8000。")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - API Key

    private var keySection: some View {
        let hasKey = settings.hasAPIKey(for: draft.id)
        let note = (draft.requiresAPIKey
            ? "这个服务需要 API Key。"
            : "局域网里的本地服务一般不需要 Key，可以留空。")
            + "粘贴后点右上角“保存”才会写进这台设备的钥匙串，不会显示出来。"
        return SettingsSection("API Key", note: note) {
            HStack(spacing: 10) {
                Image(systemName: hasKey ? "checkmark.seal.fill" : "key")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(hasKey ? Theme.magenta : Theme.muted)
                Text(hasKey ? "已保存" : "还没有填写")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(Theme.ink)
                Spacer()
                if hasKey {
                    Button("删除", role: .destructive) {
                        settings.deleteAPIKey(for: draft.id)
                        keyMessage = "已删除"
                    }
                    .font(.system(size: 15, weight: .heavy))
                }
            }
            .padding(14)
            InkDivider()
            VStack(alignment: .leading, spacing: 10) {
                SecureField(hasKey ? "粘贴新的 Key 可替换旧的" : "粘贴 API Key", text: $keyInput)
                    .inkTextField()
                if let keyMessage {
                    Text(keyMessage)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                }
            }
            .padding(14)
        }
    }

    // MARK: - 能力

    private var capabilitySection: some View {
        SettingsSection("能力", note: capabilityNote) {
            SettingsToggleRow(
                title: "支持看图",
                detail: "开着时会把带编号框的图片一起发过去；模型不能看图就关掉，只发识别出的文字",
                isOn: $draft.config.supportsImages)
            if draft.config.format == .openAICompatible {
                InkDivider()
                SettingsToggleRow(
                    title: "JSON 模式",
                    detail: "要求模型只输出 json。有的模型不支持会报错，关掉后 App 也能从普通回复里提取 json",
                    isOn: $draft.config.jsonMode)
            }
            InkDivider()
            SettingsField("最长等待") {
                InkSegmented(selection: $draft.config.timeoutSeconds, options: Self.timeoutOptions)
            }
        }
    }

    private var capabilityNote: String {
        var lines = ["本地小模型翻一页可能要一两分钟，等待时间可以设长一些。"]
        if draft.config.format == .anthropic {
            lines.append("Anthropic 格式靠提示词要求输出 json，不需要 JSON 模式。")
        }
        if let preset = trimmedConfig.preset {
            let price = trimmedConfig.pricing == nil
                ? "这个模型没有价格数据，只显示 token 数" : "会按 \(trimmedConfig.model) 的官方价格估算费用"
            lines.append("已识别为 \(preset.name)：会发送关闭思考的专用参数，\(price)。")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 测试连接

    private var testSection: some View {
        SettingsSection("测试连接", note: "只发一条很短的文字请求（不发图片），确认地址、模型和 Key 都能用，会用掉少量 token。") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Button(test == .running ? "测试中…" : "测试连接", action: runTest)
                        .buttonStyle(InkButtonStyle(prominent: true))
                        .disabled(test == .running || validationError != nil)
                        .opacity(validationError != nil ? 0.45 : 1)
                    if test == .running {
                        ProgressView().tint(Theme.ink)
                    }
                    Spacer()
                }
                switch test {
                case .succeeded(let message): testResult(message, ok: true)
                case .failed(let message): testResult(message, ok: false)
                case .idle, .running: EmptyView()
                }
            }
            .padding(14)
        }
    }

    private func testResult(_ message: String, ok: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(ok ? Theme.magenta : Theme.ink)
            Text(message)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - 删除

    private var deleteSection: some View {
        let canDelete = settings.services.count > 1
        return VStack(alignment: .leading, spacing: 10) {
            Button(role: .destructive) {
                confirmingDelete = true
            } label: {
                Text("删除这个模型服务")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(canDelete ? Color.red : Theme.muted)
                    .frame(maxWidth: .infinity)
                    .padding(14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .panel()
            .disabled(!canDelete)
            if !canDelete {
                Text("至少要保留一个模型服务。")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
            }
        }
    }

    // MARK: - 动作

    /// 去掉首尾空格后的连接参数
    private var trimmedConfig: LLMServiceConfig {
        var config = draft.config
        config.baseURL = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        config.model = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        return config
    }

    private var endpointResult: Result<URL, Error> {
        Result { try trimmedConfig.endpoint() }
    }

    private var validationError: String? {
        if case .failure(let error) = endpointResult { return error.localizedDescription }
        if trimmedConfig.model.isEmpty { return "还没有填写模型名" }
        return nil
    }

    private func save() {
        guard validationError == nil else { return }
        var service = draft
        service.config = trimmedConfig
        service.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if service.name.isEmpty {
            service.name = (try? trimmedConfig.endpoint().host()) ?? trimmedConfig.format.displayName
        }
        let typedKey = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typedKey.isEmpty {
            do {
                try settings.saveAPIKey(typedKey, for: service.id)
            } catch {
                keyMessage = error.localizedDescription
                return
            }
        }
        settings.saveService(service)
        dismiss()
    }

    private func runTest() {
        let config = trimmedConfig
        let typedKey = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = typedKey.isEmpty ? settings.apiKey(for: draft.id) : typedKey
        test = .running
        Task {
            let started = ContinuousClock.now
            do {
                let reply = try await config.makeClient(apiKey: key).ping()
                let seconds = (ContinuousClock.now - started) / .seconds(1)
                test = .succeeded(Self.describe(reply, seconds: seconds, pricing: config.pricing))
            } catch {
                test = .failed(error.localizedDescription)
            }
        }
    }

    private static func describe(_ reply: LLMReply, seconds: Double, pricing: LLMPricing?) -> String {
        var text = seconds < 0.1 ? "连接成功，用时不到 0.1 秒。" : String(format: "连接成功，用时 %.1f 秒。", seconds)
        let content = LLMJSON.stripThinking(reply.content).trimmingCharacters(in: .whitespacesAndNewlines)
        if content.isEmpty {
            text += "不过模型没有回复文字，可能只输出了思考过程。"
        } else {
            text += "模型回复：" + (content.count > 80 ? content.prefix(80) + "…" : content)
            if !LLMJSON.containsJSON(content) {
                text += "\n注意：回复里没有 json，翻译时可能解析失败。"
            }
        }
        if let usage = reply.usage {
            text += "\n输入 \(usage.inputTokens) / 输出 \(usage.outputTokens) token"
            if let pricing {
                text += String(format: "，约 $%.6f", pricing.cost(of: usage, peak: pricing.isPeak(Date())))
            }
        }
        return text
    }
}
