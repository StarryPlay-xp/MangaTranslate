import CoreGraphics
import Foundation
import Testing
@testable import MangaCore

struct OverlayKindTests {
    private func block(kind: String, translation: String = "译文", characterSize: Int? = 30) -> TranslatedBlock {
        let source = TextBlock(
            id: 1, box: Box(CGRect(x: 0, y: 0, width: 200, height: 80)), direction: .horizontal,
            text: "原文", confidence: 1, lines: [])
        var block = TranslatedBlock(untranslated: source)
        block.kind = kind
        block.translation = translation
        block.characterSize = characterSize
        return block
    }

    @Test func 拟声词和标题也贴译文_非剧情文字和空译文不贴() {
        #expect(block(kind: "dialogue").shouldOverlay)
        #expect(block(kind: "narration").shouldOverlay)
        #expect(block(kind: "sfx").shouldOverlay)
        #expect(block(kind: "title").shouldOverlay)
        #expect(!block(kind: "noise").shouldOverlay)
        #expect(!block(kind: "missing").shouldOverlay)
        // 标题和中文写法一样（汉字人名）时模型会留空
        #expect(!block(kind: "title", translation: "").shouldOverlay)
    }

    @Test func 只有拟声词和标题用小标签_字再大的对白也盖住气泡() {
        #expect(block(kind: "sfx").showsAsLabel)
        #expect(block(kind: "title").showsAsLabel)
        #expect(!block(kind: "dialogue", characterSize: 30).showsAsLabel)
        // 条漫里喊出来的台词，字号有图片宽度的 7% 以上
        #expect(!block(kind: "dialogue", characterSize: 80).showsAsLabel)
        #expect(!block(kind: "narration", characterSize: 120).showsAsLabel)
    }

    @Test func 前文只记对白和旁白() {
        var memory = TranslationMemory()
        let page = PageTranslation(
            blocks: [block(kind: "dialogue", translation: "你好"), block(kind: "sfx", translation: "咚"),
                     block(kind: "title", translation: "第1话")],
            newTerms: [], usage: .zero, attempts: 1)
        memory.record(page)
        #expect(memory.recentLines == ["你好"])
    }

    @Test func 提示词里有标题类型() {
        #expect(PageTranslator.systemPrompt.contains(#"kind 填 "title""#))
    }
}
