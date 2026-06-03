import Flutter
import UIKit

/// Manager for iOS 26+ Native Tab Bar with Search Support
@available(iOS 26.0, *)
class iOS26NativeTabBarManager: NSObject {

    static let shared = iOS26NativeTabBarManager()

    private var tabBarController: OverlayTabBarController?
    private var overlayPassthroughView: PassThroughOverlayView?
    private var flutterViewController: FlutterViewController?
    private var searchController: UISearchController?
    private var methodChannel: FlutterMethodChannel?

    private var tabConfigurations: [TabConfig] = []
    private var searchTabIndex: Int = -1
    private var browseIndexBeforeSearch: Int = 0
    private var isSearchMorphActive: Bool = false
    private var isEnabled: Bool = false
    private var selectedTint: UIColor? = nil

    /// Pending hide/show work scheduled with a lead-in delay. Cancelled
    /// on rapid toggle so the latest hide/show wins.
    private var pendingFadeWorkItem: DispatchWorkItem?

    struct TabConfig {
        let title: String
        let sfSymbol: String?
        let isSearchTab: Bool
        let badgeCount: Int?
    }

    private override init() {
        super.init()
    }

    func setup(messenger: FlutterBinaryMessenger) {
        self.methodChannel = FlutterMethodChannel(
            name: "adaptive_platform_ui/native_tab_bar",
            binaryMessenger: messenger
        )

        methodChannel?.setMethodCallHandler { [weak self] call, result in
            self?.handleMethodCall(call, result: result)
        }
    }

    private func getFlutterViewController() -> FlutterViewController? {
        if let flutterVC = flutterViewController {
            return flutterVC
        }

        for window in UIApplication.shared.windows {
            if let flutterVC = findFlutterViewController(in: window.rootViewController) {
                self.flutterViewController = flutterVC
                return flutterVC
            }
        }

        return nil
    }

    private func findFlutterViewController(in viewController: UIViewController?)
        -> FlutterViewController?
    {
        if let flutterVC = viewController as? FlutterViewController {
            return flutterVC
        }
        for child in viewController?.children ?? [] {
            if let flutterVC = findFlutterViewController(in: child) {
                return flutterVC
            }
        }
        return nil
    }

    private func enableNativeTabBar(
        tabs: [TabConfig], selectedIndex: Int, selectedTint: UIColor? = nil
    ) {
        self.selectedTint = selectedTint
        guard let flutterVC = getFlutterViewController() else {
            return
        }

        // Tear down any prior overlay without touching the Flutter root.
        if let existing = tabBarController {
            detachTabBarOverlay(existing, from: flutterVC)
        }

        self.flutterViewController = flutterVC

        let tabBar = OverlayTabBarController()
        tabBarController = tabBar
        setupTabBarAppearance(tabBar)

        self.tabConfigurations = tabs
        self.searchTabIndex = tabs.firstIndex(where: { $0.isSearchTab }) ?? -1

        var viewControllers: [UIViewController] = []

        for (index, config) in tabs.enumerated() {
            if config.isSearchTab {
                let searchVC = SearchTabViewController()
                searchVC.tabIndex = index

                let navController = UINavigationController(rootViewController: searchVC)
                navController.setNavigationBarHidden(true, animated: false)

                let search = UISearchController(searchResultsController: nil)
                search.searchResultsUpdater = self
                search.delegate = self
                search.searchBar.delegate = self
                search.obscuresBackgroundDuringPresentation = false
                search.searchBar.placeholder = "Search"
                search.hidesNavigationBarDuringPresentation = false
                // Exit search via another tab — no cancel / X affordance.
                search.automaticallyShowsCancelButton = false
                search.searchBar.showsCancelButton = false

                searchVC.navigationItem.searchController = search
                searchVC.navigationItem.hidesSearchBarWhenScrolling = false

                self.searchController = search

                navController.tabBarItem = UITabBarItem(tabBarSystemItem: .search, tag: index)
                if !config.title.isEmpty {
                    navController.tabBarItem.title = config.title
                }

                viewControllers.append(navController)
            } else {
                let tabVC = EmptyTabVC()
                tabVC.tabIndex = index

                var image: UIImage?
                if let symbol = config.sfSymbol {
                    image = UIImage(systemName: symbol)
                }
                tabVC.tabBarItem = UITabBarItem(
                    title: config.title,
                    image: image,
                    selectedImage: image
                )
                tabVC.tabBarItem.tag = index

                if let count = config.badgeCount, count > 0 {
                    tabVC.tabBarItem.badgeValue = count > 99 ? "99+" : String(count)
                } else {
                    tabVC.tabBarItem.badgeValue = nil
                }

                viewControllers.append(tabVC)
            }
        }

        tabBar.viewControllers = viewControllers
        tabBar.selectedIndex = selectedIndex
        tabBar.delegate = self

        // Overlay the native tab bar ON TOP of the existing Flutter root.
        // The Flutter view never moves and window.rootViewController stays
        // FlutterViewController — replacing root or re-parenting the Metal
        // surface is what caused the persistent black screen.
        attachTabBarOverlay(tabBar, to: flutterVC)

        isEnabled = true
    }

