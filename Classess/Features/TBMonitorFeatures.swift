import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 能力单元总览
//
// 每个类型对应一项可独立安装、独立卸载的采集能力。约定：
//
// 1. `init?` 返回 nil = 当前环境不支持该能力（iOS 版本、配置关闭）。
//    注册表静默跳过，其余能力照常安装。这是「iOS 13 没有 MXAppExitMetric
//    怎么办」的答案：能力不存在，其余全部正常，且 `cap.*` 会在
//    session_start 里如实自报 0。
// 2. `install()` 返回 false = 运行期安装失败，同样不阻断其它能力。
// 3. 跨能力取依赖一律走 `runtime.service(_:)`，不持有对方实例引用。
//
// 与业界对照：
// - Sentry `SentryIntegrationProtocol` / `SwiftIntegration`：可失败初始化器、
//   `static var name`、`uninstall()`，由 `SentrySDKInternal.installIntegrations`
//   在 Hub 建好后统一安装
// - Datadog `DatadogCore` + 各 Feature 模块：能力以模块为粒度独立引入，
//   依赖由 Core 的依赖容器（FeatureBaggage）统一提供

