# 基建能力实现说明与业界对照

> **定位**：本文是 TDMonitorKit 各采集能力的**实现讲解 + 业界对照**，给接手维护的人看——每一项先讲「我们代码到底怎么做的」，再讲「业界（Sentry / Datadog / Firebase / Matrix）怎么做」，最后标差异与取舍。
>
> **不是契约**：本文随实现演进，若与代码出现分歧，**以代码为准**，并请顺手更新此处。逐文件的源码抓取证据、复核命令见 `INDUSTRY-COMPARISON.md`；每条能力的选型理由与局限见 `CAPABILITIES.md`。三份文档分工不同，不要互相覆盖。
>
> **判定图例**：`A`=与业界实质一致；`B`=思路一致、细节/口径有差异；`C`=因接入约束或架构导致的合理偏离；`D`=自有设计、业界没有或不同，**保留但带契约约束（置信度/文档标注/单测）**。

---

## 0. 总览

| # | 能力 | 关键类 | 文件 | 一句话实现机制 | 业界对标 | 判定 |
|---|---|---|---|---|---|---|
| — | 能力单元模型 | `TDMonitorFeature` / `TDMonitorRuntime` | `TBMonitorCore.swift` `TBMonitorFeatures.swift` | 每个能力=可失败构造+安装/卸载，依赖走运行期容器，按 `requires` 顺序装、逆序卸 | Sentry `SwiftIntegration` + `SentryDependencyContainer` | A+C+D |
| 1 | ANR / 卡顿 | `TDHangWatchdog` / `TDLongTaskMonitor` | `TBMonitorHang.swift` `TBMonitorStackSampler.swift` | 独立线程 semaphore ping + 帧采样；主线程连续忙 RunLoop 观测 | Sentry V2 / Datadog / Matrix | A+B+D |
| 2 | 页面渲染质量 | `TDScreenFrameSession` / `TDScreenFrameTracker` / `TDDisplayLinkHub` | `TBMonitorScreenFrames.swift` `TBMonitorViewController.swift` | 每 VC 一个会话，慢/冻帧互斥计数 + 30s 切片 | Sentry FramesTracker / Firebase | A+D |
| 3 | 非致命异常 | `TDNonFatalRecorder` | `TBMonitorNonFatal.swift` | 交换 `-[NSException raise]`，去重+限流 | Sentry `capture(error:)` | A+C |
| 4 | OOM / 终止归因 | `TDTerminationClassifier` / `TDAppState` / `TDExitDiagnostics` | `TBMonitorTermination.swift` `TBMonitorExitDiagnostics.swift` `TBMonitorMetricKitBridge.swift` | 双源（启发式五档 + MetricKit 增量）交叉验证 | Sentry 单档 / Matrix 分配级 | A+D |
| 5 | 崩溃补发 | `TDCrashBridge` / `TDBreadcrumbStore` / `TDCrashReportParser` | `TBMonitorCrashBridge.swift` `TBMonitorBreadcrumbs.swift` | **消费**宿主落盘 JSON 补发+补维度（刻意不装 handler，consume 而非 capture） | 业界四家均自接管（handler chaining 可共存不冲突） | C |
| 6 | 启动分段 | `TDLaunchClock` / `TDLaunchRecorder` | `TBMonitorLaunch.swift` | `kinfo_proc.p_starttime` 取内核启动时刻，pre-main / 首帧分段 | Sentry appStartMeasurement | A+B |
| 7 | 资源采样 | `TDResourceSampler` / `TDResourceMonitor` | `TBMonitorResources.swift` | mach 接口采内存/CPU/磁盘/线程/FD，内存 5s 高频落盘、其余 30s 上报 | Datadog RUMMetrics / MetricKit | A+B |
| 8 | 网络可观测 | `TDURLSessionNetworkClient` / 三族拦截器 | `TBMonitorNetworkClient.swift` `TBMonitorNetworkContract.swift` | Adapter/Retrier/Observer 三族；Observer 返回 Void 防改流程；metrics 兜底 | Alamofire 5 / Datadog | A+B+C |
| 9 | 页面加载耗时 | `TDViewControllerInstrumentation` | `TBMonitorViewController.swift` | swizzle 四个生命周期，keyWindow 门控，时间戳用完即清 | Firebase 同 swizzle | A+B |
| 10 | MetricKit 诊断 | `TDMetricKitBridge` / `TDExitDiagnostics` | `TBMonitorMetricKitBridge.swift` `TBMonitorExitDiagnostics.swift` | 订阅系统诊断 + 退出指标增量，作为补充源 | Sentry MetricKitIntegration | A+B |
| 11 | 生命周期 / 前后台 | `TDLifecycleFeature` | `TBMonitorFeatures.swift` | 前台→活跃测热启动，后台落盘，willTerminate 区分强杀 | 通用做法 | A |

---

## —. 能力单元模型（基建的基建）

维护者第一件要懂的事：**所有采集能力都是同一个协议 `TDMonitorFeature` 的实例**（`TBMonitorCore.swift`）。

