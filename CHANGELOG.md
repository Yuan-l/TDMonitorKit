# Changelog

本组件遵循语义化版本。破坏性变更（事件语义、阈值口径、公开 API）一律升主版本号，
并在下方写清「改了什么、为什么改、升级要做什么」。

## 2.5.3

**修复崩溃补发被后台整批拒收、补发时间/会话错位，以及外部 SDK 边界样本污染传输层网络报表。** 公开 API 无删除，无需迁移。

真机补验（`TB_CRASH_TEST=exception` → 重启补发）发现接收端 4 次 `422 VALIDATION_ERROR`，
客户端诊断日志记录 `fieldErrors.events = ["Invalid date" × 6]`。根因：宿主
`TBCrashReporter` 落盘的面包屑 `timestamp` 只有时分秒（`"16:12:01.895"`），
`TDCrashReportParser` 原样塞进 `breadcrumbs[].ts`，而后台 `breadcrumbSchema.ts`
是 `z.coerce.date()`——一条非法日期让**整批 `native_crash` 被拒**。结果是自采的
崩溃（符号化栈、面包屑、崩溃前现场）全部丢失，后台只剩 MetricKit 那条未符号化
诊断：崩溃率和崩溃详情都是错的，这比没有数据更有误导性。

修复：

- 新增 `TDBreadcrumbStore.normalizedTimestamp(_:fallback:)`，统一收口 ISO8601、
  秒/毫秒时间戳、`HH:mm:ss.SSS`（按崩溃当天重建，跨午夜回退一天）；解析不了
  退回崩溃时刻，绝不把自由文本交给后台。
- `recordCrash` 组包前按后台 `breadcrumbSchema` / `crashThreadSchema` 清洗嵌套
  字段（ts / level / category / message / crashed / frames / 条数上限），避免同类
  脏字段再次打死整批。
- 补发事件的 `ts` 改用宿主报告的**崩溃真实时刻**（此前是下次启动时刻），并在
  attributes 标 `forwardedFromPreviousSession` / `crashOccurredAt`；宿主 context
  带合法 UUID 的 sessionId 时，由 `TDEvent.sessionIdOverride` 把崩溃挂回原会话，
  不再错算到重启会话。

用后台真实 `telemetryIngestSchema` 离线复现：旧值 `16:12:01.895` → 6 个
`Invalid date`，归一化后通过；Swift 全源码 typecheck 通过。

**同一轮补验还查出一处端上数据口径错误（外部 SDK 边界样本）**：查真机库发现
46 条 `api_metric` 的 `url` 是 `sdk://qweather/...`，全部来自天气 SDK 的调用
边界样本。它们没有 DNS/TCP/TLS/TTFB，`method` 写死 `GET`、`status` 是
「成功 200 / 失败 0」的边界层映射值，而后台的网络 P95 / 成功率 / 慢接口报表
正是按 `kind='api_metric'` + `GROUP BY method,url` 算的 —— 等于把「SDK 调用
前后耗时」冒充真实 HTTP 传输请求，会把网络质量大盘算歪。这比没有数据更危险。

修复：`TDBusinessMonitor recordExternalRequest` 改走新增的
`TDMonitor.recordExternalRequest` / `TDCrashBridge.recordExternalRequest`，
只产出 `mobile_metric(name=custom_metric)`，`attributes` 带
`metric=external_sdk_request`、`domain=business_boundary`、`endpoint`、
`logicalURL`（`sdk://` 仅作追溯）、`status`、`success`、`durationMs`。
业务侧 10 个调用点签名不变、一行未改；数据一条不丢，但与传输层物理隔离。
后台要展示边界层表现，按 `attributes.metric` 单独开视图。
旧包已写入的那批 `sdk://` `api_metric` 是脏数据，正式接入前应清理，
不要拿它做基线（建设阶段不为旧数据加兼容代码）。

## 2.5.2

**修复「业务 `setScreen` 根本没进终止归因」的断链。** 公开 API 无变化，无需迁移。

