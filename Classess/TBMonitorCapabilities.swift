import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// SDK 运行环境探测。
///
/// 这些判断不是为了"锦上添花"，而是决定数据能否被采信：
/// - 连着调试器时进程会被 ptrace 挂住，`applicationWillTerminate` 的时序、
///   后台挂起行为、看门狗触发条件全都与线上不同，拿这类数据算 OOM 率会污染大盘
/// - 模拟器没有真实的 jetsam / 看门狗，退出原因一定是假的
/// 业界（Sentry）在 watchdog 归因里明确排除这两类环境，否则开发期每次重启
/// 都会产出一条「未正常退出」。
enum TDEnvironment {

    /// `sysctl(KERN_PROC)` 的 `kp_proc.p_flag` 里是否带 `P_TRACED`。
    /// 这是判断调试器附着的唯一可靠方式：`isDebuggerAttached` 之类的名字在
    /// Foundation 里并不存在，很多人误以为有。
    static var isDebuggerAttached: Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard result == 0 else { return false }
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }

    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    /// 主版本号用于按 OS 大版本分组统计——跨版本直接比 FPS / 内存没有意义。
    static var osMajorVersion: Int {
        Int(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }

    static var osVersion: String { ProcessInfo.processInfo.operatingSystemVersionString }

    /// 关闭「共享 iPhone 分析」的用户不会产出 MetricKit 数据，覆盖率因此永远
    /// 不是 100%。无法读取该开关，但可以把 `MXMetricManager` 是否真的投递过
    /// payload 作为观测值上报，用真实样本反推覆盖率。
    static var availableMemoryMb: Double? {
        let available = os_proc_available_memory()
        return available > 0 ? Double(available) / 1024 / 1024 : nil
    }
}

/// 能力可用性矩阵。
///
/// 动机：SDK 声称支持 iOS 13，但 `MXAppExitMetric` 是 iOS 14 才有的。如果不把
/// 「这台设备实际启用了哪些采集器、哪些因系统版本降级」变成可上报的数据，那么
/// 看板上"iOS 13 用户没有 OOM 数据"这件事就永远只能靠人记文档——而人是会忘的。
///
/// 每次启动把矩阵挂在 `session_start.attributes` 上，后端就能直接回答：
/// 「iOS 13 占比多少」「有多少用户拿不到分阶段网络耗时」「MetricKit 真实覆盖率」。
public struct TDCapabilityMatrix {

    public struct Item {
        public let name: String
        public let available: Bool
        /// 不可用/降级的原因，直接面向排查而不是面向文档。
        public let detail: String
        /// 当前实际走的是哪条路径，用于确认降级是否按预期生效。
        public let path: String
    }

    public let items: [Item]

    public static func probe(networkInstrumentation: Bool, viewLoad: Bool) -> TDCapabilityMatrix {
        var items: [Item] = []

        // ---- 稳定性 ----
        let metricKitAvailable: Bool
        if #available(iOS 14.0, *) {
            metricKitAvailable = true
        } else {
            metricKitAvailable = false
        }
        items.append(Item(
            name: "oom_metrickit",
            available: metricKitAvailable,
            detail: metricKitAvailable ? "MXAppExitMetric 可用" : "MXAppExitMetric 需 iOS 14+",
            path: metricKitAvailable ? "metrickit" : "unavailable"
        ))
        items.append(Item(
            name: "oom_heuristic",
            available: true,
            detail: "全版本常驻，与 MetricKit 交叉验证",
            path: "app_state_file"
        ))
        items.append(Item(
            name: "anr_stack_sampling",
            available: true,
            detail: "thread_suspend + 帧指针回溯，无版本门槛",
            path: "semaphore_ping"
        ))
        items.append(Item(
            name: "nonfatal_exception",
            available: true,
            detail: "交换 -[NSException raise]，不接管崩溃处理器",
            path: "raise_swizzle"
        ))