- **可失败构造器** `init?(runtime:)`：返回 `nil` 即"当前环境不支持"，注册表静默跳过其余照常装——这正是"iOS 13 没有 MetricKit 怎么办"的架构级答案，而不是到处写 `if #available`。
- **安装/卸载** `install() -> Bool` / `uninstall()`：与 Sentry `SwiftIntegration` 对齐。
- **依赖容器** `TDMonitorRuntime`：跨能力取依赖统一走 `runtime.service(TDAppState.self)`，不持有对方实例引用；内置 `TDAppStateTracker`、`TDScreenContext`、`TDResourceMonitor` 等共享件。
- **顺序安装 / 逆序卸载**：`TDMonitorFeatureRegistry` 按 `requires` 拓扑排序，`TDAttributionFeature` 必须是第一个（归因结论要随首条 `session_start` 走）。
- **依赖缺口留痕**：Release 下 `requires` 未满足不 assert，而是 `noteBlocked` + warning，并暴露 `TDMonitor.blockedFeatures` 诊断，让"能力没装上"可被观测。
- **对外扩展**：`TDMonitor.register(_:)` 门面 + 闭包式 `registry.register(_:name:requires:)`，业务可加自定义能力，与内置能力共用同一套依赖注入/安装/卸载/能力矩阵对账。
- **可注入时钟** `TDClock`：`TDSystemClock` / `TDManualClock`，测试用 `TDManualClock` 确定性驱动时间相关逻辑（切片、重复抑制、启动兜底）。

**判定**：模型对齐 Sentry（A）；运行期服务字典 + `requires` 是相比 Sentry 刚性 `associatedtype` 更灵活的设计（D）；不靠 assert 而靠留痕是显式取舍（C）。

---

## 1. ANR / 卡顿监控

> 你点名要讲透的项。核心文件 `TBMonitorHang.swift` + `TBMonitorStackSampler.swift`。

### 我们怎么实现的

**检测线程 `TDHangWatchdog`（主线程卡死）**

- **独立后台线程**每秒用 `DispatchSemaphore` 往主线程投一个空 block，主线程若在 `thresholdMs`（默认 250ms）内没执行就判定卡顿——这是 Sentry 式主动投递，**能覆盖纯计算死循环**（RunLoop 类方案在这种场景恰好漏掉最严重的卡）。
- **检测起点 250ms ≠ 上报阈值 2000ms ≠ 致命阈值 8000ms**，三个阈值绝不混为一谈：
  - `hangThresholdMs=250`：卡顿一开始就要采栈，起晚了拿不到调用链前段。
  - `anrReportThresholdMs=2000`：低于它不发 `anr` 事件（对齐 Sentry `defaultAppHangTimeoutInterval=2.0`）。250ms~2s 的抖动在启动/切页时极常见，逐条上报会把真卡顿淹没。
  - `fatalThresholdMs=8000`：复用 `TDTerminationClassifier.watchdogHangThresholdMs`，达到即疑似被系统看门狗 SIGKILL。
- **卡顿期间每秒 `onProgress` 落盘**：进程被 SIGKILL 时内存里的事件发不出去，只有卡顿期间把时长写进 `TDAppState`，下次启动的终止归因才能拿到"上次是卡死被杀"的证据。
- **分级（纯函数，可单测）**：
  - `severity`：`≥8s` → `fatal_suspected`，否则 `hang`。
  - `blockType`：卡顿窗口内 displayLink 回调次数 `≤1` → `fully_blocked`，否则 `partially_blocked`（思路对齐 Sentry V2 的 `framesContributingToDelayCount==1`，但我们用"帧数"近似，不是"帧延迟"精确判定）。
  - `shouldReport`：距上次上报不足 `reportThresholdMs`（2s）则抑制——一段持续卡顿在恢复中会被结算多次，逐条上报等于把一次事故放大成 N 次。窗口取 2s 而非 Datadog 的 30s，避免吞掉连续卡顿这种真实场景。

**主线程堆栈采样 `TDStackSampler`（arm64）**

- 卡顿期间每 `sampleIntervalMs`（默认 50ms）采一次主线程调用栈：后台线程 `thread_suspend` 主线程 mach port → 从 `arm_thread_state64_t` 的 PC/LR + 帧指针链（`[fp]=上一帧fp, [fp+8]=返回地址`）回溯最多 48 帧。
- **关键安全约定**：挂起期间**只取地址、绝不符号化**；恢复线程之后才调 `dladdr`。否则采样器自身可能在挂起期间撞上 dlopen 锁而制造死锁。arm64e 的 PAC 签名位用 `0x0000_7FFF_FFFF_FFFF` 掩码剥离。
- 输出三路：文本栈（atos 可二次符号化）、结构化帧（模块+镜像内偏移，服务端用 dSYM 还原行号）、采样计数。

**卡顿采栈的风险与业界共识**

- **不引入新卡顿**：卡顿定义就是主线程已堵死——看门狗正是靠主线程 semaphore 没被 signal 才判定卡顿，挂起一个本不在跑的线程不会让它更卡；`thread_suspend`/`thread_resume` 是微秒级内核调用，采样跑在我们的后台 hang 队列上，不占主线程。
- **真正的风险是死锁，不是卡顿**：若采样线程在**主线程挂起期间**调用了主线程持有的锁（如 `dladdr` 会碰 `dlopen` 锁），进程会死锁。我们的规避与 Sentry iOS profiler 博客一致——**挂起期间只做必要操作**（`thread_get_state` + 原始帧指针内存读 `vm_read_overwrite`），符号化（`dladdr`）一律放到 `thread_resume` 之后。
- **多次采样优于单快照**：卡顿期间每 `sampleIntervalMs`（默认 50ms）采一次、取首条 >2 帧的样。Sentry 自承「主线程极忙时 hang 检测会偏晚、栈可能不完全相关」，我们多次采样反而缓解这个。
- **帧指针回溯的真实局限（口径已校正）**：我们用 AAPCS64 帧指针链回溯。此前把"栈只有 1–2 帧"写成"FP 方案的已知取舍、非 bug"，**这是误判**：真机复验发现根因是回溯方向写反（`framePointer < previous` + 初值 `UInt64.max`，而栈向低地址增长、沿 fp 往调用者回溯时 fp 递增），独立 C 程序对照证实旧逻辑只回溯 1 帧、修正后 11 帧；改为 `framePointer > previous` + 初值 0 后，真机栈深度从 1–2 帧恢复到平均 6 帧、最深 8 帧。修正后仍存在的**真实**局限是：叶子函数、尾调用、重度内联不产生 fp 记录时链会断，这类帧的补全需要 compact unwind + DWARF（KSCrash/Sentry 的做法），代价更大，本次不做。栈深 6–8 帧已能满足"看出主线程卡在哪"的定位目标。

