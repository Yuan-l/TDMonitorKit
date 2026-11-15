# TDMonitorKit 能力方案对比与选型

> 每项能力都至少存在两条技术路线，选哪条决定精度、性能开销、可维护性。
> 本文先于实现，逐项给出：候选路线 → 各家实际做法 → 我们的选择 → 理由 → 局限 → 待确认。

---

## 1. 启动耗时

| 候选路线 | 说明 |
|---|---|
| A. `+load` / `__attribute__((constructor))` 起算 | 最早，能覆盖 dyld 到 main 之前；但 `+load` 会拖慢启动本身 |
| B. `main()` 起算 | 简单准确，漏掉 pre-main |
| C. `didFinishLaunching` 起算 + 首帧回调结算 | 覆盖业务可感知区间，需要宿主配合标记首帧 |
| D. 进程启动时间 `KERN_PROC_PID` 读 `p_starttime` | 能拿到真实进程创建时刻，可反推 pre-main |

**各家**：Firebase 拆 `_as_` (app start) 与首屏 trace；Matrix 分「冷启动 / 热启动 / 首屏渲染」多段；Sentry 用 `appStartMeasurement`（pre-main / 冷启 / 暖启三段）。

**我们的选择**：C + 兜底。`markDidFinishLaunching()` → `markFirstFrame()`，未标记首帧则 3 秒兜底结算。热启动走 `willEnterForeground → didBecomeActive`。

**理由**：A 会污染启动；B 漏 pre-main 且宿主 `main` 不可控；D 需要额外 sysctl 且跨版本行为不一致。C 的缺口是「pre-main 不可见」，用 `cap.*` 如实标注。

**局限**：拿不到 dyld 阶段耗时。**若要做**，走 D 读 `p_starttime`，不需接管启动流程。

---

## 2. 全局帧率

| 候选路线 | 说明 |
|---|---|
| A. `CADisplayLink` 每次回调算间隔 | 唯一能拿到真实 vsync 的手段 |
| B. `CADisplayLink.preferredFrameRateRange` 锁 60 | 会干扰宿主自身的帧率策略，**不能做** |
| C. 固定 `2/60` 判掉帧 | 120Hz 设备全员误报（我们旧实现就栽在这） |
| D. 用设备实测帧预算 `targetTimestamp - timestamp` | 自适应刷新率，正确做法 |

**各家**：Sentry 用 CADisplayLink + 实测帧预算，产出 `frames_slow` / `frames_frozen` 计数；Matrix `WCFPSMonitorPlugin` 在**滚动时**才采主线程栈，定位卡顿函数。

**我们的选择**：A + D。`TDDisplayLinkHub` 进程内唯一 displayLink，多消费者共享（避免多个 displayLink 互相抢）。窗口 10s，>1s 间隔整段丢弃。

**理由**：C 有真实线上事故（120Hz 全员误报）；B 侵犯宿主。

**局限**：静止页面帧率恒等于刷新率上限，**全局 FPS 只能看趋势，不能用来定位**。这也是必须做页面级的原因。

---

## 3. 页面级渲染质量

| 候选路线 | 说明 |
|---|---|
| A. swizzle `viewDidAppear`/`viewDidDisappear`，VC 粒度 | Firebase 做法，能回答「哪个页面卡」 |
| B. 只在 `viewDidDisappear` 结算 | Firebase 做法，**用户停在页面不动就永远没数据** |
| C. 加时间切片，窗口到点就结算一片 | 解决 B 的缺陷 |
| D. 按 keyWindow 门控 | 排除非活跃窗口/被 present 未成为 key 的页面 |

**各家**：Firebase Performance screen rendering trace —— A + B + D，无 C。慢帧 = 超过一帧预算 1.5 倍；冻结帧 = 单帧 > 700ms。

**我们的选择**：A + C + D。切片默认 30s（可配 `screenSliceSeconds`）；`phase=slice|final` 区分。

**理由**：C 是补 Firebase 的已知缺口，属于我们自有增强，**必须标注**：同一页面会产出多片，后端按 `phase` 聚合，**不能直接求和**。

**局限**：容器页（导航/分栏）与业务页的关系只能靠类名前缀粗筛（`UI*` / `_*` 跳过），宿主自定义容器无法识别。

