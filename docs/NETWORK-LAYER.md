# 网络层：边界、拦截器设计与接入

## 1. 边界先说清

**统一网络层属于业务，不属于监控 SDK。**

SDK 提供三样东西：

| 提供物 | 用途 | 是否强制 |
|---|---|---|
| `TDNetworkRequest` / `TDNetworkResult` / `TDNetworkContext` | 可观测的事实模型 | 不强制，但推荐 |
| `TDRequestAdapter` / `TDRequestRetrier` / `TDNetworkObserver` | 拦截器三族协议 | 不强制 |
| `TDURLSessionNetworkClient` | 零依赖参考实现 | 不强制 |

**不强制**的意思是：业务已经有自己的网络层（AFNetworking / Alamofire / 自研），
不需要换成我们的 client，只需要：

1. 在业务 client 里跑同样的三族拦截器；
2. 把每次请求的结果构造成 `TDNetworkResult` 交给 `TDNetworkSampleObserver`。

采集能力挂在**采集器**上，不挂在 client 上。这是复用点选对与否的分水岭——
如果能力绑在 client 上，任何不走我们 client 的流量就永远采不到。

## 2. 为什么分成三族，而不是一个拦截器协议

业界有两种做法：

- **Moya `PluginType`**：一个协议同时有 `willSend`（能改请求）、`didReceive`（只能看）、
  `prepare`（能改目标）。结果是「只想加日志的 plugin」也必须实现能改请求的方法，
  职责靠文档约束。
- **Alamofire 5**：`RequestAdapter`（改请求）/ `RequestRetrier`（决定重试）/
  `EventMonitor`（只观测）三族分开。

我们照 Alamofire 分，并加一条硬规则：

> **`TDNetworkObserver` 的所有方法返回 `Void`。**

监控 SDK 的全部采集器都实现 `TDNetworkObserver`。返回 `Void` 意味着它们
**在类型层面**无法改变业务请求的成败、顺序或内容。这比写一条
「采集器不得修改请求」的规范可靠——规范会被下一个人忘记，函数签名不会。

| 族 | 能力 | 执行顺序 | 能否影响流程 |
|---|---|---|---|
| `TDRequestAdapter` | 改请求头、签名、刷新 token、补参数 | 注册顺序，串行，前一个的输出是后一个的输入 | 能（抛错即短路，不发请求） |
| `TDRequestRetrier` | 决定重不重试、等多久 | 注册顺序，**第一个非 `doNotRetry` 生效并终止询问** | 能（决定是否重发） |
| `TDNetworkObserver` | 打点、统计、链路串联 | 全部都会收到 | **不能**（返回 Void） |

retrier 为什么"第一个生效就停"而不是投票：重试决策互斥。
「立即重试」和「退避 3 秒」不能同时成立，取并集只会得到矛盾结论。

## 3. 三个必须处理的细节

### 3.1 短路也要出样本

缓存命中、token 拿不到、前置条件失败——这些请求**没有产生网络流量**。
如果直接跳过不上报，监控看到的是「这个接口从没被调用过」，
而真相是「调了，一直在本地被挡住」。这两者对排查是完全相反的结论。

所以短路产一条 `shortCircuit != nil` 的样本，`errorDomain = "TDShortCircuit"`。

### 3.2 重入

刷新 token 的 adapter 自己会发请求。如果那条请求再次进入整条 adapter 链，
就会无限递归。解法是 `context.bypass(adapter)` ——表达「这一类 adapter 我不要跑」，
比按调用栈深度判断更直接。

### 3.3 metrics 可能晚于 completion 到

`URLSessionTaskMetrics` 只通过 delegate 交付，而它与 completion handler 的
到达顺序**不确定**。AFNetworking 源码里有一句直接的原话
（`AFURLSessionManager.m:1101`）：

> *"Metrics may fire after URLSession:task:didCompleteWithError: is called, delegate may be nil"*

所以：

- **业务回调立即执行**，不为了等 metrics 拖慢业务；
- **观测上报等两者齐了再发**，用一个兜底窗口（默认 1s）；
- 窗口超时就发 `metricsMissing = true` 的版本，**迟到的 metrics 直接丢弃**。

最后这条是刻意的：补发会让同一请求被计数两次，而双计数在分位统计里
表现为「p95 突然变好」，比缺数据更难发现。

参考实现见 `TDURLSessionNetworkClient.tryEmit(_:)` 与 `scheduleDeadline(for:)`。

## 4. AFNetworking 接入

**结论：可以，而且分段耗时一条不少。**

AF 4.x 底层就是 `NSURLSession`，它把同一个 `URLSessionTaskMetrics` 从两个口子吐出来：

- `AFURLSessionManager.h:384` 的 `setTaskDidFinishCollectingMetricsBlock:`
- `AFURLSessionManager.m:196` 把 metrics 放进 `AFNetworkingTaskDidCompleteNotification` 的 userInfo

两个口子各有代价，必须知道：

| 口子 | 问题 |
|---|---|
| `setTaskDidFinishCollectingMetricsBlock:` | **替换式**。`AFURLSessionManager.m:855` 只是存进单个 `taskDidFinishCollectingMetrics` 属性，谁后设谁覆盖。业务自己或别的 SDK 也设了就互相吞 |
| `AFNetworkingTaskDidCompleteNotification` | userInfo 里的 metrics 受 §3.3 的时序影响，可能缺失；且该通知固定 dispatch 到**主队列**（`AFURLSessionManager.m:241`），重活放进去会掉帧 |

