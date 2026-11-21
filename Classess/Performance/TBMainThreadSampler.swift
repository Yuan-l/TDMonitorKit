import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif

/// 旁路主线程栈采样器：为长任务 / 慢帧提供「卡住时主线程在做什么」的证据。
///
/// 为什么不能在主线程回调里直接采：
/// - `TDLongTaskMonitor.handle` 跑在 RunLoop observer（主线程），
///   `screen_render.tick` 跑在 displayLink（主线程）；
/// - `TDStackSampler.captureMainThreadAddresses()` 内部会 `thread_suspend(主线程Port)`，
///   主线程调它等于把自己挂起——采样器自己制造死锁；
/// - 而且这些回调是在「忙完之后」才结算的，此刻主线程已恢复，当场采到的
///   是空闲栈，不是真凶。
///
/// 所以按微信 Matrix 的做法：独立 utility 线程周期性采主线程栈，带墙钟时间戳
/// 存进环形缓冲；主线程回调只记时刻，事后用 `bestFrames(from:to:)` 取窗口内
/// 「重复次数最多」的栈（栈顶相同视为同一栈，重复越多≈卡得越久，并列取最近）。
///
/// 开销：每 50ms 一次 thread_suspend + 帧指针回溯，Matrix 实测约 +3% CPU。
/// 为控制开销，采样器只在有页面会话在屏上时运行（`TDScreenFrameTracker` 启停），
/// 后台无页面时自动停止——顺带避免了后台挂起被误记成分钟级卡顿时的无效采样。
final class TDMainThreadSampler {

    struct Sample {
        /// 墙钟（CFAbsoluteTimeGetCurrent），与 long_task 的 busySince、慢帧时刻同源，
        /// 必须同一时钟才能按窗口对齐。毫秒级窗口内 NTP 跳变可忽略。
        let at: CFTimeInterval
        let addresses: [UInt64]
    }

    static let shared = TDMainThreadSampler()

    /// 独立队列：不能复用 `TDMonitorQueues.hang`——那个队列被 ANR watchdog 的
    /// semaphore 循环长期占住，timer 回调插不进去。
    private let queue = DispatchQueue(label: "com.truedepth.monitor.sample", qos: .utility)
    private let lock = NSLock()
    private var buffer: [Sample] = []
    private var timer: DispatchSourceTimer?
    private let intervalMs: Double
    private let capacity: Int

    init(intervalMs: Double = 50, capacity: Int = 24) {
        self.intervalMs = max(20, intervalMs)
        self.capacity = max(4, capacity)
    }

    /// 采样是否在进行。long_task 上报时据此判断有无可用栈。
    private(set) var isRunning = false

    func start() {
        lock.lock()
        guard timer == nil else { lock.unlock(); return }
        isRunning = true
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(Int(intervalMs)))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            // capture 内部已做 thread_suspend/resume 配对，且帧指针回溯在挂起期内
            // 只读内存；dladdr 符号化留到 bestFrames 里（线程恢复后）再做。
            let addresses = TDStackSampler.captureMainThreadAddresses()
            guard !addresses.isEmpty else { return }
            let sample = Sample(at: CFAbsoluteTimeGetCurrent(), addresses: addresses)
            self.lock.lock()
            self.buffer.append(sample)
            if self.buffer.count > self.capacity {
                self.buffer.removeFirst(self.buffer.count - self.capacity)
            }
            self.lock.unlock()
        }
        self.timer = timer
        lock.unlock()
        timer.resume()
    }

    func stop() {
        lock.lock()
        guard let timer = timer else { lock.unlock(); return }
        self.timer = nil
        self.isRunning = false
        self.buffer.removeAll()
        lock.unlock()
        timer.cancel()
    }

    /// 取 [from, to] 窗口内的「最热栈」结构化帧。
    ///
    /// Matrix 算法：栈顶（PC）相同视为同一段卡顿，出现次数近似其耗时，
    /// 并列时取最近一次（栈更完整）。返回 nil 表示窗口内没有样本。
    /// 符号化在调用方队列（非主线程）执行，dladdr 安全。
    func bestFrames(from: CFTimeInterval, to: CFTimeInterval) -> [[String: Any]]? {
        lock.lock()
        let window = buffer.filter { $0.at >= from && $0.at <= to }
        lock.unlock()
        guard !window.isEmpty else { return nil }

        // 按栈顶地址分组，统计次数并记录各组最近的样本。
        var groups: [UInt64: (count: Int, latest: Sample)] = [:]
        for sample in window {
            guard let top = sample.addresses.first else { continue }
            if let existing = groups[top] {
                groups[top] = (existing.count + 1,
                               sample.at >= existing.latest.at ? sample : existing.latest)
            } else {
                groups[top] = (1, sample)
            }
        }
        // 次数最多优先；并列取时间戳最大（最近）。
        guard let best = groups.max(by: { lhs, rhs in
            if lhs.value.count != rhs.value.count { return lhs.value.count < rhs.value.count }
            return lhs.value.latest.at < rhs.value.latest.at
        }) else { return nil }

        let frames = TDStackSampler.structured(TDStackSampler.symbolicate(best.value.latest.addresses))
        return frames.isEmpty ? nil : frames
    }
}
