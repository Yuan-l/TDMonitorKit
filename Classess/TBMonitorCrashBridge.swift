import Foundation

/// Bridges the app's existing stability stack into the monitoring backend.
///
/// The host app already owns crash capture (TBCrashReporter). Registering a second
/// signal / NSException handler here would overwrite theirs, so this class exposes
/// ingest APIs instead, plus a lightweight "unclean termination" OOM heuristic.
/// Production deployments should additionally feed MetricKit diagnostics (see
/// TDMetricKitBridge) for symbolicated crash / hang reports.
final class TDCrashBridge {
    private static let maxBreadcrumbs = 100

    private let transport: TDTransport
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var breadcrumbs: [[String: Any]] = []

    init(transport: TDTransport) {
        self.transport = transport
        self.defaults = UserDefaults(suiteName: "com.truedepth.monitor") ?? .standard
    }

    // MARK: - Session & termination heuristics

    func start() {
        detectPreviousTermination()
        defaults.set(false, forKey: "td_session_clean")
        defaults.set(true, forKey: "td_has_launched")
        addBreadcrumb(category: "app", message: "session_start", level: "info")
        transport.enqueue(TDEvent(kind: "session_start"))
    }

    private func detectPreviousTermination() {
        let launchedBefore = defaults.bool(forKey: "td_has_launched")
        let clean = defaults.bool(forKey: "td_session_clean")
        let hadMemoryWarning = defaults.bool(forKey: "td_memory_warning")
        defer { defaults.set(false, forKey: "td_memory_warning") }
        guard launchedBefore, !clean else { return }

        if hadMemoryWarning {
            recordOOM(
                footprintMb: TDResourceSampler.memoryFootprintMB(),
                reason: "jetsam",
                message: "疑似 OOM / Jetsam 终止（上次会话收到内存警告且未正常结束）"
            )
        } else {
            transport.enqueue(TDEvent(
                kind: "mobile_metric",
                fields: ["name": "watchdog", "value": 1, "severity": "warning"],
                attributes: ["reason": "unclean_termination"]
            ))
        }
    }

    func markCleanExit() { defaults.set(true, forKey: "td_session_clean") }
    func markMemoryWarning() { defaults.set(true, forKey: "td_memory_warning") }

    func endSession(uptimeMs: Double) {
        transport.enqueue(TDEvent(kind: "session_end", fields: ["durationMs": uptimeMs]))
    }

    // MARK: - Breadcrumbs

    func addBreadcrumb(category: String, message: String, level: String = "info") {
        let crumb: [String: Any] = [
            "ts": TDISO8601.string(from: Date()),
            "category": category,
            "message": message,
            "level": level,
        ]
        lock.lock()
        breadcrumbs.append(crumb)
        if breadcrumbs.count > TDCrashBridge.maxBreadcrumbs { breadcrumbs.removeFirst() }
        lock.unlock()

        transport.enqueue(TDEvent(
            kind: "mobile_metric",
            fields: ["name": "breadcrumb", "value": 1],
            attributes: ["category": category, "message": message, "level": level]
        ))
    }

