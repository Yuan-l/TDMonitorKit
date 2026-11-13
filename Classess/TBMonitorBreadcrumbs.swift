import Foundation
#if canImport(Darwin)
import Darwin
#endif
import MachO

/// 主二进制（以及其它已加载镜像）的 UUID。
///
/// 符号化的前提是「崩溃栈里的地址」与「dSYM 的 UUID」能对上，否则 dSYM 一换
/// 版本就全错。这里直接从 Mach-O 的 LC_UUID 读取，不依赖任何私有接口。
enum TDBinaryImage {

    static func uuid(forImageAt index: UInt32 = 0) -> String? {
        guard let header = _dyld_get_image_header(index) else { return nil }
        return uuid(in: header)
    }

    static func uuid(in header: UnsafePointer<mach_header>) -> String? {
        let is64 = header.pointee.magic == MH_MAGIC_64 || header.pointee.magic == MH_CIGAM_64
        let headerSize = is64 ? MemoryLayout<mach_header_64>.size : MemoryLayout<mach_header>.size
        var cursor = UnsafeRawPointer(header).advanced(by: headerSize)

        for _ in 0..<header.pointee.ncmds {
            let command = cursor.load(as: load_command.self)
            if command.cmd == LC_UUID {
                let uuidCommand = cursor.load(as: uuid_command.self)
                let bytes = withUnsafeBytes(of: uuidCommand.uuid) { Array($0) }
                guard bytes.count == 16 else { return nil }
                let hex = bytes.map { String(format: "%02X", $0) }
                return [hex[0...3].joined(), hex[4...5].joined(), hex[6...7].joined(),
                        hex[8...9].joined(), hex[10...15].joined()].joined(separator: "-")
            }
            guard command.cmdsize > 0 else { break }
            cursor = cursor.advanced(by: Int(command.cmdsize))
        }
        return nil
    }

    static var mainUUID: String? { uuid() }

    /// 主二进制在**本次运行**中的加载基址。
    /// PIE 每次启动的 slide 不同，只有把基址一起上报，事后才能用 atos + dSYM 还原行号。
    static var mainLoadAddress: UInt64? {
        guard let header = _dyld_get_image_header(0) else { return nil }
        return UInt64(UInt(bitPattern: header))
    }
}

/// 崩溃现场：面包屑 + 结构化栈 + 镜像 UUID。
///
/// 早期实现把面包屑只放在内存里，App 被杀时一起消失；崩溃是「下一次启动」
/// 才补发的，那时内存早已清空，所以崩溃事件里的 `breadcrumbs` 永远是空数组。
/// 现在每条面包屑都会落盘（节流写入），崩溃补发时能带上真实的操作轨迹。
final class TDBreadcrumbStore {

    private let maxCount = 100
    private let lock = NSLock()
    private var items: [[String: Any]] = []
    private var lastWrite = Date.distantPast
    private var dirty = false

    private var fileURL: URL {
        let base = (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("TDMonitor", isDirectory: true)
            .appendingPathComponent("breadcrumbs.json")
    }

    func append(category: String, message: String, level: String) {
        let crumb: [String: Any] = [
            "ts": TDISO8601.string(from: Date()),
            "category": String(category.prefix(64)),
            "message": String(message.prefix(512)),
            // 服务端 level 是 info|warning|error 三值枚举，宿主传进来的自由文本
            // 必须收口，否则一条 debug 级别就会让整条崩溃事件被拒。
            "level": TDBreadcrumbStore.normalizedLevel(level),
        ]
        lock.lock()
        items.append(crumb)
        if items.count > maxCount { items.removeFirst(items.count - maxCount) }
        let shouldWrite = Date().timeIntervalSince(lastWrite) > 1
        if shouldWrite { lastWrite = Date() } else { dirty = true }
        let snapshot = items
        lock.unlock()
        if shouldWrite { write(snapshot) }
    }

    /// 进入后台 / 崩溃前调用，把节流期间攒下的内容立即刷盘。
    func flush() {
        lock.lock()
        let snapshot = items
        let needsWrite = dirty
        dirty = false
        lastWrite = Date()
        lock.unlock()
        if needsWrite { write(snapshot) }
    }

    func current() -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return items
    }

