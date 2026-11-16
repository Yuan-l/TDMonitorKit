import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 12. 生命周期

/// 前后台切换：维度刷新、热启动计时、面包屑、进后台落盘。
final class TDLifecycleFeature: TDMonitorFeature {

    static let name = "lifecycle"

    private let runtime: TDMonitorRuntime
    private var observers: [NSObjectProtocol] = []
    /// 进入前台的时刻，用于测量热启动（仅主线程访问）。
    private var foregroundEnteredAt: Date?

    init?(runtime: TDMonitorRuntime) {
        #if canImport(UIKit)
        self.runtime = runtime
        #else
        return nil
        #endif
    }

    func install() -> Bool {
        #if canImport(UIKit)
        let center = NotificationCenter.default
        let queue = OperationQueue.main
        let runtime = self.runtime

        let willEnter = center.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                           object: nil, queue: queue) { [weak self] _ in
            self?.foregroundEnteredAt = Date()
        }

        let active = center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                        object: nil, queue: queue) { [weak self] _ in
            guard let self = self else { return }
            runtime.context.foreground = true
            runtime.context.refreshNetworkType()
            runtime.service(TDResourceMonitor.self)?.setForeground(true)
            runtime.service(TDCrashBridge.self)?.addBreadcrumb(category: "app", message: "foreground", level: "info")

            // 热启动：进程仍在内存里，用户从后台切回。
            // 冷启动走 TDLaunchFeature，这里是「回到前台到可交互」的实测耗时。
            if let entered = self.foregroundEnteredAt {
                let durationMs = Date().timeIntervalSince(entered) * 1000
                self.foregroundEnteredAt = nil
                runtime.sink.enqueue(TDEvent(
                    kind: "mobile_metric",
                    fields: ["name": "app_launch", "durationMs": durationMs, "unit": "ms"],
                    attributes: ["type": "warm", "phase": "foreground_to_active"]
                ))
            }
            runtime.sink.flush()
        }

        let background = center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                            object: nil, queue: queue) { _ in
            runtime.context.foreground = false
            runtime.service(TDResourceMonitor.self)?.setForeground(false)
            let bridge = runtime.service(TDCrashBridge.self)
            bridge?.addBreadcrumb(category: "app", message: "background", level: "info")
            // 落盘轨迹与内存现场：进程随时可能在后台被杀
            bridge?.flushBreadcrumbs()
            runtime.service(TDCrashFeature.self)?
                .forwardPendingCrashReports(TDMonitor.hostCrashReportPaths?() ?? [])
            runtime.sink.flushInBackground()
        }

        let terminate = center.addObserver(forName: UIApplication.willTerminateNotification,
                                           object: nil, queue: queue) { _ in
            // 用户上划强杀或系统请求退出：标记后下次启动不会把它误判成 OOM。
            // 被 jetsam / 看门狗 SIGKILL 时这里不会被调用，正是这个差异
            // 让「强杀」与「系统杀」能够区分开。
            runtime.appState.markCleanExit(initiator: "will_terminate")
            TDMonitor.shared.stop()
        }

        observers = [willEnter, active, background, terminate]
        return true
        #else
        return false
        #endif
    }

    func uninstall() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }
}
