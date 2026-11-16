import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// 现场时间线上的一条记录。
///
/// 存在的理由：OOM 的难点从来不是「判断是不是」，而是**「在什么时候、被什么耗尽的」**。
/// 之前只有一堆散落字段——`peakFootprintMb`、`memoryWarningCount`、`lastScreen`——
/// 它们各自是对的，但彼此之间**没有时间关系**。看到「峰值 900MB、警告 2 次、最后停在
/// 详情页」，仍然回答不了：内存是缓慢泄漏还是某个页面一次性拉爆？警告发生在爬升前
/// 还是峰值时？
///
/// 加时间戳之后，这些问题变成读一条序列就能回答的事。
///
/// `offsetMs` 用相对会话开始的偏移而不是绝对时间：设备重启、NTP 校时、用户改时间
/// 都不会让序列错序，也不需要跨时区解释。
struct TDTimelineEntry: Codable {

    enum Kind: String, Codable {
        /// 周期内存采样（5s 一次，只进时间线，不单独发网络事件）
        case memory
        /// 系统内存警告。OOM 最强的先兆信号，必须单独记。
        case memoryWarning = "memory_warning"
        /// 页面切换
        case screen
        case foreground
        case background
        /// 主线程卡顿（可能是 watchdog 的前兆）
        case hang
    }

    /// 相对本次会话开始的毫秒偏移。
    let offsetMs: Double
    let kind: Kind
    /// 数值：内存为 MB，卡顿为 ms。
    var value: Double?
    /// 文本标签：页面名、前后台切换原因等。
    var label: String?

    var asJSON: [String: Any] {
        var dict: [String: Any] = [
            "t": Int(offsetMs.rounded()),
            "k": kind.rawValue,
        ]
        if let value = value { dict["v"] = (value * 10).rounded() / 10 }
        if let label = label { dict["l"] = label }
        return dict
    }
}

/// 上一次进程的完整现场。
///
/// 与旧实现的差别：
/// - 落**文件**且原子写，不用 `UserDefaults`。`UserDefaults` 在 SIGKILL 之前不保证
///   已同步到磁盘，用它存"本次是否干净退出"会在被系统杀掉时读到陈旧值，直接
///   导致归因反过来。
/// - 存**footprint 序列**而不是单点。SIGKILL 类退出没有崩溃栈，唯一可用的证据就是
///   死亡前那段时间的内存爬升曲线；只有最后一个采样点，等于没有证据。
/// - 存环境标记（调试器 / 模拟器 / OS 版本 / app 版本），让下次启动能判断这次
///   退出差额到底该不该算数。
struct TDAppState: Codable {

    var sessionId: String
    var startedAt: Date
    var lastAliveAt: Date
    var lastScreen: String?

    var foreground: Bool
    var backgroundEnteredAt: Date?
    /// 未结束的后台任务数量（`beginBackgroundTask` 与 `endBackgroundTask` 的差）。
    /// 用计数而不是布尔：业务可能并发申请多个后台任务，布尔会把"还剩一个"算成没有。
    var backgroundTaskCount: Int

    /// 走了 `applicationWillTerminate`。用户上划强杀会走这里，系统杀不会。
    var cleanExit: Bool
    var exitInitiator: String?

    var hadMemoryWarning: Bool
    var memoryWarningCount: Int
    var peakFootprintMb: Double
    /// 环形缓冲，最近 `maxSeriesPoints` 个内存采样，用于前推死亡前的爬升。
    /// 纯数值、无时间戳，服务端画曲线用。因果链看 `timeline`。
    var footprintSeries: [Double]

    /// 现场时间线：内存 / 内存警告 / 页面 / 前后台 / 卡顿，统一时间轴。
    ///
    /// 用 Optional 而不是空数组，只为一件事：2.0 之前写下的 `app_state.json`
    /// 里没有这个键，非可选属性会让整份 state 解码失败——那等于升级当天
    /// 全部终止归因失效。
    var timeline: [TDTimelineEntry]?

    var lastFootprintMb: Double?
    var limitMb: Double?
    var availableMb: Double?

    /// 本会话观测到的最大主线程卡顿时长。看门狗杀进程前主线程一定长时间不响应，
    /// 这是区分「看门狗」与「内存」最直接的本地证据。
    var maxHangMs: Double

