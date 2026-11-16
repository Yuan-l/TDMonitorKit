import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(QuartzCore)
import QuartzCore
#endif

/// 进程内唯一的 `CADisplayLink`。
///
/// 全局帧率与逐页面帧率都需要每帧回调。各开一个 displayLink 不会有功能问题，
/// 但意味着每次 vsync 有两个 selector 被派发、两份时间戳计算，而且两者的
/// 生命周期没人统一管理——后续再加"滑动流畅度"之类又得开第三个。
/// 这里做成一个 hub：谁需要谁注册，全部撤销后自动 invalidate。
final class TDDisplayLinkHub {

    static let shared = TDDisplayLinkHub()

    private let lock = NSLock()
    private var handlers: [ObjectIdentifier: (CFTimeInterval, CFTimeInterval) -> Void] = [:]
    /// 回调快照。`add` / `remove` 时重建，`tick` 里直接复制引用（O(1)），
    /// 避免每帧都做一次 `Array(handlers.values)` 的构建与释放。
    /// 常驻注册之后每帧都会走到这里，这点分配量值得省。
    private var snapshot: [(CFTimeInterval, CFTimeInterval) -> Void] = []
    private var link: CADisplayLink?

    private init() {}

    func add(_ owner: AnyObject, handler: @escaping (_ timestamp: CFTimeInterval, _ expected: CFTimeInterval) -> Void) {
        lock.lock()
        handlers[ObjectIdentifier(owner)] = handler
        snapshot = Array(handlers.values)
        let needStart = link == nil
        lock.unlock()
        if needStart { start() }
    }

    func remove(_ owner: AnyObject) {
        lock.lock()
        handlers.removeValue(forKey: ObjectIdentifier(owner))
        snapshot = Array(handlers.values)
        let shouldStop = handlers.isEmpty
        lock.unlock()
        if shouldStop { stop() }
    }

    private func start() {
        #if canImport(UIKit)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            guard self.link == nil else { self.lock.unlock(); return }
            let link = CADisplayLink(target: self, selector: #selector(self.tick(_:)))
            // 不指定 preferredFrameRateRange：让系统按屏幕能力与省电策略决定。
            // 强行要求 120Hz 会阻止低电量模式降频，而"系统正在降频"本身
            // 就是应该被观测到的信号，不能被采集器自己抹掉。
            link.add(to: .main, forMode: .common)
            self.link = link
            self.lock.unlock()
        }
        #endif
    }

    private func stop() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            self.link?.invalidate()
            self.link = nil
            self.lock.unlock()
        }
    }

    #if canImport(UIKit)
    @objc private func tick(_ link: CADisplayLink) {
        let timestamp = link.timestamp
        let expected = max(link.targetTimestamp - link.timestamp, 1.0 / 240.0)
        lock.lock()
        let active = snapshot
        lock.unlock()
        for handler in active { handler(timestamp, expected) }
    }
    #endif
}

/// 一次页面的渲染质量切片。
///
/// 为什么是"切片"而不是"整个页面生命周期一个数"：如果只在 `viewDidDisappear`
/// 上报，那么用户一直停在首页就永远没有首页的渲染数据——而首页恰恰是最重要的
/// 页面。所以停留在同一页超过 `sliceSeconds` 就结算一片，然后重新开窗。
struct TDScreenRenderReport {
    let screen: String
    let durationMs: Double
    let frameCount: Int
    let slowFrames: Int
    let frozenFrames: Int
    let hitchMs: Double
    let frameBudget: CFTimeInterval
    /// `slice` 表示页面还在，按窗口切出来的一片；`final` 表示页面已经消失。
    let phase: String

    var slowFrameRate: Double {
        frameCount > 0 ? Double(slowFrames) / Double(frameCount) * 100 : 0
    }

    var frozenFrameRate: Double {
        frameCount > 0 ? Double(frozenFrames) / Double(frameCount) * 100 : 0
    }

    var hitchRatio: Double {
        durationMs > 0 ? min(hitchMs / durationMs, 1.0) * 100 : 0
    }
}

