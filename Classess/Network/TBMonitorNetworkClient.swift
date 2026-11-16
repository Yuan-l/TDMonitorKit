import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// 参考实现：基于 `URLSession` 的统一出口，零第三方依赖。
///
/// 它有两个使用者：
/// 1. **没有统一网络层的项目**——直接用它当出口；
/// 2. **已有网络层的项目**——不换出口，只把这里的采集器（observer）挂过去。
///
/// ## 监控自身上报**刻意不走这里**
///
/// `TDHTTPBatchUploader` 自己持有一个独立的 `URLSession` 直发，不与业务网络层共用：
/// - 上报是 SDK 的最后出口。让它依赖一个带拦截器链、observer、metrics 兜底窗口的
///   组件去送数据，等于「网络层出问题时，连『网络层出问题了』这件事都报不上去」。
/// - 「上报也能被观测」这个收益本来就不存在：`isInternal` 在采集侧已经把它挡掉了
///   （`TBMonitorNetwork.swift` 的 emit 入口）。既然必须挡住自激，就必然看不到它。
/// - 上报只要「发出去 + 返回四种结果」，业务网络层要的是「可扩展的拦截链」。
///   目标不同，共用一套只会互相拖累。
///
/// ## 为什么 metrics 和 completion 不能各发各的
///
/// 分段耗时只由 `URLSessionTaskDelegate.urlSession(_:task:didFinishCollecting:)`
/// 交付，而它与 `dataTask` 的 completion handler **到达顺序不确定**。
/// AFNetworking 源码里有一句直接的原话（`AFURLSessionManager.m:1101`）：
/// *"Metrics may fire after URLSession:task:didCompleteWithError: is called"*。
///
/// 如果两个回调各自上报，结果就是同一请求被记两次（成功率分母翻倍），
/// 或者只记一次但没有分段（分阶段报表永远为空）。所以这里做两件事：
/// - **业务回调立即执行**，不为了等 metrics 拖慢业务；
/// - **观测上报等两者齐了再发**，用一个兜底窗口（默认 1s）防止永远等下去。
///
/// 兜底窗口超时后按「宁可少数据，不要错数据」处理：发一条 `metricsMissing = true`
/// 的结果，之后迟到的 metrics **直接丢弃并留痕**——补发会造成双计数，
/// 而双计数在分位统计里表现为「p95 突然变好」，比缺数据更难发现。
final class TDURLSessionNetworkClient: NSObject, TDNetworkClient {

    /// metrics 兜底窗口。取值依据：
    /// metrics 是 task 结束后由 session 回调的，正常在毫秒级内到达；
    /// 取 1s 是为了覆盖 delegateQueue 被业务长任务堵住的极端情况。
    /// 再长没有意义——超过 1s 仍未到的，基本是后台 session 或系统异常。
    static let metricsGraceInterval: TimeInterval = 1.0

    private let session: URLSession
    private let forwarder: TDMetricsForwarder

    private let lock = NSLock()
    /// adapter / 重试链推进用的串行队列。
    ///
    /// **不能复用 session 的 delegateQueue**：如果某个 adapter 在 delegateQueue 上
    /// 同步等待另一个网络请求的结果，而那个请求的完成回调也需要 delegateQueue，
    /// 就会互相等待直到 watchdog 打进来。用独立队列彻底断开这个环。
    private let workQueue = DispatchQueue(label: "com.truedepth.monitor.network.client",
                                          qos: .utility)

    private var adapters: [TDRequestAdapter] = []
    private var retriers: [TDRequestRetrier] = []
    private var observers: [TDNetworkObserver] = []
    /// taskIdentifier → 状态，供 metrics 回调反查。
    private var statesByTask: [Int: RequestState] = [:]
    /// 尚未结束的请求的强引用。
    ///
    /// 必须有：`handle.state` 与 `state.handle` 都是 weak，
    /// 如果只靠这两个引用，请求在 adapter 阶段（task 还没建、
    /// 也还没进 `statesByTask`）就会被释放，回调直接丢失。
    private var inflight: [ObjectIdentifier: RequestState] = [:]

