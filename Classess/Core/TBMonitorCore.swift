import Foundation
#if canImport(QuartzCore)
import QuartzCore
#endif

// MARK: - 事件出口

/// 上报出口。
///
/// SDK 内部所有采集单元只依赖这个协议，**不依赖任何具体上报实现**。
/// 这是「换后端零成本」的边界：
/// - 换云厂商 / 自建 Kafka / 双写 → 换一个 `TDEventSink` 实现，采集代码零改动
/// - 单元测试 → 换成内存实现，直接断言「发了什么、发了几条、字段对不对」
/// - 私有化交付 → 换成写本地文件的实现，连网络都不需要
///
/// 之前 7 个类直接 `let transport: TDTransport`，接口被具体类型焊死，
/// 上面三件事一件都做不到。
public protocol TDEventSink: AnyObject {
    /// 恢复上次未发完的队列并启动定时 flush。
    func start()
    func enqueue(_ event: TDEvent)
    func flush()
    /// 借后台任务额度把队列发完，供进后台 / 退出前调用。
    func flushInBackground()
    /// 停止定时调度。**不丢弃**队列内容——留在本地待下次启动续发。
    func stop()
}

extension TDEventSink {
    /// 自定义出口的默认实现：没有定时器可停，把队列发完即可。
    /// 这样外部实现的 sink 不必为了满足协议写一个空方法。
    public func stop() { flushInBackground() }
}

// MARK: - 时钟

/// 可注入时钟。
///
/// 采集逻辑里凡是「阈值」「窗口」「切片」都依赖时间。之前一律直接调
/// `Date()` / `CACurrentMediaTime()`，导致这些逻辑**无法被确定性测试**——
/// 只能靠 sleep 去撞，撞不上就调阈值。抽出时钟后，测试可以把 8 秒卡顿、
/// 30 秒切片在 1 毫秒内跑完并断言结果。
public protocol TDClock: AnyObject {
    /// 墙钟。只用于事件时间戳与展示，不用于测量间隔。
    var now: Date { get }
    /// 单调时钟。测间隔一律用它：NTP 校时、用户改时间都不会让差值变负。
    var monotonic: TimeInterval { get }
}

public final class TDSystemClock: TDClock {
    public static let shared = TDSystemClock()
    private init() {}

    public var now: Date { Date() }

    public var monotonic: TimeInterval {
        #if canImport(QuartzCore)
        return CACurrentMediaTime()
        #else
        return ProcessInfo.processInfo.systemUptime
        #endif
    }
}

/// 手动时钟。仅测试与本地调试使用。
final class TDManualClock: TDClock {
    private let lock = NSLock()
    private var _now: Date
    private var _monotonic: TimeInterval

    init(now: Date = Date(timeIntervalSince1970: 1_700_000_000), monotonic: TimeInterval = 0) {
        self._now = now
        self._monotonic = monotonic
    }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return _now
    }

    var monotonic: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return _monotonic
    }

    /// 时间一起往前推，保持墙钟与单调时钟不漂移。
    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        _now = _now.addingTimeInterval(seconds)
        _monotonic += seconds
    }
}

// MARK: - 运行时容器

/// 一次运行期的依赖容器。
///
/// 对照 Sentry 的 `SentryDependencyContainer` 与 Datadog 的 `FeatureBaggage`：
/// 能力单元之间不互相持引用，也不各自摸全局单例，只从这里取依赖。
/// 带来两个直接结果：
/// 1. **没有循环依赖**——A 要用 B，取的是协议/服务，不是 B 的实例引用
/// 2. **可替换**——测试时把 clock / sink / appState 换成假实现即可
public final class TDMonitorRuntime {

    public let configuration: TDMonitorConfiguration
    public let context: TDContext
    public let sink: TDEventSink
    public let clock: TDClock
    public let capabilities: TDCapabilityMatrix
    public let appState: TDAppStateTracker

    private let lock = NSLock()
    private var services: [ObjectIdentifier: Any] = [:]
    private var _installed: [String] = []
    private var _blocked: [String: [String]] = [:]

    public init(
        configuration: TDMonitorConfiguration,
        context: TDContext,
        sink: TDEventSink,
        clock: TDClock = TDSystemClock.shared,
        capabilities: TDCapabilityMatrix,
        appState: TDAppStateTracker = .shared
    ) {
        self.configuration = configuration
        self.context = context
        self.sink = sink
        self.clock = clock
        self.capabilities = capabilities
        self.appState = appState
    }

