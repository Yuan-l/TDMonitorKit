import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 3. 启动分段

/// 冷启动 / 热启动分段耗时。依赖 `markFirstFrame()`，未调用时 3 秒兜底结算。
final class TDLaunchFeature: TDMonitorFeature {

    static let name = "launch"

    private let runtime: TDMonitorRuntime
    private let recorder: TDLaunchRecorder

    init?(runtime: TDMonitorRuntime) {
        self.runtime = runtime
        let sink = runtime.sink
        self.recorder = TDLaunchRecorder { fields in
            var payload = fields
            let durationMs = payload.removeValue(forKey: "durationMs") as? Double ?? 0
            var attributes = payload
            attributes["phase"] = "launch_to_first_frame"
            sink.enqueue(TDEvent(
                kind: "mobile_metric",
                fields: ["name": "app_launch", "durationMs": durationMs, "unit": "ms"],
                attributes: attributes
            ))
        }
    }

    func install() -> Bool {
        runtime.provide(recorder)
        recorder.markDidFinishLaunching()
        // 3 秒内宿主仍未标记首帧时兜底结算，保证指标不缺失。
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak recorder] in
            recorder?.forceEmitIfNeeded()
        }
        return true
    }

    func uninstall() {
        recorder.forceEmitIfNeeded()
    }
}

