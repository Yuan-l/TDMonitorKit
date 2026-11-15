# TDMonitorKit 架构决策记录

> 本文先于实现。任何实现改动必须能指回这里的某一条；指不回去的，要么补这条记录，要么不要改。
> 目的：避免"方案一变就要重写"的返工。

## 1. 横向对比（四家真实实现，非二手转述）

| 维度 | Sentry (sentry-cocoa) | Datadog (dd-sdk-ios) | Firebase Performance | Matrix (腾讯/微信) |
|---|---|---|---|---|
| 模块化机制 | Integration 数组 | Core + 独立 Feature 模块 | 单个 product，内部 Instrumentor | Plugin（`MatrixPluginProtocol`） |
| 注册方式 | `installIntegrations()` 统一安装 | `register(feature:)` | 内部固定 | `MatrixBuilder addPlugin:` |
| 依赖提供 | `SentryDependencyContainer`（集中服务定位器） | `FeatureBaggage` + Core | 单例 | Builder 持有 |
| 是否可单独不装 | 是（可失败 init 返回 nil） | 是（不引那个 pod） | 否 | 是（不加那个 plugin） |
| 生命周期 | `install` → `uninstall` | Feature 启停 | 无显式 | `onInit`→`onStart`→`onStop`→`onDestroy` |
| **数据出口** | SDK 内置 Transport | SDK 内置 Upload | SDK 内置 | **外置**：SDK 只产 `MatrixIssue`，经 `onReportIssue:` 交给宿主 |
| 能否按类型取回实例 | 是（`getInstalledIntegration:[Class]`） | 是 | 否 | 是（Builder 持有 plugin 引用） |
| 卸载粒度 | 整体 `removeAllIntegrations` | 单 Feature | 无 | 单 plugin `onDestroy` |
| 页面帧率口径 | `frames_slow` / `frames_frozen` 计数 | RUM view slow/frozen frames | 慢帧/冻结帧，按 VC trace | FPS + 滚动时主线程栈 |
| 页面采集入口 | — | — | **只 swizzle `viewDidAppear:`/`viewDidDisappear:`，且 `view.window.keyWindow` 才起 trace** | RunLoop 状态判定卡顿 |
| 终止/OOM 策略 | 启发式，且明确排除强杀/调试器/模拟器/OS升级/app升级/首启 | — | — | 内存分配记录，OOM 时上报 |
| 版本门槛处理 | 可失败 init（`init?`）+ 编译期 `@available` | Feature 模块按需引入 | — | 单 plugin 粒度 |

## 2. 四家收敛出的形状

尽管技术栈、年代、公司都不同，四家独立收敛到同一组约束：

1. **一个容器**负责持有能力、提供依赖。
2. **能力是可失败创建的离散单元**，不支持就整体不存在，而不是运行时到处 `if #available` 打补丁。
3. **生命周期显式**：init → install/start → uninstall/stop。没有"一个 167 行方法按顺序把所有人串起来"。
4. **数据出口与采集解耦**。Matrix 走到极致——SDK 连上传都不管，只产 `MatrixIssue`。

第 4 条是最有价值的：它意味着**换后端不动采集代码**。这正是"基建先做好、接后端才便利"的机制解释。

## 3. 我们的方案映射

| 我们的类型 | 依据 | 差异与理由 |
|---|---|---|
| `TDMonitorFeature`（`init?` / `install()` / `uninstall()` / `name` / `requires`） | Sentry `SwiftIntegration` + Matrix `MatrixPluginProtocol` | Sentry 的 `install(options:)` 带参；我们把依赖收进 `init(runtime:)`，装的动作无参。等价且更短 |
| `TDMonitorFeatureRegistry` | Sentry 集成数组 + `getInstalledIntegration:` + `removeAllIntegrations` | 多一条 DEBUG 顺序断言（`requires`），提早暴露注册顺序错误 |
| `TDMonitorRuntime` | `SentryDependencyContainer` + Datadog `FeatureBaggage` | 按类型查字典，不做懒加载 |
| `TDEventSink`（`start`/`enqueue`/`flush`/`flushInBackground`） | Matrix `MatrixIssue` + `onReportIssue:`（出口外置） | 我们保留 SDK 内置 HTTP 实现作为默认，但采集侧只认协议 |
| `TDMonitorQueues` | Sentry `SentryDispatchQueueWrapper` | 4 条固定队列，粒度更粗 |
| `TDClock` / `TDManualClock` | 无直接对应（Datadog 有可注入时钟） | 为可测试性引入；时间相关判定必须能确定性断言 |
| 页面 keyWindow 门控 | Firebase `FPRUIViewControllerInstrument` 逐行对应 | 额外加 `isBeingDismissed` / `isMovingFromParent` |
| 终止归因双源（启发式 + MetricKit） | Sentry 启发式排除清单 + Apple MetricKit `MXAppExitMetric` | Sentry 只做启发式；我们两条都跑并各自标记来源 |

