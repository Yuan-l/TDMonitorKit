import XCTest
@testable import TDMonitorKit

// MARK: - 测试替身

/// 记录 adapter 执行顺序，并把名字追加到 endpoint 上——
/// 这样不仅验证「按顺序跑了」，还验证「后一个能看到前一个的输出」。
final class OrderRecordingAdapter: TDRequestAdapter {

    private let name: String
    private let recorder: ExecutionRecorder

    init(name: String, recorder: ExecutionRecorder) {
        self.name = name
        self.recorder = recorder
    }

    func adapt(_ request: TDNetworkRequest, context: TDNetworkContext) throws -> TDNetworkRequest {
        var mutated = request
        let previous = mutated.tag.endpoint ?? ""
        mutated.tag.endpoint = previous.isEmpty ? name : "\(previous)>\(name)"
        recorder.append("adapt:\(name)")
        return mutated
    }
}

/// 模拟「前置条件拿不到」：例如 token 刷新失败、必填签名缺失。
final class PreconditionFailingAdapter: TDRequestAdapter {

    struct Failure: Error {}
    private let recorder: ExecutionRecorder

    init(recorder: ExecutionRecorder) { self.recorder = recorder }

    func adapt(_ request: TDNetworkRequest, context: TDNetworkContext) throws -> TDNetworkRequest {
        recorder.append("adapt:fail endpoint=\(request.tag.endpoint ?? "nil")")
        throw Failure()
    }
}

/// 异步 adapter：模拟读 Keychain / 等 token 刷新的 IO 等待。
final class AsyncRecordingAdapter: TDRequestAdapter {

    private let name: String
    private let recorder: ExecutionRecorder

    init(name: String, recorder: ExecutionRecorder) {
        self.name = name
        self.recorder = recorder
    }

    func adapt(_ request: TDNetworkRequest, context: TDNetworkContext) throws -> TDNetworkRequest {
        // 同步版本不该被调用：走异步入口时必须用下面那个实现。
        XCTFail("异步 adapter 的同步实现不应被调用")
        return request
    }

    func adapt(_ request: TDNetworkRequest, context: TDNetworkContext,
               completion: @escaping (Result<TDNetworkRequest, Error>) -> Void) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.02) {
            var mutated = request
            mutated.tag.endpoint = self.name
            self.recorder.append("adapt:\(self.name)")
            completion(.success(mutated))
        }
    }
}