**原生长任务 `TDLongTaskMonitor`（主线程连续忙）**

- 用 `CFRunLoopObserver` 测"醒来→再次休眠"之间的连续忙时间，超 `longTaskThresholdMs`（默认 100ms）即报。它**发现卡顿源头**（掉帧是结果，长任务是原因），且不依赖屏幕刷新。与卡顿看门狗是正交互补的两套机制。

**当前页面归属 `TDScreenContext`**：用栈而非单值，push 动画期间旧页未消失时避免归属来回跳；支持 `TDMonitor.setScreen` 手动埋点覆盖。

### 业界怎么做的

| 项 | Sentry V2 | Datadog | Matrix iOS |
|---|---|---|---|
| 检测 | 独立线程投 block **+ 帧延迟判定** | 独立 watchdog 线程 + semaphore | **无独立线程**，RunLoop observer（有盲区） |
| 阈值 | 2.0s | 构造传入 | 2s |
| 采样 | — | 50ms | 50ms |
| 分级 | 5 类（fully/non-fully × hang/fatal + unknown） | 2 类 | 按时长分档 |
| 误报防护 | 1 分钟内不重复报 | `falsePositiveThreshold=30s` | CPU 使用率 |

### 差异与取舍

- **检测手法、2s 阈值、hang/fatal 两段式、重复抑制**：与业界一致（A）。
- **`blockType` 用"卡顿期间出过几帧"近似**，而非 Sentry V2 的 `framesContributingToDelayCount==1` 帧延迟精确判定（B/D）——口径相近但不等价，已在 CHANGELOG「已知限制」标注。
- **重复抑制窗口取 2s 而非 30s**（D 类小偏离）：30s 会吞掉连续卡顿，2s 只压同一段卡顿的重复结算。

---

## 2. 页面渲染质量

> 你点名要讲透的项。核心文件 `TBMonitorScreenFrames.swift` + `TBMonitorViewController.swift`。

### 我们怎么实现的

**进程唯一 vsync 源 `TDDisplayLinkHub`**：全局帧率与逐页面帧率都每帧回调。多个 displayLink 会互相抢、没人管生命周期，所以做成一个 hub——谁需要谁注册，全部撤销后自动 `invalidate`。**不指定 `preferredFrameRateRange`**：强行要 120Hz 会阻止低电量降频，而"系统正在降频"本身就是该被观测的信号。

**逐页面会话 `TDScreenFrameSession`**（核心算法）

- 每 VC 一个会话，`viewDidAppear → viewDidDisappear`。全局 FPS 在大盘上永远平线（静止页帧率=刷新率上限），只有按页面归因才能定位"哪个页卡"。
- **慢帧** `1/(fps-1)`、`冻结帧` 0.7s，与 Sentry/Firebase 一致；**互斥计数**（冻结帧单独成档，未冻结的才进慢帧），`slowFrameRate + frozenFrameRate` = 全部异常帧占比。减一的 reason：多数帧会比理论帧长几微秒，直接用 `1/fps` 会让几乎所有帧被判慢帧。
- **`hitchMs`**：异常帧超出预算的时间之和，比"帧数占比"更贴近体感卡顿时长。
- **30s 切片** `phase=slice|final`：只在 `viewDidDisappear` 结算会让一直停在首页（最重要页面）永远没数据。停留超 30s 就切一片上报，结算即重置窗口（`takeReport` 的 `defer` 块清零），**所以 slice 与 final 不重复计数**。后端必须按 `phase` 聚合，不能直接求和。
- **抗抖动/抗污染**：单帧间隔 `>1s` 视为前后台/系统打断，整段丢弃（`discontinuityThreshold`）；`frameCount>=10` 且窗口≥300ms 才出结论（`isWindowMeaningful`），避免分母过小造成 100% 慢帧假告警。

**驱动 `TDScreenFrameTracker`**：维护活跃会话数组，每帧 tick 推进；有页面在屏才注册 vsync，没人看时自动注销。

**页面身份与门控 `TDViewControllerInstrumentation`**：swizzle `viewDidLoad/viewWillAppear/viewDidAppear/viewDidDisappear`；**只统计挂在 `keyWindow` 上的业务页**（`UI*`/`_*` 系统容器类跳过）；`viewDidLoad` 时间戳用后立即清空，否则 pop 回来会把 `loadMs` 算成距上次 load 的几万毫秒（旧实现的线上 bug）。

上报事件 `screen_render`，带 `slowFrameRate/frozenFrameRate/hitchRatio/budgetMs/refreshRateHz` 等维度。

### 业界怎么做的

- **Sentry `SentryFramesTracker`**：`frozenFrameThreshold=0.7`、`slowFrameThreshold=1/(fps-1)`，互斥计数（已实时核实）。
- **Firebase `FPRScreenTraceTracker`**：每 VC 一条 trace，**只在 `viewDidDisappear` 结算一次**——长停留页面永远没数据。慢帧=1/59、冻结=700ms。

### 差异与取舍

