Pod::Spec.new do |spec|
  spec.name                  = "TDMonitorKit"
  spec.version               = "2.5.4"
  spec.summary               = "TrueDepth 客户端统一监控组件：崩溃/ANR/OOM/页面帧率/启动/资源/网络指标采集与上报"
  spec.description           = <<-DESC
    一个按「Core 容器 + 可独立安装的能力单元」组织 iOS 监控 SDK：
    - 出口可替换：采集侧只依赖 TDEventSink 协议，默认实现走内置 HTTP
    - 能力可单独安装/卸载：每个能力实现 TDMonitorFeature（可失败初始化器）
    - 纯逻辑可单测：时间、出口、采集器均可注入替身
    口径对齐 Sentry / Datadog / Firebase，差异点在 docs/INDUSTRY-COMPARISON.md 中逐条说明。
  DESC
  spec.ios.deployment_target = "13.0"
  spec.swift_version         = "5.7"

  # 内部组件，由主工程以 :path 引用。发布到私有源时把下面两项换成真实地址；
  # `.example` 是 RFC 2606 保留域名，明确表示「这里是占位」而不是伪装成可用地址。
  spec.homepage              = "https://internal.truedepth.example/TDMonitorKit"
  spec.license               = { :type => "MIT" }
  spec.author                = { "truedepth" => "mobile@truedepth.example" }
  spec.source                = { :git => "https://internal.truedepth.example/TDMonitorKit.git", :tag => spec.version.to_s }

  spec.source_files          = "Classess/**/*.swift"
  spec.frameworks            = "Foundation", "UIKit", "SystemConfiguration"
  # 事件队列落盘复用独立 L0 底座 TBMMAPStorageKit（TBMMAPLogFile / TBMMAPRecordStore）：
  # 每条 CRC32 + AES-256-CBC + msync 提交位点，不另起一套持久化实现。
  # 2026-11-17 从 TBCustomNetworkLogger 抽出——TD 不再依赖退役上报器组件。
  spec.dependency            "TBMMAPStorageKit"
  # MetricKit diagnostics are iOS 14+ and guarded with @available / canImport.
  spec.weak_frameworks       = "MetricKit"
  spec.requires_arc          = true

  # 没有 test_spec 时 `xcodebuild test` 找不到 target，测试等于写在纸上。
  spec.test_spec 'Tests' do |test_spec|
    test_spec.source_files = "TDMonitorKitTests/**/*.swift"
    test_spec.frameworks   = "XCTest"
  end
end