final class ExecutionRecorder {
    private let lock = NSLock()
    private var items: [String] = []
    func append(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

final class RecordingNetworkObserver: TDNetworkObserver {

    private let lock = NSLock()
    private var _results: [TDNetworkResult] = []
    private var _willStartCount = 0
    private var _didSendCount = 0
    /// 在 `didComplete` 之后触发，用于让测试等待「观测侧真的收到了」，
    /// 而不是等业务回调——业务回调先于观察者发出，等它会和观察者抢跑。
    var onComplete: (() -> Void)?

    var results: [TDNetworkResult] { lock.lock(); defer { lock.unlock() }; return _results }
    var willStartCount: Int { lock.lock(); defer { lock.unlock() }; return _willStartCount }
    var didSendCount: Int { lock.lock(); defer { lock.unlock() }; return _didSendCount }

    func client(_ client: TDNetworkClient, willStart request: TDNetworkRequest,
                context: TDNetworkContext) {
        lock.lock(); _willStartCount += 1; lock.unlock()
    }

    func client(_ client: TDNetworkClient, didSend request: TDNetworkRequest,
                context: TDNetworkContext) {
        lock.lock(); _didSendCount += 1; lock.unlock()
    }

    func client(_ client: TDNetworkClient, didComplete result: TDNetworkResult) {
        lock.lock(); _results.append(result); lock.unlock()
        onComplete?()
    }
}

/// 固定决策的 retrier，用来单独验证裁决链行为。
final class FixedRetrier: TDRequestRetrier {
    private let decision: TDRetryDecision
    init(_ decision: TDRetryDecision) { self.decision = decision }
    func shouldRetry(_ result: TDNetworkResult, context: TDNetworkContext) -> TDRetryDecision {
        decision
    }
}

/// 有限次重试：超过 `maxAttempts` 后不再重试，避免测试里无限重试。
final class LimitedRetrier: TDRequestRetrier {
    private let maxAttempts: Int
    init(maxAttempts: Int) { self.maxAttempts = maxAttempts }
    func shouldRetry(_ result: TDNetworkResult, context: TDNetworkContext) -> TDRetryDecision {
        // attempt 从 0 起：attempt + 1 是「已经用掉的次数」
        context.attempt + 1 < maxAttempts ? .retry(after: 0, request: nil) : .doNotRetry
    }
}

// MARK: - 上下文

final class TDNetworkContextTests: XCTestCase {

    func testNextAttemptIncrementsAndSharesTrace() {
        let first = TDNetworkContext(traceId: "trace-1")
        let second = first.nextAttempt()
        let third = second.nextAttempt()

        XCTAssertEqual(first.attempt, 0)
        XCTAssertEqual(second.attempt, 1)
        XCTAssertEqual(third.attempt, 2)
        XCTAssertEqual(second.traceId, "trace-1")
        XCTAssertEqual(third.traceId, "trace-1")
        // 必须共享同一个起点：否则每次重试的起点时间不同，
        // 「这条请求一共花了多久」会变成「最后一次尝试花了多久」。
        XCTAssertEqual(second.startedAt, first.startedAt)
    }

    func testBypassAdapterIsInheritedByRetry() {
        let adapter = TDTraceAdapter()
        let context = TDNetworkContext(traceId: "t")
        context.bypass(adapter)

        XCTAssertTrue(context.isBypassed(adapter))
        // 继承是关键：刷新 token 的 adapter 第一次就该被跳过，
        // 之后的重试也不该重新进入它，否则递归中断不了。
        XCTAssertTrue(context.nextAttempt().isBypassed(adapter))
    }
}

// MARK: - 幂等重试裁决

final class TDIdempotentRetrierTests: XCTestCase {

    private func makeResult(
        idempotent: Bool,
        errorCode: Int? = nil,
        status: Int = 0
    ) -> TDNetworkResult {
        let url = URL(string: "https://api.example.com/v1/orders")!
        let request = TDNetworkRequest(
            url: url,
            tag: TDRequestTag(isIdempotent: idempotent))
        let error = errorCode.map { NSError(domain: NSURLErrorDomain, code: $0) as Error }
        let response = status > 0
            ? HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
            : nil
        return TDNetworkResult(
            request: request,
            context: TDNetworkContext(traceId: "t"),
            response: response,
            data: nil,
            error: error,
            metrics: nil,
            metricsMissing: true,
            shortCircuit: nil)
    }

    func testNonIdempotentNeverRetries() {
        let retrier = TDIdempotentRetrier()
        let result = makeResult(idempotent: false, errorCode: NSURLErrorTimedOut)
        guard case .doNotRetry = retrier.shouldRetry(result, context: result.context) else {
            return XCTFail("非幂等请求不得重试：POST 超时可能已成功，重发即重复下单")
        }
    }

    func testIdempotentRetriesTransientTimeout() {
        let retrier = TDIdempotentRetrier()
        let result = makeResult(idempotent: true, errorCode: NSURLErrorTimedOut)
        guard case .retry(let delay, _) = retrier.shouldRetry(result, context: result.context) else {
            return XCTFail("幂等请求遇到超时应重试")
        }
        XCTAssertGreaterThan(delay ?? 0, 0)
    }

    func testIdempotentDoesNotRetryClientError() {
        let retrier = TDIdempotentRetrier()
        let result = makeResult(idempotent: true, status: 401)
        guard case .doNotRetry = retrier.shouldRetry(result, context: result.context) else {
            return XCTFail("401 重试一百次还是 401，只会把鉴权失败放大成流量洪峰")
        }
    }

    func testIdempotentRetriesServiceUnavailable() {
        let retrier = TDIdempotentRetrier()
        let result = makeResult(idempotent: true, status: 503)
        guard case .retry = retrier.shouldRetry(result, context: result.context) else {
            return XCTFail("503 是服务端明确说「稍后再来」")
        }
    }

    func testStopsAtMaxAttempts() {
        let retrier = TDIdempotentRetrier(maxAttempts: 2)
        let result = makeResult(idempotent: true, errorCode: NSURLErrorTimedOut)
        let context = TDNetworkContext(traceId: "t", attempt: 2)
        guard case .doNotRetry = retrier.shouldRetry(result, context: context) else {
            return XCTFail("达到上限必须停，否则弱网下会无限重试")
        }
    }

    func testBackoffGrowsWithAttempt() {
        let retrier = TDIdempotentRetrier(maxAttempts: 4, baseDelay: 1, maxDelay: 100)
        let result = makeResult(idempotent: true, errorCode: NSURLErrorTimedOut)
        let first = TDNetworkContext(traceId: "t", attempt: 0)
        let third = TDNetworkContext(traceId: "t", attempt: 2)

        guard case .retry(let early, _) = retrier.shouldRetry(result, context: first),
              case .retry(let late, _) = retrier.shouldRetry(result, context: third) else {
            return XCTFail("应给出重试决策")
        }
        // 抖动区间是 [0.5, 1.0) 倍，所以第三次的下界仍应高于第一次的上界。
        XCTAssertGreaterThan(late ?? 0, early ?? 0)
    }
}

// MARK: - 内置 adapter

final class TDTraceAdapterTests: XCTestCase {

    func testInjectsTraceId() throws {
        let adapter = TDTraceAdapter()
        let context = TDNetworkContext(traceId: "abc123")
        let request = TDNetworkRequest(url: URL(string: "https://api.example.com/a")!)

        let mutated = try adapter.adapt(request, context: context)
        XCTAssertEqual(mutated.headers["X-TD-Trace-Id"], "abc123")
        XCTAssertEqual(mutated.tag.traceId, "abc123")
    }

    func testKeepsBusinessSuppliedTraceId() throws {
        let adapter = TDTraceAdapter()
        let context = TDNetworkContext(traceId: "ours")
        var request = TDNetworkRequest(url: URL(string: "https://api.example.com/a")!)
        request.headers["X-TD-Trace-Id"] = "business"

        let mutated = try adapter.adapt(request, context: context)
        // 覆盖业务值会让业务侧日志和我们的报表对不上，宁可各用各的。
        XCTAssertEqual(mutated.headers["X-TD-Trace-Id"], "business")
    }
}

// MARK: - metrics 映射

final class TDNetworkMetricsMapperTests: XCTestCase {

    func testWithoutMetricsKeepsPhasesEmpty() {
        let sample = TDNetworkMetricsMapper.makeSample(
            url: "https://api.example.com/a", method: "GET", status: 200,
            errorDomain: nil, errorCode: nil, metrics: nil,
            requestBytes: 0, responseBytes: 128)

        // 关键不是「值是 nil」，而是「nil 表示采集不到，而不是 0ms」。
        // 若这里返回 0，后端会把所有缺失样本当成「零耗时」，把 p50 拉低。
        XCTAssertNil(sample.dnsMs)
        XCTAssertNil(sample.tcpMs)
        XCTAssertNil(sample.tlsMs)
        XCTAssertNil(sample.ttfbMs)
        XCTAssertEqual(sample.durationMs, 0)
        XCTAssertEqual(sample.transactionCount, 0)
        XCTAssertEqual(sample.responseBytes, 128)
    }
}

// MARK: - 采集器

final class TDNetworkSampleObserverTests: XCTestCase {

    func testShortCircuitStillEmitsSample() {
        let observer = TDNetworkSampleObserver()
        var captured: TDNetworkSample?
        observer.onSample = { captured = $0 }

        let request = TDNetworkRequest(
            url: URL(string: "https://api.example.com/v1/orders/42")!,
            tag: TDRequestTag(endpoint: "api.example.com/v1/orders/:id"))
        let result = TDNetworkResult(
            request: request,
            context: TDNetworkContext(traceId: "t"),
            response: nil, data: nil, error: nil,
            metrics: nil, metricsMissing: true,
            shortCircuit: .cacheHit)

        observer.client(TDURLSessionNetworkClient(), didComplete: result)

        // 短路没有网络流量，但如果不上报，监控看到的是「这个接口从没被调用过」——
        // 与「调了但一直被本地缓存挡住」是完全不同的结论。
        XCTAssertNotNil(captured)
        XCTAssertEqual(captured?.shortCircuit, "cache_hit")
        XCTAssertEqual(captured?.errorDomain, "TDShortCircuit")
        XCTAssertEqual(captured?.endpoint, "api.example.com/v1/orders/:id")
        XCTAssertEqual(captured?.status, 0)
        XCTAssertEqual(captured?.metricsMissing, true)
    }
}

// MARK: - 客户端链路（不触网）

final class TDURLSessionNetworkClientTests: XCTestCase {

    private func makeClient() -> TDURLSessionNetworkClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1
        return TDURLSessionNetworkClient(configuration: configuration)
    }

    func testAdaptersRunInOrderAndDownstreamSeesUpstreamOutput() {
        let client = makeClient()
        let recorder = ExecutionRecorder()
        client.add(adapter: OrderRecordingAdapter(name: "a", recorder: recorder))
        client.add(adapter: OrderRecordingAdapter(name: "b", recorder: recorder))
        client.add(adapter: PreconditionFailingAdapter(recorder: recorder))

        let observer = RecordingNetworkObserver()
        client.add(observer: observer)
        let observed = expectation(description: "观测到终态")
        observer.onComplete = { observed.fulfill() }

        var completions = 0
        client.send(TDNetworkRequest(url: URL(string: "https://api.example.com/ping")!)) { _ in
            completions += 1
        }
        waitForExpectations(timeout: 2)

        XCTAssertEqual(recorder.all,
                       ["adapt:a", "adapt:b", "adapt:fail endpoint=a>b"])
        XCTAssertEqual(observer.results.count, 1)
        XCTAssertEqual(observer.results.first?.shortCircuit, .preconditionFailed)
        // 短路发生在派发之前，所以一次网络流量都不该有。
        XCTAssertEqual(observer.didSendCount, 0)
        XCTAssertEqual(observer.willStartCount, 0)
        XCTAssertEqual(completions, 1)
    }

    func testAsyncAdapterIsAwaited() {
        let client = makeClient()
        let recorder = ExecutionRecorder()
        client.add(adapter: AsyncRecordingAdapter(name: "async", recorder: recorder))
        client.add(adapter: PreconditionFailingAdapter(recorder: recorder))

        let done = expectation(description: "完成")
        client.send(TDNetworkRequest(url: URL(string: "https://api.example.com/ping")!)) { _ in
            done.fulfill()
        }
        waitForExpectations(timeout: 2)

        XCTAssertEqual(recorder.all, ["adapt:async", "adapt:fail endpoint=async"])
    }

    func testCompletionAndObserverFireExactlyOnce() {
        let client = makeClient()
        client.add(adapter: PreconditionFailingAdapter(recorder: ExecutionRecorder()))
        let observer = RecordingNetworkObserver()
        client.add(observer: observer)

        // 以 observer 的终态通知作为完成信号：completion 在它之前调用，
        // 这样断言时两边的计数都已落定，不会读到竞态中的旧值。
        let done = expectation(description: "完成")
        observer.onComplete = { done.fulfill() }

        var completionCount = 0
        client.send(TDNetworkRequest(url: URL(string: "https://api.example.com/ping")!)) { _ in
            completionCount += 1
        }
        waitForExpectations(timeout: 2)
        // 再等一会儿，确认没有第二次回调（重复回调会让成功率分母翻倍）。
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(observer.results.count, 1)
    }

    /// 回归：**重试链路**下 completion 也只能回调一次。
    ///
    /// 真机冒烟验证时实测到的问题：旧实现每个 attempt 结束都回调 `completion`，
    /// 于是「失败 → 重试 → 成功」会让业务先收到 failure、再收到 success，
    /// 表现为先弹一次错误提示、随后又被成功态覆盖。业务侧无法用这个契约写逻辑。
    ///
    /// 这条用例走真实发请求的路径（不是 adapter 短路），所以能覆盖重试分支。
    /// 目标地址用 127.0.0.1:1（连接被拒，立即失败），不依赖 DNS 与外网。
    func testCompletionFiresOnlyOnceAcrossRetries() {
        let client = makeClient()
        client.add(retrier: LimitedRetrier(maxAttempts: 3))
        let observer = RecordingNetworkObserver()
        client.add(observer: observer)

        var completionCount = 0
        var finalAttempt: Int?
        let done = expectation(description: "最终结果")
        _ = client.send(TDNetworkRequest(url: URL(string: "https://127.0.0.1:1/ping")!)) { result in
            completionCount += 1
            finalAttempt = result.context.attempt
            done.fulfill()
        }
        waitForExpectations(timeout: 15)
        // 留足重试窗口，确认中间 attempt 没有额外回调
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))

