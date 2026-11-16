import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 9. 页面（加载耗时 + 渲染质量）

/// 页面加载耗时与页面级渲染质量共用同一处方法交换，因此合成一个能力单元。
///
/// 两个指标回答不同问题，缺一不可：
/// - `view_load`：这个页面多久能被看到（`willAppear→didAppear` / `load→didAppear`）
/// - `screen_render`：看到之后卡不卡（慢帧率 / 冻结帧率 / 卡顿时长占比）
final class TDScreenFeature: TDMonitorFeature {

    static let name = "screen"

    private let runtime: TDMonitorRuntime

    init?(runtime: TDMonitorRuntime) {
        guard runtime.configuration.viewLoadInstrumentation else { return nil }
        self.runtime = runtime
    }

    func install() -> Bool {
        let runtime = self.runtime
        let sliceSeconds = runtime.configuration.screenSliceSeconds

        TDViewControllerInstrumentation.shared.install { screen, appearMs, loadMs in
            guard Self.shouldSample(runtime.configuration.sampleRate) else { return }
            runtime.service(TDCrashBridge.self)?
                .recordViewLoad(screen: screen, durationMs: appearMs, renderMs: loadMs)
        }

        // 停留超过 sliceSeconds 也结算一片发出，保证长停留页面（首页、播放页）
        // 同样有数据，而不是「不走就永远没数据」。
        TDScreenFrameTracker.shared.configure(sliceSeconds: sliceSeconds) { report in
            guard Self.shouldSample(runtime.configuration.sampleRate) else { return }
            Self.report(report, sink: runtime.sink)
        }
        return true
    }

    func uninstall() {
        TDViewControllerInstrumentation.shared.uninstall()
        TDScreenFrameTracker.shared.unconfigure()
    }

    private static func shouldSample(_ rate: Double) -> Bool {
        rate >= 1 || Double.random(in: 0..<1) <= rate
    }

    private static func report(_ report: TDScreenRenderReport, sink: TDEventSink) {
        sink.enqueue(TDEvent(
            kind: "mobile_metric",
            fields: [
                "name": "screen_render",
                "durationMs": report.durationMs,
                "screen": report.screen,
            ],
            attributes: [
                "screen": report.screen,
                // slice = 页面还在，按窗口切的一片；final = 页面已消失
                "phase": report.phase,
                // 慢帧率：超过当前设备一帧预算 1.5 倍的帧占比
                "slowFrameRate": report.slowFrameRate,
                // 冻结帧率：单帧超过 700ms 的占比，用户能明确感知界面冻住
                "frozenFrameRate": report.frozenFrameRate,
                // 卡顿时长占比，对偶发长卡比帧占比更敏感
                "hitchRatio": report.hitchRatio,
                "hitchMs": report.hitchMs,
                "frameCount": report.frameCount,
                "slowFrames": report.slowFrames,
                "frozenFrames": report.frozenFrames,
                // 帧预算随设备刷新率变化，跨设备对比时必须带上这个维度
                "budgetMs": (report.frameBudget * 1000 * 100).rounded() / 100,
                "refreshRateHz": Int((1 / max(report.frameBudget, 1.0 / 240.0)).rounded()),
            ]
        ))
    }
}

