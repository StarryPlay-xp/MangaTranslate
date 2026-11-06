import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import HelperCore
@testable import MangaCore

struct NativeMessagingTests {
    @Test func 分帧_长度在前_一次读到多条和半条都能正确拆开() {
        let first = Data(#"{"type":"hello","id":1}"#.utf8)
        let second = Data(#"{"type":"usage","id":2}"#.utf8)
        var buffer = NativeMessaging.frame(first) + NativeMessaging.frame(second)
        let third = NativeMessaging.frame(Data(#"{"type":"x"}"#.utf8))
        buffer.append(third.prefix(6))

        let messages = NativeMessaging.takeMessages(from: &buffer)
        #expect(messages == [first, second])
        #expect(buffer.count == 6)

        buffer.append(third.dropFirst(6))
        #expect(NativeMessaging.takeMessages(from: &buffer) == [Data(#"{"type":"x"}"#.utf8)])
        #expect(buffer.isEmpty)
    }

    @Test func 长度是小端四字节() {
        let framed = NativeMessaging.frame(Data(count: 300))
        #expect(Array(framed.prefix(4)) == [44, 1, 0, 0])
    }
}

/// 读取小助手写出的消息，按条件等待
final class Collector: @unchecked Sendable {
    let pipe = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var messages: [[String: Any]] = []

    init() {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            lock.lock()
            buffer.append(data)
            for message in NativeMessaging.takeMessages(from: &buffer) {
                if let object = try? JSONSerialization.jsonObject(with: message) as? [String: Any] {
                    messages.append(object)
                }
            }
            lock.unlock()
        }
    }

    func next(timeout: Duration = .seconds(20), where match: @escaping ([String: Any]) -> Bool) async throws
        -> [String: Any]
    {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let message = take(where: match) { return message }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw MangaCoreError("等不到消息")
    }

    private func take(where match: ([String: Any]) -> Bool) -> [String: Any]? {
        lock.withLock {
            guard let index = messages.firstIndex(where: match) else { return nil }
            return messages.remove(at: index)
        }
    }

    func reply(_ id: Int) async throws -> [String: Any] {
        try await next { $0["type"] as? String == "reply" && $0["id"] as? Int == id }
    }

    func event(_ type: String, job: String) async throws -> [String: Any] {
        try await next { $0["type"] as? String == type && $0["job"] as? String == job }
    }
}

struct HelperTests {
    let home: URL
    let collector = Collector()
    let helper: Helper

    init() {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("manga-helper-test-" + UUID().uuidString, isDirectory: true)
        let paths = HelperPaths.standard(environment: ["MANGA_HELPER_HOME": home.path])
        helper = Helper(paths: paths, writer: MessageWriter(handle: collector.pipe.fileHandleForWriting))
    }

    private func send(_ object: [String: Any]) async throws {
        await helper.handle(try JSONSerialization.data(withJSONObject: object))
    }

    @Test func 第一次启动_只有DeepSeek_缺Key时不算就绪() async throws {
        try await send(["type": "hello", "id": 1])
        let reply = try await collector.reply(1)
        let result = try #require(reply["result"] as? [String: Any])
        let service = try #require(result["service"] as? [String: Any])
        #expect(service["name"] as? String == "DeepSeek")
        #expect(service["requiresKey"] as? Bool == true)
        #expect(result["ready"] as? Bool == false)
        #expect(result["imageLimit"] as? Int == 4)
    }

    @Test func 填了Key就就绪_Key只存在测试文件里_设置里没有Key() async throws {
        try await send(["type": "getSettings", "id": 1])
        let settings = try #require(try await collector.reply(1)["result"] as? [String: Any])
        let serviceID = try #require(settings["activeServiceID"] as? String)
        try await send(["type": "setKey", "id": 2, "serviceID": serviceID, "key": " sk-test \n"])
        _ = try await collector.reply(2)
        try await send(["type": "hello", "id": 3])
        let hello = try #require(try await collector.reply(3)["result"] as? [String: Any])
        #expect(hello["ready"] as? Bool == true)

        let settingsFile = try String(contentsOf: home.appendingPathComponent("support/settings.json"), encoding: .utf8)
        #expect(!settingsFile.contains("sk-test"))
        let keys = try String(contentsOf: home.appendingPathComponent("keys.json"), encoding: .utf8)
        #expect(keys.contains("sk-test") && !keys.contains(" sk-test"))
    }

    @Test func 保存局域网服务并设为当前_并发降为1_不需要Key() async throws {
        try await send([
            "type": "saveService", "id": 1, "activate": true,
            "service": ["name": "本机模型", "config": ["format": "openai", "baseURL": "http://127.0.0.1:8766", "model": "mock"]],
        ])
        let reply = try await collector.reply(1)
        #expect(reply["ok"] as? Bool == true)
        try await send(["type": "hello", "id": 2])
        let hello = try #require(try await collector.reply(2)["result"] as? [String: Any])
        #expect(hello["ready"] as? Bool == true)
        #expect(hello["imageLimit"] as? Int == 1)
        #expect((hello["service"] as? [String: Any])?["isLocal"] as? Bool == true)
    }

    @Test func 缺Key时翻译图片_报告停止并要求去设置() async throws {
        try await send([
            "type": "translateImage", "job": "j1", "image": try Self.blankPNG(), "src": "https://example.com/1.png",
            "isCanvas": false, "host": "example.com", "language": "japanese",
        ])
        let failed = try await collector.event("failed", job: "j1")
        #expect(failed["stopsAll"] as? Bool == true)
        #expect(failed["needsSettings"] as? Bool == true)
    }

    @Test func 试运行_没有字的图直接完成_不写缓存() async throws {
        try await send([
            "type": "translateImage", "job": "j2", "image": try Self.blankPNG(), "src": "https://example.com/2.png",
            "isCanvas": false, "host": "example.com", "language": "korean", "dryRun": true,
        ])
        _ = try await collector.event("working", job: "j2")
        let done = try await collector.event("done", job: "j2")
        #expect((done["items"] as? [Any])?.isEmpty == true)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("caches/Translations").path))
    }

    @Test func 用量查询_空账本全为零() async throws {
        try await send(["type": "usage", "id": 1])
        let result = try #require(try await collector.reply(1)["result"] as? [String: Any])
        let today = try #require(result["today"] as? [String: Any])
        #expect(today["requests"] as? Int == 0)
        #expect(result["activeHasPricing"] as? Bool == true)
    }

    @Test func 网页文字试运行_加括号_同样的文字只算一次() async throws {
        try await send([
            "type": "translateText", "id": 1, "texts": ["무료", "무료", "다음 화"], "host": "example.com",
            "language": "korean", "dryRun": true,
        ])
        let result = try #require(try await collector.reply(1)["result"] as? [String: Any])
        #expect(result["translations"] as? [String] == ["〔무료〕", "〔무료〕", "〔다음 화〕"])
    }

    @Test func 重新启动后服务编号不变_Key还能对上() async throws {
        try await send(["type": "getSettings", "id": 1])
        let first = try #require(try await collector.reply(1)["result"] as? [String: Any])
        let paths = HelperPaths.standard(environment: ["MANGA_HELPER_HOME": home.path])
        let restarted = Collector()
        let again = Helper(paths: paths, writer: MessageWriter(handle: restarted.pipe.fileHandleForWriting))
        await again.handle(try JSONSerialization.data(withJSONObject: ["type": "getSettings", "id": 2]))
        let second = try #require(try await restarted.reply(2)["result"] as? [String: Any])
        #expect(first["activeServiceID"] as? String == second["activeServiceID"] as? String)
    }

    @Test func 不认识的消息_回复错误() async throws {
        try await send(["type": "nope", "id": 9])
        let reply = try await collector.reply(9)
        #expect(reply["ok"] as? Bool == false)
    }

    static func blankPNG(width: Int = 400, height: Int = 300) throws -> String {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return (data as Data).base64EncodedString()
    }
}
