import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Darwin)
import Darwin
#endif

/// 进程启动时刻与分段计时。
///
/// 关键点：起点必须来自内核记录的进程创建时间（`kinfo_proc.p_starttime`）。
/// 如果像早期实现那样在 SDK 首次被触达时取 `systemUptime`，测到的是
/// 「start() 调用 → recordLaunch()」之间的几微秒，pre-main / dyld / 静态初始化
/// 全部丢失，上报的启动时长没有任何诊断价值。
enum TDLaunchClock {

    /// 内核视角的进程创建时刻。拿不到时返回 nil，调用方降级为「首次触达」时刻。
    static let processStart: Date? = {
        #if canImport(Darwin)
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let result = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        guard result == 0 else { return nil }
        let start = info.kp_proc.p_starttime
        guard start.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
        #else
        return nil
        #endif
    }()

    /// iOS 15+ 的预热启动：进程由系统提前拉起，用户点开时并未真正冷启动。
    /// 不区分会让「冷启动 P95」被预热样本污染。
    static var isPrewarmed: Bool {
        ProcessInfo.processInfo.environment["ActivePrewarm"] == "1"
    }

    /// SDK 首次被触达的时刻，仅在拿不到内核启动时间时兜底。
    static let firstTouch = Date()
}

/// 启动分段记录器。三段各自有明确的物理含义：
/// - `preMainMs`：进程创建 → `didFinishLaunching` 返回（dyld、静态初始化、启动项）
/// - `firstFrameMs`：`didFinishLaunching` → 首帧渲染完成（UI 组装的真实代价）
/// - `totalMs`：两者之和，与用户感知的「点开图标到看见界面」对齐
final class TDLaunchRecorder {

    private let origin: Date
    private let onFinish: ([String: Any]) -> Void
    private let lock = NSLock()

    private var didFinishLaunchingAt: Date?
    private var didEmit = false
    private var displayLink: CADisplayLink?

    init(onFinish: @escaping ([String: Any]) -> Void) {
        self.origin = TDLaunchClock.processStart ?? TDLaunchClock.firstTouch
        self.onFinish = onFinish
    }

    /// 在 `application(_:didFinishLaunchingWithOptions:)` 末尾调用。
    func markDidFinishLaunching() {
        lock.lock()
        if didFinishLaunchingAt == nil { didFinishLaunchingAt = Date() }
        lock.unlock()
    }

    /// 等到下一个渲染周期再结算首帧：`makeKeyAndVisible()` 只是提交了布局，
    /// 此刻取时间会把首帧渲染耗时算成 0。CADisplayLink 的第一次回调才是
    /// 首帧真正被呈现的时机。
    func markFirstFrameWhenRendered() {
        #if canImport(UIKit)
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.displayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(self.firstFrameTick))
            link.add(to: .main, forMode: .common)
            self.displayLink = link
        }
        #else
        emit()
        #endif
    }

    @objc private func firstFrameTick() {
        displayLink?.invalidate()
        displayLink = nil
        emit()
    }

    /// 兜底：宿主没有显式调用 `markFirstFrame()` 时也要有数据，
    /// 否则启动指标会永久缺失（比数字略偏更糟）。
    func forceEmitIfNeeded() {
        lock.lock()
        let done = didEmit
        lock.unlock()
        guard !done else { return }
        emit()
    }

    private func emit() {
        lock.lock()
        guard !didEmit else { lock.unlock(); return }
        didEmit = true
        let finish = didFinishLaunchingAt ?? Date()
        lock.unlock()

        let now = Date()
        let preMainMs = max(0, finish.timeIntervalSince(origin) * 1000)
        let firstFrameMs = max(0, now.timeIntervalSince(finish) * 1000)
        onFinish([
            "durationMs": preMainMs + firstFrameMs,
            "preMainMs": preMainMs,
            "firstFrameMs": firstFrameMs,
            "type": TDLaunchClock.isPrewarmed ? "prewarm" : "cold",
            "origin": TDLaunchClock.processStart == nil ? "first_touch" : "kernel_process_start",
            "measuredAt": TDISO8601.string(from: now),
        ])
    }
}
