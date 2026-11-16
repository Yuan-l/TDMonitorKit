import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 6. ANR / 卡顿

/// 主线程卡顿检测 + 真实栈采样。
///
/// 卡顿**进行中**每秒把时长落盘：被系统看门狗 SIGKILL 时进程直接消失，
/// 内存里的这条 ANR 一条都发不出去。没有进度落盘，最严重的那类卡顿
/// 恰好是数据完全空白的那一类。
final class TDANRFeature: TDMonitorFeature {

    static let name = "anr"
    static let requires = ["crash"]

    private let runtime: TDMonitorRuntime
    private let watchdog: TDHangWatchdog

    init?(runtime: TDMonitorRuntime) {
        guard let bridge = runtime.service(TDCrashBridge.self) else { return nil }
        self.runtime = runtime
        let appState = runtime.appState
        self.watchdog = TDHangWatchdog(
            thresholdMs: runtime.configuration.hangThresholdMs,
            reportThresholdMs: runtime.configuration.anrReportThresholdMs,
            // 致命推测阈值复用终止归因里的同一个常量，避免两处各写一个 8000
            // 之后悄悄漂移——那样"卡顿说 8s 致命、归因说 10s 致命"就没人能解释了。
            fatalThresholdMs: TDTerminationClassifier.watchdogHangThresholdMs,
            sampleIntervalMs: runtime.configuration.anrSampleIntervalMs,
            maxHangMs: runtime.configuration.maxHangMs,
            foregroundProvider: { appState.isForeground },
            onProgress: { elapsedMs in
                appState.recordHang(durationMs: elapsedMs)
            },
            onHang: { report in
                bridge.recordANR(durationMs: report.durationMs,
                                 stack: report.stack,
                                 thresholdMs: report.thresholdMs,
                                 sampleCount: report.sampleCount,
                                 frames: report.frames,
                                 screen: report.screen,
                                 reportThresholdMs: report.reportThresholdMs,
                                 severity: report.severity,
                                 blockType: report.blockType,
                                 framesDuring: report.framesDuring,
                                 foreground: report.foreground)
            }
        )
    }

    func install() -> Bool {
        watchdog.start()
        return true
    }

    func uninstall() {
        watchdog.stop()
    }
}

