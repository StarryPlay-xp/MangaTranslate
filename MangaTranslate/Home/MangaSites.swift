import Foundation
import MangaCore

/// 首页「漫画网站」里的正版平台入口。名单来自用户整理的《韩漫与日漫正版网站汇总》（2026-11-05），
/// 免费章节、付费、年龄验证和地区限制以各平台为准
struct MangaSite: Identifiable, Hashable {
    enum Category {
        case korean
        /// 出版社官方漫画平台
        case japanesePublisher
        /// 综合漫画和电子书平台
        case japaneseStore
    }

    /// 常用的英文或拉丁字母名
    let name: String
    /// 韩文、日文原名；和 name 一样时为 nil
    let nativeName: String?
    let url: URL
    /// 主要类型和特点
    let tags: [String]
    let category: Category

    var id: URL { url }

    /// 打开这个网站时把原文语言切到对应的语言
    var language: SourceLanguage { category == .korean ? .korean : .japanese }

    private init(_ name: String, _ nativeName: String?, _ address: StaticString, _ tags: [String], _ category: Category) {
        self.name = name
        self.nativeName = nativeName
        // 都是写死的合法网址
        self.url = URL(string: "\(address)")!
        self.tags = tags
        self.category = category
    }

    static func sites(for language: SourceLanguage) -> [MangaSite] {
        language == .korean ? korean : japanesePublishers + japaneseStores
    }

    static let korean: [MangaSite] = [
        MangaSite("NAVER WEBTOON", "네이버웹툰", "https://comic.naver.com", ["综合", "热血", "奇幻", "校园", "恋爱"], .korean),
        MangaSite("KakaoPage", "카카오페이지", "https://page.kakao.com", ["奇幻", "恋爱", "穿越", "小说改编"], .korean),
        MangaSite("Kakao Webtoon", "카카오웹툰", "https://webtoon.kakao.com", ["综合", "原创", "剧情", "恋爱"], .korean),
        MangaSite("Lezhin Comics", "레진코믹스", "https://www.lezhin.com/ko", ["恋爱", "BL", "剧情", "成人向"], .korean),
        MangaSite("RIDI", "리디", "https://ridibooks.com", ["恋爱", "BL", "奇幻", "漫画", "小说"], .korean),
        MangaSite("Bomtoon", "봄툰", "https://www.bomtoon.com", ["女性向", "BL", "浪漫爱情"], .korean),
        MangaSite("Toptoon", "탑툰", "https://toptoon.com", ["成人向", "恋爱", "都市", "动作"], .korean),
        MangaSite("Toomics", "투믹스", "https://toomics.com/kr", ["成人向", "恋爱", "奇幻", "动作"], .korean),
        MangaSite("MrBlue", "미스터블루", "https://www.mrblue.com", ["武侠", "动作", "奇幻", "BL"], .korean),
        MangaSite("NAVER Series", "네이버 시리즈", "https://series.naver.com", ["漫画", "网络小说", "电子书"], .korean),
    ]

    static let japanesePublishers: [MangaSite] = [
        MangaSite("少年 Jump+", "少年ジャンプ＋", "https://shonenjumpplus.com", ["少年", "热血", "冒险", "恋爱"], .japanesePublisher),
        MangaSite("Magazine Pocket", "マガポケ", "https://pocket.shonenmagazine.com", ["少年", "校园", "恋爱", "奇幻"], .japanesePublisher),
        MangaSite("Sunday Webry", "サンデーうぇぶり", "https://www.sunday-webry.com", ["少年", "推理", "奇幻", "喜剧"], .japanesePublisher),
        MangaSite("Manga One", "マンガワン", "https://manga-one.com", ["青年", "动作", "恋爱"], .japanesePublisher),
        MangaSite("Comic DAYS", "コミックDAYS", "https://comic-days.com", ["青年", "恋爱", "悬疑", "日常"], .japanesePublisher),
        MangaSite("Tonari no Young Jump", "となりのヤングジャンプ", "https://tonarinoyj.jp", ["青年", "动作", "奇幻"], .japanesePublisher),
        MangaSite("KADOCOMI", "カドコミ", "https://comic-walker.com", ["异世界", "轻小说改编", "恋爱"], .japanesePublisher),
        MangaSite("Pixiv Comic", "pixivコミック", "https://comic.pixiv.net", ["原创", "恋爱", "BL", "日常"], .japanesePublisher),
    ]

    static let japaneseStores: [MangaSite] = [
        MangaSite("Comic Cmoa", "コミックシーモア", "https://www.cmoa.jp", ["综合漫画", "BL", "TL", "青年漫画"], .japaneseStore),
        MangaSite("ebookjapan", nil, "https://ebookjapan.yahoo.co.jp", ["综合日漫电子书", "网页试读"], .japaneseStore),
        MangaSite("BookLive", nil, "https://booklive.jp", ["综合漫画", "小说", "电子书"], .japaneseStore),
        MangaSite("BOOK☆WALKER", nil, "https://bookwalker.jp", ["漫画", "轻小说", "异世界"], .japaneseStore),
        MangaSite("Renta!", nil, "https://renta.papy.co.jp", ["按话购买", "租阅", "BL", "TL"], .japaneseStore),
        MangaSite("Mecha Comic", "めちゃコミック", "https://mechacomic.jp", ["恋爱", "女性向", "青年", "成人向"], .japaneseStore),
        MangaSite("DMM Books", nil, "https://book.dmm.com", ["综合漫画", "轻小说", "成人向"], .japaneseStore),
        MangaSite("Piccoma", "ピッコマ", "https://piccoma.com/web/", ["日漫", "韩漫", "纵向彩漫"], .japaneseStore),
    ]
}
