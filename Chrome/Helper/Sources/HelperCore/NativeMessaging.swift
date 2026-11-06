import Foundation

/// Chrome Native Messaging 的消息格式：每条消息是 4 字节长度（本机字节序，Mac 上是小端）+ UTF-8 JSON。
/// Chrome 通过标准输入发消息过来，小助手往标准输出写回复；标准输出只能写消息，日志一律写标准错误
public enum NativeMessaging {
    /// 小助手发给 Chrome 的单条消息上限是 1 MB，超过时 Chrome 会断开连接
    public static let maxOutgoingBytes = 1024 * 1024

    public static func frame(_ payload: Data) -> Data {
        var length = UInt32(payload.count).littleEndian
        var data = Data(bytes: &length, count: 4)
        data.append(payload)
        return data
    }

    /// 从缓冲区里取出所有完整的消息，剩下不完整的部分留在缓冲区
    public static func takeMessages(from buffer: inout Data) -> [Data] {
        var messages: [Data] = []
        while buffer.count >= 4 {
            let start = buffer.startIndex
            let length = buffer[start..<start + 4].enumerated().reduce(0) { total, pair in
                total | Int(pair.element) << (8 * pair.offset)
            }
            guard buffer.count >= 4 + length else { break }
            messages.append(Data(buffer[start + 4..<start + 4 + length]))
            buffer.removeSubrange(start..<start + 4 + length)
        }
        return messages
    }
}

/// 往标准输出写消息。多个任务同时回复时按顺序写，不会交错
public final class MessageWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle

    public init(handle: FileHandle = .standardOutput) {
        self.handle = handle
    }

    public func send(_ object: some Encodable) {
        guard let payload = try? JSONEncoder().encode(object) else { return }
        guard payload.count <= NativeMessaging.maxOutgoingBytes else {
            HelperLog.write("回复太大（\(payload.count) 字节），没有发送")
            return
        }
        lock.lock()
        defer { lock.unlock() }
        handle.write(NativeMessaging.frame(payload))
    }
}

/// 在单独的线程里读标准输入，每收到一条完整消息就回调；Chrome 断开（读到结尾）时调用 onEnd
public enum MessageReader {
    public static func start(onMessage: @escaping @Sendable (Data) -> Void, onEnd: @escaping @Sendable () -> Void) {
        let thread = Thread {
            var buffer = Data()
            let chunkSize = 1 << 16
            var chunk = [UInt8](repeating: 0, count: chunkSize)
            while true {
                let count = read(STDIN_FILENO, &chunk, chunkSize)
                if count <= 0 { break }
                buffer.append(chunk, count: count)
                for message in NativeMessaging.takeMessages(from: &buffer) { onMessage(message) }
            }
            onEnd()
        }
        thread.stackSize = 1 << 20
        thread.start()
    }
}

/// 日志写到标准错误和小助手目录里的 helper.log。只记录数量、耗时和错误，不记录图片地址、网页文字和 Key
public enum HelperLog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fileHandle: FileHandle?
    private static let maxFileBytes: UInt64 = 1024 * 1024

    public static func open(at url: URL) {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 超过 1 MB 就从头写，免得越积越大
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64,
           size > maxFileBytes {
            try? FileManager.default.removeItem(at: url)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: url)
        _ = try? fileHandle?.seekToEnd()
    }

    public static func write(_ message: String) {
        let stamp = ISO8601DateFormatter.string(
            from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withFullTime])
        let line = Data("\(stamp) \(message)\n".utf8)
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardError.write(line)
        fileHandle?.write(line)
    }
}
