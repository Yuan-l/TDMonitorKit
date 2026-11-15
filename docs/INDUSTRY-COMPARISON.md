# 业界方案横向对比（ANR / OOM / 崩溃 / 帧率）

> 用途：为三项待定决策提供可核对的事实依据，而不是"业界通常"这类无法验证的说法。
> 抓取时间：2026-11-14。抓取方式：直接拉取各仓库 `main`/`develop`/`master` 分支源码文件。
> 每条结论后面都标了**文件路径 + 关键常量**，可以逐条复核。

---

## 0. 调研范围

| SDK | 仓库 / 分支 | 核实方式 |
|---|---|---|
| Sentry Cocoa | `getsentry/sentry-cocoa` @ `main` | 源码（Objective-C + Swift） |
| Datadog iOS | `DataDog/dd-sdk-ios` @ `develop` | 源码（Swift） |
| Matrix（微信） | `Tencent/matrix` @ `master` | 源码（Objective-C++ / C++） |
| Firebase Performance | `firebase/firebase-ios-sdk` @ `main` | 源码（Objective-C） |
| Firebase Crashlytics | 同上 | **公开仓库中不含实现**，仅能用官方文档，本文不引用其内部机制 |

Matrix 的 iOS 侧只有三个插件：`WCCrashBlockMonitor`（卡顿/崩溃）、`WCFPSMonitor`（帧率）、`WCMemoryStat`（内存分配）。它**没有 iOS 侧的 OOM 归因模块**——OOM 归因是 Android 侧的能力。

---

## 1. ANR（主线程卡死）

### 1.1 四家实现对照

| 项 | Sentry V1 | Sentry V2（当前主用） | Datadog | Matrix iOS | TDMonitorKit 现状 |
|---|---|---|---|---|---|
| 检测线程 | 独立线程 `io.sentry.app-hang-tracker` | 同左 | 独立 watchdog 线程 | **无独立线程**，主线程 RunLoop observer | 独立线程 |
| 判定手法 | 后台线程往主线程投 block，累计 tick 数 | 后台线程投 block **+ 查 FramesTracker 帧延迟** | 往主队列投 task + semaphore 测等待时长 | `BeforeSources` → `AfterWaiting` 间隔 | semaphore ping |
| 判定阈值 | `appHangTimeoutInterval` | 同左 | `appHangThreshold`（构造参数） | `runloopTimeOut` | `watchdogHangThresholdMs = 8_000` |
| 默认值 | **2.0s**（`Options.defaultAppHangTimeoutInterval`） | 2.0s | 由配置传入 | **2s**（`g_defaultRunLoopTimeOut = 2 * BM_MicroFormat_Second`） | 8s |
| 轮询粒度 | `timeout / 5` = 400ms | 同左 | `threshold × 2.5%` = 50ms（`Constants.tolerance = 0.025`） | `perStackInterval = 50ms`（`g_defaultPerStackInterval`） | 50ms 采样 |
| 完全/非完全阻塞 | ❌ | ✅ `framesContributingToDelayCount == 1` | ❌ | ❌ | ❌ |
| hang 分类 | 单一 | **5 类** | 2 类（fatal / non-fatal） | 按时长分档 + CPU 采样 | 无分类，只有时长 |
| 误报防护 | 后台/挂起 `delta >= timeout` 丢弃 | 同左 + 1 分钟内不重复报 | `falsePositiveThreshold = 30s` | 主/子线程过滤、CPU 使用率 | 调试器 / 模拟器 |

**逐条出处**