---

## 4. ANR / 卡顿检测 —— 已定（A + 两阈值分级）

| 候选路线 | 机制 | 优点 | 缺点 |
|---|---|---|---|
| **A. 独立线程 semaphore ping**（我们采用 = Sentry 做法） | 监视线程向主线程投空 block，超时未执行即判定卡顿 | 能检测**任何**主线程阻塞，包括死循环；实现简单 | 卡顿期间需高频采样堆栈 |
| **B. RunLoop Observer**（Matrix `WCCrashBlockMonitorPlugin`） | 观察 `beforeSources`/`afterWaiting`，用超时判定 | 平时开销极低，不额外投递 block | 主线程卡在纯计算死循环时 RunLoop 不转，**恰好漏掉最严重的场景** |
| **C. 编译期插桩 + 慢函数**（Matrix TraceCanary Android） | 字节码/编译期改写，记录每个方法耗时 | 能定位到**具体函数** | iOS 只能靠 `-finstrument-functions`，Release 下开销不可接受 |

**各家**：Sentry 用 A（V2 在 A 之上叠加帧延迟判定）；Matrix iOS 用 B；Matrix Android 用 C。

**结论：A，不做 A+B 混合。** B 更省电，但它漏掉的正是最需要事后定位的纯计算死循环。
「省电」不构成换一条有盲区路线的理由——真要省电，把采样间隔调大即可。

### 4.1 三个阈值，别混成一个

这是与业界对齐后修掉的一个真实缺陷。之前只有一个 250ms 阈值，既当采样起点又当上报条件，
结果是 2~8 秒的卡顿和 250ms 的抖动在同一条事件里无法区分，且 250ms 级抖动刷屏。

| 阈值 | 值 | 作用 |
|---|---|---|
| 采样起点 `hangThresholdMs` | 250ms | 一开始卡就采栈。起晚了拿不到调用链前段 |
| 上报阈值 `anrReportThresholdMs` | **2000ms** | 低于它不产生 `anr` 事件。对齐 Sentry `defaultAppHangTimeoutInterval = 2.0` |
| 致命推测 `fatalThresholdMs` | **8000ms** | 达到即认为可能已被系统 watchdog 终止（复用终止归因里的同一常量） |

**为什么「早采晚报」**：250ms 级的抖动在启动、页面切换时极常见，逐条上报会把真实卡顿淹没；
而等到 2s 才开始采样，早期调用链已经拿不到了。两件事必须分开。

### 4.2 分级

| 字段 | 取值 | 依据 |
|---|---|---|
| `severity` | `hang`（2s~8s）／`fatal_suspected`（≥8s） | Sentry 的 non-fatal / fatal 两段式；Datadog 同样是「未结 hang 落盘、下次启动升格 fatal」 |
| `blockType` | `fully_blocked`／`partially_blocked` | 卡顿期间 displayLink 回调次数 ≤1 即完全停摆。思路对齐 Sentry V2 `framesContributingToDelayCount == 1` |

**两者的价值**：`fatal_suspected` 的进程常在事件发出前就消失，所以另有 `onProgress`
每秒把时长落盘，下次启动由归因链取用；`blockType` 区分「主线程被独占」和
「渲染链路吃力」，排查方向完全不同。

### 4.3 真实开销

- **平时**：每秒 4 次空 block，执行时间微秒级，可忽略。
- **卡顿时**：每 50ms 一次主线程堆栈采样。卡 5 秒 = 100 次采样，这是真正的成本——
  但卡顿时用户本来就在等，此时优先保证有数据。

**未采用的**：Sentry V2 的 `partially_blocked` 用帧延迟精确判定，我们用的是
「卡顿期间是否出过帧」这一近似，口径相近但不等价，已在 CHANGELOG 的「已知限制」标注。

---

## 5. 崩溃采集

| 候选路线 | 说明 |
|---|---|
| A. SDK 自己注册 signal / NSException handler（KSCrash / PLCrashReporter / Sentry 自研） | 完整控制，但要和宿主已有方案打架 |
| B. 不注册，依赖宿主落盘 JSON，SDK 负责补发 + 补全维度 | 不冲突，可共存 |
| C. 只依赖 MetricKit 崩溃诊断 | iOS 14+，延迟一天，覆盖率不满 |

