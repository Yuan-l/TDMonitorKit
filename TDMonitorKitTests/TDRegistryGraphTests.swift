import XCTest
@testable import TDMonitorKit

/// 锁住「能力依赖机制」的契约。
///
/// 审计（IMPLEMENTATION-AUDIT §1）点名：我们的 `requires` + 运行期服务字典是 D 类自创，
/// 写错类型不会编译报错，依赖缺口在 Release 下静默继续。保留这套设计的底线是：
/// (1) 缺口必须被 `noteBlocked` 记录、可被观测；(2) 内置 12 能力的 `requires` 图谱
/// 必须自洽——任一能力声明依赖却没人 provide，就会悄悄少数据。本测试锁住这两条。
final class TDRegistryGraphTests: XCTestCase {

    private func config() -> TDMonitorConfiguration {
        TDMonitorConfiguration(baseURL: URL(string: "https://example.com")!,
                               apiKey: "k", appId: "a")
    }

    override func setUp() {
        super.setUp()
        TDMonitor.shared.stop()
    }

    override func tearDown() {
        TDMonitor.shared.stop()
        super.tearDown()
    }

    // MARK: - 纯函数：依赖缺口计算

    func testUnmetRequirementsEmpty() {
        XCTAssertEqual(
            TDMonitorFeatureRegistry.unmetRequirements(requires: [], installed: []), [])
        XCTAssertEqual(
            TDMonitorFeatureRegistry.unmetRequirements(requires: ["crash"], installed: ["crash"]), [])
    }

    func testUnmetRequirementsDetectsMissing() {
        let missing = TDMonitorFeatureRegistry.unmetRequirements(
            requires: ["crash", "attribution"], installed: ["attribution"])
        XCTAssertEqual(missing, ["crash"])
    }

    // MARK: - 内置图谱：安装后不得有缺口

    /// 端到端验证：内置 12 能力的 `requires` 全部可满足，`blockedFeatures` 必须为空。
    ///
    /// 这是「依赖写错就少数据且不报错」这条最隐蔽故障的对抗测试——
    /// 如果有人把某个能力的 `requires` 指向一个不存在的名字，或者忘了 `provide`
    /// 某个服务，这里会立刻变红。
    func testBuiltInGraphInstallsWithoutBlockedFeatures() {
        let started = TDMonitor.shared.start(configuration: config(), sink: RecordingSink())
        XCTAssertTrue(started)

        XCTAssertTrue(
            TDMonitor.shared.blockedFeatures.isEmpty,
            "内置能力依赖图谱必须自洽，实际缺口：\(TDMonitor.shared.blockedFeatures)")

        // 平台无关的核心能力必须装齐。metrickit 受 iOS 14 / 系统设置影响，不在此断言。
        for name in ["attribution", "crash", "anr", "lifecycle"] {
            XCTAssertTrue(
                TDMonitor.shared.installedFeatures.contains(name),
                "核心能力 \(name) 未安装")
        }
    }
}
