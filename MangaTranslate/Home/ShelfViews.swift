import SwiftUI

/// 页面封面：有缩略图时显示缩略图（从顶部裁切），没有时显示网点和网站首字母。
/// 用透明底色确定大小，图片叠在上面再按底色裁切，图片再大也不会撑开格子
struct PageCover: View {
    let url: URL?

    var body: some View {
        Color.clear
            .overlay(alignment: .top) {
                if let url, let image = ThumbnailStore.image(for: url) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        Theme.paper
                        Halftone()
                        Text(initial)
                            .font(.system(size: 40, weight: .black))
                            .foregroundStyle(Theme.ink)
                    }
                }
            }
            .clipped()
            .accessibilityHidden(true)
    }

    private var initial: String {
        let host = url?.host()?.replacingOccurrences(of: "www.", with: "") ?? ""
        return host.first.map { String($0).uppercased() } ?? "漫"
    }
}

/// 书架上的一格：上面是封面，墨线隔开，下面是标题和网站
struct ShelfPanel: View {
    let bookmark: Bookmark

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageCover(url: bookmark.url)
            Rectangle().fill(Theme.ink).frame(height: Theme.line)
            VStack(alignment: .leading, spacing: 3) {
                Text(bookmark.title)
                    .font(.panelTitle)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(bookmark.url.host() ?? bookmark.url.absoluteString)
                    .font(.panelCaption)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 68, alignment: .topLeading)
        }
        .panel()
    }
}

/// 一行几格，宽度按比例分；书架隔行换宽格的位置，排出漫画分镜那种错落感。
/// 这一行不满时，按已有几格的比例分满整行（只剩一格就占满）
struct PanelRow: Layout {
    var fractions: [CGFloat]
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        let column = width / CGFloat(max(subviews.count, 1))
        let height = proposal.height ?? subviews.map { $0.sizeThatFits(.init(width: column, height: nil)).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let shares = (0..<subviews.count).map { $0 < fractions.count ? fractions[$0] : (fractions.last ?? 1) }
        let total = shares.reduce(0, +)
        let available = bounds.width - spacing * CGFloat(subviews.count - 1)
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() {
            // 最后一格补齐取整误差，右边缘和上下对齐
            let width = index == subviews.count - 1
                ? bounds.maxX - x
                : (available * shares[index] / total).rounded()
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: .init(width: width, height: bounds.height))
            x += width + spacing
        }
    }
}

/// 分镜格按下时往右下沉一点
struct PanelButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .offset(x: configuration.isPressed ? 3 : 0, y: configuration.isPressed ? 3 : 0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// 墨线方框图标按钮，用在首页右上角的设置
struct InkIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Theme.ink)
            .frame(width: 42, height: 42)
            .background(configuration.isPressed ? Theme.tone : Theme.paper)
            .overlay(Rectangle().strokeBorder(Theme.ink, lineWidth: Theme.line))
    }
}