真机端到端核验时导出 `Library/Caches/TDMonitor/app_state.json`，发现
`lastScreen=null`、页面时间线为空，接收端 `session_start.prevScreen` 恒为 `-`。
根因：`TDMonitor.setScreen` 只更新内存里的 `TDScreenContext.current`，
而 `TDAppStateTracker.setScreen`（负责把页面写进落盘现场、供 OOM/终止归因读取）
**全工程没有任何调用方**；自动 VC swizzle 的 `push` 同样没写 AppState。
此前文档宣称「setScreen 影响终止归因」是错的。

修复：`TDScreenContext` 的 `push` / `pop` / `update` 统一收敛到
`reportIfChanged(_:)`，页面真正变化时才同步 `TDAppStateTracker.shared.setScreen`
（自动页面栈与业务 override 两条路都覆盖，重复出现不重复落盘）。
同时 `addBreadcrumb` 产出的 `mobile_metric(name=breadcrumb)` 补上 `screen`，
面包屑可以按页面聚合。

**口径更正（文档，无代码行为变化）**：查证 Sentry Cocoa 的
`enableMetricKit` 默认 `false` 且只收 hang / 磁盘 / CPU 诊断，不读
`MXAppExitMetric`；Datadog 的 watchdog termination 同样是纯启发式。
业界 OOM 主路径是自采集 + 启发式，MetricKit 只是补充源。
真机 `metrickitPayloads` 长期为 0，对外 OOM 率的分子只取启发式路径。
`CAPABILITY-IMPLEMENTATION.md` / `CAPABILITY-STATUS.md` /
`CAPABILITIES.md` / `INDUSTRY-COMPARISON.md` 已同步更正。

## 2.5.1

**修复诊断日志在节流窗口内丢失。** 公开 API 无变化，无需迁移。

`TDMonitorLog` 用 0.5s 节流合并写盘，但节流命中时只是把行留在内存 `fileBuffer`，
既没有延迟刷新，也不保证之后还有下一条日志来再次触发写盘。真机压测（构造满队列
触发淘汰）复现：本次启动 `diagnostics.log` 里只剩「能力矩阵」一行，队列截断 / 淘汰 /
ingest 失败的 warning、error 全部丢失——恰好是短时爆发后进程被强杀时最该留下的几行。

修复：`appendLocked` 在节流命中时挂一个一次性 `DispatchWorkItem`，`writeInterval`
之后无条件 `flushToDisk()`；`writeLocked()` 写盘后取消并清空该任务，避免重复写。
退后台 / 退出时的 `flushToDisk()` 保持不变。

行为验证（隔离目录 A/B）：「0.5s 内连打 3 条、之后无新日志、不主动 flush」——
旧逻辑落盘 1 行（丢 2 行），新逻辑 3 行全在。

## 2.5.0

**按「工程仍在建设测试阶段」删掉全部旧数据 / 旧版本兼容层。** 破坏性清理，磁盘格式与采集能力不变。

### 删了什么

- `TDJSONLQueueStore` 整个实现（含 `pending.json` JSON 数组迁移），以及对应的
  `TDJSONLQueueStoreTests` 6 条测试。队列现在只有 `TDMMAPQueueStore` 一个落盘实现，
  `TDInMemoryQueueStore` 仅用于依赖注入。
- `TDMMAPQueueStore.migrateLegacyJSONLIfNeeded()`：不再从 `pending.jsonl` 倒数据。
- `TDTransport.storeFileSize()`：不再为「注入非 mmap store」回退读旧 JSONL 文件大小；
  `storedBytes` 直接取 `committedBytes`，无磁盘实现时为 0。
- 共享 mmap 底座（`TBCustomNetworkLogger`）里的 v1 文件格式兼容：
  `LogFileHeaderV1Struct` / `kLogFileVersionV1`、`TBMMAPLogFile.isLegacy`、
  `loadHeaderLocked` 的 v1 分支、`readLegacyRecordsLocked`；以及 `LogFileWriter`
  的 Documents 历史文件迁移、v1 只读分支、历史空文件清理。
  现在文件头不匹配就明确拒绝打开，不猜格式、不降级。

