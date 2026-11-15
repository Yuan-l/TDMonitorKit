# 实现与业界源码对账

> 目的：回答「说是参考业界，实际有没有自行发挥」。
> 方法：**逐条拿我们的代码去对业界源码**，不用「业界通常」这类说法。
> 分类只有四种，不做模糊表述：
>
> - **A 对齐**：与某家实现一致，能指出对方文件与行
> - **B 近似**：思路一致、实现简化，差异点写清
> - **C 偏离**：明知不同、有理由，理由写清
> - **D 自创**：业界没有，风险自负
>
> 对账时间：2026-11-14，抓取各仓库 `main` / `develop` / `master`。

---

## 1. 能力单元协议（`TDMonitorFeature`）

**业界**：`getsentry/sentry-cocoa` `Sources/Swift/Core/Integrations/Integrations.swift`

```swift
@_spi(Private) @objc public protocol SentryIntegrationProtocol: NSObjectProtocol {
    func uninstall()
}

protocol SwiftIntegration: SentryIntegrationProtocol {
    associatedtype Dependencies
    init?(with options: Options, dependencies: Dependencies)
    static var name: String { get }
}
```

安装循环（同文件末尾）：

```swift
integrations.forEach { anyIntegration in
    guard let integration = anyIntegration.install(options, dependencies) else { return }
    SentrySDKInternal.currentHub().addInstalledIntegration(integration, name: anyIntegration.name)
}
```

**我们**：`Classess/TBMonitorCore.swift:167`

```swift
protocol TDMonitorFeature: AnyObject {
    static var name: String { get }
    static var requires: [String] { get }
    init?(runtime: TDMonitorRuntime)
    func install() -> Bool
    func uninstall()
}
```

| 项 | Sentry | 我们 | 判定 |
|---|---|---|---|
| 可失败构造决是否安装 | `init?(with:dependencies:)` | `init?(runtime:)` | **A** |
| 名称标识 | `static var name` | 同 | **A** |
| 卸载 | `uninstall()` | 同 | **A** |
| **安装动作** | **协议里没有 install**，实例化成功即视为装上 | `install() -> Bool` | **C** |
| 类型擦除存进数组 | `AnyIntegration` 闭包 | `Entry.make` 闭包 | **A** |
| 顺序依赖 | 数组顺序 + 源码注释（"The order of integrations here is important"） | `requires` + DEBUG `assert` | **D** |
| 依赖注入方式 | `associatedtype Dependencies`（泛型，编译期约束） | 运行期 `[ObjectIdentifier: Any]` 字典 | **C** |
| 安装实例归属 | Hub 持有，可按类型取回 | registry 持有 | **A** |

### 偏离的代价（不是白拿的）

1. **`install() -> Bool` 让协议比业界复杂一档。** 好处是能表达「构造成功但运行期失败」
   （如系统接口被权限拒绝）。Sentry 只能把所有检查塞进 init，装不上就是装不上。
   代价是调用方要处理两种失败，且「init 返回 nil」与「install 返回 false」语义容易混淆。
2. **运行期服务字典丢掉了编译期类型安全。** `runtime.service(T.self)` 取不到只能 nil 降级，
   **写错类型不会编译报错**——Sentry 的 `associatedtype` 能编译期发现。
   这是真实的可维护性损失，属于我为了「一个容器装所有服务」的便利做的取舍。

### `requires` 是自创，且有一个实际风险

Sentry 靠数组顺序 + 注释表达依赖，写错就写错了，没有校验。我加了 `requires`，
但断言包在 `#if DEBUG` 里——**Release 构建下顺序写错会静默继续**：能力装上了，
它依赖的服务却没装，表现是「某个指标突然没有数据」，排查成本很高。

这是自创带来的新失败模式，不能只享受好处。已在下方「待修正」列出。

---

## 2. 依赖容器（`TDMonitorRuntime`）