- 阈值、互斥计数、每 VC 粒度、keyWindow 门控：与业界一致（A）。
- **30s 切片**（D）：补 Firebase 的已知缺口，自研增强，必须标注"后端按 `phase` 聚合、不能求和"。
- **`hitchRatio`**（D）：自有派生指标，对偶发长卡更敏感，但**无法与任何外部基准横向比较**，文档已标注，主指标仍是 `slowFrameRate/frozenFrameRate`。

---

## 3. 非致命异常捕获

> 你点名要讲透的项。核心文件 `TBMonitorNonFatal.swift`。

### 我们怎么实现的

- **交换 `-[NSException raise]`**（`method_exchangeImplementations`）：覆盖 `+[NSException raise:format:]` 系列与显式 `[exception raise]`，在 `td_raise` 里先记录再调原实现（该抛还是抛，不拦截流程）。**不交换 `objc_exception_throw`**——`@throw` 走的这条路无法在不接管崩溃的前提下拦截，且交换它会把所有被正常 `catch` 的异常都算成"异常"，数据噪声压过信号。
- **去重 + 限流**，避免异常风暴打满队列：60s 内同一 `(category|message 前160|栈首行前120)` 不重复；每分钟上限 20 条；内存里 seen 表超过 200 条清空重建。
- **业务补报入口** `record(message:stack:category:attributes:)`：覆盖 Swift `Error`、被 catch 的分支、降级路径——`NSException` 路径覆盖不到的 Swift 错误只能靠它。
- 上报 `error` 事件，带面包屑轨迹（优先上次会话残留，因为本次会话轨迹在崩溃时已随进程消失）。

### 业界怎么做的

- Sentry `capture(error:)`、Firebase 非致命上报：都是显式 API + 自动捕获 ObjC 异常。

### 差异与取舍

- 交换 `raise` 自动捕获：与业界一致（A）。
- 不交换 `throw`、限制每分钟条数：刻意取舍（C）——避免被 catch 的异常噪声化。

---

## 4. OOM / 终止归因

> 你点名要讲透的项。核心文件 `TBMonitorTermination.swift`（启发式）+ `TBMonitorExitDiagnostics.swift` + `TBMonitorMetricKitBridge.swift`（MetricKit 源）。

### 我们怎么实现的

**这是双源 + 交叉验证的设计，不是"选一个更准的用"**：

| 来源 | 覆盖 | 时效 | 局限 |
|---|---|---|---|
| 启发式（本地） | 全版本全用户 | 下次启动即知 | 只能给证据，给不了权威判定 |
| MetricKit | iOS 14+ 且未关「共享 iPhone 分析」 | 次日批量 | 覆盖率非 100%，无实时性 |

只信 MetricKit：iOS 13 完全没有、国内关分析比例高时大面积缺失。只信启发式：会把强杀/后台超时/系统升级都算成 OOM，比率虚高不可用。**两条都跑，各自带 `source` 标记，后端按来源分组；同一退出可能被两条路径各报一次——这是刻意的，用计数差反推 MetricKit 覆盖率。**

**启发式现场 `TDAppState`**

- **原子写文件**（不是 `UserDefaults`）：`UserDefaults` 在 SIGKILL 前不保证落盘，用它存"是否干净退出"会在被杀时读到陈旧值，直接导致归因反转。
- **存 footprint 序列（60 点环形，5s 一次）而非单点**：SIGKILL 类退出没有崩溃栈，唯一证据是死亡前的内存爬升曲线，单点等于没证据。
- **`timeline` 统一时间轴**：内存/内存警告/页面切换/前后台/卡顿都打在同一条带 `offsetMs` 相对偏移的序列上，回答"是缓慢泄漏还是一次性拉爆、警告发生在爬升前还是峰值时"。用相对偏移而非绝对时间，避免重启/NTP/改时间导致错序。
- 环境标记（调试器/模拟器/OS 版本/app 版本）：让下次启动能判断这次退出差额该不该算数。
- 高频写（内存每 5s 一次）+ 语义变化才写（前后台/页面/警告）：既拿得到爬升曲线，又不因高频 IO 自己成为性能问题；`willTerminate` 走**同步写**（系统只给很短收尾窗口，异步大概率来不及）。

**归因分类器 `TDTerminationClassifier.classify`**（纯函数，可单测）

- 排除序列（命中即返回 nil=不报）：`cleanExit`（走了 willTerminate=强杀/正常退出）→ 调试器/模拟器 → 首次启动无基线 → OS 升级 → app 版本/build 变化（发版当天会有一波假尖峰）。
- 五档归因（带 `confidence`）：
  1. `watchdog`：前台 + 主线程卡死 `≥8s`（`maxHangMs` 来自卡顿期间的 `onProgress` 落盘）。confidence 0.8。
  2. `jetsam`：`footprint/limit ≥ 0.85`（自有经验值）或可用内存 `<50MB`。confidence 0.7~0.95。
  3. `backgroundTaskTimeout`：后台 + 后台任务未结束（`beginBackgroundTask`/`endBackgroundTask` 已 swizzle 计数）。confidence 0.6。
  4. `memoryPressure`：有内存警告但没到上限。confidence 0.5。
  5. `unknown_unclean`：**证据不足时宁可报 unknown，不冒充 OOM**——把强杀算成 OOM 会让整个 OOM 率失去意义。confidence 0.2。

**MetricKit 源 `TDExitDiagnostics` + `TDMetricKitBridge`**