- `Sources/Swift/Options.swift:690` → `static let defaultAppHangTimeoutInterval: TimeInterval = 2.0`
- `Sources/Swift/Integrations/AppHangTracking/SentryANRTrackerV1.swift:63` → `let reportThreshold: Int32 = 5`，`:64` → `let sleepInterval = timeoutInterval / Double(reportThreshold)`
- `Sources/Swift/Integrations/AppHangTracking/SentryANRTrackerV2.swift:158` → `let isFullyBlocking = framesDelayForTimeInterval.framesContributingToDelayCount == 1`
- `Sources/Swift/Integrations/AppHangTracking/SentryANRTrackerV2.swift:166` → `let nonFullyBlockingFramesDelayThreshold = timeoutInterval * 0.99`
- `DatadogRUM/Sources/Instrumentation/AppHangs/AppHangsWatchdogThread.swift:39` → `static let tolerance: Double = 0.025`
- `DatadogRUM/Sources/Instrumentation/AppHangs/AppHangsWatchdogThread.swift:45` → `static let falsePositiveThreshold: TimeInterval = 30`
- `Tencent/matrix/.../WCBlockMonitorConfiguration.h:23` → `g_defaultRunLoopTimeOut = 2 * BM_MicroFormat_Second`
- `Tencent/matrix/.../WCBlockMonitorConfiguration.h:25` → `g_defaultPerStackInterval = 50 * BM_MicroFormat_MillSecond`

### 1.2 Sentry 的 5 类是怎么分的

`SentryAppHangTypeMapper.swift` 里的 `ExceptionType`：

```
App Hang Fully Blocked
App Hang Non Fully Blocked
Fatal App Hang Fully Blocked
Fatal App Hang Non Fully Blocked
App Hanging                (unknown)
```

并把 non-fatal 升级为 fatal：

```swift
public static func getFatalExceptionType(nonFatalErrorType: String) -> String {
    if nonFatalErrorType == ExceptionType.nonFullyBlocking.rawValue {
        return ExceptionType.fatalNonFullyBlocking.rawValue
    }
    return ExceptionType.fatalFullyBlocking.rawValue
}
```

**「Fully Blocked」的判定是 `framesContributingToDelayCount == 1`**：主线程完全卡住时，只有一个帧在贡献延迟；主线程还在跑但渲染慢时，会有多个帧共同贡献。这是用帧数据反推阻塞性质，比单纯测时长精细一个量级。

### 1.3 关键区别：**「卡了」和「被系统杀了」是两个阈值**

这是本次调研最重要的发现，也是我们目前最大的概念错误。

- Sentry：2s 判 **hang**（体验问题，报 non-fatal）；进程被杀走 **WatchdogTermination** 另一条链路。
- Datadog：`appHangThreshold` 判 hang；`FatalAppHangsHandler` 把**未结束的 hang 落盘**，下次启动时作为 `error: .hang` 的 fatal 上报，附 `backtraceResult.stack / threads / binaryImages`。
- Matrix：2s 判卡顿；卡顿数据独立文件，下次启动补报。

**我们现状**：只有一个 8s 阈值，超了就归因为 watchdog。结果是——
1. 2s~8s 之间的卡顿（用户明确感知到卡）**完全不上报**；
2. 一旦上报就直接是"被系统杀"，没有"卡了但没死"这一档。

### 1.4 结论

业界在 ANR 上的共识是四件事：**独立观察线程 + 显式阈值 + hang/fatal 两段式 + 误报剔除**。分歧只有一处：Matrix 用 RunLoop observer（省电但有盲区），Sentry/Datadog 用主动投递（有开销但覆盖全）。

真正需要决策的不是"ping 还是 observer"，而是：**是否补上 2s 的 hang 上报档，把 8s 留给致命归因。** 这个改动不影响现有架构，只是多加一条上报路径。

---

## 2. OOM / 进程被系统杀

### 2.1 对照

| 项 | Sentry | Datadog | Matrix iOS | TDMonitorKit 现状 |
|---|---|---|---|---|
| 主路径 | 上次会话 AppState 落盘 + 启发式 | `WatchdogTerminationChecker` | `WCMemoryStat`（malloc/对象分配钩子） | MetricKit + 启发式双源 |
| 结论口径 | **统一 1 档** `WatchdogTermination` | **统一 1 档** Watchdog Termination | 不做归因，做**分配归因** | **5 档**：jetsam / watchdog / backgroundTaskTimeout / memoryPressure / unknown_unclean |
| 是否区分 jetsam 与 watchdog | ❌ | ❌ | — | ✅ |
| 排除条件 | 模拟器、release 变化、OS 升级、设备重启、调试器 | synthetics、debugging、appVersion、wasTerminated、osVersion、systemBootTime、vendorId、processId、isActive | — | 调试器、模拟器、首次启动、版本变化 |
| 内存序列 | AppState 带内存字段 | AppState 带内存 | **对象级分配栈** | 60 点环形，5s 间隔 |

