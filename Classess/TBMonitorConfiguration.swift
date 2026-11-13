import Foundation

/// 运行时配置。生产 Key 绝不硬编码在源码里：
/// Xcode Scheme / CI 的 `TD_MONITOR_API_KEY` 优先于 plist。
public struct TDMonitorConfiguration {
    public let baseURL: URL
    public let apiKey: String
    public let appId: String
    public let environment: String
    public let release: String
    public let sampleRate: Double
    public let maxQueueSize: Int
    public let flushInterval: TimeInterval
    public let hangThresholdMs: Double
    public let anrSampleIntervalMs: Double
    public let maxHangMs: Double
    public let longTaskThresholdMs: Double
    public let metricsInterval: TimeInterval
    public let autoCollect: Bool
    public let networkInstrumentation: Bool
    public let viewLoadInstrumentation: Bool
    public let nonFatalCapture: Bool

    public init(
        baseURL: URL,
        apiKey: String,
        appId: String,
        environment: String = "development",
        release: String? = nil,
        sampleRate: Double = 1.0,
        maxQueueSize: Int = 1000,
        flushInterval: TimeInterval = 10,
        hangThresholdMs: Double = 250,
        anrSampleIntervalMs: Double = 50,
        maxHangMs: Double = 10_000,
        longTaskThresholdMs: Double = 100,
        metricsInterval: TimeInterval = 30,
        autoCollect: Bool = true,
        networkInstrumentation: Bool = true,
        viewLoadInstrumentation: Bool = true,
        nonFatalCapture: Bool = true
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.appId = appId
        self.environment = environment
        self.release = release
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "unknown"
        self.sampleRate = min(max(sampleRate, 0), 1)
        self.maxQueueSize = max(100, maxQueueSize)
        self.flushInterval = max(2, flushInterval)
        self.hangThresholdMs = max(50, hangThresholdMs)
        self.anrSampleIntervalMs = max(20, anrSampleIntervalMs)
        self.maxHangMs = max(1000, maxHangMs)
        self.longTaskThresholdMs = max(16, longTaskThresholdMs)
        self.metricsInterval = max(5, metricsInterval)
        self.autoCollect = autoCollect
        self.networkInstrumentation = networkInstrumentation
        self.viewLoadInstrumentation = viewLoadInstrumentation
        self.nonFatalCapture = nonFatalCapture
    }

    /// 兼容主机根（`http://host:3000`）与 API 根（`http://host:3000/api/v1`），
    /// 不会重复拼前缀。
    var apiRoot: URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              components.scheme != nil, components.host != nil else { return baseURL }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/api/v1") { path += "/api/v1" }
        components.path = path
        return components.url ?? baseURL
    }

    var ingestURL: URL { apiRoot.appendingPathComponent("telemetry/ingest") }

    /// 从宿主 Bundle 的 `TDMonitor.plist` 读取。
    /// 必需键：`baseURL`、`apiKey`（或环境变量）、`appId`。
    public static func load(
        named name: String = "TDMonitor",
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TDMonitorConfiguration? {
        guard let path = bundle.path(forResource: name, ofType: "plist"),
              let dict = NSDictionary(contentsOfFile: path) as? [String: Any] else {
            return nil
        }
        let urlString = environment["TD_MONITOR_BASE_URL"]
            ?? (dict["baseURL"] as? String) ?? ""
        guard !urlString.isEmpty, let baseURL = URL(string: urlString),
              baseURL.scheme != nil, baseURL.host != nil else { return nil }
        let apiKey = environment["TD_MONITOR_API_KEY"] ?? (dict["apiKey"] as? String) ?? ""
        guard !apiKey.isEmpty else { return nil }
        let env = environment["TD_MONITOR_ENV"]
            ?? (dict["environment"] as? String)
            ?? "development"
        return TDMonitorConfiguration(
            baseURL: baseURL,
            apiKey: apiKey,
            appId: dict["appId"] as? String ?? "truedepthdemo2",
            environment: env,
            release: dict["release"] as? String,
            sampleRate: doubleValue(dict["sampleRate"]) ?? 1.0,
            maxQueueSize: intValue(dict["maxQueueSize"]) ?? 1000,
            flushInterval: doubleValue(dict["flushInterval"]) ?? 10,
            hangThresholdMs: doubleValue(dict["hangThresholdMs"]) ?? 250,
            anrSampleIntervalMs: doubleValue(dict["anrSampleIntervalMs"]) ?? 50,
            maxHangMs: doubleValue(dict["maxHangMs"]) ?? 10_000,
            longTaskThresholdMs: doubleValue(dict["longTaskThresholdMs"]) ?? 100,
            metricsInterval: doubleValue(dict["metricsInterval"]) ?? 30,
            autoCollect: dict["autoCollect"] as? Bool ?? true,
            networkInstrumentation: dict["networkInstrumentation"] as? Bool ?? true,
            viewLoadInstrumentation: dict["viewLoadInstrumentation"] as? Bool ?? true,
            nonFatalCapture: dict["nonFatalCapture"] as? Bool ?? true
        )
    }

    /// plist 里的数字可能是 Integer 也可能是 Real，统一收口。
    private static func doubleValue(_ any: Any?) -> Double? {
        if let value = any as? Double { return value }
        if let value = any as? Int { return Double(value) }
        if let value = any as? NSNumber { return value.doubleValue }
        return nil
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let value = any as? Int { return value }
        if let value = any as? NSNumber { return value.intValue }
        return nil
    }
}