    /// Hide / show the iOS 26 native tab bar with the system's built-in
    /// liquid-glass dematerialize / materialize animation.
    ///
    /// Uses `UITabBarController.setTabBarHidden(_:animated:)` for the glass
    /// material transition. On hide, UIKit dematerializes the glass correctly
    /// but snaps tab-item icons/labels to alpha 0 instantly — so we run a
    /// matching alpha fade on the item chrome in parallel (show is fine as-is).
    private func setOverlayModalDimmed(
        _ dimmed: Bool, opacity: CGFloat, animated: Bool, durationMs: Int
    ) {
        overlayPassthroughView?.setModalDimmed(
            dimmed, opacity: opacity, animated: animated, durationMs: durationMs)
    }

    private func setOverlayHidden(_ hidden: Bool, animated: Bool, durationMs: Int, delayMs: Int) {
        guard let overlay = overlayPassthroughView,
            let tabBarVC = tabBarController
        else { return }

        if hidden {
            overlay.setModalDimmed(false, opacity: 0, animated: false, durationMs: 0)
        }

        overlay.isUserInteractionEnabled = !hidden

        pendingFadeWorkItem?.cancel()
        pendingFadeWorkItem = nil

        let duration = max(0.25, Double(durationMs) / 1000.0)

        let apply: () -> Void = { [weak self] in
            guard let self,
                let tabBarVC = self.tabBarController
            else { return }

            let tabBar = tabBarVC.tabBar

            if #available(iOS 18.0, *) {
                if hidden {
                    // Ensure item chrome starts fully visible, then fade it
                    // in the same window as the system glass dematerialize.
                    let itemViews = Self.collectTabBarItemViews(in: tabBar)
                    itemViews.forEach { $0.alpha = 1 }

                    if animated {
                        UIView.animate(
                            withDuration: duration,
                            delay: 0,
                            options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]
                        ) {
                            itemViews.forEach { $0.alpha = 0 }
                        }
                    } else {
                        itemViews.forEach { $0.alpha = 0 }
                    }

                    tabBarVC.setTabBarHidden(true, animated: animated)
                } else {
                    // Restore item chrome before the materialize animation —
                    // our hide fade left them at alpha 0 and deferring the
                    // reset made the separated search pill lag ~320ms behind
                    // the main tab bar glass.
                    Self.resetTabBarItemAlphas(in: tabBar)
                    tabBarVC.setTabBarHidden(false, animated: animated)
                }
            } else {
                tabBar.isHidden = hidden
            }
        }

        let delay = max(0, Double(delayMs)) / 1000.0
        if delay == 0 || !animated {
            apply()
        } else {
            let work = DispatchWorkItem(block: apply)
            pendingFadeWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    /// Tab bar buttons / labels / icons — everything except the glass
    /// background layers that `setTabBarHidden` dematerializes on its own.
    private static func collectTabBarItemViews(in tabBar: UITabBar) -> [UIView] {
        var results: [UIView] = []
        for subview in tabBar.subviews {
            if subview is UIVisualEffectView { continue }
            let name = String(describing: type(of: subview))
            if name.contains("BarBackground") || name.contains("Platter") { continue }
            results.append(subview)
            collectTabBarItemViewsRecursive(subview, into: &results)
        }
        return results
    }

    private static func collectTabBarItemViewsRecursive(_ view: UIView, into results: inout [UIView]) {
        for subview in view.subviews {
            if subview is UIVisualEffectView { continue }
            results.append(subview)
            collectTabBarItemViewsRecursive(subview, into: &results)
        }
    }

    private static func resetTabBarItemAlphas(in tabBar: UITabBar) {
        collectTabBarItemViews(in: tabBar).forEach { $0.alpha = 1 }
    }

    private func disableNativeTabBar() {
        guard let flutterVC = getFlutterViewController(),
            let tabBar = tabBarController
        else {
            return
        }

        detachTabBarOverlay(tabBar, from: flutterVC)

        isEnabled = false
        tabBarController = nil
    }

    private func attachTabBarOverlay(
        _ tabBar: OverlayTabBarController, to flutterVC: FlutterViewController
    ) {
        let passthrough = PassThroughOverlayView()
        passthrough.tabBarController = tabBar
        passthrough.searchController = searchController
        passthrough.searchTabIndex = searchTabIndex
        passthrough.isSearchMorphActive = isSearchMorphActive
        passthrough.translatesAutoresizingMaskIntoConstraints = false
        overlayPassthroughView = passthrough

        flutterVC.addChild(tabBar)
        tabBar.view.translatesAutoresizingMaskIntoConstraints = false
        passthrough.addSubview(tabBar.view)
        NSLayoutConstraint.activate([
            tabBar.view.leadingAnchor.constraint(equalTo: passthrough.leadingAnchor),
            tabBar.view.trailingAnchor.constraint(equalTo: passthrough.trailingAnchor),
            tabBar.view.topAnchor.constraint(equalTo: passthrough.topAnchor),
            tabBar.view.bottomAnchor.constraint(equalTo: passthrough.bottomAnchor),
        ])
        tabBar.didMove(toParent: flutterVC)

        flutterVC.view.addSubview(passthrough)
        NSLayoutConstraint.activate([
            passthrough.leadingAnchor.constraint(equalTo: flutterVC.view.leadingAnchor),
            passthrough.trailingAnchor.constraint(equalTo: flutterVC.view.trailingAnchor),
            passthrough.topAnchor.constraint(equalTo: flutterVC.view.topAnchor),
            passthrough.bottomAnchor.constraint(equalTo: flutterVC.view.bottomAnchor),
        ])

        tabBar.elevateTabBarChrome()
        flutterVC.view.bringSubviewToFront(passthrough)
    }

    private func detachTabBarOverlay(
        _ tabBar: OverlayTabBarController, from flutterVC: FlutterViewController
    ) {
        pendingFadeWorkItem?.cancel()
        pendingFadeWorkItem = nil

        // Make sure we don't leave a previously-hidden tab bar in an
        // inconsistent state for the next attach cycle.
        if #available(iOS 18.0, *) {
            tabBar.setTabBarHidden(false, animated: false)
        }
        Self.resetTabBarItemAlphas(in: tabBar.tabBar)
        tabBar.willMove(toParent: nil)
        tabBar.view.removeFromSuperview()
        tabBar.removeFromParent()
        overlayPassthroughView?.removeFromSuperview()
        overlayPassthroughView = nil
    }

    private func setupTabBarAppearance(_ tabBar: UITabBarController) {
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        // iOS 26 applies its own liquid-glass material to the floating
        // pill via a private compositing path; this legacy backgroundEffect
        // is ignored on iOS 26 but kept for the pre-26 fallback path.
        appearance.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterial)
        appearance.shadowColor = .clear

        tabBar.tabBar.standardAppearance = appearance
        tabBar.tabBar.scrollEdgeAppearance = appearance

        if let tint = selectedTint {
            tabBar.tabBar.tintColor = tint
        }
    }

    private func notifyTabSelected(_ index: Int) {
        methodChannel?.invokeMethod("onTabSelected", arguments: ["index": index])
    }

    private func notifySearchQueryChanged(_ query: String) {
        methodChannel?.invokeMethod("onSearchQueryChanged", arguments: ["query": query])
    }

    private func notifySearchSubmitted(_ query: String) {
        methodChannel?.invokeMethod("onSearchSubmitted", arguments: ["query": query])
    }

    private func notifySearchActivated() {
        isSearchMorphActive = true
        overlayPassthroughView?.isSearchMorphActive = true
        methodChannel?.invokeMethod("onSearchActivated", arguments: nil)
    }

    private func notifySearchDeactivated() {
        isSearchMorphActive = false
        overlayPassthroughView?.isSearchMorphActive = false
        methodChannel?.invokeMethod("onSearchDeactivated", arguments: nil)
    }

    private func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "enableNativeTabBar":
            guard let args = call.arguments as? [String: Any],
                let tabsData = args["tabs"] as? [[String: Any]]
            else {
                result(
                    FlutterError(code: "invalid_args", message: "Invalid tabs data", details: nil))
                return
            }

            let tabs = tabsData.compactMap { data -> TabConfig? in
                guard let title = data["title"] as? String else { return nil }
                let symbol = data["sfSymbol"] as? String
                let isSearch = (data["isSearch"] as? Bool) ?? false
                let badgeCount = data["badgeCount"] as? Int
                return TabConfig(
                    title: title, sfSymbol: symbol, isSearchTab: isSearch, badgeCount: badgeCount)
            }

            let selectedIndex = (args["selectedIndex"] as? Int) ?? 0
            var tint: UIColor? = nil
            if let argb = args["selectedTint"] as? NSNumber {
                tint = Self.colorFromARGB(argb.intValue)
            }
            enableNativeTabBar(tabs: tabs, selectedIndex: selectedIndex, selectedTint: tint)
            result(nil)

        case "disableNativeTabBar":
            disableNativeTabBar()
            result(nil)

        case "setOverlayHidden":
            let args = call.arguments as? [String: Any]
            let hidden = (args?["hidden"] as? Bool) ?? false
            let animated = (args?["animated"] as? Bool) ?? true
            let durationMs = (args?["durationMs"] as? Int) ?? 240
            let delayMs = (args?["delayMs"] as? Int) ?? 0
            setOverlayHidden(hidden, animated: animated, durationMs: durationMs, delayMs: delayMs)
            result(nil)

        case "setOverlayModalDimmed":
            let args = call.arguments as? [String: Any]
            let dimmed = (args?["dimmed"] as? Bool) ?? false
            let opacity = (args?["opacity"] as? Double) ?? 0.32
            let animated = (args?["animated"] as? Bool) ?? true
            let durationMs = (args?["durationMs"] as? Int) ?? 240
            setOverlayModalDimmed(
                dimmed, opacity: CGFloat(opacity), animated: animated, durationMs: durationMs)
            result(nil)

        case "setSelectedIndex":
            guard let args = call.arguments as? [String: Any],
                let index = args["index"] as? Int
            else {
                result(FlutterError(code: "invalid_args", message: "Invalid index", details: nil))
                return
            }
            tabBarController?.selectedIndex = index
            notifyTabSelected(index)
            result(nil)

        case "showSearch":
            searchController?.isActive = true
            result(nil)

        case "hideSearch":
            searchController?.isActive = false
            result(nil)

        case "isEnabled":
            result(isEnabled)

        case "setBadgeCounts":
            guard let args = call.arguments as? [String: Any],
                let badgeCounts = args["badgeCounts"] as? [Int?]
            else {
                result(
                    FlutterError(
                        code: "invalid_args", message: "Invalid badge counts", details: nil))
                return
            }

            if let tabBar = tabBarController, let viewControllers = tabBar.viewControllers {
                for (index, viewController) in viewControllers.enumerated() {
                    if index < badgeCounts.count {
                        let count = badgeCounts[index]
                        if let count = count, count > 0 {
                            viewController.tabBarItem.badgeValue =
                                count > 99 ? "99+" : String(count)
                        } else {
                            viewController.tabBarItem.badgeValue = nil
                        }
                    }
                }
            }
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private static func colorFromARGB(_ argb: Int) -> UIColor {
        let a = CGFloat((argb >> 24) & 0xFF) / 255.0
        let r = CGFloat((argb >> 16) & 0xFF) / 255.0
        let g = CGFloat((argb >> 8) & 0xFF) / 255.0
        let b = CGFloat(argb & 0xFF) / 255.0
        return UIColor(red: r, green: g, blue: b, alpha: a)
    }
}

