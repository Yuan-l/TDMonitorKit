import Foundation
#if canImport(Darwin)
import Darwin
#endif
import MachO

/// 主二进制（以及其它已加载镜像）的 UUID。
///
/// 符号化的前提是「崩溃栈里的地址」与「dSYM 的 UUID」能对上，否则 dSYM 一换
/// 版本就全错。这里直接从 Mach-O 的 LC_UUID 读取，不依赖任何私有接口。
public enum TDBinaryImage {

    public static func uuid(forImageAt index: UInt32 = 0) -> String? {
        guard let header = _dyld_get_image_header(index) else { return nil }
        return uuid(in: header)
    }

    public static func uuid(in header: UnsafePointer<mach_header>) -> String? {
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

    public static var mainUUID: String? { uuid() }

    /// 主二进制在**本次运行**中的加载基址。
    /// PIE 每次启动的 slide 不同，只有把基址一起上报，事后才能用 atos + dSYM 还原行号。
    public static var mainLoadAddress: UInt64? {
        guard let header = _dyld_get_image_header(0) else { return nil }
        return UInt64(UInt(bitPattern: header))
    }
}

/// 崩溃现场：面包屑 + 结构化栈 + 镜像 UUID。
///
/// 早期实现把面包屑只放在内存里，App 被杀时一起消失；崩溃是「下一次启动」
/// 才补发的，那时内存早已清空，所以崩溃事件里的 `breadcrumbs` 永远是空数组。
/// 现在每条面包屑都会落盘（节流写入），崩溃补发时能带上真实的操作轨迹。
public final class TDBreadcrumbStore {

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

    public func append(category: String, message: String, level: String) {
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
    public func flush() {
        lock.lock()
        let snapshot = items
        let needsWrite = dirty
        dirty = false
        lastWrite = Date()
        lock.unlock()
        if needsWrite { write(snapshot) }
    }

    public func current() -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return items
    }

