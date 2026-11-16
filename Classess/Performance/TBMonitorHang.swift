import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif

/// 主线程卡顿（ANR）看门狗。
///
/// **检测阈值与上报阈值是两件事**，这是与业界对齐后的关键修正：
/// - 检测起点 250ms：卡顿一旦发生就要开始采栈，起晚了抓不到早期的调用链；
/// - 上报阈值 2000ms：只有到这个量级才算「用户能明确感知的卡顿」。
///   250ms~2s 的抖动在启动、页面切换时极常见，逐条上报只会把真实信号淹没。
///
/// 分级口径对齐 Sentry `defaultAppHangTimeoutInterval = 2.0`：
/// - `hang`（2s ≤ 时长 < 8s）：体验层面的卡顿，进程活着，数据发得出去；
/// - `fatal_suspected`（≥ 8s）：大概率已被系统 watchdog 盯上，
///   这类事件常在发出前随进程一起消失，所以另有 `onProgress` 每秒落盘兜底。
///
/// 阻塞类型（`fully_blocked` / `partially_blocked`）用「卡顿期间出过几帧」判断，
/// 思路与 Sentry V2 的 `framesContributingToDelayCount == 1` 一致：
/// 主线程完全停摆时 displayLink 也不回调，帧数为 0；主线程仍在出帧只是慢，
/// 说明不是纯阻塞，而是渲染链路本身吃力。两者排查方向完全不同。
final class TDHangWatchdog {

    struct Report {
        let durationMs: Double
        /// 检测起点阈值（250ms），保留用于判断采样是否完整。
        let thresholdMs: Double
        /// 上报阈值（2000ms）。
        let reportThresholdMs: Double
        /// `hang` / `fatal_suspected`
        let severity: String
        /// `fully_blocked` / `partially_blocked`
        let blockType: String
        /// 卡顿窗口内 displayLink 的回调次数。
        let framesDuring: Int
        let sampleCount: Int
        let stack: String?
        let frames: [[String: Any]]
        let screen: String?
        let foreground: Bool
    }

    /// 检测起点：超过它就开始采样（不意味着上报）。
    private let thresholdMs: Double
    /// 上报阈值：低于它直接丢弃，避免用噪声淹没真实卡顿。
    private let reportThresholdMs: Double
    /// 致命推测阈值：达到即认为可能已被系统 watchdog 终止。
    private let fatalThresholdMs: Double
    private let sampleIntervalMs: Double
    private let maxHangMs: Double
    private let foregroundProvider: () -> Bool
    private let onHang: (Report) -> Void
    /// 卡顿**进行中**的进度回调，每秒一次（且只在超过上报阈值后开始）。
    ///
    /// 存在的理由：主线程卡死超过系统看门狗阈值时，进程会被 SIGKILL，
    /// 内存里的这条 ANR 永远发不出去。只有在卡顿期间把时长落盘，下次启动
    /// 的终止归因才能拿到「上一次是卡死被杀的」这条证据。缺少这个回调，
    /// 最严重的那类卡顿恰好一条数据都没有。
    private let onProgress: ((Double) -> Void)?

    private let queue = TDMonitorQueues.hang
    private var running = false

    /// displayLink 回调计数。只做整数累加，不持有帧数据。
    private let frameLock = NSLock()
    private var frameTicks = 0

    /// 上一次上报的时间点（单调时钟）。用于抑制同一段卡顿的重复结算。
    private var lastReportedAt: CFTimeInterval = 0

    init(thresholdMs: Double,
         reportThresholdMs: Double = 2_000,
         fatalThresholdMs: Double = 8_000,
         sampleIntervalMs: Double,
         maxHangMs: Double,
         foregroundProvider: @escaping () -> Bool = { true },
         onProgress: ((Double) -> Void)? = nil,
         onHang: @escaping (Report) -> Void) {
        self.thresholdMs = max(50, thresholdMs)
        self.reportThresholdMs = max(self.thresholdMs, reportThresholdMs)
        self.fatalThresholdMs = max(self.reportThresholdMs, fatalThresholdMs)
        self.sampleIntervalMs = max(20, sampleIntervalMs)
        self.maxHangMs = maxHangMs
        self.foregroundProvider = foregroundProvider
        self.onProgress = onProgress
        self.onHang = onHang
    }

    func start() {
        guard !running else { return }
        running = true
        // 常驻注册：即使当前没有页面在屏上，也要有帧回调，
        // 否则「卡顿时一帧都没出」和「本来就没人在看页面」无法区分。
        // 单次回调只有一次整数累加，开销可忽略。
        TDDisplayLinkHub.shared.add(self) { [weak self] _, _ in
            guard let self = self else { return }
            self.frameLock.lock()
            self.frameTicks &+= 1
            self.frameLock.unlock()
        }
        queue.async { [weak self] in self?.loop() }
    }

