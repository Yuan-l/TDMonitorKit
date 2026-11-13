import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Bounded, persisted, idempotent batch uploader.
/// - queue is capped and drops the oldest events (never grows unbounded)
/// - every event keeps its UUID across retries (server de-duplicates)
/// - 4xx (except 401/403/429) drops the rejected events, 5xx / 429 / network errors retry
/// - all work happens off the main queue
///
/// 关键设计：服务端按**整批**做 schema 校验，一条不合格就整批 422。如果整批丢弃，
/// 一条脏数据会连带丢掉同批最多 500 条好数据，而且下次还会因为同一条脏数据继续丢——
/// 数据面会形成永久缺口。所以整批被拒时做**二分隔离**：把批次劈成两半分别重发，
/// 递归到单条为止，只丢真正被拒的那条，并把服务端返回的 error body 记进诊断日志。
final class TDTransport {

    /// 单条事件的归属。
    enum Outcome: Equatable {
        case accepted
        case dropped
        case retry
    }

    /// 一次 HTTP 请求的结果。
    private enum Response {
        case accepted
        case rejected(status: Int, body: String)
        /// 401/403：凭据问题，跟事件内容无关，不做二分隔离也不无限重试。
        case unauthorized(status: Int, body: String)
        case retry
    }

    /// 隔离一批毒数据的请求预算：整批全坏时最多打这么多请求，避免故障放大。
    private static let isolationBudget = 24

