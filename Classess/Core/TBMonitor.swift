import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// 队列与上传的当前状态快照。
///
/// 存在的理由只有一个：**「事件没上来」是接入期最常见的问题，而它有三个完全不同的原因**
/// ——没采到、采到没落盘、落盘发不出去。三者表现一模一样（后端没数据），
/// 但修法完全不同。这份快照让接入方不必开日志就能分清是哪一种。
///
/// 刻意不提供「清空队列 / 强制丢弃」：那是故障处置动作，不该由展示层触发。
public struct TDQueueStatus {

    /// 内存里等待发送的条数。**持续增长 = 上传不通或后端拒收**，这是最关键的一项。
    public let queuedEvents: Int

    /// 磁盘队列文件里的条数。追加写会保留「已发未压缩」的事件，通常 ≥ `queuedEvents`，
    /// 不能当成积压量看。
    public let storedEvents: Int

    /// 磁盘队列文件字节数。同样包含已发未压缩的部分。
    public let storedBytes: Int

    /// 解析时跳过的坏行数。进程被 SIGKILL 留下半行属预期；持续增长说明写入有问题。
    public let corruptedLines: Int

    /// 本进程累计发出的批次数。
    public let sentBatches: Int

    /// 最近一次发送结果，如「500 条成功」/「500 条待重试」/「12 条被拒丢弃」。
    public let lastUploadSummary: String?

    public let lastUploadAt: Date?

    /// 上报端点（不含 Key，可直接展示）。
    public let endpoint: String

    /// 本进程因队列达到上限而丢弃的事件累计条数。
    /// 大于 0 说明上报曾经堵住过；配合 `queuedEvents` 才能分清「容量保护」和「写入失败」。
    /// 快照全是常量，由 `TDTransport.snapshot()` 显式填入（唯一构造点）。
    public let evictedEvents: Int

    /// 一行式摘要，直接丢进日志或面板即可。
    public var summary: String {
        var parts = [
            "待发 \(queuedEvents) 条",
            "落盘 \(storedEvents) 条/\(storedBytes) B",
            "已发 \(sentBatches) 批",
        ]
        if corruptedLines > 0 { parts.append("坏行 \(corruptedLines)") }
        if evictedEvents > 0 { parts.append("淘汰 \(evictedEvents) 条") }
        if let last = lastUploadSummary { parts.append("上次：\(last)") } else { parts.append("上次：尚未发送") }
        return parts.joined(separator: " · ")
    }
}

/// TDMonitorKit 的公开入口。
///
/// 这一层只做三件事：建依赖容器、声明要装哪些能力、把宿主 API 转给对应能力。
/// **不承载任何采集逻辑**——采集逻辑在 `TBMonitorFeatures.swift` 的各个能力单元里。
///
/// 之前这里是 167 行硬装配，所有子系统按执行顺序手写串起来。那种写法的问题
/// 不是"长"，而是：任何一个能力想单独启停、想替换、想在测试里绕开，都做不到。
///
/// 本 Kit **不注册** signal / NSException 崩溃处理器——宿主已经有一套，
/// 注册第二个会把宿主的实现顶掉。崩溃由宿主捕获落盘，这里负责补发与补全。
public final class TDMonitor {

    public static let shared = TDMonitor()

    private let lock = NSLock()
    private var runtime: TDMonitorRuntime?
    private var registry: TDMonitorFeatureRegistry?

    /// 外部扩展能力：在 `start()` 前通过 `TDMonitor.register(_:)` 登记。
    private static var customFeatureMakers: [(name: String, requires: [String],
                                             make: (TDMonitorRuntime) -> TDMonitorFeature?)] = []
    private static let registrationLock = NSLock()

    /// 具体实现只在启停队列时用得到；其余地方一律走 `sink`。
    private var transport: TDTransport?
    private var sink: TDEventSink?
    private var started = false

    private init() {}

