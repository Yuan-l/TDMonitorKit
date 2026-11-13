import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Public facade of TDMonitorKit.
///
/// One call in `application(_:didFinishLaunchingWithOptions:)` wires up:
/// session identity, bounded offline queue, FPS / jank / hang / resource
/// collectors, cold-start timing, MetricKit diagnostics, and bridging of the
/// host app's existing crash reporter files.
///
/// The kit deliberately does NOT install its own signal / NSException handlers.
/// The host already owns crash capture; registering a second handler would
/// silently replace theirs.
public final class TDMonitor {

    public static let shared = TDMonitor()

    private let lock = NSLock()
    private var configuration: TDMonitorConfiguration?
    private var context: TDContext?
    private var transport: TDTransport?
    private var bridge: TDCrashBridge?
    private var collectors: TDCollectors?
    private var metricKitBridge: AnyObject?
    private var started = false
    private var sessionStartedAt: Date?
    private var lifecycleObservers: [NSObjectProtocol] = []

    /// Captured when the class is first touched (i.e. very early in app launch),
    /// used as the origin of the cold-start measurement.
    private let processStart = ProcessInfo.processInfo.systemUptime

    private init() {}

    public var isEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return started
    }

    public var sessionId: String? {
        lock.lock(); defer { lock.unlock() }
        return context?.sessionId
    }

    /// Recent SDK diagnostics for the host app to surface (bounded, in-memory).
    public var diagnostics: [String] { TDMonitorLog.snapshot() }

    // MARK: - Lifecycle

    /// Loads `TDMonitor.plist` from the host bundle. Environment variable
    /// `TD_MONITOR_API_KEY` overrides the plist key (Xcode scheme / CI).
    /// Returns `false` and stays completely inert when configuration is missing —
    /// an unconfigured build must never crash or emit traffic.
    @discardableResult
    public func start(configuration: TDMonitorConfiguration? = TDMonitorConfiguration.load()) -> Bool {
        lock.lock()
        if started { lock.unlock(); return true }
        guard let configuration, !configuration.apiKey.isEmpty else {
            lock.unlock()
            TDMonitorLog.record("未配置 apiKey（TDMonitor.plist / TD_MONITOR_API_KEY），监控保持关闭", level: "warning")
            return false
        }
        let context = TDContext(config: configuration)
        let transport = TDTransport(config: configuration, context: context)
        let bridge = TDCrashBridge(transport: transport)
        let collectors = TDCollectors(config: configuration, transport: transport)
        self.configuration = configuration
        self.context = context
        self.transport = transport
        self.bridge = bridge
        self.collectors = collectors
        self.sessionStartedAt = Date()
        self.started = true
        lock.unlock()

        transport.start()
        bridge.start()
        collectors.onMemoryWarning = { [weak self] in self?.bridge?.markMemoryWarning() }
        if configuration.autoCollect { collectors.start() }
        observeLifecycle()
        recordLaunch()
        attachMetricKit(transport: transport)

        // Forward crash reports captured on a previous launch by the host reporter.
        forwardPendingCrashReports(TDMonitor.hostCrashReportPaths?() ?? [])

        #if DEBUG
        if ProcessInfo.processInfo.environment["TD_MONITOR_SMOKE"] == "1" {
            emitSampleEvents()
        }
        #endif
        return true
    }

    /// Hook for the host app: pass `TBCrashReporter.allCrashLogPaths` (or any
    /// list of JSON crash-report files) without creating a pod dependency.
    public static var hostCrashReportPaths: (() -> [String])?

    public func flush() { transport?.flush() }
    public func flushInBackground() { transport?.flushInBackground() }

    /// Call on explicit termination only. Background suspension is intentionally
    /// NOT marked clean, so a Jetsam kill can still be detected next launch.
    public func stop() {
        guard isEnabled else { return }
        bridge?.markCleanExit()
        if let started = sessionStartedAt {
            bridge?.endSession(uptimeMs: Date().timeIntervalSince(started) * 1000)
        }
        collectors?.stop()
        transport?.flushInBackground()
    }

    // MARK: - Dimensions

    public func setUserId(_ userId: String?) { context?.userId = userId }
    public func refreshNetworkType() { context?.refreshNetworkType() }

    // MARK: - Manual instrumentation

    public func breadcrumb(_ category: String, _ message: String, level: String = "info") {
        bridge?.addBreadcrumb(category: category, message: message, level: level)
    }

    public func recordCrash(
        message: String,
        stack: String? = nil,
        signal: String? = nil,
        exceptionType: String? = nil,
        symbolicated: Bool = false,
        threads: [[String: Any]]? = nil,
        uptimeMs: Double? = nil
    ) {
        bridge?.recordCrash(message: message, stack: stack, signal: signal,
                            exceptionType: exceptionType, symbolicated: symbolicated,
                            threads: threads, uptimeMs: uptimeMs)
    }

    public func recordANR(durationMs: Double, stack: String? = nil, thresholdMs: Double? = nil) {
        bridge?.recordANR(durationMs: durationMs, stack: stack, thresholdMs: thresholdMs)
    }

    public func recordOOM(footprintMb: Double?, reason: String = "jetsam", message: String? = nil) {
        bridge?.recordOOM(footprintMb: footprintMb, reason: reason, message: message)
    }

    public func recordNetwork(
        url: String,
        method: String,
        status: Int,
        durationMs: Double,
        success: Bool,
        dnsMs: Double? = nil,
        tcpMs: Double? = nil,
        tlsMs: Double? = nil,
        ttfbMs: Double? = nil,
        requestBytes: Int64? = nil,
        responseBytes: Int64? = nil,
        errorCode: Int? = nil
    ) {
        bridge?.recordNetwork(url: url, method: method, status: status, durationMs: durationMs,
                              success: success, dnsMs: dnsMs, tcpMs: tcpMs, tlsMs: tlsMs,
                              ttfbMs: ttfbMs, requestBytes: requestBytes,
                              responseBytes: responseBytes, errorCode: errorCode)
    }

    public func recordViewLoad(screen: String, durationMs: Double, renderMs: Double? = nil) {
        bridge?.recordViewLoad(screen: screen, durationMs: durationMs, renderMs: renderMs)
    }

    public func recordCustom(_ name: String, value: Double? = nil, unit: String? = nil,
                             attributes: [String: Any] = [:]) {
        bridge?.recordCustom(name: name, value: value, unit: unit, attributes: attributes)
    }

    // MARK: - Host crash reporter bridge

    /// Parses the host reporter's on-disk JSON and forwards each report as a
    /// `native_crash`. Already-forwarded ids are remembered so relaunching the
    /// app does not duplicate crashes in the backend.
    @discardableResult
    public func forwardPendingCrashReports(_ paths: [String]) -> Int {
        guard let transport, !paths.isEmpty else { return 0 }
        let defaults = UserDefaults(suiteName: "com.truedepth.monitor") ?? .standard
        var forwarded = Set<String>(defaults.stringArray(forKey: "td_forwarded_crash_ids") ?? [])
        var count = 0
        for path in paths.prefix(100) {
            let url = URL(fileURLWithPath: path)
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let reportId = json["id"] as? String ?? url.lastPathComponent
            if forwarded.contains(reportId) { continue }

            let reason = json["exceptionReason"] as? String
            let name = json["exceptionName"] as? String
            let type = json["type"] as? String ?? "unknown"
            let message = reason ?? name ?? type
            let frames = json["stack"] as? [String]
            let crumbs = (json["breadcrumbs"] as? [[String: Any]] ?? []).compactMap { raw -> [String: Any]? in
                guard let event = raw["event"] as? String else { return nil }
                return ["category": "host", "message": event, "level": "info"]
            }
            var fields: [String: Any] = [
                "message": message,
                "symbolicated": false,
                "breadcrumbs": crumbs,
            ]
            if let frames { fields["stack"] = frames.joined(separator: "\n") }
            if let signal = json["signal"] as? String { fields["signal"] = signal }
            if let name { fields["exceptionType"] = name }
            let timestamp = json["timestamp"] as? Double
            let ts = timestamp.flatMap { Date(timeIntervalSince1970: $0) } ?? Date()
            let context = (json["context"] as? [String: String]) ?? [:]
            transport.enqueue(TDEvent(kind: "native_crash", fields: fields,
                                      attributes: ["source": "TBCrashReporter", "hostContext": context],
                                      ts: ts))
            forwarded.insert(reportId)
            count += 1
        }
        if count > 0 {
            defaults.set(Array(forwarded.suffix(500)), forKey: "td_forwarded_crash_ids")
            transport.flush()
        }
        return count
    }

    // MARK: - Internals

    private func recordLaunch() {
        let elapsed = max(0, (ProcessInfo.processInfo.systemUptime - processStart) * 1000)
        transport?.enqueue(TDEvent(
            kind: "mobile_metric",
            fields: ["name": "app_launch", "durationMs": elapsed, "unit": "ms"],
            attributes: ["type": "cold", "phase": "didFinishLaunching"]
        ))
    }

    private func attachMetricKit(transport: TDTransport) {
        #if canImport(MetricKit)
        if #available(iOS 14.0, *) {
            metricKitBridge = TDMetricKitBridge(transport: transport)
        }
        #endif
    }

    private func observeLifecycle() {
        #if canImport(UIKit)
        let center = NotificationCenter.default
        let queue = OperationQueue.main
        let active = center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                        object: nil, queue: queue) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.context?.foreground = true
            self.lock.unlock()
            self.context?.refreshNetworkType()
            self.breadcrumb("app", "foreground", level: "info")
            self.flush()
        }
        let background = center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                            object: nil, queue: queue) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.context?.foreground = false
            self.lock.unlock()
            self.breadcrumb("app", "background", level: "info")
            self.forwardPendingCrashReports(TDMonitor.hostCrashReportPaths?() ?? [])
            self.flushInBackground()
        }
        let terminate = center.addObserver(forName: UIApplication.willTerminateNotification,
                                           object: nil, queue: queue) { [weak self] _ in
            self?.stop()
        }
        lock.lock()
        lifecycleObservers = [active, background, terminate]
        lock.unlock()
        #endif
    }

    #if DEBUG
    /// `TD_MONITOR_SMOKE=1` in the Xcode scheme emits one event per APM signal.
    /// Lets you validate wiring + the stability dashboard without crashing the app.
    private func emitSampleEvents() {
        guard let transport else { return }
        let metrics: [(String, Double, String)] = [
            ("fps", 58.4, "fps"), ("frame_jank", 3, "frames"),
            ("memory", 182.6, "MB"), ("cpu", 21.3, "%"),
            ("battery", 76, "%"), ("thermal", 1, "state"),
            ("disk", 4096, "MB"), ("thread_count", 24, "count"),
            ("fd_count", 128, "count"), ("network_traffic", 2048, "bytes"),
            ("custom_metric", 1, "count"),
        ]
        for (name, value, unit) in metrics {
            transport.enqueue(TDEvent(kind: "mobile_metric",
                                      fields: ["name": name, "value": value, "unit": unit]))
        }
        transport.enqueue(TDEvent(kind: "mobile_metric",
                                  fields: ["name": "long_task", "durationMs": 320.0]))
        transport.enqueue(TDEvent(kind: "mobile_metric",
                                  fields: ["name": "network_phase", "durationMs": 186.0],
                                  attributes: ["dnsMs": 12, "tcpMs": 34, "tlsMs": 51, "ttfbMs": 120]))
        transport.enqueue(TDEvent(kind: "mobile_metric",
                                  fields: ["name": "view_load", "durationMs": 240.0, "screen": "Home"]))
        recordNetwork(url: "https://example.com/api/v1/orders/12345?debug=1", method: "GET",
                      status: 200, durationMs: 186, success: true, dnsMs: 12, tcpMs: 34,
                      tlsMs: 51, ttfbMs: 120, responseBytes: 2048)
        recordNetwork(url: "https://example.com/api/v1/pay", method: "POST",
                      status: 504, durationMs: 3012, success: false, errorCode: -1001)
        recordANR(durationMs: 820, thresholdMs: 250)
        recordOOM(footprintMb: 1180, reason: "jetsam")
        recordCrash(message: "NSInvalidArgumentException: unrecognized selector sent to instance",
                    stack: "0 TrueDepthDemo2 0x0000000102a4c1d8 -[TBFinanceHomeViewController reload:]",
                    exceptionType: "NSInvalidArgumentException")
        transport.flush()
        TDMonitorLog.record("smoke events emitted")
    }
    #endif
}