**出处**

- `Sources/Swift/Integrations/WatchdogTerminations/SentryWatchdogTerminationConstants.swift`：
  ```swift
  ExceptionType  = "WatchdogTermination"
  ExceptionValue = "The OS watchdog terminated your app, possibly because it overused RAM."
  MechanismType  = "watchdog_termination"
  ```
- `SentryWatchdogTerminationLogic.swift` 的 guard 序列：`isSimulatorBuild` → release 变化 → `osVersion` 变化 → `systemBootTimestamp` 变化 → …
- `DatadogRUM/Sources/Instrumentation/WatchdogTerminations/WatchdogTerminationChecker.swift:69–121`，9 个 guard，与本项目已有排除项高度重合。
- `DatadogRUM/Sources/Instrumentation/AppHangs/FatalAppHangsHandler.swift`：pending hang 落盘 → 下次启动升级 fatal。
- `Tencent/matrix/.../WCMemoryStat/MemoryLogger/ObjectEvent/nsobject_hook.mm` + `allocation_event_db.cpp` + `StackFrames/stack_frames_db.cpp`：C++ 级分配事件与调用栈数据库。

### 2.2 两家为什么只给 1 档

Sentry 的措辞是 **"possibly because it overused RAM"**——用 `possibly` 是因为它**没有证据**，只有"没干净退出 + 不是已知排除场景"这个推断。Datadog 同理。

它们选择统一口径，是为了**不制造无法证伪的结论**。而我们的 5 档细分，本质是把推断包装成了结论。

**但这里有个真实的取舍**：5 档在排查时有价值（"这波 OOM 是后台任务超时，不是内存"，方向完全不同）。业界不给，是因为无法证明；我们给，是因为内部平台可以接受"带置信度的推断"，只要**标注清楚这是推断**。

### 2.3 我们与业界的实质差距：不在归因，在「证据」

Sentry/Datadog 的归因同样是推断，它们在归因之外补的是**证据**：
- Sentry：崩溃前 breadcrumbs + AppState（内存、前后台、最后页面）
- Datadog：同上 + RUM view 上下文
- Matrix：**对象级分配栈**（能回答"谁吃的内存"）

我们目前只有"60 点 footprint 序列 + 内存警告标记"——只能回答"是不是 OOM"，回答不了"为什么"。

### 2.4 结论

- **归因口径**：业界统一 1 档；我们 5 档更细但必须标注"推断"。两者都能接受，**不需要推翻**。
- **真正的缺口**：没有分配级证据。Matrix 的 `WCMemoryStat` 证明了这是可工程化实现的（C++ 分配钩子 + 栈 hash 库），但代价是启动与运行时开销，且会与宿主已有的内存工具冲突。
- **低成本可补的一档**：内存警告 → 前后台切换 → 页面栈序列，让归因"有上下文"而不是只有一个结论。这部分不引入 hook，风险为零。

### 2.5 MetricKit 在业界的位置（2026-11 更正）

上表「TDMonitorKit 现状 = MetricKit + 启发式双源」容易被读成「业界也这么双源」，不是。
两家的 OOM 主路径都是**纯启发式**：Sentry `enableWatchdogTerminationTracking`（默认开）、
Datadog `trackWatchdogTerminations`（默认关、需显式开启），都不读 `MXAppExitMetric`。

Sentry 确实有 `MetricKitIntegration`，但它是 `enableMetricKit` **默认 false** 的 opt-in 集成，
且只收 hang / 磁盘写入异常 / CPU 异常三类诊断，与 OOM 计数无关。Datadog 只在文档里
借用 MetricKit 的 hang rate 定义（>250ms）说明自家阈值口径。

所以我们的「双源」是**自己多跑了一条补充源**，不是行业标准做法；它有价值（系统侧权威交叉验证），
但覆盖率天然不满。真机上 `metrickitPayloads` 长期为 0 就是直接证据。对外 OOM 率只能取启发式路径。

---

## 3. 崩溃采集