// MARK: - Passthrough overlay

/// Full-screen sibling above Flutter. Only intercepts hits on the native
/// tab bar pill and active search chrome; all other touches pass through
/// to Flutter (e.g. header buttons at the top of the screen).
@available(iOS 26.0, *)
private class PassThroughOverlayView: UIView {
    weak var tabBarController: UITabBarController?
    weak var searchController: UISearchController?
    var searchTabIndex: Int = -1
    var isSearchMorphActive: Bool = false

    private let modalDimScrim = UIView()
    private(set) var isModalDimmed = false
    private var modalDimOpacity: CGFloat = 0.32

    override init(frame: CGRect) {
        super.init(frame: frame)
        modalDimScrim.isHidden = true
        modalDimScrim.alpha = 0
        modalDimScrim.isUserInteractionEnabled = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setModalDimmed(_ dimmed: Bool, opacity: CGFloat, animated: Bool, durationMs: Int) {
        isModalDimmed = dimmed
        modalDimOpacity = opacity
        modalDimScrim.backgroundColor = UIColor.black.withAlphaComponent(opacity)

        guard let tabBar = tabBarController?.tabBar else { return }

        tabBar.isUserInteractionEnabled = !dimmed

        if dimmed {
            if modalDimScrim.superview !== tabBar {
                modalDimScrim.removeFromSuperview()
                tabBar.addSubview(modalDimScrim)
            }
            modalDimScrim.frame = tabBar.bounds
            modalDimScrim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            modalDimScrim.isHidden = false
        }

        let duration = max(0, Double(durationMs)) / 1000.0
        UIView.animate(
            withDuration: animated ? duration : 0,
            delay: 0,
            options: [.curveEaseOut, .beginFromCurrentState]
        ) {
            self.modalDimScrim.alpha = dimmed ? 1 : 0
        } completion: { _ in
            if !dimmed {
                self.modalDimScrim.isHidden = true
                self.modalDimScrim.removeFromSuperview()
                self.isModalDimmed = false
                tabBar.isUserInteractionEnabled = true
            }
        }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if isModalDimmed {
            return nil
        }

        guard bounds.contains(point), let tabBarController else { return nil }
        let tabBar = tabBarController.tabBar
        let searchBar = searchController?.searchBar

        // 0. UIKit's default subview walk — often finds morphed search
        //    chrome before our manual scans do.
        if let hit = super.hitTest(point, with: event), hit !== self,
            isInteractiveChrome(hit, tabBar: tabBar, searchBar: searchBar)
        {
            return hit
        }

        // 1. Standard tab bar hit test (browse mode + morphed field
        //    children that UIKit keeps inside the bar).
        if let hit = hitTestView(tabBar, at: point, with: event),
            isInteractiveChrome(hit, tabBar: tabBar, searchBar: searchBar)
        {
            return hit
        }

        // 2. Direct search-bar hit test — iOS 26 morph reparents the
        //    bar while `isActive` is still false (keyboard not raised).
        if let searchBar,
            let hit = hitTestView(searchBar, at: point, with: event),
            isInteractiveChrome(hit, tabBar: tabBar, searchBar: searchBar)
        {
            return hit
        }

        // 3. Pre-keyboard morph: chrome is visible but not yet active.
        //    Scan the full bottom band + Flutter-root siblings.
        if isSearchChromeVisible {
            if let hit = hitTestSearchChrome(at: point, with: event, in: tabBarController) {
                return hit
            }
            if let hit = hitTestSearchMorphSiblings(at: point, with: event, tabBar: tabBar) {
                return hit
            }
            if let hit = hitTestFlutterRootChrome(at: point, with: event, tabBar: tabBar) {
                return hit
            }
        }

        return nil
    }

    /// True while search UI is on screen — includes the pre-keyboard
    /// morph window where `isActive` is still false.
    private var isSearchChromeVisible: Bool {
        isSearchMorphActive
            || searchController?.isActive == true
            || isSearchTabSelected
    }

    private var isSearchTabSelected: Bool {
        guard searchTabIndex >= 0, let tabBarController else { return false }
        return tabBarController.selectedIndex == searchTabIndex
    }

    private func hitTestView(_ view: UIView, at point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !view.isHidden, view.alpha > 0.01, view.isUserInteractionEnabled else { return nil }
        let local = convert(point, to: view)
        guard view.point(inside: local, with: event) else { return nil }
        return view.hitTest(local, with: event)
    }

    /// Hit-test the tab-bar controller subtree for search / tab chrome,
    /// rejecting full-screen transparent tab cells so Flutter keeps
    /// receiving grid scrolls and taps outside the chrome.
    private func hitTestSearchChrome(
        at point: CGPoint, with event: UIEvent?, in tabBarController: UITabBarController
    ) -> UIView? {
        let pointInRoot = convert(point, to: tabBarController.view)
        guard tabBarController.view.point(inside: pointInRoot, with: event),
            let hit = tabBarController.view.hitTest(pointInRoot, with: event)
        else { return nil }

        if isInteractiveChrome(hit, tabBar: tabBarController.tabBar, searchBar: searchController?.searchBar) {
            return hit
        }
        return nil
    }

    private func isInteractiveChrome(
        _ view: UIView, tabBar: UITabBar, searchBar: UISearchBar?
    ) -> Bool {
        var current: UIView? = view
        while let v = current {
            if v is ChromePassthroughView { return false }
            if v is UITabBar || v is UISearchBar { return true }
            if v is UIControl || v is UITextField { return true }
            if v.isDescendant(of: tabBar) { return true }
            if let searchBar, v.isDescendant(of: searchBar) { return true }
            let name = String(describing: type(of: v))
            if name.contains("Search") || name.contains("TabBar") || name.contains("BarButton") {
                return true
            }
            current = v.superview
        }
        return false
    }

    /// iOS 26 can mount morphed search controls as siblings of this
    /// overlay on the Flutter root view rather than inside the tab bar
    /// controller hierarchy.
    private func hitTestSearchMorphSiblings(
        at point: CGPoint, with event: UIEvent?, tabBar: UITabBar
    ) -> UIView? {
        guard let superview else { return nil }
        for sibling in superview.subviews.reversed() where sibling !== self {
            let pointInSibling = convert(point, to: sibling)
            guard sibling.point(inside: pointInSibling, with: event),
                let hit = sibling.hitTest(pointInSibling, with: event)
            else { continue }
            if isInteractiveChrome(hit, tabBar: tabBar, searchBar: searchController?.searchBar) {
                return hit
            }
        }
        return nil
    }

    /// Last-resort scan of every Flutter-root subview (including this
    /// overlay) for morphed search chrome UIKit mounts above Flutter.
    private func hitTestFlutterRootChrome(
        at point: CGPoint, with event: UIEvent?, tabBar: UITabBar
    ) -> UIView? {
        guard let root = superview else { return nil }
        guard bottomChromeBand.contains(point) else { return nil }

        for subview in root.subviews.reversed() where subview !== self {
            let pointInSubview = convert(point, to: subview)
            guard subview.point(inside: pointInSubview, with: event),
                let hit = subview.hitTest(pointInSubview, with: event)
            else { continue }
            if isInteractiveChrome(hit, tabBar: tabBar, searchBar: searchController?.searchBar) {
                return hit
            }
        }
        return nil
    }

    /// Bottom band covering the floating tab pill, morphed search field,
    /// and separated search circle — used for pre-keyboard morph hits.
    private var bottomChromeBand: CGRect {
        guard let tabBarController else { return .zero }
        let tabBar = tabBarController.tabBar
        var band = convert(tabBar.bounds, from: tabBar)
        // Morph expands upward from the pill before the keyboard shows.
        band = band.union(
            CGRect(
                x: 0,
                y: max(0, band.minY - 100),
                width: bounds.width,
                height: band.height + 100
            )
        )
        if let searchBar = searchController?.searchBar, searchBar.window != nil {
            let searchFrame = convert(searchBar.bounds, from: searchBar)
            if searchFrame.width > 1, searchFrame.height > 1 {
                band = band.union(searchFrame)
            }
        }
        return band
    }
}

/// Transparent full-screen view that only intercepts touches landing on
/// actual subviews — keeps Flutter scroll/tap working everywhere else.
@available(iOS 26.0, *)
private class ChromePassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, alpha >= 0.01, isUserInteractionEnabled else { return nil }
        for subview in subviews.reversed() {
            let converted = subview.convert(point, from: self)
            if let hit = subview.hitTest(converted, with: event) {
                return hit
            }
        }
        return nil
    }
}

