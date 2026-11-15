import Foundation

/// 接入自检。
///
/// 存在的理由来自一个具体的失败模式：崩溃补发依赖宿主注入
/// `TDMonitor.hostCrashReportPaths`。宿主忘了配，SDK 不会崩、不会报错，
/// 只是**永远没有崩溃数据**——而"没有崩溃"和"没抓到崩溃"在报表上长得一模一样。
///
/// 这类问题不能靠文档解决。文档写了没人看，看了也不一定照着做。能解决它的只有
/// 一件事：启动时把「你漏配了什么、会导致什么后果」说出来。
///
/// 纯函数，不读 `Bundle`、不发网络，方便直接单测。
enum TDIntakeSelfCheck {

    struct Finding: Equatable {
        enum Level: String {
            /// 数据会缺失，且没有任何其他提示。
            case blocking
            /// 能工作，但在生产环境会出问题。
            case warning
        }
        let level: Level
        let item: String
        let message: String
    }

    static func run(configuration: TDMonitorConfiguration,
                    crashReportsConfigured: Bool,
                    isDebugBuild: Bool) -> [Finding] {
        var findings: [Finding] = []

        if configuration.apiKey.isEmpty {
            findings.append(Finding(
                level: .blocking, item: "apiKey",
                message: "apiKey 为空，监控不会启动"))
        }

        // 崩溃是唯一一个「不配就彻底没有数据」的能力，也是最容易被忽略的：
        // 它不像 ANR 那样 SDK 自己能采集，必须由宿主把落盘路径交出来。
        if !crashReportsConfigured {
            findings.append(Finding(
                level: .blocking, item: "crash_reports",
                message: "未设置 TDMonitor.hostCrashReportPaths，崩溃补发不会工作；"
                    + "崩溃率将恒为 0，且不会有任何报错"))
        }

        // 明文 HTTP 在内网联调可以，上线会被 ATS 拦掉，表现同样是「没有数据」。
        if configuration.baseURL.scheme?.lowercased() == "http" && !isDebugBuild {
            findings.append(Finding(
                level: .warning, item: "transport_security",
                message: "Release 构建使用明文 HTTP，ATS 会拦截上报；确认是否应为 HTTPS"))
        }

        if configuration.baseURL.host == "localhost" || configuration.baseURL.host == "127.0.0.1" {
            findings.append(Finding(
                level: .warning, item: "ingest_host",
                message: "上报地址指向本机，打包后无法连通"))
        }

        // 采样率 < 1 时，有的指标是按事件随机丢的，有的是按会话整段丢的。
        // 接入方常以为"只是少一点"，实际是某些页面完全消失。
        if configuration.sampleRate < 1 {
            findings.append(Finding(
                level: .warning, item: "sample_rate",
                message: "采样率 \(configuration.sampleRate)，"
                    + "资源类指标按条丢弃、其余按会话保留；低频页面可能出现整段缺失"))
        }

        return findings
    }

    /// 给日志用的一行摘要。没有问题时返回 nil，不制造噪声。
    static func summary(_ findings: [Finding]) -> String? {
        guard !findings.isEmpty else { return nil }
        let blocking = findings.filter { $0.level == .blocking }.count
        let head = blocking > 0 ? "\(blocking) 项会导致数据缺失" : "\(findings.count) 项需确认"
        return head + "：" + findings.map { "[\($0.item)] \($0.message)" }.joined(separator: "；")
    }
}
