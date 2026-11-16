import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 11. MetricKit

/// 系统权威诊断源。**只有 iOS 14+ 存在**。
///
/// iOS 13 上这个能力整体不存在：`init?` 不会被调用，注册表跳过，
/// 其余能力全部正常。这是版本门槛的架构级处理——不是运行时到处
/// `if #available` 打补丁，而是能力本身的有无。
@available(iOS 14.0, *)
final class TDMetricKitFeature: TDMonitorFeature {

    static let name = "metrickit"
    static let requires = ["crash"]

    private let runtime: TDMonitorRuntime
    private let exit: TDExitDiagnostics
    private let bridge: TDMetricKitBridge

    init?(runtime: TDMonitorRuntime) {
        self.runtime = runtime
        self.exit = TDExitDiagnostics(sink: runtime.sink)
        self.bridge = TDMetricKitBridge(sink: runtime.sink, exitDiagnostics: exit)
    }

    func install() -> Bool {
        true
    }

    func uninstall() {
        bridge.stop()
    }
}