// MARK: - Overlay tab bar controller

/// Transparent full-screen overlay; tabBar chrome sits above stub tab cells.
@available(iOS 26.0, *)
private class OverlayTabBarController: UITabBarController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        // Disable iOS 26's scroll-driven tab bar minimize behavior — when
        // the route push triggers a layout pass, the system can briefly
        // collapse the floating pill into its compact form, making the
        // icons visibly jump up before our slide-out animation begins.
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior = .never
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        elevateTabBarChrome()
    }

    func elevateTabBarChrome() {
        view.bringSubviewToFront(tabBar)
    }
}

// MARK: - UITabBarControllerDelegate

@available(iOS 26.0, *)
extension iOS26NativeTabBarManager: UITabBarControllerDelegate {
    func tabBarController(
        _ tabBarController: UITabBarController,
        shouldSelect viewController: UIViewController
    ) -> Bool {
        let index = tabBarController.viewControllers?.firstIndex(of: viewController) ?? 0
        if index == searchTabIndex, tabBarController.selectedIndex != searchTabIndex {
            browseIndexBeforeSearch = tabBarController.selectedIndex
            // Morph begins on shouldSelect — flip hit-testing before
            // `isActive`/keyboard so the field and X are tappable
            // immediately.
            notifySearchActivated()
        }
        return true
    }