### 为什么

没有上线、没有真实用户数据，就不存在「升级当天积压的事件」。为不存在的数据保留
迁移分支，只会让持久化层多出一套永远走不到、也没人敢删的读取路径，还要在每次改动时
同步维护。建设阶段的代码应该只描述当前唯一的现实。

### 升级要做什么

无需迁移（本来就没有旧数据）。残留的 `pending.jsonl` / v1 文件即使留在沙盒也会被忽略，
卸载重装自然清掉。

## 2.4.1

**修掉两个「内存队列与磁盘不同步」的边界缺陷。** 磁盘格式不变，公开 API 只增一个诊断字段。

### 改了什么

1. `load(limit:)` 截断时同步落盘并留 warning（`TDMMAPQueueStore` / `TDJSONLQueueStore` /
   `TDInMemoryQueueStore` 三个实现行为一致）。此前截断只改内存：磁盘上多出来的记录
   既不进 `pending`，又会在下一次压缩被 `replace(with: pending)` 抹掉，`storedCount`
   还长期虚高——丢了数据却没有任何痕迹。收敛失败时保留磁盘原样、下次启动重试，
   且不谎报 `knownCount`。
2. `appendLocked` 队列满时改为「批量腾出 10% + 立即 `store.replace(with:)`」，
   `apply` 里 retry 回队后溢出截断同样同步。此前被淘汰的事件仍躺在 mmap 里，
   进程被强杀后下次启动会「复活」，还可能在 `load` 截断时又被读回，让容量保护失效。
   批量淘汰是为了避免「每条新事件都全量重写 1000 条」。
3. `TDQueueStatus` 增加 `evictedEvents`，`summary` 在 > 0 时显示「淘汰 N 条」。

### 为什么

2.4.0 把「追加写 + 定期压缩」立为性能基线后，必须同时明确一条不变式：
**磁盘是 `pending` 的超集，只允许因「已发未压缩」而多；任何主动淘汰 / 截断都必须
立即同步落盘。** 只改内存不改磁盘，等于把这份差异留给下一次启动去猜。
容量保护是允许的取舍，但必须显式、可观测、可归因，不能静默。

### 升级要做什么

无需数据迁移，也无需改业务调用。`TDQueueStatus` 新增 `evictedEvents` 字段，
若外部直接用成员初始化器构造该结构，需补上这个参数（Kit 内唯一构造点已更新）。

## 2.4.0

**事件队列落盘改为复用宿主自研的 mmap 底座，并修复一个会丢数据的队列缺陷。**
公开 API 不变，但磁盘格式变了，故升次版本。

### 改了什么

1. **落盘后端**：`TDTransport` 默认 `TDEventQueueStore` 由 `TDJSONLQueueStore`
   换成新增的 `TDMMAPQueueStore`，底层是 `TBCustomNetworkLogger` 里的
   `TBMMAPRecordStore` → `TBMMAPLogFile`。因此新增 `spec.dependency "TBCustomNetworkLogger"`。
2. **底座泛化**（在 `TBCustomNetworkLogger` 内）：`TBMMAPLogFile` 把 `NetworkFailureLogObjc`
   的 NSKeyedArchiver 编解码从持久化逻辑里抽走，新增 bytes 级
   `writeRecords:` / `readRecords` / `replaceAllRecords:` / `corruptedRecordCount`。
   framing、CRC32、AES-256-CBC、`msync` 后推进 `dataLength` 提交位点、1.25 倍扩容 remap
   **一行未删**；原 `writeLogs:` / `readLogs` 降级为编解码薄封装，对外行为不变。
3. **旧数据迁移**：`TDMMAPQueueStore.load()` 在 mmap 文件为空且 `pending.jsonl` 存在时，
   把里面的积压事件倒进 mmap 文件，成功后才删除旧文件；失败则保留，下次启动重试。
