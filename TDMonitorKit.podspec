Pod::Spec.new do |spec|
  spec.name                  = "TDMonitorKit"
  spec.version               = "1.0.0"
  spec.summary               = "TrueDepth 客户端统一监控组件：崩溃/ANR/OOM/FPS/启动/资源/网络指标采集与上报"
  spec.ios.deployment_target = "13.0"
  spec.swift_version         = "5.7"
  spec.homepage              = "https://localhost/TDMonitorKit"
  spec.license               = { :type => "MIT" }
  spec.author                = { "local" => "local" }
  # :path pods ignore `source`; keep it so `pod spec lint` stays quiet.
  spec.source                = { :git => "https://localhost/TDMonitorKit.git", :tag => spec.version.to_s }
  spec.source_files          = "Classess/**/*.swift"
  spec.frameworks            = "Foundation", "UIKit", "SystemConfiguration"
  # MetricKit diagnostics are iOS 14+ and guarded with @available / canImport.
  spec.weak_frameworks       = "MetricKit"
  spec.requires_arc          = true
end
