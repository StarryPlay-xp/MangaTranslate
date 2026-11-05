import SwiftUI

/// 设置页的一个区块：标题 + 分镜格 + 下方的小字说明
struct SettingsSection<Content: View>: View {
    let title: String
    var note: String?
    @ViewBuilder let content: Content

    init(_ title: String, note: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.note = note
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.sectionTitle)
                .foregroundStyle(Theme.ink)
            VStack(alignment: .leading, spacing: 0) { content }
                .panel()
            if let note {
                Text(note)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 分镜格里的细墨线分隔
struct InkDivider: View {
    var body: some View {
        Rectangle().fill(Theme.ink).frame(height: Theme.thinLine)
    }
}

/// 带标题和说明的开关
struct SettingsToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
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
}

/// 一行"标题 + 内容"的格子，内容一般是输入框或分段选择
struct SettingsField<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 16, weight: .heavy))
                .foregroundStyle(Theme.ink)
            content
        }
        .padding(14)
    }
}

extension View {
    /// 方角细墨线输入框
    func inkTextField() -> some View {
        font(.system(size: 16, weight: .medium))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.horizontal, 12)
            .frame(height: 44)
            .overlay(Rectangle().strokeBorder(Theme.ink, lineWidth: Theme.thinLine))
    }
}