    /// 上次会话残留的面包屑，用于给「上次崩溃」补齐轨迹。
    public func loadPreviousSession() -> [[String: Any]] {
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

    private static let plainISO8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// 把宿主崩溃报告里自由格式的 `timestamp` 收口成后台可解析的 ISO8601。
    ///
    /// 后台 `breadcrumbSchema.ts` 的 `ts` 是 `z.coerce.date()`：只要有一条非法日期，
    /// **整个 `native_crash` 批次**就会被 422 拒掉。真机上已经发生过：自采的崩溃
    /// （带符号化栈、面包屑、现场）全部消失，后台只剩 MetricKit 的未符号化诊断。
    /// 这种「一条脏字段打死一整批」的代价，必须在组包前消掉。
    /// 支持：ISO8601（带/不带小数秒）、秒/毫秒时间戳、常见本地时间文本。
    static func normalizedTimestamp(_ raw: Any?, fallback: Date) -> String {
        if let number = raw as? NSNumber, let date = date(fromEpoch: number.doubleValue) {
            return TDISO8601.string(from: date)
        }
        if let text = raw as? String, !text.isEmpty {
            if let date = TDISO8601.formatter.date(from: text) ?? plainISO8601.date(from: text) {
                return TDISO8601.string(from: date)
            }
            if let seconds = Double(text), let date = date(fromEpoch: seconds) {
                return TDISO8601.string(from: date)
            }
            // 宿主 `TBCrashReporter` 的面包屑只写 `HH:mm:ss.SSS`（无日期）。
            // 这正是真机 422 的元凶：`new Date("16:12:01.895")` 是 Invalid Date。
            // 崩溃报告的 epoch 给了确定日期，按崩溃当天重建，保留轨迹的先后顺序。
            if let date = reconstructedTime(text, relativeTo: fallback) {
                return TDISO8601.string(from: date)
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            for pattern in ["yyyy-MM-dd HH:mm:ss ZZZ", "yyyy-MM-dd HH:mm:ss", "yyyy/MM/dd HH:mm:ss"] {
                formatter.dateFormat = pattern
                if let date = formatter.date(from: text) {
                    return TDISO8601.string(from: date)
                }
            }
        }
        // 解析不了就退回崩溃时刻，绝不能把原始自由文本塞给后台。
        return TDISO8601.string(from: fallback)
    }

    /// 把 `HH:mm:ss.SSS` 补成崩溃当天的绝对时刻；跨午夜时回退一天。
    /// 用设备本地日历拼接（宿主 formatter 也是本地时区），输出再统一转 UTC ISO8601。
    private static func reconstructedTime(_ text: String, relativeTo crash: Date) -> Date? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let hour = Int(parts[0]), (0..<24).contains(hour),
              let minute = Int(parts[1]), (0..<60).contains(minute),
              let second = Double(parts[2]), second >= 0, second < 60 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var components = calendar.dateComponents([.year, .month, .day], from: crash)
        components.hour = hour
        components.minute = minute
        components.second = Int(second)
        guard var date = calendar.date(from: components) else { return nil }
        if date.timeIntervalSince(crash) > 60 {
            date = calendar.date(byAdding: .day, value: -1, to: date) ?? date
        }
        return date
    }

    /// 秒级与毫秒级时间戳都接受，避免把毫秒当秒得到公元 57000 年。
    private static func date(fromEpoch value: Double) -> Date? {
        guard value > 0, value.isFinite else { return nil }
        return Date(timeIntervalSince1970: value > 100_000_000_000 ? value / 1000 : value)
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
        /// 宿主是崩溃当场抓的 `callStackSymbols`，帧里带符号名；MetricKit 诊断才是未符号化的。
        let symbolicated: Bool
        let signal: String?
        let exceptionType: String?
        let breadcrumbs: [[String: Any]]
        let context: [String: String]
        /// 崩溃进程启动时落盘的镜像清单（name/uuid/loadAddress/size），dSYM 符号化前提。
        let binaryImages: [[String: Any]]
    }

    static func parse(url: URL) -> Parsed? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let reason = json["exceptionReason"] as? String
        let name = json["exceptionName"] as? String
        let type = json["type"] as? String ?? "unknown"
        let message = reason ?? name ?? "崩溃（\(type)）"

        // 崩溃真实时刻：后面既作为 `native_crash.ts`，也作为无法解析的面包屑时间兜底。
        let timestamp = (json["timestamp"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()

        let stackLines = json["stack"] as? [String]
        let frames = structuredFrames(from: stackLines ?? [])
        // 宿主在崩溃当场抓 `callStackSymbols`，App / Swift 帧里已有符号名；硬编码 false
        // 会让后台把自采崩溃与 MetricKit 的未符号化诊断归成同一类，直接误导覆盖率。
        // 但系统库帧常写成 `0013A8B1-… + 185864`（image UUID + offset），那不是符号，
        // 只看「不以 0x 开头」会把它误判成已符号化，必须单独排除。
        let symbolicated = (json["symbolicated"] as? Bool) ?? frames.contains { frame in
            guard let symbol = frame["symbol"] as? String else { return false }
            return looksLikeSymbol(symbol)
        }
        let crumbs = (json["breadcrumbs"] as? [[String: Any]] ?? []).prefix(100).compactMap { raw -> [String: Any]? in
            guard let event = raw["event"] as? String, !event.isEmpty else { return nil }
            return [
                "ts": TDBreadcrumbStore.normalizedTimestamp(raw["timestamp"], fallback: timestamp),
                "category": "host",
                "message": String(event.prefix(512)),
                "level": "info",
            ]
        }
        let context = (json["context"] as? [String: String]) ?? [:]
        // 镜像快照只存文件名（context 限 8KB），实际内容由宿主闭包按文件名读回。
        let binaryImagesFile = context["binaryImagesFile"] ?? ""
        let binaryImages = binaryImagesFile.isEmpty ? [] : (TDMonitor.hostBinaryImages?(binaryImagesFile) ?? [])
        return Parsed(
            id: json["id"] as? String ?? url.lastPathComponent,
            timestamp: timestamp,
            message: message,
            stack: stackLines?.joined(separator: "\n"),
            frames: frames,
            symbolicated: symbolicated,
            signal: json["signal"] as? String,
            exceptionType: name,
            breadcrumbs: crumbs,
            context: context,
            binaryImages: binaryImages
        )
    }

    /// 栈帧的 `symbol` 列不一定真是符号名：系统库没有本地符号时会写成
    /// `0013A8B1-2524-3534-B5BA-681AAF18C798 + 185864`（image UUID + offset），
    /// 也有裸 `0x…` 地址行。两者都以数字开头，不能算符号。
    private static func looksLikeSymbol(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard let first = text.first else { return false }
        // UUID 既可能以数字开头（0013A8B1-…），也可能以字母开头
        // （C05E486D-…），只看首字符挡不住，按整行格式识别。
        let uuidFrame = "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}(\\s|$)"
        if text.range(of: uuidFrame, options: .regularExpression) != nil { return false }
        if first.isNumber { return false }          // 裸地址 / 数字开头
        // ObjC 方法 `-[Class sel]` / `+[Class sel]`、Swift mangled `$s…`、
        // C/C++ 与系统符号（`objc_exception_throw`、`_dispatch_…`）。
        return first.isLetter || first == "_" || first == "$" || first == "-" || first == "+"
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
