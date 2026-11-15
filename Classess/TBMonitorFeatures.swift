import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 能力单元总览
//
// 每个类型对应一项可独立安装、独立卸载的采集能力。约定：
//
// 1. `init?` 返回 nil = 当前环境不支持该能力（iOS 版本、配置关闭）。
//    注册表静默跳过，其余能力照常安装。这是「iOS 13 没有 MXAppExitMetric
//    怎么办」的答案：能力不存在，其余全部正常，且 `cap.*` 会在
//    session_start 里如实自报 0。
// 2. `install()` 返回 false = 运行期安装失败，同样不阻断其它能力。
// 3. 跨能力取依赖一律走 `runtime.service(_:)`，不持有对方实例引用。
//
// 与业界对照：
// - Sentry `SentryIntegrationProtocol` / `SwiftIntegration`：可失败初始化器、
//   `static var name`、`uninstall()`，由 `SentrySDKInternal.installIntegrations`
//   在 Hub 建好后统一安装
// - Datadog `DatadogCore` + 各 Feature 模块：能力以模块为粒度独立引入，
//   依赖由 Core 的依赖容器（FeatureBaggage）统一提供

// MARK: - 1. 终止归因

/// 上一次会话是怎么死的。
///
/// **必须是第一个能力**：结论要随第一条 `session_start` 发出，晚于它就永远
/// 缺这一个维度（而 OOM / 看门狗恰恰是最需要历史上下文的指标）。
final class TDAttributionFeature: TDMonitorFeature {

    static let name = "attribution"

    private let runtime: TDMonitorRuntime

    init?(runtime: TDMonitorRuntime) {
        self.runtime = runtime
    }

    func install() -> Bool {
        // 后台任务计数钩子。不装它，background_task_timeout 归因分支是死代码。
        runtime.appState.installBackgroundTaskHook()

        if let verdict = runtime.appState.beginSession(
            sessionId: runtime.context.sessionId,
            appVersion: runtime.context.appVersion,
            buildNumber: runtime.context.buildNumber
        ) {
            runtime.provide(verdict)
            TDMonitorLog.record(
                "上次退出归因 \(verdict.attribution.rawValue) 置信度 \(verdict.confidence) "
                    + "证据=\(verdict.reasons.joined(separator: "; "))",
                level: "info")
        } else {
            TDMonitorLog.record("无上次会话现场（首次启动或现场已消费）", level: "info")
        }
        return true
    }

    func uninstall() {
        runtime.appState.markStopped()
    }
}

// MARK: - 2. 崩溃桥接与会话

/// 崩溃补发、面包屑、会话开始/结束，以及所有 `record*` 手动上报的落点。
final class TDCrashFeature: TDMonitorFeature {

    static let name = "crash"
    static let requires = ["attribution"]

    private let runtime: TDMonitorRuntime
    private let bridge: TDCrashBridge
    private var installedAt: Date?

    init?(runtime: TDMonitorRuntime) {
        self.runtime = runtime
        self.bridge = TDCrashBridge(sink: runtime.sink)
    }

    func install() -> Bool {
        runtime.provide(bridge)
        installedAt = runtime.clock.now
        // 归因结论 + 能力矩阵随 session_start 一起发出。
        bridge.start(termination: runtime.service(TDTerminationVerdict.self),
                     capabilities: runtime.capabilities)
        forwardPendingCrashReports(TDMonitor.hostCrashReportPaths?() ?? [])
        return true
    }

    func uninstall() {
        guard let startedAt = installedAt else { return }
        bridge.endSession(uptimeMs: runtime.clock.now.timeIntervalSince(startedAt) * 1000)
        installedAt = nil
    }

    /// 解析宿主落盘的崩溃 JSON 并转成 `native_crash`。
    /// 已补发过的 id 会记住，重启不会重复上报。
    @discardableResult
    func forwardPendingCrashReports(_ paths: [String]) -> Int {
        guard !paths.isEmpty else { return 0 }
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
            runtime.sink.flush()
        }
        return count
    }
}

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

// MARK: - 4. 资源采样

final class TDResourceFeature: TDMonitorFeature {

    static let name = "resources"

    private let runtime: TDMonitorRuntime
    private let monitor: TDResourceMonitor

