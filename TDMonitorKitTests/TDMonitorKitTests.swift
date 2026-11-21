import XCTest
@testable import TDMonitorKit

// MARK: - 测试替身
//
// 这三个替身本身就是「可复用」的证据：如果采集侧还硬依赖 `TDTransport`，
// 这里根本写不出内存 sink，也写不出假的能力单元。

/// 内存事件出口。用来断言「发了什么、发了几条」。
final class RecordingSink: TDEventSink {

    private(set) var events: [TDEvent] = []
    private(set) var flushCount = 0
    private(set) var backgroundFlushCount = 0
    private(set) var started = false

    func start() { started = true }
    func enqueue(_ event: TDEvent) { events.append(event) }
    func flush() { flushCount += 1 }
    func flushInBackground() { backgroundFlushCount += 1 }

    var kinds: [String] { events.map { $0.kind } }
}

/// 能力安装日志，用于断言安装顺序与卸载顺序。
final class FeatureLog {
    static let shared = FeatureLog()

    private let lock = NSLock()
    private var entries: [String] = []

    func append(_ entry: String) {
        lock.lock(); entries.append(entry); lock.unlock()
    }

    var all: [String] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    func reset() {
        lock.lock(); entries.removeAll(); lock.unlock()
    }
}

final class AlphaFeature: TDMonitorFeature {
    static let name = "alpha"
    init?(runtime: TDMonitorRuntime) {}
    func install() -> Bool { FeatureLog.shared.append("+alpha"); return true }
    func uninstall() { FeatureLog.shared.append("-alpha") }
}

final class BetaFeature: TDMonitorFeature {
    static let name = "beta"
    static let requires = ["alpha"]
    init?(runtime: TDMonitorRuntime) {}
    func install() -> Bool { FeatureLog.shared.append("+beta"); return true }
    func uninstall() { FeatureLog.shared.append("-beta") }
}

/// 模拟「当前环境不支持」：iOS 13 上的 MetricKit 就是这个行为。
final class UnavailableFeature: TDMonitorFeature {
    static let name = "unavailable"
    init?(runtime: TDMonitorRuntime) { return nil }
    func install() -> Bool { FeatureLog.shared.append("+unavailable"); return true }
    func uninstall() { FeatureLog.shared.append("-unavailable") }
}

/// 模拟「运行期安装失败」：不阻断其它能力。
final class FailingFeature: TDMonitorFeature {
    static let name = "failing"
    init?(runtime: TDMonitorRuntime) {}
    func install() -> Bool { FeatureLog.shared.append("+failing"); return false }
    func uninstall() { FeatureLog.shared.append("-failing") }
}

final class ServiceProviderFeature: TDMonitorFeature {
    static let name = "service_provider"
    private let runtime: TDMonitorRuntime
    init?(runtime: TDMonitorRuntime) { self.runtime = runtime }
    func install() -> Bool { runtime.provide("hello"); return true }
    func uninstall() {}
}

// MARK: - 基类

class TDMonitorKitTestCase: XCTestCase {

    override func setUp() {
        super.setUp()
        FeatureLog.shared.reset()
    }

    func makeRuntime(clock: TDClock = TDManualClock()) -> TDMonitorRuntime {
        let configuration = TDMonitorConfiguration(
            baseURL: URL(string: "https://monitor.example.com")!,
            apiKey: "test-key",
            appId: "test-app")
        return TDMonitorRuntime(
            configuration: configuration,
            context: TDContext(config: configuration),
            sink: RecordingSink(),
            clock: clock,
            capabilities: TDCapabilityMatrix(items: []))
    }
}

// MARK: - 能力注册表

final class TDMonitorFeatureRegistryTests: TDMonitorKitTestCase {

    func testInstallsInRegistrationOrder() {
        let registry = TDMonitorFeatureRegistry()
        registry.register(AlphaFeature.self)
        registry.register(BetaFeature.self)

        let installed = registry.installAll(runtime: makeRuntime())

        XCTAssertEqual(installed, ["alpha", "beta"])
        XCTAssertEqual(FeatureLog.shared.all, ["+alpha", "+beta"])
    }

    /// 可失败初始化器返回 nil 时必须静默跳过，且不影响后续能力。
    /// 这是 iOS 13 上 MetricKit 缺失时的实际路径。
    func testSkipsFeatureWhoseInitReturnsNil() {
        let registry = TDMonitorFeatureRegistry()
        registry.register(AlphaFeature.self)
        registry.register(UnavailableFeature.self)
        registry.register(BetaFeature.self)

        let installed = registry.installAll(runtime: makeRuntime())

        XCTAssertEqual(installed, ["alpha", "beta"])
        XCTAssertFalse(FeatureLog.shared.all.contains("+unavailable"))
    }

    /// install() 返回 false 同样不阻断后续能力。
    func testSkipsFeatureWhoseInstallFails() {
        let registry = TDMonitorFeatureRegistry()
        registry.register(FailingFeature.self)
        registry.register(AlphaFeature.self)

        let installed = registry.installAll(runtime: makeRuntime())

        XCTAssertEqual(installed, ["alpha"])
    }

    /// 逆序卸载：后装的先拆，避免依赖方还在用就被拆掉。
    func testUninstallsInReverseOrder() {
        let registry = TDMonitorFeatureRegistry()
        registry.register(AlphaFeature.self)
        registry.register(BetaFeature.self)
        registry.installAll(runtime: makeRuntime())
        FeatureLog.shared.reset()

        registry.uninstallAll()

        XCTAssertEqual(FeatureLog.shared.all, ["-beta", "-alpha"])
    }