    var osVersion: String
    var appVersion: String
    var buildNumber: String
    var debuggerAttached: Bool
    var simulator: Bool

    static let maxSeriesPoints = 60

    /// 时间线容量。内存 5s 一条 → 覆盖约 10 分钟；混入页面切换后约 5~8 分钟。
    /// OOM 几乎都发生在「持续使用中的最后几分钟」，再长的历史价值递减。
    static let maxTimelinePoints = 120

    /// 时间线读法。老版本落盘的 state 没有这个键。
    var timelineEntries: [TDTimelineEntry] { timeline ?? [] }

    // MARK: - 持久化

    private static var directory: URL {
        let base = (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("TDMonitor", isDirectory: true)
    }

    private static var fileURL: URL { directory.appendingPathComponent("app_state.json") }

    /// 高频写。每 5s 一次，只写内存相关字段，避免把整份 state 反复序列化。
    func write() {
        var payload = self
        payload.lastAliveAt = Date()
        do {
            try FileManager.default.createDirectory(at: TDAppState.directory,
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(payload)
            // 原子写：先写临时文件再 rename，避免被杀时留下半截 JSON。
            try data.write(to: TDAppState.fileURL, options: .atomic)
        } catch {
            TDMonitorLog.record("appState 落盘失败：\(error.localizedDescription)", level: "warning")
        }
    }

    static func read() -> TDAppState? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(TDAppState.self, from: data)
    }

    static func clear() { try? FileManager.default.removeItem(at: fileURL) }
}

/// 终止原因归因。
///
/// 这是一个**双源 + 交叉验证**的设计，而不是"选一个更准的用"：
///
/// | 来源 | 覆盖 | 时效 | 局限 |
/// | --- | --- | --- | --- |
/// | 启发式（本类） | 全版本、全用户 | 下次启动即知 | 只能给证据，不能给权威判定 |
/// | MetricKit | iOS 14+，且用户未关闭「共享 iPhone 分析」 | 次日批量 | 覆盖率不是 100%，无实时性 |
///
/// 只信 MetricKit：iOS 13 完全没有，国内关闭分析比例高时大面积缺失。
/// 只信启发式：把用户强杀、后台任务超时、系统升级都算成 OOM，比率虚高不可用。
///
/// 所以两条都跑，各自带 `attribution` 标记上报，后端按来源分组统计。同一个退出
/// 可能被两条路径各报一次，这是**刻意**的——用两条路径的计数差就能反推 MetricKit
/// 覆盖率。文档里必须写明不要直接相加。
enum TDTerminationAttribution: String {
    /// 本地证据充分：内存逼近上限，或主线程卡死超过系统看门狗阈值。
    case jetsam = "jetsam"
    case watchdog = "watchdog"
    /// 后台任务到期未结束被回收。
    case backgroundTaskTimeout = "background_task_timeout"
    /// 有内存警告但没有其他证据，倾向内存压力。
    case memoryPressure = "memory_pressure"
    /// 无法区分用户强杀 / 系统回收 / 其他。**不冒充**为 OOM 或 watchdog。
    case unknown = "unknown_unclean"
}

struct TDTerminationVerdict {
    let attribution: TDTerminationAttribution
    /// 0~1，用于后端过滤：低于阈值的样本不进 OOM 率分母。
    let confidence: Double
    let reasons: [String]
    let state: TDAppState
}

/// 归因判定依赖的环境事实。
///
/// 抽成值类型而不是直接读 `TDEnvironment` 静态属性，原因很具体：
/// 模拟器上 `TDEnvironment.isSimulator` 恒为 true，而分类器第一条规则就是
/// 「模拟器不判」——直接读静态属性意味着**这套判定链在模拟器上永远不会执行**，
/// 一条单测都写不出来。注入之后，「模拟器 → 直接返回 nil」本身也成了可断言的行为。
struct TDEnvironmentSnapshot {
    let debuggerAttached: Bool
    let simulator: Bool

    static var current: TDEnvironmentSnapshot {
        TDEnvironmentSnapshot(debuggerAttached: TDEnvironment.isDebuggerAttached,
                              simulator: TDEnvironment.isSimulator)
    }
}

enum TDTerminationClassifier {

