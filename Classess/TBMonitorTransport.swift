import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Bounded, persisted, idempotent batch uploader.
/// - queue is capped and drops the oldest events (never grows unbounded)
/// - every event keeps its UUID across retries (server de-duplicates)
/// - 4xx (except 429) is dropped, 5xx / 429 / network errors retry with backoff
/// - all work happens off the main queue
final class TDTransport {
    private enum Outcome { case success, discard, retry }

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
            let batch = Array(self.pending.prefix(500))
            self.send(batch) { [weak self] outcome in
                guard let self = self else { completion?(); return }
                self.queue.async {
                    switch outcome {
                    case .success, .discard:
                        let remove = min(batch.count, self.pending.count)
                        self.pending.removeFirst(remove)
                        self.backoff = 0.25
                    case .retry:
                        self.backoff = min(self.backoff * 2, 8)
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
    }

    private func persistLocked() {
        guard JSONSerialization.isValidJSONObject(pending),
              let data = try? JSONSerialization.data(withJSONObject: pending) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    private func send(_ batch: [[String: Any]], completion: @escaping (Outcome) -> Void) {
        let body: [String: Any] = ["events": batch]
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body) else {
            completion(.discard)
            return
        }
        let url = config.ingestURL
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey, forHTTPHeaderField: "X-API-Key")
        request.httpBody = data
        session.dataTask(with: request) { _, response, error in
            if let error = error {
                TDMonitorLog.record("ingest failed: \(error.localizedDescription)", level: "error")
                // Respect the backoff before the next automatic attempt.
                DispatchQueue.global().asyncAfter(deadline: .now() + self.backoff) { completion(.retry) }
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200...299).contains(status) {
                completion(.success)
            } else if (400...499).contains(status) && status != 429 {
                TDMonitorLog.record("ingest rejected HTTP \(status), dropping batch", level: "error")
                completion(.discard)
            } else {
                DispatchQueue.global().asyncAfter(deadline: .now() + self.backoff) { completion(.retry) }
            }
        }.resume()
    }
}