    /// 上次会话残留的面包屑，用于给「上次崩溃」补齐轨迹。
    func loadPreviousSession() -> [[String: Any]] {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return stored.suffix(maxCount).compactMap { raw in
            guard let category = raw["category"] as? String, !category.isEmpty else { return nil }
            var crumb = raw
            crumb["level"] = TDBreadcrumbStore.normalizedLevel(raw["level"] as? String ?? "info")
            return crumb
        }
    }

    static func normalizedLevel(_ raw: String) -> String {
        switch raw.lowercased() {
        case "error", "fatal", "critical": return "error"
        case "warn", "warning": return "warning"
        default: return "info"
        }
    }

    /// 新会话开始：清空磁盘上的旧轨迹，避免与本次会话混在一起。
    func resetForNewSession() {
        lock.lock()
        items.removeAll()
        dirty = false
        lock.unlock()
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func write(_ snapshot: [[String: Any]]) {
        let url = fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard JSONSerialization.isValidJSONObject(snapshot),
              let data = try? JSONSerialization.data(withJSONObject: snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// 把宿主崩溃组件落盘的 JSON 转成标准 APM 事件。
enum TDCrashReportParser {

    struct Parsed {
        let id: String
        let timestamp: Date
        let message: String
        let stack: String?
        let frames: [[String: Any]]
        let signal: String?
        let exceptionType: String?
        let breadcrumbs: [[String: Any]]
        let context: [String: String]
    }

    static func parse(url: URL) -> Parsed? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let reason = json["exceptionReason"] as? String
        let name = json["exceptionName"] as? String
        let type = json["type"] as? String ?? "unknown"
        let message = reason ?? name ?? "崩溃（\(type)）"

        let stackLines = json["stack"] as? [String]
        let crumbs = (json["breadcrumbs"] as? [[String: Any]] ?? []).compactMap { raw -> [String: Any]? in
            guard let event = raw["event"] as? String else { return nil }
            let ts = raw["timestamp"] as? String ?? TDISO8601.string(from: Date())
            return ["ts": ts, "category": "host", "message": String(event.prefix(512)), "level": "info"]
        }

        let timestamp = (json["timestamp"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()
        return Parsed(
            id: json["id"] as? String ?? url.lastPathComponent,
            timestamp: timestamp,
            message: message,
            stack: stackLines?.joined(separator: "\n"),
            frames: structuredFrames(from: stackLines ?? []),
            signal: json["signal"] as? String,
            exceptionType: name,
            breadcrumbs: crumbs,
            context: (json["context"] as? [String: String]) ?? [:]
        )
    }

    /// 从宿主已有的文本栈里抽回地址，生成符号化脚本可消费的结构化帧。
    /// 形如 `0   TrueDepthDemo2   0x0000000102a4c1d8 -[Foo bar] + 12`。
    static func structuredFrames(from lines: [String]) -> [[String: Any]] {
        var frames: [[String: Any]] = []
        for line in lines.prefix(80) {
            let parts = line.split(separator: " ").map(String.init).filter { !$0.isEmpty }
            // 形如：<序号> <模块> 0x<地址> <符号>
            let offset = Int(parts.first ?? "") != nil ? 1 : 0
            guard parts.count > offset + 1 else { continue }
            let module = parts[offset]
            let addressToken = parts[offset + 1]
            guard addressToken.hasPrefix("0x"),
                  let address = UInt64(addressToken.dropFirst(2), radix: 16) else { continue }
            var frame: [String: Any] = [
                "module": module,
                "address": String(format: "0x%llx", address),
            ]
            if parts.count > offset + 2 {
                frame["symbol"] = parts[(offset + 2)...].joined(separator: " ")
            }
            frames.append(frame)
        }
        return frames
    }
}
