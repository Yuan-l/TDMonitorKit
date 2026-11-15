import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// 页面加载耗时 + 页面渲染质量自动采集。
///
/// 早期只有手工 `recordViewLoad`，全仓无人调用，等于没有。这里对 UIViewController
/// 做方法交换，拿到三样业界通用口径：
/// - `appearMs`：`viewWillAppear` → `viewDidAppear`，用户感知的「页面出现」代价
/// - `loadMs`：`viewDidLoad` → 首次 `viewDidAppear`，含构建视图的完整代价
/// - 页面渲染质量：`viewDidAppear` → `viewDidDisappear` 期间的慢帧 / 冻结帧
///   （口径见 `TDScreenFrameSession`）
///
/// 系统类（UI*、_*）一律跳过，避免把导航栈内部的容器页算进业务页面。
final class TDViewControllerInstrumentation {

    static let shared = TDViewControllerInstrumentation()

    typealias LoadHandler = (_ screen: String, _ appearMs: Double, _ loadMs: Double?) -> Void

    private var installed = false
    private var loadHandler: LoadHandler?
    /// 记录交换过的 selector 对，`method_exchangeImplementations` 是自身逆运算，
    /// 再交换一次即还原。
    private var swizzledPairs: [(original: Selector, replacement: Selector)] = []

    private init() {}

