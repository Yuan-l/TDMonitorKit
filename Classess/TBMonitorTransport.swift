import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// 上报编排层。
///
/// 现在只做四件事：**入队、出队、排期、记账**。
/// - 落盘 → `TDEventQueueStore`
/// - HTTP → `TDBatchUploader`
/// - 毒数据隔离 → `TDBatchResolver`
/// - 退避 → `TDRetryPolicy`
///
/// 拆分依据（Datadog `DatadogCore/Sources/Core` 把 `Storage` / `Upload` / `DataStore`
/// 做成三个独立子系统，`DatadogCore.swift` 只做组装）：旧实现 293 行一个类，
/// 把落盘与发网络焊在一起，结果是**出口内部逻辑完全无法单测**。想验证
/// 「4xx 会不会丢数据」「二分隔离是否只丢坏的那条」「429 会不会退避」，
/// 都必须起一个真 HTTP 服务——而这恰好是最容易写错、最需要测试的部分。
///
/// **投递语义：至少一次（at-least-once）。** 成功发送的事件在下一次压缩前仍留在
/// 磁盘上；此刻进程被杀，重启后会重发，靠事件 `id` 由服务端去重。
/// 反过来（先删后发）就变成至多一次：重复可以纠正，丢失无法补。
final class TDTransport: TDEventSink {

    /// 单批上限。500 条约 300KB，在 4G 下约 1~2 秒传完；
    /// 再大会让一次失败的重试代价过高，再小则请求数膨胀。
    private static let maxBatchSize = 500

    private let config: TDMonitorConfiguration
    private let context: TDContext
    private let queue = TDMonitorQueues.transport
    private let store: TDEventQueueStore
    private let policy = TDRetryPolicy()
    private var resolver: TDBatchResolver!

    private var pending: [[String: Any]] = []
    /// 已发出但尚未收到上传结论的批次数（永远等于 `pending` 队首的这么多条）。
    /// `apply(outcomes:)` 依赖这个不变式出队，队列满时的淘汰必须避开它。
    private var inFlightCount = 0
    /// 本进程因容量保护累计淘汰的事件条数。只进诊断快照，不参与任何投递判定。
    private var evictedEvents = 0
    private var timer: DispatchSourceTimer?
    private var retryTimer: DispatchSourceTimer?
    private var backoff: TimeInterval = 0.25
    private var sending = false

    /// 最近一次 flush 的结果与累计批次数。只在 `queue` 上写。
    ///
    /// 存在的理由很具体：队列涨到几百 KB 时，「是没采到、没落盘、还是发不出去」
    /// 这三个判断用日志是查不出来的——日志要人盯着看，而积压是持续的。
    /// 有一句「上次发送：失败 500 条（HTTP 401）」就能直接定位到配错 Key。
    private var lastUploadSummary: String?
    private var lastUploadAt: Date?
    private var sentBatches = 0

    init(configuration: TDMonitorConfiguration,
         context: TDContext,
         uploader: TDBatchUploader? = nil,
         store: TDEventQueueStore? = nil) {
        self.config = configuration
        self.context = context

        // 唯一落盘实现：共享 mmap 底座（TBCustomNetworkLogger 的 TBMMAPLogFile），
        // 每条 CRC32 + AES + msync 提交位点，断电/强杀都只丢最后一批。
        // 依赖注入可换成内存实现；没有旧格式需要读取或迁移。
        self.store = store ?? TDMMAPQueueStore(directory: TDTransport.storeDirectory(),
                                               maxEvents: configuration.maxQueueSize)

        let upload = uploader ?? TDHTTPBatchUploader(configuration: configuration)
        // 回调里全部用局部变量 / static 函数，不捕获 self：
        // 闭包在 resolver 初始化期间创建，捕获 self 会让「self 是否已完整」变成
        // 编译器要判定的事，而这件事没有任何运行时收益。
        let authLogger = TDAuthFailureLogger()
        self.resolver = TDBatchResolver(
            uploader: upload,
            onReject: { payload, status, body in
                TDTransport.logRejection(payload, status: status, body: body)
            },
            onAuthFailure: { status, body, count in
                authLogger.logIfNeeded(status: status, body: body, count: count)
            },
            onBudgetExhausted: { count, status in
                TDMonitorLog.record(
                    "毒数据隔离预算耗尽，\(count) 条事件整组丢弃（HTTP \(status)）", level: "error")
            })
    }

    // MARK: - TDEventSink

    func start() {
        queue.sync {
            pending = store.load(limit: config.maxQueueSize)
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + config.flushInterval, repeating: config.flushInterval)
        timer.setEventHandler { [weak self] in self?.flush() }
        timer.resume()
        self.timer = timer
        flush()
    }