    /// 系统看门狗在前台杀掉主线程长时间无响应的进程，超时阈值量级是 10s
    /// （启动阶段更长）。这里用 8s 作为保守下界，宁可判不出也不误判。
    static let watchdogHangThresholdMs: Double = 8_000

    /// 距内存上限多近才认定是 jetsam。
    ///
    /// **这是自有经验值，不是业界口径。** 核对过 Sentry 与 Datadog：两家都**不做**
    /// footprint/limit 比值判断，只判断「没干净退出 + 不在排除清单」，然后统一归为
    /// `WatchdogTermination`，措辞是 "possibly because it overused RAM"——
    /// 用 `possibly` 就是在承认自己没有证据。Matrix 走的是分配栈，也不用这个比值。
    ///
    /// 选 0.85 的理由：进程通常在真正逼近 limit 之前就被回收，把阈值卡到 1.0
    /// 会把边界情况判成「不是 OOM」。所以它只是**推断依据**，不是结论；
    /// 后端展示时必须带上 confidence，不能当事实呈现。
    static let jetsamFootprintRatio: Double = 0.85

    /// 归因主入口。返回 nil 表示这次退出不需要上报。
    static func classify(previous: TDAppState,
                         currentOSVersion: String,
                         currentAppVersion: String,
                         currentBuild: String,
                         hasLaunchedBefore: Bool,
                         environment: TDEnvironmentSnapshot = .current) -> TDTerminationVerdict? {

        // 走了 willTerminate：用户上划强杀、或系统正常请求退出。
        // 这类不算 OOM，也不算看门狗——Sentry 同样明确排除强杀。
        if previous.cleanExit { return nil }

        // 调试器附着时进程被 ptrace 影响，退出时序不可信；开发期每次热重启都会
        // 产生一次"未正常退出"。不排除的话线上大盘会被开发机数据污染。
        if previous.debuggerAttached || environment.debuggerAttached { return nil }
        if previous.simulator || environment.simulator { return nil }

        // 首次启动没有可比基线。
        guard hasLaunchedBefore else { return nil }

        // OS 或 app 升级会重建所有进程，上一次的状态不再代表同版本行为。
        // 不排除的话每次发版当天都会出现一波假的 OOM 尖峰。
        if previous.osVersion != currentOSVersion { return nil }
        if previous.appVersion != currentAppVersion || previous.buildNumber != currentBuild { return nil }

        var reasons: [String] = []
        reasons.append("foreground=\(previous.foreground)")
        reasons.append("peakFootprint=\(String(format: "%.1f", previous.peakFootprintMb))MB")
        reasons.append("maxHang=\(String(format: "%.0f", previous.maxHangMs))ms")
        if previous.hadMemoryWarning {
            reasons.append("memoryWarnings=\(previous.memoryWarningCount)")
        }

        // 1) 主线程卡死超过看门狗阈值 + 前台：看门狗杀
        if previous.maxHangMs >= watchdogHangThresholdMs && previous.foreground {
            return TDTerminationVerdict(attribution: .watchdog, confidence: 0.8,
                                        reasons: reasons, state: previous)
        }

        // 2) 内存逼近上限：jetsam
        if let footprint = previous.lastFootprintMb, let limit = previous.limitMb, limit > 0 {
            let ratio = footprint / limit
            reasons.append("footprintRatio=\(String(format: "%.2f", ratio))")
            if ratio >= jetsamFootprintRatio {
                return TDTerminationVerdict(attribution: .jetsam, confidence: min(0.95, ratio),
                                            reasons: reasons, state: previous)
            }
        }

        // 3) 没有 limit（部分设备拿不到）时退化为「可用内存极低」
        if let available = previous.availableMb, available < 50 {
            reasons.append("availableMb=\(String(format: "%.1f", available))")
            return TDTerminationVerdict(attribution: .jetsam, confidence: 0.7,
                                        reasons: reasons, state: previous)
        }

        // 4) 后台 + 后台任务未结束：后台任务超时回收
        if !previous.foreground && previous.backgroundTaskCount > 0 {
            return TDTerminationVerdict(attribution: .backgroundTaskTimeout, confidence: 0.6,
                                        reasons: reasons, state: previous)
        }

        // 5) 有内存警告但没到上限：内存压力，比 unknown 更有信息量
        if previous.hadMemoryWarning {
            return TDTerminationVerdict(attribution: .memoryPressure, confidence: 0.5,
                                        reasons: reasons, state: previous)
        }

        // 6) 证据不足。这里**必须**报 unknown 而不是猜成 watchdog：
        //    把强杀算成 OOM 会让整个 OOM 率失去意义，宁可数据少也不要数据假。
        return TDTerminationVerdict(attribution: .unknown, confidence: 0.2,
                                    reasons: reasons, state: previous)
    }
}

/// 维护并落盘当前会话的现场。
///
/// 写盘频率是设计的一部分：内存每 5s 一次（OOM 前兆需要分辨率），其余字段
/// 只在前台/后台切换、页面切换、内存警告这些**语义变化**时写。这样既能拿到
/// 死亡前的爬升曲线，又不会因为高频 IO 自己成为性能问题。
public final class TDAppStateTracker {

