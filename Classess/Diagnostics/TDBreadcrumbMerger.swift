import Foundation

/// 把两套同 schema 的面包屑（宿主崩溃报告 + TD store 上一会话）合并成单条时间线。
///
/// 2026-11-17 口径迁移第一步：此前崩溃补发在二者间「二选一」
/// （`parsed.breadcrumbs.isEmpty ? previous : parsed`），用一套必丢另一套，
/// 崩溃现场诊断信息不完整。两套经各自归一化后都是 `ts/category/message/level`
/// 四字段、`ts` 为统一 ISO8601（带毫秒、UTC），字典序即时间序，可直接合并。
///
/// 设计取舍：
/// - **不往条目里塞 source 字段**。后台 `breadcrumbSchema` 是严格四字段，
///   历史上一条非法字段就让整批 native_crash 422。溯源信息改由调用方放进
///   `TDEvent.attributes`（自由字典，不进 breadcrumbSchema），见 TDCrashFeature。
/// - **去重键 `ts+category+message`**：同秒同文本但 category 不同的操作不算重复；
///   两套 store 里时间戳、分类、文本完全一致的重复项才合并。
/// - **保留最近 limit 条**：崩溃诊断关心的是崩溃前最近的轨迹，不是最早的；
///   排序后取尾部。下游 `sanitizedBreadcrumbs` 还有 prefix(100)，这里先收口
///   避免最近轨迹被它从头部截断。
enum TDBreadcrumbMerger {

    /// 合并两套面包屑并按时间升序输出。
    /// - Parameters:
    ///   - host: 宿主崩溃报告里的操作路径（category 通常为 "host"）。
    ///   - store: TD store 的上一会话面包屑（生命周期等）。
    ///   - limit: 合并后保留的最近条数，默认 100（与 store maxCount 一致）。
    /// - Returns: 去重、排序、截断后的单条时间线。
    static func merge(_ host: [[String: Any]],
                      _ store: [[String: Any]],
                      limit: Int = 100) -> [[String: Any]] {
        var seen = Set<String>()
        var merged: [[String: Any]] = []
        merged.reserveCapacity(min(host.count + store.count, limit * 2))

        // host 先入、store 后入：完全同键的重复项保留 host 那条（崩溃当场抓的更权威）。
        for crumb in host + store {
            let ts = crumb["ts"] as? String ?? ""
            guard !ts.isEmpty else { continue }
            let category = crumb["category"] as? String ?? ""
            let message = crumb["message"] as? String ?? ""
            let key = "\(ts)|\(category)|\(message)"
            guard seen.insert(key).inserted else { continue }
            merged.append(crumb)
        }

        // ISO8601 同格式（带毫秒、UTC）字典序即时间序。去重后按 ts 升序，取最近 limit 条。
        merged.sort { ($0["ts"] as? String ?? "") < ($1["ts"] as? String ?? "") }
        if merged.count > limit {
            merged.removeFirst(merged.count - limit)
        }
        return merged
    }

    /// 给调用方放进 attributes 的溯源标记（不进 breadcrumbSchema，避免 422）。
    static func provenance(hostCount: Int, storeCount: Int, mergedCount: Int) -> [String: Any] {
        return [
            "breadcrumbSources": ["host", "td_store"],
            "breadcrumbHostCount": hostCount,
            "breadcrumbStoreCount": storeCount,
            "breadcrumbMergedCount": mergedCount,
        ]
    }
}