    func snapshotBreadcrumbs() -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return breadcrumbs
    }

    // MARK: - Stability events

    /// Call from the host crash reporter when it has a pending report to forward.
    func recordCrash(
        message: String,
        stack: String? = nil,
        signal: String? = nil,
        exceptionType: String? = nil,
        symbolicated: Bool = false,
        threads: [[String: Any]]? = nil,
        uptimeMs: Double? = nil
    ) {
        var fields: [String: Any] = ["message": message, "symbolicated": symbolicated]
        if let stack = stack { fields["stack"] = stack }
        if let signal = signal { fields["signal"] = signal }
        if let exceptionType = exceptionType { fields["exceptionType"] = exceptionType }
        if let threads = threads { fields["threads"] = threads }
        if let uptimeMs = uptimeMs { fields["uptimeMs"] = uptimeMs }
        fields["breadcrumbs"] = snapshotBreadcrumbs()
        transport.enqueue(TDEvent(kind: "native_crash", fields: fields))
        transport.flush()
    }

    func recordANR(durationMs: Double, stack: String? = nil, thresholdMs: Double? = nil) {
        var fields: [String: Any] = ["durationMs": durationMs, "type": "main_thread_block"]
        if let stack = stack { fields["stack"] = stack }
        if let thresholdMs = thresholdMs { fields["thresholdMs"] = thresholdMs }
        fields["breadcrumbs"] = snapshotBreadcrumbs()
        transport.enqueue(TDEvent(kind: "anr", fields: fields))
    }

    func recordOOM(footprintMb: Double?, reason: String, message: String? = nil) {
        var fields: [String: Any] = ["reason": reason]
        if let footprintMb = footprintMb { fields["footprintMb"] = footprintMb }
        if let message = message { fields["message"] = message }
        fields["breadcrumbs"] = snapshotBreadcrumbs()
        transport.enqueue(TDEvent(kind: "oom", fields: fields))
    }

    // MARK: - Network / view / custom metrics

    /// Feed one request. `url` is normalised (query stripped, numeric ids masked)
    /// so the backend's slow-API grouping stays low-cardinality.
    func recordNetwork(
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
        var attributes: [String: Any] = ["method": method, "status": status]
        if let dnsMs = dnsMs { attributes["dnsMs"] = dnsMs }
        if let tcpMs = tcpMs { attributes["tcpMs"] = tcpMs }
        if let tlsMs = tlsMs { attributes["tlsMs"] = tlsMs }
        if let ttfbMs = ttfbMs { attributes["ttfbMs"] = ttfbMs }
        if let errorCode = errorCode { attributes["errorCode"] = errorCode }
        transport.enqueue(TDEvent(
            kind: "mobile_metric",
            fields: ["name": "network_phase", "durationMs": durationMs,
                     "severity": success ? "info" : "warning"],
            attributes: attributes
        ))

        var apiFields: [String: Any] = [
            "url": TDCrashBridge.sanitizedURL(url), "method": method, "status": status,
            "durationMs": durationMs, "success": success,
        ]
        if let requestBytes = requestBytes { apiFields["requestBytes"] = requestBytes }
        if let responseBytes = responseBytes { apiFields["responseBytes"] = responseBytes }
        transport.enqueue(TDEvent(kind: "api_metric", fields: apiFields))

        if !success {
            transport.enqueue(TDEvent(
                kind: "mobile_metric",
                fields: ["name": "network_error", "value": 1, "severity": "warning"],
                attributes: ["url": TDCrashBridge.sanitizedURL(url), "method": method,
                             "status": status, "errorCode": errorCode ?? 0]
            ))
        }
    }

    func recordViewLoad(screen: String, durationMs: Double, renderMs: Double? = nil) {
        var attributes: [String: Any] = [:]
        if let renderMs = renderMs { attributes["renderMs"] = renderMs }
        transport.enqueue(TDEvent(
            kind: "mobile_metric",
            fields: ["name": "view_load", "durationMs": durationMs, "screen": screen],
            attributes: attributes
        ))
    }

    func recordCustom(name: String, value: Double? = nil, unit: String? = nil,
                      attributes: [String: Any] = [:]) {
        var fields: [String: Any] = ["name": "custom_metric"]
        if let value = value { fields["value"] = value }
        if let unit = unit { fields["unit"] = unit }
        var merged = attributes
        merged["metric"] = name
        transport.enqueue(TDEvent(kind: "mobile_metric", fields: fields, attributes: merged))
    }

    static func sanitizedURL(_ raw: String) -> String {
        guard var components = URLComponents(string: raw) else { return raw }
        components.query = nil
        components.fragment = nil
        let parts = components.path.split(separator: "/").map { part -> String in
            if Int(part) != nil || part.count == 36 { return ":id" }
            return String(part)
        }
        components.path = "/" + parts.joined(separator: "/")
        return components.string ?? raw
    }
}