- `TDExitDiagnostics.handle(MXAppExitMetric)`：取 `cumulativeMemoryResourceLimitExitCount`/`cumulativeMemoryPressureExitCount`/`cumulativeAppWatchdogExitCount` 的**累计计数 → 本次增量**（首次见到某 key 以当前值为基线，返回 0，避免升级当天把历史全算到当前版本）；发 `oom`/`watchdog` 事件，带 `source="metrickit"` 与同一份 `footprintSeries`/`timeline` 证据。
- `TDMetricKitBridge`：订阅 `MXMetricManager`，把崩溃/卡顿/CPU/磁盘诊断与 `MXMetricPayload` 聚合指标转成事件；`TDMetricKitCoverage.deliveryCount` 记录真实投递次数——为 0 即该用户关了「共享 iPhone 分析」，用于反推覆盖率。

### 业界怎么做的

- **Sentry**：单档 `WatchdogTermination`，措辞 "possibly because it overused RAM"——用 `possibly` 是承认自己没证据；排除调试器/模拟器/OS 升级/app 升级/首启/强杀。
- **Datadog**：`WatchdogTerminationChecker` 10 条 guard 返回单个 bool。
- **Matrix iOS**：**不做 OOM 归因**；OOM 归因是 Android 侧能力。iOS 侧只有 `WCMemoryStat`（C++ malloc/对象分配钩子 + 栈 hash 库，能做分配级证据，但工程量与运行时开销最大）。

### 差异与取舍

- 排除逻辑、双源交叉验证思路：与业界一致（A）。
- **五档归因**（D）：比业界单档 `possibly` 更可操作（"这波是后台超时不是内存"方向完全不同），但每档带 `confidence` 防误读，且 `unknown` 不冒充 OOM。
- **`jetsamFootprintRatio=0.85`**（D）：自有经验值，注释已写明"非业界口径"——Sentry/Datadog 根本不做比值判断。拿不到 `limit` 时退化为"可用内存 <50MB"，并带 confidence。

---

## 5. 崩溃补发（消费宿主落盘 JSON，未自装 handler）

核心文件 `TBMonitorCrashBridge.swift` + `TBMonitorBreadcrumbs.swift`。

### 我们怎么实现的

- **不装任何崩溃处理器（这是设计选择，不是外部约束）**：`TDCrashBridge` 只做一件事——解析宿主 `TBCrashReporter` 已经落盘的崩溃 JSON（`TDCrashReportParser`）→ 转成带结构化栈、镜像 UUID、加载基址、真实面包屑的 `native_crash` 事件；已补发过的 id 记住，重启不重复。2.5.4 起 `symbolicated` 按帧内符号判定（不再恒为 `false`），`sessionId` 从 `app_state.json` 的上一会话现场按崩溃时间窗口认领，并用 `attributes.originSessionIdSource` 标注来源——这三项直接决定后台的符号化覆盖率与崩溃率分母是否可信。我们**没有**注册第二个 signal/NSException/Mach handler，所以是"消费（consume）"宿主现场而非"捕获（capture）"。
- **面包屑落盘 `TDBreadcrumbStore`**：100 条环形，节流写（>1s 才落盘，期间攒脏标记），进入后台/崩溃前 `flush`。崩溃是下次启动补发的，内存里的轨迹必然丢失，**所以必须落盘上次会话的轨迹**（`loadPreviousSession`），崩溃事件才能带上真实操作链。
- **镜像 UUID `TDBinaryImage`**：直接从 Mach-O `LC_UUID` 读，不依赖私有接口；上报 `appUUID` + `appLoadAddress`（PIE 每次 slide 不同，没有基址事后无法 atos 还原行号）。
- **把宿主缺口变指标**：每次启动检查"上次异常退出 && 无崩溃文件 → `crash_pipeline_missing`"——缺口有数字，不是静默。

**符号化链路的真实状态（2026-11-22 查库校正，勿夸大）**：客户端 `attributes.frames` 与 MetricKit 原始 `stack`（UUID+offset 的 JSON）都**带齐了符号化前提**，后台 `crash-symbolicator.ts` 也实现了按地址区间定位镜像 + dSYM 索引回填，代码链路是通的。但**完整还原业务帧依赖对应构建的 dSYM 已上传**：当前 `symbol_indexes` 表只有 2 个 UUID（`LMPerformanceKit`、`TrueDepthDemo2.debug.dylib`，11-20 上传），而真机崩溃的 `appUUID`（`367CF844…`/`F3DF4371…`）从未上传过符号表。因此端到端 API 实测：系统库帧可读（dladdr/demangle 得来），**业务帧只有 demangle 出的 mangled 名、`symbolSource=raw/demangle`、`frameKind=unknown`，没有一条是 `dsym` 回填**。此前"崩溃符号化闭合、75 帧完整可读"是挑了最好的一条下的结论——真实情况是一部分帧可读、业务帧未做 dSYM 还原。要让业务帧可读，需为当前 Release 构建执行 `scripts/upload-dsym.mjs` 上传 dSYM 后复验。

### 业界怎么做的

四家（Sentry/Datadog/Matrix/Crashlytics）**全部自接管** KSCrash 类 handler——所谓「接管」是在内核 Mach 层 `task_set_exception_ports` 设为异常接收者（并先 `task_get_exception_ports` 备份上一家端口），再配 signal / `NSSetUncaughtExceptionHandler`，Mach 层才是真正可靠、能抓 `EXC_BAD_ACCESS` 的一层。

但要注意：**「自接管」不等于「链路接管 / chaining 共存」**。Mach 端口与 signal handler 在 iOS 上是**独占**的——后装的覆盖先装的，不是「挂」上去。因此业界的标准姿态是**自接管 + 独占 + 不共存**：
- Firebase 工程师明确："On iOS there can be only one global signal handler… only one crash reporting tool active for the app"；
- Sentry 官方："We recommend against running multiple APM tools in parallel… Duplicate or missing crash reports"；
- KSCrash 虽然会在安装时备份上一家的 Mach 端口（`g_previousExceptionPorts`），但那个备份的真实用途是**卸装时还原**、不是保证两家共享崩溃；即便转发，结果也是两家各生成一份报告、各自符号化、双份链路，业界不鼓励。
所以「两个崩溃 SDK 优雅共存」在 iOS 上**没有确定可靠的机制**——这条认识直接决定了下面「接管 vs 消费」的取舍。