4. **诊断口径**：`TDQueueStatus.storedBytes` 改取文件头 `dataLength`（已提交字节）。
   mmap 文件大小是映射区大小（16KB 起步、按需扩容），拿它当积压量会严重虚高。

### 为什么

异构事件一样要持久化，持久化就该有同样的质量。此前 JSONL 版缺三样东西：
每条 CRC 校验、AES 落盘加密、写后 `msync`（断电会丢最后几秒）；每事件还要
open/lseek/write/close 四次 syscall。这些都是老组件已经解决了的问题，另写一套
加固既不经济又会产生第二份实现。JSONL 是**记录编码**，mmap 是 **IO 方式**，两者
并不对立——把「存什么」和「怎么存」分层后，两套事件可以共用同一个引擎。

### 顺带修掉的 bug（会丢数据，不是取舍）

`flush()` 取队首 500 条上传，但上传在途时 `enqueue` 仍可写 `pending`。队列满（1000）时
`appendLocked` 会 `removeFirst` 淘汰最旧——淘汰掉的正是**在途批次**里的元素；等
`apply(outcomes:)` 回来仍按 `batch.count` 从队首删，就会把若干条**从未发过的新事件**
一起删掉。高事件率 + 队列满 + 上传在途三条件叠加即触发。

修法：显式记 `inFlightCount`，队列满时只淘汰在途批次之后的条目，`apply` 按该计数出队。

### 升级要做什么

- 必须重新 `pod install`（新增 `TDMonitorKit → TBCustomNetworkLogger` 依赖）。
- 旧 `pending.jsonl` 会自动迁移，无需手工处理；迁移成功后该文件消失。新文件是
  `Library/Caches/TDMonitor/queue.mmap`。**（2.5.0 起已移除该迁移，见上方 2.5.0）**
- 注入了自定义 `store:` 的调用方（单测）不受影响，`TDEventQueueStore` 协议未变。
- 密钥仍取 Keychain `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`：
  **首次解锁前**、**应用重装后**，旧文件里的加密记录解不开（读取端会跳过并计入坏行）。
  这是从老组件继承的既定行为，不是回归。

## 2.3.0

新增公开 API `TDMonitor.queueStatus()`（返回 `TDQueueStatus`）。**非破坏性**：纯新增。

### 新增

- `TDQueueStatus`：一次快照给出「待发条数 / 落盘条数 / 落盘字节 / 坏行数 / 已发批次数 /
  最近一次发送结果 / 上报端点」。
- `TDTransport.snapshot()` 在 transport 串行队列上同步取值，任意线程可调。

### 为什么加

「事件没上来」有三个完全不同的原因：没采到、采到没落盘、落盘发不出去。三者表现一模一样
（后端没数据），修法却完全不同，而此前只能靠人翻诊断日志猜。

加完立刻用上了：真机上读到 `待发 28 条 · 落盘 130 条/76800 B · 已发 2 批 · 上次：3 条成功`，
直接推翻了「`pending.jsonl` 涨到 225KB 说明上报打不通」这个判断——文件大小包含「已发未压缩」
的事件（追加写的必然结果），根本不能当积压量看。真正的积压指标是 `queuedEvents`。

### 注意

- 使用自定义 `sink` 时 `queueStatus()` 返回 `nil`：队列、落盘、重试由接入方自理，内置出口无从得知。
- 不提供「清空队列 / 强制丢弃」：那是故障处置动作，不该由展示层触发。

## 2.2.1

修复「业务给的 endpoint 落盘时被丢掉」。**非破坏性**：`recordNetwork` 只加可选参数。

### 修复

- `TDCrashBridge.recordNetwork` / `TDMonitor.recordNetwork` 新增 `endpoint`、`traceId`
  两个可选参数，并写进 `network_phase` / `api_metric` / `network_error` /
  `network_traffic` 四类事件的 attributes。
