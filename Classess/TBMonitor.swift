import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// TDMonitorKit 的公开入口。
///
/// `TDMonitor.shared.start()` 一行完成：会话标识、有界离线队列、启动分段、
/// 崩溃桥接、ANR 栈采样、长任务、FPS/掉帧、资源、网络分阶段、页面耗时、
/// 非致命异常、MetricKit 诊断。
///
/// 本 Kit **不注册** signal / NSException 崩溃处理器——宿主已经有一套，
/// 注册第二个会把宿主的实现顶掉。崩溃由宿主捕获落盘，这里负责补发与补全。
public final class TDMonitor {

    public static let shared = TDMonitor()

    private let lock = NSLock()
    private var configuration: TDMonitorConfiguration?
    private var context: TDContext?
    private var transport: TDTransport?
    private var bridge: TDCrashBridge?
    private var collectors: TDCollectors?
    private var resources: TDResourceMonitor?
    private var hangWatchdog: TDHangWatchdog?
    private var longTasks: TDLongTaskMonitor?
    private var launch: TDLaunchRecorder?
    private var metricKitBridge: AnyObject?
    private var exitDiagnostics: AnyObject?
    private var started = false
    private var sessionStartedAt: Date?
    /// 进入前台的时刻，用于测量热启动（仅在主线程访问）。
    private var foregroundEnteredAt: Date?
    private var lifecycleObservers: [NSObjectProtocol] = []

    private init() {}