## 4. 出口分四层（补齐原「不分层」的债务）

上一版把「`TDTransport` 未按 Datadog 分层」写进 CHANGELOG 的已知限制，这是逃避。
293 行一个类同时做落盘、队列上限、重试、鉴权、HTTP、毒数据隔离，结果是
**出口内部逻辑完全无法单测**——想验证「4xx 会不会丢数据」「二分隔离是否只丢坏的那条」
「429 会不会退避」，都必须起一个真 HTTP 服务。

对齐 Datadog `DatadogCore/Sources/Core` 的 `Storage` / `Upload` / `DataStore` 三子系统：

| 层 | 类型 | 职责 | 可测性 |
|---|---|---|---|
| 落盘 | `TDEventQueueStore` / `TDMMAPQueueStore` | 队列持久化（mmap + CRC/AES/提交位点） | 真机验证 + 注入内存实现 |
| 上传 | `TDBatchUploader` / `TDHTTPBatchUploader` | 把一批 JSON 发出去，翻译成 4 种结果 | 接口可替身 |
| 隔离 | `TDBatchResolver` | 毒数据二分定位 | 纯逻辑，5 条单测 |
| 退避 | `TDRetryPolicy` | 指数退避与重置 | 纯函数，3 条单测 |
| 编排 | `TDTransport` | 入队/出队/排期/记账 | 由上面四层保证 |

拆的过程中查出三个真问题，一并修了：

1. **写放大**：旧实现每条事件都 `JSONSerialization` 整个 pending 数组再原子写盘。
   队列满（1000 条）时每来一条要重写约 600KB，且发生在持锁的串行队列上。
   改为 JSONL 追加写，累计追加超过 `maxQueueSize/2` 才压缩一次。（当前存储已升级为
   mmap 记录级追加：CRC/AES/提交位点，压缩条件改为 `appendedSinceCompact > maxEvents/2`
   或 `bloat > maxQueueSize/2`，触发时写诊断日志，见 `TDMMAPQueueStore` / `TDTransport`。）
2. **假退避**：旧实现的 `backoff` 被计算，但从未用于排期——`retryLater` 只是延迟了
   网络回调的返回，重发时机仍由固定 10s timer 决定。所谓「指数退避」既不退避，
   还让一次 flush 多卡几秒。现在由 `scheduleRetry(after:)` 真正排期。
3. **整份作废**：旧实现 `try? JSONSerialization.jsonObject` 解析整个文件，
   一行损坏就队列归零——恰好在被 SIGKILL 之后、最需要数据的时候丢光。
   改为逐行解析，坏行只损失自己。

## 5. 我们自己判断、没有业界对应的部分

必须显式标注，否则就是"假装对齐业界"：

| 项 | 为什么这么做 | 风险 |
|---|---|---|
| **30s 切片上报** | Firebase 只在 `viewDidDisappear` 结算，用户停首页不动就永远没数据。这是它的已知缺陷 | 同一页面会有多片，后端需按 `phase=slice/final` 聚合，不能直接求和 |
| **`hitchRatio`**（卡顿时长占比） | Sentry 是计数、Datadog 是 hitch rate，口径都不同。长卡比帧占比更贴近体感 | 自有指标，**不可**与别家数字横向比较 |
| **毒数据二分隔离** | 我们后端按整批校验，一条脏数据废掉最多 500 条好数据；Sentry 用 envelope 单条投递不存在此问题 | 全坏批次下请求数放大（上限 24 次） |
| **footprint 5s 序列（60 点环形）** | SIGKILL 类退出没有崩溃栈，唯一证据是死亡前的内存爬升曲线 | 高频写盘，需确保原子写且不阻塞主线程 |

## 6. 决策状态

### 已定

| # | 项 | 决定 | 理由 |
|---|---|---|---|
| 1 | 数据出口 | 默认内置 HTTP + 开放 `start(configuration:sink:)` 注入口 | 开箱可用与可替换性兼顾，接入方不写代码也能跑 |
| 2 | 模块粒度 | **暂缓拆分**：保持单 pod，内部按能力单元分文件 | 见下方「为什么没拆」。类型设计已经就绪，将来拆分不改代码结构 |
| 3 | 页面帧率口径 | slow / frozen + `hitchRatio` | 前两项对齐 Sentry/Firebase；`hitchRatio` 为自有指标，**文档必须标明不可横比** |
| 4 | 全局 FPS | **删除**，只保留页面级 | 全局值只能看趋势、不能定位，且静止页面读数恒为刷新率上限，信息量低 |
| 5 | ANR 检测路线 | **A：semaphore ping**，并补 2s 上报档 | ping 能抓纯计算死循环，RunLoop observer 抓不到。省电不是换一条有盲区路线的理由 |
| 6 | ANR 分级 | 2s 上报（`hang`）／8s 致命推测（`fatal_suspected`），并区分完全/非完全阻塞 | 对齐 Sentry `defaultAppHangTimeoutInterval = 2.0` 与 5 类划分的核心两维 |
| 7 | OOM 深度 | MetricKit + 启发式双源，**不做 malloc hook** | hook 内存分配写错会让业务崩溃，且与宿主已有工具冲突；改为补上下文证据 |
| 8 | 崩溃接管 | 不接管，依赖宿主 reporter | 宿主已独占 handler；signal-safe 代码风险高，需专门崩溃矩阵验证 |

