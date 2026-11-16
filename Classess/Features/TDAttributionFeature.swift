import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 1. 终止归因

/// 上一次会话是怎么死的。
///
/// **必须是第一个能力**：结论要随第一条 `session_start` 发出，晚于它就永远
/// 缺这一个维度（而 OOM / 看门狗恰恰是最需要历史上下文的指标）。
final class TDAttributionFeature: TDMonitorFeature {

    static let name = "attribution"

    private let runtime: TDMonitorRuntime

    init?(runtime: TDMonitorRuntime) {
        self.runtime = runtime
    }

    func install() -> Bool {
        // 后台任务计数钩子。不装它，background_task_timeout 归因分支是死代码。
        runtime.appState.installBackgroundTaskHook()

        if let verdict = runtime.appState.beginSession(
            sessionId: runtime.context.sessionId,
            appVersion: runtime.context.appVersion,
            buildNumber: runtime.context.buildNumber
        ) {
            runtime.provide(verdict)
            TDMonitorLog.record(
                "上次退出归因 \(verdict.attribution.rawValue) 置信度 \(verdict.confidence) "
                    + "证据=\(verdict.reasons.joined(separator: "; "))",
                level: "info")
        } else {
            TDMonitorLog.record("无上次会话现场（首次启动或现场已消费）", level: "info")
        }
        return true
    }

    func uninstall() {
        runtime.appState.markStopped()
    }
}

