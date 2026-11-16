import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 10. 非致命异常

final class TDNonFatalFeature: TDMonitorFeature {

    static let name = "non_fatal"
    static let requires = ["crash"]

    private let runtime: TDMonitorRuntime

    init?(runtime: TDMonitorRuntime) {
        guard runtime.configuration.nonFatalCapture else { return nil }
        guard runtime.service(TDCrashBridge.self) != nil else { return nil }
        self.runtime = runtime
    }

    func install() -> Bool {
        let runtime = self.runtime
        TDNonFatalRecorder.shared.install { message, stack, category, attributes in
            runtime.service(TDCrashBridge.self)?
                .recordNonFatal(message: message, stack: stack,
                                category: category, attributes: attributes)
        }
        return true
    }

    func uninstall() {
        TDNonFatalRecorder.shared.uninstall()
    }
}

