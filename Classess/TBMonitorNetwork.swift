import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// 一次请求的可观测结果。
struct TDNetworkSample {
    let url: String
    let method: String
    let status: Int
    let durationMs: Double
    let dnsMs: Double?
    let tcpMs: Double?
    let tlsMs: Double?
    let ttfbMs: Double?
    let requestBytes: Int64?
    let responseBytes: Int64?
    let errorDomain: String?
    let errorCode: Int?
    let protocolName: String?
    let reusedConnection: Bool
    let transactionCount: Int
    let cached: Bool
}

/// 关联对象 key。放文件级变量，避免静态存储属性在严格并发检查下的告警。
private var tdProxyAssociationKey: UInt8 = 0
private var tdCallContextKey: UInt8 = 0
private var tdReportedKey: UInt8 = 0

/// URLSession 自动埋点。
///
/// 分阶段耗时（DNS / TCP / TLS / TTFB）只有一个来源：`URLSessionTaskMetrics`，
/// 而它只通过 delegate 回调交付。历史做法是替换
/// `initWithConfiguration:delegate:delegateQueue:` 给每个新 session 套一层代理——
/// 但 iOS 18 起 Foundation 的 `URLSession` 初始化器不再是 ObjC 方法
/// （`class_getInstanceMethod` 取不到，硬套 IMP 会直接崩），这条路径在新系统上已失效。
///
/// 所以这里分三条路径，按可用性自动降级：
/// 1. **DelegatingSession（推荐）**：`TDMonitor.shared.makeInstrumentedSession(...)`
///    创建 session 时套代理，拿到完整分阶段耗时。任何系统版本都可用。
/// 2. **legacy swizzle**：老系统（初始化器仍是 ObjC 方法）自动接管业务已有 session，
///    同样有分阶段耗时。
/// 3. **完成回调拦截**：替换 `dataTaskWithURL/Request:completionHandler:` 等 ObjC 方法，
///    新系统上也能拿到成功率、状态码、错误分类、重试、流量与总耗时——**没有分阶段**。
///
/// 三条路径共用同一个 `TDNetworkSample`，上层不用关心数据来自哪条。
final class TDNetworkInstrumentation {

    static let shared = TDNetworkInstrumentation()

    private let lock = NSLock()
    private var handler: ((TDNetworkSample) -> Void)?
    private var installed = false
    private var ingestHost: String?
    private var ingestPathFragment: String?

    private init() {}

    func install(ingestURL: URL, handler: @escaping (TDNetworkSample) -> Void) {
        lock.lock()
        if installed { lock.unlock(); return }
        installed = true
        self.handler = handler
        self.ingestHost = ingestURL.host
        self.ingestPathFragment = ingestURL.path
        lock.unlock()

        let legacy = installLegacySessionHook()
        let callbacks = installCompletionHandlerHooks()
        TDMonitorLog.record(
            "网络埋点已启用 legacySession=\(legacy ? "on" : "off") completionHook=\(callbacks ? "on" : "off")"
            + (legacy ? "" : "（分阶段耗时需用 TDMonitor.shared.makeInstrumentedSession 创建 session）"),
            level: legacy ? "info" : "warning")
    }