### 为什么没拆子 pod（决策 2 的实际状态）

文档早前把「拆 Core + 子 pod」写成了已定，但 `TDMonitorKit.podspec` 一直是单 pod。
这是文档与代码不一致，必须纠正而不是放着。

不拆的真实理由是：本项目的组件通过自定义注入机制（`local_pod_interceptor.rb` +
`Podfile.local`）以 `:path` 接入，subspec 与 test_spec 的组合在该机制下会触发
`undefined method 'root' for nil`。拆成多个 pod 意味着每个子 pod 都要在两处维护声明，
一旦有人漏改，`pod install` 直接失败——收益（包体）远小于维护成本。

代码侧已经按能力单元组织（`TBMonitorFeatures.swift` 里每个 `TDMonitorFeature` 都自带
install/uninstall，彼此不直接引用），所以真到需要拆的那天，只是移动文件 + 补 podspec，
不需要重写。

## 7. 网络层分三层（补齐「网络没有统一出口」的债务）

上一版的网络采集是「三处方法交换 + 一个全局单例」，问题与当初的 `TDTransport`
同构：**采集能力焊死在具体实现上**，业务一旦换网络库或自建 session，能力就整段消失。

现在分成三层，边界是「谁拥有什么」：

| 层 | 内容 | 归属 | 为什么在这一层 |
|---|---|---|---|
| 契约层 `TBMonitorNetworkContract` | `TDNetworkRequest` / `Result` / `Context` + 三族拦截器协议 | SDK 定义，业务实现 | 议的是「可观测的事实」，与用什么库无关 |
| 出口层 `TBMonitorNetworkClient` | `TDURLSessionNetworkClient` | 参考实现，业务可替换 | 有统一网络层的业务不该被 SDK 绑架架构 |
| 采集层 `TBMonitorNetworkCollectors` | metrics 映射、trace 注入、幂等重试、样本 observer | SDK 拥有 | **复用点在这里**：同一批采集器可挂到任意 client |

关键判断：**复用发生在采集器，不在 client。**
如果复用的是 client，那么不走这个 client 的流量（SDWebImage、WKWebView、
三方 SDK）就永远采不到，而业务也失去了选型自由。

配套的口径修正：

- `TDNetworkMetricsMapper` 成为 metrics → 样本的唯一折算式，
  legacy swizzle 与统一出口共用。两份实现必然漂移，而分阶段报表最怕口径不一致
- `TDRequestTag.isInternal` 取代 `url.contains(host)` 字符串匹配识别上报自身流量。
  字符串匹配在后端换域名 / 加 CDN 时会静默失效，属于「数据污染且不自知」
- 上报请求不进 retrier 链（`shouldConsultRetrier` 纯函数）：它已有
  `TDRetryPolicy` 的指数退避，叠加即双重退避

## 8. 与当前代码的一致性

已完成且与本方案一致，不因决策变化而返工：

- 协议抽象、容器、能力单元、注册表、统一队列、可注入时钟
- 7 处具体 `TDTransport` 依赖全部改为 `TDEventSink`
- `start()` 从 167 行降为注册 + 安装
- 页面 keyWindow 门控
- `autoCollect` 从死配置变为真开关
- ANR 两阈值分离（采样 250ms / 上报 2s / 致命 8s）+ 完全/非完全阻塞分类
- 慢帧阈值改为 `1/(fps-1)`，与 Sentry、Firebase 一致；慢帧与冻结帧互斥计数
- 出口拆为 Store / Uploader / Resolver / RetryPolicy 四层，编排层只剩调度
- OOM 两条来源带同一份证据（footprint 序列 + 带时间偏移的现场时间线）
- 接入自检：崩溃路径未配置、明文 HTTP、localhost 上报等会点名，不再静默
- 网络分三层：契约 / 参考出口 / 采集器，复用点是采集器而非 client
- metrics 与 completion 的时序竞争已处理（1s 兜底 + 迟到丢弃），
  依据是 AFNetworking 源码注释 `AFURLSessionManager.m:1101`