    /// 重复注册同一类型应被忽略，否则会装两遍、上报翻倍。
    func testRegisteringSameTypeTwiceIsIgnored() {
        let registry = TDMonitorFeatureRegistry()
        registry.register(AlphaFeature.self)
        registry.register(AlphaFeature.self)

        let installed = registry.installAll(runtime: makeRuntime())

        XCTAssertEqual(installed, ["alpha"])
        XCTAssertEqual(FeatureLog.shared.all, ["+alpha"])
    }

    /// 没装成功的实例不能被记进 installedNames，否则自检会误报。
    func testInstalledNamesReflectsOnlySuccessfulInstall() {
        let registry = TDMonitorFeatureRegistry()
        registry.register(AlphaFeature.self)
        registry.register(UnavailableFeature.self)
        registry.installAll(runtime: makeRuntime())

        XCTAssertEqual(registry.installedNames, ["alpha"])
    }
}

// MARK: - 运行时容器

final class TDMonitorRuntimeTests: TDMonitorKitTestCase {

    func testProvideAndLookupService() {
        let runtime = makeRuntime()
        let registry = TDMonitorFeatureRegistry()
        registry.register(ServiceProviderFeature.self)
        registry.installAll(runtime: runtime)

        XCTAssertEqual(runtime.service(String.self), "hello")
    }

    func testLookupMissingServiceReturnsNil() {
        XCTAssertNil(makeRuntime().service(Int.self))
    }

    /// 安装记录必须和注册表返回的一致——自检面板读的就是这份。
    func testInstalledFeaturesAreRecorded() {
        let runtime = makeRuntime()
        let registry = TDMonitorFeatureRegistry()
        registry.register(AlphaFeature.self)
        registry.installAll(runtime: runtime)

        XCTAssertEqual(runtime.installedFeatures, ["alpha"])
    }

    /// 依赖缺失的规则必须可测：DEBUG 下走的是 assert（会终止进程），
    /// 所以把「怎么算缺失」抽成纯函数单独验证。
    func testUnmetRequirements() {
        XCTAssertEqual(
            TDMonitorFeatureRegistry.unmetRequirements(requires: [], installed: []), [])
        XCTAssertEqual(
            TDMonitorFeatureRegistry.unmetRequirements(requires: ["alpha"], installed: ["alpha"]), [])
        XCTAssertEqual(
            TDMonitorFeatureRegistry.unmetRequirements(requires: ["alpha"], installed: []), ["alpha"])
        // 只缺一个时只报那一个，不能整片报错
        XCTAssertEqual(
            TDMonitorFeatureRegistry.unmetRequirements(requires: ["alpha", "beta"], installed: ["alpha"]),
            ["beta"])
    }

    /// 装上了但依赖没装 → 必须留痕。这类故障不崩溃不报错，
    /// 表现只是「某个指标突然没数据」，没有这条记录就查不到原因。
    func testBlockedFeatureIsRecordedInReleaseToo() {
        let runtime = makeRuntime()
        let registry = TDMonitorFeatureRegistry()
        // 只注册 Beta（requires: ["alpha"]），故意不注册 Alpha。
        registry.register(BetaFeature.self)
        registry.installAll(runtime: runtime)

        XCTAssertEqual(runtime.blockedFeatures["beta"], ["alpha"])
    }
}

// MARK: - 事件封包

final class TDEventPayloadTests: TDMonitorKitTestCase {

    private func makeContext() -> TDContext {
        TDContext(config: TDMonitorConfiguration(
            baseURL: URL(string: "https://monitor.example.com")!,
            apiKey: "k", appId: "app"))
    }

    /// 服务端按 schema 校验整批，超长字段会导致整批 422，
    /// 所以客户端必须按上限截断——截断只损失自己，不截断损失整批。
    func testClampsOversizedMessage() {
        let event = TDEvent(kind: "error",
                            fields: ["message": String(repeating: "a", count: 5000)])
        let payload = event.payload(context: makeContext())

        XCTAssertEqual((payload["message"] as? String)?.count, 4_000)
    }

    func testClampsOversizedStack() {
        let event = TDEvent(kind: "native_crash",
                            fields: ["stack": String(repeating: "b", count: 80_000)])
        let payload = event.payload(context: makeContext())

        XCTAssertEqual((payload["stack"] as? String)?.count, 60_000)
    }

    func testKeepsShortFieldsUntouched() {
        let event = TDEvent(kind: "mobile_metric",
                            fields: ["name": "fps", "value": 58.4, "unit": "fps"])
        let payload = event.payload(context: makeContext())

        XCTAssertEqual(payload["name"] as? String, "fps")
        XCTAssertEqual(payload["value"] as? Double, 58.4)
        XCTAssertEqual(payload["kind"] as? String, "mobile_metric")
    }

    /// 每条事件都必须带齐维度，否则后端无法按版本 / 设备归因。
    func testPayloadCarriesBaseDimensions() {
        let context = makeContext()
        let payload = TDEvent(kind: "session_start").payload(context: context)

        XCTAssertEqual(payload["appId"] as? String, "app")
        XCTAssertEqual(payload["sessionId"] as? String, context.sessionId)
        XCTAssertNotNil(payload["deviceId"])
        XCTAssertNotNil(payload["osVersion"])
        XCTAssertNotNil(payload["ts"])
    }
}

// MARK: - 页面帧率
//
// 用 `TDManualClock` 推进窗口时长，用显式 timestamp 喂帧间隔，
// 全程不 sleep，1 毫秒内跑完——这是当初引入 `TDClock` 的全部理由。

final class TDScreenFrameSessionTests: TDMonitorKitTestCase {

    private let budget60Hz: CFTimeInterval = 1.0 / 60.0

    private func makeSession(clock: TDManualClock = TDManualClock()) -> TDScreenFrameSession {
        TDScreenFrameSession(screen: "HomeViewController", pageID: ObjectIdentifier(Self.testPage), budget: budget60Hz, clock: clock)
    }

    /// 测试用的稳定页面身份。
    static let testPage = NSObject()