    func install(loadHandler: @escaping LoadHandler) {
        guard !installed else { return }
        installed = true
        self.loadHandler = loadHandler

        let controller = UIViewController.self
        let pairs: [(original: Selector, replacement: Selector)] = [
            (#selector(UIViewController.viewDidLoad), #selector(UIViewController.td_viewDidLoad)),
            (#selector(UIViewController.viewWillAppear(_:)), #selector(UIViewController.td_viewWillAppear(_:))),
            (#selector(UIViewController.viewDidAppear(_:)), #selector(UIViewController.td_viewDidAppear(_:))),
            (#selector(UIViewController.viewDidDisappear(_:)), #selector(UIViewController.td_viewDidDisappear(_:))),
        ]
        for pair in pairs {
            swizzle(controller, original: pair.original, replacement: pair.replacement)
        }
        swizzledPairs = pairs
    }

    /// 还原方法交换。页面插桩是纯读取，没有飞行中的任务持有旧 IMP，
    /// 因此这里可以真正撤销，不像网络钩子那样只能停止投递。
    func uninstall() {
        guard installed else { return }
        installed = false
        loadHandler = nil
        let controller = UIViewController.self
        for pair in swizzledPairs.reversed() {
            swizzle(controller, original: pair.original, replacement: pair.replacement)
        }
        swizzledPairs.removeAll()
    }

    private func swizzle(_ cls: AnyClass, original: Selector, replacement: Selector) {
        guard let originalMethod = class_getInstanceMethod(cls, original),
              let replacementMethod = class_getInstanceMethod(cls, replacement) else { return }
        method_exchangeImplementations(originalMethod, replacementMethod)
    }

    /// 系统容器页（UINavigationController / UITabBarController / _UIPageSheet…）
    /// 不是业务页面，计入会稀释真实页面的渲染指标。
    static func isBusinessScreen(_ name: String) -> Bool {
        !name.hasPrefix("UI") && !name.hasPrefix("_")
    }


    func handleLoad(_ screen: String, appearMs: Double, loadMs: Double?) {
        guard Self.isBusinessScreen(screen) else { return }
        loadHandler?(screen, appearMs, loadMs)
    }
}

// MARK: - 关联对象键

private var tdViewDidLoadKey: UInt8 = 0
private var tdViewWillAppearKey: UInt8 = 0
private var tdFrameSessionKey: UInt8 = 0

extension UIViewController {

    @objc func td_viewDidLoad() {
        objc_setAssociatedObject(self, &tdViewDidLoadKey, Date(), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        td_viewDidLoad()
    }

    @objc func td_viewWillAppear(_ animated: Bool) {
        if objc_getAssociatedObject(self, &tdViewWillAppearKey) == nil {
            objc_setAssociatedObject(self, &tdViewWillAppearKey, Date(), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        td_viewWillAppear(animated)
    }

    @objc func td_viewDidAppear(_ animated: Bool) {
        td_viewDidAppear(animated)

        let now = Date()
        defer { objc_setAssociatedObject(self, &tdViewWillAppearKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }

        let name = td_screenName
        let isBusiness = TDViewControllerInstrumentation.isBusinessScreen(name)

        // 和 Firebase `FPRUIViewControllerInstrument` 对齐：只有真正承载在
        // keyWindow 上的页面才算「用户看着的页面」。缺这个判定，多 scene 下
        // 非活跃窗口的页面、被 present 但没成为 key 的页面都会进统计，
        // 页面帧率排行榜会被根本没人看的页面污染。
        guard isBusiness, td_isOnKeyWindow else { return }
        TDScreenContext.shared.push(name)

        guard let willAppear = objc_getAssociatedObject(self, &tdViewWillAppearKey) as? Date else { return }
        // 关键修正：`viewDidLoad` 只发生一次，但 `viewDidAppear` 在每次 pop 回来、
        // tab 切换、modal 关闭时都会再次触发。之前不清这个时间戳，第二次起
        // `loadMs` 会算成「距上次 viewDidLoad 的墙钟差」，动辄几万毫秒，
        // 直接把页面耗时 P95 拉爆。
        let loadAt = objc_getAssociatedObject(self, &tdViewDidLoadKey) as? Date
        objc_setAssociatedObject(self, &tdViewDidLoadKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        TDViewControllerInstrumentation.shared.handleLoad(
            name,
            appearMs: now.timeIntervalSince(willAppear) * 1000,
            loadMs: loadAt.map { now.timeIntervalSince($0) * 1000 }
        )

        // 开启页面渲染统计：每个页面一份独立会话，push 过程中新旧页面
        // 各统计各的，互不干扰。
        if let existing = objc_getAssociatedObject(self, &tdFrameSessionKey) as? TDScreenFrameSession {
            // 理论上不该有残留（disappear 会清），防御性处理。
            TDScreenFrameTracker.shared.end(existing)
        }
        let budget = 1.0 / max(Double(UIScreen.main.maximumFramesPerSecond), 60.0)
        let session = TDScreenFrameSession(screen: name, budget: budget)
        objc_setAssociatedObject(self, &tdFrameSessionKey, session, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        TDScreenFrameTracker.shared.begin(session)
    }

    @objc func td_viewDidDisappear(_ animated: Bool) {
        td_viewDidDisappear(animated)

        let name = td_screenName
        if TDViewControllerInstrumentation.isBusinessScreen(name) {
            TDScreenContext.shared.pop(name)
        }

        guard let session = objc_getAssociatedObject(self, &tdFrameSessionKey) as? TDScreenFrameSession else { return }
        objc_setAssociatedObject(self, &tdFrameSessionKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        // 结算并上报由 tracker 统一收口（含切片上报），这里不重复处理。
        TDScreenFrameTracker.shared.end(session)
    }

    /// 页面是否真的挂在 keyWindow 上。
    ///
    /// 对应 Firebase `FPRUIViewControllerInstrument` 里的
    /// `((UIViewController *)_self).view.window.keyWindow` 判定。
    private var td_isOnKeyWindow: Bool {
        guard let window = view.window, !window.isHidden else { return false }
        if isBeingDismissed || isMovingFromParent { return false }
        return window.isKeyWindow
    }

    /// 去掉模块前缀与系统类。`TrueDepthDemo2.TBFinanceHomeViewController` → `TBFinanceHomeViewController`
    private var td_screenName: String {
        let raw = String(describing: type(of: self))
        let name = raw.split(separator: ".").last.map(String.init) ?? raw
        return name
    }
}
