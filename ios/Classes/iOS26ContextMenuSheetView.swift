import Flutter
import UIKit

/// Platform view that renders a native iOS 26 glass "menu sheet": a
/// `UIVisualEffectView` (Liquid Glass on iOS 26, material fallback) panel of
/// tappable action rows separated by hairlines.
///
/// This is a native *reimplementation* of a context-menu options list — iOS
/// has no public API to present the real system `UIMenu` programmatically, so
/// when a Flutter-driven lift route needs native-looking options, it embeds
/// this view. Selections are reported back over the method channel as
/// `itemSelected` with the row index.
class iOS26ContextMenuSheetView: NSObject, FlutterPlatformView {
    private let channel: FlutterMethodChannel
    private let container: RoundedEffectContainer
    private var labels: [String] = []
    private var symbols: [String] = []
    private var destructive: [Bool] = []
    private var enabled: [Bool] = []

    // The glass effect is applied on appear (materialize), not at creation, so
    // it fades in with the system's Liquid Glass animation rather than popping.
    // Flutter opacity can't animate a platform view, so we drive it here.
    private weak var effectView: UIVisualEffectView?
    private var pendingEffect: UIVisualEffect?
    private var didMaterialize = false

    init(frame: CGRect, viewId: Int64, args: Any?, messenger: FlutterBinaryMessenger) {
        self.channel = FlutterMethodChannel(
            name: "adaptive_platform_ui/ios26_context_menu_sheet_\(viewId)",
            binaryMessenger: messenger
        )
        self.container = RoundedEffectContainer(frame: frame)

        var isDark = false
        if let dict = args as? [String: Any] {
            labels = (dict["labels"] as? [String]) ?? []
            symbols = (dict["sfSymbols"] as? [String]) ?? []
            destructive = ((dict["isDestructive"] as? [NSNumber]) ?? []).map { $0.boolValue }
            enabled = ((dict["enabled"] as? [NSNumber]) ?? []).map { $0.boolValue }
            if let v = dict["isDark"] as? NSNumber { isDark = v.boolValue }
        }

        super.init()

        if #available(iOS 13.0, *) {
            container.overrideUserInterfaceStyle = isDark ? .dark : .light
        }
        buildSheet()
    }

    func view() -> UIView { container }

    /// Animate the Liquid Glass in. Per Apple's guidance, materialize by
    /// animating the `effect` property (not alpha) so the system runs its
    /// proper glass fade-in; fade the content alpha alongside it.
    private func materialize() {
        guard !didMaterialize, let ev = effectView, let effect = pendingEffect else {
            return
        }
        didMaterialize = true
        UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseOut) {
            ev.effect = effect
            ev.contentView.alpha = 1
        }
    }

    private func buildSheet() {
        let effect: UIVisualEffect
        if #available(iOS 26.0, *) {
            effect = UIGlassEffect()
        } else {
            effect = UIBlurEffect(style: .systemThinMaterial)
        }
        // Start with no effect + hidden content; materialize on first layout.
        pendingEffect = effect
        let effectView = UIVisualEffectView(effect: nil)
        effectView.contentView.alpha = 0
        effectView.translatesAutoresizingMaskIntoConstraints = false
        effectView.clipsToBounds = true
        container.effectView = effectView
        self.effectView = effectView
        container.onFirstLayout = { [weak self] in self?.materialize() }
        container.addSubview(effectView)
        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            effectView.topAnchor.constraint(equalTo: container.topAnchor),
            effectView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .fill
        stack.distribution = .fill
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        effectView.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effectView.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effectView.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effectView.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effectView.contentView.bottomAnchor),
        ])

        for i in 0..<labels.count {
            if i > 0 {
                let sep = UIView()
                sep.translatesAutoresizingMaskIntoConstraints = false
                sep.backgroundColor = UIColor.separator.withAlphaComponent(0.5)
                sep.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale).isActive = true
                stack.addArrangedSubview(sep)
            }
            stack.addArrangedSubview(makeButton(index: i))
        }
    }

    private func makeButton(index i: Int) -> UIButton {
        let isDestructive = i < destructive.count ? destructive[i] : false
        let isEnabled = i < enabled.count ? enabled[i] : true
        let tint: UIColor = isDestructive ? .systemRed : .label

        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isEnabled = isEnabled
        button.tag = i
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        button.contentHorizontalAlignment = .fill

        if #available(iOS 15.0, *) {
            var config = UIButton.Configuration.plain()
            config.title = i < labels.count ? labels[i] : ""
            config.baseForegroundColor = tint
            config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
            if i < symbols.count, !symbols[i].isEmpty {
                config.image = UIImage(systemName: symbols[i])
                config.imagePlacement = .trailing
                config.imagePadding = 8
            }
            config.titleAlignment = .leading
            button.configuration = config
            button.contentHorizontalAlignment = .leading
            // Keep the title pinned leading and the symbol trailing.
            button.configurationUpdateHandler = { btn in
                btn.contentHorizontalAlignment = .leading
            }
        } else {
            button.setTitle(i < labels.count ? labels[i] : "", for: .normal)
            button.setTitleColor(tint, for: .normal)
            button.contentHorizontalAlignment = .left
            button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        }

        button.addTarget(self, action: #selector(onTap(_:)), for: .touchUpInside)
        return button
    }

    @objc private func onTap(_ sender: UIButton) {
        channel.invokeMethod("itemSelected", arguments: ["index": sender.tag])
    }
}

/// Container that keeps the glass panel's continuous corner radius in sync
/// with whatever frame Flutter assigns.
private class RoundedEffectContainer: UIView {
    weak var effectView: UIVisualEffectView?
    var cornerRadius: CGFloat = 13
    var onFirstLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = cornerRadius
        layer.cornerCurve = .continuous
        effectView?.layer.cornerRadius = cornerRadius
        effectView?.layer.cornerCurve = .continuous

        if bounds.width > 0, let cb = onFirstLayout {
            onFirstLayout = nil
            cb()
        }
    }
}

/// Factory for creating `iOS26ContextMenuSheetView` instances.
class iOS26ContextMenuSheetViewFactory: NSObject, FlutterPlatformViewFactory {
    private let messenger: FlutterBinaryMessenger

    init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
        super.init()
    }

    func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
        return iOS26ContextMenuSheetView(frame: frame, viewId: viewId, args: args, messenger: messenger)
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        return FlutterStandardMessageCodec.sharedInstance()
    }
}