**业界**：`SentryDependencyContainer` 是**编译期确定的属性列表**
（`dispatchQueueWrapper` / `fileManager` / `binaryImageCache` / `extraContextProvider`…），
懒加载，类型在编译期就定死。

**我们**：5 个固定 `let` 属性 + 一个 `[ObjectIdentifier: Any]` 字典。

| 项 | Sentry | 我们 | 判定 |
|---|---|---|---|
| 固定依赖 | 属性，编译期类型安全 | 5 个 let 属性 | **A** |
| 能力间共享服务 | 属性懒加载 | 运行期字典 | **C**（同 §1 第 2 点） |

---

## 3. 事件出口（`TDEventSink`）

**业界**：`DataDog/dd-sdk-ios` 的 `DatadogCore/Sources/Core/` 是**七个目录各司其职**：
`Context`（维度）、`DataStore`（落盘）、`Storage`（存储抽象）、`Upload`（上传抽象）、
`MessageBus`（能力间通信）、`TLV`（存储格式）、`RemoteConfigurationProvider`。

**我们**：`TDEventSink` 仍是 4 个方法（`start` / `enqueue` / `flush` / `flushInBackground` /
`stop`），但 `TDTransport` **已不再是一个类干六件事**。它现在只做**入队、出队、排期、记账**，
把其余四件事委托出去：

| 职责 | 实现 | 对应 Datadog |
|---|---|---|
| 落盘（mmap 追加写 / CRC / 压缩） | `TDEventQueueStore` / `TDMMAPQueueStore` | `Storage` |
| HTTP 批量发送（401/4xx/5xx/429 区分） | `TDBatchUploader` / `TDHTTPBatchUploader` | `Upload` |
| 毒数据二分隔离（纯函数） | `TDBatchResolver` | `DataStore` 的隔离职责 |
| 指数退避与重置（纯函数） | `TDRetryPolicy` | — |

| 项 | Datadog | 我们 | 判定 |
|---|---|---|---|
| 采集侧依赖抽象而非实现 | 依赖 Storage / Upload 协议 | 依赖 `TDEventSink` 协议 | **A** |
| 存储与上传分层 | **两层分开** | **已拆为 Store / Uploader / Resolver / RetryPolicy 四层** | **A**（原审计记为 C，已修正） |

### 这一处已闭环

> 说明：初版审计（本文件本节的旧结论）写 `TDTransport` 是「组包 + 落盘 + 重试 + 4xx/5xx + 401 + 上传」
> 的合成类、列为「本轮不修的已知债务」。**那是写审计时的过时判断**——出口分层实际上已经在
> 2.0 拆完（见 CHANGELOG 2.0「数据出口拆为四层」），本次二次对账已核对代码确认。
> 上面旧结论作废，改记为本条已对齐。

拆层之后，**可测性边界从 sink 推进到了出口内部**：入队、批量切分、二分隔离、重试退避
各自是纯函数或被独立类持有，无需启动真实 HTTP 栈即可单测（测试见
`TDNetworkLayerTests`）。换出口时也能只换 `TDBatchUploader` 而保留落盘与重试，
不再需要把 `TDTransport` 整个重写——这正是当初对照 Datadog 想达到的目标。

---

## 4. ANR

**业界**：`SentryANRTrackerV1.swift` / `V2.swift`、`SentryAppHangTypeMapper.swift`、
`DatadogRUM/.../AppHangs/*`、`matrix-iOS/.../WCBlockMonitorConfiguration.h`