    // MARK: 服务注册表

    /// 注册一个供其它能力单元取用的服务。
    public func provide<T>(_ service: T) {
        lock.lock()
        services[ObjectIdentifier(T.self)] = service
        lock.unlock()
    }

    /// 取服务。取不到返回 nil，由调用方决定降级还是放弃安装。
    public func service<T>(_ type: T.Type) -> T? {
        lock.lock(); defer { lock.unlock() }
        return services[ObjectIdentifier(type)] as? T
    }

    // MARK: 安装记录

    public func noteInstalled(_ name: String) {
        lock.lock()
        _installed.append(name)
        lock.unlock()
    }

    /// 记录「依赖没装上但自己装上了」的能力。
    ///
    /// 这类能力不会报错，只会表现为「某个指标突然没数据」，是最难排查的一种故障。
    /// 所以即使 Release 也要留痕，不能只在 DEBUG 断言里出现。
    public func noteBlocked(_ name: String, missing: [String]) {
        lock.lock()
        _blocked[name] = missing
        lock.unlock()
    }

    public var installedFeatures: [String] {
        lock.lock(); defer { lock.unlock() }
        return _installed
    }

    /// 依赖缺失的能力 → 缺失的依赖名。空字典表示所有依赖都满足了。
    public var blockedFeatures: [String: [String]] {
        lock.lock(); defer { lock.unlock() }
        return _blocked
    }
}

// MARK: - 能力单元

/// 一个可独立安装、独立卸载的能力。
///
/// 对照 Sentry 的 `SwiftIntegration`：
/// - `init?(runtime:)` 是**可失败构造器**，当前环境不支持就返回 nil，
///   SDK 静默跳过它继续装其它的，不会因为一个能力不可用而整体起不来。
///   这正是「`MXAppExitMetric` 只有 iOS 14 才有，iOS 13 怎么办」的架构级答案：
///   iOS 13 上 `TDMetricKitFeature` 直接不存在，其余能力照常工作，
///   同时 `cap.oom_metrickit=0` 会随 `session_start` 上报——降级是**数据里可见的事实**，
///   不是文档里的一句免责声明。
/// - `name` 用于安装/卸载日志与能力矩阵对账
/// - `install()` 返回 false 表示运行期安装失败（权限、系统接口异常等），
///   同样不阻断其它能力
public protocol TDMonitorFeature: AnyObject {
    static var name: String { get }
    /// 必须在它之前安装的能力名。仅用于 DEBUG 顺序断言，Release 零开销。
    static var requires: [String] { get }
    init?(runtime: TDMonitorRuntime)
    func install() -> Bool
    func uninstall()
}

public extension TDMonitorFeature {
    static var requires: [String] { [] }
}

// MARK: - 能力注册表

/// 按注册顺序安装、逆序卸载。
///
/// 顺序敏感的地方（终止归因必须早于 `session_start`、`transport.start()`
/// 必须早于所有 enqueue）由**注册顺序**显式表达，读代码就能看出依赖，
/// 不再藏在一个 167 行方法的执行流里。
public final class TDMonitorFeatureRegistry {

    private struct Entry {
        let name: String
        let requires: [String]
        let make: (TDMonitorRuntime) -> TDMonitorFeature?
    }

    private var entries: [Entry] = []
    private var installed: [TDMonitorFeature] = []
    private let lock = NSLock()

    public func register<F: TDMonitorFeature>(_ type: F.Type) {
        lock.lock(); defer { lock.unlock() }
        guard !entries.contains(where: { $0.name == type.name }) else { return }
        entries.append(Entry(name: type.name, requires: type.requires) { runtime in
            type.init(runtime: runtime)
        })
    }

    /// 外部扩展入口：用闭包登记一个自定义能力。
    ///
    /// `name` / `requires` 由调用方从类型上取（`MyFeature.name` / `MyFeature.requires`），
    /// 避免在公开 API 上再暴露 Swift 的元类型。自定义能力复用与内置能力
    /// 完全相同的依赖注入、顺序安装、逆序卸载与能力矩阵对账。
    public func register(
        _ maker: @escaping (TDMonitorRuntime) -> TDMonitorFeature?,
        name: String,
        requires: [String] = []
    ) {
        lock.lock(); defer { lock.unlock() }
        guard !entries.contains(where: { $0.name == name }) else { return }
        entries.append(Entry(name: name, requires: requires, make: maker))
    }

