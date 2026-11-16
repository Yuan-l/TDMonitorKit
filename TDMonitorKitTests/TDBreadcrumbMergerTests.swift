import XCTest
@testable import TDMonitorKit

/// 口径迁移第一步：两套面包屑合并逻辑的纯函数测试。
/// ts 用统一 ISO8601（带毫秒、UTC）字符串，字典序即时间序。
final class TDBreadcrumbMergerTests: XCTestCase {

    private func crumb(_ ts: String, _ category: String, _ message: String) -> [String: Any] {
        return ["ts": ts, "category": category, "message": message, "level": "info"]
    }

    /// 两套并存时全部保留，不再二选一；按 ts 升序输出。
    func testMergeKeepsBothSourcesSortedByTime() {
        let host = [crumb("2026-11-17T10:00:02.000Z", "host", "tap:next"),
                    crumb("2026-11-17T10:00:04.000Z", "host", "tap:submit")]
        let store = [crumb("2026-11-17T10:00:01.000Z", "lifecycle", "didBecomeActive"),
                     crumb("2026-11-17T10:00:03.000Z", "network", "request.end")]

        let merged = TDBreadcrumbMerger.merge(host, store)

        XCTAssertEqual(merged.count, 4)
        XCTAssertEqual(merged.map { $0["message"] as? String },
                       ["didBecomeActive", "tap:next", "request.end", "tap:submit"])
    }

    /// 完全同键（ts+category+message）的重复项合并为一条，host 优先。
    func testMergeDeduplicatesByTsCategoryMessage() {
        let host = [crumb("2026-11-17T10:00:00.000Z", "host", "tap:X")]
        let store = [crumb("2026-11-17T10:00:00.000Z", "host", "tap:X"),
                     crumb("2026-11-17T10:00:00.000Z", "host", "tap:Y")]

        let merged = TDBreadcrumbMerger.merge(host, store)

        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(Set(merged.map { $0["message"] as? String }), ["tap:X", "tap:Y"])
    }

    /// 同秒同文本但 category 不同不算重复（去重键含 category）。
    func testMergeDoesNotDropSameSecondDifferentCategory() {
        let host = [crumb("2026-11-17T10:00:00.000Z", "host", "open")]
        let store = [crumb("2026-11-17T10:00:00.000Z", "lifecycle", "open")]

        let merged = TDBreadcrumbMerger.merge(host, store)

        XCTAssertEqual(merged.count, 2)
    }

    /// 无 ts 的脏条目被丢弃，不进入时间线。
    func testMergeDropsCrumbsWithoutTimestamp() {
        let bad: [String: Any] = ["category": "host", "message": "no-ts", "level": "info"]
        let good = crumb("2026-11-17T10:00:00.000Z", "host", "ok")

        let merged = TDBreadcrumbMerger.merge([bad], [good])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?["message"] as? String, "ok")
    }

    /// 超过上限时保留最近的 limit 条——崩溃诊断关心崩溃前最近的轨迹。
    func testMergeKeepsMostRecentWhenOverLimit() {
        let host = (1...4).map { crumb("2026-11-17T10:00:0\($0).000Z", "host", "h\($0)") }
        let merged = TDBreadcrumbMerger.merge(host, [], limit: 3)

        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged.map { $0["message"] as? String }, ["h2", "h3", "h4"])
    }

    /// 溯源标记进 attributes（自由字典），不污染面包屑条目的四字段 schema。
    func testProvenanceGoesToAttributesNotCrumbFields() {
        let merged = TDBreadcrumbMerger.merge(
            [crumb("2026-11-17T10:00:00.000Z", "host", "x")], [])

        // 条目本身仍只有四字段，没有 source。
        XCTAssertEqual(Set(merged[0].keys), ["ts", "category", "message", "level"])

        let prov = TDBreadcrumbMerger.provenance(hostCount: 1, storeCount: 0, mergedCount: 1)
        XCTAssertEqual(prov["breadcrumbHostCount"] as? Int, 1)
        XCTAssertEqual(prov["breadcrumbStoreCount"] as? Int, 0)
        XCTAssertEqual(prov["breadcrumbMergedCount"] as? Int, 1)
    }
}