        // ---- 性能 ----
        items.append(Item(
            name: "screen_frame_stats",
            available: true,
            detail: "按 UIViewController appear→disappear 统计慢帧/冻结帧",
            path: "displaylink_per_screen"
        ))
        let highRefresh: Bool
        if #available(iOS 15.0, *) {
            highRefresh = true
        } else {
            highRefresh = false
        }
        items.append(Item(
            name: "high_refresh_rate",
            available: highRefresh,
            detail: highRefresh ? "可读 CAFrameRateRange" : "iOS 15 以下按 60Hz 估算",
            path: highRefresh ? "preferred_frame_rate_range" : "assume_60hz"
        ))
        items.append(Item(
            name: "long_task_runloop",
            available: true,
            detail: "RunLoop observer 测主线程连续占用",
            path: "cfrunloop_observer"
        ))

        // ---- 网络 ----
        // iOS 18 起 URLSession 的初始化器不再是 ObjC 方法，swizzle 那条路必然失败，
        // 只能走显式 session 或完成回调拦截。
        let legacySessionHook: Bool
        if #available(iOS 18.0, *) {
            legacySessionHook = false
        } else {
            legacySessionHook = true
        }
        items.append(Item(
            name: "network_phases",
            available: networkInstrumentation,
            detail: networkInstrumentation
                ? "需显式 makeInstrumentedSession 才有 DNS/TCP/TLS/TTFB 分阶段"
                : "已关闭",
            path: networkInstrumentation ? "urlsession_task_metrics" : "disabled"
        ))
        items.append(Item(
            name: "network_legacy_session_hook",
            available: networkInstrumentation && legacySessionHook,
            detail: legacySessionHook
                ? "可接管业务已有 session（无需改造调用方）"
                : "iOS 18+ URLSession 初始化器非 ObjC 方法，无法接管，仅剩完成回调拦截",
            path: legacySessionHook ? "swizzle_init" : "completion_hook_only"
        ))

        // ---- 资源 ----
        items.append(Item(
            name: "file_descriptor_count",
            available: true,
            detail: "/dev/fd 在沙箱不可枚举，改 fcntl 逐号探测",
            path: "fcntl_probe"
        ))
        items.append(Item(
            name: "thermal_state",
            available: true,
            detail: "ProcessInfo.thermalState",
            path: "process_info"
        ))

        // ---- 环境可信度 ----
        // 调试器 / 模拟器下退出归因不可信，单独作为能力项暴露，后端可直接过滤。
        let trusted = !TDEnvironment.isDebuggerAttached && !TDEnvironment.isSimulator
        items.append(Item(
            name: "termination_attribution_trusted",
            available: trusted,
            detail: trusted ? "线上环境" : "调试器或模拟器，退出归因不计入统计",
            path: trusted ? "production" : "debug_environment"
        ))

        return TDCapabilityMatrix(items: items)
    }

    /// 压成扁平结构塞进 attributes：后端按 `cap.<name>` 直接 group by。
    var attributes: [String: Any] {
        var result: [String: Any] = [:]
        var unavailable: [String] = []
        for item in items {
            result["cap.\(item.name)"] = item.available ? 1 : 0
            result["path.\(item.name)"] = item.path
            if !item.available { unavailable.append(item.name) }
        }
        result["cap.unavailable"] = unavailable.isEmpty ? "-" : unavailable.joined(separator: ",")
        result["cap.total"] = items.count
        result["cap.available"] = items.count - unavailable.count
        return result
    }

    /// 人读摘要，进诊断日志。
    public var summary: String {
        items.map { "\($0.name)=\($0.available ? "on" : "off")(\($0.path))" }
            .joined(separator: " ")
    }
}

/// MetricKit 的真实投递计数。
///
/// `cap.oom_metrickit=1` 只说明「这台系统有这个 API」，不等于「这个用户会给我们数据」——
/// 用户可以在「设置 → 隐私 → 分析与改进」里关掉共享分析，关掉之后
/// `MXMetricManager` 永远收不到 payload，且没有任何 API 能读到这个开关。
///
/// 于是把「历史上收到过几次 payload」累计下来随 `session_start` 上报：
/// 计数为 0 的设备就是实际无覆盖的设备。用真实样本反推覆盖率，
/// 比在文档里写一句"覆盖率不是 100%"有用得多。
public enum TDMetricKitCoverage {

    private static let key = "td_metrickit_payloads"

    public static func recordDelivery() {
        let defaults = UserDefaults(suiteName: "com.truedepth.monitor") ?? .standard
        defaults.set(defaults.integer(forKey: key) + 1, forKey: key)
    }

    public static var deliveryCount: Int {
        let defaults = UserDefaults(suiteName: "com.truedepth.monitor") ?? .standard
        return defaults.integer(forKey: key)
    }
}