    init(configuration: URLSessionConfiguration = .default) {
        // delegate 只能在初始化器里指定，所以先造转发对象再把 session 造出来。
        let forwarder = TDMetricsForwarder()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "com.truedepth.monitor.network.delegate"
        // delegateQueue 串行化后，metrics 与 completion 不会并发进入本类，
        // 状态机只需处理「两种先后顺序」，不必再额外兜并发。
        self.session = URLSession(configuration: configuration,
                                  delegate: forwarder,
                                  delegateQueue: queue)
        self.forwarder = forwarder
        super.init()
        // super.init 之后 self 才可用，这时才把回调接回自己。
        forwarder.onMetrics = { [weak self] identifier, metrics in
            self?.receive(metrics: metrics, for: identifier)
        }
    }

    deinit {
        session.invalidateAndCancel()
    }

    // MARK: 装配

    func add(adapter: TDRequestAdapter) {
        lock.lock(); adapters.append(adapter); lock.unlock()
    }

    func add(retrier: TDRequestRetrier) {
        lock.lock(); retriers.append(retrier); lock.unlock()
    }

    func add(observer: TDNetworkObserver) {
        lock.lock(); observers.append(observer); lock.unlock()
    }

    // MARK: 发送

    @discardableResult
    func send(
        _ request: TDNetworkRequest,
        completion: ((TDNetworkResult) -> Void)?
    ) -> TDNetworkCancellable {
        let context = TDNetworkContext(traceId: request.tag.traceId ?? UUID().uuidString.lowercased())
        let state = RequestState(request: request, context: context, completion: completion)
        let handle = TDNetworkTaskHandle()
        handle.owner = self
        handle.state = state
        state.handle = handle

        lock.lock()
        inflight[ObjectIdentifier(state)] = state
        lock.unlock()

        workQueue.async { [weak self] in
            self?.runAdapters(state, index: 0, request: request)
        }
        return handle
    }

    /// adapter 链推进。任一环抛错即短路。
    private func runAdapters(_ state: RequestState, index: Int, request: TDNetworkRequest) {
        if state.isCancelled { finish(state, shortCircuit: .cancelled); return }

        lock.lock()
        let chain = adapters
        lock.unlock()

        guard index < chain.count else {
            dispatch(state, request: request)
            return
        }
        let adapter = chain[index]
        // 被标记跳过的 adapter 直接略过，用于打断刷新 token 的重入。
        if state.context.isBypassed(adapter) {
            runAdapters(state, index: index + 1, request: request)
            return
        }

        var mutated = request
        if mutated.tag.traceId == nil {
            mutated.tag.traceId = state.context.traceId
        }

        adapter.adapt(mutated, context: state.context) { [weak self] result in
            guard let self = self else { return }
            self.workQueue.async {
                switch result {
                case .success(let next):
                    self.runAdapters(state, index: index + 1, request: next)
                case .failure(let error):
                    self.shortCircuit(state, reason: .preconditionFailed, error: error)
                }
            }
        }
    }

    private func dispatch(_ state: RequestState, request: TDNetworkRequest) {
        if state.isCancelled { finish(state, shortCircuit: .cancelled); return }
        state.request = request
        notifyWillStart(request: request, context: state.context)

        let task = session.dataTask(with: request.asURLRequest()) { [weak self] data, response, error in
            guard let self = self else { return }
            self.recordCompletion(state, data: data, response: response, error: error)
        }
        state.task = task
        state.handle?.bind(task: task)

        lock.lock()
        statesByTask[task.taskIdentifier] = state
        lock.unlock()

        task.resume()
        notifyDidSend(request: request, context: state.context)
    }

    // MARK: 两个回调的汇合

    /// 业务完成回调。先执行业务回调，再做观测合流，不因为观测拖慢业务。
    private func recordCompletion(_ state: RequestState,
                                  data: Data?, response: URLResponse?, error: Error?) {
        lock.lock()
        state.data = data
        state.response = response as? HTTPURLResponse
        state.error = error
        state.taskFinished = true
        lock.unlock()
        scheduleDeadline(for: state)
        tryEmit(state)
    }

    func receive(metrics: URLSessionTaskMetrics, for taskIdentifier: Int) {
        lock.lock()
        let state = statesByTask[taskIdentifier]
        let alreadyEmitted = state?.emitted ?? false
        if let state = state, !alreadyEmitted {
            state.metrics = metrics
        }
        lock.unlock()

        guard let state = state else { return }
        if alreadyEmitted {
            // 已按兜底口径发过。迟到补发会造成双计数，比缺分段更糟。
            TDMonitorLog.record(
                "metrics 晚于兜底窗口到达，已丢弃（避免同一请求被计数两次）",
                level: "debug")
            return
        }
        tryEmit(state)
    }

