import Foundation

/// 事件队列的本地落盘。
///
/// 拆成独立一层的理由，对照 Datadog `DatadogCore/Sources/Core/Storage`：
/// 之前队列、HTTP、重试、鉴权、毒数据隔离全在一个类里，「队列上限」「被杀时丢多少」
/// 「写放大多少」都无法单独验证——想测其中任何一个都得把网络一起拖进来。
///
/// 当前只有一个落盘实现 `TDMMAPQueueStore`；`TDInMemoryQueueStore` 仅供依赖注入。
/// 工程还在建设测试阶段，没有历史格式需要兼容，因此不保留旧格式读取器 / 迁移代码。
///
/// 这一层有三条硬要求：
///
/// 1. **追加写**。正常路径只追加，不因单条事件全量重写整个队列。
/// 2. **坏记录可跳过**。CRC / 解密失败只损失那一条，不能让整份队列归零。
/// 3. **非追加变更必须同步落盘**。`load(limit:)` 的截断、容量保护下的淘汰、
///    编排层的溢出裁剪，都要让磁盘与返回给 `pending` 的内容一致，并留诊断痕迹。
///    只改内存会留下一批「磁盘里有、内存里没有、也永远不会被发」的孤儿记录：
///    下次启动被读回（复活），或在压缩时被静默抹掉，两种结果都不可观测。
protocol TDEventQueueStore: AnyObject {

    /// 读出最近 `limit` 条，顺序为入队顺序；超出上限时同步收敛磁盘。
    func load(limit: Int) -> [[String: Any]]

    /// 追加到队尾。进程被杀时最多丢最后一条。
    func append(_ events: [[String: Any]])

    /// 用给定内容重写整个队列（压缩 / 淘汰）。
    func replace(with events: [[String: Any]])

    func clear()

    /// 追加次数是否已超出容差，该做一次压缩了。
    ///
    /// 交给调用方决定时机，而不是在 `append` 里偷偷重写：压缩是 O(n) 全量写，
    /// 发生在哪一帧、能不能被接受，只有编排层知道。
    var needsCompaction: Bool { get }

    /// 诊断用：解析时跳过的坏记录数。为 0 说明落盘链路干净。
    var corruptedLines: Int { get }

    /// 磁盘上实际还留着多少条。
    ///
    /// 追加写的必然结果：已成功发送的事件仍躺在文件里，直到下一次压缩才消失。
    /// 编排层用它判断「文件比内存队列胖了多少」，超过容差才压缩。
    var storedCount: Int { get }
}

/// 内存实现：依赖注入用，也让「换存储后端」有第二个实现可验证抽象是否成立。
final class TDInMemoryQueueStore: TDEventQueueStore {

    private var events: [[String: Any]] = []
    private let maxEvents: Int
    private(set) var corruptedLines = 0
    private var appended = 0

    init(maxEvents: Int = 500) {
        self.maxEvents = max(1, maxEvents)
    }

    var needsCompaction: Bool { appended > maxEvents / 2 }

    var storedCount: Int { events.count }

    func load(limit: Int) -> [[String: Any]] {
        appended = 0
        // 与磁盘实现同一条不变式：截断要落到存储本身，不能只裁返回值。
        if events.count > limit {
            events.removeFirst(events.count - limit)
        }
        return events
    }

    func append(_ events: [[String: Any]]) {
        self.events.append(contentsOf: events)
        appended += events.count
        if self.events.count > maxEvents * 2 {
            self.events.removeFirst(self.events.count - maxEvents)
            appended = 0
        }
    }

    func replace(with events: [[String: Any]]) {
        self.events = events
        appended = 0
    }

    func clear() {
        events.removeAll()
        appended = 0
    }
}