    func testCountsSlowFrameWhenIntervalExceedsThreshold() {
        let session = makeSession()
        session.tick(timestamp: 1.000, expected: budget60Hz)   // 仅设基线
        session.tick(timestamp: 1.016, expected: budget60Hz)   // 正常帧（16ms < 16.95ms）
        session.tick(timestamp: 1.116, expected: budget60Hz)   // 100ms → 慢帧

        XCTAssertEqual(session.frameCount, 2)
        XCTAssertEqual(session.slowFrames, 1)
        XCTAssertEqual(session.frozenFrames, 0)
        XCTAssertGreaterThan(session.hitchMs, 80)
    }

    /// 回归：慢帧阈值必须是 `1 / (fps - 1)`，60Hz 下为 16.95ms。
    ///
    /// 曾经用的是「帧预算 × 1.5」= 25ms，结果 17~25ms 这一档
    /// （轻微但用户可感知的卡）整段漏计，慢帧率被系统性低估。
    /// 17ms 正好落在两个阈值之间，是这条修正的守门断言。
    func testSlowFrameThresholdMatchesIndustryFormula() {
        let session = makeSession()
        session.tick(timestamp: 1.000, expected: budget60Hz)
        session.tick(timestamp: 1.017, expected: budget60Hz)   // 17ms < 25ms(旧) 但 > 16.95ms(新)

        XCTAssertEqual(session.slowFrames, 1)
    }

    /// 慢帧与冻结帧互斥计数：Sentry 与 Firebase 都是这个口径，
    /// 两者相加才是「全部异常帧」。如果冻结帧同时计入慢帧，
    /// 分母不变分子重复，异常帧占比会被算高。
    func testCountsFrozenFrameAbove700ms() {
        let session = makeSession()
        session.tick(timestamp: 1.000, expected: budget60Hz)
        session.tick(timestamp: 1.800, expected: budget60Hz)   // 800ms > 700ms → 冻结帧

        XCTAssertEqual(session.slowFrames, 0)
        XCTAssertEqual(session.frozenFrames, 1)
        // 冻结帧同样计入卡顿时长，否则 hitchRatio 会漏掉最严重的那部分
        XCTAssertGreaterThan(session.hitchMs, 700)
    }

    /// 切前后台会让 displayLink 暂停后恢复，第一帧间隔是秒级。
    /// 不过滤这段，每次回前台都会记一次巨额掉帧。
    func testDiscardsDiscontinuityGap() {
        let session = makeSession()
        session.tick(timestamp: 1.000, expected: budget60Hz)
        session.tick(timestamp: 3.500, expected: budget60Hz)   // 2.5s 中断

        XCTAssertEqual(session.frameCount, 0)
        XCTAssertEqual(session.slowFrames, 0)
    }

    /// 样本太少时不产出结论，避免 100% 慢帧的假告警。
    func testTakeReportReturnsNilWhenSampleTooSmall() {
        let clock = TDManualClock()
        let session = makeSession(clock: clock)
        session.tick(timestamp: 1.000, expected: budget60Hz)
        session.tick(timestamp: 1.016, expected: budget60Hz)
        clock.advance(0.4)

        XCTAssertNil(session.takeReport(phase: "slice"))
    }

    func testTakeReportProducesRatesAndResetsWindow() {
        let clock = TDManualClock()
        let session = makeSession(clock: clock)

        // 12 帧，其中 3 帧慢帧
        var ts: CFTimeInterval = 1.0
        session.tick(timestamp: ts, expected: budget60Hz)
        for index in 0..<11 {
            ts += (index < 3) ? 0.100 : 0.016
            session.tick(timestamp: ts, expected: budget60Hz)
        }
        clock.advance(0.4)

        let report = session.takeReport(phase: "final")

        XCTAssertNotNil(report)
        XCTAssertEqual(report?.screen, "HomeViewController")
        XCTAssertEqual(report?.frameCount, 11)
        XCTAssertEqual(report?.slowFrames, 3)
        XCTAssertEqual(report?.phase, "final")
        XCTAssertEqual(report?.slowFrameRate ?? 0, 3.0 / 11 * 100, accuracy: 0.01)
        // 结算后窗口必须清零，否则下一片会把上一片的帧重复计入
        XCTAssertEqual(session.frameCount, 0)
        XCTAssertEqual(session.slowFrames, 0)
    }

    /// 120Hz 设备的帧预算不同，同一个 20ms 间隔在 60Hz 上是慢帧、在 120Hz 上更是慢帧。
    /// 这条断言守住「不要写死 16.67ms / 16.95ms」——阈值必须按实测刷新率推导。
    func testSlowFrameJudgementFollowsDeviceBudget() {
        let sixty = TDScreenFrameSession(screen: "A", pageID: ObjectIdentifier(NSObject()), budget: 1.0 / 60.0, clock: TDManualClock())
        let oneTwenty = TDScreenFrameSession(screen: "A", pageID: ObjectIdentifier(NSObject()), budget: 1.0 / 120.0, clock: TDManualClock())

        for session in [sixty, oneTwenty] {
            session.tick(timestamp: 1.000, expected: session.frameBudget)
            session.tick(timestamp: 1.020, expected: session.frameBudget)
        }

        XCTAssertEqual(sixty.slowFrames, 1)      // 20ms > 16.95ms
        XCTAssertEqual(oneTwenty.slowFrames, 1)  // 20ms > 8.40ms
    }

    /// 60Hz 下 10ms 的帧不该算慢帧——阈值放宽到 25ms 会把真正的抖动也算进来，
    /// 阈值收紧到 16.95ms 也不能把正常帧误判。这是「不要过度收紧」的边界。
    func testNormalFrameNotCountedAsSlow() {
        let session = makeSession()
        session.tick(timestamp: 1.000, expected: budget60Hz)
        session.tick(timestamp: 1.010, expected: budget60Hz)   // 10ms，正常帧

        XCTAssertEqual(session.slowFrames, 0)
        XCTAssertEqual(session.frozenFrames, 0)
        XCTAssertEqual(session.hitchMs, 0)
    }