    public static let shared = TDAppStateTracker()

    private let queue = TDMonitorQueues.appState
    private var state: TDAppState?
    /// `beginSession()` 读到的上一会话现场。文件随即被新会话覆盖，
    /// 崩溃补发只能靠这份内存快照把事件挂回崩溃那次会话。
    private var previousState: TDAppState?
    private var started = false

    private init() {}

    /// 当前是否前台。卡顿分级依赖它：后台被系统回收是正常行为，
    /// 不该算作「可能被 watchdog 杀掉」。
    public var isForeground: Bool {
        queue.sync { state?.foreground ?? true }
    }

    // MARK: - 会话开始

    /// 读旧 state → 交给分类器 → 建新 state。
    /// 返回的 verdict 由调用方决定怎么上报（这里不做网络）。
    func beginSession(sessionId: String,
                      appVersion: String,
                      buildNumber: String) -> TDTerminationVerdict? {
        let previous = TDAppState.read()
        // 文件马上会被新会话覆盖，先把上一会话现场留在内存里。
        queue.sync { self.previousState = previous }
        let defaults = UserDefaults(suiteName: "com.truedepth.monitor") ?? .standard
        let hasLaunchedBefore = defaults.bool(forKey: "td_has_launched")
        defaults.set(true, forKey: "td_has_launched")

        var verdict: TDTerminationVerdict?
        if let previous = previous {
            verdict = TDTerminationClassifier.classify(
                previous: previous,
                currentOSVersion: TDEnvironment.osVersion,
                currentAppVersion: appVersion,
                currentBuild: buildNumber,
                hasLaunchedBefore: hasLaunchedBefore)
        }

        let fresh = TDAppState(
            sessionId: sessionId,
            startedAt: Date(),
            lastAliveAt: Date(),
            lastScreen: TDScreenContext.shared.current,
            foreground: true,
            backgroundEnteredAt: nil,
            backgroundTaskCount: 0,
            cleanExit: false,
            exitInitiator: nil,
            hadMemoryWarning: false,
            memoryWarningCount: 0,
            peakFootprintMb: 0,
            footprintSeries: [],
            timeline: [],
            lastFootprintMb: nil,
            limitMb: nil,
            availableMb: nil,
            maxHangMs: 0,
            osVersion: TDEnvironment.osVersion,
            appVersion: appVersion,
            buildNumber: buildNumber,
            debuggerAttached: TDEnvironment.isDebuggerAttached,
            simulator: TDEnvironment.isSimulator
        )

        queue.sync {
            self.state = fresh
            self.started = true
        }
        // 基线不必阻塞启动路径：异步写即可，首帧之前一定能完成。
        queue.async { fresh.write() }
        return verdict
    }

    /// 崩溃补发用：把 `native_crash` 挂回崩溃那次会话。
    ///
    /// 宿主崩溃报告的 context 不带 sessionId，但 `app_state.json` 记录了上一会话的
    /// `sessionId` / `startedAt` / `lastAliveAt`。只有崩溃时刻落在存活区间内才认领：
    /// 旧报告若被无条件挂到「最近一次会话」，等于把一种错误归因换成另一种。
    /// 容差覆盖 5s 周期的现场落盘间隔，以及崩溃前最后一次写入与崩溃时刻的差值。
    func originSessionId(for crashTime: Date) -> String? {
        queue.sync {
            guard let session = previousState else { return nil }
            let tolerance: TimeInterval = 10
            guard crashTime >= session.startedAt.addingTimeInterval(-tolerance),
                  crashTime <= session.lastAliveAt.addingTimeInterval(tolerance) else { return nil }
            return session.sessionId
        }
    }

