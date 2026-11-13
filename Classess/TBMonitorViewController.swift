import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// 页面加载耗时自动采集。
///
/// 早期只有手工 `recordViewLoad`，全仓无人调用，等于没有。这里对 UIViewController
/// 做方法交换，自动拿到两个业界通用的口径：
/// - `appearMs`：`viewWillAppear` → `viewDidAppear`，用户感知的「页面出现」代价
/// - `loadMs`：`viewDidLoad` → `viewDidAppear`，含构建视图的完整代价
///
/// 系统类（UI*、_*）一律跳过，避免把导航栈内部的容器页算进业务页面。
final class TDViewControllerInstrumentation {

    static let shared = TDViewControllerInstrumentation()

    typealias Handler = (_ screen: String, _ appearMs: Double, _ loadMs: Double?) -> Void

    private var installed = false
    private var handler: Handler?

    private init() {}

    func install(handler: @escaping Handler) {
        guard !installed else { return }
        installed = true
        self.handler = handler

        let controller = UIViewController.self
        swizzle(controller,
                original: #selector(UIViewController.viewDidLoad),
                replacement: #selector(UIViewController.td_viewDidLoad))
        swizzle(controller,
                original: #selector(UIViewController.viewWillAppear(_:)),
                replacement: #selector(UIViewController.td_viewWillAppear(_:)))
        swizzle(controller,
                original: #selector(UIViewController.viewDidAppear(_:)),
                replacement: #selector(UIViewController.td_viewDidAppear(_:)))
    }

    private func swizzle(_ cls: AnyClass, original: Selector, replacement: Selector) {
        guard let originalMethod = class_getInstanceMethod(cls, original),
              let replacementMethod = class_getInstanceMethod(cls, replacement) else { return }
        method_exchangeImplementations(originalMethod, replacementMethod)
    }

    func handle(_ screen: String, appearMs: Double, loadMs: Double?) {
        // 系统容器页（UINavigationController / UITabBarController / _UIPageSheet…）
        // 不是业务页面，计入会稀释真实页面的渲染指标。
        guard !screen.hasPrefix("UI"), !screen.hasPrefix("_") else { return }
        handler?(screen, appearMs, loadMs)
    }
}

private var tdViewDidLoadKey: UInt8 = 0
private var tdViewWillAppearKey: UInt8 = 0

extension UIViewController {

    @objc func td_viewDidLoad() {
        objc_setAssociatedObject(self, &tdViewDidLoadKey, Date(), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        td_viewDidLoad()
    }

    @objc func td_viewWillAppear(_ animated: Bool) {
        if objc_getAssociatedObject(self, &tdViewWillAppearKey) == nil {
            objc_setAssociatedObject(self, &tdViewWillAppearKey, Date(), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        TDScreenContext.shared.update(td_screenName)
        td_viewWillAppear(animated)
    }

    @objc func td_viewDidAppear(_ animated: Bool) {
        td_viewDidAppear(animated)

        let now = Date()
        defer { objc_setAssociatedObject(self, &tdViewWillAppearKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }

        guard let willAppear = objc_getAssociatedObject(self, &tdViewWillAppearKey) as? Date else { return }
        let loadAt = objc_getAssociatedObject(self, &tdViewDidLoadKey) as? Date
        TDViewControllerInstrumentation.shared.handle(
            td_screenName,
            appearMs: now.timeIntervalSince(willAppear) * 1000,
            loadMs: loadAt.map { now.timeIntervalSince($0) * 1000 }
        )
    }

    /// 去掉模块前缀与系统类。`TrueDepthDemo2.TBFinanceHomeViewController` → `TBFinanceHomeViewController`
    private var td_screenName: String {
        let raw = String(describing: type(of: self))
        let name = raw.split(separator: ".").last.map(String.init) ?? raw
        return name
    }
}