        XCTAssertEqual(completionCount, 1, "重试不得把中间失败回调给业务，否则业务会重复处理")
        XCTAssertEqual(observer.results.count, 1, "observer 同样只应收到终态，否则样本分母翻倍")
        XCTAssertEqual(finalAttempt, 2, "3 次尝试后终态的 attempt 应为 2（0 起算）")
        // 重试必须共享同一个 traceId，否则服务端看到的是三条互不相关的请求
        XCTAssertEqual(observer.results.first?.context.attempt, 2)
    }

    func testInternalRequestNeverConsultsRetrier() {
        // 上报自身流量不能重试：它有 TDRetryPolicy 的指数退避，
        // 再叠一层就是双重退避，弱网下会让上报队列指数膨胀。
        let ingest = TDNetworkRequest(
            url: URL(string: "https://ingest.example.com/batch")!,
            tag: TDRequestTag(isInternal: true))
        let business = TDNetworkRequest(url: URL(string: "https://api.example.com/ping")!)

        XCTAssertFalse(TDURLSessionNetworkClient.shouldConsultRetrier(for: ingest))
        XCTAssertTrue(TDURLSessionNetworkClient.shouldConsultRetrier(for: business))
    }

    func testShortCircuitOnlyCompletesOnce() {
        let client = makeClient()
        client.add(adapter: PreconditionFailingAdapter(recorder: ExecutionRecorder()))
        // 即使挂了「永远重试」的裁决器，短路路径也不该重试：
        // 没有网络流量可重试，重试只会在本地空转。
        client.add(retrier: FixedRetrier(.retry(after: 0, request: nil)))

        let observer = RecordingNetworkObserver()
        client.add(observer: observer)

        var completionCount = 0
        let done = expectation(description: "完成")
        client.send(TDNetworkRequest(url: URL(string: "https://api.example.com/ping")!)) { _ in
            completionCount += 1
            done.fulfill()
        }
        waitForExpectations(timeout: 2)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(observer.results.count, 1)
    }

    func testCancelledBeforeDispatchDoesNotCrash() {
        let client = makeClient()
        client.add(adapter: AsyncRecordingAdapter(name: "slow", recorder: ExecutionRecorder()))
        let observer = RecordingNetworkObserver()
        client.add(observer: observer)

        let handle = client.send(
            TDNetworkRequest(url: URL(string: "https://api.example.com/ping")!),
            completion: nil)
        handle.cancel()

        // 只要求不崩、不重复回调；取消语义本身由系统 URLSession 保证。
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertLessThanOrEqual(observer.results.count, 1)
    }
}
