import Foundation

/// 一批事件的发送结果。**只有这四种**，因为后面所有决策都只依赖这四种。
///
/// 旧实现把这个判断散在 `post` 的 if-else 里，混着 HTTP 细节（`1xx`/`2xx`/`3xx`
/// 都要在脑子里过一遍才能确认行为）。抽成枚举之后，「哪些该重试」变成一张
/// 可以写成测试的表，不再是读代码猜。
enum TDUploadOutcome: Equatable {
    /// 2xx：服务端收下，这批事件可以出队。
    case accepted

    /// 4xx（不含 401/403/429）：**内容**有问题。重发同样的内容一定还是被拒，
    /// 只能丢。丢之前必须做隔离，找出到底哪几条。
    case rejected(status: Int, body: String)

    /// 401/403：**凭据**有问题，与内容无关。三个可能：Key 吊销、Key 配错、网关拦了。
    /// 不做二分隔离——那会把请求量放大 20 倍去证明同一个结论。
    case unauthorized(status: Int, body: String)

    /// 网络错误 / 5xx / 429：环境问题，内容是对的，原样重发有效。
    case retryable(reason: String)
}

/// 发送一批已组包的事件。
///
/// 这是「换后端」真正要替换的那一层。实现它不需要理解队列、重试、落盘，
/// 只需要回答一个问题：这批 JSON 发出去，服务端是什么态度。
protocol TDBatchUploader: AnyObject {
    func upload(_ payloads: [[String: Any]], completion: @escaping (TDUploadOutcome) -> Void)
}

/// 内置 HTTP 实现：POST 到 `ingestURL`，用 `X-API-Key` 鉴权。
///
/// 刻意做的事只有一件：把 HTTP 结果翻译成 `TDUploadOutcome`。
/// 不重试、不落盘、不改队列——那些都在调用方。
final class TDHTTPBatchUploader: TDBatchUploader {

    private let configuration: TDMonitorConfiguration
    private let session: URLSession

    init(configuration: TDMonitorConfiguration) {
        self.configuration = configuration
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 15
        // 有网才发，不要为了上报在无网时反复起连接把电量磨掉。
        sessionConfig.waitsForConnectivity = true
        self.session = URLSession(configuration: sessionConfig)
    }

    func upload(_ payloads: [[String: Any]], completion: @escaping (TDUploadOutcome) -> Void) {
        let body: [String: Any] = ["events": payloads]
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body) else {
            // 序列化失败是本地问题，重发也不会好，按内容问题处理。
            completion(.rejected(status: 0, body: "local serialization failed"))
            return
        }

        var request = URLRequest(url: configuration.ingestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.apiKey, forHTTPHeaderField: "X-API-Key")
        request.httpBody = data

        session.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.retryable(reason: error.localizedDescription))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""

            switch status {
            case 200...299:
                completion(.accepted)
            case 401, 403:
                completion(.unauthorized(status: status, body: text))
            case 400...499 where status != 429:
                completion(.rejected(status: status, body: text))
            default:
                // 429 限流、5xx、3xx（会话被网关重定向）、status=0：
                // 没有一条是「内容错了」，全部走重试。
                completion(.retryable(reason: "HTTP \(status)"))
            }
        }.resume()
    }
}

/// 退避与可重试判定。
///
/// 抽成 `struct` + 纯函数的唯一目的是**可测**。旧实现的退避逻辑写在
/// `flush` 的异步回调里，改一个系数要在模拟器上跑真流量才能确认，
/// 实际上等于没人敢改。
struct TDRetryPolicy {

    /// 首次重试等待。0.25s 足够让偶发抖动过去，又不会让用户等到下一次定时 flush。
    var initialDelay: TimeInterval = 0.25
    /// 上限 8s。再长就等于放弃——用户可能已经切走，下一次启动才有机会补发。
    var maximumDelay: TimeInterval = 8

    /// 指数退避：0.25 → 0.5 → 1 → 2 → 4 → 8 → 8 …
    func nextDelay(current: TimeInterval) -> TimeInterval {
        min(max(current, initialDelay) * 2, maximumDelay)
    }

    /// 成功后是否重置。必须重置，否则一次网络抖动会让该进程后续所有重试都等 8s。
    func resetDelay() -> TimeInterval { initialDelay }

    /// 这批结果里只要还有待重试的，就要排下一次等待。
    /// 全成功则立刻恢复成「随时可发」。
    func delay(for outcomes: [TDBatchResolver.Outcome], current: TimeInterval) -> TimeInterval {
        outcomes.contains(.retry) ? nextDelay(current: current) : resetDelay()
    }
}