    // MARK: - 页面语义（一处 setScreen，处处生效）

    /// 未注入语义名时回退到自动采集类名：零接入基线，页面不埋点也有数据。
    func testScreenFallsBackToClassWhenNoSemantic() {
        let session = makeSession()
        XCTAssertEqual(session.screen, "HomeViewController")
        XCTAssertEqual(session.screenClass, "HomeViewController")
    }

    /// 业务 setScreen 注入的语义名优先于类名，且类名原样保留可回溯。
    func testSemanticScreenWinsAndClassIsPreserved() {
        let clock = TDManualClock()
        let session = makeSession(clock: clock)
        session.applySemanticScreen("weather.home")

        var ts: CFTimeInterval = 1.0
        session.tick(timestamp: ts, expected: budget60Hz)
        for _ in 0..<11 {
            ts += 0.016
            session.tick(timestamp: ts, expected: budget60Hz)
        }
        clock.advance(0.4)

        let report = session.takeReport(phase: "final")
        XCTAssertNotNil(report)
        XCTAssertEqual(report?.screen, "weather.home")
        XCTAssertEqual(report?.screenClass, "HomeViewController")
    }

    /// setScreen(nil) 清除覆盖后回到自动类名，不残留上一次的语义名。
    func testScreenFallsBackAfterSemanticCleared() {
        let session = makeSession()
        session.applySemanticScreen("weather.home")
        XCTAssertEqual(session.screen, "weather.home")

        session.applySemanticScreen(nil)
        XCTAssertEqual(session.screen, "HomeViewController")
    }
}

/// 页面语义按「页面实例身份」绑定：多 tab / 同 VC 多实例时各会话只查自己的语义名，
/// 不被别的页面的 setScreen 串味。回归曾经出现的「天气首页会话被写成 finance.stock」。
final class TDScreenSemanticBindingTests: TDMonitorKitTestCase {

    func testSemanticIsolationBetweenPageInstances() {
        let context = TDScreenContext()
        let weatherPage = NSObject()
        let financePage = NSObject()

        context.update("weather.home", page: weatherPage)
        // 金融页 setScreen 传自己的实例，不能改掉天气实例的语义名
        context.update("finance.stock", page: financePage)

        XCTAssertEqual(context.semantic(for: ObjectIdentifier(weatherPage)), "weather.home")
        XCTAssertEqual(context.semantic(for: ObjectIdentifier(financePage)), "finance.stock")
        XCTAssertNil(context.semantic(for: ObjectIdentifier(NSObject())))
    }

    /// 复刻真机串味路径：天气会话已 begin，金融页在 viewDidAppear 之外切分区 setScreen。
    /// 即便那一刻栈顶还是天气类名，金融的语义名也只能写进金融实例，天气会话取自己的。
    func testFinanceSwitchSectionDoesNotPolluteWeatherSession() {
        let context = TDScreenContext()
        let weatherPage = NSObject()
        let financePage = NSObject()

        context.push("QWeatherHomeViewController")
        context.update("weather.home", page: weatherPage)
        // 金融页异步切分区：setScreen 传金融实例，此时自动栈顶仍是天气类名
        context.update("finance.stock", page: financePage)

        // 天气会话按自己的 pageID 取，仍是 weather.home，绝不串成 finance.stock
        XCTAssertEqual(context.semantic(for: ObjectIdentifier(weatherPage)), "weather.home")
        XCTAssertEqual(context.semantic(for: ObjectIdentifier(financePage)), "finance.stock")
    }

    /// 同一个 VC 承载多分区（金融首页 8 个品种）：切分区更新只影响该实例，
    /// 且取到的是最新一次 setScreen 的语义名。
    func testSemanticByPageUpdatesForSameVC() {
        let context = TDScreenContext()
        let financePage = NSObject()

        context.update("finance.stock", page: financePage)
        XCTAssertEqual(context.semantic(for: ObjectIdentifier(financePage)), "finance.stock")

        context.update("finance.fund", page: financePage)
        XCTAssertEqual(context.semantic(for: ObjectIdentifier(financePage)), "finance.fund")
    }

    /// setScreen(nil) 清除该实例的映射，会话回退到自动类名。
    func testSemanticClearedForPage() {
        let context = TDScreenContext()
        let weatherPage = NSObject()
        let pageID = ObjectIdentifier(weatherPage)

        context.update("weather.home", page: weatherPage)
        XCTAssertEqual(context.semantic(for: pageID), "weather.home")

        context.update(nil, page: weatherPage)
        XCTAssertNil(context.semantic(for: pageID))
    }

    /// 页面消失后清掉映射，避免实例地址被复用后读到旧页面的语义名。
    func testClearSemanticOnPageEnd() {
        let context = TDScreenContext()
        let page = NSObject()
        let pageID = ObjectIdentifier(page)

        context.update("weather.home", page: page)
        context.clearSemantic(for: pageID)
        XCTAssertNil(context.semantic(for: pageID))
    }
}

// MARK: - 卡顿分级

/// 看门狗主循环依赖真实主线程与墙钟，无法确定性测试；
/// 但「怎么定级」是业务契约，必须可单测。
final class TDANRGradingTests: TDMonitorKitTestCase {

    private let fatal: Double = 8_000