    /// 兜底窗口：metrics 迟迟不来时按「无分段」口径先发出去。
    private func scheduleDeadline(for state: RequestState) {
        lock.lock()
        guard state.deadline == nil, state.metrics == nil else { lock.unlock(); return }
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            guard !state.emitted else { self.lock.unlock(); return }
            state.deadlineFired = true
            self.lock.unlock()
            self.tryEmit(state)
        }
        state.deadline = item
        lock.unlock()

        let delay = TDURLSessionNetworkClient.metricsGraceInterval
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// 是否允许进入 retrier 链。
    ///
    /// 抽成静态纯函数，是因为这条规则错了的后果只能靠线上爆量发现：
    /// 上报请求走重试会与 `TDRetryPolicy` 的指数退避叠加成双重退避，
    /// 表现为「设备离线时上报队列越积越多，恢复后一次性涌出」。
    /// 纯函数能单独验证，内联在状态机里就只能靠人工审查。
    static func shouldConsultRetrier(for request: TDNetworkRequest) -> Bool {
        !request.tag.isInternal
    }

    private func tryEmit(_ state: RequestState) {
        lock.lock()
        guard !state.emitted, state.taskFinished else { lock.unlock(); return }
        // 还在等 metrics、窗口也没过：先不发。
        if state.metrics == nil && !state.deadlineFired {
            lock.unlock()
            return
        }
        state.emitted = true
        if let identifier = state.task?.taskIdentifier {
            statesByTask.removeValue(forKey: identifier)
        }
        inflight.removeValue(forKey: ObjectIdentifier(state))
        let item = state.deadline
        state.deadline = nil
        let retryRequest = state.retryRequest
        state.retryRequest = nil
        lock.unlock()

        item?.cancel()

        let result = TDNetworkResult(
            request: state.request,
            context: state.context,
            response: state.response,
            data: state.data,
            error: state.error,
            metrics: state.metrics,
            metricsMissing: state.metrics == nil,
            shortCircuit: nil)

        // 重试链只对真实发出的请求生效；内部请求（上报）一律不重试。
        //
        // completion 契约是「一条请求只回调一次」：中间 attempt 的失败不回调业务，
        // 否则「失败 → 重试 → 成功」会让业务先按失败处理（弹错误提示、写入失败态），
        // 随后又被成功回调覆盖，产生重复处理。真机冒烟验证时实测到过这个问题。
        if TDURLSessionNetworkClient.shouldConsultRetrier(for: state.request),
           let decision = retryDecision(for: result, state: state) {
            let next = state.context.nextAttempt()
            let nextRequest = retryRequest ?? decision.request ?? state.request
            let delay = decision.delay
            let retryBlock: () -> Void = { [weak self] in
                guard let self = self else { return }
                self.workQueue.async {
                    self.prepareRetry(state, context: next, request: nextRequest)
                }
            }
            if delay > 0 {
                workQueue.asyncAfter(deadline: .now() + delay, execute: retryBlock)
            } else {
                retryBlock()
            }
            return
        }

        state.completion?(result)
        notifyComplete(result)
    }

    private func prepareRetry(_ state: RequestState,
                              context: TDNetworkContext, request: TDNetworkRequest) {
        if state.isCancelled { finish(state, shortCircuit: .cancelled); return }
        state.context = context
        state.request = request
        lock.lock()
        state.response = nil
        state.data = nil
        state.error = nil
        state.metrics = nil
        state.taskFinished = false
        state.emitted = false
        state.deadlineFired = false
        state.deadline = nil
        inflight[ObjectIdentifier(state)] = state
        lock.unlock()
        runAdapters(state, index: 0, request: request)
    }

    private struct RetryPlan {
        let delay: TimeInterval
        let request: TDNetworkRequest?
    }

    /// 询问 retrier 链。第一个非 `doNotRetry` 的生效并终止询问。
    private func retryDecision(for result: TDNetworkResult, state: RequestState) -> RetryPlan? {
        lock.lock()
        let chain = retriers
        lock.unlock()
        guard !chain.isEmpty else { return nil }
        for retrier in chain {
            switch retrier.shouldRetry(result, context: state.context) {
            case .doNotRetry:
                continue
            case .retry(let delay, let request):
                return RetryPlan(delay: delay ?? 0, request: request)
            }
        }
        return nil
    }

