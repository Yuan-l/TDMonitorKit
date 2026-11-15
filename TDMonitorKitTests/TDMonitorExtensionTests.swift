import XCTest
@testable import TDMonitorKit

/// 自定义能力：验证外部在不 fork SDK 的前提下能扩展采集能力。
///
/// 这就是「能力可复用 / 可工程化」的验收点——业务方只需遵循 `TDMonitorFeature`
/// 协议，即可与内置能力共用同一套依赖注入、顺序安装、逆序卸载与能力矩阵对账。
final class GammaFeature: TDMonitorFeature {
    static let name = "gamma"
    init?(runtime: TDMonitorRuntime) {}
    func install() -> Bool { FeatureLog.shared.append("+gamma"); return true }
    func uninstall() { FeatureLog.shared.append("-gamma") }
}

final class TDMonitorExtensionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        FeatureLog.shared.reset()
        TDMonitor.shared.stop()
    }

    /// 1. 公开注册入口能把自定义能力装进注册表并随 `installAll` 安装。
    func testPublicRegisterInstallsCustomFeature() {
        let registry = TDMonitorFeatureRegistry()
        registry.register({ rt in GammaFeature(runtime: rt) }, name: GammaFeature.name)
        let runtime = makeRuntime()
        let installed = registry.installAll(runtime: runtime)
        XCTAssertTrue(installed.contains("gamma"))
        XCTAssertTrue(FeatureLog.shared.all.contains("+gamma"))
    }

    /// 2. 同名重复登记只安装一次——注册表按名字去重。
    func testDuplicateRegistrationInstalledOnce() {
        let registry = TDMonitorFeatureRegistry()
        registry.register({ rt in GammaFeature(runtime: rt) }, name: GammaFeature.name)
        registry.register({ rt in GammaFeature(runtime: rt) }, name: GammaFeature.name)
        let runtime = makeRuntime()
        let installed = registry.installAll(runtime: runtime)
        XCTAssertEqual(installed.filter { $0 == "gamma" }.count, 1)
    }

    /// 3. 端到端：通过 `TDMonitor.register` 门面登记，start 时真实安装。
    ///
    /// 这条不走 registry 单测，而是走与业务完全相同的 `start(configuration:sink:)`
    /// 路径——证明外部扩展能力对宿主而言和内置能力没有区别。
    func testFacadeRegisterInstallsOnStart() {
        TDMonitor.register(GammaFeature.self)
        let sink = RecordingSink()
        let config = TDMonitorConfiguration(baseURL: URL(string: "https://example.com")!,
                                            apiKey: "k", appId: "a")
        let started = TDMonitor.shared.start(configuration: config, sink: sink)
        XCTAssertTrue(started)
        XCTAssertTrue(FeatureLog.shared.all.contains("+gamma"))
        TDMonitor.shared.stop()
    }

    // MARK: - helpers

    private func makeRuntime(config: TDMonitorConfiguration? = nil) -> TDMonitorRuntime {
        let cfg = config
            ?? TDMonitorConfiguration(baseURL: URL(string: "https://example.com")!,
                                      apiKey: "k", appId: "a")
        let context = TDContext(config: cfg)
        let sink = RecordingSink()
        let clock = TDManualClock()
        let capabilities = TDCapabilityMatrix.probe(networkInstrumentation: true, viewLoad: true)
        return TDMonitorRuntime(configuration: cfg, context: context, sink: sink,
                                clock: clock, capabilities: capabilities,
                                appState: TDAppStateTracker.shared)
    }
}