    func tabBarController(
        _ tabBarController: UITabBarController, didSelect viewController: UIViewController
    ) {
        let index = tabBarController.viewControllers?.firstIndex(of: viewController) ?? 0
        notifyTabSelected(index)
        if index == searchTabIndex {
            notifySearchActivated()
            // iOS 26's `.search` system item morph does not always flip
            // `isActive` on its own — without this, hit-testing and
            // `didDismissSearchController` never fire when the field is
            // empty and the user backs out via the morph chevron.
            if searchController?.isActive != true {
                searchController?.isActive = true
            }
            hideSearchDismissChrome()
            DispatchQueue.main.async { [weak self] in
                self?.elevateSearchChrome()
                self?.hideSearchDismissChrome()
            }
        } else {
            browseIndexBeforeSearch = index
            searchController?.isActive = false
            notifySearchDeactivated()
        }
        (tabBarController as? OverlayTabBarController)?.elevateTabBarChrome()
    }

    /// Re-layer search chrome above the transparent tab cells after
    /// the iOS 26 morph mounts new views.
    private func elevateSearchChrome() {
        guard let tabBarVC = tabBarController else { return }
        tabBarVC.elevateTabBarChrome()
        if let searchBar = searchController?.searchBar,
            let host = searchBar.superview
        {
            host.bringSubviewToFront(searchBar)
        }
    }