- 单测 82 条：注册表顺序/跳过/逆序卸载、容器取服务、事件字段截断与维度、
  帧会话慢帧/冻结帧/中断丢弃/窗口重置、归因判定链 12 条、ANR 分级规则、
  退避序列、毒数据隔离、队列落盘（mmap / 压缩 / 淘汰一致性）、OOM 时间线、接入自检

受决策影响、需要跟进的：

- 决策 1 → `TDMonitor.start` 增加 `sink:` 参数，`TDEventSink` 提为 `public`
- 决策 2 → 目录与 podspec 重构，**不影响类型设计**
- 决策 3 → 已按此实现，无需改动
- 决策 4 → 删除 `TDFPSFeature` 与 `TDCollectors` 的全局 FPS 上报（保留 `TDDisplayLinkHub`，页面级依赖它）

## 9. 对外扩展契约（2.2.0）

之前的定位是「内置能力可用」，但所有协议与容器都是 `internal`：
- 能力只能「用内置的」——别的团队想叠加自有采集，唯一的路是 fork 或等 SDK 排期；
- 采样器 / 契约只能「SDK 自己用」——宿主想复用内存采样、想挂自己的网络拦截器，都得重新造一遍。

这正是「无法复用、无法工程化」的骨架级根因：组件对外是一个黑盒，
积木和能力单元都锁在里面。2.2.0 把这个边界打开——**公开该公开的全部，
但不改默认行为、不动既有 API**。

### 9.1 能力可外部扩展

新增门面，业务方在 `start()` 前登记自定义能力类型即可：

```swift
final class MyLatencyFeature: TDMonitorFeature {
    static let name = "my_latency"
    static let requires: [String] = ["td_resource"]   // 需要时声明依赖

    required init?(runtime: TDMonitorRuntime) {
        // 环境不满足就返回 nil，SDK 静默跳过，不阻断其它能力
    }
    func install() -> Bool { /* 挂 hook、注册采样器 */; return true }
    func uninstall() { /* 还原 */ }
}

TDMonitor.register(MyLatencyFeature.self)
TDMonitor.shared.start(configuration: config)
```

自定义能力与内置能力走**完全相同的路径**：

| 环节 | 内置 / 外部是否一致 |
|---|---|
| 依赖注入 | 同一个 `TDMonitorRuntime` 容器（`provide` / `service`） |
| 顺序安装 / 逆序卸载 | 同一个 `TDMonitorFeatureRegistry`，按注册顺序装、逆序拆 |
| 依赖缺口 | 同一个 `requires` 机制，缺口记入 `runtime.blockedFeatures` 并留日志 |
| 能力矩阵对账 | 同样纳入 `session_start` 的 `cap.*` 维度，降级在数据里可见 |

门面背后是闭包式注册入口 `TDMonitorFeatureRegistry.register(_:name:requires:)`，
`name` / `requires` 从类型上取后透传，避免在公开 API 上暴露 Swift 元类型。
两条约束（写进文档也写进单测）：

- **必须在 `start()` 之前调用**——注册表在 `start()` 内构建，之后登记无效；
- **同名只登记一次**——`register` 内部按 `name` 去重，重复注册被静默忽略，
  避免能力装两遍、观察者挂两次。

扩容测试 `TDMonitorExtensionTests` 覆盖了「公开注册 → 安装」「同名去重」
「门面 + `start(configuration:sink:)` 端到端」三条路径。

### 9.2 可复用积木公开

除能力系统外，下列类型一并提为 `public`，宿主可直接调用，无需绕经监控 SDK：

- 采样器：`TDResourceSampler`（内存 / CPU / 磁盘 / 线程 / FD）
- 网络契约：`TDNetworkSample`、`TDNetworkClient` 三族拦截器
  （`TDRequestAdapter` / `TDRequestRetrier` / `TDNetworkObserver`）
- 上下文与维度：`TDContext`、`TDCapabilityMatrix`、`TDAppStateTracker`
- 二进制与现场：`TDBinaryImage`、`TDBreadcrumbStore`
- 出口契约：`TDEventSink`（连同 `start(configuration:sink:)` 注入点）

公开边界的判定原则：**注册表 / 运行时 / 契约公开，但默认 `sink`
（`TDTransport`）仍走内置**——宿主只有显式注入才替换出口，
不会因「公开了协议」就意外把上报逻辑改成可被外部改写的形态。

### 9.3 为什么这层补齐后才是「工程化」

工程化的前提不是「功能多」，而是「别人能在不碰你源码的前提下叠加与复用」：

- 能力可扩展 → 接入方不再需要 fork 来加自有采集，SDK 演进与业务演进解耦；
- 积木公开 → 采样与契约成为团队公共资产，重复造轮子的成本消失；
- 测试注入点（`sink` / `clock` / 自定义能力）→ 接入与回归都能脱离真机、确定性验证。

至此「底座具备、能力可插拔、积木可复用」三者齐全，下一步才是「接入具体业务场景」。