    /// 2s 是上报门槛（低于它的不进这条链路），8s 是致命推测门槛。
    /// 两个阈值语义不同，混成一个就会出现「2~8 秒的卡顿全丢」。
    func testSeveritySplitsAtFatalThreshold() {
        XCTAssertEqual(TDHangWatchdog.severity(durationMs: 2_000, fatalThresholdMs: fatal), "hang")
        XCTAssertEqual(TDHangWatchdog.severity(durationMs: 5_000, fatalThresholdMs: fatal), "hang")
        XCTAssertEqual(TDHangWatchdog.severity(durationMs: 7_999, fatalThresholdMs: fatal), "hang")
        XCTAssertEqual(TDHangWatchdog.severity(durationMs: 8_000, fatalThresholdMs: fatal), "fatal_suspected")
        XCTAssertEqual(TDHangWatchdog.severity(durationMs: 30_000, fatalThresholdMs: fatal), "fatal_suspected")
    }

    /// 卡顿期间一帧都没出 = 主线程完全停摆，displayLink 也不回调；
    /// 还在出帧只是慢 = 不是纯阻塞，问题在渲染链路而不是主线程被独占。
    /// 两者排查方向完全不同，不能混为一类。
    func testBlockTypeUsesFrameCountDuringHang() {
        XCTAssertEqual(TDHangWatchdog.blockType(framesDuring: 0), "fully_blocked")
        XCTAssertEqual(TDHangWatchdog.blockType(framesDuring: 1), "fully_blocked")
        XCTAssertEqual(TDHangWatchdog.blockType(framesDuring: 2), "partially_blocked")
        XCTAssertEqual(TDHangWatchdog.blockType(framesDuring: 60), "partially_blocked")
    }

    /// 同一段卡顿在恢复过程中会被结算多次，逐条上报等于把一次事故放大成 N 次。
    /// Sentry V2 用 `lastAppHangStoppedSystemTime + timeoutInterval > now` 抑制，
    /// 我们用同样的窗口。
    func testSuppressesRepeatedReportWithinWindow() {
        let threshold: Double = 2_000

        // 首次没有历史，必须允许
        XCTAssertTrue(TDHangWatchdog.shouldReport(now: 100, lastReportedAt: 0, thresholdMs: threshold))
        // 1.9s 后仍在窗口内 → 抑制
        XCTAssertFalse(TDHangWatchdog.shouldReport(now: 101.9, lastReportedAt: 100, thresholdMs: threshold))
        // 刚好 2s → 允许
        XCTAssertTrue(TDHangWatchdog.shouldReport(now: 102.0, lastReportedAt: 100, thresholdMs: threshold))
        // 远超过窗口 → 允许（连续卡顿是真实场景，不能一律吞掉）
        XCTAssertTrue(TDHangWatchdog.shouldReport(now: 130, lastReportedAt: 100, thresholdMs: threshold))
    }
}

// MARK: - 终止归因

final class TDTerminationClassifierTests: TDMonitorKitTestCase {

    private let environment = TDEnvironmentSnapshot(debuggerAttached: false, simulator: false)
    private let osVersion = "Version 18.0 (Build 22A3351)"

    private func classify(_ state: TDAppState,
                          hasLaunchedBefore: Bool = true,
                          environment: TDEnvironmentSnapshot? = nil,
                          currentAppVersion: String = "1.0.0",
                          currentBuild: String = "1") -> TDTerminationVerdict? {
        TDTerminationClassifier.classify(
            previous: state,
            currentOSVersion: osVersion,
            // 这里是「本次启动」的版本，必须能独立指定。
            // 之前写成 state.appVersion，等于把上次的版本同时当成当前版本，
            // 版本变化的分支永远不可能命中——测试因此长期处于假通过状态。
            currentAppVersion: currentAppVersion,
            currentBuild: currentBuild,
            hasLaunchedBefore: hasLaunchedBefore,
            environment: environment ?? self.environment)
    }

    private func makeState(
        cleanExit: Bool = false,
        debuggerAttached: Bool = false,
        simulator: Bool = false,
        maxHangMs: Double = 0,
        foreground: Bool = true,
        lastFootprintMb: Double? = nil,
        limitMb: Double? = nil,
        availableMb: Double? = nil,
        backgroundTaskCount: Int = 0,
        hadMemoryWarning: Bool = false,
        memoryWarningCount: Int = 0,
        osVersion: String? = nil,
        appVersion: String = "1.0.0",
        buildNumber: String = "1"
    ) -> TDAppState {
        TDAppState(
            sessionId: "session",
            startedAt: Date(timeIntervalSince1970: 0),
            lastAliveAt: Date(timeIntervalSince1970: 100),
            lastScreen: "HomeViewController",
            foreground: foreground,
            backgroundEnteredAt: nil,
            backgroundTaskCount: backgroundTaskCount,
            cleanExit: cleanExit,
            exitInitiator: nil,
            hadMemoryWarning: hadMemoryWarning,
            memoryWarningCount: memoryWarningCount,
            peakFootprintMb: lastFootprintMb ?? 0,
            footprintSeries: [],
            lastFootprintMb: lastFootprintMb,
            limitMb: limitMb,
            availableMb: availableMb,
            maxHangMs: maxHangMs,
            osVersion: osVersion ?? self.osVersion,
            appVersion: appVersion,
            buildNumber: buildNumber,
            debuggerAttached: debuggerAttached,
            simulator: simulator)
    }

    // 排除项：这些情况下不该产生任何归因，否则会把强杀 / 开发机 / 发版日
    // 全部算成 OOM，指标直接失去意义。

    func testCleanExitProducesNoVerdict() {
        XCTAssertNil(classify(makeState(cleanExit: true, maxHangMs: 30_000)))
    }

    func testDebuggerAttachedProducesNoVerdict() {
        XCTAssertNil(classify(makeState(debuggerAttached: true, maxHangMs: 30_000)))
        XCTAssertNil(classify(makeState(maxHangMs: 30_000),
                              environment: TDEnvironmentSnapshot(debuggerAttached: true, simulator: false)))
    }