    public var isEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return started
    }

    public var sessionId: String? {
        lock.lock(); defer { lock.unlock() }
        return context?.sessionId
    }

    /// 最近若干条 SDK 自身诊断，宿主可直接展示（有界，纯内存）。
    public var diagnostics: [String] { TDMonitorLog.snapshot() }

    // MARK: - 生命周期

    /// 读取 `TDMonitor.plist`（可用 `TD_MONITOR_API_KEY` / `TD_MONITOR_BASE_URL` 覆盖）。
    /// 配置缺失时完全静默关闭，不崩溃、不产生流量。
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
        let resources = TDResourceMonitor(config: configuration, transport: transport)
        self.configuration = configuration
        self.context = context
        self.transport = transport
        self.bridge = bridge
        self.collectors = collectors
        self.resources = resources
        self.sessionStartedAt = Date()
        self.started = true
        lock.unlock()

        TDStackSampler.registerMainThread()

        let launch = TDLaunchRecorder { [weak transport] fields in
            var payload = fields
            let durationMs = payload.removeValue(forKey: "durationMs") as? Double ?? 0
            var attributes = payload
            attributes["phase"] = "launch_to_first_frame"
            transport?.enqueue(TDEvent(
                kind: "mobile_metric",
                fields: ["name": "app_launch", "durationMs": durationMs, "unit": "ms"],
                attributes: attributes
            ))
        }
        self.launch = launch
        launch.markDidFinishLaunching()
        // 3 秒内宿主仍未标记首帧时兜底结算，保证指标不缺失。
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak launch] in
            launch?.forceEmitIfNeeded()
        }

        transport.start()
        bridge.start()
        collectors.start()
        resources.onMemoryWarning = { [weak bridge] in bridge?.markMemoryWarning() }
        resources.start()

        // ANR：阈值触发后按间隔采样主线程真实堆栈
        let watchdog = TDHangWatchdog(thresholdMs: configuration.hangThresholdMs,
                                      sampleIntervalMs: configuration.anrSampleIntervalMs,
                                      maxHangMs: configuration.maxHangMs) { [weak bridge] report in
            bridge?.recordANR(durationMs: report.durationMs,
                              stack: report.stack,
                              thresholdMs: report.thresholdMs,
                              sampleCount: report.sampleCount,
                              frames: report.frames,
                              screen: report.screen)
        }
        watchdog.start()
        self.hangWatchdog = watchdog

        // 原生长任务
        let longTasks = TDLongTaskMonitor(thresholdMs: configuration.longTaskThresholdMs) { [weak bridge] duration, screen in
            bridge?.recordLongTask(durationMs: duration, screen: screen)
        }
        longTasks.start()
        self.longTasks = longTasks

        if configuration.networkInstrumentation {
            TDNetworkInstrumentation.shared.install(ingestURL: configuration.ingestURL) { [weak self] sample in
                self?.handleNetwork(sample)
            }
        }
        if configuration.viewLoadInstrumentation {
            TDViewControllerInstrumentation.shared.install { [weak self] screen, appearMs, loadMs in
                self?.handleViewLoad(screen: screen, appearMs: appearMs, loadMs: loadMs)
            }
        }
        if configuration.nonFatalCapture {
            TDNonFatalRecorder.shared.install { [weak bridge] message, stack, category, attributes in
                bridge?.recordNonFatal(message: message, stack: stack,
                                       category: category, attributes: attributes)
            }
        }

        observeLifecycle()
        attachMetricKit(transport: transport)

        // 补发宿主上次落盘的崩溃（此时 bridge 已持有上次会话的面包屑）
        forwardPendingCrashReports(TDMonitor.hostCrashReportPaths?() ?? [])

        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if environment["TD_MONITOR_SMOKE"] == "1" {
            emitSampleEvents()
        }
        // 真机验证用：真实阻塞主线程 900ms，验证「阈值 → 栈采样 → 上报」整条链路。
        // Release 不编译，不会成为线上可触发的开关。
        if environment["TD_MONITOR_HANG_TEST"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                Thread.sleep(forTimeInterval: 0.9)
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
        #endif
        return true
    }

    #if DEBUG
    /// `TD_MONITOR_NETWORK_TEST=1`：三条网络路径各打一发，验证「完成回调拦截」与
    /// 「显式 session 的分阶段耗时」在真机上都通，并覆盖一次失败分类。
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

    /// 首帧渲染完成后调用（`window.makeKeyAndVisible()` 之后）。
    /// 不调用也能工作：3 秒后会用兜底逻辑结算，只是首帧耗时略偏大。
    public func markFirstFrame() {
        launch?.markFirstFrameWhenRendered()
    }

    /// 宿主可注入崩溃报告文件路径，避免为了一个回调引入组件依赖。
    public static var hostCrashReportPaths: (() -> [String])?

    public func flush() { transport?.flush() }
    public func flushInBackground() { transport?.flushInBackground() }

    /// 仅在明确终止时调用。退到后台**不**标记为干净退出，
    /// 否则 Jetsam / 看门狗杀进程将无法在下次启动被识别。
    public func stop() {
        guard isEnabled else { return }
        bridge?.markCleanExit()
        if let started = sessionStartedAt {
            bridge?.endSession(uptimeMs: Date().timeIntervalSince(started) * 1000)
        }
        collectors?.stop()
        resources?.stop()
        hangWatchdog?.stop()
        longTasks?.stop()
        transport?.flushInBackground()
    }

    // MARK: - 维度

    public func setUserId(_ userId: String?) { context?.userId = userId }
    public func refreshNetworkType() { context?.refreshNetworkType() }
    public func setScreen(_ screen: String?) { TDScreenContext.shared.update(screen) }

    /// 创建带**分阶段耗时**采集的 session。
    ///
    /// DNS / TCP / TLS / TTFB 只能来自 `URLSessionTaskMetrics`，而它只通过 delegate 回调交付。
    /// iOS 18 起 `URLSession` 的初始化器不再是 ObjC 方法，SDK 无法再自动接管业务已有 session，
    /// 因此需要分阶段数据的页面请用这个方法创建 session：
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

    // MARK: - 自动采集回填

    private func handleNetwork(_ sample: TDNetworkSample) {
        guard let bridge = bridge, let context = context else { return }
        let classification = networkClassifier.classify(sample, networkType: context.networkType)
        let success = sample.status > 0 && sample.status < 400 && sample.errorCode == nil
        bridge.recordNetwork(
            url: sample.url,
            method: sample.method,
            status: sample.status,
            durationMs: sample.durationMs,
            success: success,
            dnsMs: sample.dnsMs,
            tcpMs: sample.tcpMs,
            tlsMs: sample.tlsMs,
            ttfbMs: sample.ttfbMs,
            requestBytes: sample.requestBytes,
            responseBytes: sample.responseBytes,
            errorCode: sample.errorCode,
            category: classification.category,
            retryAttempt: classification.retryAttempt,
            weakNetwork: classification.weakNetwork,
            extraAttributes: [
                "protocol": sample.protocolName ?? "unknown",
                "reusedConnection": sample.reusedConnection,
                "transactions": sample.transactionCount,
                "cached": sample.cached,
            ]
        )
    }

    private let networkClassifier = TDNetworkClassifier()

    private func handleViewLoad(screen: String, appearMs: Double, loadMs: Double?) {
        guard let configuration = configuration else { return }
        if configuration.sampleRate < 1 && Double.random(in: 0..<1) > configuration.sampleRate { return }
        bridge?.recordViewLoad(screen: screen, durationMs: appearMs, renderMs: loadMs)
    }

    // MARK: - 崩溃补发

    /// 解析宿主落盘的 JSON 并转成 `native_crash`。已补发过的 id 会记住，
    /// 重启不会重复上报。
    @discardableResult
    public func forwardPendingCrashReports(_ paths: [String]) -> Int {
        guard transport != nil, let bridge = bridge, !paths.isEmpty else { return 0 }
        let defaults = UserDefaults(suiteName: "com.truedepth.monitor") ?? .standard
        var forwarded = Set<String>(defaults.stringArray(forKey: "td_forwarded_crash_ids") ?? [])
        var count = 0

        for path in paths.prefix(100) {
            guard let parsed = TDCrashReportParser.parse(url: URL(fileURLWithPath: path)) else { continue }
            if forwarded.contains(parsed.id) { continue }

            var attributes: [String: Any] = ["source": "TBCrashReporter"]
            if let uuid = TDBinaryImage.mainUUID { attributes["appUUID"] = uuid }

            bridge.recordCrash(
                message: parsed.message,
                stack: parsed.stack,
                signal: parsed.signal,
                exceptionType: parsed.exceptionType,
                symbolicated: false,
                frames: parsed.frames,
                breadcrumbs: parsed.breadcrumbs.isEmpty ? bridge.previousSessionBreadcrumbs : parsed.breadcrumbs,
                extraAttributes: attributes
            )
            forwarded.insert(parsed.id)
            count += 1
        }
        if count > 0 {
            defaults.set(Array(forwarded.suffix(500)), forKey: "td_forwarded_crash_ids")
            transport?.flush()
        }
        return count
    }

    // MARK: - 内部

    private func attachMetricKit(transport: TDTransport) {
        #if canImport(MetricKit)
        if #available(iOS 14.0, *) {
            let exit = TDExitDiagnostics(transport: transport)
            exitDiagnostics = exit
            metricKitBridge = TDMetricKitBridge(transport: transport, exitDiagnostics: exit)
        }
        #endif
    }

    private func observeLifecycle() {
        #if canImport(UIKit)
        let center = NotificationCenter.default
        let queue = OperationQueue.main
        let willEnter = center.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                           object: nil, queue: queue) { [weak self] _ in
            self?.foregroundEnteredAt = Date()
        }
        let active = center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                        object: nil, queue: queue) { [weak self] _ in
            guard let self = self else { return }
            self.context?.foreground = true
            self.context?.refreshNetworkType()
            self.resources?.setForeground(true)
            self.breadcrumb("app", "foreground", level: "info")

            // 热启动：进程仍在内存里，用户从后台切回。冷启动走 TDLaunchRecorder，
            // 这里是「回到前台到可交互」的实测耗时。
            if let entered = self.foregroundEnteredAt {
                let durationMs = Date().timeIntervalSince(entered) * 1000
                self.foregroundEnteredAt = nil
                self.transport?.enqueue(TDEvent(
                    kind: "mobile_metric",
                    fields: ["name": "app_launch", "durationMs": durationMs, "unit": "ms"],
                    attributes: ["type": "warm", "phase": "foreground_to_active"]
                ))
            }
            self.flush()
        }
        let background = center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                            object: nil, queue: queue) { [weak self] _ in
            guard let self = self else { return }
            self.context?.foreground = false
            self.resources?.setForeground(false)
            self.breadcrumb("app", "background", level: "info")
            // 落盘轨迹与内存现场：进程随时可能在后台被杀
            self.bridge?.flushBreadcrumbs()
            self.forwardPendingCrashReports(TDMonitor.hostCrashReportPaths?() ?? [])
            self.flushInBackground()
        }
        let terminate = center.addObserver(forName: UIApplication.willTerminateNotification,
                                           object: nil, queue: queue) { [weak self] _ in
            self?.stop()
        }
        lock.lock()
        lifecycleObservers = [willEnter, active, background, terminate]
        lock.unlock()
        #endif
    }

    #if DEBUG
    /// `TD_MONITOR_SMOKE=1`：每类信号发一条，用于在没有真实流量的情况下验证链路。
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
        let sample = TDNetworkSample(
            url: "https://example.com/api/v1/orders/12345?debug=1", method: "GET", status: 200,
            durationMs: 186, dnsMs: 12, tcpMs: 34, tlsMs: 51, ttfbMs: 120,
            requestBytes: 512, responseBytes: 2048, errorDomain: nil, errorCode: nil,
            protocolName: "h2", reusedConnection: true, transactionCount: 1, cached: false
        )
        handleNetwork(sample)
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
    #endif
}
