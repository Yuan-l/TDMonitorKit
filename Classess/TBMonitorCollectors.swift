import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Darwin)
import Darwin
#endif

/// Process resource sampling. `resident_size` is a robust footprint approximation;
/// CPU is the delta of `clock()` over wall time (Darwin clock() is microseconds).
enum TDResourceSampler {
    static func memoryFootprintMB() -> Double? {
        #if canImport(Darwin)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.resident_size) / 1_048_576.0
        #else
        return nil
        #endif
    }

    private static let lock = NSLock()
    private static var lastSample: (cpu: Double, wall: TimeInterval)?

    static func cpuUsagePercent() -> Double? {
        #if canImport(Darwin)
        let cpu = Double(clock()) / 1_000_000.0
        #else
        return nil
        #endif
        let wall = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }
        let previous = lastSample
        lastSample = (cpu, wall)
        guard let last = previous else { return nil }
        let elapsed = wall - last.wall
        guard elapsed > 0 else { return nil }
        return max(0, min(100, ((cpu - last.cpu) / elapsed) * 100))
    }
}

/// Automatic collectors: FPS / dropped frames, main-thread hang (ANR),
/// memory, CPU, battery, thermal state and memory warnings.
final class TDCollectors {
    private let config: TDMonitorConfiguration
    private weak var transport: TDTransport?
    private let hangQueue = DispatchQueue(label: "com.truedepth.monitor.hang", qos: .utility)

    private var displayLink: CADisplayLink?
    private var frameCount = 0
    private var slowFrames = 0
    private var lastFrameTimestamp: CFTimeInterval = 0
    private var lastFPSReport = Date()
    private var hangActive = false
    private var metricsTimer: DispatchSourceTimer?

    /// Called when the OS sends a memory warning; the bridge uses it for OOM heuristics.
    var onMemoryWarning: (() -> Void)?

    init(config: TDMonitorConfiguration, transport: TDTransport) {
        self.config = config
        self.transport = transport
    }

    func start() {
        #if canImport(UIKit)
        UIDevice.current.isBatteryMonitoringEnabled = true
        let link = CADisplayLink(target: self, selector: #selector(frameTick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didReceiveMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        #endif
        startHangWatch()
        startResourceTimer()
    }

    func stop() {
        hangActive = false
        displayLink?.invalidate()
        displayLink = nil
        metricsTimer?.cancel()
        metricsTimer = nil
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - FPS / jank

    @objc private func frameTick(_ link: CADisplayLink) {
        frameCount += 1
        if lastFrameTimestamp > 0 {
            let delta = link.timestamp - lastFrameTimestamp
            if delta > 2.0 / 60.0 { slowFrames += 1 }
        }
        lastFrameTimestamp = link.timestamp

        let now = Date()
        let elapsed = now.timeIntervalSince(lastFPSReport)
        guard elapsed >= 1 else { return }
        let fps = min(Double(frameCount) / max(elapsed, 0.001), 120)
        report(name: "fps", value: fps, unit: "fps")
        if slowFrames > 0 {
            report(name: "frame_jank", value: Double(slowFrames), unit: "frames",
                   attributes: ["windowSeconds": elapsed, "expectedFrameMs": 16.67])
        }
        frameCount = 0
        slowFrames = 0
        lastFPSReport = now
    }

    // MARK: - Main-thread hang / ANR

    private func startHangWatch() {
        hangActive = true
        hangQueue.async { [weak self] in
            while let self = self, self.hangActive {
                let semaphore = DispatchSemaphore(value: 0)
                let started = Date()
                DispatchQueue.main.async { semaphore.signal() }
                let threshold = self.config.hangThresholdMs / 1000.0
                if semaphore.wait(timeout: .now() + threshold) == .timedOut {
                    // Wait (bounded) for the main thread to recover to measure real stall length.
                    _ = semaphore.wait(timeout: .now() + 5)
                    let duration = Date().timeIntervalSince(started) * 1000
                    let event = TDEvent(kind: "anr", fields: [
                        "durationMs": duration,
                        "thresholdMs": self.config.hangThresholdMs,
                        "type": "main_thread_block",
                    ])
                    self.transport?.enqueue(event)
                }
                Thread.sleep(forTimeInterval: 0.15)
            }
        }
    }

    // MARK: - Resources

    private func startResourceTimer() {
        let timer = DispatchSource.makeTimerSource(queue: hangQueue)
        timer.schedule(deadline: .now() + 2, repeating: config.metricsInterval)
        timer.setEventHandler { [weak self] in self?.sampleResources() }
        timer.resume()
        metricsTimer = timer
    }

    private func sampleResources() {
        if let memory = TDResourceSampler.memoryFootprintMB() {
            report(name: "memory", value: memory, unit: "MB", attributes: ["metric": "resident_size"])
        }
        if let cpu = TDResourceSampler.cpuUsagePercent() {
            report(name: "cpu", value: cpu, unit: "%")
        }
        #if canImport(UIKit)
        let device = UIDevice.current
        report(name: "battery", value: Double(device.batteryLevel) * 100, unit: "%",
               attributes: ["state": batteryState(device.batteryState)])
        #endif
        if #available(iOS 11.0, *) {
            report(name: "thermal", value: Double(ProcessInfo.processInfo.thermalState.rawValue),
                   attributes: ["state": "\(ProcessInfo.processInfo.thermalState)"])
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

    @objc private func didReceiveMemoryWarning() {
        onMemoryWarning?()
        let footprint = TDResourceSampler.memoryFootprintMB() ?? 0
        let event = TDEvent(
            kind: "mobile_metric",
            fields: ["name": "memory", "value": footprint, "unit": "MB", "severity": "warning"],
            attributes: ["memoryWarning": true]
        )
        transport?.enqueue(event)
    }
    #endif

    private func report(name: String, value: Double, durationMs: Double? = nil,
                        unit: String? = nil, screen: String? = nil,
                        attributes: [String: Any] = [:]) {
        if config.sampleRate < 1 && Double.random(in: 0..<1) > config.sampleRate { return }
        var fields: [String: Any] = ["name": name, "value": value]
        if let durationMs = durationMs { fields["durationMs"] = durationMs }
        if let unit = unit { fields["unit"] = unit }
        if let screen = screen { fields["screen"] = screen }
        transport?.enqueue(TDEvent(kind: "mobile_metric", fields: fields, attributes: attributes))
    }
}
