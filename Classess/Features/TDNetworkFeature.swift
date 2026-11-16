import Foundation
#if canImport(UIKit)
import UIKit
#endif

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