胶水示例（业务侧约 60 行，不需要 SDK 内置，因为网络层归业务所有）：

```swift
import AFNetworking

final class AFNetworkClientAdapter: TDNetworkClient {

    private let manager: AFHTTPSessionManager
    private let lock = NSLock()
    private var adapters: [TDRequestAdapter] = []
    private var retriers: [TDRequestRetrier] = []
    private var observers: [TDNetworkObserver] = []
    /// metrics 与 completion 的汇合区，见 §3.3。
    private var metricsByTask: [Int: URLSessionTaskMetrics] = [:]

    init(manager: AFHTTPSessionManager) {
        self.manager = manager
        super.init()
        // 注意：这是替换式接口。若业务自己也设了 metrics block，
        // 二者只能活一个——要么约定这一层只有一个主人，
        // 要么改读通知（但会失去时序可控性）。
        manager.setTaskDidFinishCollectingMetricsBlock { [weak self] _, task, metrics in
            guard let self, let metrics else { return }
            self.lock.lock()
            self.metricsByTask[task.taskIdentifier] = metrics
            self.lock.unlock()
        }
    }

    func add(adapter: TDRequestAdapter) { lock.lock(); adapters.append(adapter); lock.unlock() }
    func add(retrier: TDRequestRetrier) { lock.lock(); retriers.append(retrier); lock.unlock() }
    func add(observer: TDNetworkObserver) { lock.lock(); observers.append(observer); lock.unlock() }

    func send(_ request: TDNetworkRequest,
              completion: ((TDNetworkResult) -> Void)?) -> TDNetworkCancellable {
        let context = TDNetworkContext(traceId: request.tag.traceId ?? UUID().uuidString)

        // adapter 链：串行，前一环的输出是后一环的输入。
        var adapted = request
        for adapter in adapters {
            if context.isBypassed(adapter) { continue }
            do {
                adapted = try adapter.adapt(adapted, context: context)
            } catch {
                // 短路也必须产样本，否则「接口从没被调用过」是假象。
                let result = TDNetworkResult(
                    request: adapted, context: context, response: nil, data: nil,
                    error: error, metrics: nil, metricsMissing: true,
                    shortCircuit: .preconditionFailed)
                completion?(result)
                announce(result)
                return NoopCancellable()
            }
        }

        let urlRequest = adapted.asURLRequest()
        let task = manager.dataTask(with: urlRequest) { [weak self] response, data, error in
            guard let self else { return }
            // 业务回调先走，不等 metrics——观测不能拖慢业务。
            // 这里只组装；真正的上报交给下面的汇合逻辑（带 1s 兜底窗口）。
            self.finish(adapted, context, response, data, error, completion: completion)
        }
        task.resume()
        return TaskCancellable(task)
    }
}
```

`finish` 里要做的事与 `TDURLSessionNetworkClient.tryEmit` 完全一致：
等 `metricsByTask[taskIdentifier]` 出现，或 1s 兜底超时，然后构造
`TDNetworkResult` → 走 retrier 链 → 喂给 `TDNetworkSampleObserver`。
**不要在 completion 里直接读 metrics**，那一刻大概率还没到（§3.3）。

## 5. 上报自举：三个收益 + 一个必须防的冲突

让监控自己的上报走同一个网络层，收益是实打实的：

1. **上报能感知真实网络质量**。现在的 `TDTransport` 是盲发——不知道失败是弱网、
   DNS 挂了，还是后端 5xx。走统一层后能拿到分段耗时，弱网时可以主动拉长 flush 间隔，
   而不是每 10s 撞一次超时。
2. **业务请求失败与崩溃能串起来**。同一个 `X-TD-Trace-Id`，后端可以反查
   「用户是在某个接口连续超时之后崩的」。
3. **上报流量可被显式标记**。`TDRequestTag.isInternal = true` 替代旧实现里
   `url.contains(host) && url.contains(path)` 的字符串匹配——那种写法在后端换域名、
   加 CDN、改路径前缀时会**静默失效**，表现为监控自身请求混进业务成功率。

**必须防的冲突**：上报请求不能走 retrier。它已经有 `TDRetryPolicy` 的指数退避，
再叠一层就是双重退避，表现为「设备离线时上报队列越积越多，恢复后一次性涌出」。
这就是 `TDURLSessionNetworkClient.shouldConsultRetrier(for:)` 存在的唯一原因，
也是它被抽成静态纯函数的原因——这条规则错了只能靠线上爆量发现，必须可单测。

## 6. 这套能力管不到什么

必须提前说，否则对接方会以为「全量网络可观测」。

| 流量 | 为什么管不到 |
|---|---|
| SDWebImage 等图片库 | 内部自建 session，不经过业务出口 |
| `WKWebView` 页面内请求 | 在 WebContent 进程里，宿主看不到 |
| AMapLocation / QNNetDiag 等三方 SDK | 各自建 session，只受 legacy swizzle 部分覆盖 |

兜底是 legacy swizzle（`TDNetworkInstrumentation` 的完成回调拦截）：
它能覆盖这些流量，但**没有分段耗时**，因为完成回调路径拿不到 `URLSessionTaskMetrics`。