    init?(runtime: TDMonitorRuntime) {
        guard runtime.configuration.autoCollect else { return nil }
        self.runtime = runtime
        self.monitor = TDResourceMonitor(config: runtime.configuration,
                                         sink: runtime.sink,
                                         appState: runtime.appState)
    }

    func install() -> Bool {
        runtime.provide(monitor)
        monitor.start()
        return true
    }

    func uninstall() {
        monitor.stop()
    }
}

// MARK: - 6. ANR / 卡顿

/// 主线程卡顿检测 + 真实栈采样。
///
/// 卡顿**进行中**每秒把时长落盘：被系统看门狗 SIGKILL 时进程直接消失，
/// 内存里的这条 ANR 一条都发不出去。没有进度落盘，最严重的那类卡顿
/// 恰好是数据完全空白的那一类。
final class TDANRFeature: TDMonitorFeature {

    static let name = "anr"
    static let requires = ["crash"]

    private let runtime: TDMonitorRuntime
    private let watchdog: TDHangWatchdog

    init?(runtime: TDMonitorRuntime) {
        guard let bridge = runtime.service(TDCrashBridge.self) else { return nil }
        self.runtime = runtime
        let appState = runtime.appState
        self.watchdog = TDHangWatchdog(
            thresholdMs: runtime.configuration.hangThresholdMs,
            reportThresholdMs: runtime.configuration.anrReportThresholdMs,
            // 致命推测阈值复用终止归因里的同一个常量，避免两处各写一个 8000
            // 之后悄悄漂移——那样"卡顿说 8s 致命、归因说 10s 致命"就没人能解释了。
            fatalThresholdMs: TDTerminationClassifier.watchdogHangThresholdMs,
            sampleIntervalMs: runtime.configuration.anrSampleIntervalMs,
            maxHangMs: runtime.configuration.maxHangMs,
            foregroundProvider: { appState.isForeground },
            onProgress: { elapsedMs in
                appState.recordHang(durationMs: elapsedMs)
            },
            onHang: { report in
                bridge.recordANR(durationMs: report.durationMs,
                                 stack: report.stack,
                                 thresholdMs: report.thresholdMs,
                                 sampleCount: report.sampleCount,
                                 frames: report.frames,
                                 screen: report.screen,
                                 reportThresholdMs: report.reportThresholdMs,
                                 severity: report.severity,
                                 blockType: report.blockType,
                                 framesDuring: report.framesDuring,
                                 foreground: report.foreground)
            }
        )
    }

    func install() -> Bool {
        watchdog.start()
        return true
    }

    func uninstall() {
        watchdog.stop()
    }
}

// MARK: - 7. 原生长任务

final class TDLongTaskFeature: TDMonitorFeature {

    static let name = "long_task"
    static let requires = ["crash"]

    private let runtime: TDMonitorRuntime
    private let monitor: TDLongTaskMonitor

    init?(runtime: TDMonitorRuntime) {
        guard let bridge = runtime.service(TDCrashBridge.self) else { return nil }
        self.runtime = runtime
        self.monitor = TDLongTaskMonitor(thresholdMs: runtime.configuration.longTaskThresholdMs) {
            duration, screen in
            bridge.recordLongTask(durationMs: duration, screen: screen)
        }
    }

    func install() -> Bool {
        monitor.start()
        return true
    }

    func uninstall() {
        monitor.stop()
    }
}

// MARK: - 8. 网络

/// 成功率 / 状态码 / 分阶段耗时 / 失败分类 / 重试 / 流量。
final class TDNetworkFeature: TDMonitorFeature {

    static let name = "network"
    static let requires = ["crash"]

    private let runtime: TDMonitorRuntime

    init?(runtime: TDMonitorRuntime) {
        guard runtime.configuration.networkInstrumentation else { return nil }
        guard runtime.service(TDCrashBridge.self) != nil else { return nil }
        self.runtime = runtime
    }

    func install() -> Bool {
        let ingestURL = runtime.configuration.ingestURL
        let runtime = self.runtime
        TDNetworkInstrumentation.shared.install(ingestURL: ingestURL) { sample in
            Self.handle(sample, runtime: runtime)
        }
        return true
    }

    func uninstall() {
        TDNetworkInstrumentation.shared.uninstall()
    }

