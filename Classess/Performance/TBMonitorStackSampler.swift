import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// 主线程堆栈采样器。
///
/// ANR 诊断的价值 90% 在「卡住时主线程停在哪个函数」，只上报一个 durationMs
/// 无法定位问题。这里用标准做法：后台线程短暂挂起主线程，从 `ucontext` 级的
/// 寄存器状态出发沿帧指针链回溯，**先取地址、恢复线程、再做符号解析**——
/// 挂起期间绝不调用 dladdr 这类可能加锁的接口，否则采样器自己就会制造死锁。
enum TDStackSampler {

    struct Frame {
        let module: String
        let symbol: String?
        let address: UInt64
        let offsetInImage: UInt64
    }

    #if arch(arm64)
    /// 主线程的 mach port。必须由主线程在启动时登记一次。
    private static var mainThreadPort: mach_port_t = 0
    private static let portLock = NSLock()

    static func registerMainThread() {
        #if canImport(Darwin)
        portLock.lock()
        defer { portLock.unlock() }
        guard mainThreadPort == 0 else { return }
        mainThreadPort = mach_thread_self()
        #endif
    }

    /// 采样主线程当前调用栈。返回的是**未符号化**的地址，调用方在恢复线程后再解析。
    static func captureMainThreadAddresses(maxFrames: Int = 48) -> [UInt64] {
        portLock.lock()
        let port = mainThreadPort
        portLock.unlock()
        guard port != 0 else { return [] }

        guard thread_suspend(port) == KERN_SUCCESS else { return [] }
        defer { thread_resume(port) }

        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<UInt32>.size)
        let result = withUnsafeMutablePointer(to: &state) { pointer in
            pointer.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { rebound in
                thread_get_state(port, thread_state_flavor_t(ARM_THREAD_STATE64), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return [] }

        // arm64e 的指针带 PAC 签名位，取真实虚拟地址前必须剥掉高位。
        let addressMask: UInt64 = 0x0000_7FFF_FFFF_FFFF
        var addresses: [UInt64] = [UInt64(state.__pc) & addressMask]
        if state.__lr != 0 {
            addresses.append(UInt64(state.__lr) & addressMask)
        }

        // 帧记录布局（AAPCS64）：[fp] = 上一帧的 fp，[fp + 8] = 返回地址。
        var framePointer = UInt64(state.__fp) & addressMask
        var previous = UInt64.max
        for _ in 0..<maxFrames {
            guard framePointer != 0, framePointer % 8 == 0, framePointer < previous else { break }
            guard let record = readMemory(at: framePointer, count: 16) else { break }
            let next = record.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt64.self) } & addressMask
            let returnAddress = record.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt64.self) } & addressMask
            if returnAddress != 0 { addresses.append(returnAddress) }
            previous = framePointer
            framePointer = next
        }
        return addresses
    }
    #else
    static func registerMainThread() {}
    static func captureMainThreadAddresses(maxFrames: Int = 48) -> [UInt64] { [] }
    #endif

    /// 地址 → 模块 / 符号。只在线程恢复之后调用。
    static func symbolicate(_ addresses: [UInt64]) -> [Frame] {
        #if canImport(Darwin)
        var frames: [Frame] = []
        frames.reserveCapacity(addresses.count)
        for address in addresses {
            guard address != 0, let pointer = UnsafeRawPointer(bitPattern: UInt(address)) else { continue }
            var info = Dl_info()
            guard dladdr(pointer, &info) != 0 else {
                frames.append(Frame(module: "unknown", symbol: nil, address: address, offsetInImage: 0))
                continue
            }
            let module = info.dli_fname.map { URL(fileURLWithPath: String(cString: $0)).lastPathComponent } ?? "unknown"
            let base = UInt64(UInt(bitPattern: info.dli_fbase))
            let symbol = info.dli_sname.map { String(cString: $0) }
            frames.append(Frame(module: module,
                                symbol: symbol,
                                address: address,
                                offsetInImage: address >= base ? address - base : 0))
        }
        return frames
        #else
        return []
        #endif
    }

    /// 一行一个帧，格式与 atos 可解析的 `模块 0x地址` 对齐，便于后续用 dSYM 二次符号化。
    static func format(_ frames: [Frame]) -> String {
        frames.enumerated().map { index, frame in
            let symbol = frame.symbol.map { " \($0)" } ?? ""
            return "\(index) \(frame.module) 0x\(String(frame.address, radix: 16))\(symbol)"
        }.joined(separator: "\n")
    }

    /// 供上报的结构化帧：模块 + 镜像内偏移，服务端拿到 dSYM 后可精确还原行号。
    static func structured(_ frames: [Frame]) -> [[String: Any]] {
        frames.map { frame in
            var item: [String: Any] = [
                "module": frame.module,
                "address": String(format: "0x%llx", frame.address),
                "offset": frame.offsetInImage,
            ]
            if let symbol = frame.symbol { item["symbol"] = symbol }
            return item
        }
    }

    private static func readMemory(at address: UInt64, count: Int) -> Data? {
        #if canImport(Darwin)
        var buffer = [UInt8](repeating: 0, count: count)
        var outSize: vm_size_t = 0
        let result = buffer.withUnsafeMutableBytes { raw -> kern_return_t in
            guard let base = raw.baseAddress else { return KERN_FAILURE }
            return vm_read_overwrite(mach_task_self_,
                                     vm_address_t(address),
                                     vm_size_t(count),
                                     vm_address_t(UInt(bitPattern: base)),
                                     &outSize)
        }
        guard result == KERN_SUCCESS, outSize == vm_size_t(count) else { return nil }
        return Data(buffer)
        #else
        return nil
        #endif
    }
}
