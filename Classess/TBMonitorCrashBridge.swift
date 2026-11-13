import Foundation

/// 宿主稳定性栈 → 监控后端的桥。
///
/// 宿主（TBCrashReporter）已经独占 signal / NSException 处理器，这里**绝不注册**
/// 第二个崩溃处理器（会覆盖宿主的实现）。SDK 的职责是：
/// - 采集并落盘面包屑（崩溃是下次启动才补发的，内存里的轨迹必然丢失）
/// - 把宿主落盘的 JSON 转成带结构化栈、镜像 UUID、真实轨迹的 `native_crash`
/// - 采集系统无法直接上报的 OOM / 异常退出归因
final class TDCrashBridge {

    private static let maxBreadcrumbs = 100

    private let transport: TDTransport
    private let defaults: UserDefaults
    private let breadcrumbs = TDBreadcrumbStore()
    private let lock = NSLock()

    /// 上次会话的面包屑。崩溃补发发生在新会话启动时，只有这份轨迹是有效的。
    private(set) var previousSessionBreadcrumbs: [[String: Any]] = []

    init(transport: TDTransport) {
        self.transport = transport
        self.defaults = UserDefaults(suiteName: "com.truedepth.monitor") ?? .standard
    }

    // MARK: - 会话与终止归因

    func start() {
        previousSessionBreadcrumbs = breadcrumbs.loadPreviousSession()
        detectPreviousTermination()
        breadcrumbs.resetForNewSession()
        defaults.set(false, forKey: "td_session_clean")
        defaults.set(true, forKey: "td_has_launched")
        addBreadcrumb(category: "app", message: "session_start", level: "info")
        transport.enqueue(TDEvent(kind: "session_start"))
    }

    /// 上一次进程没有走 `stop()`：可能是崩溃、OOM、看门狗或用户强杀。
    /// 这里只做**证据留存**，不冒充结论——真正的 OOM / Watchdog 由 MetricKit
    /// 的退出原因计数确认（见 TDExitDiagnostics）。
    private func detectPreviousTermination() {
        let launchedBefore = defaults.bool(forKey: "td_has_launched")
        let clean = defaults.bool(forKey: "td_session_clean")
        let hadMemoryWarning = defaults.bool(forKey: "td_memory_warning")
        defer { defaults.set(false, forKey: "td_memory_warning") }
        guard launchedBefore, !clean else {
            TDTerminationSnapshot.clear()
            return
        }

        let snapshot = TDTerminationSnapshot.read()
        if hadMemoryWarning {
            recordOOM(footprintMb: snapshot?.footprintMb,
                      reason: "memory_warning",
                      message: "上次会话收到内存警告后未正常结束，疑似内存压力终止",
                      limitMb: snapshot?.limitMb,
                      breadcrumbs: previousSessionBreadcrumbs)
        } else {
            transport.enqueue(TDEvent(
                kind: "mobile_metric",
                fields: ["name": "watchdog", "value": 1, "severity": "info"],
                attributes: [
                    "reason": "unclean_exit",
                    "lastFootprintMb": snapshot?.footprintMb ?? 0,
                    "lastForeground": snapshot?.foreground ?? false,
                ]
            ))
        }
        TDTerminationSnapshot.clear()
    }

    func markCleanExit() {
        defaults.set(true, forKey: "td_session_clean")
        breadcrumbs.flush()
    }

    func markMemoryWarning() { defaults.set(true, forKey: "td_memory_warning") }

    func flushBreadcrumbs() { breadcrumbs.flush() }

    func endSession(uptimeMs: Double) {
        transport.enqueue(TDEvent(kind: "session_end", fields: ["durationMs": uptimeMs]))
    }

    // MARK: - 面包屑

    func addBreadcrumb(category: String, message: String, level: String = "info") {
        breadcrumbs.append(category: category, message: message, level: level)
        transport.enqueue(TDEvent(
            kind: "mobile_metric",
            fields: ["name": "breadcrumb", "value": 1],
            attributes: ["category": category, "message": String(message.prefix(200)), "level": level]
        ))
    }

