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

    @Test func 拟声词标题和特别大的字用小标签显示() {
        #expect(block(kind: "sfx").showsAsLabel(imageWidth: 1000, fallbackCharacterSize: 30))
        #expect(block(kind: "title").showsAsLabel(imageWidth: 1000, fallbackCharacterSize: 30))
        // 普通对白盖住原文
        #expect(!block(kind: "dialogue", characterSize: 30).showsAsLabel(imageWidth: 1000, fallbackCharacterSize: 30))
        // 字号达到图片宽度的 7% 就算排版大字
        #expect(block(kind: "narration", characterSize: 70).showsAsLabel(imageWidth: 1000, fallbackCharacterSize: 30))
        #expect(!block(kind: "narration", characterSize: 69).showsAsLabel(imageWidth: 1000, fallbackCharacterSize: 30))
        // 没有自己的字号估计时用整页字号
        #expect(block(kind: "dialogue", characterSize: nil).showsAsLabel(imageWidth: 1000, fallbackCharacterSize: 80))
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