| 项 | Sentry | Datadog | 我们 | 判定 |
|---|---|---|---|---|
| 检测机制 | 独立线程 + `DispatchQueue.main.async` tick | 独立线程 + 主队列 task + 信号量 | 独立线程 + `DispatchSemaphore` | **A** |
| 判定阈值 | `defaultAppHangTimeoutInterval = 2.0` | `appHangThreshold`（构造参数） | `anrReportThresholdMs = 2000` | **A** |
| 轮询粒度 | `timeout / 5` = 400ms | `threshold × 0.025` = 50ms | 检测 250ms / 采样 50ms | **B**（切分方式不同，量级接近） |
| 完全/非完全阻塞 | ✅ `framesContributingToDelayCount == 1` | ❌ | 帧回调数 ≤1 | **B**（思路同，判据不同） |
| hang / fatal 分段 | ✅ 5 类（fully/non × fatal/non + unknown） | ✅ 2 类 | 2 维：`severity` × `blockType` = 4 组合 | **A** |
| 致命闭环 | ANR 只报 non-fatal，被杀走 WatchdogTermination | 落盘 pending hang，下次启动升格 fatal | `onProgress` 每秒落盘，归因链取用 | **B**（同 Datadog 思路） |
| 误报剔除 | 后台/挂起 `delta >= timeout` 丢弃、1 分钟内不重复 | `falsePositiveThreshold = 30s` | 调试器/模拟器（**缺**「1 分钟内不重复」） | **C**（漏了一个防护） |

### 这里有一处需要承认的缺口

Sentry 有「同一卡顿在时间窗口内不重复上报」的抑制，Datadog 有 30 秒误报阈值。
我们两样都没有——每次 `loop` 一轮独立判断，同一个长卡顿在主线程恢复前后有可能被判两次。
目前靠「2s 上报阈值 + 一次只结算一次」勉强压住，但没有显式抑制逻辑。

### `blockType` 与 Sentry 的差异必须说清

Sentry：`framesContributingToDelayCount == 1`，是**卡顿结束后回溯**「有多少帧共同贡献了这段延迟」。
我们：卡顿窗口内 displayLink 回调次数 ≤1，是**实时计数**。

- 主线程完全卡死时两者结果一致（都判完全阻塞）
- 主线程在跑但渲染慢时：Sentry 能识别出「多帧贡献」，我们只能看到「出了几帧」
- **不等价**，已在 CHANGELOG 标注

---

## 5. OOM / 进程被系统杀

**业界**：`SentryWatchdogTerminationLogic.swift`、`SentryWatchdogTerminationConstants.swift`、
`DatadogRUM/.../WatchdogTerminations/WatchdogTerminationChecker.swift`

| 项 | Sentry | Datadog | 我们 | 判定 |
|---|---|---|---|---|
| 判定方式 | 上次 AppState + 排除项 | 同 | 同 | **A** |
| 排错项 | 模拟器 / release 变化 / OS 升级 / 设备重启 | + debugging / wasTerminated / vendorId / pid / isActive（共 9 条） | 8 条 | **A**（覆盖相当） |
| 归因档位 | **1 档** `WatchdogTermination` | **1 档** | **5 档** | **D** |
| 内存证据 | AppState 内存字段 | AppState 内存字段 | 60 点 footprint 环形 + 内存警告计数 | **B** |
| 分配级证据 | 无 | 无 | 无（Matrix 用 `WCMemoryStat`，本轮明确不做） | 与 Sentry/Datadog **A**，与 Matrix **C** |

### 两处必须承认「没有依据」

**1. `jetsamFootprintRatio = 0.85`**

我们在 `TBMonitorTermination.swift:152` 写了：

```swift
/// 0.85 是业界常用经验值
static let jetsamFootprintRatio: Double = 0.85
```

**「业界常用经验值」这句话我拿不出出处。** Sentry 与 Datadog 都不做 footprint/limit 比值判断，
它们只判断「没干净退出 + 不是已知排除场景」，然后统一叫 WatchdogTermination。
Matrix 走的是分配栈，也不用这个比值。

也就是说：**这个 0.85 是我的判断，不是业界口径**，而注释把它写成了业界口径。
这是本次审计发现的最该改的一处——不是数值可能错，是**注释在撒谎**。

**2. 5 档归因是自创**

