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

    private let sink: TDEventSink
    private let defaults: UserDefaults
    private let breadcrumbs = TDBreadcrumbStore()
    private let lock = NSLock()

    /// 上次会话的面包屑。崩溃补发发生在新会话启动时，只有这份轨迹是有效的。
    private(set) var previousSessionBreadcrumbs: [[String: Any]] = []

    init(sink: TDEventSink) {
        self.sink = sink
        self.defaults = UserDefaults(suiteName: "com.truedepth.monitor") ?? .standard
    }

    // MARK: - 会话与终止归因

    func start(termination: TDTerminationVerdict? = nil,
               capabilities: TDCapabilityMatrix? = nil) {
        previousSessionBreadcrumbs = breadcrumbs.loadPreviousSession()
        breadcrumbs.resetForNewSession()

        // 能力矩阵挂在 session_start 上：每台设备每次启动都自报「我实际启用了
        // 哪些采集器、哪些因系统版本降级、走的是哪条路径」。这样"iOS 13 用户
        // 没有 OOM 数据"这类事实是数据里可见的，而不是藏在文档免责声明里。
        var sessionAttributes: [String: Any] = capabilities?.attributes ?? [:]
        // MetricKit 的真实投递次数：为 0 说明这个用户关闭了「共享 iPhone 分析」，
        // 他的设备上永远不会有 MetricKit 数据。用它反推覆盖率，而不是靠猜。
        sessionAttributes["metrickitPayloads"] = TDMetricKitCoverage.deliveryCount
        if let verdict = termination {
            sessionAttributes.merge(terminationAttributes(verdict)) { _, new in new }
            reportTermination(verdict)
        }

        addBreadcrumb(category: "app", message: "session_start", level: "info")
        sink.enqueue(TDEvent(kind: "session_start", attributes: sessionAttributes))
    }

    /// 上次退出的归因结果压成 session_start 的维度字段。
    ///
    /// 无论归因是哪一类都会挂在这里：unknown 不进 OOM 率，但必须可查——
    /// 否则「有多少次退出我们根本说不清」这个问题永远没有答案。
    private func terminationAttributes(_ verdict: TDTerminationVerdict) -> [String: Any] {
        let state = verdict.state
        return [
            "prevTermination": verdict.attribution.rawValue,
            "prevTerminationConfidence": verdict.confidence,
            // 上次会话真实存活时长：startedAt → 最后一次心跳，而不是到现在的差值。
            "prevSessionDurationMs": max(0, state.lastAliveAt.timeIntervalSince(state.startedAt) * 1000),
            "prevPeakFootprintMb": state.peakFootprintMb,
            "prevLastFootprintMb": state.lastFootprintMb ?? 0,
            "prevLimitMb": state.limitMb ?? 0,
            "prevMaxHangMs": state.maxHangMs,
            "prevMemoryWarnings": state.memoryWarningCount,
            "prevForeground": state.foreground,
            "prevExitInitiator": state.exitInitiator ?? "-",
            "prevScreen": state.lastScreen ?? "-",
            "prevTracePoints": state.footprintSeries.count,
            "prevEvidence": verdict.reasons.joined(separator: "; "),
        ]
    }

    /// 只上报有本地证据支撑的归因。
    ///
    /// 刻意不做的事：`unknown_unclean` 不伪装成 OOM 或 watchdog。用户从后台
    /// 上划强杀、系统因存储压力回收、越狱插件杀进程，在本地都无法与 OOM 区分；
    /// 把它们算进 OOM 率会让这个指标彻底失去意义（老实现就是只要"没干净退出"
    /// 就报一条 watchdog，导致强杀和 OOM 无法分开）。
    private func reportTermination(_ verdict: TDTerminationVerdict) {
        let state = verdict.state
        switch verdict.attribution {
        case .jetsam, .memoryPressure, .backgroundTaskTimeout:
            var fields: [String: Any] = [
                "reason": verdict.attribution == .jetsam ? "jetsam" : "memory_warning",
                "message": "上次会话非正常结束：\(verdict.attribution.rawValue)",
            ]
            if let footprint = state.lastFootprintMb { fields["footprintMb"] = footprint }
            if let limit = state.limitMb { fields["limitMb"] = limit }
            sink.enqueue(TDEvent(
                kind: "oom",
                fields: fields,
                attributes: terminationAttributes(verdict).merging([
                    "source": "heuristic",
                    "screen": state.lastScreen ?? "-",
                    "footprintSeries": state.footprintSeries,
                    // 因果链：内存 / 内存警告 / 页面 / 前后台 / 卡顿统一在一条时间轴上。
                    // 单看「峰值 900MB、警告 2 次、最后停在详情页」回答不了
                    // 「是缓慢泄漏还是一次性拉爆」，加上时间偏移就能。
                    "timeline": state.timelineEntries.map(\.asJSON),
                ]) { _, new in new }
            ))
        case .watchdog:
            sink.enqueue(TDEvent(
                kind: "mobile_metric",
                fields: ["name": "watchdog", "value": 1, "severity": "error"],
                attributes: terminationAttributes(verdict).merging([
                    "source": "heuristic",
                    "reason": "main_thread_unresponsive",
                    "maxHangMs": state.maxHangMs,
                    // 看门狗杀进程前主线程一定长时间无响应，时间线上能看到
                    // 「卡顿从第 N 秒开始持续到进程消失」。
                    "timeline": state.timelineEntries.map(\.asJSON),
                ]) { _, new in new }
            ))
        case .unknown:
            TDMonitorLog.record(
                "上次退出无法归因（不计入 OOM 率）：\(verdict.reasons.joined(separator: "; "))",
                level: "warning")
        }
    }

    func flushBreadcrumbs() { breadcrumbs.flush() }

    func endSession(uptimeMs: Double) {
        sink.enqueue(TDEvent(kind: "session_end", fields: ["durationMs": uptimeMs]))
    }

    // MARK: - 面包屑

    func addBreadcrumb(category: String, message: String, level: String = "info") {
        breadcrumbs.append(category: category, message: message, level: level)
        // 带上当前页面：面包屑单独看只有一串文本，按页面聚合才能回答
        // 「用户是在哪个页面走到这一步的」。fields 与 attributes 都写，
        // 与 screen_render 事件保持同一口径（后端两条路径都可能取 screen）。
        var fields: [String: Any] = ["name": "breadcrumb", "value": 1]
        var attributes: [String: Any] = ["category": category,
                                         "message": String(message.prefix(200)),
                                         "level": level]
        if let screen = TDScreenContext.shared.current {
            fields["screen"] = screen
            attributes["screen"] = screen
        }
        sink.enqueue(TDEvent(kind: "mobile_metric", fields: fields, attributes: attributes))
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
        extraAttributes: [String: Any] = [:],
        occurredAt: Date? = nil,
        originSessionId: String? = nil
    ) {
        // 补发事件的 ts 必须是崩溃发生时刻，不能是「下次启动那一刻」，
        // 否则后台按时间看崩溃趋势、按会话看崩溃归属都会错位。
        let crashTime = occurredAt ?? Date()
        var fields: [String: Any] = ["message": message, "symbolicated": symbolicated]
        if let stack = stack { fields["stack"] = stack }
        if let signal = signal { fields["signal"] = signal }
        if let exceptionType = exceptionType { fields["exceptionType"] = exceptionType }
        if let threads = threads {
            let safe = Self.sanitizedThreads(threads)
            if !safe.isEmpty { fields["threads"] = safe }
        }
        if let uptimeMs = uptimeMs { fields["uptimeMs"] = uptimeMs }
        let trail = breadcrumbs ?? snapshotBreadcrumbs()
        let safeTrail = Self.sanitizedBreadcrumbs(trail, fallback: crashTime)
        if !safeTrail.isEmpty { fields["breadcrumbs"] = safeTrail }

        var attributes = extraAttributes
        if let frames = frames, !frames.isEmpty { attributes["frames"] = frames }
        // 补发事件已由崩溃现场快照填好 appUUID/appLoadAddress（见 TDCrashFeature），
        // 不能用补发进程的 dyld 基址覆盖——那样符号化会按错误的镜像偏移查表。
        // 只有调用方没提供时（实时崩溃）才用当前进程兜底。
        if attributes["appUUID"] == nil, let uuid = TDBinaryImage.mainUUID {
            attributes["appUUID"] = uuid
        }
        if attributes["appLoadAddress"] == nil, let loadAddress = TDBinaryImage.mainLoadAddress {
            attributes["appLoadAddress"] = String(format: "0x%llx", loadAddress)
        }
        if occurredAt != nil {
            attributes["forwardedFromPreviousSession"] = true
            attributes["crashOccurredAt"] = TDISO8601.string(from: crashTime)
        }
        if let originSessionId = originSessionId {
            attributes["originSessionId"] = originSessionId
        }
        sink.enqueue(TDEvent(kind: "native_crash", fields: fields, attributes: attributes,
                             ts: crashTime, sessionIdOverride: originSessionId))
        sink.flush()
    }

    /// 按后台 `breadcrumbSchema` 收口嵌套字段。
    /// 一条非法 `ts` / 越界 `level` 会让**整个批次** 422，代价远大于逐条清洗。
    private static func sanitizedBreadcrumbs(_ raw: [[String: Any]],
                                             fallback: Date) -> [[String: Any]] {
        raw.prefix(100).compactMap { crumb in
            let category = String((crumb["category"] as? String ?? "").prefix(64))
            guard !category.isEmpty else { return nil }
            return [
                "ts": TDBreadcrumbStore.normalizedTimestamp(
                    crumb["ts"] ?? crumb["timestamp"], fallback: fallback),
                "category": category,
                "message": String((crumb["message"] as? String ?? "").prefix(512)),
                "level": TDBreadcrumbStore.normalizedLevel(crumb["level"] as? String ?? "info"),
            ]
        }
    }

    /// 按后台 `crashThreadSchema` 收口：`crashed` 必填 Bool、`frames` 必须是字符串数组。
    private static func sanitizedThreads(_ raw: [[String: Any]]) -> [[String: Any]] {
        raw.prefix(32).map { thread in
            let frames = (thread["frames"] as? [Any] ?? []).prefix(256).compactMap { value -> String? in
                guard let text = value as? String else { return nil }
                return String(text.prefix(512))
            }
            return [
                "name": String((thread["name"] as? String ?? "unknown").prefix(128)),
                "crashed": (thread["crashed"] as? Bool) ?? false,
                "frames": frames,
            ]
        }
    }

    func recordNonFatal(message: String, stack: String?, category: String,
                        attributes: [String: Any]) {
        var fields: [String: Any] = ["message": message, "severity": "error"]
        if let stack = stack { fields["stack"] = String(stack.prefix(16_000)) }
        var merged = attributes
        merged["category"] = category
        merged["breadcrumbs"] = snapshotBreadcrumbs()
        sink.enqueue(TDEvent(kind: "error", fields: fields,
                                  attributes: merged, ts: Date()))
    }

    func recordANR(durationMs: Double, stack: String? = nil, thresholdMs: Double? = nil,
                   sampleCount: Int? = nil, frames: [[String: Any]]? = nil,
                   screen: String? = nil,
                   reportThresholdMs: Double? = nil,
                   severity: String? = nil,
                   blockType: String? = nil,
                   framesDuring: Int? = nil,
                   foreground: Bool? = nil) {
        var fields: [String: Any] = ["durationMs": durationMs, "type": "main_thread_block"]
        if let stack = stack { fields["stack"] = String(stack.prefix(60_000)) }
        if let thresholdMs = thresholdMs { fields["thresholdMs"] = thresholdMs }
        if let sampleCount = sampleCount { fields["sampleCount"] = sampleCount }

        // `anr` 的契约为 durationMs / thresholdMs / type / stack / sampleCount 五项，
        // 轨迹放在 attributes 里（顶层多出的键会被服务端按 schema 丢弃）。
        // `screen` 也是如此：后台 anrEventSchema 没有该字段，写顶层等于没写，
        // 页面归因会恒为空，必须走 attributes。
        //
        // severity / blockType 也放 attributes 而不是顶层：`type` 保持
        // `main_thread_block` 不变，后端既有分组统计与看板无需同步改造，
        // 想按新维度看时再从 attributes 里取，属于向后兼容的加法。
        var attributes: [String: Any] = ["thresholdMs": thresholdMs ?? 0]
        // 页面归因只能走 attributes：顶层 `screen` 会被 zod 直接剥掉。
        if let screen = screen { attributes["screen"] = screen }
        if let reportThresholdMs = reportThresholdMs {
            attributes["reportThresholdMs"] = reportThresholdMs
        }
        // 卡顿分级：hang（2s~8s，进程活着）/ fatal_suspected（≥8s，大概率已被看门狗杀掉）
        if let severity = severity { attributes["severity"] = severity }
        // 阻塞类型：fully_blocked（期间一帧未出）/ partially_blocked（仍在出帧但很慢）
        if let blockType = blockType { attributes["blockType"] = blockType }
        if let framesDuring = framesDuring { attributes["framesDuring"] = framesDuring }
        if let foreground = foreground { attributes["foreground"] = foreground }
        if let frames = frames, !frames.isEmpty { attributes["frames"] = frames }
        let trail = snapshotBreadcrumbs()
        if !trail.isEmpty { attributes["breadcrumbs"] = trail }
        sink.enqueue(TDEvent(kind: "anr", fields: fields, attributes: attributes))
    }

    func recordOOM(footprintMb: Double?, reason: String, message: String? = nil,
                   limitMb: Double? = nil, breadcrumbs: [[String: Any]]? = nil) {
        var fields: [String: Any] = ["reason": reason]
        if let footprintMb = footprintMb { fields["footprintMb"] = footprintMb }
        if let limitMb = limitMb { fields["limitMb"] = limitMb }
        if let message = message { fields["message"] = message }
        let trail = breadcrumbs ?? snapshotBreadcrumbs()
        if !trail.isEmpty { fields["breadcrumbs"] = trail }
        sink.enqueue(TDEvent(kind: "oom", fields: fields))
    }

    // MARK: - 网络 / 页面 / 自定义

    /// 一次请求：分阶段耗时进 attributes，聚合指标进 api_metric。
    ///
    /// `endpoint` / `traceId` 必须一路带到底：业务在门面里给每个接口起了归一化名字
    /// （`finance.quote`、`api/v1/orders`），后端只能靠它做「按接口聚合」——
    /// 一旦在落盘前丢了这个字段，就只能拿 URL 做字符串匹配，参数不同、域名轮换
    /// 都会被拆成不同接口，聚合直接失效。
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
        endpoint: String? = nil,
        traceId: String? = nil,
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
        if let endpoint = endpoint { attributes["endpoint"] = endpoint }
        if let traceId = traceId { attributes["traceId"] = traceId }
        extraAttributes.forEach { attributes[$0.key] = $0.value }

        sink.enqueue(TDEvent(
            kind: "mobile_metric",
            fields: ["name": "network_phase", "durationMs": durationMs,
                     "severity": success ? "info" : "warning"],
            attributes: attributes
        ))

        var apiFields: [String: Any] = [
            "url": path, "method": method, "status": status,
            "durationMs": durationMs, "success": success,
        ]
        // 聚合事件同样要带：`api_metric` 才是后端算成功率/P95 的那张表。
        if let endpoint = endpoint { apiFields["endpoint"] = endpoint }
        if let requestBytes = requestBytes, requestBytes > 0 { apiFields["requestBytes"] = requestBytes }
        if let responseBytes = responseBytes, responseBytes > 0 { apiFields["responseBytes"] = responseBytes }
        sink.enqueue(TDEvent(kind: "api_metric", fields: apiFields))

        // `network_error` 只记真正的网络/服务端失败：链路错误（errorCode）与 5xx。
        // 4xx 是业务语义（参数错、404），记进去只会把「网络质量」噪音化——
        // 它仍然体现在 api_metric.success=false 与 network_phase 的 status 上。
        let isNetworkFailure = errorCode != nil || status >= 500
        if !success && isNetworkFailure {
            var errorAttributes: [String: Any] = ["url": path, "method": method, "status": status,
                                                  "errorCode": errorCode ?? 0,
                                                  "category": category ?? "transport",
                                                  "weakNetwork": weakNetwork]
            if let endpoint = endpoint { errorAttributes["endpoint"] = endpoint }
            if let traceId = traceId { errorAttributes["traceId"] = traceId }
            sink.enqueue(TDEvent(
                kind: "mobile_metric",
                fields: ["name": "network_error", "value": 1, "severity": "warning"],
                attributes: errorAttributes
            ))
        }
        if let requestBytes = requestBytes, let responseBytes = responseBytes,
           requestBytes + responseBytes > 0 {
            var trafficAttributes: [String: Any] = ["url": path, "upBytes": requestBytes,
                                                    "downBytes": responseBytes]
            if let endpoint = endpoint { trafficAttributes["endpoint"] = endpoint }
            sink.enqueue(TDEvent(
                kind: "mobile_metric",
                fields: ["name": "network_traffic",
                         "value": Double(requestBytes + responseBytes), "unit": "bytes"],
                attributes: trafficAttributes
            ))
        }
    }

    func recordViewLoad(screen: String, durationMs: Double, renderMs: Double? = nil) {
        var attributes: [String: Any] = ["screen": screen]
        if let renderMs = renderMs { attributes["loadMs"] = renderMs }
        sink.enqueue(TDEvent(
            kind: "mobile_metric",
            fields: ["name": "view_load", "durationMs": durationMs, "screen": screen],
            attributes: attributes
        ))
    }

    func recordLongTask(durationMs: Double, screen: String?) {
        var attributes: [String: Any] = [:]
        if let screen = screen { attributes["screen"] = screen }
        sink.enqueue(TDEvent(
            kind: "mobile_metric",
            fields: ["name": "long_task", "durationMs": durationMs, "screen": screen ?? ""],
            attributes: attributes
        ))
    }

    /// 外部二进制 SDK 的「业务边界层」样本。
    ///
    /// 这类观测只有「调用了哪个接口 / 耗时 / 成败」，没有 DNS/TCP/TLS/TTFB，
    /// `status` / `method` 也是边界层映射出来的，不是真实 HTTP 响应。早先把它
    /// 接到 `recordNetwork` 上，会产出带 `sdk://qweather/...` 的 `api_metric`；
    /// 后台按 `kind='api_metric'` + `GROUP BY method,url` 算网络 P95、成功率、
    /// 慢接口，于是把「SDK 调用前后」当成了传输请求统计 —— 数据看着完整，
    /// 其实口径是错的。真机库里已经能查到这批误入的样本。
    ///
    /// 因此单独走 `mobile_metric(name=custom_metric)`：数据一条不丢，但与传输层
    /// 指标物理隔离。后台要展示时按 `metric=external_sdk_request` 单独开视图。
    func recordExternalRequest(endpoint: String, url: String, status: Int,
                               durationMs: Double, success: Bool, error: NSError?) {
        var attributes: [String: Any] = [
            "metric": "external_sdk_request",
            "domain": "business_boundary",
            "observedLayer": "business_boundary",
            "endpoint": endpoint,
            "logicalURL": url,
            "status": status,
            "success": success,
        ]
        if let error = error {
            attributes["errorCode"] = error.code
            attributes["errorDomain"] = error.domain
        }
        sink.enqueue(TDEvent(
            kind: "mobile_metric",
            fields: ["name": "custom_metric",
                     "durationMs": max(0, durationMs),
                     "severity": success ? "info" : "warning"],
            attributes: attributes
        ))
    }

    /// 通用自定义指标逃生口。当前业务层零调用，为防未来被借去塞业务 KPI
    /// （污染 mobile_metric 统一口径），2026-11-17 加三道轻量护栏：
    ///   1) metric 名须为 [a-z0-9_.]，挡住自由文本/中文 KPI 名；
    ///   2) 过滤 attributes 中会被 payload 覆盖或污染 schema 的保留字段；
    ///   3) 打 source="custom" 标记，便于后台单独审计这类指标。
    /// 非法名直接丢弃并记 diagnostics，不 enqueue。
    func recordCustom(name: String, value: Double? = nil, unit: String? = nil,
                      attributes: [String: Any] = [:]) {
        guard Self.isValidCustomMetricName(name) else {
            TDMonitorLog.record("recordCustom 拒绝非法 metric 名: \(name)", level: "warning")
            return
        }
        var fields: [String: Any] = ["name": "custom_metric"]
        if let value = value, value.isFinite { fields["value"] = value }
        if let unit = unit { fields["unit"] = unit }
        var merged = attributes.filter { !Self.reservedEventKeys.contains($0.key) }
        merged["metric"] = name
        merged["source"] = "custom"
        sink.enqueue(TDEvent(kind: "mobile_metric", fields: fields, attributes: merged))
    }

    /// 允许的小写 snake/dot 命名，长度 1..64。禁止空名、大写、空格、中文与路径分隔符。
    /// internal 供单测覆盖（@testable import）。
    static func isValidCustomMetricName(_ name: String) -> Bool {
        guard (1...64).contains(name.count) else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_.")
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// 这些键由 TDEvent.payload / TDContext 写入，允许用户 attributes 覆盖会污染事件 schema。
    private static let reservedEventKeys: Set<String> = [
        "id", "ts", "kind", "type", "sessionId", "environment", "appVersion",
        "buildNumber", "os", "osVersion", "deviceModel", "networkType", "foreground",
        "appId", "deviceId", "release", "userId",
    ]

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