    func snapshotBreadcrumbs() -> [[String: Any]] {
        let current = breadcrumbs.current()
        return current.isEmpty ? previousSessionBreadcrumbs : current
    }

    // MARK: - 稳定性事件

    func recordCrash(
        message: String,
        stack: String? = nil,
        signal: String? = nil,
        exceptionType: String? = nil,
        symbolicated: Bool = false,
        threads: [[String: Any]]? = nil,
        uptimeMs: Double? = nil,
        frames: [[String: Any]]? = nil,
        breadcrumbs: [[String: Any]]? = nil,
        extraAttributes: [String: Any] = [:]
    ) {
        var fields: [String: Any] = ["message": message, "symbolicated": symbolicated]
        if let stack = stack { fields["stack"] = stack }
        if let signal = signal { fields["signal"] = signal }
        if let exceptionType = exceptionType { fields["exceptionType"] = exceptionType }
        if let threads = threads { fields["threads"] = threads }
        if let uptimeMs = uptimeMs { fields["uptimeMs"] = uptimeMs }
        let trail = breadcrumbs ?? snapshotBreadcrumbs()
        if !trail.isEmpty { fields["breadcrumbs"] = trail }

        var attributes = extraAttributes
        if let frames = frames, !frames.isEmpty { attributes["frames"] = frames }
        if let uuid = TDBinaryImage.mainUUID { attributes["appUUID"] = uuid }
        if let loadAddress = TDBinaryImage.mainLoadAddress {
            attributes["appLoadAddress"] = String(format: "0x%llx", loadAddress)
        }
        transport.enqueue(TDEvent(kind: "native_crash", fields: fields, attributes: attributes))
        transport.flush()
    }

    func recordNonFatal(message: String, stack: String?, category: String,
                        attributes: [String: Any]) {
        var fields: [String: Any] = ["message": message, "severity": "error"]
        if let stack = stack { fields["stack"] = String(stack.prefix(16_000)) }
        var merged = attributes
        merged["category"] = category
        merged["breadcrumbs"] = snapshotBreadcrumbs()
        transport.enqueue(TDEvent(kind: "error", fields: fields,
                                  attributes: merged, ts: Date()))
    }

    func recordANR(durationMs: Double, stack: String? = nil, thresholdMs: Double? = nil,
                   sampleCount: Int? = nil, frames: [[String: Any]]? = nil,
                   screen: String? = nil) {
        var fields: [String: Any] = ["durationMs": durationMs, "type": "main_thread_block"]
        if let stack = stack { fields["stack"] = String(stack.prefix(60_000)) }
        if let thresholdMs = thresholdMs { fields["thresholdMs"] = thresholdMs }
        if let sampleCount = sampleCount { fields["sampleCount"] = sampleCount }
        if let screen = screen { fields["screen"] = screen }

        // `anr` 的契约为 durationMs / thresholdMs / type / stack / sampleCount 五项，
        // 轨迹放在 attributes 里（顶层多出的键会被服务端按 schema 丢弃）。
        var attributes: [String: Any] = ["thresholdMs": thresholdMs ?? 0]
        if let frames = frames, !frames.isEmpty { attributes["frames"] = frames }
        let trail = snapshotBreadcrumbs()
        if !trail.isEmpty { attributes["breadcrumbs"] = trail }
        transport.enqueue(TDEvent(kind: "anr", fields: fields, attributes: attributes))
    }

    func recordOOM(footprintMb: Double?, reason: String, message: String? = nil,
                   limitMb: Double? = nil, breadcrumbs: [[String: Any]]? = nil) {
        var fields: [String: Any] = ["reason": reason]
        if let footprintMb = footprintMb { fields["footprintMb"] = footprintMb }
        if let limitMb = limitMb { fields["limitMb"] = limitMb }
        if let message = message { fields["message"] = message }
        let trail = breadcrumbs ?? snapshotBreadcrumbs()
        if !trail.isEmpty { fields["breadcrumbs"] = trail }
        transport.enqueue(TDEvent(kind: "oom", fields: fields))
    }

