import Foundation
import TBMMAPStorageKit

/// 事件队列的 mmap 落盘实现。
///
/// ## 为什么不是另一套持久化
///
/// 这里**没有**重新实现文件布局、CRC、加密、提交位点或扩容逻辑。底层直接复用
/// 独立 L0 底座 `TBMMAPStorageKit` 里的 `TBMMAPRecordStore` → `TBMMAPLogFile`：
///
/// ```
/// 56B 文件头(magic/version/entryCount/dataLength/flags)
///   └─ [uint32 length][uint32 crc32][AES-256-CBC payload] × N
/// ```
///
/// 写入顺序是「memcpy 数据 → msync → 推进 dataLength → 写文件头」，
/// 所以进程被强杀最多丢最后一批，不会读到半条；容量不够时 ftruncate +
/// munmap/mmap 按 1.25 倍扩容。密钥在 Keychain
/// (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`)，不可用时降级明文，
/// 由文件头 flags 标记，读取端据此决定是否解密。
///
/// 唯一改动是把 `NetworkFailureLogObjc` 的 NSKeyedArchiver 编解码从底座里
/// 抽了出去，换成 bytes 级接口（见 `TBMMAPLogFile.h`）。因此异构 JSON 事件
/// 和失败日志共用**同一个**持久化引擎，只是各自负责自己的序列化。
///
/// ## 压缩语义
///
/// 追加写的必然结果：已成功发送的记录仍躺在映射区里，直到 `replace(with:)`
/// 整体重写才消失。这正是「至少一次」投递所需的——重复可由服务端按 id 去重，
/// 丢失无法补。压缩会 munmap 后重建文件，调用方不可持有映射区指针。
final class TDMMAPQueueStore: TDEventQueueStore {

    private let store: TBMMAPRecordStore?
    private let maxEvents: Int

    /// 以下状态只在 `TDTransport` 的串行队列上访问：不加锁，避免给人
    /// 「可任意线程调用」的错觉。
    private var appendedSinceCompact = 0
    private var knownCount = 0
    private(set) var corruptedLines = 0

    var storedCount: Int { knownCount }
    var needsCompaction: Bool { appendedSinceCompact > max(1, maxEvents) / 2 }
    /// 已提交的数据字节数。mmap 文件大小是映射区大小（16KB 起步、按需扩容），
    /// 拿它当「积压多少」会严重虚高，所以诊断统一用提交长度。
    var committedBytes: Int { Int(store?.committedBytes ?? 0) }

    init(directory: URL, maxEvents: Int) {
        self.maxEvents = max(1, maxEvents)
        self.store = TBMMAPRecordStore(directory: directory.path,
                                       fileName: "queue.mmap")
        if store == nil {
            TDMonitorLog.record("mmap 事件队列不可用，本次进程仅存内存", level: "error")
        }
    }

    // MARK: - TDEventQueueStore

    func load(limit: Int) -> [[String: Any]] {
        guard let store = store, limit > 0 else {
            knownCount = 0
            return []
        }

        let records = store.readRecords()
        corruptedLines = Int(store.corruptedRecordCount)

        var parsed: [[String: Any]] = []
        parsed.reserveCapacity(records.count)
        for data in records {
            guard let object = try? JSONSerialization.jsonObject(with: data),
                  let event = object as? [String: Any] else {
                // CRC 已过但仍不是合法 JSON：说明写入方版本不兼容或密钥换了。
                // 只丢这一条，不能让整份队列归零。
                corruptedLines += 1
                continue
            }
            parsed.append(event)
        }

        knownCount = Int(store.recordCount)
        appendedSinceCompact = 0
        if corruptedLines > 0 {
            TDMonitorLog.record(
                "mmap 事件队列有 \(corruptedLines) 条损坏已跳过（CRC/解密/JSON）",
                level: "warning")
        }
        guard parsed.count > limit else { return parsed }

        // 截断必须同步落盘。否则这批记录既不会进 `pending`，又会在下一次压缩时
        // 被 `replace(with: pending)` 抹掉——丢了数据却没有任何痕迹，`storedCount`
        // 还会一直虚高。容量保护本身是允许的取舍，但必须显式且可观测。
        let dropped = parsed.count - limit
        let kept = Array(parsed.suffix(limit))
        guard store.replaceAllRecords(Self.encode(kept)) else {
            // 收敛失败就保留磁盘原样，下次启动重试；本次内存仍只取尾部。
            // 绝不能在失败后把 knownCount 写成 kept.count：那会让编排层以为
            // 磁盘已经干净，压缩不再触发。
            TDMonitorLog.record(
                "事件队列上限收敛失败，磁盘仍有 \(dropped) 条超出内存队列（下次启动重试）",
                level: "error")
            return kept
        }
        knownCount = Int(store.recordCount)
        appendedSinceCompact = 0
        TDMonitorLog.record(
            "事件队列 \(parsed.count) 条超过上限 \(limit)，按入队顺序丢弃最旧 \(dropped) 条并同步落盘（容量保护，非写入失败）",
            level: "warning")
        return kept
    }

    func append(_ events: [[String: Any]]) {
        guard let store = store, !events.isEmpty else { return }
        let payload = Self.encode(events)
        guard !payload.isEmpty else { return }
        guard store.appendRecords(payload) else {
            // 落盘失败时内存队列仍然保留这些事件，下一次压缩会再试一次。
            TDMonitorLog.record("mmap 事件队列追加失败，本次 \(events.count) 条仅存内存",
                                level: "error")
            return
        }
        knownCount = Int(store.recordCount)
        appendedSinceCompact += payload.count
    }

    func replace(with events: [[String: Any]]) {
        guard let store = store else { return }
        let payload = Self.encode(events)
        guard store.replaceAllRecords(payload) else {
            TDMonitorLog.record("mmap 事件队列压缩失败", level: "error")
            return
        }
        knownCount = Int(store.recordCount)
        appendedSinceCompact = 0
    }

    func clear() {
        guard let store = store else { return }
        _ = store.replaceAllRecords([])
        knownCount = 0
        appendedSinceCompact = 0
    }

    // MARK: - 编码

    /// 逐条守 JSON 合法性：一条 NaN / 无穷大不会拖累整批。
    private static func encode(_ events: [[String: Any]]) -> [Data] {
        var result: [Data] = []
        result.reserveCapacity(events.count)
        for event in events {
            guard JSONSerialization.isValidJSONObject(event),
                  let data = try? JSONSerialization.data(withJSONObject: event) else {
                continue
            }
            result.append(data)
        }
        return result
    }
}