Sentry 的措辞是 `"The OS watchdog terminated your app, possibly because it overused RAM."`——
用 `possibly` 是因为它承认自己没有证据。我们拆成
jetsam / watchdog / backgroundTaskTimeout / memoryPressure / unknown 五档，
粒度比业界细，但**每一档都是推断**。文档已标注，但首屏看板如果不显示置信度，
使用者会把它当成结论。这是设计上的风险，不是实现错误。

---

## 6. 页面帧率

**业界**：`SentryFramesTracker.swift`、`FirebasePerformance/.../FPRScreenTraceTracker.m`

| 项 | Sentry | Firebase | 我们 | 判定 |
|---|---|---|---|---|
| 慢帧阈值 | `1 / (actualFPS - 1)` = 16.95ms@60Hz | `1 / 59.0` = 16.95ms | `1 / (fps - 1)` | **A**（本轮修正，此前是 25ms） |
| 冻结帧 | `frozenFrameThreshold = 0.7` | `700 / 1000` | 0.7 | **A** |
| 慢/冻结互斥计数 | ✅ `>slow && <=frozen` 才计 slow | ✅ 三个独立计数器 | ✅ | **A** |
| 统计单位 | 全局 | 每 VC 一条 trace | 每 VC 一个会话 | **A**（对齐 Firebase） |
| UI 门控 | — | `view.window.keyWindow` | 同 | **A** |
| 切片上报 | 无 | 只在 `viewDidDisappear` 结算 | 30s 切片 | **D** |
| `hitchRatio` | 无 | 无 | 有 | **D** |

### 之前的 25ms 是怎么来的

`帧预算 × 1.5`，没有出处，是我自己拍的系数。后果是把 17~25ms
（轻微但用户可感知的卡）整段漏计。本轮已改为 `1/(fps-1)`，与两家一致。

这件事本身就是「表面参考、实际发挥」的实例：文档写着「对齐 Firebase」，
代码却用了 Firebase 没有的 1.5 倍系数。

---

## 7. 汇总：哪些是真的对齐，哪些是我自己拿的主意

| 能力 | 真对齐（A） | 近似（B） | 偏离（C） | 自创（D） |
|---|---|---|---|---|
| 能力单元 | 可失败构造、name、uninstall、类型擦除 | — | `install() -> Bool`、运行期服务字典 | `requires` |
| 出口 | 依赖协议而非实现；存储/上传/隔离/退避已拆为四层 | — | — | — |
| ANR | 检测机制、2s 阈值、分段思想 | 轮询粒度、blockType 判据、致命闭环 | 缺重复上报抑制 | — |
| OOM | 判定方式、排除项 | 内存证据 | — | 5 档归因、**0.85 无出处** |
| 帧率 | 慢帧/冻结阈值、互斥计数、页面粒度、keyWindow | — | — | 30s 切片、hitchRatio |

**A 类占多数，但 D 类集中在这几处：`requires`、5 档 OOM、30s 切片、hitchRatio、
0.85 阈值。** 这些要么标注为自有设计（前四项已在文档写明），要么本来就是错的（第五项）。

---

## 8. 待修正（本审计的直接产出）

| # | 问题 | 性质 | 处理 |
|---|---|---|---|
| 1 | `jetsamFootprintRatio = 0.85` 注释声称业界口径，实际无出处 | **注释与事实不符** | 已改注释为「自有经验值」，写明 Sentry/Datadog/Matrix 都不做此项判断。**未开放配置**——加参数要穿透 config → runtime → 分类器三处，当前阶段收益不抵风险，保持常量并把依据写清 |
| 2 | `requires` 用 `#if DEBUG assert`：开发期崩宿主，Release 静默 | 自创引入的新失败模式 | **已去掉 assert**。改为 DEBUG/Release 一致的 `noteBlocked` + warning 日志。理由见下 |
| 3 | 「同一卡顿不重复上报」抑制缺失 | 相对 Sentry/Datadog 的功能缺口 | **已补**：`TDHangWatchdog.shouldReport` 用 2s 窗口抑制重复结算，对齐 Sentry V2 的 `lastAppHangStoppedSystemTime + timeoutInterval` |
| 4 | `TDTransport` 未按 Datadog 分层 | 架构债务 | **已闭环**：出口已拆为 `TDEventQueueStore` / `TDBatchUploader` / `TDBatchResolver` / `TDRetryPolicy` 四层（对齐 Datadog Storage/Upload），可测性边界推进到出口内部。初版审计误记为「本轮不修」，本次二次对账已更正 |

