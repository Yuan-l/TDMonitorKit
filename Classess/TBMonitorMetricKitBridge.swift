import Foundation

#if canImport(MetricKit)
import MetricKit

/// Official OS-level diagnostics. These complement (never replace) the host's
/// crash reporter: MetricKit delivers symbolication-ready crash stacks, hang
/// diagnostics and CPU / disk-write exception reports on a daily cadence, and
/// is the only reliable source for OOM-adjacent Jetsam information on iOS.
@available(iOS 14.0, *)
final class TDMetricKitBridge: NSObject, MXMetricManagerSubscriber {

    private let transport: TDTransport
    private let exitDiagnostics: TDExitDiagnostics?

    init(transport: TDTransport, exitDiagnostics: TDExitDiagnostics? = nil) {
        self.transport = transport
        self.exitDiagnostics = exitDiagnostics
        super.init()
        MXMetricManager.shared.add(self)
    }

    deinit { MXMetricManager.shared.remove(self) }

    // MARK: - Diagnostics (daily, iOS 14+)

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
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
                transport.enqueue(TDEvent(
                    kind: "native_crash",
                    fields: fields,
                    attributes: ["source": "MetricKit", "applicationVersion": crash.applicationVersion]
                ))
            }

            for hang in payload.hangDiagnostics ?? [] {
                let ms = hang.hangDuration.converted(to: .milliseconds).value
                transport.enqueue(TDEvent(
                    kind: "anr",
                    fields: ["durationMs": ms, "type": "watchdog"],
                    attributes: ["source": "MetricKit", "applicationVersion": hang.applicationVersion]
                ))
            }

            for exception in payload.cpuExceptionDiagnostics ?? [] {
                transport.enqueue(TDEvent(
                    kind: "mobile_metric",
                    fields: ["name": "cpu", "value": exception.totalCPUTime.converted(to: .seconds).value,
                             "unit": "s", "severity": "warning"],
                    attributes: ["source": "MetricKit", "reason": "cpu_exception",
                                 "stack": Self.stackString(exception.callStackTree)]
                ))
            }

            for exception in payload.diskWriteExceptionDiagnostics ?? [] {
                transport.enqueue(TDEvent(
                    kind: "mobile_metric",
                    fields: ["name": "disk", "value": exception.totalWritesCaused.converted(to: .megabytes).value,
                             "unit": "MB", "severity": "warning"],
                    attributes: ["source": "MetricKit", "reason": "excessive_disk_writes"]
                ))
            }
        }
        transport.flush()
    }

    // MARK: - Aggregate metrics (daily, iOS 13+)

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            // OOM / 看门狗终止的权威来源：累计退出原因计数，只上报增量。
            if let exit = payload.applicationExitMetrics {
                exitDiagnostics?.handle(exit)
            }
            if let memory = payload.memoryMetrics?.peakMemoryUsage {
                transport.enqueue(TDEvent(
                    kind: "mobile_metric",
                    fields: ["name": "memory", "value": memory.converted(to: .megabytes).value, "unit": "MB"],
                    attributes: ["source": "MetricKit", "metric": "peakMemoryUsage",
                                 "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"]
                ))
            }
            if let cpu = payload.cpuMetrics?.cumulativeCPUTime {
                transport.enqueue(TDEvent(
                    kind: "mobile_metric",
                    fields: ["name": "cpu", "value": cpu.converted(to: .seconds).value, "unit": "s"],
                    attributes: ["source": "MetricKit", "metric": "cumulativeCPUTime"]
                ))
            }
            // Cold/warm launch is measured directly at runtime in TDMonitor.recordLaunch();
            // MXAppLaunchMetric only exposes a histogram without an average accessor, so
            // mixing it in here would double-count and distort the P95.
        }
        transport.flush()
    }

    // MARK: - Helpers

    private static func stackString(_ tree: MXCallStackTree) -> String {
        let data = tree.jsonRepresentation()
        let text = String(data: data, encoding: .utf8) ?? ""
        return String(text.prefix(60_000))
    }
}
#endif
