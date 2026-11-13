import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif

/// 主线程卡顿（ANR）看门狗。
///
/// 判定与采样分开：
/// 1. 后台线程每轮向主线程投递一个空 block，超过阈值未执行即判定为卡顿；
/// 2. 卡顿期间按固定间隔抓取主线程真实堆栈（`TDStackSampler`），得到 N 个样本；
/// 3. 主线程恢复后统一符号化并上报，`durationMs` 是实测墙钟时长而非估算。
///
/// 这样上报的 ANR 带「卡在哪个函数 + 采了几次」的信息，可以直接定位问题，
/// 而不是只有一条「卡了 800ms」的记录。
final class TDHangWatchdog {

    struct Report {
        let durationMs: Double
        let thresholdMs: Double
        let sampleCount: Int
        let stack: String?
        let frames: [[String: Any]]
        let screen: String?
    }

    private let thresholdMs: Double
    private let sampleIntervalMs: Double
    private let maxHangMs: Double
    private let onHang: (Report) -> Void
    private let queue = DispatchQueue(label: "com.truedepth.monitor.hang", qos: .utility)
    private var running = false

    init(thresholdMs: Double, sampleIntervalMs: Double, maxHangMs: Double,
         onHang: @escaping (Report) -> Void) {
        self.thresholdMs = thresholdMs
        self.sampleIntervalMs = max(20, sampleIntervalMs)
        self.maxHangMs = maxHangMs
        self.onHang = onHang
    }

    func start() {
        guard !running else { return }
        running = true
        queue.async { [weak self] in self?.loop() }
    }

    func stop() { running = false }

    private func loop() {
        let threshold = thresholdMs / 1000.0
        while running {
            let started = Date()
            let semaphore = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { semaphore.signal() }

            if semaphore.wait(timeout: .now() + threshold) == .timedOut {
                var samples: [[UInt64]] = []
                var recovered = false
                let interval = sampleIntervalMs / 1000.0

                while running {
                    samples.append(TDStackSampler.captureMainThreadAddresses())
                    if semaphore.wait(timeout: .now() + interval) == .success {
                        recovered = true
                        break
                    }
                    if Date().timeIntervalSince(started) * 1000 > maxHangMs { break }
                }

                let durationMs = Date().timeIntervalSince(started) * 1000
                // 采样与符号化必须分开：主线程挂起期间做 dladdr 可能撞上 dlopen 锁。
                let addresses = samples.first(where: { $0.count > 2 }) ?? samples.first ?? []
                let frames = TDStackSampler.symbolicate(addresses)
                let report = Report(
                    durationMs: durationMs,
                    thresholdMs: thresholdMs,
                    sampleCount: samples.count,
                    stack: frames.isEmpty ? nil : TDStackSampler.format(frames),
                    frames: TDStackSampler.structured(frames),
                    screen: TDScreenContext.shared.current
                )
                onHang(report)

                // 主线程仍未恢复时不要继续叠加采样，等它回来再说。
                if !recovered {
                    _ = semaphore.wait(timeout: .now() + threshold)
                }
            }
            Thread.sleep(forTimeInterval: 0.1)
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

/// 当前页面名，供卡顿 / 长任务 / 页面耗时共用。
final class TDScreenContext {
    static let shared = TDScreenContext()
    private let lock = NSLock()
    private var screen: String?

    var current: String? {
        lock.lock(); defer { lock.unlock() }
        return screen
    }

    func update(_ name: String?) {
        lock.lock(); screen = name; lock.unlock()
    }
}