    private static func handle(_ sample: TDNetworkSample, runtime: TDMonitorRuntime) {
        guard let bridge = runtime.service(TDCrashBridge.self) else { return }
        let classifier = TDNetworkClassifier()
        let classification = classifier.classify(sample, networkType: runtime.context.networkType)
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
            endpoint: sample.endpoint,
            traceId: sample.traceId,
            extraAttributes: [
                "protocol": sample.protocolName ?? "unknown",
                "reusedConnection": sample.reusedConnection,
                "transactions": sample.transactionCount,
                "cached": sample.cached,
            ]
        )
    }
}

// MARK: - 9. 页面（加载耗时 + 渲染质量）

/// 页面加载耗时与页面级渲染质量共用同一处方法交换，因此合成一个能力单元。
///
/// 两个指标回答不同问题，缺一不可：
/// - `view_load`：这个页面多久能被看到（`willAppear→didAppear` / `load→didAppear`）
/// - `screen_render`：看到之后卡不卡（慢帧率 / 冻结帧率 / 卡顿时长占比）
final class TDScreenFeature: TDMonitorFeature {

    static let name = "screen"

    private let runtime: TDMonitorRuntime

    init?(runtime: TDMonitorRuntime) {
        guard runtime.configuration.viewLoadInstrumentation else { return nil }
        self.runtime = runtime
    }

    func install() -> Bool {
        let runtime = self.runtime
        let sliceSeconds = runtime.configuration.screenSliceSeconds

        TDViewControllerInstrumentation.shared.install { screen, appearMs, loadMs in
            guard Self.shouldSample(runtime.configuration.sampleRate) else { return }
            runtime.service(TDCrashBridge.self)?
                .recordViewLoad(screen: screen, durationMs: appearMs, renderMs: loadMs)
        }

        // 停留超过 sliceSeconds 也结算一片发出，保证长停留页面（首页、播放页）
        // 同样有数据，而不是「不走就永远没数据」。
        TDScreenFrameTracker.shared.configure(sliceSeconds: sliceSeconds) { report in
            guard Self.shouldSample(runtime.configuration.sampleRate) else { return }
            Self.report(report, sink: runtime.sink)
        }
        return true
    }

    func uninstall() {
        TDViewControllerInstrumentation.shared.uninstall()
        TDScreenFrameTracker.shared.unconfigure()
    }

    private static func shouldSample(_ rate: Double) -> Bool {
        rate >= 1 || Double.random(in: 0..<1) <= rate
    }

    private static func report(_ report: TDScreenRenderReport, sink: TDEventSink) {
        sink.enqueue(TDEvent(
            kind: "mobile_metric",
            fields: [
                "name": "screen_render",
                "durationMs": report.durationMs,
                "screen": report.screen,
            ],
            attributes: [
                "screen": report.screen,
                // slice = 页面还在，按窗口切的一片；final = 页面已消失
                "phase": report.phase,
                // 慢帧率：超过当前设备一帧预算 1.5 倍的帧占比
                "slowFrameRate": report.slowFrameRate,
                // 冻结帧率：单帧超过 700ms 的占比，用户能明确感知界面冻住
                "frozenFrameRate": report.frozenFrameRate,
                // 卡顿时长占比，对偶发长卡比帧占比更敏感
                "hitchRatio": report.hitchRatio,
                "hitchMs": report.hitchMs,
                "frameCount": report.frameCount,
                "slowFrames": report.slowFrames,
                "frozenFrames": report.frozenFrames,
                // 帧预算随设备刷新率变化，跨设备对比时必须带上这个维度
                "budgetMs": (report.frameBudget * 1000 * 100).rounded() / 100,
                "refreshRateHz": Int((1 / max(report.frameBudget, 1.0 / 240.0)).rounded()),
            ]
        ))
    }
}

// MARK: - 10. 非致命异常

final class TDNonFatalFeature: TDMonitorFeature {

    static let name = "non_fatal"
    static let requires = ["crash"]

    private let runtime: TDMonitorRuntime

    init?(runtime: TDMonitorRuntime) {
        guard runtime.configuration.nonFatalCapture else { return nil }
        guard runtime.service(TDCrashBridge.self) != nil else { return nil }
        self.runtime = runtime
    }

    func install() -> Bool {
        let runtime = self.runtime
        TDNonFatalRecorder.shared.install { message, stack, category, attributes in
            runtime.service(TDCrashBridge.self)?
                .recordNonFatal(message: message, stack: stack,
                                category: category, attributes: attributes)
        }
        return true
    }

