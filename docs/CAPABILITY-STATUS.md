# 能力交付状态

这份表回答一个问题：**每一项能力现在到底能不能用。**

区分三个状态，不要混着看：

- ✅ **可用** — 装上就有数据，口径明确。
- ⚠️ **有前提** — 装上也有数据，但只在满足某个条件时完整。前提写在「前提」列，
  不满足时不是坏了，是拿不到。
- ❌ **有缺口** — 已知某类数据拿不到，原因和替代手段写在「缺口」列。

最后更新：2026-11-15（按当前代码重新核对，不再沿用 2.0.0 的自述）

> **口径说明**：文档按「观测项」编号 1–12（编号 5 的页面耗时并入页面渲染），
> 代码里是 11 个 feature 单元，两者不是一一对应。别拿 feature 类数量核对能力清单。
>
> **能力可用 ≠ 已接入**：采集能力都是自动的（swizzle / observer / timer / 系统通知），
> 生产路径默认全量生效，不依赖 demo 页；但「统一网络层」和「业务上下文」需要业务
> 主动调用，当前接入范围见第 4、5 节。

---

## 1. 启动

| 项 | 状态 | 实现 | 前提 | 缺口 |
|---|---|---|---|---|
| 冷启动 | ✅ | `TDLaunchRecorder`：起点取 `kinfo_proc.p_starttime`（内核记录的进程创建时刻），分 `preMainMs` / `firstFrameMs` / `totalMs` | 宿主在 `didFinishLaunching` 末尾调 `markDidFinishLaunching()`；不调则 3s 兜底 | 无法细分 dyld / 静态初始化 / `+load`，需要 dyld hook，成本和风险都不划算 |
| 预热启动 | ✅ | 读 `ActivePrewarm` 环境变量，标 `type=prewarm` | iOS 15+ | 更早的系统没有这个概念，如实标 `cold` |
| 热启动 | ⚠️ | `TDLifecycleFeature`：`willEnterForeground → didBecomeActive` | — | 只覆盖「进程还活着、从后台切回」。进程被系统回收后再点开**属于冷启动**，由 `TDLaunchRecorder` 覆盖——两者不重叠，但名字容易被误读成「热启动只有几十毫秒」 |

**热启动的口径要说清**：它量的是「回到前台到可交互」，通常几十到几百毫秒。
和冷启动共用 `app_launch` 指标名，靠 `attributes.type`（`cold` / `prewarm` / `warm`）区分。
**后端如果只按 `name` 聚合，P95 会被热启动样本稀释**——必须按 `type` 分组。

## 2. 稳定性

| 项 | 状态 | 实现 | 前提 | 缺口 |
|---|---|---|---|---|
| ANR | ✅ | `TDHangWatchdog`：独立线程信号量 ping，250ms 起采样、2s 上报、8s 标 `fatal_suspected`；卡顿期间 50ms 抓一次主线程栈 | — | 主线程被 SIGKILL 时事件发不出去，靠 `onProgress` 每秒落盘 + 下次启动归因兜底 |
| 崩溃 | ⚠️ | `TDCrashFeature`：**不接管** handler，解析宿主落盘的 JSON 后补发，并补全面包屑与上一会话内存轨迹；补发事件的 `ts` 取崩溃真实时刻，带 `forwardedFromPreviousSession` / `crashOccurredAt` 标记 | 宿主必须设置 `TDMonitor.hostCrashReportPaths`；补发的嵌套字段必须过后台 `breadcrumbSchema` / `crashThreadSchema` | 不设 → **崩溃率恒为 0，且不报错**（2.0 起由接入自检点名）。采集质量取决于宿主 reporter。**2.5.3 前**：宿主面包屑 `timestamp` 只有 `HH:mm:ss.SSS`，被后台 `z.coerce.date()` 判为非法，导致整批 `native_crash` 422 拒收、自采崩溃全丢；现已统一归一化并在组包前清洗 |
| 非致命异常 | ✅ | 交换 `-[NSException raise]` + `TDMonitor.recordNonFatal` | — | 不交换 `objc_exception_throw`：那会把大量被正常 catch 的异常也收进来，噪声压过信号 |
| OOM | ✅ | **启发式为主**（5 档，全版本、下次启动即知）+ MetricKit `MXAppExitMetric` 增量**补充校验**；两者都带 `footprintSeries` 与 `timeline` | 启发式需宿主 AppState 落盘；MetricKit 需 iOS 14+ 且用户开「共享 iPhone 分析」 | 能回答「什么时候、在哪个页面、从多少爬到多少、有没有内存警告」，**回答不了「哪一行分配的」**。MetricKit 在这台真机上 `deliveryCount=0`，不能当覆盖率来源 |

