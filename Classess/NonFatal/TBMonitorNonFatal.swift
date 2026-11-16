import Foundation

/// 非致命异常采集。
///
/// 「非致命」指的是被业务 `@try/@catch` 或框架内部接住、没有导致进程退出的
/// Objective-C 异常。它们不会进崩溃列表，但往往就是下一次崩溃的前兆
/// （比如 unrecognized selector 被兜底后继续跑）。
///
/// `@throw` 走 `objc_exception_throw`，任何 SDK 都无法在不接管崩溃的前提下拦截；
/// 这里交换 `-[NSException raise]`，覆盖 `+[NSException raise:format:]` 系列与
/// 显式 `[exception raise]`，同时提供 `TDMonitor.recordNonFatal` 供业务补报。
/// 两者都会做去重与限流，避免异常风暴把队列打满。
final class TDNonFatalRecorder {

    static let shared = TDNonFatalRecorder()

    private let lock = NSLock()
    private var seen: [String: Date] = [:]
    private var windowCount = 0
    private var windowStart = Date()
    private let maxPerMinute = 20
    private let dedupeInterval: TimeInterval = 60

    private var handler: ((_ message: String, _ stack: String?, _ category: String,
                           _ attributes: [String: Any]) -> Void)?
    private var installed = false

    func install(handler: @escaping (_ message: String, _ stack: String?, _ category: String,
                                     _ attributes: [String: Any]) -> Void) {
        self.handler = handler
        guard !installed else { return }
        installed = true
        let original = #selector(NSException.raise)
        let replacement = #selector(NSException.td_raise)
        guard let originalMethod = class_getInstanceMethod(NSException.self, original),
              let replacementMethod = class_getInstanceMethod(NSException.self, replacement) else { return }
        method_exchangeImplementations(originalMethod, replacementMethod)
    }

    /// 还原 `-[NSException raise]` 并停止投递。
    func uninstall() {
        lock.lock()
        handler = nil
        let wasInstalled = installed
        installed = false
        lock.unlock()
        guard wasInstalled else { return }
        let original = #selector(NSException.raise)
        let replacement = #selector(NSException.td_raise)
        guard let originalMethod = class_getInstanceMethod(NSException.self, original),
              let replacementMethod = class_getInstanceMethod(NSException.self, replacement) else { return }
        method_exchangeImplementations(originalMethod, replacementMethod)
    }

    /// 业务侧显式上报（Swift `Error`、被 catch 的异常、降级分支）。
    func record(message: String, stack: String? = nil, category: String = "non_fatal",
                attributes: [String: Any] = [:]) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let topFrame = stack?.split(separator: "\n").first.map(String.init)
        let key = "\(category)|\(trimmed.prefix(160))|\(topFrame?.prefix(120) ?? "")"

        lock.lock()
        if windowStart.timeIntervalSinceNow < -60 {
            windowStart = Date()
            windowCount = 0
        }
        if windowCount >= maxPerMinute {
            lock.unlock()
            return
        }
        if let last = seen[key], Date().timeIntervalSince(last) < dedupeInterval {
            lock.unlock()
            return
        }
        seen[key] = Date()
        windowCount += 1
        if seen.count > 200 { seen.removeAll() }
        lock.unlock()

        handler?(trimmed, stack, category, attributes)
    }

    func record(exception: NSException) {
        var userInfoKeys: [String] = []
        if let userInfo = exception.userInfo {
            userInfoKeys = userInfo.keys.prefix(12).map { "\($0)" }
        }
        var attributes: [String: Any] = [
            "exceptionName": exception.name.rawValue,
            "userInfoKeys": userInfoKeys,
        ]
        if let reason = exception.reason { attributes["reason"] = String(reason.prefix(500)) }
        record(message: "\(exception.name.rawValue): \(exception.reason ?? "unknown")",
               stack: exception.callStackSymbols.joined(separator: "\n"),
               category: "objc_exception",
               attributes: attributes)
    }
}

extension NSException {
    /// 交换后的入口：先记录，再把控制权交给系统原实现（该抛还是抛）。
    @objc func td_raise() {
        TDNonFatalRecorder.shared.record(exception: self)
        td_raise()
    }
}