    /// Hide the morph's leading dismiss / cancel control. iOS 26 adds
    /// this outside the standard `showsCancelButton` path; users exit
    /// search by selecting another tab instead.
    private func hideSearchDismissChrome() {
        guard let searchController else { return }
        searchController.automaticallyShowsCancelButton = false
        searchController.searchBar.setShowsCancelButton(false, animated: false)

        let roots = [searchController.searchBar as UIView]
            + (searchController.searchBar.superview.map { [$0] } ?? [])
            + (tabBarController?.tabBar.subviews ?? [])
        for root in roots {
            hideDismissControls(in: root)
        }
    }

    private func hideDismissControls(in view: UIView) {
        if let searchBar = searchController?.searchBar,
            view.isDescendant(of: searchBar.searchTextField)
        {
            return
        }

        let typeName = String(describing: type(of: view))
        if typeName.contains("Dismiss")
            || typeName.contains("Cancel")
            || typeName.contains("BackButton")
        {
            view.isHidden = true
            view.isUserInteractionEnabled = false
            return
        }

        // iOS 26 morph leading X — a button sitting left of the field.
        if let button = view as? UIButton, let searchBar = searchController?.searchBar {
            let frameInBar = searchBar.convert(button.bounds, from: button)
            if frameInBar.maxX <= searchBar.searchTextField.frame.minX + 4 {
                button.isHidden = true
                button.isUserInteractionEnabled = false
                return
            }
        }

        for subview in view.subviews {
            hideDismissControls(in: subview)
        }
    }
}