### 差异与取舍

- **不装 handler 是刻意的设计选择（consume 而非 capture），不是「你不让接管」、也不是「接管必然顶掉」**：
  - 在「宿主已有成熟崩溃上报（TBCrashReporter）」这个前提下，若我们**裸装** capture handler，会和宿主抢 Mach/signal 端口、互相顶掉；若想「chaining 共存」，iOS 上又**没有确定可靠**的共存机制（见上节：Mach/signal 端口独占、Sentry/Firebase 均不推荐两个崩溃 SDK 并存）。两条 capture 路线在这个场景下都别扭。
  - 我们选 consume 的**好处**：宿主永远是原始崩溃的唯一真相源，我们不可能因自己装 handler 把宿主捕获顶没了，也不承担「handler 内再崩一次就全丢」的风险；**代价**：完全依赖宿主 JSON 格式，只能 enrich 不能重抓现场。
  - 因此 capture（Plan B）真正划算的场景只有一个：**宿主没有崩溃 SDK，或我们要把监控 SDK 独立分发（别的 App 没有 TBCrashReporter）**——那种情况下应做的是「成为唯一崩溃 SDK」（独占），而不是 chaining。本能力因此仍标记为与业界的偏离（C），但偏离的是「capture 形态」，不是「没接好管」。
- 面包屑落盘、`crash_pipeline_missing` 缺口可观测：与「不接管」正交，保留。

---

## 6. 启动分段

核心文件 `TBMonitorLaunch.swift`。

### 我们怎么实现的

- **起点取 `kinfo_proc.p_starttime`**（sysctl `KERN_PROC_PID`）：内核记录的进程创建时刻。若像早期实现那样在 SDK 首次触达时取 `systemUptime`，测到的只是"start 调用→recordLaunch"的几微秒，pre-main/dyld/静态初始化全部丢失。拿不到内核时间时降级为"首次触达"时刻并如实标注 `origin`。
- **三段计时** `TDLaunchRecorder`：`preMainMs`（进程创建→`didFinishLaunching` 返回，含 dyld/启动项）、`firstFrameMs`（`didFinishLaunching`→首帧渲染完成，CADisplayLink 首次回调，因为 `makeKeyAndVisible` 只是提交布局此刻算首帧耗时=0）、`totalMs`=两者之和。
- **首帧用 CADisplayLink 等真正呈现**：`makeKeyAndVisible()` 只提交布局，此刻取时间会把首帧渲染算成 0；displayLink 第一次回调才是首帧真正上屏。
- **3s 兜底**：宿主没显式 `markFirstFrame()` 也要有数据，否则启动指标永久缺失（比略偏更糟）。
- **预热启动**：读 `ActivePrewarm` 环境变量，标 `type=prewarm` 避免污染冷启动 P95。

### 业界怎么做的

Sentry `appStartMeasurement`（pre-main/cold/warm）、Firebase 拆 `_as_`+首屏 trace、Matrix 分冷/热/首屏。

### 差异与取舍

- 起点取法、三段口径、首帧等渲染：与业界一致（A）。
- **不细分 dyld/`+load` 阶段**（B）：文档已说明成本不划算（会污染启动、跨版本行为不一致）。

---

## 7. 资源采样

核心文件 `TBMonitorResources.swift`。

### 我们怎么实现的

**`TDResourceSampler`（全走内核接口，零估算）**

- 内存：`task_vm_info.phys_footprint`（与 Xcode 内存 gauge 同源）+ `os_proc_available_memory()`（iOS 13+），`limit ≈ footprint + available`。
- CPU：`task_basic_info` 的 user+system 时间差 / 墙钟；**上限按核心数收口**（进程可超 100% 多核），避免异常值污染 P95。
- 磁盘：`attributesOfFileSystem`。
- 线程：`task_threads` 计数。
- FD：`/dev/fd` 在沙箱不可枚举、`proc_pidinfo` 未导出 Swift 模块，改为逐个 `fcntl(fd, F_GETFD)` 探测，上限 4096，纯 POSIX 无私有符号。

**`TDResourceMonitor`（分频采样）**

- 内存单独 5s 高频 **只落盘不上报**（服务 OOM 爬升曲线），其余（CPU/磁盘/电池/热状态/线程/FD）30s 上报一次——混在一个 timer 要么内存太稀、要么事件量放大 6 倍白烧电。
- `nearLimit`（footprint/limit>0.8）、`peakMb`、电池状态、热状态（`thermalState`）一并上报；受 `sampleRate` 抽样控制。

### 业界怎么做的

三家的**主路径都是进程内自采样**：Datadog RUM 的 `RUMMetrics`、Firebase Performance 的
自建 trace / 系统采集、Sentry 的 AppState 采样。Apple `MetricKit` 是另一类东西——系统聚合、
次日批量、需用户开启「共享 iPhone 分析」，**不是实时资源监控的数据源**（详见第 10 节）。
所以本节「mach 接口 + 内存 5s / 其余 30s 分频」对齐的是三家的自采样路径，不是 MetricKit。

### 差异与取舍

- 维度与口径：与业界一致（A）。
- **FD 探测走 fcntl 而非枚举目录**（B）：iOS 沙箱的特有实现细节，已在注释说明。

---

## 8. 网络可观测