### 关于 #2：为什么是去掉断言而不是加强断言

第一版我打算「Release 也加日志，DEBUG 保留 assert」。想清楚之后改成了**直接删掉 assert**：

- 监控组件让宿主 App 在自己装配出错时崩溃，是把「可观测性工具」变成了「新的崩溃源」。
  一个测不出问题的 SDK 顶多没用，一个会崩的 SDK 是负资产。
- 而且 assert 只在 DEBUG 生效，线上那条分支根本没跑过——「只在开发期安全」本身就不是工程化。
- 删掉之后 DEBUG / Release 走同一条路径，不需要维护两套语义。

代价是开发期不再有强制中断。换来的是「序列错了就少一个指标，且有日志和 `blockedFeatures` 可查」，
这个取舍比「崩一下提醒你」更符合这个组件在宿主里的位置。

---

## 9. 复核命令

```bash
# Sentry 能力单元协议（对照 §1）
curl -s https://raw.githubusercontent.com/getsentry/sentry-cocoa/main/Sources/Swift/Core/Integrations/Integrations.swift

# Sentry ANR 默认阈值
curl -s https://raw.githubusercontent.com/getsentry/sentry-cocoa/main/Sources/Swift/Options.swift | grep -n defaultAppHangTimeoutInterval

# Sentry 帧阈值与互斥计数
curl -s https://raw.githubusercontent.com/getsentry/sentry-cocoa/main/Sources/Swift/Core/Integrations/FramesTracking/SentryFramesTracker.swift | grep -n "frozenFrameThreshold\|slowFrameThreshold"

# Firebase 慢帧/冻结帧
curl -s https://raw.githubusercontent.com/firebase/firebase-ios-sdk/main/FirebasePerformance/Sources/AppActivity/FPRScreenTraceTracker.m | grep -n "SlowFrameThreshold\|FrozenFrameThreshold"

# Datadog watchdog 排除项
curl -s https://raw.githubusercontent.com/DataDog/dd-sdk-ios/develop/DatadogRUM/Sources/Instrumentation/WatchdogTerminations/WatchdogTerminationChecker.swift | sed -n '60,125p'
```

---

## 10. 自创项收口结论（逐项复查，2026-11-14 二次对账）

> 背景：§1 / §5 / §6 把 `requires`、5 档 OOM、30s 切片、`hitchRatio`、0.85 比值标记为
> D 类（自创，业界没有）。本次二次对账逐项复查，结论如下。原则：**能对齐业界的
> 就对齐；必须偏离的写清理由、标出残余风险、并用单测锁住契约**——而不是删掉它们。

### 10.1 `requires` + 运行期服务字典 → 保留

- **业界（Sentry）**：`associatedtype Dependencies` 编译期约束；安装顺序靠数组顺序 + 注释，写错就写错、无校验。
- **我们**：运行期 `[ObjectIdentifier: Any]` 服务字典 + `requires` 名字顺序，`noteBlocked` 留痕。
- **结论：保留。** 理由：我们的能力需要从容器取多种不同服务（bridge / appState /
  recorder），Sentry 每 integration 一个 associatedtype 的刚性约束不适合这种「一对多」
  取依赖；且 Sentry 自己也不做顺序校验，我们反而用 `requires` + `noteBlocked`
  在 Release 也能留痕，比业界更安全。
