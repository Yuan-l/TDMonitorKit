import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(SystemConfiguration)
import SystemConfiguration
#endif

enum TDISO8601 {
    static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func string(from date: Date) -> String { formatter.string(from: date) }
}

/// Immutable-by-default session dimensions, with thread-safe mutable dimensions.
public final class TDContext {
    public let appId: String
    public let environment: String
    public let release: String
    public let os: String = "ios"
    public let osVersion: String
    public let deviceModel: String
    public let appVersion: String
    public let buildNumber: String
    public let deviceId: String
    public let sessionId: String

    private let lock = NSLock()
    private var _userId: String?
    private var _networkType: String
    private var _foreground: Bool

    public var userId: String? {
        get { lock.lock(); defer { lock.unlock() }; return _userId }
        set { lock.lock(); _userId = newValue; lock.unlock() }
    }
    public var networkType: String {
        get { lock.lock(); defer { lock.unlock() }; return _networkType }
        set { lock.lock(); _networkType = newValue; lock.unlock() }
    }
    public var foreground: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _foreground }
        set { lock.lock(); _foreground = newValue; lock.unlock() }
    }

    init(config: TDMonitorConfiguration) {
        self.appId = config.appId
        self.environment = config.environment
        self.release = config.release
        #if canImport(UIKit)
        let device = UIDevice.current
        self.osVersion = device.systemVersion
        self.deviceModel = device.model
        #else
        self.osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        self.deviceModel = "unknown"
        #endif
        self.appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        self.buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        self.sessionId = UUID().uuidString.lowercased()

        let defaults = UserDefaults(suiteName: "com.truedepth.monitor") ?? .standard
        let key = "td_device_id"
        if let existing = defaults.string(forKey: key) {
            self.deviceId = existing
        } else {
            #if canImport(UIKit)
            let identifier = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
            #else
            let identifier = UUID().uuidString
            #endif
            defaults.set(identifier, forKey: key)
            self.deviceId = identifier
        }
        self._networkType = TDReachability.currentType()
        self._foreground = true
    }

    /// Fields shared by every event. Extra per-kind fields are merged by `TDEvent`.
    var baseFields: [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        var fields: [String: Any] = [
            "appId": appId,
            "deviceId": deviceId,
            "sessionId": sessionId,
            "release": release,
            "environment": environment,
            "os": os,
            "osVersion": osVersion,
            "deviceModel": deviceModel,
            "appVersion": appVersion,
            "buildNumber": buildNumber,
            "networkType": _networkType,
            "foreground": _foreground,
        ]
        if let userId = _userId { fields["userId"] = userId }
        return fields
    }

    func refreshNetworkType() { networkType = TDReachability.currentType() }
}

enum TDReachability {
    static func currentType() -> String {
        #if canImport(SystemConfiguration)
        var zeroAddress = sockaddr_in()
        zeroAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        zeroAddress.sin_family = sa_family_t(AF_INET)
        let ref = withUnsafePointer(to: &zeroAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                SCNetworkReachabilityCreateWithAddress(nil, $0)
            }
        }
        guard let reachability = ref else { return "unknown" }
        var flags = SCNetworkReachabilityFlags()
        guard SCNetworkReachabilityGetFlags(reachability, &flags) else { return "unknown" }
        if !flags.contains(.reachable) { return "offline" }
        if flags.contains(.isWWAN) { return "cellular" }
        return "wifi"
        #else
        return "unknown"
        #endif
    }
}

/// One wire event. `fields` holds kind-specific top-level keys (schema-defined),
/// `attributes` holds free-form detail and is always a JSON object.
///
/// 对外可见：`TDEventSink` 是公开扩展点，自定义出口必须能读到事件内容。
/// `payload(context:)` 仍为内部——组包格式是 SDK 与后端的约定，不该成为公开 API。
public struct TDEvent {
    public let id: String
    public let ts: Date
    public let kind: String
    public let fields: [String: Any]
    public let attributes: [String: Any]
    /// 崩溃补发这类「事件发生在上一个会话」的场景，用真实会话 id 覆盖当前上下文。
    /// 只接受合法 UUID，避免把宿主报告里的自由文本带进后台的 sessionIdSchema。
    public let sessionIdOverride: String?

    public init(kind: String, fields: [String: Any] = [:], attributes: [String: Any] = [:],
                ts: Date = Date(), sessionIdOverride: String? = nil) {
        self.id = UUID().uuidString.lowercased()
        self.ts = ts
        self.kind = kind
        self.fields = fields
        self.attributes = attributes
        self.sessionIdOverride = sessionIdOverride.flatMap { UUID(uuidString: $0)?.uuidString.lowercased() }
    }

    func payload(context: TDContext) -> [String: Any] {
        var body = context.baseFields
        if let origin = sessionIdOverride { body["sessionId"] = origin }
        body["id"] = id
        body["ts"] = TDISO8601.string(from: ts)
        body["kind"] = kind
        for (key, value) in fields {
            body[key] = TDEvent.clamp(value, key: key)
        }
        if !attributes.isEmpty { body["attributes"] = attributes }
        return body
    }

    /// 按服务端 schema 的字段上限截断。超限会让整批被拒，损失面远大于截断。
    private static func clamp(_ value: Any, key: String) -> Any {
        guard let text = value as? String else { return value }
        let limit: Int
        switch key {
        case "message": limit = 4_000          // schema: 4096
        case "stack": limit = 60_000           // schema: 65536
        case "url": limit = 2_000              // schema: 2048
        case "exceptionType": limit = 120      // schema: 128
        case "exceptionCodes": limit = 500     // schema: 512
        case "signal": limit = 60              // schema: 64
        case "screen": limit = 250             // schema: 256
        default: limit = 512
        }
        guard text.count > limit else { return text }
        return String(text.prefix(limit))
    }
}
