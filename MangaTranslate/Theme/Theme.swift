import SwiftUI
import UIKit

/// 漫画分镜风的设计规范：纸白底、墨黑粗线框、网点灰、印刷品红点缀。深色模式下纸和墨互换
enum Theme {
    static let ink = Color(light: 0x000000, dark: 0xF2F2F2)
    static let paper = Color(light: 0xFFFFFF, dark: 0x17171A)
    /// 网点灰：网点底纹和占位图
    static let tone = Color(light: 0xC8C8CE, dark: 0x3D3D44)
    static let muted = Color(light: 0x5C5C63, dark: 0xA3A3AB)
    static let magenta = Color("AccentColor")
    /// 硬投影：浅色用墨黑，深色用网点灰（黑影在深色背景上看不见）
    static let hardShadow = Color(light: 0x000000, dark: 0x4A4A52)
    /// 阅读页底部工具栏始终是黑色，夜里看也不刺眼
    static let bar = Color.black

    static let line: CGFloat = 2.5
    static let thinLine: CGFloat = 1.5
    /// 分镜格之间的间距
    static let gutter: CGFloat = 10
    static let pageMargin: CGFloat = 16
    /// 首页内容最宽多少：iPad 上不铺满整个屏幕，居中显示
    static let contentMaxWidth: CGFloat = 960
}

extension Font {
    static let mangaTitle = Font.system(size: 36, weight: .black)
    static let sectionTitle = Font.system(size: 21, weight: .heavy)
    static let panelTitle = Font.system(size: 16, weight: .heavy)
    static let panelCaption = Font.system(size: 12, weight: .medium)
}

extension Color {
    /// 深浅色自动切换的颜色。SwiftUI 可能在后台渲染线程上解析颜色，
    /// 所以这个闭包不能绑在主线程上（项目默认主线程隔离，不标 @Sendable 会被加上主线程检查而崩溃）
    nonisolated init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { @Sendable traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension UIColor {
    nonisolated convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }
}

// MARK: - 分镜格

/// 分镜格：方角、墨黑粗框；shadow 为 true 时加一层不模糊的硬投影，只给最重要的那一格用
struct PanelModifier: ViewModifier {
    var shadow = false

    func body(content: Content) -> some View {
        content
            .background(Theme.paper)
            .clipShape(Rectangle())
            .overlay(Rectangle().strokeBorder(Theme.ink, lineWidth: Theme.line))
            .background {
                if shadow {
                    Rectangle().fill(Theme.hardShadow).offset(x: 6, y: 6)
                }
            }
    }
}

extension View {
    func panel(shadow: Bool = false) -> some View {
        modifier(PanelModifier(shadow: shadow))
    }
}

// MARK: - 对话气泡

/// 对话气泡：圆角矩形，底边伸出一个尖角。整条外轮廓是一笔画成的，描边时尖角和气泡之间没有接缝
struct SpeechBubble: Shape {
    var cornerRadius: CGFloat = 18
    var tailHeight: CGFloat = 10
    var tailWidth: CGFloat = 14
    /// 尖角根部在底边的位置，0 是最左，1 是最右
    var tailPosition: CGFloat = 0.8
    /// 尖角向右偏多少（以尖角宽度为单位），负数向左
    var tailLean: CGFloat = 0.5

    func path(in rect: CGRect) -> Path {
        let body = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - tailHeight)
        let radius = min(cornerRadius, body.height / 2, body.width / 2)
        let center = body.minX + body.width * tailPosition
        let left = max(body.minX + radius, center - tailWidth / 2)
        let right = min(body.maxX - radius, center + tailWidth / 2)
        let tip = CGPoint(x: center + tailWidth * tailLean, y: rect.maxY)

        var path = Path()
        path.move(to: CGPoint(x: body.minX + radius, y: body.minY))
        path.addLine(to: CGPoint(x: body.maxX - radius, y: body.minY))
        path.addArc(
            tangent1End: CGPoint(x: body.maxX, y: body.minY),
            tangent2End: CGPoint(x: body.maxX, y: body.minY + radius), radius: radius)
        path.addLine(to: CGPoint(x: body.maxX, y: body.maxY - radius))
        path.addArc(
            tangent1End: CGPoint(x: body.maxX, y: body.maxY),
            tangent2End: CGPoint(x: body.maxX - radius, y: body.maxY), radius: radius)
        path.addLine(to: CGPoint(x: right, y: body.maxY))
        path.addLine(to: tip)
        path.addLine(to: CGPoint(x: left, y: body.maxY))
        path.addLine(to: CGPoint(x: body.minX + radius, y: body.maxY))
        path.addArc(
            tangent1End: CGPoint(x: body.minX, y: body.maxY),
            tangent2End: CGPoint(x: body.minX, y: body.maxY - radius), radius: radius)
        path.addLine(to: CGPoint(x: body.minX, y: body.minY + radius))
        path.addArc(
            tangent1End: CGPoint(x: body.minX, y: body.minY),
            tangent2End: CGPoint(x: body.minX + radius, y: body.minY), radius: radius)
        path.closeSubpath()
        return path
    }
}

// MARK: - 网点

/// 网点（screentone）：漫画里表现灰度的圆点阵，从左下角往右上角渐淡
struct Halftone: View {
    var spacing: CGFloat = 7
    var maxDot: CGFloat = 3.4
    var color: Color = Theme.tone

    var body: some View {
        // 绘制闭包也可能在后台渲染线程执行：先把参数拷成局部常量，闭包标 @Sendable，不绑在主线程上
        let spacing = spacing
        let maxDot = maxDot
        let color = color
        Canvas { @Sendable context, size in
            guard size.width > 0, size.height > 0 else { return }
            let rowStep = spacing * 0.866
            var row = 0
            var y: CGFloat = 0
            while y <= size.height + rowStep {
                var x: CGFloat = row.isMultiple(of: 2) ? 0 : spacing / 2
                while x <= size.width + spacing {
                    let fade = (x / size.width + (1 - y / size.height)) / 2
                    let diameter = maxDot * (1 - fade * 0.85)
                    if diameter > 0.4 {
                        let dot = CGRect(x: x - diameter / 2, y: y - diameter / 2, width: diameter, height: diameter)
                        context.fill(Path(ellipseIn: dot), with: .color(color))
                    }
                    x += spacing
                }
                y += rowStep
                row += 1
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - 按钮

/// 墨线按钮：prominent 时填品红；按下时往右下沉一点，像按进纸里
struct InkButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .heavy))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .foregroundStyle(prominent ? Color.white : Theme.ink)
            .background(prominent ? Theme.magenta : Theme.paper)
            .overlay(Rectangle().strokeBorder(Theme.ink, lineWidth: Theme.line))
            .offset(x: configuration.isPressed ? 2 : 0, y: configuration.isPressed ? 2 : 0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}
