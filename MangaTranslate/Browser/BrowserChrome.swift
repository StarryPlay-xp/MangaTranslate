import SwiftUI

/// 自动翻译开关：对话气泡的形状，开启时填品红。翻译进行中，气泡轮廓上有一圈白色虚线在流动
struct TranslateToggle: View {
    let isOn: Bool
    let isBusy: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let bubble = SpeechBubble(cornerRadius: 24, tailHeight: 12, tailWidth: 16, tailPosition: 0.28, tailLean: -0.8)

    var body: some View {
        Button(action: action) {
            ZStack {
                bubble.fill(isOn ? Theme.magenta : Color.white)
                bubble.stroke(Color.black, style: StrokeStyle(lineWidth: Theme.line, lineJoin: .round))
                if isBusy {
                    TimelineView(.animation(paused: reduceMotion)) { context in
                        let phase = context.date.timeIntervalSinceReferenceDate * 28
                        bubble.stroke(
                            Color.white,
                            style: StrokeStyle(
                                lineWidth: 3, lineCap: .round, lineJoin: .round, dash: [9, 15],
                                dashPhase: -CGFloat(phase.truncatingRemainder(dividingBy: 24))))
                    }
                }
                Text("译")
                    .font(.system(size: 24, weight: .black))
                    .foregroundStyle(isOn ? Color.white : Color.black)
                    .padding(.bottom, 12)
            }
            .frame(width: 64, height: 62)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("自动翻译")
        .accessibilityValue(isOn ? (isBusy ? "已开启，正在翻译" : "已开启") : "已关闭")
    }
}

/// 阅读页底部弹出的提示气泡，尖角指向下方的翻译开关；点一下就收起
struct MessageBubble: View {
    let message: BrowserMessage
    let onOpenSettings: () -> Void
    let onDismiss: () -> Void

    private let bubble = SpeechBubble(cornerRadius: 14, tailHeight: 9, tailWidth: 14, tailPosition: 0.5, tailLean: 0)

    var body: some View {
        HStack(spacing: 10) {
            switch message.kind {
            case .progress:
                ProgressView().tint(Theme.ink)
            case .error, .needsSettings:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.magenta)
            case .info:
                EmptyView()
            }
            Text(message.text)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            if message.kind == .needsSettings {
                Button("去设置", action: onOpenSettings)
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(Theme.magenta)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 11)
        .padding(.bottom, 20)
        .background(bubble.fill(Theme.paper))
        .overlay(bubble.stroke(Theme.ink, style: StrokeStyle(lineWidth: Theme.line, lineJoin: .round)))
        .padding(.horizontal, 28)
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
        .accessibilityAddTraits(.isStaticText)
    }
}
