import Foundation

/// 把「一批里有一条毒数据导致整批 422」定位到具体那一条。
///
/// 为什么这件事必须做（而不是整批丢掉）：
/// 服务端按**整批**做 schema 校验，一条不合格就整批拒。如果整批丢弃，
/// 一条脏数据会连带丢掉同批最多 500 条好数据，**而且下次还是同一条脏数据继续丢**，
/// 形成永久数据缺口。用户看到的现象是「这个版本某几个指标莫名其妙没数据」。
///
/// Sentry 用 envelope 逐条投递，天然不会整批失败，所以没有这个问题；
/// Datadog 的批次服务端是逐条校验的。我们后端不是，所以这一段必须自己做。
/// 这一层是纯逻辑——给定 uploader 的行为，输出每条事件的归属，可完全用假数据测试。
final class TDBatchResolver {

    enum Outcome: Equatable {
        case accepted
        case dropped
        case retry
    }

    /// 隔离一次 flush 允许消耗的额外请求数。
    /// 整批全坏时，二分会打约 2n 个请求；不设上限会让一次故障放大成请求风暴。
    static let defaultIsolationBudget = 24

    private let uploader: TDBatchUploader
    private var remainingBudget: Int
    private let onReject: ((_ payload: [String: Any], _ status: Int, _ body: String) -> Void)?
    private let onAuthFailure: ((_ status: Int, _ body: String, _ count: Int) -> Void)?
    private let onBudgetExhausted: ((_ count: Int, _ status: Int) -> Void)?
    private let lock = NSLock()

    init(uploader: TDBatchUploader,
         isolationBudget: Int = TDBatchResolver.defaultIsolationBudget,
         onReject: ((_ payload: [String: Any], _ status: Int, _ body: String) -> Void)? = nil,
         onAuthFailure: ((_ status: Int, _ body: String, _ count: Int) -> Void)? = nil,
         onBudgetExhausted: ((_ count: Int, _ status: Int) -> Void)? = nil) {
        self.uploader = uploader
        self.remainingBudget = max(1, isolationBudget)
        self.onReject = onReject
        self.onAuthFailure = onAuthFailure
        self.onBudgetExhausted = onBudgetExhausted
    }

    /// 逐条给出归属。整批成功时一次请求完成；整批被拒时二分定位。
    func resolve(_ batch: [[String: Any]], completion: @escaping ([Outcome]) -> Void) {
        guard !batch.isEmpty else { completion([]); return }

        uploader.upload(batch) { [weak self] outcome in
            guard let self = self else { return }
            switch outcome {
            case .accepted:
                completion(Array(repeating: .accepted, count: batch.count))

            case .retryable:
                completion(Array(repeating: .retry, count: batch.count))

            case let .rejected(status, body):
                guard batch.count > 1 else {
                    self.onReject?(batch[0], status, body)
                    completion([.dropped])
                    return
                }
                guard self.consumeBudget() else {
                    self.onBudgetExhausted?(batch.count, status)
                    completion(Array(repeating: .dropped, count: batch.count))
                    return
                }
                let middle = batch.count / 2
                let group = DispatchGroup()
                var left: [Outcome] = []
                var right: [Outcome] = []
                group.enter()
                self.resolve(Array(batch[..<middle])) { left = $0; group.leave() }
                group.enter()
                self.resolve(Array(batch[middle...])) { right = $0; group.leave() }
                group.notify(queue: .global()) { completion(left + right) }

            case let .unauthorized(status, body):
                self.onAuthFailure?(status, body, batch.count)
                completion(Array(repeating: .dropped, count: batch.count))
            }
        }
    }

    /// 领一次额度。请求从多个回调线程发起，必须加锁。
    private func consumeBudget() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard remainingBudget > 0 else { return false }
        remainingBudget -= 1
        return true
    }
}