/// 单个页面的渲染质量会话：`viewDidAppear` → `viewDidDisappear`。
///
/// 为什么必须按页面切分：全局 FPS 在大盘上永远是一条平线，因为
/// 大部分时间用户停在某个静止页面上，此时没有内容更新但 vsync 照常回调，
/// 帧率读数就是屏幕刷新率上限。真正的卡顿集中在少数几个页面（长列表、
/// 首屏、播放页），只有按页面归因才能定位到「哪个页面、慢到什么程度」。
///
/// 口径对齐 Sentry `SentryFramesTracker` 与 Firebase `FPRScreenTraceTracker`：
/// - 慢帧（slow frame）：单帧超过 `1 / (fps - 1)`。60Hz 下是 16.95ms，
///   120Hz 下是 8.4ms。**不是**「预算 × 1.5」——那个系数会把 17~25ms
///   这一档（轻微但可感知的卡）整段漏掉，慢帧率被系统性低估。
/// - 冻结帧（frozen frame）：单帧超过 700ms，用户能明确感知到界面冻住。
///   与慢帧互斥计数，两家都是这个口径，相加才是全部异常帧。
/// - 另加 hitchTime：异常帧超出预算的时间之和，比"帧数占比"更贴近体感卡顿时长。
final class TDScreenFrameSession {

    let screen: String
    /// 当前切片窗口的起点（单调时钟）。
    private(set) var windowStartedAt: CFTimeInterval
    /// 本页面的帧预算（秒）。120Hz 设备上约为 1/120。
    private(set) var frameBudget: CFTimeInterval = 1.0 / 60.0

    private(set) var frameCount = 0
    private(set) var slowFrames = 0
    private(set) var frozenFrames = 0
    private(set) var hitchMs: Double = 0
    private var lastTimestamp: CFTimeInterval = 0

    /// 一帧间隔超过该值视为「非渲染原因」，整段丢弃。
    /// 典型来源：App 切前后台导致 displayLink 暂停后恢复、系统弹窗、来电。
    /// 不做这个过滤，每次切回前台都会记一个秒级的大掉帧。
    private static let discontinuityThreshold: CFTimeInterval = 1.0

    /// 冻结帧阈值。Sentry `frozenFrameThreshold = 0.7`、Firebase
    /// `kFPRFrozenFrameThreshold = 700/1000`，两家一致。
    private static let frozenFrameThreshold: CFTimeInterval = 0.7

    /// 慢帧阈值 = `1 / (fps - 1)`。
    ///
    /// 为什么要减一：绝大多数帧都会比理论帧长多出几微秒（调度、合成、提交），
    /// 直接用 `1/fps` 会让几乎所有帧都被判成慢帧。减一之后留出这点余量，
    /// 只有真正掉帧才会命中。这是 Sentry 源码里的原话。
    ///
    /// 60Hz → 16.95ms；120Hz → 8.4ms。按实测刷新率动态取值，
    /// 所以 120Hz 设备不会被 60Hz 的绝对值误判成"全员慢帧"。
    static func slowFrameThreshold(expected: CFTimeInterval) -> CFTimeInterval {
        let frameDuration = max(expected, 1.0 / 240.0)
        let fps = 1.0 / frameDuration
        guard fps > 1 else { return frameDuration }
        return 1.0 / (fps - 1)
    }

    /// 一个切片窗口的时长。默认 30s：足够摊平抖动，又不会让长停留页面的数据延迟太久。
    /// 实际值由 `TDMonitorConfiguration.screenSliceSeconds` 注入。
    static let defaultSliceSeconds: CFTimeInterval = 30

    /// 窗口时长从这里取。注入是为了让「30s 切一片」「样本不足丢弃」这类
    /// 依赖时间的判定能被确定性测试，而不是靠 sleep 去撞。
    private let clock: TDClock

    init(screen: String, budget: CFTimeInterval, clock: TDClock = TDSystemClock.shared) {
        self.screen = screen
        self.clock = clock
        self.windowStartedAt = clock.monotonic
        self.frameBudget = budget
    }

    func updateBudget(_ budget: CFTimeInterval) {
        guard budget > 0 else { return }
        frameBudget = budget
    }

