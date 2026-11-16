import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Darwin)
import Darwin
#endif

/// 进程资源采样。全部走内核接口，不做任何估算：
/// - 内存：`mach_task_basic_info.resident_size` + `phys_footprint`（更接近 Xcode/Instruments 的口径）
/// - CPU：`task_basic_info` 的 user + system 时间差 / 墙钟
/// - 磁盘：`attributesOfFileSystem`
/// - 线程：`task_threads` 计数
/// - FD：`/dev/fd` 目录项计数
public enum TDResourceSampler {

    public struct Memory {
        public let footprintMb: Double
        public let availableMb: Double?
        public let limitMb: Double?
    }

    public static func memory() -> Memory? {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let footprint = Double(info.phys_footprint) / 1_048_576.0

        var available: Double?
        if #available(iOS 13.0, *) {
            let bytes = os_proc_available_memory()
            if bytes > 0 { available = Double(bytes) / 1_048_576.0 }
        }
        let limit = available.map { $0 + footprint }
        return Memory(footprintMb: footprint, availableMb: available, limitMb: limit)
        #else
        return nil
        #endif
    }

    private static let cpuLock = NSLock()
    private static var lastCPU: (seconds: Double, wall: TimeInterval)?

    public static func cpuPercent() -> Double? {
        #if canImport(Darwin)
        var info = task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_BASIC_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let seconds = Double(info.user_time.seconds + info.system_time.seconds)
            + Double(info.user_time.microseconds + info.system_time.microseconds) / 1_000_000
        #else
        let seconds = 0.0
        #endif
        let wall = ProcessInfo.processInfo.systemUptime

        cpuLock.lock()
        defer { cpuLock.unlock() }
        let previous = lastCPU
        lastCPU = (seconds, wall)
        guard let last = previous else { return nil }
        let elapsed = wall - last.wall
        guard elapsed > 0 else { return nil }
        // 进程 CPU 可以超过 100%（多核），上限按核心数收口，避免异常值污染 P95。
        let ceiling = Double(ProcessInfo.processInfo.activeProcessorCount) * 100
        return max(0, min(ceiling, ((seconds - last.seconds) / elapsed) * 100))
    }

    public static func disk() -> (freeMb: Double, totalMb: Double)? {
        let path = NSHomeDirectory()
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let free = attributes[.systemFreeSize] as? NSNumber,
              let total = attributes[.systemSize] as? NSNumber else { return nil }
        return (Double(free.int64Value) / 1_048_576.0, Double(total.int64Value) / 1_048_576.0)
    }

    public static func threadCount() -> Int? {
        #if canImport(Darwin)
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads = threads else { return nil }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: threads)),
                          vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }
        return Int(count)
        #else
        return nil
        #endif
    }

    public static func fileDescriptorCount() -> Int? {
        #if canImport(Darwin)
        // 两条常见做法在 iOS 上都不成立：`/dev/fd` 在沙箱里不可枚举（contentsOfDirectory
        // 直接返回 nil），`proc_pidinfo` 没有导出到 Swift 模块。改成逐个问内核
        // 「这个 fd 号还在不在」——F_GETFD 返回 -1 即已关闭，纯 POSIX，无私有符号。
        let limit = min(getdtablesize(), 4096)
        guard limit > 0 else { return nil }
        var count = 0
        for fd in 0..<limit where fcntl(Int32(fd), F_GETFD) != -1 { count += 1 }
        return count
        #else
        return nil
        #endif
    }
}

/// 说明：原先这里有一个只存单点快照的 `TDTerminationSnapshot`（覆盖写
/// `last_session.json`）。它有两个致命缺陷，已被 `TDAppState` 取代：
/// 1. 用 `UserDefaults` 存「本次是否干净退出」，SIGKILL 前不保证落盘；
/// 2. 只留最后一个内存采样点，SIGKILL 类退出没有崩溃栈，唯一证据就是死亡前
///    的内存爬升曲线，单点等于没有证据。
/// 现由 `TDAppStateTracker`（`TBMonitorTermination.swift`）维护完整现场。

/// 定时资源采集 + 内存序列落盘。
final class TDResourceMonitor {

    private let config: TDMonitorConfiguration
    private weak var sink: TDEventSink?
    /// 终止归因的现场记录器。注入而不是直接摸 `.shared`，
    /// 否则这一层永远无法在测试里替换掉真实落盘。
    private let appState: TDAppStateTracker
    private let queue = TDMonitorQueues.resource
    private var timer: DispatchSourceTimer?
    /// 内存单独高频采样。OOM 前兆的爬升曲线需要 5s 级分辨率，
    /// 而 CPU / 磁盘 / 电池这类指标 30s 一次足够——混在一个 timer 里
    /// 要么内存太稀、要么其他指标白烧电。
    private var memoryTimer: DispatchSourceTimer?
    private var peakMb: Double = 0
    private var lastReportedPeak: Double = 0
    private var isForeground = true

    var onMemoryWarning: (() -> Void)?