| 项 | Sentry | Datadog | Matrix | Crashlytics | TDMonitorKit |
|---|---|---|---|---|---|
| 是否自接管 handler | ✅ 内置 KSCrash | ✅ 内置 | ✅ KSCrash | ✅（闭源） | ❌ **依赖宿主 TBCrashReporter** |
| 覆盖信号 | signal / NSException / mach / C++ | 同左 | 同左 | 同左 | 宿主决定 |
| 崩溃时落盘 | 自己写 | 自己写 | 自己写 | 自己写 | 宿主写，SDK 补发 |

**四家全部自己接管。我们是唯一不接管的。**

这不是技术判断，是接入约束：宿主 `TBCrashReporter` 已经注册了 signal handler，再注册会顶掉它（iOS 上同类 handler 后注册的生效）。所以当前崩溃数据的质量**完全取决于宿主**，且宿主出问题时我们**无感知**。

### 结论

「自接管」是行业标准做法，但迁移成本高（signal-safe 代码 + 必须移除宿主 handler + 全量回归）。当前阶段的合理选择是**不接管，但把"宿主没抓到"变成可观测指标**（每次启动检查：上次异常退出 && 无崩溃文件 → 上报 `crash_pipeline_missing`）。这样缺口有数字，而不是静默。

---

## 4. 页面帧率

| 项 | Sentry | Firebase Performance | TDMonitorKit 现状 |
|---|---|---|---|
| 慢帧阈值 | `1.0 / (actualFPS - 1)` → 60fps 时 **16.95ms** | `1.0 / 59.0` = **16.95ms**（iOS 固定） | 帧预算 × 1.5 = **25ms** @60fps |
| 冻结帧阈值 | `0.7s` | `700/1000` = `0.7s` | 0.7s ✅ |
| 计数口径 | `frames_slow` / `frames_frozen` + 时间序列 | `_fr_slo` / `_fr_fzn` / `_fr_tot` | `slowFrameRate` / `frozenFrameRate` / `hitchRatio` |
| 统计单位 | 全局（非页面） | **每 VC 一条 trace** | 每 VC 一个会话 ✅ |
| UI 门控 | — | `view.window.keyWindow` | ✅ 已补 |

**出处**

- `Sources/Swift/Core/Integrations/FramesTracking/SentryFramesTracker.swift:63` → `private static let frozenFrameThreshold: CFTimeInterval = 0.7`
- 同文件 `static func slowFrameThreshold`：`return 1.0 / CFTimeInterval(actualFramesPerSecond - 1)`，注释说明"减一是因为多数帧会比理论时长多几微秒，否则几乎所有帧都会被算成慢帧"
- `FirebasePerformance/Sources/AppActivity/FPRScreenTraceTracker.m:32` → `kFPRSlowFrameThreshold = 1.0 / 59.0; // Anything less than 59 FPS is slow.`
- 同文件 `:33` → `kFPRFrozenFrameThreshold = 700.0 / 1000.0`
- 同文件 `:24–26` → 计数器名 `_fr_fzn` / `_fr_slo` / `_fr_tot`

### 4.1 我们这里存在一个真实偏差

Sentry 与 Firebase 的慢帧阈值**都是 16.95ms**（= 1/59）。我们用的是 `1/60 × 1.5 = 25ms`。

**25ms vs 16.95ms，我们宽松了 47%。** 这意味着：帧耗时在 17~25ms 之间的帧——恰好是"轻微但可感知"的那一档——我们全部不计入慢帧。慢帧率会被系统性低估。

这个偏差是我自己在实现时拍的系数，没有任何依据。**建议改为 `1.0 / (actualFPS - 1)`，与 Sentry 完全一致**，并按实测刷新率取值（120Hz 设备自然得到 1/119）。

### 4.2 `hitchRatio` 的定位问题

Sentry 用 `frames_slow` / `frames_frozen` 两个计数，Firebase 用三个计数。**两家都没有"卡顿时长占比"这个指标。**

我们的 `hitchRatio` 是自有合成指标，好处是对偶发长卡更敏感，坏处是**无法与任何外部基准比较**，也无法跨团队对齐口径。

建议：保留 `hitchRatio` 但降级为辅助字段，**主指标改为 `slowFrameRate` / `frozenFrameRate`**（与两家同构），并在文档中明确标注 hitchRatio 不可横向比较。

