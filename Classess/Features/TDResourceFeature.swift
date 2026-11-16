import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 4. 资源采样

final class TDResourceFeature: TDMonitorFeature {

    static let name = "resources"

    private let runtime: TDMonitorRuntime
    private let monitor: TDResourceMonitor

    init?(runtime: TDMonitorRuntime) {
        guard runtime.configuration.autoCollect else { return nil }
        self.runtime = runtime
        self.monitor = TDResourceMonitor(config: runtime.configuration,
                                         sink: runtime.sink,
                                         appState: runtime.appState)
    }

    func install() -> Bool {
        runtime.provide(monitor)
        monitor.start()
        return true
    }

    func uninstall() {
        monitor.stop()
    }
}