    func testSimulatorProducesNoVerdict() {
        XCTAssertNil(classify(makeState(simulator: true, maxHangMs: 30_000)))
        XCTAssertNil(classify(makeState(maxHangMs: 30_000),
                              environment: TDEnvironmentSnapshot(debuggerAttached: false, simulator: true)))
    }

    func testFirstLaunchProducesNoVerdict() {
        XCTAssertNil(classify(makeState(maxHangMs: 30_000), hasLaunchedBefore: false))
    }

    /// 发版当天所有进程都会重建，上一次现场不能算到新版本头上。
    /// 三家都有这条排除：Sentry `currentRelease != previousRelease → return false`，
    /// Datadog `previous.appVersion == current.appVersion` 的 guard。
    func testVersionChangeProducesNoVerdict() {
        // OS 升级
        XCTAssertNil(classify(makeState(maxHangMs: 30_000, osVersion: "Version 17.0 (Build 21A1)")))
        // app 版本变化
        XCTAssertNil(classify(makeState(maxHangMs: 30_000), currentAppVersion: "0.9.0"))
        // build 号变化（同版本重打包，最容易漏掉的一种）
        XCTAssertNil(classify(makeState(maxHangMs: 30_000), currentBuild: "999"))
        // 反向断言：版本一致时必须能正常归因，否则上面的 nil 可能只是「全都不报」的假象
        XCTAssertNotNil(classify(makeState(maxHangMs: 30_000)))
    }

    // 判定链

    func testWatchdogWhenForegroundAndHangExceedsThreshold() {
        let verdict = classify(makeState(maxHangMs: 9_000, foreground: true))

        XCTAssertEqual(verdict?.attribution, .watchdog)
        XCTAssertEqual(verdict?.confidence ?? 0, 0.8, accuracy: 0.001)
    }

    /// 后台长时间无响应不一定是看门狗杀的，不能套用同一条规则。
    func testHangInBackgroundIsNotWatchdog() {
        let verdict = classify(makeState(maxHangMs: 9_000, foreground: false))

        XCTAssertNotEqual(verdict?.attribution, .watchdog)
    }

    func testJetsamWhenFootprintNearLimit() {
        let verdict = classify(makeState(lastFootprintMb: 900, limitMb: 1_000))

        XCTAssertEqual(verdict?.attribution, .jetsam)
    }

    /// 内存只是接近但没到 0.85，不能判成 jetsam——长会话内存高是常态。
    func testJetsamNotTriggeredBelowRatioThreshold() {
        let verdict = classify(makeState(lastFootprintMb: 700, limitMb: 1_000))

        XCTAssertEqual(verdict?.attribution, .unknown)
    }

    /// 部分设备拿不到 limit，退化为「可用内存极低」判据。
    func testJetsamFallbackWhenAvailableMemoryIsCritical() {
        let verdict = classify(makeState(availableMb: 20))

        XCTAssertEqual(verdict?.attribution, .jetsam)
        XCTAssertEqual(verdict?.confidence ?? 0, 0.7, accuracy: 0.001)
    }

    func testBackgroundTaskTimeoutWhenInBackgroundWithPendingTask() {
        let verdict = classify(makeState(foreground: false, backgroundTaskCount: 1))

        XCTAssertEqual(verdict?.attribution, .backgroundTaskTimeout)
    }

    func testMemoryPressureWhenOnlyMemoryWarnings() {
        let verdict = classify(makeState(hadMemoryWarning: true, memoryWarningCount: 2))

        XCTAssertEqual(verdict?.attribution, .memoryPressure)
    }

    /// 证据不足时必须报 unknown，**不能**猜成 OOM 或 watchdog。
    /// 把强杀算成 OOM 会让整个 OOM 率失真，宁可数据少也不要数据假。
    func testUnknownWhenNoEvidence() {
        let verdict = classify(makeState())

        XCTAssertEqual(verdict?.attribution, .unknown)
        XCTAssertEqual(verdict?.confidence ?? 1, 0.2, accuracy: 0.001)
    }

    /// 每条归因都要留下可复查的证据，否则线上只能看到结论、看不到依据。
    func testVerdictCarriesEvidence() {
        let verdict = classify(makeState(maxHangMs: 9_000, lastFootprintMb: 900, limitMb: 1_000))

        XCTAssertNotNil(verdict)
        XCTAssertTrue(verdict!.reasons.contains { $0.hasPrefix("maxHang=") })
        XCTAssertTrue(verdict!.reasons.contains { $0.hasPrefix("peakFootprint=") })
    }
}

// MARK: - 传输层：退避策略

/// 退避必须是**可算的**，不能靠真跑流量去撞。
///
/// 旧实现的退避写在异步网络回调里，改一个系数没有验证手段，实际上等于没人敢改；
/// 更糟的是它只延迟了「回调返回」，重发时机仍由固定 10s timer 决定——
/// 所谓指数退避从未生效过。抽成纯函数之后，这件事变成三条断言。
final class TDRetryPolicyTests: TDMonitorKitTestCase {

    func testDelayDoublesUntilCap() {
        let policy = TDRetryPolicy()
        var delay = policy.initialDelay
        var seen: [TimeInterval] = []
        for _ in 0..<7 {
            delay = policy.nextDelay(current: delay)
            seen.append(delay)
        }
        XCTAssertEqual(seen, [0.5, 1, 2, 4, 8, 8, 8])
    }

    /// 一旦全成功就必须回到起点。
    /// 不重置的话，一次网络抖动会让该进程之后所有重试都等 8 秒。
    func testResetsAfterFullSuccess() {
        let policy = TDRetryPolicy()
        XCTAssertEqual(policy.delay(for: [.accepted, .dropped], current: 8), policy.initialDelay)
    }

    /// 只要有一条待重试，就要继续拉长等待。
    func testKeepsEscalatingWhenAnyRetry() {
        let policy = TDRetryPolicy()
        XCTAssertEqual(policy.delay(for: [.accepted, .retry], current: 1), 2)
        XCTAssertEqual(policy.delay(for: [.retry], current: 8), 8)
    }
}