    /// 一次 displayLink 回调。
    /// - Parameters:
    ///   - timestamp: 单调时钟（`link.timestamp`），不要用 `Date()`：
    ///     墙钟会被 NTP 校正跳变，且卡顿期间墙钟差值会把窗口拉长、把 FPS 算低。
    ///   - expected: `link.targetTimestamp - link.timestamp`，该设备当前的期望帧长。
    func tick(timestamp: CFTimeInterval, expected: CFTimeInterval) {
        updateBudget(expected)
        defer { lastTimestamp = timestamp }

        guard lastTimestamp > 0 else { return }
        let delta = timestamp - lastTimestamp
        guard delta > 0 else { return }

        // 跨越前后台 / 系统打断：不计数，只重置基线。
        if delta > Self.discontinuityThreshold { return }

        frameCount += 1

        // 慢帧与冻结帧互斥计数：冻结帧单独成档，未冻结的才进慢帧。
        // 这样 slowFrameRate + frozenFrameRate 才是「全部异常帧占比」。
        guard delta > Self.slowFrameThreshold(expected: expected) else { return }
        hitchMs += max(0, delta - expected) * 1000
        if delta > Self.frozenFrameThreshold {
            frozenFrames += 1
        } else {
            slowFrames += 1
        }
    }

    var windowDurationMs: Double { (clock.monotonic - windowStartedAt) * 1000 }

    /// 帧数太少（页面秒开秒关、或切片刚开始）时不产出结论，
    /// 避免分母过小造成 100% 慢帧的假告警。
    var isWindowMeaningful: Bool { frameCount >= 10 && windowDurationMs >= 300 }

    /// 结算当前窗口并重置。返回 nil 表示本窗口样本不足，直接丢弃。
    func takeReport(phase: String) -> TDScreenRenderReport? {
        defer {
            frameCount = 0
            slowFrames = 0
            frozenFrames = 0
            hitchMs = 0
            windowStartedAt = clock.monotonic
        }
        guard isWindowMeaningful else { return nil }
        return TDScreenRenderReport(
            screen: screen,
            durationMs: windowDurationMs,
            frameCount: frameCount,
            slowFrames: slowFrames,
            frozenFrames: frozenFrames,
            hitchMs: hitchMs,
            frameBudget: frameBudget,
            phase: phase
        )
    }
}

/// 驱动所有活跃页面会话的帧统计。
///
/// 没有页面在屏上时不注册 vsync 回调：此时既没有页面可归属，回调也只会空转。
final class TDScreenFrameTracker {

    static let shared = TDScreenFrameTracker()

    private let lock = NSLock()
    private var sessions: [TDScreenFrameSession] = []
    private var handler: ((TDScreenRenderReport) -> Void)?
    private var sliceSeconds: CFTimeInterval = TDScreenFrameSession.defaultSliceSeconds

    private init() {}

    func configure(sliceSeconds: CFTimeInterval = TDScreenFrameSession.defaultSliceSeconds,
                   handler: @escaping (TDScreenRenderReport) -> Void) {
        lock.lock()
        self.sliceSeconds = max(5, sliceSeconds)
        self.handler = handler
        lock.unlock()
    }

    /// 拆掉回调并丢弃所有活跃会话。用于 SDK 停止时。
    func unconfigure() {
        lock.lock()
        sessions.removeAll()
        handler = nil
        lock.unlock()
        TDDisplayLinkHub.shared.remove(self)
    }

    func begin(_ session: TDScreenFrameSession) {
        lock.lock()
        let wasEmpty = sessions.isEmpty
        sessions.append(session)
        lock.unlock()

        if wasEmpty {
            TDDisplayLinkHub.shared.add(self) { [weak self] timestamp, expected in
                self?.tick(timestamp: timestamp, expected: expected)
            }
        }
    }

    /// 页面消失：结算最后一片并停止跟踪。
    func end(_ session: TDScreenFrameSession) {
        lock.lock()
        sessions.removeAll { $0 === session }
        let nowEmpty = sessions.isEmpty
        let handler = self.handler
        lock.unlock()

        if nowEmpty { TDDisplayLinkHub.shared.remove(self) }
        if let report = session.takeReport(phase: "final") { handler?(report) }
    }

    private func tick(timestamp: CFTimeInterval, expected: CFTimeInterval) {
        lock.lock()
        let active = sessions
        let handler = self.handler
        let sliceMs = self.sliceSeconds * 1000
        lock.unlock()

        var slices: [TDScreenRenderReport] = []
        for session in active {
            session.tick(timestamp: timestamp, expected: expected)
            // 停留超过一个窗口就切一片上报，保证长停留页面也有数据。
            if session.windowDurationMs >= sliceMs,
               let report = session.takeReport(phase: "slice") {
                slices.append(report)
            }
        }
        for report in slices { handler?(report) }
    }
}