- 之前 `TDNetworkSampleObserver` 已经把 `tag.endpoint` 赋给 sample，但
  `TDNetworkFeatures` → `bridge.recordNetwork` 这一段没有这个参数，字段就在落盘前丢了。
  后果是后端只能拿 URL 做字符串匹配：查询参数不同、域名轮换（行情模块有 4 个 CDN
  前缀域）都会被拆成不同接口，「按接口聚合成功率 / P95」直接失效。
- `traceId` 同步带上，便于把一条失败请求和当时的 breadcrumb / 崩溃串起来。

升级要做什么：不用改。自定义采集若直接调 `recordNetwork`，建议补 `endpoint`。

## 2.2.0

把能力系统从「内置可用」升级为「可被外部复用与扩展」。**非破坏性**：所有新增 API 为加法，
既有 `TDMonitor.start` / 各采集器调用方式不变。

### 新增（可复用 / 可工程化）

1. **能力可外部扩展**：`TDMonitorFeature` 协议、`TDMonitorFeatureRegistry`、`TDMonitorRuntime`、
   `TDClock` 全部公开；新增门面 `TDMonitor.register(_:)`，业务方可在 `start()` 前登记自定义能力，
   与内置能力共用同一套依赖注入、顺序安装、逆序卸载与能力矩阵对账。
2. **可复用积木公开**：`TDResourceSampler`（内存/CPU/磁盘/线程/FD 采样）、`TDNetworkSample`、
   `TDNetworkClient` 系列拦截器契约、`TDContext`、`TDCapabilityMatrix`、`TDAppStateTracker`、
   `TDBinaryImage`、`TDBreadcrumbStore`、`TDEventSink` 等均可被宿主直接调用，
   无需绕经监控 SDK。
3. **能力依赖可观测**：新增公开诊断 `TDMonitor.blockedFeatures`（与 `installedFeatures` 成对），
   回答「哪个能力装上了但依赖缺口、可能数据不全」——这是 `requires` 机制在 Release 下
   留痕、可查的落地（详见 `IMPLEMENTATION-AUDIT` §10.1）。
4. **配套测试**：`TDMonitorExtensionTests` 覆盖「公开注册 → 安装」「同名去重」「门面 + start 端到端」；
   新增 `TDTerminationClassifierTests` / `TDRegistryGraphTests` / `TDScreenSliceTests`，
   锁定 5 档 OOM 归因、能力依赖图谱自洽、页面切片与慢/冻结互斥等自创项的契约。
5. **`TDNetworkMetricsMapper` 提为 `public`**：metrics → 样本的唯一折算式现在可被
   宿主网络门面复用，避免「业务侧与上报侧分阶段耗时口径不一致」。

### 为什么做

之前这些类型都是 `internal`：能力只能「用内置的」，采样器/契约只能「SDK 自己用」。
这意味着监控 SDK 是一坨黑盒，别的工程师无法在其上叠加自有采集、也无法复用采样逻辑——
这正是「无法复用、无法工程化」的根因。本次把该公开的全部公开，边界是：
注册表/运行时/契约公开，但默认 `sink`（`TDTransport`）仍走内置，宿主选择注入才替换。

## 2.1.0

新增统一网络层。**非破坏性**：旧 API 全部保留，`makeInstrumentedSession` 仍然可用。

### 新增

1. **拦截器三族契约**
   - `TDRequestAdapter`（改请求）/ `TDRequestRetrier`（决定重试）/ `TDNetworkObserver`（只观测）
   - 划分依据是 Alamofire 5 的 `RequestAdapter` / `RequestRetrier` / `EventMonitor`：
     把「能改流程的」和「只能看的」在类型上分开，避免一个协议什么都干
   - 硬规则：observer 的方法全部返回 `Void`，所以监控采集器**在类型层面**
     无法改变业务请求——隔离靠签名保证，不靠规范