// MARK: - 传输层：毒数据隔离

final class FakeUploader: TDBatchUploader {

    enum Behavior {
        case succeed
        case reject(poisonIDs: Set<String>)
        case unauthorized
        case alwaysRetry
    }

    private let behavior: Behavior
    private let lock = NSLock()
    private(set) var requestCount = 0

    init(behavior: Behavior = .succeed) {
        self.behavior = behavior
    }

    func upload(_ payloads: [[String: Any]], completion: @escaping (TDUploadOutcome) -> Void) {
        lock.lock(); requestCount += 1; lock.unlock()

        switch behavior {
        case .succeed:
            completion(.accepted)
        case let .reject(poisonIDs):
            let hasPoison = payloads.contains { poisonIDs.contains($0["id"] as? String ?? "") }
            if hasPoison {
                completion(.rejected(status: 422, body: "schema violation"))
            } else {
                completion(.accepted)
            }
        case .unauthorized:
            completion(.unauthorized(status: 401, body: "api key revoked"))
        case .alwaysRetry:
            completion(.retryable(reason: "timeout"))
        }
    }
}

final class TDBatchResolverTests: TDMonitorKitTestCase {

    private func batch(_ ids: [String]) -> [[String: Any]] {
        ids.map { ["id": $0, "kind": "mobile_metric"] }
    }

