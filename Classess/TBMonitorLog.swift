import Foundation

/// In-memory diagnostics. A library must not write to the host's console, so
/// the kit keeps a small bounded ring buffer instead and lets the host surface
/// it through its own logging facility via `TDMonitor.shared.diagnostics`.
enum TDMonitorLog {
    private static let capacity = 50
    private static let lock = NSLock()
    private static var entries: [String] = []

    static func record(_ message: String, level: String = "info") {
        let line = "\(TDISO8601.string(from: Date())) [\(level)] TDMonitor: \(message)"
        lock.lock()
        entries.append(line)
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        lock.unlock()
    }

    static func snapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }
}
