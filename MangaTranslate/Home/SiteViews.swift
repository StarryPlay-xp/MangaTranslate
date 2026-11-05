import MangaCore
import SwiftUI

/// 首页的「漫画网站」：韩漫、日漫两组正版平台，左右滑动的两行小格子，点一下直接打开
struct SiteSection: View {
    let onOpen: (MangaSite) -> Void
    /// 上次看的是哪一组，下次打开首页还停在这一组
    @AppStorage("homeSiteLanguage") private var language: SourceLanguage = .japanese

    private let rows = [
        GridItem(.fixed(SiteTile.height), spacing: Theme.gutter),
        GridItem(.fixed(SiteTile.height), spacing: Theme.gutter),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                Text("漫画网站")
                    .font(.sectionTitle)
                    .foregroundStyle(Theme.ink)
                Spacer()
                InkSegment(selection: $language, options: [(.korean, "韩漫"), (.japanese, "日漫")])
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHGrid(rows: rows, spacing: Theme.gutter) {
                    ForEach(MangaSite.sites(for: language)) { site in
                        Button {
                            onOpen(site)
                        } label: {
                            SiteTile(site: site)
                        }
                        .buttonStyle(PanelButtonStyle())
                    }
                }
                // 留出按下时下沉的空间
                .padding(.vertical, 3)
                .padding(.trailing, 3)
            }
            // 横向滚动到屏幕边缘，内容和上下对齐
            .contentMargins(.horizontal, Theme.pageMargin, for: .scrollContent)
            .padding(.horizontal, -Theme.pageMargin)
            .id(language)
            Text("均为正版平台。免费章节、付费、年龄验证和地区限制以各网站为准")
                .font(.panelCaption)
                .foregroundStyle(Theme.muted)
        }
    }
}

/// 一个网站：名字、原名、主要类型
struct SiteTile: View {
    static let height: CGFloat = 78
    let site: MangaSite

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(site.name)
                .font(.system(size: 15, weight: .heavy))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if let nativeName = site.nativeName {
                Text(nativeName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.ink.opacity(0.75))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
            Text(site.tags.joined(separator: " · "))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(width: 156, height: Self.height, alignment: .topLeading)
        .panel()
        .accessibilityElement(children: .combine)
        .accessibilityHint("打开网站")
    }
}

/// 墨线分段按钮：选中的一格填墨黑
struct InkSegment<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                let selected = option.0 == selection
                if index > 0 {
                    Rectangle().fill(Theme.ink).frame(width: Theme.line)
                }
                Button {
                    selection = option.0
                } label: {
                    Text(option.1)
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundStyle(selected ? Theme.paper : Theme.ink)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .background(selected ? Theme.ink : Theme.paper)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .fixedSize()
        .overlay(Rectangle().strokeBorder(Theme.ink, lineWidth: Theme.line))
        .sensoryFeedback(.selection, trigger: selection)
    }
}
