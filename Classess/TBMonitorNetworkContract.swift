import Foundation

// MARK: - 拦截器契约
//
// 设计依据：Alamofire 5 把「能改流程的」和「只能观测的」拆成三族
// （`RequestAdapter` / `RequestRetrier` / `EventMonitor`），是目前唯一被
// 大规模验证过的划分方式。Moya 的 `PluginType` 把三者塞进一个协议，
// 结果是「一个 plugin 想只做日志，却必须实现能改请求的 `willSend`」——
// 职责靠文档约束，而不是靠类型约束。
//
// 这里沿用三族，并额外加一条硬规则：
// **`TDNetworkObserver` 的所有方法返回 Void。**
// 监控采集器全部实现为 observer，因此它们**在类型层面就不可能**改变
// 业务请求的成败、顺序或内容。这比「代码规范要求采集器不要改请求」可靠得多——
// 规范会被下一个人忘记，类型签名不会。

// MARK: - 请求

/// 一次网络请求的规范化描述。
///
/// 不直接拿 `URLRequest` 当传输对象，有两个具体原因：
/// 1. `URLRequest.allHTTPHeaderFields` 在重定向、缓存策略切换时会被
///    Foundation 隐式改写，拦截器之间传递时字段容易丢失；
/// 2. 业务语义（接口名、幂等性、是否上报自身流量）在 `URLRequest` 里无处安放，
///    塞进 header 会污染真实报文，也可能被服务端或网关拒掉。
public struct TDNetworkRequest {

    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    public var timeout: TimeInterval?
    /// 业务语义标签。adapter 可读可改，观测侧据此分流。
    public var tag: TDRequestTag

    public init(
        url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval? = nil,
        tag: TDRequestTag = TDRequestTag()
    ) {
        self.url = url
        self.method = method.uppercased()
        self.headers = headers
        self.body = body
        self.timeout = timeout
        self.tag = tag
    }

    /// 转成系统类型。只在真正派发那一刻调用一次，
    /// 之后链路里流转的都是 `TDNetworkRequest`。
    ///
    /// public 是契约的一部分：业务自己实现 `TDNetworkClient`（比如基于
    /// AFNetworking）时必须能把 `TDNetworkRequest` 变成 `URLRequest`，
    /// 否则「可以自己实现 client」只是一句空话。
    public func asURLRequest() -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        if let timeout = timeout {
            request.timeoutInterval = timeout
        }
        return request
    }
}

/// 业务语义标签。
public struct TDRequestTag {

    /// 归一化接口名，如 `api.example.com/v1/orders/:id`。
    ///
    /// 留空时由客户端从 URL 推导（只把数字段与 36 位 UUID 换成 `:id`），
    /// 但推导必然有偏差（业务 ID 可能是 slug、可能是嵌套路径）。
    /// 后端要按接口聚合成功率/分位耗时，这个字段的准确性直接决定报表能不能用，
    /// 所以业务愿意给的时候优先用业务值。
    public var endpoint: String?

    /// 幂等语义。**只有幂等请求才允许网络层自动重试。**
    ///
    /// 默认 false：`POST` 重复提交会造重复订单、重复扣款，
    /// 这类错误的代价远高于「少重试一次」。要重试必须在发起处显式声明。
    public var isIdempotent: Bool

    /// 上报自身的流量。
    ///
    /// 置 true 的请求不进业务网络指标、不走 retrier。
    /// 替代旧实现里 `url.contains(host) && url.contains(path)` 的字符串匹配——
    /// 那种写法在后端换域名、加 CDN、改路径前缀时会**静默失效**，
    /// 表现是「监控自身请求混进业务成功率」，属于很难被发现的数据污染。
    public var isInternal: Bool

    /// 与 breadcrumb / 崩溃 / 卡顿串起来用的链路 ID。
    public var traceId: String?

    public init(
        endpoint: String? = nil,
        isIdempotent: Bool = false,
        isInternal: Bool = false,
        traceId: String? = nil
    ) {
        self.endpoint = endpoint
        self.isIdempotent = isIdempotent
        self.isInternal = isInternal
        self.traceId = traceId
    }
}

// MARK: - 单次尝试的上下文

/// 一次请求在其生命周期内共享的上下文。
///
/// 是 class 而不是 struct：adapter 之间需要**传值**（比如刷新 token 的 adapter
/// 把新 token 放进 `userInfo`，重试 adapter 读出来用）。
/// 值语义会让每个 adapter 拿到副本，传值这件事直接不成立。
///
/// 线程约定：只在客户端内部串行推进时读写，不跨线程共享，因此不加锁。
public final class TDNetworkContext {