核心文件 `TBMonitorNetworkClient.swift`（统一出口）+ `TBMonitorNetworkContract.swift`（三族契约）+ `TBMonitorNetwork.swift`/`TBMonitorNetworkCollectors.swift`（采集器）。

### 我们怎么实现的

**三族拦截器契约（对齐 Alamofire 5，刻意避开 Moya 单协议）**

- `TDRequestAdapter`：**能改请求不能决定成败**（注入 trace header/签名/刷新 token/补公共参数），串行，任一环抛错即短路出 `preconditionFailed`。
- `TDRequestRetrier`：**只决定重不重试**，要改请求通过 `request` 回传而非就地改——让"发生了什么重试"可被观测；多个 retrier 第一个非 `doNotRetry` 生效。
- `TDNetworkObserver`：**所有方法返回 Void**——监控采集器全实现在这一族，在类型层面就不可能改变业务请求的成败/顺序/内容，比"代码规范要求采集器别改请求"可靠（规范会被下一人忘，类型签名不会）。

**参考实现 `TDURLSessionNetworkClient`**

- adapter 链 → dispatch → 业务回调立即执行（不拖慢业务）→ metrics 与 completion 齐了再合流观测上报；**1s 兜底窗口**（`metricsGraceInterval`）防 metrics 迟到（AFNetworking 源码原话："Metrics may fire after didCompleteWithError"）。兜底超时按"宁可少数据不要错数据"发 `metricsMissing=true`，迟到的 metrics **直接丢弃并留痕**——补发会造成双计数，比缺数据更难发现。
- **监控自身上报刻意不走这里**：`TDHTTPBatchUploader` 持独立 `URLSession` 直发，不与业务网络层共用（避免"网络层出问题连网络层出问题都报不上去"），且 `isInternal` 在采集侧就挡掉自激。
- **短路也出观测记录**（缓存命中/token 拿不到/前置失败）：否则监控看到的是"接口从没被调用"，实际是"一直被本地短路"——最难查的一类指标缺失。

### 业界怎么做的

Alamofire 5（`RequestAdapter`/`RequestRetrier`/`EventMonitor` 三族分开）、Datadog（`URLSession` 拦截拿 metrics）、Moya（`PluginType` 单协议，把三者塞一个协议，职责靠文档约束——正是我们避开的对照）。

### 差异与取舍

- 三族拆分、metrics 分阶段、短路出记录：与业界一致（A）。
- **Observer 返回 Void 防改流程**：在 Alamofire 基础上的加固（A+）。
- **metrics 时序兜底 + 自激隔离**：自研细节（B/C）。

---

## 9. 页面加载耗时

核心文件 `TBMonitorViewController.swift`。

### 我们怎么实现的

- swizzle 四个生命周期：
  - `appearMs` = `viewWillAppear → viewDidAppear`（用户感知的"页面出现"）；
  - `loadMs` = `viewDidLoad → 首次 viewDidAppear`（含构建视图完整代价）。
- **`viewDidLoad` 时间戳用后立即清空**：否则 pop 回来/`tab` 切换/`modal` 关闭时 `viewDidAppear` 再次触发，`loadMs` 会算成距上次 load 的墙钟差，动辄几万毫秒（旧实现把 P95 拉爆的 bug）。
- **keyWindow 门控 + 系统类 `UI*`/`_*` 跳过**：容器页（导航/分栏）不是业务页，计入会稀释真实页面指标。
- 上报 `view_load` 事件。

### 业界怎么做的

Firebase `FPRScreenTraceTracker` 同样 swizzle 生命周期取页面加载耗时。

### 差异与取舍

- swizzle 口径：与业界一致（A）。
- 时间戳清理是 bugfix（B）；keyWindow 门控对齐 Firebase。

---

## 10. MetricKit 系统诊断

核心文件 `TBMonitorMetricKitBridge.swift` + `TBMonitorExitDiagnostics.swift`。

### 我们怎么实现的

- `TDMetricKitFeature`：**只有 iOS 14+ 存在**，`init?` 在 iOS 13 不调用、注册表跳过，其余能力照常——版本门槛是"能力本身的有无"，不是运行时到处 `if #available` 打补丁。
- `TDMetricKitBridge`：订阅 `MXMetricManager`，把 `MXDiagnosticPayload`（崩溃/卡顿/CPU 异常/磁盘写入异常，带可符号化栈）与 `MXMetricPayload`（峰值内存/累计 CPU）转成事件；次日批量、无实时性。
- 作为**补充源不替代自研采集**；`TDMetricKitCoverage.deliveryCount` 反推覆盖率（关分析的用户永不到达）。
- `TDExitDiagnostics` 处理 `MXAppExitMetric` 增量（见第 4 节）。

### 业界怎么做的（2026-11 复核，**此前写错了**）

**结论：业界没有把 MetricKit 当主路径，更没有用它做 OOM 归因。**

| 厂商 | MetricKit 的实际用法 | 主路径 |
|---|---|---|
| Sentry Cocoa | `enableMetricKit`，**默认 `false`**（8.14.0 起提供，文档标注 iOS 15+）。开启后只订阅 `MXHangDiagnostic` / `MXDiskWriteExceptionDiagnostic` / `MXCPUExceptionDiagnostic` 三类诊断并转成事件；官方文档明确「SDK 无法控制 MetricKit 给出的栈，有时只有几帧」。**不订阅 `MXAppExitMetric`，不用于 OOM 计数** | `enableWatchdogTerminationTracking`（默认 `true`）：上次会话 AppState + 排除清单的启发式推断 |
| Datadog iOS | 不把 MetricKit 数据接入 RUM。只在文档里借用 **MetricKit 对 hang rate 的定义**（>250ms）说明自家 `appHangThreshold` 的口径对齐 | `trackWatchdogTerminations`：上次会话排除清单启发式；app hang 用独立观察线程 |
| Firebase / Crashlytics | 未查到公开的 MetricKit 数据接入路径 | 自有进程内插桩（Performance trace / Crashlytics 自有 handler） |
| 国内自研（含 Apple 自家 Organizer） | 常见做法是自建 `MXMetricManager` 订阅**做交叉校验**，因为系统源权威但太慢太稀 | 仍是自采集 + 启发式 |