    // MARK: - 网络 / 页面 / 自定义

    /// 一次请求：分阶段耗时进 attributes，聚合指标进 api_metric。
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
        errorCode: Int? = nil,
        category: String? = nil,
        retryAttempt: Int = 0,
        weakNetwork: Bool = false,
        extraAttributes: [String: Any] = [:]
    ) {
        let path = TDCrashBridge.sanitizedURL(url)
        var attributes: [String: Any] = [
            "method": method, "status": status, "url": path,
            "category": category ?? (success ? "ok" : "transport"),
            "retryAttempt": retryAttempt,
        ]
        if let dnsMs = dnsMs { attributes["dnsMs"] = dnsMs }
        if let tcpMs = tcpMs { attributes["tcpMs"] = tcpMs }
        if let tlsMs = tlsMs { attributes["tlsMs"] = tlsMs }
        if let ttfbMs = ttfbMs { attributes["ttfbMs"] = ttfbMs }
        if let errorCode = errorCode { attributes["errorCode"] = errorCode }
        if weakNetwork { attributes["weakNetwork"] = true }
        extraAttributes.forEach { attributes[$0.key] = $0.value }

        transport.enqueue(TDEvent(
            kind: "mobile_metric",
            fields: ["name": "network_phase", "durationMs": durationMs,
                     "severity": success ? "info" : "warning"],
            attributes: attributes
        ))

        var apiFields: [String: Any] = [
            "url": path, "method": method, "status": status,
            "durationMs": durationMs, "success": success,
        ]
        if let requestBytes = requestBytes, requestBytes > 0 { apiFields["requestBytes"] = requestBytes }
        if let responseBytes = responseBytes, responseBytes > 0 { apiFields["responseBytes"] = responseBytes }
        transport.enqueue(TDEvent(kind: "api_metric", fields: apiFields))

        // `network_error` 只记真正的网络/服务端失败：链路错误（errorCode）与 5xx。
        // 4xx 是业务语义（参数错、404），记进去只会把「网络质量」噪音化——
        // 它仍然体现在 api_metric.success=false 与 network_phase 的 status 上。
        let isNetworkFailure = errorCode != nil || status >= 500
        if !success && isNetworkFailure {
            transport.enqueue(TDEvent(
                kind: "mobile_metric",
                fields: ["name": "network_error", "value": 1, "severity": "warning"],
                attributes: ["url": path, "method": method, "status": status,
                             "errorCode": errorCode ?? 0,
                             "category": category ?? "transport",
                             "weakNetwork": weakNetwork]
            ))
        }
        if let requestBytes = requestBytes, let responseBytes = responseBytes,
           requestBytes + responseBytes > 0 {
            transport.enqueue(TDEvent(
                kind: "mobile_metric",
                fields: ["name": "network_traffic",
                         "value": Double(requestBytes + responseBytes), "unit": "bytes"],
                attributes: ["url": path, "upBytes": requestBytes, "downBytes": responseBytes]
            ))
        }
    }

    func recordViewLoad(screen: String, durationMs: Double, renderMs: Double? = nil) {
        var attributes: [String: Any] = ["screen": screen]
        if let renderMs = renderMs { attributes["loadMs"] = renderMs }
        transport.enqueue(TDEvent(
            kind: "mobile_metric",
            fields: ["name": "view_load", "durationMs": durationMs, "screen": screen],
            attributes: attributes
        ))
    }

    func recordLongTask(durationMs: Double, screen: String?) {
        var attributes: [String: Any] = [:]
        if let screen = screen { attributes["screen"] = screen }
        transport.enqueue(TDEvent(
            kind: "mobile_metric",
            fields: ["name": "long_task", "durationMs": durationMs, "screen": screen ?? ""],
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
