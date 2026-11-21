import Foundation

#if canImport(MetricKit)
import MetricKit

/// Official OS-level diagnostics. These complement (never replace) the host's
/// crash reporter: MetricKit delivers symbolication-ready crash stacks, hang
/// diagnostics and CPU / disk-write exception reports on a daily cadence, and
/// is the only reliable source for OOM-adjacent Jetsam information on iOS.
@available(iOS 14.0, *)
final class TDMetricKitBridge: NSObject, MXMetricManagerSubscriber {

    private let sink: TDEventSink
    private let exitDiagnostics: TDExitDiagnostics?
    private var subscribed = true

    init(sink: TDEventSink, exitDiagnostics: TDExitDiagnostics? = nil) {
        self.sink = sink
        self.exitDiagnostics = exitDiagnostics
        super.init()
        MXMetricManager.shared.add(self)
    }

    /// 取消订阅。MetricKit 的订阅是强引用，不显式摘掉会在 SDK 停止后
    /// 继续往里投递 payload。
    func stop() {
        guard subscribed else { return }
        subscribed = false
        MXMetricManager.shared.remove(self)
    }

    deinit { if subscribed { MXMetricManager.shared.remove(self) } }

    // MARK: - Diagnostics (daily, iOS 14+)

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        // 记录真实投递：用户关闭「共享 iPhone 分析」后这里永远不会被调用，
        // 计数为 0 的设备就是无覆盖设备，见 TDMetricKitCoverage。
        if !payloads.isEmpty { TDMetricKitCoverage.recordDelivery() }
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                var fields: [String: Any] = [
                    "message": crash.terminationReason ?? "MetricKit crash diagnostic",
                    "stack": Self.stackString(crash.callStackTree),
                    "symbolicated": false,
                ]
                if let signal = crash.signal?.stringValue { fields["signal"] = signal }
                if let exceptionType = crash.exceptionType?.stringValue { fields["exceptionType"] = exceptionType }
                if let exceptionCodes = crash.exceptionCode?.stringValue { fields["exceptionCodes"] = exceptionCodes }
                sink.enqueue(TDEvent(
                    kind: "native_crash",
                    fields: fields,
                    attributes: ["source": "metrickit", "applicationVersion": crash.applicationVersion]
                ))
            }

            for hang in payload.hangDiagnostics ?? [] {
                let ms = hang.hangDuration.converted(to: .milliseconds).value
                // hang 的 callStackTree 是系统采的权威卡顿栈（系统帧已带 UUID/offset）。
                // 之前这里只上报了时长、把栈丢了——和同函数里 crash(:44)/cpuException(:72)
                // 都取 stackString 的做法不一致，等于系统把最有价值的数据送到手边却扔掉。
                // stack 是 anrEventSchema 的顶层白名单字段，放 fields 不会被服务端剥掉；
                // 服务端 buildCrashFrames 见 '{' 开头会走 parseMetricKitStack + dSYM 回填。
                sink.enqueue(TDEvent(
                    kind: "anr",
                    fields: ["durationMs": ms, "type": "watchdog",
                             "stack": Self.stackString(hang.callStackTree)],
                    attributes: ["source": "metrickit",
                                 "applicationVersion": hang.applicationVersion,
                                 "symbolicated": false]
                ))
            }

            for exception in payload.cpuExceptionDiagnostics ?? [] {
                sink.enqueue(TDEvent(
                    kind: "mobile_metric",
                    fields: ["name": "cpu", "value": exception.totalCPUTime.converted(to: .seconds).value,
                             "unit": "s", "severity": "warning"],
                    attributes: ["source": "metrickit", "reason": "cpu_exception",
                                 "stack": Self.stackString(exception.callStackTree)]
                ))
            }

            for exception in payload.diskWriteExceptionDiagnostics ?? [] {
                sink.enqueue(TDEvent(
                    kind: "mobile_metric",
                    fields: ["name": "disk", "value": exception.totalWritesCaused.converted(to: .megabytes).value,
                             "unit": "MB", "severity": "warning"],
                    attributes: ["source": "metrickit", "reason": "excessive_disk_writes"]
                ))
            }
        }
        sink.flush()
    }

    // MARK: - Aggregate metrics (daily, iOS 13+)

    func didReceive(_ payloads: [MXMetricPayload]) {
        if !payloads.isEmpty { TDMetricKitCoverage.recordDelivery() }
        for payload in payloads {
            // OOM / 看门狗终止的权威来源：累计退出原因计数，只上报增量。
            if let exit = payload.applicationExitMetrics {
                exitDiagnostics?.handle(exit)
            }
            if let memory = payload.memoryMetrics?.peakMemoryUsage {
                sink.enqueue(TDEvent(
                    kind: "mobile_metric",
                    fields: ["name": "memory", "value": memory.converted(to: .megabytes).value, "unit": "MB"],
                    attributes: ["source": "metrickit", "metric": "peakMemoryUsage",
                                 "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"]
                ))
            }
            if let cpu = payload.cpuMetrics?.cumulativeCPUTime {
                sink.enqueue(TDEvent(
                    kind: "mobile_metric",
                    fields: ["name": "cpu", "value": cpu.converted(to: .seconds).value, "unit": "s"],
                    attributes: ["source": "metrickit", "metric": "cumulativeCPUTime"]
                ))
            }
            // Cold/warm launch is measured directly at runtime in TDMonitor.recordLaunch();
            // MXAppLaunchMetric only exposes a histogram without an average accessor, so
            // mixing it in here would double-count and distort the P95.
        }
        sink.flush()
    }

    // MARK: - Helpers

    private static func stackString(_ tree: MXCallStackTree) -> String {
        let data = tree.jsonRepresentation()
        let text = String(data: data, encoding: .utf8) ?? ""
        return String(text.prefix(60_000))
    }
}
#endif