    /// 供未走到 `install` 的极早期调用方使用（例如启动前建的 session）。
    ///
    /// 同一次请求可能走两条路径（delegate metrics + 完成回调），必须只上报一条：
    /// 否则 api 成功率、p95 全部会被放大两倍。先在 task 上打标记，后到的那条丢弃。
    fileprivate func emit(_ sample: TDNetworkSample, task: URLSessionTask? = nil) {
        if let task = task {
            objc_sync_enter(task)
            let alreadyReported = objc_getAssociatedObject(task, &tdReportedKey) != nil
            if !alreadyReported {
                objc_setAssociatedObject(task, &tdReportedKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
            objc_sync_exit(task)
            if alreadyReported { return }
        }
        lock.lock()
        let handler = self.handler
        let host = self.ingestHost
        let path = self.ingestPathFragment
        lock.unlock()
        guard let handler = handler else { return }
        if let host = host, let path = path,
           sample.url.contains(host), sample.url.contains(path) {
            return   // 监控自身的上报请求不计入业务网络质量
        }
        handler(sample)
    }

    // MARK: - 路径 2：老系统接管已有 session

    private func installLegacySessionHook() -> Bool {
        let selector = NSSelectorFromString("initWithConfiguration:delegate:delegateQueue:")
        guard let method = class_getInstanceMethod(URLSession.self, selector) else { return false }
        typealias InitFunction = @convention(c) (AnyObject, Selector, URLSessionConfiguration,
                                                 AnyObject?, OperationQueue?) -> AnyObject
        let original = unsafeBitCast(method_getImplementation(method), to: InitFunction.self)
        let block: @convention(block) (AnyObject, URLSessionConfiguration, AnyObject?, OperationQueue?) -> AnyObject = {
            object, configuration, delegate, queue in
            let proxy = TDURLSessionDelegateProxy(wrapping: delegate as? URLSessionDelegate)
            let session = original(object, selector, configuration, proxy, queue)
            objc_setAssociatedObject(session, &tdProxyAssociationKey,
                                     proxy, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return session
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
        return true
    }

    // MARK: - 路径 3：完成回调拦截（所有系统版本可用）

    fileprivate struct CallContext {
        let createdAt = Date()
        var resumedAt: Date?
        weak var task: URLSessionTask?
        var startDate: Date { resumedAt ?? createdAt }
    }

    private func installCompletionHandlerHooks() -> Bool {
        let variants = [
            "dataTaskWithRequest:completionHandler:",
            "dataTaskWithURL:completionHandler:",
            "uploadTaskWithRequest:fromData:completionHandler:",
            "downloadTaskWithRequest:completionHandler:",
        ]
        var hooked = 0
        for name in variants where hookTaskCreation(name) { hooked += 1 }
        guard hooked > 0 else { return false }
        hookResume()
        return true
    }

    /// 原始方法签名统一按「一个 request/url 参数 + 一个 completion block」处理，
    /// 参数类型不需要精确：我们把第一个对象原样透传，只替换最后的 block。
    private func hookTaskCreation(_ name: String) -> Bool {
        let selector = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(URLSession.self, selector) else { return false }
        typealias CreateFunction = @convention(c) (AnyObject, Selector, AnyObject?,
                                                   AnyObject?) -> AnyObject?
        let original = unsafeBitCast(method_getImplementation(method), to: CreateFunction.self)

        let block: @convention(block) (AnyObject, AnyObject?, AnyObject?) -> AnyObject? = {
            sessionObject, argument, completion in
            guard let completion = completion else {
                return original(sessionObject, selector, argument, nil)
            }
            var context = CallContext()
            let wrapped: @convention(block) (AnyObject?, AnyObject?, AnyObject?) -> Void = {
                data, response, error in
                (unsafeBitCast(completion, to: (@convention(block) (AnyObject?, AnyObject?, AnyObject?) -> Void).self))(data, response, error)
                TDNetworkInstrumentation.shared.finish(context: context, argument: argument,
                                                       data: data, response: response, error: error)
            }
            let task = original(sessionObject, selector, argument,
                                unsafeBitCast(wrapped, to: AnyObject.self))
            context.task = task as? URLSessionTask
            if let task = context.task {
                objc_setAssociatedObject(task, &tdCallContextKey,
                                         TDContextBox(context), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
            return task
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
        return true
    }

    /// 计时起点取 `resume`，否则「创建了但排队很久」的请求会把排队时间算进去。
    private func hookResume() {
        let selector = NSSelectorFromString("resume")
        guard let method = class_getInstanceMethod(URLSessionTask.self, selector) else { return }
        typealias ResumeFunction = @convention(c) (AnyObject, Selector) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: ResumeFunction.self)
        let block: @convention(block) (AnyObject) -> Void = { taskObject in
            if let box = objc_getAssociatedObject(taskObject, &tdCallContextKey) as? TDContextBox {
                box.value.resumedAt = Date()
            }
            original(taskObject, selector)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    private func finish(context: CallContext, argument: AnyObject?, data: AnyObject?,
                        response: AnyObject?, error: AnyObject?) {
        let request: URLRequest?
        if let urlRequest = argument as? URLRequest {
            request = urlRequest
        } else if let url = argument as? URL {
            request = URLRequest(url: url)
        } else {
            request = context.task?.originalRequest
        }
        guard let url = request?.url?.absoluteString else { return }
        let httpResponse = response as? HTTPURLResponse
        let nsError = error as? NSError
        let payload = data as? Data
        let bodyBytes = request?.httpBody?.count
        let sample = TDNetworkSample(
            url: url,
            method: request?.httpMethod ?? "GET",
            status: httpResponse?.statusCode ?? 0,
            durationMs: Date().timeIntervalSince(context.startDate) * 1000,
            dnsMs: nil, tcpMs: nil, tlsMs: nil, ttfbMs: nil,   // 需要 delegate，见 TDInstrumentedSession
            requestBytes: Int64(bodyBytes ?? 0),
            responseBytes: payload.map { Int64($0.count) },
            errorDomain: nsError?.domain,
            errorCode: nsError?.code,
            protocolName: nil,
            reusedConnection: false,
            transactionCount: 0,
            cached: false
        )
        emit(sample, task: context.task)
    }
}

/// 把 `CallContext` 装箱，供关联对象持有。
private final class TDContextBox: NSObject {
    var value: TDNetworkInstrumentation.CallContext
    init(_ value: TDNetworkInstrumentation.CallContext) { self.value = value }
}
/// 转发型代理：只接管 metrics 回调，其余全部转交给业务原始 delegate。
final class TDURLSessionDelegateProxy: NSObject, URLSessionDelegate, URLSessionTaskDelegate {

    private weak var wrapped: URLSessionDelegate?

    init(wrapping wrapped: URLSessionDelegate?) {
        self.wrapped = wrapped
        super.init()
    }

    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return wrapped?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if wrapped?.responds(to: aSelector) == true { return wrapped }
        return super.forwardingTarget(for: aSelector)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didFinishCollecting metrics: URLSessionTaskMetrics) {
        let selector = NSSelectorFromString("URLSession:task:didFinishCollectingMetrics:")
        if let delegate = wrapped as? URLSessionTaskDelegate, delegate.responds(to: selector) {
            delegate.urlSession?(session, task: task, didFinishCollecting: metrics)
        }
        guard let sample = Self.makeSample(task: task, metrics: metrics) else { return }
        TDNetworkInstrumentation.shared.emit(sample, task: task)
    }

    static func makeSample(task: URLSessionTask, metrics: URLSessionTaskMetrics) -> TDNetworkSample? {
        guard let request = task.originalRequest ?? task.currentRequest,
              let url = request.url?.absoluteString else { return nil }

        let transactions = metrics.transactionMetrics
        var dnsMs: Double = 0
        var tcpMs: Double = 0
        var tlsMs: Double = 0
        var ttfbMs: Double = 0
        var sawDNS = false, sawTCP = false, sawTLS = false, sawTTFB = false

        for transaction in transactions {
            if let start = transaction.domainLookupStartDate, let end = transaction.domainLookupEndDate {
                dnsMs += end.timeIntervalSince(start) * 1000; sawDNS = true
            }
            if let start = transaction.connectStartDate, let end = transaction.connectEndDate {
                tcpMs += end.timeIntervalSince(start) * 1000; sawTCP = true
            }
            if let start = transaction.secureConnectionStartDate, let end = transaction.secureConnectionEndDate {
                tlsMs += end.timeIntervalSince(start) * 1000; sawTLS = true
            }
            if let start = transaction.requestStartDate, let end = transaction.responseStartDate {
                ttfbMs = end.timeIntervalSince(start) * 1000; sawTTFB = true   // 只取最后一段
            }
        }

        let last = transactions.last
        let nsError = task.error as NSError?
        return TDNetworkSample(
            url: url,
            method: request.httpMethod ?? "GET",
            status: (task.response as? HTTPURLResponse)?.statusCode ?? 0,
            durationMs: metrics.taskInterval.duration * 1000,
            dnsMs: sawDNS ? dnsMs : nil,
            tcpMs: sawTCP ? tcpMs : nil,
            tlsMs: sawTLS ? tlsMs : nil,
            ttfbMs: sawTTFB ? ttfbMs : nil,
            requestBytes: Int64(request.httpBody?.count ?? 0),
            responseBytes: last?.countOfResponseBodyBytesReceived,
            errorDomain: nsError?.domain,
            errorCode: nsError?.code,
            protocolName: last?.networkProtocolName,
            reusedConnection: last?.isReusedConnection ?? false,
            transactionCount: transactions.count,
            cached: last?.resourceFetchType == .localCache
        )
    }
}

/// 错误分类、重试识别、弱网判定。
final class TDNetworkClassifier {

    private let lock = NSLock()
    private var lastFailure: [String: Date] = [:]
    private var retryCount: [String: Int] = [:]

    struct Result {
        let category: String
        let retryAttempt: Int
        let weakNetwork: Bool
    }

    func classify(_ sample: TDNetworkSample, networkType: String) -> Result {
        let key = "\(sample.method) \(TDNetworkClassifier.normalizedPath(sample.url))"
        let success = sample.status > 0 && sample.status < 400 && sample.errorCode == nil

        lock.lock()
        var attempt = 0
        if let previous = lastFailure[key] {
            if Date().timeIntervalSince(previous) < 60 {
                attempt = (retryCount[key] ?? 0) + 1
                retryCount[key] = attempt
            } else {
                retryCount[key] = 0
            }
        }
        if success {
            lastFailure.removeValue(forKey: key)
            retryCount[key] = 0
        } else {
            lastFailure[key] = Date()
        }
        if retryCount.count > 200 { retryCount.removeAll(); lastFailure.removeAll() }
        lock.unlock()

        let category: String
        if sample.cached {
            category = "cache"
        } else if let code = sample.errorCode, sample.errorDomain == NSURLErrorDomain {
            switch code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
                category = "offline"
            case NSURLErrorTimedOut:
                category = "timeout"
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
                category = "dns"
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot:
                category = "tls"
            case NSURLErrorCancelled:
                category = "cancelled"
            default:
                category = "transport"
            }
        } else if sample.status >= 500 {
            category = "http_5xx"
        } else if sample.status >= 400 {
            category = "http_4xx"
        } else if sample.status == 0 {
            category = "transport"
        } else {
            category = "ok"
        }

        // 弱网：蜂窝网络下首字节超过 800ms 或整体超过 2s，或链路错误。
        let weak = networkType == "cellular"
            && ((sample.ttfbMs ?? 0) > 800 || sample.durationMs > 2000
                || ["timeout", "offline", "dns", "tls", "transport"].contains(category))

        return Result(category: category, retryAttempt: attempt, weakNetwork: weak)
    }

    static func normalizedPath(_ raw: String) -> String {
        guard let components = URLComponents(string: raw) else { return raw }
        let parts = components.path.split(separator: "/").map { part -> String in
            if Int(part) != nil || part.count == 36 { return ":id" }
            return String(part)
        }
        return "\(components.host ?? "")/\(parts.joined(separator: "/"))"
    }
}