    func uninstall() {
        TDNonFatalRecorder.shared.uninstall()
    }
}

// MARK: - 11. MetricKit

/// 系统权威诊断源。**只有 iOS 14+ 存在**。
///
/// iOS 13 上这个能力整体不存在：`init?` 不会被调用，注册表跳过，
/// 其余能力全部正常。这是版本门槛的架构级处理——不是运行时到处
/// `if #available` 打补丁，而是能力本身的有无。
@available(iOS 14.0, *)
final class TDMetricKitFeature: TDMonitorFeature {

    static let name = "metrickit"
    static let requires = ["crash"]

    private let runtime: TDMonitorRuntime
    private let exit: TDExitDiagnostics
    private let bridge: TDMetricKitBridge

    init?(runtime: TDMonitorRuntime) {
        self.runtime = runtime
        self.exit = TDExitDiagnostics(sink: runtime.sink)
        self.bridge = TDMetricKitBridge(sink: runtime.sink, exitDiagnostics: exit)
    }

    func install() -> Bool {
        true
    }

    func uninstall() {
        bridge.stop()
    }
}

// MARK: - 12. 生命周期

/// 前后台切换：维度刷新、热启动计时、面包屑、进后台落盘。
final class TDLifecycleFeature: TDMonitorFeature {

    static let name = "lifecycle"

    private let runtime: TDMonitorRuntime
    private var observers: [NSObjectProtocol] = []
    /// 进入前台的时刻，用于测量热启动（仅主线程访问）。
    private var foregroundEnteredAt: Date?

    init?(runtime: TDMonitorRuntime) {
        #if canImport(UIKit)
        self.runtime = runtime
        #else
        return nil
        #endif
    }

    func install() -> Bool {
        #if canImport(UIKit)
        let center = NotificationCenter.default
        let queue = OperationQueue.main
        let runtime = self.runtime

        let willEnter = center.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                           object: nil, queue: queue) { [weak self] _ in
            self?.foregroundEnteredAt = Date()
        }

        let active = center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                        object: nil, queue: queue) { [weak self] _ in
            guard let self = self else { return }
            runtime.context.foreground = true
            runtime.context.refreshNetworkType()
            runtime.service(TDResourceMonitor.self)?.setForeground(true)
            runtime.service(TDCrashBridge.self)?.addBreadcrumb(category: "app", message: "foreground", level: "info")

            // 热启动：进程仍在内存里，用户从后台切回。
            // 冷启动走 TDLaunchFeature，这里是「回到前台到可交互」的实测耗时。
            if let entered = self.foregroundEnteredAt {
                let durationMs = Date().timeIntervalSince(entered) * 1000
                self.foregroundEnteredAt = nil
                runtime.sink.enqueue(TDEvent(
                    kind: "mobile_metric",
                    fields: ["name": "app_launch", "durationMs": durationMs, "unit": "ms"],
                    attributes: ["type": "warm", "phase": "foreground_to_active"]
                ))
            }
            runtime.sink.flush()
        }

        let background = center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                            object: nil, queue: queue) { _ in
            runtime.context.foreground = false
            runtime.service(TDResourceMonitor.self)?.setForeground(false)
            let bridge = runtime.service(TDCrashBridge.self)
            bridge?.addBreadcrumb(category: "app", message: "background", level: "info")
            // 落盘轨迹与内存现场：进程随时可能在后台被杀
            bridge?.flushBreadcrumbs()
            runtime.service(TDCrashFeature.self)?
                .forwardPendingCrashReports(TDMonitor.hostCrashReportPaths?() ?? [])
            runtime.sink.flushInBackground()
        }

        let terminate = center.addObserver(forName: UIApplication.willTerminateNotification,
                                           object: nil, queue: queue) { _ in
            // 用户上划强杀或系统请求退出：标记后下次启动不会把它误判成 OOM。
            // 被 jetsam / 看门狗 SIGKILL 时这里不会被调用，正是这个差异
            // 让「强杀」与「系统杀」能够区分开。
            runtime.appState.markCleanExit(initiator: "will_terminate")
            TDMonitor.shared.stop()
        }

        observers = [willEnter, active, background, terminate]
        return true
        #else
        return false
        #endif
    }

    func uninstall() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }
}
