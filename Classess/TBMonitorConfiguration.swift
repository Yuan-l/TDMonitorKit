import Foundation

/// Runtime configuration. Never hard-code a production key in source:
/// `TD_MONITOR_API_KEY` (Xcode scheme env) takes precedence over the plist value.
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
    public let metricsInterval: TimeInterval
    public let autoCollect: Bool

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
        metricsInterval: TimeInterval = 30,
        autoCollect: Bool = true
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
        self.metricsInterval = max(5, metricsInterval)
        self.autoCollect = autoCollect
    }

    /// Accepts either a host root (`http://host:3000`) or an API root
    /// (`http://host:3000/api/v1`) without ever double-appending the prefix.
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

    /// Load from `TDMonitor.plist` in the host app bundle.
    /// Required keys: `baseURL`, `apiKey` (or env `TD_MONITOR_API_KEY`), `appId`.
    public static func load(
        named name: String = "TDMonitor",
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TDMonitorConfiguration? {
        guard let path = bundle.path(forResource: name, ofType: "plist"),
              let dict = NSDictionary(contentsOfFile: path) as? [String: Any] else {
            return nil
        }
        // Xcode scheme / CI overrides: handy for real-device testing where
        // "localhost" would point at the device itself, not the dev machine.
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
            sampleRate: dict["sampleRate"] as? Double ?? 1.0,
            maxQueueSize: dict["maxQueueSize"] as? Int ?? 1000,
            flushInterval: dict["flushInterval"] as? TimeInterval ?? 10,
            hangThresholdMs: dict["hangThresholdMs"] as? Double ?? 250,
            metricsInterval: dict["metricsInterval"] as? TimeInterval ?? 30,
            autoCollect: dict["autoCollect"] as? Bool ?? true
        )
    }
}