**各家**：Matrix 基于 KSCrash（A）；Sentry 自研（A）；Firebase Crashlytics（A）。

**我们的选择**：B。宿主 TBCrashReporter 已独占 handler，注册第二个会**顶掉**它的实现。

**理由**：这是接入约束决定的，不是技术偏好。SDK 的增量价值是：补上镜像 UUID、结构化栈、上次会话的真实面包屑轨迹、去重 id。

**局限**：崩溃捕获能力等价于宿主，SDK 不改进它。文档必须写明「崩溃率准确性取决于宿主 reporter」。

---

## 6. OOM / 终止归因 —— **待决策**

| 候选路线 | 说明 | 覆盖 | 精度 |
|---|---|---|---|
| **A. MetricKit `MXAppExitMetric`** | 系统权威来源，累计计数取增量 | iOS 14+，且用户需开启「共享 iPhone 分析」 | 高 |
| **B. 启发式现场**（heartbeat + footprint 序列 + cleanExit 标记） | 下次启动推断 | 全版本全用户 | 中，只能给证据 |
| **C. 内存分配记录**（Matrix `WCMemoryStatPlugin`） | hook malloc，记录每个对象的分配栈，OOM 时上报 | 全版本 | 高（能定位到分配栈） |
| **D. 只信 A** | 简单 | iOS 14+ 且开启分析的用户 | 高但残缺 |

**各家**：Sentry 只做 B，且明确排除强杀/调试器/模拟器/OS 升级/app 升级/首启；Matrix 做 C；Apple 提供 A。

**我们的选择**：**B 为主 + A 补充**，双源各自带 `attribution` 标记，后端按来源分组。**刻意不用 D**（国内关闭分析比例高，会大面积缺失），**也不用 C**（malloc hook 对性能影响大，且需要处理多线程/递归分配，工程量最大）。

> 口径更正（2026-11）：这不是「业界标准双源」。Sentry / Datadog 的 OOM 主路径都是纯 B；
> Sentry 的 `MetricKitIntegration` 是默认关闭的 opt-in，且只收 hang / 磁盘 / CPU 诊断，
> 不读 `MXAppExitMetric`。A 是我们自己多跑的补充源，真机 `metrickitPayloads=0`，
> 对外 OOM 率的分子只取 B。详见 `CAPABILITY-IMPLEMENTATION.md` 第 10 节。

**B 的判定链**（命中即止）：
`cleanExit` → 调试器/模拟器 → 首启/版本变化 → `hang≥8s` 且前台 = watchdog → `footprint/limit≥0.85` 或 `可用<50MB` = jetsam → 后台任务未结束 = backgroundTaskTimeout → 有内存警告 = memoryPressure → `unknown_unclean`

**关键取舍**：证据不足时**报 unknown，不冒充 OOM**。老实现是"没干净退出就报 watchdog"，导致强杀和 OOM 无法分开，OOM 率完全失真。

**待确认**：是否需要 C？代价是 hook malloc + 分配栈采样，粗略估计会使内存操作开销上升一档，且需要大量边界处理。

---

## 7. 内存 / CPU / 磁盘 / 电池 / 线程 / FD

| 候选路线 | 说明 |
|---|---|
| A. `task_vm_info` 读 `phys_footprint` | 与 Xcode memory gauge 同源，是 jetsam 判据 |
| B. `os_proc_available_memory()` | iOS 13+，直接给可用余量 |
| C. `mach_task_basic_info.resident_size` | RSS，与 footprint 不同，含共享页，**不用于 jetsam 判定** |
| D. 定期全量采样 vs 分频采样 | 内存要 5s 级才能看爬升；CPU/磁盘 30s 足够 |

**我们的选择**：A + B，分频：内存 5s（只落盘不上报，60 点环形），其余 30s（上报）。

**理由**：OOM 前兆是内存爬升曲线，30s 采样看不到；但把其他指标也提到 5s 会让事件量放大 6 倍、白烧电。

**局限**：`fd_count` 在部分系统版本受限；`thread_count` 与 `fd_count` 的采集路径需要按 `cap.*` 标注可用性。

---