2. **零依赖参考实现 `TDURLSessionNetworkClient`**
   - `TDMonitor.shared.makeNetworkClient()` 一次装配好 trace 注入、幂等重试、样本采集
   - 业务已有网络层（AFNetworking / Alamofire）时**不必换出口**，
     把这三种拦截器挂到自己的 client 上即可

3. **`TDIdempotentRetrier`**
   - 只重试 `isIdempotent == true` 的请求：`POST` 超时可能已成功，重发即重复下单
   - 只重试传输层瞬时错误与 429/503/504，不重试 4xx
   - 指数退避 + `[0.5, 1.0)` 抖动，避免后端抖动时全端同时重发

4. **`TDNetworkMetricsMapper`**
   - metrics → 样本的唯一折算式，legacy swizzle 与统一网络层共用
   - 多段事务（重定向）：DNS/TCP/TLS 累加，TTFB 只取最后一段

### 修复

1. **metrics 与 completion 的时序竞争**
   - AFNetworking 源码注释明确写了 metrics 可能晚于 `didCompleteWithError:`
     （`AFURLSessionManager.m:1101`），旧实现假定「完成时 metrics 已到」
   - 现在：业务回调立即执行；观测上报等两者齐或 1s 兜底超时；
     超时后迟到的 metrics 丢弃并留痕（补发会造成双计数，p95 会假性变好）

2. **上报自身流量的识别方式**
   - 旧实现靠 `url.contains(host) && url.contains(path)` 字符串匹配，
     后端换域名 / 加 CDN / 改路径前缀会静默失效
   - 现在优先用 `TDRequestTag.isInternal` 显式标记；URL 匹配只作为 legacy 兜底，
     且仅在拿不到 `endpoint` 时启用

### 已知边界

- 统一网络层管不到 SDWebImage（自建 session）、`WKWebView`（跨进程）、
  三方 SDK（各自建 session），这些只能靠 legacy swizzle 兜底，无分段耗时
- `TDRequestTag.endpoint` 的 URL 推导对 slug、嵌套 ID 会失准，跨端对齐需业务显式给

## 2.0.0

这一版不是功能堆叠，是把采集口径与业界对齐、把装配方式改成可安装的能力单元。
**有三处会影响既有数据解读，升级前请先读「破坏性变更」。**

### 破坏性变更

1. **ANR 上报阈值与采样阈值分离**
   - 之前：`hangThresholdMs = 250` 既是检测起点也是上报条件，250ms 以上的卡顿逐条上报。
     启动、页面切换时这类抖动极常见，结果真实卡顿被自家噪声淹没。
   - 现在：250ms 只作为**采样起点**（早采才能拿到调用链前段），实际上报要求
     `durationMs >= anrReportThresholdMs`，默认 **2000ms**，与 Sentry
     `defaultAppHangTimeoutInterval = 2.0` 一致。
   - **升级影响**：2 秒以下的卡顿不再产生 `anr` 事件，事件量会明显下降。
     这是预期行为，不是采集失效。需要保留短卡顿视图的话请用 `long_task`（默认 100ms）。

2. **慢帧阈值改为 `1 / (fps - 1)`**
   - 之前：`帧预算 × 1.5`，60Hz 下 25ms。
   - 现在：60Hz 下 **16.95ms**、120Hz 下 8.40ms，按实测刷新率推导，与
     Sentry `slowFrameThreshold`、Firebase `kFPRSlowFrameThreshold = 1/59` 一致。
   - **为什么**：17~25ms 这一档（轻微但可感知）此前整段漏计，慢帧率被系统性低估
     约一半。升级后 `slowFrameRate` 会**上升**，这是修正而非劣化。

3. **慢帧与冻结帧改为互斥计数**
   - 之前：单帧 >700ms 会同时进入 `slowFrames` 和 `frozenFrames`，分母不变、分子重复。
   - 现在：>700ms 只计冻结帧，其余超阈值计慢帧。
     `slowFrameRate + frozenFrameRate` 才是全部异常帧占比。