    // MARK: - 现场更新

    public func setForeground(_ foreground: Bool) {
        mutate { state in
            state.foreground = foreground
            state.backgroundEnteredAt = foreground ? nil : Date()
            // 前后台序列是 OOM 的关键判据：后台被回收属正常，前台被杀才是问题。
            // 只有当前值的布尔量无法区分「一直在前台」和「刚从前台切走」。
            Self.appendTimeline(&state,
                                kind: foreground ? .foreground : .background,
                                value: nil, label: nil)
        }
    }

    /// 后台任务数量变化。`beginBackgroundTask` 与 `endBackgroundTask` 由 swizzle
    /// 捕获（见 `TDAppStateTracker.installBackgroundTaskHook`）。
    func setBackgroundTaskCount(_ count: Int) {
        mutate { state in state.backgroundTaskCount = max(0, count) }
    }

    /// 挂钩 `beginBackgroundTask` / `endBackgroundTask`。
    ///
    /// 不挂这个钩，`background_task_timeout` 这条归因分支就是死代码：字段永远是 0，
    /// 判定永远不命中。而后台任务到期被系统回收是很常见的一类"静默退出"，
    /// 用户看到的是"App 回来就重启了"，没有任何崩溃报告。
    func installBackgroundTaskHook() {
        #if canImport(UIKit)
        let cls = UIApplication.self
        swizzle(cls, original: NSSelectorFromString("beginBackgroundTaskWithExpirationHandler:"),
                replacement: #selector(UIApplication.td_beginBackgroundTask(expirationHandler:)))
        swizzle(cls, original: NSSelectorFromString("beginBackgroundTaskWithName:expirationHandler:"),
                replacement: #selector(UIApplication.td_beginBackgroundTask(withName:expirationHandler:)))
        swizzle(cls, original: NSSelectorFromString("endBackgroundTask:"),
                replacement: #selector(UIApplication.td_endBackgroundTask(_:)))
        #endif
    }

    private func swizzle(_ cls: AnyClass, original: Selector, replacement: Selector) {
        guard let originalMethod = class_getInstanceMethod(cls, original),
              let replacementMethod = class_getInstanceMethod(cls, replacement) else { return }
        method_exchangeImplementations(originalMethod, replacementMethod)
    }

    /// 当前未结束的后台任务数，由 UIApplication 的 swizzle 维护。
    private var liveBackgroundTasks = 0

    func didBeginBackgroundTask() {
        liveBackgroundTasks += 1
        setBackgroundTaskCount(liveBackgroundTasks)
    }

    func didEndBackgroundTask() {
        liveBackgroundTasks = max(0, liveBackgroundTasks - 1)
        setBackgroundTaskCount(liveBackgroundTasks)
    }

    func setScreen(_ screen: String?) {
        guard let screen = screen else { return }
        mutate { state in
            state.lastScreen = screen
            // 页面切换进时间线：OOM 最需要回答的是「在哪个页面爬上去的」。
            // 只留最后一个页面，等于只知道终点、不知道路径。
            Self.appendTimeline(&state, kind: .screen, value: nil, label: screen)
        }
    }

    public func recordMemoryWarning() {
        mutate { state in
            state.hadMemoryWarning = true
            state.memoryWarningCount += 1
            // 带上当前 footprint：判断「警告时已经多高」比「警告过几次」有用得多。
            Self.appendTimeline(&state, kind: .memoryWarning,
                                value: state.lastFootprintMb, label: nil)
        }
    }

    func recordHang(durationMs: Double) {
        mutate { state in
            state.maxHangMs = max(state.maxHangMs, durationMs)
            Self.appendTimeline(&state, kind: .hang, value: durationMs, label: nil)
        }
    }

    /// 内存采样：追加序列 + 更新峰值。每次调用都落盘（本身已是 5s 级）。
    public func recordMemory(footprintMb: Double, limitMb: Double?, availableMb: Double?) {
        queue.sync {
            guard var state = self.state else { return }
            state.lastFootprintMb = footprintMb
            state.limitMb = limitMb
            state.availableMb = availableMb
            state.peakFootprintMb = max(state.peakFootprintMb, footprintMb)
            state.footprintSeries.append(footprintMb)
            if state.footprintSeries.count > TDAppState.maxSeriesPoints {
                state.footprintSeries.removeFirst(state.footprintSeries.count - TDAppState.maxSeriesPoints)
            }
            Self.appendTimeline(&state, kind: .memory, value: footprintMb, label: nil)
            state.lastAliveAt = Date()
            self.state = state
            state.write()
        }
    }

    /// 追加一条时间线记录并按容量淘汰最旧的。
    ///
    /// 调用方必须已经持有 `state` 的可变副本并在同一个串行队列上——这里不加锁，
    /// 因为加锁会掩盖「时间线顺序」这个唯一的正确性前提。
    static func appendTimeline(_ state: inout TDAppState,
                               kind: TDTimelineEntry.Kind,
                               value: Double?,
                               label: String?) {
        let offset = Date().timeIntervalSince(state.startedAt) * 1000
        var entries = state.timeline ?? []
        entries.append(TDTimelineEntry(offsetMs: max(0, offset), kind: kind, value: value, label: label))
        if entries.count > TDAppState.maxTimelinePoints {
            entries.removeFirst(entries.count - TDAppState.maxTimelinePoints)
        }
        state.timeline = entries
    }

    // MARK: - 会话结束

    /// `applicationWillTerminate` 到达。iOS 上只有「进程仍在运行、系统主动请求退出」
    /// 时才会回调——用户上划强杀走这里，被 jetsam / 看门狗 SIGKILL 不走这里。
    /// 这正是区分强杀与系统杀的依据。
    ///
    /// 先到者为准：willTerminate 先触发时不能被后续 `stop()` 覆盖成 sdk_stop，
    /// 否则归因里就看不出"是用户杀的"还是"我们自己关的"。
    ///
    /// 这里是**同步**写：`willTerminate` 返回后进程随时会被回收（系统只给很短的
    /// 收尾窗口），投递到异步队列大概率来不及落盘，等于这次退出没有被标记，
    /// 下次启动就会被误判成系统杀。
    func markCleanExit(initiator: String) {
        queue.sync {
            guard var state = self.state, !state.cleanExit else { return }
            state.cleanExit = true
            state.exitInitiator = initiator
            state.lastAliveAt = Date()
            self.state = state
            state.write()
        }
    }

    /// 显式 `stop()`。与 willTerminate 不同语义，这里是我们自己关掉监控。
    func markStopped() { markCleanExit(initiator: "sdk_stop") }

    func current() -> TDAppState? {
        queue.sync { state }
    }

    // MARK: - 内部

    /// 异步落盘。
    ///
    /// `mutate` 会被切页面（viewDidAppear）、切前后台这类主线程事件调用，
    /// 同步写文件等于在 UI 关键路径上做 IO。改成投递到串行队列：
    /// 顺序仍有保证（串行），而 `current()` 用 `sync` 会等到所有挂起的写完成，
    /// 不会读到旧值。
    private func mutate(_ body: @escaping (inout TDAppState) -> Void) {
        queue.async { [weak self] in
            guard let self = self, var state = self.state else { return }
            body(&state)
            state.lastAliveAt = Date()
            self.state = state
            state.write()
        }
    }
}

#if canImport(UIKit)
// MARK: - 后台任务计数

extension UIApplication {

    @objc func td_beginBackgroundTask(expirationHandler handler: (() -> Void)?) -> UIBackgroundTaskIdentifier {
        let identifier = td_beginBackgroundTask(expirationHandler: handler)
        if identifier != .invalid { TDAppStateTracker.shared.didBeginBackgroundTask() }
        return identifier
    }

    @objc func td_beginBackgroundTask(withName name: String?,
                                     expirationHandler handler: (() -> Void)?) -> UIBackgroundTaskIdentifier {
        let identifier = td_beginBackgroundTask(withName: name, expirationHandler: handler)
        if identifier != .invalid { TDAppStateTracker.shared.didBeginBackgroundTask() }
        return identifier
    }

    @objc func td_endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {
        td_endBackgroundTask(identifier)
        // 同一个 id 可能被调用多次（业务常见写法），计数用 max(0,) 兜底。
        if identifier != .invalid { TDAppStateTracker.shared.didEndBackgroundTask() }
    }
}
#endif
