import Foundation
import Testing
@testable import MangaCore

struct ReplyFormatTests {
    @Test func shorterFormatsDropSourceButKeepSharedRules() {
        let full = PageTranslator.systemPrompt(for: .full)
        #expect(full == PageTranslator.systemPrompt)
        #expect(full.contains(#""source": "核对后的原文""#))
        // 开头的规则相同，DeepSeek 等服务能缓存这一段
        let sharedPrefix = full.components(separatedBy: "\n7. ").first ?? ""
        for format in [ReplyFormat.noSource, .compact] {
            let prompt = PageTranslator.systemPrompt(for: format)
            #expect(prompt.hasPrefix(sharedPrefix))
            #expect(!prompt.contains("核对后的原文"))
            #expect(!prompt.contains("source 和 translation 都留空"))
            #expect(prompt.contains("json"))
        }
        #expect(PageTranslator.systemPrompt(for: .compact).contains(#"[1, "dialogue", "中文译文"]"#))
    }

    @Test func parsesCompactArrays() throws {
        let content = #"{"blocks": [[1, "dialogue", "你好"], ["2", "noise", ""], [3, "sfx"]], "new_terms": [["佐藤", "佐藤"]]}"#
        let output = try TranslationOutput.parse(content)
        #expect(output.blocks.map(\.id) == [1, 2, 3])
        #expect(output.blocks.map(\.kind) == ["dialogue", "noise", "sfx"])
        #expect(output.blocks.map(\.translation) == ["你好", "", ""])
        #expect(output.blocks.allSatisfy { $0.source.isEmpty })
        #expect(output.newTerms == [GlossaryTerm(source: "佐藤", translation: "佐藤")])
    }

    @Test func parsesObjectsWithoutSource() throws {
        let content = #"{"blocks": [{"id": 1, "translation": "走吧", "kind": "dialogue"}], "new_terms": []}"#
        let output = try TranslationOutput.parse(content)
        #expect(output.blocks.first?.translation == "走吧")
        #expect(output.blocks.first?.source == "")
    }

    @Test func glossaryStillSavesAsObjects() throws {
        var memory = TranslationMemory()
        memory.glossary = [GlossaryTerm(source: "佐藤", translation: "佐藤")]
        let data = try JSONEncoder().encode(memory)
        #expect(String(decoding: data, as: UTF8.self).contains(#""source":"佐藤""#))
        #expect(try JSONDecoder().decode(TranslationMemory.self, from: data).glossary == memory.glossary)
    }
}