4. **移除全局 FPS 指标**
   - 删除 `fps` 采集器与对应事件。整体 FPS 在静止页面上恒等于屏幕刷新率上限，
     无法回答「哪个页面卡」，保留只会制造误导性大盘。
   - 页面级帧率（`screen_render`）保留并加强。

### 新增

- **ANR 分级**：`anr` 事件的 `attributes` 增加
  - `severity`：`hang`（2s ≤ 时长 < 8s）／`fatal_suspected`（≥ 8s，大概率已被系统
    watchdog 终止，这类事件常有去无回，另有 `onProgress` 每秒落盘兜底）
  - `blockType`：`fully_blocked`（卡顿期间一帧未出，主线程完全停摆）／
    `partially_blocked`（仍在出帧但很慢，问题在渲染链路）
  - `framesDuring`、`foreground`、`reportThresholdMs`
  - `type` 仍为 `main_thread_block`，向后兼容；后端既有分组统计无需改造。
- **ANR 重复上报抑制**：距上次上报不足 2 秒的结算直接丢弃。同一段卡顿在恢复过程中
  会被结算多次，逐条上报等于把一次事故放大成 N 次，事故数统计失真。
  窗口取 2s（对齐 Sentry V2 `lastAppHangStoppedSystemTime + timeoutInterval`），
  不取 Datadog 的 30s——30s 会吞掉「连续操作一路都卡」这种真实场景。
- **配置项** `anrReportThresholdMs`（默认 2000，可由 `TDMonitor.plist` 覆盖）
- **出口注入**：`start(configuration:sink:)`。默认仍走内置 HTTP，一行 `start()` 即可；
  要换通道（统一网关 / 双写 / 自建）时实现 `TDEventSink` 的 4 个方法传进来，
  采集侧零改动。
- **架构分层**（`TBMonitorCore.swift` / `TBMonitorFeatures.swift`）
  - `TDEventSink`：出口协议，取代 7 处对具体 `TDTransport` 的硬依赖
  - `TDMonitorRuntime`：依赖容器（对应 Sentry `SentryDependencyContainer`）
  - `TDMonitorFeature`：能力单元，可失败初始化器决定装不装，
    带 `install()` / `uninstall()` / `name` / `requires`（对应 Sentry `SwiftIntegration`）
  - `TDMonitorFeatureRegistry`：按声明顺序安装、逆序卸载
  - `TDMonitorQueues`：4 条散落队列收口
  - `TDClock`：可注入时钟
- **数据出口拆为四层**（对齐 Datadog `DatadogCore` 的 `Storage` / `Upload` / `DataStore`）
  - `TDEventQueueStore` / `TDJSONLQueueStore`：JSONL 落盘，追加写 + 坏行跳过 + 旧格式迁移
  - `TDBatchUploader` / `TDHTTPBatchUploader`：只负责发一批，把结果翻译成
    `accepted` / `rejected` / `unauthorized` / `retryable` 四种
  - `TDBatchResolver`：毒数据二分隔离，纯逻辑
  - `TDRetryPolicy`：指数退避与重置，纯函数
  - `TDTransport` 退化为编排层（入队 / 出队 / 排期 / 记账）
  - `stop()` 加入 `TDEventSink` 协议，并在 extension 提供默认实现，自定义出口不必改动
- **OOM 现场时间线**：新增 `TDTimelineEntry`，把内存采样、内存警告、页面切换、
  前后台切换、卡顿统一到一条带毫秒偏移的序列上（容量 120 条）。
  `oom` 事件的 `attributes.timeline` 在**两条来源**（启发式与 MetricKit）中都带同一份。
  之前启发式有整条曲线、MetricKit 只有单点，同一个指标按 `source` 分开看，
  可查性差一半。
- **接入自检** `TDIntakeSelfCheck` + `TDMonitor.intakeWarnings`：启动时点名
  「崩溃路径未配置（会导致崩溃率恒为 0 且不报错）」「Release 用明文 HTTP」
  「上报地址指向 localhost」「采样率 < 1 的丢弃方式」等会静默导致缺数据的问题。