## 3. 性能

| 项 | 状态 | 实现 | 前提 | 缺口 |
|---|---|---|---|---|
| 页面渲染 | ✅ | `TDScreenFrameSession`：VC 粒度，`view.window.keyWindow` 门控，30s 切片 | — | 系统容器页（`UI*` / `_*`）被排除，是刻意的 |
| 页面耗时 | ✅ | `willAppear→didAppear` + `load→首次 appear` | — | — |
| 卡顿样本 | ✅ | 卡顿期间按 50ms 抓主线程栈，恢复后统一符号化 | — | 采样与符号化必须分开做（主线程挂起期间 `dladdr` 可能撞 `dlopen` 锁），已分 |
| 资源 | ✅ | 内存 `phys_footprint` + limit、CPU、磁盘、线程数、FD、电池、热状态 | — | FD 用 `F_GETFD` 逐个探测（iOS 上 `/dev/fd` 不可枚举、`proc_pidinfo` 未导出），开销随 `getdtablesize()` 增长，上限已收口 4096 |

## 4. 网络

网络这块有两条路，先说清区别，否则会被"装上了怎么数据不全"反复绊住：

**要分清两层，之前这里混为一谈，导致天气 tab 被误判成「完全没法采」**：

| 层 | 天气 tab（`QWeather.framework` 二进制 SDK） |
|---|---|
| **传输层**：DNS / TCP / TLS / TTFB / 真实 HTTP 状态码 | 拿不到。SDK 自建 `NSURLSession`，业务换不了它的传输实现；iOS 18 上初始化器不可 swizzle，完成回调钩子也没命中（接收端 0 条 `*.qweather.net` 样本）。这一层**明确不采** |
| **业务边界层**：哪个接口发起、耗时多久、成功失败、在哪个页面 | 完全拿得到。`QWeatherRequest.m` 在调用 SDK 前记起点，在 success / failure 回调里记终点，经 `TBBusinessMonitor recordExternalRequest` 产出 `mobile_metric(name=custom_metric)` + `attributes.metric=external_sdk_request`，带 `endpoint=weather.*` |

`SDWebImage` / `WKWebView` 同理：传输层不采，但只要业务侧能观测到调用前后，就能补边界样本。
真正走统一网络层的目前只有 `TBFinanceKit`（行情）；天气 tab 走的是边界 API。
2.5.3 起两条路**产出不同 kind**：传输层是 `api_metric` + `network_*`，
边界层是 `mobile_metric(name=custom_metric)`，物理隔离。此前边界样本也产
`api_metric`，带 `sdk://qweather/...` 和伪造的 `status`/`method`，被后台
`GROUP BY method,url` 的网络报表当成真实传输请求统计——看着有数据，口径是错的。

| 路径 | 覆盖范围 | 分阶段耗时 | 业务改造 |
|---|---|---|---|
| **统一网络层**（推荐） | 所有走该出口的请求 | ✅ 全量 | 把调用点收进 `TDNetworkClient` |
| legacy swizzle（兜底） | 所有 `dataTaskWith*:completionHandler:` 调用 | ❌ 无 | 零 |

两条路的数据源**完全相同**——都是 `URLSessionTaskMetrics`。差别只在
"能不能在请求前/后插拦截器"，而不在"谁能采到分段"。走 AFNetworking 的业务
一样能拿全（AF 4.x 的 `setTaskDidFinishCollectingMetricsBlock:` 就是转发同一个 metrics）。

| 项 | 状态 | 实现 | 前提 | 缺口 |
|---|---|---|---|---|
| 成功率 / 状态码 / 总耗时 / 流量 / 错误分类 | ✅ | 统一网络层 `TDURLSessionNetworkClient`；未改造的项目由 swizzle 兜底 | 兜底路径要求业务用 `URLSession` 的完成回调 API | delegate 风格的自定义 session 不经过兜底钩子 |
| 分阶段耗时（DNS / TCP / TLS / TTFB） | ✅ | `TDNetworkMetricsMapper`，两条路共用同一折算式 | 走统一网络层，或 `makeInstrumentedSession` | 多段事务（重定向）里 DNS/TCP/TLS 累加、TTFB 只取最后一段——业务语义上只有最后一段有意义 |
| 重试率 / 重试次数 | ✅ | `attempt` 字段 + `TDIdempotentRetrier` | 业务在 `TDRequestTag` 标 `isIdempotent` | 未标幂等的请求一律不自动重试（`POST` 重发会重复下单，代价高于少一次重试） |
| 接口维度聚合 | ✅ | `TDRequestTag.endpoint`，未给则从 URL 推导（数字段 / UUID → `:id`） | — | URL 推导对 slug、嵌套 ID 会失准，跨端对齐需业务显式给 |
| 链路串联 | ✅ | `TDTraceAdapter` 注入 `X-TD-Trace-Id`，与 breadcrumb / 崩溃同 ID | — | 业务已有自己的 trace 体系时保留业务值，两套 ID 并存 |
| 短路请求（缓存命中 / 前置失败） | ✅ | 短路也产一条样本，`shortCircuit` 标记原因 | — | — |