    /// 计算未满足的依赖。
    ///
    /// 抽成纯函数是因为 DEBUG 下的 `assert` 会直接终止进程，无法在测试里走那条分支；
    /// 但「哪些依赖算缺失」本身是业务规则，必须能单独验证。
    public static func unmetRequirements(requires: [String], installed: [String]) -> [String] {
        requires.filter { !installed.contains($0) }
    }

    /// 依次安装。返回实际装上的能力名，跳过的不在其中。
    @discardableResult
    func installAll(runtime: TDMonitorRuntime) -> [String] {
        lock.lock()
        let plan = entries
        lock.unlock()

        var names: [String] = []
        for entry in plan {
            // iOS 13 上 MetricKit 能力返回 nil 走这里；不是错误，是设计。
            guard let feature = entry.make(runtime) else {
                TDMonitorLog.record("能力 \(entry.name) 在当前环境不可用，跳过", level: "info")
                continue
            }
            let unmet = Self.unmetRequirements(requires: entry.requires, installed: names)
            // 这里**刻意不用 assert**。之前是 `#if DEBUG assert(...)`，两个问题：
            // 1. 注册顺序写错就让宿主 App 在开发期直接崩——监控组件绝不能成为新的崩溃源；
            // 2. Release 下这段被编译掉，线上「某个指标突然没数据」永远查不到原因。
            // 改为统一留痕：DEBUG / Release 行为一致，且崩的是功能而不是进程。
            if !unmet.isEmpty {
                runtime.noteBlocked(entry.name, missing: unmet)
                TDMonitorLog.record(
                    "能力 \(entry.name) 的依赖 [\(unmet.joined(separator: ", "))] 未安装，该能力可能不完整",
                    level: "warning")
            }
            guard feature.install() else {
                TDMonitorLog.record("能力 \(entry.name) 安装失败，跳过", level: "warning")
                continue
            }
            lock.lock()
            installed.append(feature)
            lock.unlock()
            runtime.noteInstalled(entry.name)
            names.append(entry.name)
        }
        return names
    }

    /// 逆序卸载：后装的先拆，避免依赖方还在用就被拆掉。
    func uninstallAll() {
        lock.lock()
        let features = installed.reversed()
        installed.removeAll()
        lock.unlock()
        for feature in features { feature.uninstall() }
    }

    public var installedNames: [String] {
        lock.lock(); defer { lock.unlock() }
        return installed.map { type(of: $0).name }
    }
}

// MARK: - 队列

/// 统一线程模型。
///
/// 之前 4 个模块各自 `DispatchQueue(label: "com.truedepth.monitor.xxx")`，
/// 谁也不清楚整体有几个队列、优先级怎么排、哪些任务会互相阻塞。
/// 收口到这里之后，「SDK 一共 4 条串行队列，全部 utility，不占主线程」
/// 是一句可以被审计的话。
///
/// 约定：
/// - 采集回调（`displayLink` / `notification` / 网络完成）在各自系统线程触发，
///   一律**不做重活**，只投递到对应队列
/// - 落盘、序列化、重试全部在 utility 队列
/// - 主线程只做 UIKit 相关（后台任务登记、通知观察者）
enum TDMonitorQueues {
    /// 事件队列与上报
    static let transport = DispatchQueue(label: "com.truedepth.monitor.transport", qos: .utility)
    /// 终止现场的落盘（内存序列、前台状态、退出标记）
    static let appState = DispatchQueue(label: "com.truedepth.monitor.appstate", qos: .utility)
    /// 卡顿检测与栈采样
    ///
    /// 注意：这是**串行**队列，且 `TDHangWatchdog.loop()` 用 semaphore 长期占住它。
    /// 任何需要排队执行的后处理（screen_render / long_task 的栈符号化）都**不能**
    /// 投到这里，否则永远排不上队、事件静默丢失。那些请走 `symbolication`。
    static let hang = DispatchQueue(label: "com.truedepth.monitor.hang", qos: .utility)
    /// 栈符号化后处理（screen_render / long_task 的 dladdr + 事件组装）。
    ///
    /// 独立于 hang 队列：hang 被 watchdog 独占，投进去会饿死。用并发队列，
    /// 多页面同时结算也不互相阻塞；dladdr 内部自带锁、并发安全。
    static let symbolication = DispatchQueue(label: "com.truedepth.monitor.symbolication",
                                             qos: .utility, attributes: .concurrent)
    /// 周期资源采样
    static let resource = DispatchQueue(label: "com.truedepth.monitor.resource", qos: .utility)
}
