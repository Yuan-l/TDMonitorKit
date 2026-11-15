import Foundation

// MARK: - metrics → sample 的唯一映射
//
// 单点映射不是整理代码口味的问题。分段耗时的口径一旦有两份实现，
// 就会出现「业务请求的 TTFB 是 120ms，上报自己发的探活是 340ms」这种
// 对不上的情况，而排查的人第一反应是怀疑后端。
// 所以 legacy swizzle 路径和新的 client 路径都走这一个函数。

public enum TDNetworkMetricsMapper {

    /// 把系统指标折成一条样本。
    ///
    /// 多段事务（重定向、HTTP/2 连接迁移）的处理：
    /// DNS / TCP / TLS 是**累加**，TTFB 只取**最后一段**。
    /// 理由：前三者每段都是真实发生的等待，累加才等于「这条请求一共等了多久」；
    /// 而 TTFB 描述的是「最后一次请求发出去到首字节回来」，把重定向链上
    /// 每一跳的 TTFB 加起来没有业务含义——用户感知的是最后那次。
    public static func makeSample(
        url: String,
        method: String,
        status: Int,
        errorDomain: String?,
        errorCode: Int?,
        metrics: URLSessionTaskMetrics?,
        requestBytes: Int64?,
        responseBytes: Int64?
    ) -> TDNetworkSample {
        var dnsMs: Double = 0
        var tcpMs: Double = 0
        var tlsMs: Double = 0
        var ttfbMs: Double = 0
        var sawDNS = false, sawTCP = false, sawTLS = false, sawTTFB = false

        let transactions = metrics?.transactionMetrics ?? []
        for transaction in transactions {
            if let start = transaction.domainLookupStartDate,
               let end = transaction.domainLookupEndDate {
                dnsMs += end.timeIntervalSince(start) * 1000; sawDNS = true
            }
            if let start = transaction.connectStartDate,
               let end = transaction.connectEndDate {
                tcpMs += end.timeIntervalSince(start) * 1000; sawTCP = true
            }
            if let start = transaction.secureConnectionStartDate,
               let end = transaction.secureConnectionEndDate {
                tlsMs += end.timeIntervalSince(start) * 1000; sawTLS = true
            }
            if let start = transaction.requestStartDate,
               let end = transaction.responseStartDate {
                ttfbMs = end.timeIntervalSince(start) * 1000; sawTTFB = true
            }
        }

        let last = transactions.last
        let durationMs = metrics.map { $0.taskInterval.duration * 1000 } ?? 0

        return TDNetworkSample(
            url: url,
            method: method,
            status: status,
            durationMs: durationMs,
            dnsMs: sawDNS ? dnsMs : nil,
            tcpMs: sawTCP ? tcpMs : nil,
            tlsMs: sawTLS ? tlsMs : nil,
            ttfbMs: sawTTFB ? ttfbMs : nil,
            requestBytes: requestBytes,
            responseBytes: responseBytes,
            errorDomain: errorDomain,
            errorCode: errorCode,
            protocolName: last?.networkProtocolName,
            reusedConnection: last?.isReusedConnection ?? false,
            transactionCount: transactions.count,
            cached: last?.resourceFetchType == .localCache)
    }
}

// MARK: - 内置 adapter：注入链路 ID

/// 把 `context.traceId` 写进请求头。
///
/// 这一层是「网络失败」和「崩溃 / 卡顿」能串起来的唯一前提：
/// 崩溃发生时，breadcrumb 里带着 traceId，后端反查同一 traceId 的
/// 网络记录，就能判断「是不是某个接口超时导致用户反复重试最后崩了」。
///
/// 没有这个 header，两边的数据只能在时间戳上相邻，无法证明因果。
final class TDTraceAdapter: TDRequestAdapter {

    private let headerName: String

    init(headerName: String = "X-TD-Trace-Id") {
        self.headerName = headerName
    }

    func adapt(_ request: TDNetworkRequest, context: TDNetworkContext) throws -> TDNetworkRequest {
        var mutated = request
        // 业务自己传了 trace 就尊重业务值：业务可能已经在用同一套链路追踪，
        // 覆盖掉它会让业务侧的日志和我们的报表对不上。
        if let existing = mutated.headers[headerName], !existing.isEmpty { return mutated }
        mutated.headers[headerName] = context.traceId
        if mutated.tag.traceId == nil {
            mutated.tag.traceId = context.traceId
        }
        return mutated
    }
}

// MARK: - 内置 retrier：只重试幂等请求

