import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 7. 原生长任务

final class TDLongTaskFeature: TDMonitorFeature {

    static let name = "long_task"
    static let requires = ["crash"]

    private let runtime: TDMonitorRuntime
    private let monitor: TDLongTaskMonitor

    init?(runtime: TDMonitorRuntime) {
        guard let bridge = runtime.service(TDCrashBridge.self) else { return nil }
        self.runtime = runtime
        self.monitor = TDLongTaskMonitor(thresholdMs: runtime.configuration.longTaskThresholdMs) { task in
            // observer 回调在主线程，只把轻量值投到后台队列：查环形缓冲 + dladdr
            // 符号化都不便宜，绝不能占住 RunLoop（那会制造新的长任务）。
            // 用 symbolication 而非 hang：hang 是串行队列且被 ANR watchdog 独占，
            // 投进去会饿死、long_task 事件静默丢失。
            TDMonitorQueues.symbolication.async {
                let sampler = TDMainThreadSampler.shared
                // 向后扩 50ms：长任务结束时主线程刚恢复，真正的卡点在其之前；
                // 采样器以 50ms 为周期，向前多覆盖一个采样点避免窗口边缘漏采。
                let frames = sampler.isRunning
                    ? sampler.bestFrames(from: task.busyFrom - 0.05, to: task.busyTo)
                    : nil
                bridge.recordLongTask(durationMs: task.durationMs, screen: task.screen, frames: frames)
            }
        }
    }

    func install() -> Bool {
        monitor.start()
        return true
    }

    func uninstall() {
        monitor.stop()
    }
}

