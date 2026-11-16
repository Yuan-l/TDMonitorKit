import XCTest
@testable import TDMonitorKit

/// 治理第二步：recordCustom 语义护栏的纯函数测试。
/// 约束目的：防止业务方借通用逃生口塞自由文本 KPI 名污染 mobile_metric 统一口径。
final class TDCustomMetricGuardTests: XCTestCase {

    func testAcceptsLowerSnakeAndDotNames() {
        let valid = ["phys_footprint", "external_sdk_request", "gpu.memory.peak",
                     "a", "metric_2", "launch.duration_ms"]
        for name in valid {
            XCTAssertTrue(TDCrashBridge.isValidCustomMetricName(name), "应接受: \(name)")
        }
    }

    func testRejectsFreeTextAndBusinessKpiNames() {
        let invalid = [
            "",                          // 空
            "CheckoutTap",               // 大写（业务 KPI 常见写法）
            "checkout tap",              // 空格
            "结算转化率",                 // 中文自由文本
            "user/checkout",             // 路径分隔符
            "a-b",                       // 连字符
            String(repeating: "a", count: 65), // 超长
        ]
        for name in invalid {
            XCTAssertFalse(TDCrashBridge.isValidCustomMetricName(name), "应拒绝: \(name)")
        }
    }

    func testBoundaryLength64Accepted() {
        XCTAssertTrue(TDCrashBridge.isValidCustomMetricName(String(repeating: "m", count: 64)))
        XCTAssertFalse(TDCrashBridge.isValidCustomMetricName(String(repeating: "m", count: 65)))
    }
}
