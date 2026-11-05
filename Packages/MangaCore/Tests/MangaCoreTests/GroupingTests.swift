import CoreGraphics
import Foundation
import Testing
@testable import MangaCore

struct GroupingTests {
    private func line(_ text: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> TextLine {
        TextLine(text: text, confidence: 1, box: Box(CGRect(x: x, y: y, width: width, height: height)))
    }

    private func blocks(_ lines: [TextLine], regions: [CGRect] = [], page: CGFloat = 30) -> [TextBlock] {
        let analysis = TextAnalysis(lines: lines, regions: regions, characterSize: page)
        return groupIntoBlocks(analysis, gapFactor: 0.6, order: .rightToLeft)
    }

    @Test func 同一个气泡里的几行合成一块() {
        // 横排三行，字高 30，行距 8
        let result = blocks([
            line("이번 주", 100, 100, 200, 30), line("인기 웹툰", 100, 138, 240, 30), line("업데이트", 100, 176, 210, 30),
        ])
        #expect(result.count == 1)
        #expect(result.first?.text == "이번 주\n인기 웹툰\n업데이트")
    }

    @Test func 竖排气泡的几列合成一块() {
        let result = blocks([line("おうじさまが", 300, 100, 30, 180), line("ひざまづくと", 262, 100, 30, 180)])
        #expect(result.count == 1)
        #expect(result.first?.direction == .vertical)
    }

    @Test func 大字竖排标题和旁边的小字旁白分开() {
        // 按第 1 话第一页的实测尺寸：竖排标题列宽 99（含注音）、11 个字；旁白列宽 19，两者只隔 12 像素
        let result = blocks([
            line("運命の人に憧れる少女は", 24, 101, 99, 650),
            line("おうじさまこそ", 135, 135, 19, 108), line("おうじょの", 159, 135, 19, 77),
        ], page: 14)
        #expect(result.count == 2)
        #expect(result.map(\.text).contains("運命の人に憧れる少女は"))
    }

    @Test func 横排大标题和竖排小字分开() {
        // 『龍と苺』の柳本光晴、帰還!! 下面紧挨着竖排的 うんめいの…
        let result = blocks([
            line("『龍と苺』の柳本光晴、", 40, 40, 700, 70), line("帰還!!", 300, 120, 260, 80),
            line("うんめいの…", 60, 124, 34, 220),
        ])
        #expect(result.count == 2)
        #expect(result.contains { $0.text == "うんめいの…" && $0.direction == .vertical })
    }

    @Test func 注音并进旁边的大字_不会串起别的块() {
        // 标题字宽 60；注音字宽 22、只有两个字，贴在标题右边；再往右隔 10 像素是另一段小字旁白
        let title = line("運命の人", 40, 100, 60, 240)
        let ruby = line("うん", 102, 100, 22, 44)
        let narration = line("おうじさまこそ", 134, 100, 26, 200)
        let result = blocks([title, ruby, narration])
        #expect(result.count == 2)
        #expect(result.contains { $0.lines.count == 2 && $0.text.contains("運命の人") })
        #expect(result.contains { $0.text == "おうじさまこそ" })
    }

    @Test func 大面积重叠的检测框不管字号都合并() {
        // 检测到的文字区域包住整个气泡，比一行宽很多
        let result = blocks(
            [line("いつか", 100, 100, 30, 90), line("ありすも…", 64, 100, 30, 140)],
            regions: [CGRect(x: 60, y: 96, width: 74, height: 150)])
        #expect(result.count == 1)
    }

    @Test func 紧挨着的两行大字标题合成一块() {
        let result = blocks([line("『龍と苺』の柳本光晴、", 10, 30, 730, 95), line("帰還!!", 340, 128, 270, 110)], page: 30)
        #expect(result.count == 1)
    }
}

extension GroupingTests {
    @Test func 横着的注音并进竖排标题后_标题仍是竖排_不会和横排标志合并() {
        // 横排标志紧贴在竖排标题上方；标题旁边有一个横着的小注音框
        let result = blocks([
            line("Honey Creep", 26, 14, 382, 84), line("運命の人に憧れる少女は", 24, 101, 99, 650),
            line("ひと", 93, 643, 34, 13),
        ], page: 14)
        #expect(result.count == 2)
        #expect(result.contains { $0.text == "Honey Creep" })
    }

    @Test func 紧挨着大号拟声词的短对白不当成注音() {
        // どんっ 字高 75；きゃっ。字宽 33，比正文大、也不和拟声词并排
        let result = blocks([line("どんっ", 496, 768, 156, 75), line("きゃっ。", 462, 793, 33, 75)], page: 14)
        #expect(result.count == 2)
    }
}

extension GroupingTests {
    @Test func 带注音的列和旁边没注音的列仍是同一个气泡() {
        // 「運命が待っている！」旁边带注音，列宽 31；「闇をさまよう」列宽 17：按列长 ÷ 字数算字号都约 18
        let result = blocks([line("闇をさまよう", 142, 89, 17, 111), line("運命が待っている！", 111, 89, 31, 169)], page: 16)
        #expect(result.count == 1)
    }
}

extension GroupingTests {
    @Test func 单独识别出的长注音并进旁边的字() {
        // 「愛嬌愛嬌！」旁边整列注音被认成了单独一行
        let result = blocks([line("愛嬌愛嬌！", 667, 891, 24, 104), line("あいきょうあいきよう", 688, 891, 12, 82)], page: 15)
        #expect(result.count == 1)
    }
}

extension GroupingTests {
    @Test func 压在大字标志上的章节标签不合并() {
        // 「第1話 運命の相手」的红色标签压在花体标志「Creep」下半部分上
        let result = blocks([line("Creep", 300, 120, 700, 220), line("第1話運命の相手", 180, 300, 470, 66)], page: 30)
        #expect(result.count == 2)
    }
}

extension GroupingTests {
    @Test func 竖排小字在横排大字上方不算注音() {
        // 说明框「1997年」「11月」在倾斜的校门牌上方；门牌框很高，看不出方向
        let result = blocks([
            line("1997年", 303, 951, 19, 94), line("11月", 274, 951, 19, 39),
            line("成野市立城北中学校", 87, 1045, 340, 105),
        ], page: 33)
        #expect(result.count == 2)
        #expect(result.contains { $0.text == "1997年\n11月" })
    }
}

