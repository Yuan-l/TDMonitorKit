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
final class TDContext {
    let appId: String
    let environment: String
    let release: String
    let os: String = "ios"
    let osVersion: String
    let deviceModel: String
    let appVersion: String
    let buildNumber: String
    let deviceId: String
    let sessionId: String

    private let lock = NSLock()
    private var _userId: String?
    private var _networkType: String
    private var _foreground: Bool

    var userId: String? {
        get { lock.lock(); defer { lock.unlock() }; return _userId }
        set { lock.lock(); _userId = newValue; lock.unlock() }
    }
    var networkType: String {
        get { lock.lock(); defer { lock.unlock() }; return _networkType }
        set { lock.lock(); _networkType = newValue; lock.unlock() }
    }
    var foreground: Bool {
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
struct TDEvent {
    let id: String
    let ts: Date
    let kind: String
    let fields: [String: Any]
    let attributes: [String: Any]

    init(kind: String, fields: [String: Any] = [:], attributes: [String: Any] = [:], ts: Date = Date()) {
        self.id = UUID().uuidString.lowercased()
        self.ts = ts
        self.kind = kind
        self.fields = fields
        self.attributes = attributes
    }

    func payload(context: TDContext) -> [String: Any] {
        var body = context.baseFields
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