    func enqueue(_ event: TDEvent) {
        let payload = event.payload(context: context)
        // 逐条守住 JSON 合法性：NaN / 无穷大会让**整批**序列化失败，
        // 坏数据只损失自己。
        guard JSONSerialization.isValidJSONObject(payload),
              (try? JSONSerialization.data(withJSONObject: payload)) != nil else {
            TDMonitorLog.record("丢弃无法序列化的事件 kind=\(event.kind)", level: "warning")
            return
        }
        queue.async { [weak self] in
            self?.appendLocked(payload)
        }
    }

    /// 协议要求无参 `flush()`；带默认参数的版本在 Swift 里不算同一个 witness。
    func flush() { flush(completion: nil) }

    func flush(completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self = self, !self.sending, !self.pending.isEmpty else {
                completion?()
                return
            }
            self.sending = true
            let batch = Array(self.pending.prefix(TDTransport.maxBatchSize))
            self.inFlightCount = batch.count
            self.resolver.resolve(batch) { outcomes in
                self.queue.async {
                    self.apply(outcomes, to: batch)
                    self.sending = false
                    completion?()
                }
            }
        }
    }

    func flushInBackground() {
        #if canImport(UIKit)
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.flushInBackground() }
            return
        }
        var identifier: UIBackgroundTaskIdentifier = .invalid
        identifier = UIApplication.shared.beginBackgroundTask {
            UIApplication.shared.endBackgroundTask(identifier)
        }
        flush {
            DispatchQueue.main.async { UIApplication.shared.endBackgroundTask(identifier) }
        }
        #else
        flush()
        #endif
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
            self?.retryTimer?.cancel()
            self?.retryTimer = nil
        }
        // 队列不清空：没发完的事件留在磁盘，下次启动继续发。
        flushInBackground()
        TDMonitorLog.flushToDisk()
    }

    // MARK: - 队列（以下方法只在 queue 上调用）

    private func appendLocked(_ payload: [String: Any]) {
        if pending.count >= config.maxQueueSize {
            // 队首 inFlightCount 条是「已发出但未确认」的批次，淘汰不能碰它们：
            // 否则 apply(outcomes:) 按 batch.count 出队时会错位，把从未发过的
            // 新事件一起删掉。只淘汰在途批次之后的记录；若整个队列都被在途
            // 批次占满，宁可拒绝这条新事件，也不错位丢一批。
            let protectedCount = inFlightCount
            let droppable = pending.count - protectedCount
            // 一次腾出 10%，而不是每条新事件淘汰 1 条：下面必须做一次全量重写
            // 来同步磁盘，逐条淘汰会把写放大变成「每条事件都重写 1000 条」。
            let batch = min(max(1, config.maxQueueSize / 10), droppable)
            guard batch > 0 else { return }
            pending.removeSubrange(protectedCount..<(protectedCount + batch))
            evictedEvents += batch
            // 非追加变更必须立刻同步磁盘。只删内存的话，被淘汰的事件仍躺在
            // mmap 里；此刻进程被强杀，下次启动 load() 会把它读回来「复活」，
            // 容量保护形同虚设。同步后磁盘与 pending 一致，再走正常追加。
            store.replace(with: pending)
            TDMonitorLog.record(
                "事件队列达到上限 \(config.maxQueueSize)，淘汰在途批次之后最旧 \(batch) 条并同步落盘（累计 \(evictedEvents) 条）",
                level: "warning")
        }
        pending.append(payload)
        // 追加写：不再重写整个队列（旧实现每条事件都全量序列化 + 原子写）。
        store.append([payload])
        compactIfNeeded()
    }

    private func apply(_ outcomes: [TDBatchResolver.Outcome], to batch: [[String: Any]]) {
        let remove = min(inFlightCount, pending.count)
        pending.removeFirst(remove)
        inFlightCount = 0

        // 只有 retry 的那几条回队首，保持原顺序重发。
        var retries: [[String: Any]] = []
        retries.reserveCapacity(batch.count)
        for (index, payload) in batch.enumerated() where index < outcomes.count {
            if outcomes[index] == .retry { retries.append(payload) }
        }
        if !retries.isEmpty {
            pending.insert(contentsOf: retries, at: 0)
            if pending.count > config.maxQueueSize {
                let overflow = pending.count - config.maxQueueSize
                pending.removeLast(overflow)
                evictedEvents += overflow
                // 截断同样不是追加，磁盘必须同步：否则强杀后这批会复活，
                // 下一次 load 又要按上限再截一次，且全程无痕迹。
                store.replace(with: pending)
                TDMonitorLog.record(
                    "重试回队后超过上限 \(config.maxQueueSize)，丢弃队尾 \(overflow) 条并同步落盘",
                    level: "warning")
            }
        }

        backoff = policy.delay(for: outcomes, current: backoff)
        compactIfNeeded()
        recordOutcome(outcomes)

        // 真正的退避在这里生效。
        //
        // 旧实现是假退避：它用 `asyncAfter(backoff)` 去**延迟网络回调的返回**，
        // 而重发时机仍由固定 10s 的 timer 决定——`backoff` 字段被算了但从没被
        // 用来排期。结果是「指数退避」既不退避，还让一次 flush 多卡几秒。
        if outcomes.contains(.retry), backoff > policy.initialDelay {
            scheduleRetry(after: backoff)
        }
    }

    /// 追加写的必然结果：已成功发送的事件仍留在文件里，直到下一次压缩才消失。
    /// 每次发送完都全量重写，等于把追加写的好处又还回去。
    private func compactIfNeeded() {
        let bloat = store.storedCount - pending.count
        guard store.needsCompaction || bloat > config.maxQueueSize / 2 else { return }
        store.replace(with: pending)
    }

    private func scheduleRetry(after delay: TimeInterval) {
        retryTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            self?.retryTimer = nil
            self?.flush()
        }
        timer.resume()
        retryTimer = timer
    }

    // MARK: - 诊断

    /// 把一批结果记成一句人能读懂的话。
    ///
    /// 刻意不记 HTTP body——那已经在 `logRejection` 里进诊断日志了。
    /// 这里只回答「还在往外发吗、发得动吗」，是长期驻留的一句状态。
    private func recordOutcome(_ outcomes: [TDBatchResolver.Outcome]) {
        let accepted = outcomes.filter { $0 == .accepted }.count
        let dropped = outcomes.filter { $0 == .dropped }.count
        let retried = outcomes.filter { $0 == .retry }.count

        sentBatches += 1
        lastUploadAt = Date()

        var parts = ["\(accepted) 条成功"]
        if retried > 0 { parts.append("\(retried) 条待重试") }
        if dropped > 0 { parts.append("\(dropped) 条被拒丢弃") }
        lastUploadSummary = parts.joined(separator: " / ")
    }

    /// 队列与上传的当前状态。从任意线程调用都安全（内部同步到 transport 队列）。
    ///
    /// 迁移排障用：宿主面板 / 自动化脚本靠它回答「采集到的事件到底走到哪一步了」。
    func snapshot() -> TDQueueStatus {
        queue.sync {
            TDQueueStatus(
                queuedEvents: pending.count,
                storedEvents: store.storedCount,
                storedBytes: storedBytes(),
                corruptedLines: store.corruptedLines,
                sentBatches: sentBatches,
                lastUploadSummary: lastUploadSummary,
                lastUploadAt: lastUploadAt,
                endpoint: config.ingestURL.absoluteString,
                evictedEvents: evictedEvents)
        }
    }

    /// 磁盘上「已提交数据」的字节数。
    ///
    /// mmap 文件大小是映射区大小（16KB 起步、按需扩容），拿它当积压量会严重虚高，
    /// 所以走 `committedBytes`（文件头里的 dataLength）。注入内存实现时没有磁盘文件，
    /// 直接返回 0。
    private func storedBytes() -> Int {
        (store as? TDMMAPQueueStore)?.committedBytes ?? 0
    }

    /// 把被拒事件的 kind / name / 服务端 error body 记下来。
    /// 没有这条日志，线上只能看到「数据没上来」，永远定位不到是哪条、为什么。
    private static func logRejection(_ payload: [String: Any], status: Int, body: String) {
        let kind = payload["kind"] as? String ?? "?"
        let name = payload["name"] as? String ?? "-"
        let attributes = (payload["attributes"] as? [String: Any])?.keys.sorted().joined(separator: ",") ?? "-"
        let trimmed = body.count > 400 ? String(body.prefix(400)) : body
        TDMonitorLog.record(
            "事件被拒 HTTP \(status) kind=\(kind) name=\(name) attrs=[\(attributes)] body=\(trimmed)",
            level: "error")
    }

    private static func storeDirectory() -> URL {
        let base = (try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("TDMonitor", isDirectory: true)
    }
}

/// 鉴权失败日志节流。
///
/// Key 配错时会每一轮都失败。不节流的话，一个配错的 Key 能在几分钟内把诊断日志
/// 冲满，真正有用的信息（哪一类事件被拒）反而被挤掉。
final class TDAuthFailureLogger {

    private let lock = NSLock()
    private var lastLog = Date.distantPast
    private let interval: TimeInterval

    init(interval: TimeInterval = 60) {
        self.interval = interval
    }

    func logIfNeeded(status: Int, body: String, count: Int) {
        lock.lock()
        let shouldLog = Date().timeIntervalSince(lastLog) > interval
        if shouldLog { lastLog = Date() }
        lock.unlock()
        guard shouldLog else { return }
        let trimmed = body.count > 200 ? String(body.prefix(200)) : body
        TDMonitorLog.record(
            "鉴权失败 HTTP \(status)，本批 \(count) 条已丢弃——检查 apiKey 是否吊销/过期 body=\(trimmed)",
            level: "error")
    }
}