    /// 整批干净时只能发一次请求——隔离逻辑不能给正常路径增加任何成本。
    func testCleanBatchUsesSingleRequest() {
        let uploader = FakeUploader()
        let resolver = TDBatchResolver(uploader: uploader)
        let done = expectation(description: "resolved")

        resolver.resolve(batch(["a", "b", "c"])) { outcomes in
            XCTAssertEqual(outcomes, [.accepted, .accepted, .accepted])
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(uploader.requestCount, 1)
    }

    /// 一条脏数据不能带走同批其余事件。这是这一层存在的全部理由：
    /// 服务端按整批校验，整批丢弃会让数据面形成**永久**缺口（下次还是同一条继续丢）。
    func testPoisonEventIsIsolatedNotWholeBatch() {
        let uploader = FakeUploader(behavior: .reject(poisonIDs: ["b"]))
        let lock = NSLock()
        var rejected: [[String: Any]] = []
        let resolver = TDBatchResolver(uploader: uploader, onReject: { payload, status, body in
            lock.lock(); rejected.append(payload); lock.unlock()
            XCTAssertEqual(status, 422)
            XCTAssertFalse(body.isEmpty)
        })
        let done = expectation(description: "resolved")

        resolver.resolve(batch(["a", "b", "c", "d"])) { outcomes in
            XCTAssertEqual(outcomes, [.accepted, .dropped, .accepted, .accepted])
            done.fulfill()
        }
        wait(for: [done], timeout: 3)

        XCTAssertEqual(rejected.count, 1, "只应丢掉真正被拒的那一条")
        XCTAssertEqual(rejected.first?["id"] as? String, "b")
    }

    /// 凭据问题跟内容无关，二分只会把请求量放大 20 倍去证明同一个结论。
    func testUnauthorizedDoesNotBisect() {
        let uploader = FakeUploader(behavior: .unauthorized)
        var authFailureCount = 0
        let resolver = TDBatchResolver(uploader: uploader, onAuthFailure: { status, _, count in
            XCTAssertEqual(status, 401)
            XCTAssertEqual(count, 4)
            authFailureCount += 1
        })
        let done = expectation(description: "resolved")

        resolver.resolve(batch(["a", "b", "c", "d"])) { outcomes in
            XCTAssertEqual(outcomes, Array(repeating: .dropped, count: 4))
            done.fulfill()
        }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(uploader.requestCount, 1)
        XCTAssertEqual(authFailureCount, 1)
    }

    /// 网络问题不是内容问题：整批原样重试，一条都不能丢。
    func testRetryableKeepsWholeBatch() {
        let uploader = FakeUploader(behavior: .alwaysRetry)
        let resolver = TDBatchResolver(uploader: uploader)
        let done = expectation(description: "resolved")

        resolver.resolve(batch(["a", "b", "c"])) { outcomes in
            XCTAssertEqual(outcomes, Array(repeating: .retry, count: 3))
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(uploader.requestCount, 1, "重试不需要二分")
    }

    /// 整批全坏时二分是 2n 个请求。不设预算，一次故障就是一场请求风暴。
    func testIsolationBudgetIsEnforced() {
        let allPoison: Set<String> = Set((0..<16).map { "p\($0)" })
        let uploader = FakeUploader(behavior: .reject(poisonIDs: allPoison))
        let resolver = TDBatchResolver(uploader: uploader, isolationBudget: 3)
        let done = expectation(description: "resolved")

        resolver.resolve(batch(Array(allPoison))) { outcomes in
            XCTAssertTrue(outcomes.allSatisfy { $0 == .dropped || $0 == .accepted })
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertLessThanOrEqual(uploader.requestCount, 1 + 3 + 4,
                                 "预算只允许少量额外请求，不能无限二分")
    }
}

// MARK: - OOM 时间线

final class TDTimelineTests: TDMonitorKitTestCase {

    private func makeState() -> TDAppState {
        TDAppState(sessionId: "s", startedAt: Date(), lastAliveAt: Date(), lastScreen: nil,
                   foreground: true, backgroundEnteredAt: nil, backgroundTaskCount: 0,
                   cleanExit: false, exitInitiator: nil,
                   hadMemoryWarning: false, memoryWarningCount: 0, peakFootprintMb: 0,
                   footprintSeries: [], timeline: [],
                   lastFootprintMb: nil, limitMb: nil, availableMb: nil,
                   maxHangMs: 0, osVersion: "iOS 17.0", appVersion: "1.0", buildNumber: "1",
                   debuggerAttached: false, simulator: true)
    }

    /// 线上体积敏感：键名压到一个字母，整数毫秒，数值保留一位小数。
    func testEntrySerializesCompactly() {
        let entry = TDTimelineEntry(offsetMs: 12_345.6, kind: .memory, value: 823.44, label: nil)
        let json = entry.asJSON

        XCTAssertEqual(json["t"] as? Int, 12_346)
        XCTAssertEqual(json["k"] as? String, "memory")
        XCTAssertEqual(json["v"] as? Double, 823.4)
        XCTAssertNil(json["l"])
    }

    func testScreenEntryCarriesLabel() {
        let entry = TDTimelineEntry(offsetMs: 100, kind: .screen, value: nil, label: "TBFinanceHome")
        XCTAssertEqual(entry.asJSON["l"] as? String, "TBFinanceHome")
        XCTAssertNil(entry.asJSON["v"])
    }

    /// 时间线是因果链，不能无限增长。超出容量时丢最旧的，保留死亡前的现场。
    func testTimelineKeepsLatestAndDropsOldest() {
        var state = makeState()
        for index in 0..<(TDAppState.maxTimelinePoints + 30) {
            TDAppStateTracker.appendTimeline(&state, kind: .memory,
                                             value: Double(index), label: nil)
        }
        let entries = state.timelineEntries
        XCTAssertEqual(entries.count, TDAppState.maxTimelinePoints)
        XCTAssertEqual(entries.last?.value, Double(TDAppState.maxTimelinePoints + 30 - 1))
    }

    /// 老版本落盘的 state 没有 timeline 键，解码不能失败——
    /// 否则升级当天全部终止归因失效。
    func testStateWithoutTimelineDecodes() throws {
        var dict: [String: Any] = [
            "sessionId": "s",
            "startedAt": ISO8601DateFormatter().string(from: Date()),
            "lastAliveAt": ISO8601DateFormatter().string(from: Date()),
            "foreground": true,
            "backgroundTaskCount": 0,
            "cleanExit": false,
            "hadMemoryWarning": false,
            "memoryWarningCount": 0,
            "peakFootprintMb": 0,
            "footprintSeries": [Double](),
            "maxHangMs": 0,
            "osVersion": "iOS 17.0",
            "appVersion": "1.0",
            "buildNumber": "1",
            "debuggerAttached": false,
            "simulator": true,
        ]
        dict["timeline"] = nil

        let data = try JSONSerialization.data(withJSONObject: dict)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(TDAppState.self, from: data)
        XCTAssertTrue(state.timelineEntries.isEmpty)
    }
}

// MARK: - 接入自检

final class TDIntakeSelfCheckTests: TDMonitorKitTestCase {

    private func makeConfig(baseURL: String = "https://monitor.example.com",
                            apiKey: String = "k",
                            sampleRate: Double = 1) -> TDMonitorConfiguration {
        TDMonitorConfiguration(baseURL: URL(string: baseURL)!,
                               apiKey: apiKey,
                               appId: "app",
                               sampleRate: sampleRate)
    }

    /// 崩溃补发是唯一「不配就彻底没数据、而且不报错」的能力。
    /// 这条必须被点名，否则线上只会看到「崩溃率 0」并以为是好事。
    func testMissingCrashReportPathsIsBlocking() {
        let findings = TDIntakeSelfCheck.run(configuration: makeConfig(),
                                             crashReportsConfigured: false,
                                             isDebugBuild: true)
        let crash = findings.first { $0.item == "crash_reports" }
        XCTAssertNotNil(crash)
        XCTAssertEqual(crash?.level, .blocking)
    }

    func testCleanConfigurationProducesNoFindings() {
        let findings = TDIntakeSelfCheck.run(configuration: makeConfig(),
                                             crashReportsConfigured: true,
                                             isDebugBuild: false)
        XCTAssertTrue(findings.isEmpty, "没问题时不能制造噪声：\(findings)")
        XCTAssertNil(TDIntakeSelfCheck.summary(findings))
    }

    /// Release 下明文 HTTP 会被 ATS 拦掉，表现同样是「没有数据」。
    func testPlainHTTPInReleaseIsWarning() {
        let findings = TDIntakeSelfCheck.run(
            configuration: makeConfig(baseURL: "http://monitor.example.com"),
            crashReportsConfigured: true,
            isDebugBuild: false)
        XCTAssertTrue(findings.contains { $0.item == "transport_security" })
    }

    /// 内网联调用 HTTP 是正常做法，Debug 下不该报。
    func testPlainHTTPInDebugIsSilent() {
        let findings = TDIntakeSelfCheck.run(
            configuration: makeConfig(baseURL: "http://10.0.0.8:3000"),
            crashReportsConfigured: true,
            isDebugBuild: true)
        XCTAssertFalse(findings.contains { $0.item == "transport_security" })
    }

    func testLocalhostIngestIsFlagged() {
        let findings = TDIntakeSelfCheck.run(
            configuration: makeConfig(baseURL: "http://localhost:3000"),
            crashReportsConfigured: true,
            isDebugBuild: true)
        XCTAssertTrue(findings.contains { $0.item == "ingest_host" })
    }

    /// 摘要要把 blocking 的数量说清楚，否则一条 warning 混在里面会被忽略。
    func testSummaryHighlightsBlockingCount() {
        let findings = TDIntakeSelfCheck.run(configuration: makeConfig(apiKey: ""),
                                             crashReportsConfigured: false,
                                             isDebugBuild: false)
        let summary = TDIntakeSelfCheck.summary(findings)
        XCTAssertNotNil(summary)
        XCTAssertTrue(summary!.contains("会导致数据缺失"))
    }
}