**这套能力管不到什么**（必须提前说，否则对接方会以为"全量网络可观测"）：

| 流量 | 原因 |
|---|---|
| 和风天气 `QWeather.framework`（天气 tab 的全部业务请求） | **传输层分段拿不到**（自建 session）；已在业务调用前后补边界样本，见上一节 |
| SDWebImage 等图片库 | 内部自建 session，不经过业务出口；边界样本待接 |
| `WKWebView` 页面内请求 | 在 WebContent 进程里，宿主完全看不到 |
| AMapLocation / QNNetDiag 等三方 SDK | 各自建 session，只受 legacy swizzle 部分覆盖 |

边界样本是**业务侧计时**，不是 `URLSessionTaskMetrics`：没有分段、没有真实 HTTP 状态码
（SDK 回调成功记 200、`NSError` 记 0），URL 用 `sdk://` 逻辑标识且只放在
`attributes.logicalURL`。所以 2.5.3 起它不再写 `api_metric.url`：后台的慢接口 /
网络 P95 / 成功率报表是按 `kind='api_metric'` + `GROUP BY method,url` 算的，
边界样本混进去会把这些指标算歪。要看边界层表现，按
`attributes.metric='external_sdk_request'` 单独聚合 `durationMs`，
**不要和传输层放在同一张报表**。

## 5. 归因与观测

| 项 | 状态 | 说明 |
|---|---|---|
| 面包屑 | ✅ | 100 条环形，进后台 / 崩溃前落盘。崩溃补发时读上次会话的落盘轨迹——内存里的那份已随进程消失 |
| 终止归因 | ✅ | 每次启动把上次退出的结论压进 `session_start` 的 `prev*` 维度，`unknown` 也上报（不进 OOM 率，但必须可查） |
| SDK 自检 | ✅ | `installedFeatures`（装了哪些）+ `intakeWarnings`（漏配了什么）+ `diagnostics`（最近诊断） |
| MetricKit 补充源 | ⚠️ | 崩溃诊断、CPU/内存/卡顿汇总，`init?` 返回 nil 即不装。**装了不等于有数据**：需用户开「共享 iPhone 分析」且系统次日批量投递；真机 `metrickitPayloads` 长期为 0。业界（Sentry/Datadog）OOM 主路径都是启发式，MetricKit 只在 Sentry 里作为默认关闭的 opt-in 诊断集成 |

**业务上下文（工程化接入）**：`setScreen` 本身不产生事件，它更新 `TDScreenContext.current`
（供 ANR / 卡顿读取）**并同步写 AppState**（供终止归因 `prevScreen` 与 OOM 页面时间线读取）；
`breadcrumb` 既进环形缓冲供崩溃现场使用，也产出一条带 `screen` 的轻量 `breadcrumb` 事件。
行情 tab 切换品种写 `finance.<section>`，打开详情 / 加载失败写面包屑；天气 tab 写
`weather.home` 并在 SDK 调用边界补请求样本。业务组件统一通过 `TBNetworkManager` 的
`TBBusinessMonitor` 调用，不直接依赖 `TDMonitorKit`。

> **2.5.2 修复的断链**：此前 `setScreen` 只改 `TDScreenContext`，而
> `TDAppStateTracker.setScreen` **没有任何调用方**——真机导出 `app_state.json` 显示
> `lastScreen=null`、页面时间线为空，`session_start.prevScreen` 恒为 `-`。
> 也就是说文档宣称的「影响终止归因」当时是**假的**。现在由 `TDScreenContext` 的
> push / update 统一同步 AppState，自动页面栈与业务 override 都会落盘。

---

## 已知不可用 / 有意不做的

| 项 | 原因 |
|---|---|
| malloc 级内存分配追踪 | hook 内存分配路径写错会让业务崩溃或死锁；与宿主已有工具冲突。已决定不做，OOM 用上下文证据替代 |
| 编译期插桩的慢函数追踪（Matrix TraceCanary Android 路线） | iOS 只能用 `-finstrument-functions`，Release 下开销不可接受 |
| 自动接管崩溃 handler | 宿主 `TBCrashReporter` 已注册，再注册会顶掉它。接入约束，不是技术选择 |
| 全局 FPS | 静止页面上恒等于刷新率上限，无法回答「哪个页面卡」。已删除，只保留页面级 |