    public let traceId: String
    public let startedAt: Date
    /// 0 表示首次尝试，之后每次重试 +1。
    public private(set) var attempt: Int
    public private(set) var bypassedAdapters: Set<ObjectIdentifier>
    /// adapter 之间的自由传值区。约定 key 用 `模块名.字段名` 避免撞车。
    public var userInfo: [String: Any]

    public init(
        traceId: String,
        startedAt: Date = Date(),
        attempt: Int = 0,
        bypassedAdapters: Set<ObjectIdentifier> = [],
        userInfo: [String: Any] = [:]
    ) {
        self.traceId = traceId
        self.startedAt = startedAt
        self.attempt = attempt
        self.bypassedAdapters = bypassedAdapters
        self.userInfo = userInfo
    }

    /// 派生下一次尝试的上下文。
    ///
    /// 复用同一个实例会在重试时覆写 `attempt`，导致「第 2 次尝试的样本
    /// 被记成第 1 次」——重试率统计直接失真，所以必须新建。
    public func nextAttempt() -> TDNetworkContext {
        let next = TDNetworkContext(
            traceId: traceId,
            startedAt: startedAt,
            attempt: attempt + 1,
            bypassedAdapters: bypassedAdapters,
            userInfo: userInfo)
        return next
    }

    /// 让某个 adapter 对本次请求（含后续重试）失效。
    ///
    /// 用于打断重入：刷新 token 的 adapter 自己会发请求，若那条请求再次进入
    /// 整条 adapter 链，就会无限递归。Alamofire 的 `Authenticator` 用
    /// `Request` 的 retry 计数拦住，我们这里用 adapter 身份标记，
    /// 更直接——它表达的是「这一类 adapter 我不要跑」。
    public func bypass(_ adapter: TDRequestAdapter) {
        bypassedAdapters.insert(ObjectIdentifier(adapter))
    }

    public func isBypassed(_ adapter: TDRequestAdapter) -> Bool {
        bypassedAdapters.contains(ObjectIdentifier(adapter))
    }
}

// MARK: - 结果

/// 请求被拦截器短路的原因。
///
/// 短路（缓存命中、token 拿不到、前置条件失败）**不产生网络流量，
/// 但必须产生一条观测记录**。否则监控看到的是「这个接口从没被调用过」，
/// 而实际是「调用了一直被本地短路」——这正是最难查的一类「指标缺失」。
public enum TDShortCircuitReason: String {
    case cacheHit = "cache_hit"
    case preconditionFailed = "precondition_failed"
    case unavailable = "unavailable"
    case cancelled = "cancelled"
}

/// 一次请求的最终结果（含重试耗尽后的终态）。
public struct TDNetworkResult {

    public let request: TDNetworkRequest
    public let context: TDNetworkContext
    public let response: HTTPURLResponse?
    public let data: Data?
    public let error: Error?
    /// 分段耗时来源。为 nil 有两种情况：
    /// 1. 请求被短路，根本没有 task；
    /// 2. metrics 晚于兜底窗口到达，已按「宁可少数据不要错数据」丢弃。
    public let metrics: URLSessionTaskMetrics?
    /// `true` 表示这条结果是在 metrics 到达前就算出来的。
    /// 观测侧据此知道「分段耗时为什么是空的」，而不是误判成「都不支持」。
    public let metricsMissing: Bool
    public let shortCircuit: TDShortCircuitReason?

    /// public 是契约的一部分：业务自己实现 `TDNetworkClient` 时要能造出结果。
    public init(
        request: TDNetworkRequest,
        context: TDNetworkContext,
        response: HTTPURLResponse?,
        data: Data?,
        error: Error?,
        metrics: URLSessionTaskMetrics?,
        metricsMissing: Bool,
        shortCircuit: TDShortCircuitReason?
    ) {
        self.request = request
        self.context = context
        self.response = response
        self.data = data
        self.error = error
        self.metrics = metrics
        self.metricsMissing = metricsMissing
        self.shortCircuit = shortCircuit
    }

    public var status: Int { response?.statusCode ?? 0 }

    /// 耗时口径：
    /// - 有 metrics → 用 `taskInterval.duration`（系统口径，与本条请求的
    ///   DNS/TCP/TLS/TTFB 同源，加起来能对上总耗时）
    /// - 无 metrics → 用墙钟差值兜底，但**会包含 adapter 耗时**
    ///
    /// 两个口径不能混着做分位统计。上报时用 `metricsMissing` 标记区分，
    /// 后端可以只对 `metricsMissing == false` 的样本算分阶段报表。
    public var durationMs: Double {
        if let interval = metrics?.taskInterval {
            return interval.duration * 1000
        }
        return Date().timeIntervalSince(context.startedAt) * 1000
    }

    public var isSuccess: Bool {
        error == nil && status > 0 && status < 400
    }
}

// MARK: - 三族拦截器

