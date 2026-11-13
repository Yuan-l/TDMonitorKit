import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(QuartzCore)
import QuartzCore
#endif

/// 帧率与掉帧采集。
///
/// 早期实现用固定的 `2.0 / 60.0` 作为掉帧判据，在 120Hz 设备上会把正常帧全部
/// 记成卡顿、在低电量降频时又漏报。这里改为用 `CADisplayLink` 自己给出的
/// `targetTimestamp - timestamp` 作为该设备的期望帧间隔，并按帧耗时分布分桶，
/// 上报的不只是一个 FPS 数字，而是「有多少帧落在哪个区间」。
final class TDCollectors {

    struct FrameWindow {
        var frames = 0
        var jankFrames = 0
        var droppedFrames = 0
        var buckets = [0, 0, 0, 0, 0]   // <1.5x / <2x / <3x / <6x / >=6x 期望帧长
    }

    private let config: TDMonitorConfiguration
    private weak var transport: TDTransport?

    private var displayLink: CADisplayLink?
    private var lastFrameTimestamp: CFTimeInterval = 0
    private var expectedFrameDuration: CFTimeInterval = 1.0 / 60.0
    private var window = FrameWindow()
    private var windowStartedAt = Date()

    /// 内存警告由资源采集器处理，这里只保留统一出口。
    var onMemoryWarning: (() -> Void)?

    init(config: TDMonitorConfiguration, transport: TDTransport) {
        self.config = config
        self.transport = transport
    }

    func start() {
        #if canImport(UIKit)
        let link = CADisplayLink(target: self, selector: #selector(frameTick(_:)))
        if #available(iOS 15.0, *) {
            // 跟随屏幕原生刷新率，120Hz 设备上才能看到真实的 120fps 上限。
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        }
        link.add(to: .main, forMode: .common)
        displayLink = link
        windowStartedAt = Date()
        #endif
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func frameTick(_ link: CADisplayLink) {
        let expected = max(link.targetTimestamp - link.timestamp, 1.0 / 120.0)
        expectedFrameDuration = expected

        defer { lastFrameTimestamp = link.timestamp }
        guard lastFrameTimestamp > 0 else { return }

        let delta = link.timestamp - lastFrameTimestamp
        guard delta > 0 else { return }

        window.frames += 1
        let ratio = delta / expected
        if ratio >= 1.5 {
            window.jankFrames += 1
            window.droppedFrames += max(0, Int((ratio - 1).rounded()))
            switch ratio {
            case ..<2: window.buckets[0] += 1
            case ..<3: window.buckets[1] += 1
            case ..<6: window.buckets[2] += 1
            default: window.buckets[3] += 1
            }
        }

        let elapsed = Date().timeIntervalSince(windowStartedAt)
        guard elapsed >= 5 else { return }
        flushWindow(elapsed: elapsed)
    }

    private func flushWindow(elapsed: TimeInterval) {
        let snapshot = window
        window = FrameWindow()
        windowStartedAt = Date()

        guard snapshot.frames > 0 else { return }
        let fps = min(Double(snapshot.frames) / max(elapsed, 0.001), 120)
        report(name: "fps", value: fps, unit: "fps",
               attributes: ["refreshRateHz": Int((1.0 / expectedFrameDuration).rounded())])

        let jankRate = Double(snapshot.jankFrames) / Double(snapshot.frames)
        report(name: "frame_jank", value: jankRate * 100, unit: "%",
               attributes: [
                   "jankFrames": snapshot.jankFrames,
                   "droppedFrames": snapshot.droppedFrames,
                   "totalFrames": snapshot.frames,
                   "windowSeconds": elapsed,
                   // 分桶：1.5x / 2x / 3x / 6x 以上期望帧长，用于看掉帧严重程度分布
                   "buckets": snapshot.buckets,
               ])
    }

    private func report(name: String, value: Double, unit: String? = nil,
                        attributes: [String: Any] = [:]) {
        if config.sampleRate < 1 && Double.random(in: 0..<1) > config.sampleRate { return }
        var fields: [String: Any] = ["name": name, "value": value]
        if let unit = unit { fields["unit"] = unit }
        transport?.enqueue(TDEvent(kind: "mobile_metric", fields: fields, attributes: attributes))
    }
}
