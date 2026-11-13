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
enum TDResourceSampler {

    struct Memory {
        let footprintMb: Double
        let availableMb: Double?
        let limitMb: Double?
    }

    static func memory() -> Memory? {
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

    static func cpuPercent() -> Double? {
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

    static func disk() -> (freeMb: Double, totalMb: Double)? {
        let path = NSHomeDirectory()
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let free = attributes[.systemFreeSize] as? NSNumber,
              let total = attributes[.systemSize] as? NSNumber else { return nil }
        return (Double(free.int64Value) / 1_048_576.0, Double(total.int64Value) / 1_048_576.0)
    }

    static func threadCount() -> Int? {
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

    static func fileDescriptorCount() -> Int? {
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

/// 上次会话终止前的内存快照。
///
/// 真机 OOM 是系统直接杀进程，客户端没有机会上报任何东西。唯一可行的是
/// 在进入后台 / 收到内存警告时落盘一次现场，下次启动若判定为异常退出，
/// 就把这份快照作为归因证据（内存已逼近上限 vs 与内存无关）。
struct TDTerminationSnapshot {
    var footprintMb: Double?
    var availableMb: Double?
    var limitMb: Double?
    var foreground: Bool
    var at: Date?

    private static var fileURL: URL {
        let base = (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("TDMonitor", isDirectory: true)
            .appendingPathComponent("last_session.json")
    }

    func write() {
        var payload: [String: Any] = [
            "foreground": foreground,
            "ts": TDISO8601.string(from: Date()),
        ]
        if let footprintMb = footprintMb { payload["footprintMb"] = footprintMb }
        if let availableMb = availableMb { payload["availableMb"] = availableMb }
        if let limitMb = limitMb { payload["limitMb"] = limitMb }
        let url = TDTerminationSnapshot.fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func read() -> TDTerminationSnapshot? {
        guard let data = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return TDTerminationSnapshot(
            footprintMb: json["footprintMb"] as? Double,
            availableMb: json["availableMb"] as? Double,
            limitMb: json["limitMb"] as? Double,
            foreground: json["foreground"] as? Bool ?? true,
            at: (json["ts"] as? String).flatMap { formatter.date(from: $0) }
        )
    }

    static func clear() { try? FileManager.default.removeItem(at: fileURL) }
}

/// 定时资源采集 + 前台/后台内存快照。
final class TDResourceMonitor {

    private let config: TDMonitorConfiguration
    private weak var transport: TDTransport?
    private let queue = DispatchQueue(label: "com.truedepth.monitor.resource", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var peakMb: Double = 0
    private var lastReportedPeak: Double = 0
    private var isForeground = true

    var onMemoryWarning: (() -> Void)?

    init(config: TDMonitorConfiguration, transport: TDTransport) {
        self.config = config
        self.transport = transport
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
    }

    func stop() {
        timer?.cancel()
        timer = nil
        NotificationCenter.default.removeObserver(self)
    }

    func setForeground(_ foreground: Bool) {
        isForeground = foreground
        snapshot()
    }

    /// 落盘一次现场，供下次启动归因 OOM。
    func snapshot() {
        guard let memory = TDResourceSampler.memory() else { return }
        TDTerminationSnapshot(footprintMb: memory.footprintMb,
                              availableMb: memory.availableMb,
                              limitMb: memory.limitMb,
                              foreground: isForeground).write()
    }

    @objc private func didReceiveMemoryWarning() {
        onMemoryWarning?()
        snapshot()
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
        transport?.enqueue(TDEvent(kind: "mobile_metric", fields: fields, attributes: attributes))
    }
}