**MetricKit 为什么只能当补充源**：数据由系统在 App 外聚合，用户必须开启「共享 iPhone 分析」才投递；按天批量、无实时性；只有累计计数/直方图，没有业务上下文、面包屑、逐用户现场；栈未符号化。关闭分析的用户**永远没有数据**，且 API 读不到这个开关。

**本项目的真机证据（口径已校正）**：此前写「每次 `session_start` 的 `metrickitPayloads` 都是 0」是**错的**——
`metrickitPayloads` 取自 `TDMetricKitCoverage.deliveryCount`，语义是**该设备自安装以来的累计投递次数**，
不是本次会话增量。真机库实测：130 个会话里 **95 个 >0（最高 14）**，证明 MetricKit 在这台设备上真实投递过。
当时下"永远是 0"的结论，是拿某一时刻（设备刚装、尚未收到投递）的快照写成普遍规律，属于臆测。
结论不变的部分仍成立：MetricKit 是补充源而非 OOM 主路径（业界一致），OOM 率的分子取启发式路径。

### 差异与取舍

- 订阅 + 增量 + 版本门槛处理：机制本身没问题（A），但**默认开启比业界更激进**——
  Sentry 是 opt-in。我们靠 `deliveryCount` 显式暴露真实覆盖率，而不是默默少报。
- 作为补充而非替代（B）：与业界一致。国内关分析比例高，单信它会大面积缺失。
- **口径修正**：OOM 率的分子取启发式路径；MetricKit 增量只用于按 `source` 分组做
  交叉验证 / 反推覆盖率，不参与对外 OOM 率计算。

---

## 11. 生命周期 / 前后台

核心文件 `TBMonitorFeatures.swift`（`TDLifecycleFeature`）。

### 我们怎么实现的

- **前台→活跃**：测热启动（`willEnterForeground` 记起点 → `didBecomeActive` 算"回到前台到可交互"实测耗时，与冷启动 `TDLaunchFeature` 并列）；刷新前台标记、网络类型、资源监控前后台态。
- **进入后台**：落盘轨迹与内存现场（进程随时可能被后台杀）+ `flushBreadcrumbs` + 补发挂起的崩溃报告 + `flushInBackground`。
- **`willTerminate`**：同步标记 `markCleanExit(initiator: "will_terminate")`——用户上划强杀或系统请求退出走这里；被 jetsam/看门狗 SIGKILL 不走这里，**正是这个差异让"强杀"与"系统杀"能被区分开**（见第 4 节）。

### 业界怎么做的

通用做法，与各家生命周期监听一致。

### 差异与取舍

- 热启动计时、后台落盘、willTerminate 区分强杀：与业界一致（A）。

---

## 12. 判定分布与维护须知

| 判定 | 数量 | 含义 |
|---|---|---|
| A（与业界实质一致） | 最多 | 逐条对着业界源码写过，是可信基线 |
| B（思路一致、细节差异） | 若干 | 见各节括号内说明 |
| C（约束/架构导致的合理偏离） | 3 | 崩溃不装 handler（consume-host-JSON 的设计选择，capture 可走 chaining）、网络 Observer 返回 Void、非致命不交换 throw |
| D（自有设计，保留+契约约束） | 4 | 运行期服务字典、`requires`；OOM 五档；30s 切片+`hitchRatio`；`jetsamFootprintRatio=0.85` |

**D 类项的契约约束（改动前必读，避免"推断当结论"）**

1. OOM 五档：每档带 `confidence`，`unknown` 不冒充 OOM，`TDTerminationClassifierTests` 覆盖此契约（**已写、未实跑**，见下方工程化债）。
2. 切片：`phase` 区分、结算即重置不重复，`TDScreenSliceTests` 覆盖（**已写、未实跑**）。
3. `0.85` 比值：注释标明非业界口径，拿不到 limit 退化为可用内存阈值。
4. 运行期服务字典：`TDRegistryGraphTests` 覆盖内置 12 能力自检自洽（**已写、未实跑**）。

> 措辞说明：以上三处此前写"单测锁住"，容易被读成"已验证通过"。事实是测试代码存在，但没有一次成功的实跑记录，不能作为契约已成立的证据。

**仍待补的工程化债（非本次范围）**

- **构建可重现**：SPM `Package.swift` 在干净环境 `swift test` 仍需打通；README 的接入与验证步骤待补齐。2026-11-22 实测 `xcrun swift test` 在 manifest 编译阶段即被 `sandbox-exec: sandbox_apply: Operation not permitted` 拦住（本机沙箱限制，非代码问题），需在 Xcode GUI 或 CI 无沙箱环境跑。
- **能力粒度太粗**：配置只有 `autoCollect`/`networkInstrumentation`/`viewLoadInstrumentation`/`nonFatalCapture` 四个总开关，无法单独关 ANR/调卡顿窗口/开关 OOM 归因。
- **三份偏离契约单测**（Termination/Slice/RegistryGraph）已在代码层写好，但**从未成功实跑**——在 Xcode/CI 跑一遍确认绿之前，只能标"已实现未验证"，不算闭环。