---

## 5. 汇总：三项待定的真实决策点

把上面的材料压缩成"到底要决策什么"：

| 决策项 | 业界现状 | 真正需要拍板的 | 我的建议 |
|---|---|---|---|
| **ANR** | 三家都是「独立检测 + 显式阈值 + hang/fatal 两段式」；2s 判 hang | 不是"ping 还是 observer"（伪选择题），而是**要不要补 2s 的 hang 上报档** | 补。8s 保留给致命归因，2s 用于体验卡顿。改动小、收益直接 |
| **OOM** | Sentry/Datadog 统一 1 档；Matrix 做分配级证据 | 不是"双源还是单源"（双源已是业界上限），而是**要不要投入分配级证据（malloc hook）** | 不投入 hook（风险与冲突成本高）；改为补"内存警告 + 页面栈 + 前后台"的上下文证据，零风险 |
| **崩溃** | 四家全部自接管 | 不是"接管还是不接管"（不接管是接入约束，不是选择），而是**要不要把宿主捕获缺口变成指标** | 补 `crash_pipeline_missing` 自检。成本一个计数，收益是缺口可观测 |

另外有 **一条不需要决策、直接改**的项：

| 项 | 现状 | 业界 | 动作 |
|---|---|---|---|
| 慢帧阈值 | 25ms（帧预算×1.5） | 16.95ms（`1/(fps-1)`） | 改为 `1/(actualFPS-1)`，与 Sentry 一致 |

---

## 6. 我此前判断中「没有业界依据」的部分（必须标明）

避免用"业界"给自有设计背书：

1. **30s 切片上报**：Firebase 只在 `viewDidDisappear` 结算，长停留页面永远没有数据。切片是我们的补充，不是抄的。
2. **5 档 OOM 归因**：Sentry/Datadog 都只有 1 档。细分是我们的选择，必须标注为推断。
3. **毒数据二分隔离**：后端整批校验的适配方案，业界用单条投递天然规避，不是业界做法。
4. **能力矩阵自报**（`cap.*`）：业界依靠"版本判断 + 编译期可选"，没有把能力位作为数据上报。这是为多端差异做的自有设计。

---

## 7. 复核清单

想自己核对的话，按这个列表逐条查：

```bash
# Sentry ANR 默认阈值
curl -s https://raw.githubusercontent.com/getsentry/sentry-cocoa/main/Sources/Swift/Options.swift | grep -n defaultAppHangTimeoutInterval

# Sentry 完全阻塞判定
curl -s https://raw.githubusercontent.com/getsentry/sentry-cocoa/main/Sources/Swift/Integrations/AppHangTracking/SentryANRTrackerV2.swift | grep -n framesContributingToDelayCount

# Sentry 慢帧/冻结帧阈值
curl -s https://raw.githubusercontent.com/getsentry/sentry-cocoa/main/Sources/Swift/Core/Integrations/FramesTracking/SentryFramesTracker.swift | grep -n "slowFrameThreshold\|frozenFrameThreshold"

# Firebase 慢帧/冻结帧
curl -s https://raw.githubusercontent.com/firebase/firebase-ios-sdk/main/FirebasePerformance/Sources/AppActivity/FPRScreenTraceTracker.m | grep -n "SlowFrameThreshold\|FrozenFrameThreshold"

# Datadog hang 采样与误报阈值
curl -s https://raw.githubusercontent.com/DataDog/dd-sdk-ios/develop/DatadogRUM/Sources/Instrumentation/AppHangs/AppHangsWatchdogThread.swift | grep -n "tolerance\|falsePositiveThreshold"

# Datadog watchdog 判定 guard
curl -s https://raw.githubusercontent.com/DataDog/dd-sdk-ios/develop/DatadogRUM/Sources/Instrumentation/WatchdogTerminations/WatchdogTerminationChecker.swift | sed -n '60,125p'

# Matrix iOS 卡顿阈值
curl -s https://raw.githubusercontent.com/Tencent/matrix/master/matrix/matrix-iOS/Matrix/WCCrashBlockMonitor/CrashBlockPlugin/Main/BlockMonitor/WCBlockMonitorConfiguration.h | grep -n g_default
```
