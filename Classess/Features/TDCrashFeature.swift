import Foundation
#if canImport(UIKit)
import UIKit
#endif

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

            var attributes: [String: Any] = ["source": "TBCrashReporter",
                                             "forwardedFromPreviousSession": true]

            // dSYM 符号化前提：用崩溃进程落盘的镜像快照，而不是补发进程的 dyld 基址。
            // 补发是「下次启动」的新进程，mainUUID/mainLoadAddress 都指向错误的进程。
            // 主二进制 = dyld image 0（快照按 index 顺序采集），其余为动态库镜像。
            if let mainImage = parsed.binaryImages.first {
                if let uuid = mainImage["uuid"] as? String { attributes["appUUID"] = uuid }
                if let load = mainImage["loadAddress"] as? String { attributes["appLoadAddress"] = load }
            }
            if !parsed.binaryImages.isEmpty { attributes["binaryImages"] = parsed.binaryImages }

            // 宿主报告 context 里若带了会话 id，优先用它；否则从上一会话现场反查。
            // TDEvent 只接受合法 UUID；拿不到就保持当前会话，并把「为什么没挂回」
            // 写进 attributes，别让后台把「没挂回」误读成「就是本次会话的崩溃」。
            let fromHost = parsed.context["sessionId"]
                ?? parsed.context["session_id"]
                ?? parsed.context["td_session_id"]
            let fromState = runtime.appState.originSessionId(for: parsed.timestamp)
            let originSessionId = fromHost ?? fromState
            attributes["originSessionIdSource"] = fromHost != nil ? "host_report"
                : (fromState != nil ? "app_state" : "unavailable")

            // 2026-11-17 口径迁移第一步：两套面包屑合并，不再二选一。
            // 宿主崩溃报告的操作路径（host）+ TD store 上一会话的生命周期事件合并成
            // 单条时间线；溯源计数放 attributes（自由字典），不塞进面包屑条目，
            // 避免后台严格 breadcrumbSchema 因多余字段把整批 native_crash 422。
            let hostCrumbs = parsed.breadcrumbs
            let storeCrumbs = bridge.previousSessionBreadcrumbs
            let merged = TDBreadcrumbMerger.merge(hostCrumbs, storeCrumbs)
            for (key, value) in TDBreadcrumbMerger.provenance(
                hostCount: hostCrumbs.count,
                storeCount: storeCrumbs.count,
                mergedCount: merged.count
            ) {
                attributes[key] = value
            }

            bridge.recordCrash(
                message: parsed.message,
                stack: parsed.stack,
                signal: parsed.signal,
                exceptionType: parsed.exceptionType,
                symbolicated: parsed.symbolicated,
                frames: parsed.frames,
                breadcrumbs: merged,
                extraAttributes: attributes,
                occurredAt: parsed.timestamp,
                originSessionId: originSessionId
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