## 8. 网络

| 候选路线 | 说明 |
|---|---|
| A. `URLSessionTaskMetrics`（delegate 交付） | **唯一**能拿到 DNS/TCP/TLS/TTFB 分阶段 |
| B. 交换 `URLSession` 初始化方法接管业务 session | iOS 18 起初始化器不再是 ObjC 方法，**已不可行** |
| C. 交换 `dataTask` 完成回调 | 能拿成功率/状态码/总耗时/流量，**没有分阶段** |
| D. 只提供 `makeInstrumentedSession` 让业务显式创建 | 分阶段完整，但要求业务改代码 |

**我们的选择**：C（默认覆盖所有请求）+ D（需要分阶段的页面显式创建）+ A（D 的 session 内部走 delegate metrics）。

**理由**：B 在新系统已失效；只做 D 会让 90% 的请求没有数据；只做 C 就永远没有分阶段。

**局限**：分阶段数据只覆盖用 `makeInstrumentedSession` 创建的请求，覆盖率需在 `cap.network_phases` 里如实上报。

---

## 9. 页面加载耗时

| 候选路线 | 说明 |
|---|---|
| A. `viewWillAppear → viewDidAppear` | 用户感知的"页面出现" |
| B. `viewDidLoad → 首次 viewDidAppear` | 含构建视图代价，仅首次有效 |
| C. 只在 `viewDidLoad` 记时间戳，不清空 | pop 回来会算出几万毫秒（我们旧实现的 bug） |

**我们的选择**：A + B，且 A/B 都要求 keyWindow 门控；`viewDidLoad` 时间戳用后立即清空。

**局限**：纯 SwiftUI 页面没有 UIViewController 生命周期，需要额外的 `makeUIViewController` 桥接或手工埋点。

---

## 10. 非致命异常

| 候选路线 | 说明 |
|---|---|
| A. 交换 `-[NSException raise]` | 覆盖被业务/框架接住的 ObjC 异常 |
| B. 暴露 `recordNonFatal` 让业务显式上报 | 覆盖 Swift `Error`、降级分支 |
| C. 交换 `objc_exception_throw` | 能拿**所有** `@throw`，但无法区分是否被接住，噪声极大 |

**我们的选择**：A + B。C 不做。

**理由**：C 会把所有被正常 catch 的异常都算成"异常"，数据噪声压过信号。

**局限**：Swift `Error` 无法自动捕获，只能靠 B。

---

## 11. MetricKit 诊断

**我们的选择**：作为**补充源**，不替代自研采集。覆盖崩溃符号化栈、hang 诊断、CPU/磁盘写入异常、`MXAppExitMetric`。

**版本门槛处理**（这是「iOS 13 怎么办」的正面回答）：能力单元 `init?` 在 iOS 13 返回 nil，注册表跳过，其余能力全装；同时 `cap.oom_metrickit=0` 随 `session_start` 上报——**降级是数据里可见的事实，不是文档里的一句免责**。

**局限**：次日批量投递，无实时性；用户关闭「共享 iPhone 分析」后永不到达（用 `metrickitPayloads` 计数反推覆盖率）。

---

## 12. 面包屑

**我们的选择**：内存 100 条环形 + 进后台/崩溃时落盘。崩溃补发时优先用**上次会话**的轨迹（本次会话的轨迹在崩溃时已随进程消失）。

---

## 13. 汇总：需要拍板的分歧点

| # | 项 | 现状 | 备选 | 影响 |
|---|---|---|---|---|
| 1 | ANR 检测 | A：semaphore ping（Sentry 式） | B：RunLoop observer（Matrix 式）／A+B 混合 | 耗电 vs 死循环覆盖 |
| 2 | OOM 深度 | A+B 双源 | 加 C：malloc 分配记录（Matrix 式） | 定位能力 vs 性能开销与工程量 |
| 3 | 崩溃接管 | B：依赖宿主 reporter | A：自带 KSCrash 风格 handler | 是否与宿主冲突 |
| 4 | 出口注入口 | 未开放 | 开放 `start(configuration:sink:)` | 换通道是否要改 SDK 源码 |
| 5 | 全局 FPS | 保留 | 只保留页面级 | 事件量 vs 版本趋势 |