/// 请求适配器：**能改请求，不能决定成败**。
///
/// 典型用途：注入 trace header、签名、刷新 token、补公共参数。
///
/// 执行顺序 = 注册顺序，串行，前一个的输出是后一个的输入。
/// 任何一环 `throw` 即中止发送并产出一条 `preconditionFailed` 的短路结果。
public protocol TDRequestAdapter: AnyObject {
    func adapt(_ request: TDNetworkRequest, context: TDNetworkContext) throws -> TDNetworkRequest

    /// 异步版本。需要等 IO（读 token、算签名）的 adapter 实现它。
    ///
    /// **完成回调不在 session 的 delegateQueue 上执行**——
    /// 如果在 delegateQueue 上同步等待另一个网络请求，会直接死锁。
    /// 默认实现转发同步版本，绝大多数 adapter 不需要实现它。
    func adapt(
        _ request: TDNetworkRequest,
        context: TDNetworkContext,
        completion: @escaping (Result<TDNetworkRequest, Error>) -> Void
    )
}

public extension TDRequestAdapter {
    func adapt(
        _ request: TDNetworkRequest,
        context: TDNetworkContext,
        completion: @escaping (Result<TDNetworkRequest, Error>) -> Void
    ) {
        completion(Result { try adapt(request, context: context) })
    }
}

/// 重试决策。
public enum TDRetryDecision {
    case doNotRetry
    /// - Parameters:
    ///   - delay: nil 表示立即重试
    ///   - request: 非 nil 表示带一个新请求重试（换 URL / 换 token 后重发）
    case retry(after: TimeInterval?, request: TDNetworkRequest?)
}

/// 重试裁决器：**只决定重不重试，不直接改请求**。
///
/// 要改请求时通过 `request` 回传，而不是就地修改——这让「发生了什么重试」
/// 留在结果里可被观测，而不是变成一次无声的请求替换。
///
/// 多个 retrier 按注册顺序询问，**第一个给出非 `doNotRetry` 的生效并终止询问**。
/// 理由：重试决策互斥，「立即重试」和「退避 3 秒」不能同时成立，
/// 让所有 retrier 投票再取并集只会得到矛盾结论。
public protocol TDRequestRetrier: AnyObject {
    func shouldRetry(_ result: TDNetworkResult, context: TDNetworkContext) -> TDRetryDecision
}

/// 观测者：**只观测，不能影响流程**。
///
/// 所有方法返回 Void。监控 SDK 的全部采集器都实现在这一族，
/// 因此它们在类型层面无法改变业务请求——这是「监控不侵入业务」的
/// 架构保证，而不是一句承诺。
public protocol TDNetworkObserver: AnyObject {
    /// 请求已通过全部 adapter，即将派发。
    func client(_ client: TDNetworkClient, willStart request: TDNetworkRequest,
                context: TDNetworkContext)
    /// task 已 resume，真正飞出去了。与 `willStart` 的区别是
    /// 这里一定产生了真实网络流量，可以用来算「实际发出量」。
    func client(_ client: TDNetworkClient, didSend request: TDNetworkRequest,
                context: TDNetworkContext)
    /// 终态。**重试链只在最后一次尝试后回调一次**，不会每次尝试都回调，
    /// 否则一条请求被重试 3 次会污染成功率分母。
    ///
    /// 时序约定：在业务的 `completion` **之后**同步发出。
    /// 目的是不让观测拖慢业务——业务回调一到就归还控制权，
    /// 采集器做多重的活都不影响请求本身的时延。
    /// 代价是「业务回调里读不到刚产生的观测结果」，需要那一刻就有数据的场景
    /// 请直接在业务回调里读 `TDNetworkResult`，不要绕 observer。
    func client(_ client: TDNetworkClient, didComplete result: TDNetworkResult)
}

public extension TDNetworkObserver {
    func client(_ client: TDNetworkClient, willStart request: TDNetworkRequest,
                context: TDNetworkContext) {}
    func client(_ client: TDNetworkClient, didSend request: TDNetworkRequest,
                context: TDNetworkContext) {}
    func client(_ client: TDNetworkClient, didComplete result: TDNetworkResult) {}
}

// MARK: - 客户端

public protocol TDNetworkCancellable: AnyObject {
    func cancel()
}

/// 统一出口。业务网络层实现它即可获得全部采集能力；
/// Kit 自带一个 `TDURLSessionNetworkClient` 作为参考实现，
/// 同时给监控自身上报使用。
public protocol TDNetworkClient: AnyObject {
    @discardableResult
    func send(
        _ request: TDNetworkRequest,
        completion: ((TDNetworkResult) -> Void)?
    ) -> TDNetworkCancellable

    func add(adapter: TDRequestAdapter)
    func add(retrier: TDRequestRetrier)
    func add(observer: TDNetworkObserver)
}