    func stop() {
        running = false
        TDDisplayLinkHub.shared.remove(self)
    }

    private var currentFrameTicks: Int {
        frameLock.lock(); defer { frameLock.unlock() }
        return frameTicks
    }

    // MARK: - 分级规则（纯函数，可单测）

    /// 主循环依赖真实主线程与墙钟，无法在不 sleep 的前提下做确定性测试，
    /// 所以把「怎么定级」抽成纯函数单独覆盖。规则本身是业务契约，
    /// 一旦有人改动阈值语义，这两条测试会立刻失败。
    static func severity(durationMs: Double, fatalThresholdMs: Double) -> String {
        durationMs >= fatalThresholdMs ? "fatal_suspected" : "hang"
    }

    static func blockType(framesDuring: Int) -> String {
        framesDuring <= 1 ? "fully_blocked" : "partially_blocked"
    }

    /// 抑制窗口：距上一次上报太近就不再报。
    ///
    /// 对齐 Sentry V2 `lastAppHangStoppedSystemTime + timeoutInterval > now → ignore`
    /// 与 Datadog `falsePositiveThreshold = 30s` 的同一意图：一段持续卡顿在恢复过程中
    /// 会被结算多次，逐条上报等于把一次事故放大成 N 次，事故数统计直接失真。
    ///
    /// 窗口取上报阈值（2s）而不是 Datadog 的 30s：30s 会吞掉连续卡顿这种真实场景
    /// （用户连续操作、一路都卡），2s 只压掉同一段卡顿的重复结算。
    static func shouldReport(now: CFTimeInterval,
                             lastReportedAt: CFTimeInterval,
                             thresholdMs: Double) -> Bool {
        guard lastReportedAt > 0 else { return true }
        return (now - lastReportedAt) * 1000 >= thresholdMs
    }

    private func loop() {
        let detect = thresholdMs / 1000.0
        while running {
            let started = CFAbsoluteTimeGetCurrent()
            let semaphore = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { semaphore.signal() }

            // 未超时说明主线程正常，直接下一轮。
            guard semaphore.wait(timeout: .now() + detect) == .timedOut else { continue }

            let framesAtStart = currentFrameTicks
            var samples: [[UInt64]] = []
            var recovered = false
            let interval = sampleIntervalMs / 1000.0
            var lastProgressAt: CFTimeInterval = 0

            while running {
                samples.append(TDStackSampler.captureMainThreadAddresses())
                let elapsedMs = (CFAbsoluteTimeGetCurrent() - started) * 1000

                // 只在确认「这是要上报的卡顿」之后才落盘：2s 以下的抖动
                // 落盘既无价值又平白增加 IO。之后每秒一次，保证被 SIGKILL
                // 前有证据，也不至于让监控自己成为 IO 负担。
                if elapsedMs >= reportThresholdMs && elapsedMs - lastProgressAt >= 1000 {
                    lastProgressAt = elapsedMs
                    onProgress?(elapsedMs)
                }

                if semaphore.wait(timeout: .now() + interval) == .success {
                    recovered = true
                    break
                }
                if elapsedMs > maxHangMs { break }
            }

            // 用单调时钟算时长：卡顿期间墙钟可能被 NTP 校正，差值不可靠。
            let endedAt = CFAbsoluteTimeGetCurrent()
            let durationMs = (endedAt - started) * 1000
            let framesDuring = max(0, currentFrameTicks - framesAtStart)

            let reachThreshold = durationMs >= reportThresholdMs
            let notTooSoon = Self.shouldReport(now: endedAt,
                                               lastReportedAt: lastReportedAt,
                                               thresholdMs: reportThresholdMs)

            if reachThreshold && notTooSoon {
                lastReportedAt = endedAt
                // 采样与符号化必须分开：主线程挂起期间做 dladdr 可能撞上 dlopen 锁。
                let addresses = samples.first(where: { $0.count > 2 }) ?? samples.first ?? []
                let frames = TDStackSampler.symbolicate(addresses)
                let report = Report(
                    durationMs: durationMs,
                    thresholdMs: thresholdMs,
                    reportThresholdMs: reportThresholdMs,
                    severity: Self.severity(durationMs: durationMs, fatalThresholdMs: fatalThresholdMs),
                    blockType: Self.blockType(framesDuring: framesDuring),
                    framesDuring: framesDuring,
                    sampleCount: samples.count,
                    stack: frames.isEmpty ? nil : TDStackSampler.format(frames),
                    frames: TDStackSampler.structured(frames),
                    screen: TDScreenContext.shared.current,
                    foreground: foregroundProvider()
                )
                onHang(report)
            }

            // 主线程仍未恢复时不要继续叠加采样，等它回来再说。
            if !recovered {
                _ = semaphore.wait(timeout: .now() + detect)
            }
        }
    }
}

