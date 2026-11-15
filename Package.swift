// swift-tools-version:5.7
import PackageDescription

/// 组件自带独立测试工程。
///
/// 存在的理由：如果测试只能挂在宿主 App 的测试 target 上，那么「这个组件能不能被
/// 另一个团队接走」就无法自证——接走的人拿不到测试，改动只能靠肉眼保证。
/// 有了 Package.swift，clone 组件目录即可直接跑：
///
///     cd components/TDMonitorKit
///     xcodebuild -scheme TDMonitorKit -destination 'platform=iOS Simulator,name=iPhone 15' test
///
/// 注意本文件只服务于本地测试，主工程仍然通过 TDMonitorKit.podspec 以 :path 集成，
/// 两条路径共用 Classess/ 下的同一份源码，不存在两份实现。
let package = Package(
    name: "TDMonitorKit",
    platforms: [
        .iOS(.v13)
    ],
    products: [
        .library(name: "TDMonitorKit", targets: ["TDMonitorKit"])
    ],
    targets: [
        .target(
            name: "TDMonitorKit",
            path: "Classess"
        ),
        .testTarget(
            name: "TDMonitorKitTests",
            dependencies: ["TDMonitorKit"],
            path: "TDMonitorKitTests"
        )
    ]
)