    init(config: TDMonitorConfiguration, sink: TDEventSink, appState: TDAppStateTracker = .shared) {
        self.config = config
        self.sink = sink
        self.appState = appState
    }

    func start() {
        #if canImport(UIKit)
        UIDevice.current.isBatteryMonitoringEnabled = true
        NotificationCenter.default.addObserver(self, selector: #selector(didReceiveMemoryWarning),
                                               name: UIApplication.didReceiveMemoryWarningNotification,
                                               object: nil)
        #endif
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: config.metricsInterval)
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
        self.timer = timer

        // 内存单独 5s 一次：只服务于终止归因的爬升曲线，不产生上报事件
        // （上报仍走 30s 的 sample，避免把事件量放大 6 倍）。
        let memoryTimer = DispatchSource.makeTimerSource(queue: queue)
        memoryTimer.schedule(deadline: .now() + 1, repeating: 5)
        memoryTimer.setEventHandler { [weak self] in self?.traceMemory() }
        memoryTimer.resume()
        self.memoryTimer = memoryTimer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        memoryTimer?.cancel()
        memoryTimer = nil
        NotificationCenter.default.removeObserver(self)
    }

    func setForeground(_ foreground: Bool) {
        isForeground = foreground
        appState.setForeground(foreground)
        traceMemory()
    }

    /// 高频内存追踪：只写本地现场，不发网络事件。
    private func traceMemory() {
        guard let memory = TDResourceSampler.memory() else { return }
        appState.recordMemory(footprintMb: memory.footprintMb,
                              limitMb: memory.limitMb,
                              availableMb: memory.availableMb)
    }

    /// 兼容旧调用点：立即刷新一次现场。
    func snapshot() { traceMemory() }

    @objc private func didReceiveMemoryWarning() {
        onMemoryWarning?()
        appState.recordMemoryWarning()
        traceMemory()
        guard let memory = TDResourceSampler.memory() else { return }
        enqueue(name: "memory", value: memory.footprintMb, unit: "MB", severity: "warning",
                attributes: ["memoryWarning": true,
                             "availableMb": memory.availableMb ?? 0,
                             "foreground": isForeground])
    }

    private func sample() {
        guard let memory = TDResourceSampler.memory() else { return }
        peakMb = max(peakMb, memory.footprintMb)
        var memoryAttributes: [String: Any] = ["metric": "phys_footprint", "foreground": isForeground]
        if let available = memory.availableMb { memoryAttributes["availableMb"] = available }
        if let limit = memory.limitMb { memoryAttributes["limitMb"] = limit }
        if peakMb > lastReportedPeak { memoryAttributes["peakMb"] = peakMb }
        if let limit = memory.limitMb, limit > 0, memory.footprintMb / limit > 0.8 {
            memoryAttributes["nearLimit"] = true
        }
        enqueue(name: "memory", value: memory.footprintMb, unit: "MB", attributes: memoryAttributes)
        lastReportedPeak = peakMb

        if let cpu = TDResourceSampler.cpuPercent() {
            enqueue(name: "cpu", value: cpu, unit: "%")
        }
        if let disk = TDResourceSampler.disk() {
            enqueue(name: "disk", value: disk.freeMb, unit: "MB",
                    attributes: ["freeMb": disk.freeMb, "totalMb": disk.totalMb,
                                 "usedMb": disk.totalMb - disk.freeMb])
        }
        if let threads = TDResourceSampler.threadCount() {
            enqueue(name: "thread_count", value: Double(threads), unit: "count")
        }
        if let fds = TDResourceSampler.fileDescriptorCount() {
            enqueue(name: "fd_count", value: Double(fds), unit: "count")
        }
        #if canImport(UIKit)
        let device = UIDevice.current
        if device.batteryLevel >= 0 {
            enqueue(name: "battery", value: Double(device.batteryLevel) * 100, unit: "%",
                    attributes: ["state": batteryState(device.batteryState)])
        }
        #endif
        if #available(iOS 11.0, *) {
            let thermal = ProcessInfo.processInfo.thermalState
            enqueue(name: "thermal", value: Double(thermal.rawValue), unit: "state",
                    attributes: ["state": thermalName(thermal)])
        }
    }

    #if canImport(UIKit)
    private func batteryState(_ state: UIDevice.BatteryState) -> String {
        switch state {
        case .charging: return "charging"
        case .full: return "full"
        case .unplugged: return "unplugged"
        default: return "unknown"
        }
    }
    #endif

    private func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private func enqueue(name: String, value: Double, unit: String?,
                         severity: String? = nil, attributes: [String: Any] = [:]) {
        if config.sampleRate < 1 && Double.random(in: 0..<1) > config.sampleRate { return }
        var fields: [String: Any] = ["name": name, "value": value]
        if let unit = unit { fields["unit"] = unit }
        if let severity = severity { fields["severity"] = severity }
        sink?.enqueue(TDEvent(kind: "mobile_metric", fields: fields, attributes: attributes))
    }
}