/// 原生长任务：主线程单次连续占用超过阈值（默认 100ms）。
///
/// 用 RunLoop 观察者衡量「醒来 → 再次休眠」之间的连续忙时间，比 FPS 更早发现
/// 卡顿源头：掉帧只是结果，长任务才是原因，且不依赖屏幕刷新。
final class TDLongTaskMonitor {

    private let thresholdMs: Double
    private let onLongTask: (Double, String?) -> Void
    private var observer: CFRunLoopObserver?
    private var busySince: CFTimeInterval?

    init(thresholdMs: Double, onLongTask: @escaping (Double, String?) -> Void) {
        self.thresholdMs = max(16, thresholdMs)
        self.onLongTask = onLongTask
    }

    func start() {
        guard observer == nil else { return }
        let activities: CFRunLoopActivity = [.afterWaiting, .beforeSources, .beforeWaiting, .exit]
        let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, activities.rawValue, true, 0) { [weak self] _, activity in
            self?.handle(activity)
        }
        guard let observer = observer else { return }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    func stop() {
        if let observer = observer {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
        observer = nil
        busySince = nil
    }

    private func handle(_ activity: CFRunLoopActivity) {
        let now = CFAbsoluteTimeGetCurrent()
        switch activity {
        case .afterWaiting, .beforeSources:
            if busySince == nil { busySince = now }
        case .beforeWaiting, .exit:
            guard let start = busySince else { return }
            busySince = nil
            let durationMs = (now - start) * 1000
            guard durationMs >= thresholdMs else { return }
            onLongTask(durationMs, TDScreenContext.shared.current)
        default:
            break
        }
    }
}

/// 当前页面上下文，供卡顿 / 长任务 / 页面耗时 / 终止归因共用。
///
/// 用栈而不是单值：push 新页面时旧页面还没消失，单值会让卡顿归属在
/// push 动画期间来回跳。栈顶才是用户真正看到的那一页。
final class TDScreenContext {
    static let shared = TDScreenContext()
    private let lock = NSLock()
    private var stack: [String] = []
    /// 手动 `setScreen` 覆盖值，非 nil 时优先于栈顶。
    private var override: String?
    /// 最近一次同步给 AppState 的页面，用来去掉重复的落盘。
    private var lastReported: String?

    var current: String? {
        lock.lock(); defer { lock.unlock() }
        return override ?? stack.last
    }

    func push(_ name: String) {
        lock.lock()
        override = nil
        // 同一个页面重复出现时先移除旧的，避免 pop 顺序错乱导致栈无限增长。
        stack.removeAll { $0 == name }
        stack.append(name)
        let resolved = stack.last
        lock.unlock()
        reportIfChanged(resolved)
    }

    func pop(_ name: String) {
        lock.lock()
        stack.removeAll { $0 == name }
        let resolved = override ?? stack.last
        lock.unlock()
        reportIfChanged(resolved)
    }

    /// 手动埋点入口（`TDMonitor.setScreen`）。传 nil 回到自动栈顶。
    func update(_ name: String?) {
        lock.lock()
        override = name
        let resolved = override ?? stack.last
        lock.unlock()
        reportIfChanged(resolved)
    }

    /// 把「当前页面」同步进落盘的现场。
    ///
    /// 终止归因的 `prevScreen` 和 OOM 页面时间线读的是 `app_state.json`，
    /// **不是**内存里的 `TDScreenContext`。之前这里漏了这一跳：
    /// `TDAppStateTracker.setScreen` 全工程没有调用方，导致真机上
    /// `lastScreen=null`、页面时间线为空、`prevScreen` 恒为 `-`。
    /// 现在自动页面栈（swizzle push/pop）与业务 `setScreen` 都会收敛到这里。
    ///
    /// 只在页面真正变化时写：同一个 VC 每次 `viewDidAppear` 都触发一次磁盘 IO
    /// 没必要，AppState 的 `mutate` 是异步串行写，重复写的代价是白烧电。
    private func reportIfChanged(_ screen: String?) {
        guard let screen = screen, !screen.isEmpty else { return }
        lock.lock()
        let changed = screen != lastReported
        if changed { lastReported = screen }
        lock.unlock()
        guard changed else { return }
        TDAppStateTracker.shared.setScreen(screen)
    }
}