    /// 一次 flush 内共享的隔离预算。请求从多个回调线程发起，必须线程安全。
    private final class Budget {
        private let lock = NSLock()
        private var remaining: Int
        init(_ value: Int) { remaining = value }
        var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return remaining <= 0 }
        /// 领一次额度；返回 false 表示预算已用尽。
        func consume() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }
    }

    private let config: TDMonitorConfiguration
    private let context: TDContext
    private let queue = DispatchQueue(label: "com.truedepth.monitor.transport", qos: .utility)
    private let session: URLSession
    private let storeURL: URL
    private var pending: [[String: Any]] = []
    private var timer: DispatchSourceTimer?
    private var backoff: TimeInterval = 0.25
    private var sending = false
    private var suspended = false
    private let authLogLock = NSLock()
    private var lastAuthLog = Date.distantPast

    init(config: TDMonitorConfiguration, context: TDContext) {
        self.config = config
        self.context = context
        let base = (try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = base.appendingPathComponent("TDMonitor", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.storeURL = directory.appendingPathComponent("pending.json")
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 15
        sessionConfig.waitsForConnectivity = true
        self.session = URLSession(configuration: sessionConfig)
    }

    func start() {
        queue.sync {
            if let data = try? Data(contentsOf: storeURL),
               let stored = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                pending = Array(stored.suffix(config.maxQueueSize))
            }
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + config.flushInterval, repeating: config.flushInterval)
        timer.setEventHandler { [weak self] in self?.flush() }
        timer.resume()
        self.timer = timer
        flush()
    }

    func enqueue(_ event: TDEvent) {
        let payload = event.payload(context: context)
        // 逐条守住 JSON 合法性：NaN / 无穷大会让整批序列化失败，坏数据只损失自己。
        guard JSONSerialization.isValidJSONObject(payload),
              (try? JSONSerialization.data(withJSONObject: payload)) != nil else {
            TDMonitorLog.record("丢弃无法序列化的事件 kind=\(event.kind)", level: "warning")
            return
        }
        queue.async { [weak self] in
            guard let self = self, !self.suspended else { return }
            if self.pending.count >= self.config.maxQueueSize {
                self.pending.removeFirst(self.pending.count - self.config.maxQueueSize + 1)
            }
            self.pending.append(payload)
            self.persistLocked()
        }
    }

    func flush(completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self = self, !self.sending, !self.pending.isEmpty else {
                completion?()
                return
            }
            self.sending = true
            let budget = Budget(TDTransport.isolationBudget)
            let batch = Array(self.pending.prefix(500))
            self.resolve(batch, budget: budget) { outcomes in
                self.queue.async {
                    let remove = min(batch.count, self.pending.count)
                    self.pending.removeFirst(remove)
                    // 发了但没定论的事件（网络错误 / 5xx / 限流）放回队首，按原顺序重试。
                    var retries: [[String: Any]] = []
                    for (index, event) in batch.enumerated() where index < outcomes.count {
                        if outcomes[index] == .retry { retries.append(event) }
                    }
                    if !retries.isEmpty {
                        self.pending.insert(contentsOf: retries, at: 0)
                        if self.pending.count > self.config.maxQueueSize {
                            self.pending.removeLast(self.pending.count - self.config.maxQueueSize)
                        }
                        self.backoff = min(self.backoff * 2, 8)
                    } else {
                        self.backoff = 0.25
                    }
                    self.persistLocked()
                    self.sending = false
                    completion?()
                }
            }
        }
    }

    /// Give the app a background task so a flush can finish before suspension.
    func flushInBackground() {
        #if canImport(UIKit)
        DispatchQueue.main.async {
            var identifier: UIBackgroundTaskIdentifier = .invalid
            identifier = UIApplication.shared.beginBackgroundTask {
                UIApplication.shared.endBackgroundTask(identifier)
            }
            self.flush {
                DispatchQueue.main.async { UIApplication.shared.endBackgroundTask(identifier) }
            }
        }
        #else
        flush()
        #endif
    }

    func stop() {
        timer?.cancel()
        timer = nil
        flushInBackground()
        TDMonitorLog.flushToDisk()
    }

    private func persistLocked() {
        guard JSONSerialization.isValidJSONObject(pending),
              let data = try? JSONSerialization.data(withJSONObject: pending) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    // MARK: - 发送与毒数据隔离

    /// 逐条给出归属。整批成功时一次请求完成；整批被拒时二分定位。
    private func resolve(_ batch: [[String: Any]], budget: Budget,
                         completion: @escaping ([Outcome]) -> Void) {
        guard !batch.isEmpty else { completion([]); return }
        post(batch, budget: budget) { [weak self] response in
            guard let self = self else { return }
            switch response {
            case .accepted:
                completion(Array(repeating: .accepted, count: batch.count))
            case .retry:
                completion(Array(repeating: .retry, count: batch.count))
            case let .rejected(status, body):
                guard batch.count > 1 else {
                    self.logRejection(batch[0], status: status, body: body)
                    completion([.dropped])
                    return
                }
                guard !budget.isEmpty else {
                    TDMonitorLog.record(
                        "隔离预算耗尽，\(batch.count) 条事件整组丢弃（HTTP \(status)）", level: "error")
                    completion(Array(repeating: .dropped, count: batch.count))
                    return
                }
                let middle = batch.count / 2
                let group = DispatchGroup()
                var left: [Outcome] = []
                var right: [Outcome] = []
                group.enter()
                self.resolve(Array(batch[..<middle]), budget: budget) { left = $0; group.leave() }
                group.enter()
                self.resolve(Array(batch[middle...]), budget: budget) { right = $0; group.leave() }
                group.notify(queue: self.queue) { completion(left + right) }
            case let .unauthorized(status, body):
                // 凭据问题：重发、二分都没有意义，只会把请求量放大 24 倍。
                self.logAuthFailure(status: status, body: body, count: batch.count)
                completion(Array(repeating: .dropped, count: batch.count))
            }
        }
    }

    private func post(_ batch: [[String: Any]], budget: Budget,
                      completion: @escaping (Response) -> Void) {
        guard budget.consume() else {
            completion(.retry)
            return
        }
        let body: [String: Any] = ["events": batch]
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body) else {
            TDMonitorLog.record("批次序列化失败，丢弃 \(batch.count) 条", level: "error")
            completion(.rejected(status: 0, body: "local serialization failed"))
            return
        }
        let url = config.ingestURL
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey, forHTTPHeaderField: "X-API-Key")
        request.httpBody = data
        session.dataTask(with: request) { [weak self] data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let error = error {
                TDMonitorLog.record("ingest failed: \(error.localizedDescription)", level: "error")
                self?.retryLater(completion)
                return
            }
            if (200...299).contains(status) {
                completion(.accepted)
            } else if status == 401 || status == 403 {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                completion(.unauthorized(status: status, body: body))
            } else if (400...499).contains(status), status != 429 {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                completion(.rejected(status: status, body: body))
            } else {
                self?.retryLater(completion)
            }
        }.resume()
    }

    private func retryLater(_ completion: @escaping (Response) -> Void) {
        let delay = backoff
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { completion(.retry) }
    }

    /// 把被拒事件的 kind / name / 服务端 error body 记下来。
    /// 没有这条日志，线上只能看到「数据没上来」，永远定位不到是哪条、为什么。
    private func logRejection(_ event: [String: Any], status: Int, body: String) {
        let kind = event["kind"] as? String ?? "?"
        let name = event["name"] as? String ?? "-"
        let attributes = (event["attributes"] as? [String: Any])?.keys.sorted().joined(separator: ",") ?? "-"
        let trimmed = body.count > 400 ? String(body.prefix(400)) : body
        TDMonitorLog.record(
            "事件被拒 HTTP \(status) kind=\(kind) name=\(name) attrs=[\(attributes)] body=\(trimmed)",
            level: "error")
    }

    /// 鉴权失败每分钟只记一次：Key 配错时会每轮都失败，刷日志没有意义。
    private func logAuthFailure(status: Int, body: String, count: Int) {
        authLogLock.lock()
        let shouldLog = Date().timeIntervalSince(lastAuthLog) > 60
        if shouldLog { lastAuthLog = Date() }
        authLogLock.unlock()
        guard shouldLog else { return }
        let trimmed = body.count > 200 ? String(body.prefix(200)) : body
        TDMonitorLog.record(
            "鉴权失败 HTTP \(status)，本批 \(count) 条事件已丢弃——请检查 apiKey 是否被吊销或过期 body=\(trimmed)",
            level: "error")
    }
}
