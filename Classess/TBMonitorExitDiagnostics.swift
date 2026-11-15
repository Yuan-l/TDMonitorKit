import Foundation

#if canImport(MetricKit)
import MetricKit

/// OOM / Watchdog 归因。
///
/// 早期实现靠「上次会话没标记干净退出」推断，用户从后台上划强杀也会被算成 OOM，
/// 数据不可用。这里改用系统权威来源：`MXAppExitMetric` 明确区分
/// 内存超限退出、App Watchdog 退出、内存压力退出、异常退出，且是累计计数，
/// 只用增量上报，重启不会重复计数。
///
/// 首次运行时只记录基线，不上报历史累计值——否则装上新版本的当天会把
/// 用户过去几个月的退出记录全部算到当前版本头上。
@available(iOS 14.0, *)
final class TDExitDiagnostics {

    private static let defaultsKey = "td_exit_counters"

    private let sink: TDEventSink
    private let defaults: UserDefaults

    init(sink: TDEventSink) {
        self.sink = sink
        self.defaults = UserDefaults(suiteName: "com.truedepth.monitor") ?? .standard
    }

    func handle(_ metric: MXAppExitMetric) {
        let state = TDAppStateTracker.shared.current()
        let stored = (defaults.dictionary(forKey: Self.defaultsKey) as? [String: Int]) ?? [:]
        let isBaseline = stored.isEmpty
        var updated = stored

        let foreground = metric.foregroundExitData
        let background = metric.backgroundExitData

        let memoryLimit = Int(foreground.cumulativeMemoryResourceLimitExitCount)
            + Int(background.cumulativeMemoryResourceLimitExitCount)
        let memoryPressure = Int(background.cumulativeMemoryPressureExitCount)
        let watchdog = Int(foreground.cumulativeAppWatchdogExitCount)
            + Int(background.cumulativeAppWatchdogExitCount)

        let memoryDelta = delta(current: memoryLimit, key: "memoryLimit", stored: stored, updated: &updated)
        let pressureDelta = delta(current: memoryPressure, key: "memoryPressure", stored: stored, updated: &updated)
        let watchdogDelta = delta(current: watchdog, key: "watchdog", stored: stored, updated: &updated)

        defaults.set(updated, forKey: Self.defaultsKey)
        guard !isBaseline else { return }

        if memoryDelta > 0 || pressureDelta > 0 {
            var fields: [String: Any] = [
                "reason": memoryDelta > 0 ? "jetsam" : "memory_warning",
                "message": memoryDelta > 0
                    ? "内存超限被系统终止（MetricKit memoryResourceLimit，\(memoryDelta) 次）"
                    : "后台因内存压力被回收（MetricKit memoryPressure，\(pressureDelta) 次）",
            ]
            if let footprint = state?.lastFootprintMb { fields["footprintMb"] = footprint }
            if let limit = state?.limitMb { fields["limitMb"] = limit }
            sink.enqueue(TDEvent(
                kind: "oom",
                fields: fields,
                attributes: [
                    // source 必须与启发式路径区分：同一个退出可能被两条路径各报
                    // 一次（MetricKit 次日批量 + 启发式下次启动即知）。后端按
                    // source 分组统计，两者计数差可反推 MetricKit 的真实覆盖率。
                    "source": "metrickit",
                    "memoryLimitExits": memoryDelta,
                    "memoryPressureExits": pressureDelta,
                    "lastForegroundFootprintMb": state?.lastFootprintMb ?? 0,
                    "lastForeground": state?.foreground ?? false,
                    "lastScreen": state?.lastScreen ?? "-",
                    // 与启发式路径带同一份证据。
                    //
                    // 之前这里只有单点（lastForegroundFootprintMb / lastScreen），
                    // 而启发式路径带整条曲线——同一个 `oom` 事件，按 source 分开
                    // 看会发现可查性差一半：MetricKit 更权威，反而证据更少。
                    "footprintSeries": state?.footprintSeries ?? [],
                    "timeline": state?.timelineEntries.map(\.asJSON) ?? [],
                ]
            ))
        }

        if watchdogDelta > 0 {
            sink.enqueue(TDEvent(
                kind: "mobile_metric",
                fields: ["name": "watchdog", "value": Double(watchdogDelta), "severity": "error"],
                attributes: ["source": "metrickit", "reason": "app_watchdog_termination",
                             "applicationVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"]
            ))
        }
        sink.flush()
    }

    /// 累计计数 → 本次增量。首次见到某个 key 时以当前值为基线，返回 0。
    private func delta(current: Int, key: String, stored: [String: Int],
                       updated: inout [String: Int]) -> Int {
        let previous = stored[key] ?? current
        updated[key] = current
        return max(0, current - previous)
    }
}
#endif
