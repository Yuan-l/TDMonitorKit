import Foundation

/// In-memory diagnostics + a bounded on-disk mirror.
///
/// A library must not write to the host's console, so the kit keeps a small ring
/// buffer that the host can surface through its own logging facility via
/// `TDMonitor.shared.diagnostics`. On top of that, the same lines are mirrored to
/// `Library/Caches/TDMonitor/diagnostics.log` (256 KB, tail-kept): real problems
/// happen on a user's phone, and a memory-only buffer is gone by the time anyone
/// looks. The file lives inside the app sandbox — no permission, no host console.
enum TDMonitorLog {
    private static let capacity = 200
    private static let maxFileBytes = 256 * 1024
    private static let writeInterval: TimeInterval = 0.5

    private static let lock = NSLock()
    private static var entries: [String] = []
    private static var fileBuffer: String?
    private static var lastWrite = Date.distantPast

    static var fileURL: URL {
        let base = (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("TDMonitor", isDirectory: true)
            .appendingPathComponent("diagnostics.log")
    }

    static func record(_ message: String, level: String = "info") {
        let line = "\(TDISO8601.string(from: Date())) [\(level)] TDMonitor: \(message)"
        lock.lock()
        entries.append(line)
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        appendLocked(line + "\n")
        lock.unlock()
    }

    static func snapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    /// 已落盘的诊断日志（供宿主上报 / 排查时展示）。
    static func persisted() -> String {
        lock.lock()
        let buffered = fileBuffer
        lock.unlock()
        if let buffered = buffered { return buffered }
        return (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    }

    /// 进入后台 / 退出前调用，把节流期间攒下的内容立即落盘。
    static func flushToDisk() {
        lock.lock()
        defer { lock.unlock() }
        writeLocked()
    }

    // MARK: - 落盘（调用方持有 lock）

    private static func appendLocked(_ text: String) {
        if fileBuffer == nil {
            fileBuffer = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        }
        var buffer = (fileBuffer ?? "") + text
        if buffer.utf8.count > maxFileBytes {
            // 只保留尾部：诊断日志关心最近一次会话，不需要永久归档。
            let keep = String(buffer.suffix(maxFileBytes / 2))
            buffer = keep
        }
        fileBuffer = buffer
        guard Date().timeIntervalSince(lastWrite) > writeInterval else { return }
        writeLocked()
    }

    private static func writeLocked() {
        guard let buffer = fileBuffer else { return }
        let url = fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        // 原子写：任何时刻被强杀都不会留下半截文件。
        try? Data(buffer.utf8).write(to: url, options: .atomic)
        lastWrite = Date()
    }
}