    // MARK: 短路 / 取消

    private func shortCircuit(_ state: RequestState,
                              reason: TDShortCircuitReason, error: Error?) {
        lock.lock()
        guard !state.emitted else { lock.unlock(); return }
        state.emitted = true
        state.taskFinished = true
        state.error = error
        inflight.removeValue(forKey: ObjectIdentifier(state))
        lock.unlock()

        let result = TDNetworkResult(
            request: state.request,
            context: state.context,
            response: nil,
            data: nil,
            error: error,
            metrics: nil,
            metricsMissing: true,
            shortCircuit: reason)
        state.completion?(result)
        notifyComplete(result)
    }

    private func finish(_ state: RequestState, shortCircuit reason: TDShortCircuitReason) {
        shortCircuit(state, reason: reason, error: nil)
    }

    func cancel(state: RequestState) {
        lock.lock()
        state.isCancelled = true
        let task = state.task
        let emitted = state.emitted
        lock.unlock()

        if let task = task, !emitted {
            // 交给系统的取消路径：completion 会带 NSURLErrorCancelled 回来，
            // 走正常合流，不在这里造一条假结果。
            task.cancel()
        } else if task == nil, !emitted {
            finish(state, shortCircuit: .cancelled)
        }
    }

    // MARK: 广播

    private func notifyWillStart(request: TDNetworkRequest, context: TDNetworkContext) {
        lock.lock(); let chain = observers; lock.unlock()
        for observer in chain { observer.client(self, willStart: request, context: context) }
    }

    private func notifyDidSend(request: TDNetworkRequest, context: TDNetworkContext) {
        lock.lock(); let chain = observers; lock.unlock()
        for observer in chain { observer.client(self, didSend: request, context: context) }
    }

    private func notifyComplete(_ result: TDNetworkResult) {
        lock.lock(); let chain = observers; lock.unlock()
        for observer in chain { observer.client(self, didComplete: result) }
    }

    // MARK: 状态

    /// 单次请求的状态机。
    ///
    /// 用引用类型是因为它要跨「adapter 队列 / delegateQueue / 兜底定时器」
    /// 三处被改写，值类型会让每次改写都变成一份新副本，合流判断直接失效。
    final class RequestState {
        var request: TDNetworkRequest
        var context: TDNetworkContext
        let completion: ((TDNetworkResult) -> Void)?
        weak var handle: TDNetworkTaskHandle?
        var task: URLSessionTask?
        var retryRequest: TDNetworkRequest?

        var response: HTTPURLResponse?
        var data: Data?
        var error: Error?

        var metrics: URLSessionTaskMetrics?
        var taskFinished = false
        var emitted = false
        var deadlineFired = false
        var isCancelled = false
        var deadline: DispatchWorkItem?

        init(request: TDNetworkRequest,
             context: TDNetworkContext,
             completion: ((TDNetworkResult) -> Void)?) {
            self.request = request
            self.context = context
            self.completion = completion
        }
    }
}

// MARK: - 取消句柄

final class TDNetworkTaskHandle: TDNetworkCancellable {

    weak var owner: TDURLSessionNetworkClient?
    weak var state: TDURLSessionNetworkClient.RequestState?
    private weak var task: URLSessionTask?

    func bind(task: URLSessionTask) { self.task = task }

    func cancel() {
        task?.cancel()
        if let state = state { owner?.cancel(state: state) }
    }
}

// MARK: - metrics 转发

/// 只做一件事：把 `didFinishCollectingMetrics` 交回 client。
///
/// 存在的唯一原因是 `URLSession` 的 delegate 只能在初始化器里指定，
/// 而初始化器执行时 `self` 还不能用。用一个不持有业务状态的对象补这个缝。
final class TDMetricsForwarder: NSObject, URLSessionDelegate, URLSessionTaskDelegate {

    var onMetrics: ((Int, URLSessionTaskMetrics) -> Void)?

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didFinishCollecting metrics: URLSessionTaskMetrics) {
        onMetrics?(task.taskIdentifier, metrics)
    }
}