- **残余风险**：运行期字典取错类型不编译报错（§1 已记）。
- **加固**：新增公开诊断 `TDMonitor.blockedFeatures`，并补 `TDRegistryGraphTests`
  锁住「内置 12 能力的 `requires` 图谱自洽（`start` 后 `blockedFeatures` 为空）」。

### 10.2 OOM 5 档归因 → 保留

- **业界（Sentry / Datadog）**：统一 1 档 `WatchdogTermination`，措辞 `possibly`。
- **我们**：jetsam / watchdog / backgroundTaskTimeout / memoryPressure / unknown_unclean
  五档，各带 `confidence`（0.2~0.95）。
- **结论：保留。** 理由：五档对「下一步排查往哪走」更可操作（内存型 vs 后台任务型 vs
  强杀），且每档带置信度，后端展示时必须带 `confidence`、不当事实呈现——这比业界
  统一 `possibly` 反而更诚实。
- **残余风险**：每档仍是推断，无分配级证据（Matrix `WCMemoryStat` 路线本轮不做）。
  若后端把 `attribution` 当结论计数会高估 OOM；`cap.oom_*` 维度 + `confidence` 已给纠偏手段。
- **加固**：`TDTerminationClassifierTests` 覆盖五档 + 6 类排除项 + 0.85 比值分支 +
  判定优先级。

### 10.3 30s 切片 + `hitchRatio` → 切片保留，`hitchRatio` 保留为派生指标

- **业界（Sentry / Firebase）**：只在 `viewDidDisappear` 结算一次。
- **我们**：停留超 `sliceSeconds`（默认 30s）周期结算一片（`phase = "slice"`），
  页面消失结算 `final`（`phase = "final"`）；`hitchRatio` 为派生指标。
- **结论：切片保留。** 理由：只结算 `final` 会让「一直停在首页」这类最重要的长停留页
  永远没有数据；切片 + final 双 `phase` 靠 `phase` 区分，且 `takeReport` 结算即重置窗口，
  **不重复计数**（已用 `TDScreenSliceTests` 锁住）。**`hitchRatio` 保留为派生指标**，
  无直接业界对照（Sentry 有 total frames duration 思路、Firebase 没有），作为
  slow / frozen 帧率之外的体感补充，文档标注其为派生、非独立事实。
- **残余风险**：切片把一次长停留切成多片，后端若按事件数聚合需除以窗口；
  `hitchRatio` 与 `slowFrameRate` 高度相关，看板避免双计。
- **加固**：`TDScreenSliceTests` 锁住切片重置、样本不足丢弃、慢/冻结互斥、`hitchRatio` 口径。

### 10.4 `jetsamFootprintRatio = 0.85` → 保留为保守启发式

- **业界**：Sentry / Datadog 不做 footprint/limit 比值判断，只看「未干净退出 + 不在排除清单」。
- **我们**：`ratio >= 0.85` 才认 jetsam，否则退化为「可用内存 < 50MB」。
- **结论：保留。** 理由：能拿到 `limit` 时，比值比单纯的「内存高」更有区分度；
  拿不到 `limit` 的路径已退化为可用内存阈值，不依赖这个常量。
- **残余风险**：0.85 是经验值不是业界口径（§5 已记，注释已改诚实）。若后端需要可解释
  归因，应展示 `confidence` 而非 `attribution` 本身。
- **加固**：`TDTerminationClassifierTests` 的 ratio 分支（>= 0.85 判 jetsam 且 confidence
  随 ratio 升并封顶；< 0.85 不靠比值判）。

### 10.5 收口判断

4 处 D 类项全部**保留并加固**，无一需要回退到业界基线——因为每处偏离都带来了可操作的
额外信息（更细的 OOM 归因、长停留页覆盖、灵活的依赖注入），且都通过 `confidence` /
`phase` / `blockedFeatures` 把「推断 vs 事实」的边界交给了后端。**真正的收口不是删掉
它们，而是让每一处偏离都有据可查、有测可锁。** 至此调研文档与代码口径一致，可作为基建契约参考。
