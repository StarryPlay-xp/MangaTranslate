import Foundation
import HelperCore

// Chrome 启动小助手时，标准输入输出就是和插件之间的消息通道。插件断开（关掉 Chrome、停用插件）时退出
let paths = HelperPaths.standard()
HelperLog.open(at: paths.logFile)
let helper = Helper(paths: paths, writer: MessageWriter())

let (messages, continuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
MessageReader.start(
    onMessage: { continuation.yield($0) },
    onEnd: { continuation.finish() })

// 按到达顺序逐条处理；耗时的翻译在 Helper 里另开任务
for await message in messages {
    await helper.handle(message)
}
exit(0)