/// 幂等重试。
///
/// 三条约束，每一条都是为了避免「重试反而制造故障」：
/// 1. **只重试 `isIdempotent == true` 的请求**。`POST` 超时时服务端可能已经处理成功，
///    重发就是重复下单 / 重复扣款。这类损失无法用「重试率下降」来换。
/// 2. **只重试传输层瞬时错误**，不重试 4xx。401 重试一百次还是 401，
///    只会把鉴权失败放大成流量洪峰。
/// 3. **有次数上限 + 指数退避 + 抖动**。没有抖动的话，一次后端抖动会让
///    所有客户端在同一秒集体重发，把「部分失败」放大成「全量雪崩」。
final class TDIdempotentRetrier: TDRequestRetrier {

    private let maxAttempts: Int
    private let baseDelay: TimeInterval
    private let maxDelay: TimeInterval

    /// 可重试的传输层错误码。
    ///
    /// 刻意不包含 `NSURLErrorCancelled`（取消是用户意图，重试会复活已取消的请求）、
    /// `NSURLErrorServerCertificateUntrusted`（证书错误重试永远不会成功）、
    /// `NSURLErrorNotConnectedToInternet`（应由网络恢复事件驱动，而不是盲目重试）。
    private static let transientCodes: Set<Int> = [
        NSURLErrorTimedOut,
        NSURLErrorNetworkConnectionLost,
        NSURLErrorCannotConnectToHost,
        NSURLErrorDNSLookupFailed,
        NSURLErrorSecureConnectionFailed,
        NSURLErrorRequestBodyStreamExhausted,
    ]

    /// 可重试的 HTTP 状态码。503 是服务端明确表示「暂时不可用」，
    /// 429 是限流——两者都建议客户端稍后再来。
    private static let transientStatuses: Set<Int> = [429, 503, 504]

    init(maxAttempts: Int = 2, baseDelay: TimeInterval = 0.5, maxDelay: TimeInterval = 8) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    func shouldRetry(_ result: TDNetworkResult, context: TDNetworkContext) -> TDRetryDecision {
        guard result.request.tag.isIdempotent else { return .doNotRetry }
        guard context.attempt < maxAttempts else { return .doNotRetry }

        let retriable: Bool
        if let error = result.error as NSError? {
            retriable = error.domain == NSURLErrorDomain
                && TDIdempotentRetrier.transientCodes.contains(error.code)
        } else {
            retriable = TDIdempotentRetrier.transientStatuses.contains(result.status)
        }
        guard retriable else { return .doNotRetry }

        let exponential = baseDelay * pow(2, Double(context.attempt))
        let capped = min(exponential, maxDelay)
        // 抖动取 [0.5, 1.0) 倍：下限不取 0 是为了保证确实退避了，
        // 上限不取 1.5 是为了不让单次等待翻倍到不可控。
        let jittered = capped * (0.5 + Double.random(in: 0..<0.5))
        return .retry(after: jittered, request: nil)
    }
}

// MARK: - 内置 observer：把结果转成事件
//
// 用 observer 而不是 adapter / retrier，是刻意的：
// 采集器在类型层面就该无法影响业务请求。它只能拿到已经发生的事实。

/// 把每次请求折成一条 `network` 事件投给出口。
final class TDNetworkSampleObserver: TDNetworkObserver {

    /// 交给上层接到 `TDCrashBridge.recordNetwork`。
    /// 不直接持 bridge，是为了让这个类可以脱离 SDK 单测。
    var onSample: ((TDNetworkSample) -> Void)?

    func client(_ client: TDNetworkClient, didComplete result: TDNetworkResult) {
        // 被短路的请求也要出样本。
        //
        // 缓存命中 / token 拿不到时根本没有网络流量，如果直接跳过，
        // 监控看到的是「这个接口从没被调用过」——而真相是「调了，一直在本地被挡」。
        // 这两者对排查是完全不同的结论。
        let error = result.error as NSError?
        let bodyBytes = result.request.body?.count
        var sample = TDNetworkMetricsMapper.makeSample(
            url: result.request.url.absoluteString,
            method: result.request.method,
            status: result.status,
            errorDomain: error?.domain ?? (result.shortCircuit != nil ? "TDShortCircuit" : nil),
            errorCode: error?.code ?? (result.shortCircuit != nil ? 0 : nil),
            metrics: result.metrics,
            requestBytes: bodyBytes.map(Int64.init),
            responseBytes: result.data.map { Int64($0.count) })
        sample.traceId = result.request.tag.traceId ?? result.context.traceId
        sample.endpoint = result.request.tag.endpoint
        sample.attempt = result.context.attempt
        sample.isInternal = result.request.tag.isInternal
        sample.metricsMissing = result.metricsMissing
        sample.shortCircuit = result.shortCircuit?.rawValue
        onSample?(sample)
    }
}