// MARK: - UISearchControllerDelegate

@available(iOS 26.0, *)
extension iOS26NativeTabBarManager: UISearchControllerDelegate {
    func willPresentSearchController(_ searchController: UISearchController) {
        searchController.automaticallyShowsCancelButton = false
        searchController.searchBar.setShowsCancelButton(false, animated: false)
        notifySearchActivated()
        DispatchQueue.main.async { [weak self] in
            self?.elevateSearchChrome()
            self?.hideSearchDismissChrome()
        }
    }

    func didDismissSearchController(_ searchController: UISearchController) {
        notifySearchDeactivated()
        // Morph back can collapse search without changing selectedIndex
        // away from the search destination — restore the browse tab so
        // describe-bar visibility and hit-testing state reset correctly.
        if tabBarController?.selectedIndex == searchTabIndex {
            tabBarController?.selectedIndex = browseIndexBeforeSearch
        }
    }
}

// MARK: - UISearchResultsUpdating

@available(iOS 26.0, *)
extension iOS26NativeTabBarManager: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        guard let query = searchController.searchBar.text else { return }
        notifySearchQueryChanged(query)
    }
}

// MARK: - UISearchBarDelegate

@available(iOS 26.0, *)
extension iOS26NativeTabBarManager: UISearchBarDelegate {
    func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {
        searchBar.setShowsCancelButton(false, animated: false)
        hideSearchDismissChrome()
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        guard let query = searchBar.text else { return }
        notifySearchSubmitted(query)
    }

    func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        searchController?.isActive = false
        methodChannel?.invokeMethod("onSearchCancelled", arguments: nil)
        notifySearchDeactivated()
    }
}

// MARK: - Tab View Controllers

@available(iOS 26.0, *)
private class EmptyTabVC: UIViewController {
    var tabIndex: Int = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
    }
}

@available(iOS 26.0, *)
private class SearchTabViewController: UIViewController {
    var tabIndex: Int = 0

    override func loadView() {
        view = ChromePassthroughView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }
}
