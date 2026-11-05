/// 限制同时进行的任务数（模型请求、文字识别），多出来的按先来后到排队。
/// 上限在每次申请时传入：切换模型服务后，新的上限从下一次申请起生效
final class RequestGate {
    private var running = 0
    private var limit = 1
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// 等到有空位再返回；用完必须调用 release()
    func acquire(limit: Int) async {
        self.limit = max(1, limit)
        if running < self.limit, waiting.isEmpty {
            running += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// 让出名额，按顺序放行排队的
    func release() {
        running -= 1
        while running < limit, !waiting.isEmpty {
            running += 1
            waiting.removeFirst().resume()
        }
    }
}