- **独立测试工程** `Package.swift`：clone 组件即可
  `xcodebuild -scheme TDMonitorKit -destination 'platform=iOS Simulator,name=iPhone 16' test`，
  不依赖宿主 App。
- **`test_spec`**：Pod 集成方式下也能跑同一批测试。
- **文档**：`docs/ARCHITECTURE.md`（分层与对标）、`docs/CAPABILITIES.md`（12 项能力
  的技术路线与取舍）、`docs/INDUSTRY-COMPARISON.md`（Sentry / Datadog / Matrix /
  Firebase 逐条对比，含可复核的文件路径与常量）、`docs/DECISION-BRIEF.md`

### 修复

- **队列写放大**：旧实现每条事件都 `JSONSerialization` 整个 pending 数组再原子写盘。
  队列满（1000 条）时每来一条要重写约 600KB，而且发生在持锁的串行队列上。
  改为 JSONL 追加写，累计追加超过 `maxQueueSize/2` 才压缩一次。
- **「指数退避」从未生效**：`backoff` 被计算却从未参与排期。旧实现用
  `asyncAfter(backoff)` 延迟的是**网络回调的返回**，重发时机仍由固定 10s timer 决定。
  结果既不退避，还让一次 flush 多卡几秒。现在由 `scheduleRetry(after:)` 真正排期。
- **一行损坏导致整队列作废**：旧实现用 `try? JSONSerialization.jsonObject` 解析整个
  文件，被 SIGKILL 留下的半行会让 `pending` 归零——恰好在最需要数据的时候丢光。
  改为逐行解析，坏行只损失自己并计入 `corruptedLines` 诊断。
- 页面帧率缺少 `view.window.keyWindow` 门控：被 present 但未成为 keyWindow 的页面、
  容器页的子 VC 都在贡献帧数据，导致「没人看的页面」拉低整体指标。
  对齐 Firebase `FPRUIViewControllerInstrument` 的判定。
- `viewDidLoad` 时间戳用后未清空：pop 回页面时 `loadMs` 会被算成
  「距首次 viewDidLoad 的墙钟差」，动辄数万毫秒，直接把页面耗时 P95 拉爆。
- `autoCollect` 是「声明了却没人读」的配置键——比没有这个键更糟，
  它让接入方以为关掉了。现在真的生效。
- `background_task_timeout` 归因分支是死代码（字段恒为 0，判定永不命中）。
  新增 `installBackgroundTaskHook()` 挂钩 `beginBackgroundTask` / `endBackgroundTask`。
- 慢帧统计窗口重置时漏清 `hitchMs`。

### 已知限制

- 崩溃采集**不接管** signal / NSException handler，依赖宿主 `TBCrashReporter` 落盘，
  SDK 负责补发与补全维度。业界（Sentry / Datadog / Matrix / Crashlytics）均自行接管；
  不接管是接入约束而非技术选择，因此崩溃采集质量当前取决于宿主。
- OOM 归因是**推断**而非证据：`jetsam` / `watchdog` / `backgroundTaskTimeout` /
  `memoryPressure` / `unknown_unclean` 五档都比业界（统一 1 档）细，但没有分配级证据，
  回答不了「谁吃的内存」。`malloc` 级分配追踪（Matrix `WCMemoryStat` 路线）本轮不做。
  归因本身仍是推断，但**上下文已经是证据**：时间线能回答「什么时候、在哪个页面、
  从多少爬到多少、期间有没有内存警告」，只是回答不了「哪一行分配的」。
- `partially_blocked` 依赖 displayLink 常驻回调，无页面在屏时也能判定；
  但它与 Sentry 的 `framesContributingToDelayCount == 1` 是相近口径，不等价。

## 1.0.0

首个内部版本：崩溃补发、ANR 采样、OOM 双源归因（MetricKit + 启发式）、
页面级帧率、启动耗时、资源采样、网络指标、页面耗时、非致命异常、面包屑。
