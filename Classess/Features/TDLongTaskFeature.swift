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
        self.monitor = TDLongTaskMonitor(thresholdMs: runtime.configuration.longTaskThresholdMs) {
            duration, screen in
            bridge.recordLongTask(durationMs: duration, screen: screen)
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