    public var isEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return started
    }

    public var sessionId: String? {
        lock.lock(); defer { lock.unlock() }
        return runtime?.context.sessionId
    }

    /// 本次实际安装成功的能力名。
    ///
    /// 接入自检用：如果 `metrickit` 不在里面，说明要么是 iOS 13，要么用户
    /// 关了「共享 iPhone 分析」。数据缺失的原因永远可以在这里查到。
    public var installedFeatures: [String] {
        lock.lock(); defer { lock.unlock() }
        return runtime?.installedFeatures ?? []
    }

    /// 依赖未满足、但自身仍装上的能力 → 缺失的依赖名。
    ///
    /// 与 `installedFeatures` 分工：`installedFeatures` 回答「装了哪些」，
    /// 这个回答「哪个能力装上了但依赖缺口、可能数据不全」。这类故障最隐蔽——
    /// 它不报错，只是「某个指标突然没数据」，所以 Release 也要留痕、可查。
    /// 内置 12 能力的 `requires` 图谱必须在此为空（由 `TDRegistryGraphTests` 锁住）。
    public var blockedFeatures: [String: [String]] {
        lock.lock(); defer { lock.unlock() }
        return runtime?.blockedFeatures ?? [:]
    }

    /// 最近若干条 SDK 自身诊断，宿主可直接展示（有界，纯内存）。
    public var diagnostics: [String] { TDMonitorLog.snapshot() }

    /// 接入自检结果。
    ///
    /// 和 `installedFeatures` 分工不同：那个回答「装了哪些能力」，
    /// 这个回答「你漏配了什么、会缺哪份数据」。后者更容易被忽略，
    /// 因为漏配从不报错，只是数据静默消失。
    public private(set) var intakeWarnings: [String] = []

    private var bridge: TDCrashBridge? { runtime?.service(TDCrashBridge.self) }

    // MARK: - 生命周期

    /// 读取 `TDMonitor.plist`（可用 `TD_MONITOR_API_KEY` / `TD_MONITOR_BASE_URL` 覆盖）。
    /// 配置缺失时完全静默关闭，不崩溃、不产生流量。
    ///
    /// 这一版使用内置 HTTP 出口，接入方只需这一行。
    @discardableResult
    public func start(configuration: TDMonitorConfiguration? = TDMonitorConfiguration.load()) -> Bool {
        start(configuration: configuration, sink: nil)
    }

    /// 自定义数据出口。
    ///
    /// 需要换成公司统一网关 / 自建通道 / 双写时用这个重载，**不用改 SDK 源码**：
    ///
    /// ```swift
    /// final class GatewaySink: TDEventSink {
    ///     func start() {}
    ///     func enqueue(_ event: TDEvent) { gateway.send(event) }
    ///     func flush() {}
    ///     func flushInBackground() {}
    /// }
    /// TDMonitor.shared.start(configuration: cfg, sink: GatewaySink())
    /// ```
    ///
    /// 传 `nil` 等价于默认的内置 HTTP 出口。
    /// **注意**：自定义出口需要自行负责落盘队列、失败重试与鉴权——这些内置出口已经做好了。
    @discardableResult
    public func start(configuration: TDMonitorConfiguration?, sink: TDEventSink?) -> Bool {
        lock.lock()
        if started { lock.unlock(); return true }
        guard let configuration, !configuration.apiKey.isEmpty else {
            lock.unlock()
            TDMonitorLog.record("未配置 apiKey（TDMonitor.plist / TD_MONITOR_API_KEY），监控保持关闭", level: "warning")
            return false
        }

        let context = TDContext(config: configuration)
        // 内置出口才有具体类型；自定义出口时 transport 为 nil，启停由 sink 自理。
        let builtIn = sink == nil ? TDTransport(configuration: configuration, context: context) : nil
        let eventSink: TDEventSink = sink ?? builtIn!
        // 能力矩阵是别人的输入（决定 session_start 上报什么），先算出来。
        let capabilities = TDCapabilityMatrix.probe(
            networkInstrumentation: configuration.networkInstrumentation,
            viewLoad: configuration.viewLoadInstrumentation)
        let runtime = TDMonitorRuntime(
            configuration: configuration,
            context: context,
            sink: eventSink,
            capabilities: capabilities)
        let registry = TDMonitorFeatureRegistry()
        TDMonitor.registerFeatures(into: registry)

        self.runtime = runtime
        self.registry = registry
        self.transport = builtIn
        self.sink = eventSink
        self.started = true
        lock.unlock()

        TDStackSampler.registerMainThread()
        TDMonitorLog.record("能力矩阵 \(capabilities.summary)", level: "info")

        // 队列恢复必须早于任何 enqueue：内置出口的 `start()` 会用磁盘内容覆盖
        // 内存队列，先 enqueue 的事件会被直接冲掉。
        eventSink.start()

        let installed = registry.installAll(runtime: runtime)
        TDMonitorLog.record("已安装能力 [\(installed.joined(separator: ", "))]", level: "info")

        #if DEBUG
        let isDebugBuild = true
        #else
        let isDebugBuild = false
        #endif
        // 崩溃补发是唯一「不配就彻底没有数据、且不报错」的能力，必须在这里点名。
        let findings = TDIntakeSelfCheck.run(
            configuration: configuration,
            crashReportsConfigured: TDMonitor.hostCrashReportPaths != nil,
            isDebugBuild: isDebugBuild)
        intakeWarnings = findings.map { "[\($0.item)] \($0.message)" }
        if let summary = TDIntakeSelfCheck.summary(findings) {
            TDMonitorLog.record("接入自检 —— \(summary)",
                                level: findings.contains { $0.level == .blocking } ? "error" : "warning")
        }

        #if DEBUG
        applyDebugScenarios(configuration: configuration)
        #endif
        return true
    }

    /// 能力清单。**顺序即依赖**：
    /// 终止归因必须最先（结论要随 `session_start` 发出）；
    /// 生命周期必须最后（它会在 `willTerminate` 里回调 `stop()`）。
    private static func registerFeatures(into registry: TDMonitorFeatureRegistry) {
        registry.register(TDAttributionFeature.self)
        registry.register(TDCrashFeature.self)
        registry.register(TDLaunchFeature.self)
        registry.register(TDResourceFeature.self)
        registry.register(TDANRFeature.self)
        registry.register(TDLongTaskFeature.self)
        registry.register(TDNetworkFeature.self)
        registry.register(TDScreenFeature.self)
        registry.register(TDNonFatalFeature.self)
        #if canImport(MetricKit)
        if #available(iOS 14.0, *) {
            registry.register(TDMetricKitFeature.self)
        }
        #endif
        registry.register(TDLifecycleFeature.self)

        // 外部扩展能力：与内置能力走完全相同的安装路径（顺序安装、逆序卸载、
        // 依赖缺口登记、能力矩阵对账）。
        registrationLock.lock()
        let custom = customFeatureMakers
        registrationLock.unlock()
        for maker in custom {
            registry.register(maker.make, name: maker.name, requires: maker.requires)
        }
    }

    /// 首帧渲染完成后调用（`window.makeKeyAndVisible()` 之后）。
    /// 不调用也能工作：3 秒后会用兜底逻辑结算，只是首帧耗时略偏大。
    public func markFirstFrame() {
        runtime?.service(TDLaunchRecorder.self)?.markFirstFrameWhenRendered()
    }

    /// 宿主可注入崩溃报告文件路径，避免为了一个回调引入组件依赖。
    public static var hostCrashReportPaths: (() -> [String])?

    /// 宿主可注入崩溃镜像快照读取：入参是崩溃 context 的 `binaryImagesFile`，
    /// 返回 name/uuid/loadAddress/size 数组。崩溃是下次启动补发的，必须用崩溃进程
    /// 落盘的快照，不能用补发进程的 dyld 基址——这是 dSYM 符号化的前提。
    public static var hostBinaryImages: ((String) -> [[String: Any]])?

    /// 注册一个自定义能力类型，使其在 `start()` 时被安装。
    ///
    /// 用于在不 fork SDK 的前提下扩展采集能力：自定义能力只需遵循
    /// `TDMonitorFeature` 协议（提供 `name` / `requires` / `init?(runtime:)` /
    /// `install()` / `uninstall()`），即可与内置能力共用同一套依赖注入、
    /// 顺序安装、逆序卸载与能力矩阵对账。
    ///
    /// ```swift
    /// TDMonitor.register(MyLatencyFeature.self)
    /// TDMonitor.start(with: configuration)
    /// ```
    ///
    /// - Warning: 必须在 `start()` 之前调用；同名能力只登记一次。
    public static func register<T: TDMonitorFeature>(_ featureType: T.Type) {
        registrationLock.lock()
        customFeatureMakers.append((
            name: featureType.name,
            requires: featureType.requires,
            make: { runtime in featureType.init(runtime: runtime) }
        ))
        registrationLock.unlock()
    }

    public func flush() { sink?.flush() }
    public func flushInBackground() { sink?.flushInBackground() }

    /// 队列与上传的当前状态，用于接入自检与故障定位。
    ///
    /// 使用自定义 `sink` 时返回 `nil`——此时队列、落盘、重试都由接入方自理，
    /// 内置出口无从得知。
    public func queueStatus() -> TDQueueStatus? {
        lock.lock()
        let transport = self.transport
        lock.unlock()
        return transport?.snapshot()
    }

    /// 仅在明确终止时调用。退到后台**不**标记为干净退出，
    /// 否则 Jetsam / 看门狗杀进程将无法在下次启动被识别。
    public func stop() {
        lock.lock()
        guard started else { lock.unlock(); return }
        started = false
        let registry = self.registry
        let sink = self.sink
        self.registry = nil
        self.runtime = nil
        self.transport = nil
        self.sink = nil
        lock.unlock()

        // 逆序卸载：先拆生命周期观察者，再结算会话，最后停出口把队列发完。
        registry?.uninstallAll()
        sink?.stop()
    }

    // MARK: - 维度

    public func setUserId(_ userId: String?) { runtime?.context.userId = userId }
    public func refreshNetworkType() { runtime?.context.refreshNetworkType() }
    /// 设置业务页面名。本身不产生事件：除了更新 ANR / 卡顿读的 `TDScreenContext.current`，
    /// `TDScreenContext` 还会同步写 `TDAppStateTracker`，让终止归因 `prevScreen`
    /// 与 OOM 页面时间线拿到同一个名字（真机侧是靠 `app_state.json` 落盘的）。
    public func setScreen(_ screen: String?) { TDScreenContext.shared.update(screen) }

    /// 建一个**已经挂好采集器**的统一网络出口。
    ///
    /// 推荐用法。业务网络层可以直接拿它当出口；已经有网络层的项目**不必**换出口，
    /// 单独把 `TDTraceAdapter` / `TDIdempotentRetrier` / `TDNetworkSampleObserver`
    /// 挂到自己的 client 上也一样——采集能力不绑定具体实现。
    ///
    /// ```swift
    /// let client = TDMonitor.shared.makeNetworkClient()
    /// client.send(TDNetworkRequest(
    ///     url: url,
    ///     method: "GET",
    ///     tag: TDRequestTag(endpoint: "api/v1/orders", isIdempotent: true))) { result in
    ///     // result.metrics 里是 DNS / TCP / TLS / TTFB
    /// }
    /// ```
    ///
    /// 与 `makeInstrumentedSession` 的区别：
    /// - 这个是**统一出口**，请求前/后的拦截、重试、超时、trace 注入都在这里收口
    /// - 那个只是「给 session 套一个 metrics 代理」，管不到重试和业务语义
    ///
    /// 两者的分阶段耗时数据来源完全相同（都是 `URLSessionTaskMetrics`），
    /// 不存在「用哪个采得更全」的差别。
    public func makeNetworkClient(
        configuration: URLSessionConfiguration = .default,
        includeTraceAdapter: Bool = true,
        includeIdempotentRetrier: Bool = true
    ) -> TDNetworkClient {
        let client = TDURLSessionNetworkClient(configuration: configuration)
        if includeTraceAdapter {
            client.add(adapter: TDTraceAdapter())
        }
        if includeIdempotentRetrier {
            client.add(retrier: TDIdempotentRetrier())
        }
        let observer = TDNetworkSampleObserver()
        observer.onSample = { sample in
            // 复用同一个投递口：幂等标记、上报自身流量过滤都在里面，
            // 不另开一条路，避免两条路径的过滤规则迟早走岔。
            TDNetworkInstrumentation.shared.emit(sample)
        }
        client.add(observer: observer)
        return client
    }

    /// 创建带**分阶段耗时**采集的 session。
    ///
    /// 已经被 `makeNetworkClient()` 取代，保留是为了让「只想要 metrics、
    /// 不想改请求链路」的迁移可以分步做：先换 session，再换出口。
    ///
    /// DNS / TCP / TLS / TTFB 只能来自 `URLSessionTaskMetrics`，而它只通过 delegate 回调交付。
    /// 系统不允许事后替换 `URLSession` 的 delegate，SDK 也无法可靠接管业务已有的 session，
    /// 因此需要分阶段数据的页面请用这个方法（或上面的 `makeNetworkClient`）创建：
    ///
    /// ```swift
    /// let session = TDMonitor.shared.makeInstrumentedSession(delegate: self)
    /// ```
    ///
    /// 不调用也能采集成功率、状态码、错误分类、重试、流量与总耗时（走完成回调拦截）。
    public func makeInstrumentedSession(
        configuration: URLSessionConfiguration = .default,
        delegate: URLSessionDelegate? = nil,
        delegateQueue: OperationQueue? = nil
    ) -> URLSession {
        let proxy = TDURLSessionDelegateProxy(wrapping: delegate)
        return URLSession(configuration: configuration, delegate: proxy, delegateQueue: delegateQueue)
    }

    // MARK: - 手动埋点

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

    /// 非致命异常 / 被兜底的错误。不会进崩溃率，但会进错误分组。
    public func recordNonFatal(message: String, stack: String? = nil,
                               category: String = "non_fatal",
                               attributes: [String: Any] = [:]) {
        TDNonFatalRecorder.shared.record(message: message, stack: stack,
                                         category: category, attributes: attributes)
    }

    public func recordNonFatal(_ error: Error, category: String = "non_fatal",
                               attributes: [String: Any] = [:]) {
        let nsError = error as NSError
        var merged = attributes
        merged["domain"] = nsError.domain
        merged["code"] = nsError.code
        recordNonFatal(message: "\(nsError.domain)(\(nsError.code)): \(nsError.localizedDescription)",
                       stack: Thread.callStackSymbols.joined(separator: "\n"),
                       category: category,
                       attributes: merged)
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
        errorCode: Int? = nil,
        endpoint: String? = nil,
        traceId: String? = nil
    ) {
        bridge?.recordNetwork(url: url, method: method, status: status, durationMs: durationMs,
                              success: success, dnsMs: dnsMs, tcpMs: tcpMs, tlsMs: tlsMs,
                              ttfbMs: ttfbMs, requestBytes: requestBytes,
                              responseBytes: responseBytes, errorCode: errorCode,
                              endpoint: endpoint, traceId: traceId)
    }

    public func recordViewLoad(screen: String, durationMs: Double, renderMs: Double? = nil) {
        bridge?.recordViewLoad(screen: screen, durationMs: durationMs, renderMs: renderMs)
    }

    public func recordCustom(_ name: String, value: Double? = nil, unit: String? = nil,
                             attributes: [String: Any] = [:]) {
        bridge?.recordCustom(name: name, value: value, unit: unit, attributes: attributes)
    }

    /// 外部二进制 SDK 的调用边界样本。**不是传输层网络指标**，不会产出
    /// `api_metric` / `network_phase`，也就不会进网络 P95 / 成功率 / 慢接口报表。
    /// 详见 `TDCrashBridge.recordExternalRequest` 的口径说明。
    public func recordExternalRequest(endpoint: String, url: String, status: Int,
                                      durationMs: Double, success: Bool, error: NSError?) {
        bridge?.recordExternalRequest(endpoint: endpoint, url: url, status: status,
                                      durationMs: durationMs, success: success, error: error)
    }

    // MARK: - 崩溃补发

    /// 解析宿主落盘的 JSON 并转成 `native_crash`。已补发过的 id 会记住，
    /// 重启不会重复上报。
    @discardableResult
    public func forwardPendingCrashReports(_ paths: [String]) -> Int {
        runtime?.service(TDCrashFeature.self)?.forwardPendingCrashReports(paths) ?? 0
    }

    // MARK: - DEBUG 验证场景

    #if DEBUG
    /// 真机验证开关。Release 不编译，不会成为线上可触发的入口。
    private func applyDebugScenarios(configuration: TDMonitorConfiguration) {
        let environment = ProcessInfo.processInfo.environment

        if environment["TD_MONITOR_SMOKE"] == "1" { emitSampleEvents() }

        // 真实阻塞主线程 2.5s：必须越过 `TDHangWatchdog` 的 2s 上报阈值，
        // 才能验证 `anr` 事件（含主线程栈采样）而不只是 `long_task`。
        // 900ms 那版只能验到 long_task，曾让「ANR 已验证」变成误判。
        // 仍低于 8s 的 fatal_suspected 阈值，不会触发系统 watchdog 杀进程。
        if environment["TD_MONITOR_HANG_TEST"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                Thread.sleep(forTimeInterval: 2.5)
            }
        }
        if environment["TD_MONITOR_NONFATAL_TEST"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                self?.recordNonFatal(message: "NSCocoaErrorDomain(3840): 验证非致命异常上报链路",
                                     stack: Thread.callStackSymbols.joined(separator: "\n"),
                                     category: "verification")
            }
        }
        if environment["TD_MONITOR_NETWORK_TEST"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.emitNetworkProbes(ingestURL: configuration.ingestURL)
            }
        }
        // 在主线程制造可控慢帧（每次忙等 50ms，间隔让出 RunLoop），
        // 用于确认页面级掉帧统计能如实上报。单次不超过 ANR 阈值，不会误触发卡顿告警。
        if environment["TD_MONITOR_SCREEN_TEST"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                for _ in 0..<20 {
                    let busyUntil = Date().addingTimeInterval(0.05)
                    while Date() < busyUntil {}
                    RunLoop.current.run(until: Date().addingTimeInterval(0.03))
                }
            }
        }
        #if canImport(UIKit)
        // 热启动：真机上把 App 切后台再切回来不好脚本化（devicectl 没有 home 键），
        // 这里直接投递系统通知，验证「willEnterForeground → didBecomeActive」这段
        // 计算与上报逻辑确实产出 type=warm 的 app_launch。
        if environment["TD_MONITOR_LIFECYCLE_TEST"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                let center = NotificationCenter.default
                center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
                }
            }
        }
        #endif
    }

    /// 每类信号发一条，用于在没有真实流量的情况下验证链路。
    private func emitSampleEvents() {
        guard let transport = transport else { return }
        let metrics: [(String, Double, String)] = [
            ("fps", 58.4, "fps"), ("frame_jank", 3, "%"),
            ("memory", 182.6, "MB"), ("cpu", 21.3, "%"),
            ("battery", 76, "%"), ("thermal", 1, "state"),
            ("disk", 4096, "MB"), ("thread_count", 24, "count"),
            ("fd_count", 128, "count"),
        ]
        for (name, value, unit) in metrics {
            transport.enqueue(TDEvent(kind: "mobile_metric",
                                      fields: ["name": name, "value": value, "unit": unit]))
        }
        recordNetwork(url: "https://example.com/api/v1/orders/12345?debug=1", method: "GET",
                      status: 200, durationMs: 186, success: true,
                      dnsMs: 12, tcpMs: 34, tlsMs: 51, ttfbMs: 120,
                      requestBytes: 512, responseBytes: 2048)
        recordANR(durationMs: 820, stack: "0   TrueDepthDemo2   0x0000000102a4c1d8 -[TBHome layout]", thresholdMs: 250)
        recordOOM(footprintMb: 1180, reason: "jetsam")
        recordCrash(message: "NSInvalidArgumentException: unrecognized selector sent to instance",
                    stack: "0   TrueDepthDemo2   0x0000000102a4c1d8 -[TBFinanceHomeViewController reload:]",
                    exceptionType: "NSInvalidArgumentException")
        recordNonFatal(message: "NSCocoaErrorDomain(3840): JSON 解析失败，已降级为空列表",
                       stack: "0   TrueDepthDemo2   0x0000000102a4c1d8 -[TBFeed decode:]")
        transport.flush()
        TDMonitorLog.record("smoke events emitted")
    }

    /// 三条网络路径各打一发，验证「完成回调拦截」与「显式 session 的分阶段耗时」
    /// 在真机上都通，并覆盖一次失败分类。
    private func emitNetworkProbes(ingestURL: URL) {
        var components = URLComponents(url: ingestURL, resolvingAgainstBaseURL: false)
        components?.path = "/api/v1/health"
        components?.query = nil
        guard let probeURL = components?.url else { return }

        // 路径 3：普通 session + 完成回调 → 成功率 / 状态码 / 总耗时 / 流量
        let plainConfig = URLSessionConfiguration.default
        plainConfig.timeoutIntervalForRequest = 5
        let plain = URLSession(configuration: plainConfig)
        plain.dataTask(with: probeURL).resume()

        // 路径 1：显式可观测 session → 额外拿到 DNS / TCP / TLS / TTFB
        let instrumentedConfig = URLSessionConfiguration.ephemeral
        instrumentedConfig.timeoutIntervalForRequest = 5
        let instrumented = makeInstrumentedSession(configuration: instrumentedConfig)
        instrumented.dataTask(with: probeURL).resume()

        // 失败分类：不可路由地址，验证 network_error 的 category / errorCode
        var failing = URLComponents(url: probeURL, resolvingAgainstBaseURL: false)
        failing?.host = "192.0.2.1"
        if let failingURL = failing?.url {
            let failingConfig = URLSessionConfiguration.ephemeral
            failingConfig.timeoutIntervalForRequest = 3
            let failingSession = makeInstrumentedSession(configuration: failingConfig)
            failingSession.dataTask(with: failingURL).resume()
        }
    }
    #endif
}
