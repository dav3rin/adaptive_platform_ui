import Flutter
import UIKit

/// Factory for creating iOS 26 native segmented control platform views
class iOS26SegmentedControlViewFactory: NSObject, FlutterPlatformViewFactory {
    private var messenger: FlutterBinaryMessenger

    init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
        super.init()
    }

    func create(
        withFrame frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?
    ) -> FlutterPlatformView {
        return iOS26SegmentedControlView(
            frame: frame,
            viewIdentifier: viewId,
            arguments: args,
            binaryMessenger: messenger
        )
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        return FlutterStandardMessageCodec.sharedInstance()
    }
}

/// Container view that fires a callback on every layout pass
private class LayoutAwareView: UIView {
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

/// Segmented control that supports both system (Liquid Glass) and custom styling
class iOS26SegmentedControlView: NSObject, FlutterPlatformView {
    private var _view: LayoutAwareView
    private var channel: FlutterMethodChannel
    private var controlId: Int
    private var useCustomStyle: Bool = false

    // System control
    private var segmentedControl: UISegmentedControl?

    // Custom control
    private var thumbView: UIView?
    private var segmentButtons: [UIButton] = []
    private var segmentStackView: UIStackView?
    private var currentSelectedIndex: Int = 0
    private var numberOfSegments: Int = 0
    private var isControlEnabled: Bool = true
    private var selectedTextColor: UIColor = .white
    private var unselectedTextColor: UIColor = UIColor(white: 0.55, alpha: 1.0)

    init(
        frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?,
        binaryMessenger messenger: FlutterBinaryMessenger
    ) {
        _view = LayoutAwareView(frame: frame)

        if let config = args as? [String: Any] {
            controlId = config["id"] as? Int ?? 0
            useCustomStyle = config["useCustomStyle"] as? Bool ?? false
        } else {
            controlId = 0
        }

        channel = FlutterMethodChannel(
            name: "adaptive_platform_ui/ios26_segmented_control_\(controlId)",
            binaryMessenger: messenger
        )

        super.init()

        if useCustomStyle {
            createCustomControl(with: args)
            _view.onLayout = { [weak self] in
                self?.updateThumbPosition(animated: false)
            }
        } else {
            createSystemControl(with: args)
        }

        channel.setMethodCallHandler { [weak self] (call, result) in
            self?.handleMethodCall(call, result: result)
        }
    }

    func view() -> UIView {
        return _view
    }

    // MARK: - System UISegmentedControl (default / Liquid Glass)

    private func createSystemControl(with args: Any?) {
        let control = UISegmentedControl()
        control.translatesAutoresizingMaskIntoConstraints = false
        control.isUserInteractionEnabled = true
        _view.isUserInteractionEnabled = true

        if let config = args as? [String: Any] {
            if let sfSymbols = config["sfSymbols"] as? [String], !sfSymbols.isEmpty {
                for (index, symbolName) in sfSymbols.enumerated() {
                    if let image = UIImage(systemName: symbolName) {
                        control.insertSegment(with: image, at: index, animated: false)
                    } else {
                        print("⚠️ SF Symbol not found: \(symbolName)")
                    }
                }
                if let iconSizeNumber = config["iconSize"] as? NSNumber {
                    let iconSize = CGFloat(iconSizeNumber.doubleValue)
                    let configuration = UIImage.SymbolConfiguration(pointSize: iconSize)
                    for i in 0..<control.numberOfSegments {
                        if let image = control.imageForSegment(at: i) {
                            control.setImage(image.withConfiguration(configuration), forSegmentAt: i)
                        }
                    }
                }
                if let iconColorValue = config["iconColor"] as? Int {
                    let iconColor = colorFromARGB(iconColorValue)
                    control.setTitleTextAttributes([.foregroundColor: iconColor], for: .normal)
                }
            } else if let labels = config["labels"] as? [String] {
                for (index, label) in labels.enumerated() {
                    control.insertSegment(withTitle: label, at: index, animated: false)
                }
            }

            if let enabled = config["enabled"] as? Bool {
                control.isEnabled = enabled
            }
            if let tintColorValue = config["tintColor"] as? Int {
                control.selectedSegmentTintColor = colorFromARGB(tintColorValue)
            }
            if let selectedIndex = config["selectedIndex"] as? Int, selectedIndex >= 0 {
                control.selectedSegmentIndex = selectedIndex
            }
            if let isDark = config["isDark"] as? Bool {
                if #available(iOS 13.0, *) {
                    _view.overrideUserInterfaceStyle = isDark ? .dark : .light
                }
            }
        }

        segmentedControl = control
        _view.addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: _view.leadingAnchor),
            control.trailingAnchor.constraint(equalTo: _view.trailingAnchor),
            control.topAnchor.constraint(equalTo: _view.topAnchor),
            control.bottomAnchor.constraint(equalTo: _view.bottomAnchor),
        ])

        control.addTarget(self, action: #selector(systemSegmentChanged), for: .valueChanged)
    }

    @objc private func systemSegmentChanged() {
        guard let control = segmentedControl else { return }
        channel.invokeMethod("valueChanged", arguments: ["index": control.selectedSegmentIndex])
        let impact = UIImpactFeedbackGenerator(style: .light)
        impact.impactOccurred()
    }

    // MARK: - Custom control (no Liquid Glass)

    private func createCustomControl(with args: Any?) {
        _view.isUserInteractionEnabled = true

        var segmentPadding: CGFloat = 0
        var labels: [String] = []
        var sfSymbols: [String] = []
        var selectedIndex = 0
        var tintColor = UIColor(white: 0.3, alpha: 1.0)
        var bgColor = UIColor.clear
        var outlineColor: UIColor?
        var viewHeight: CGFloat = 36
        var iconSize: CGFloat = 20
        var iconColor: UIColor?

        if let config = args as? [String: Any] {
            if let l = config["labels"] as? [String] { labels = l }
            if let s = config["sfSymbols"] as? [String], !s.isEmpty { sfSymbols = s }
            if let si = config["selectedIndex"] as? Int, si >= 0 { selectedIndex = si }
            if let e = config["enabled"] as? Bool { isControlEnabled = e }
            if let tc = config["tintColor"] as? Int { tintColor = colorFromARGB(tc) }
            if let bc = config["backgroundColor"] as? Int { bgColor = colorFromARGB(bc) }
            if let oc = config["outlineColor"] as? Int { outlineColor = colorFromARGB(oc) }
            if let p = config["segmentPadding"] as? NSNumber { segmentPadding = CGFloat(p.doubleValue) }
            if let h = config["viewHeight"] as? NSNumber { viewHeight = CGFloat(h.doubleValue) }
            if let s = config["iconSize"] as? NSNumber { iconSize = CGFloat(s.doubleValue) }
            if let ic = config["iconColor"] as? Int { iconColor = colorFromARGB(ic) }
            if let stc = config["selectedTextColor"] as? Int { selectedTextColor = colorFromARGB(stc) }
            if let utc = config["unselectedTextColor"] as? Int { unselectedTextColor = colorFromARGB(utc) }

            if let isDark = config["isDark"] as? Bool {
                if #available(iOS 13.0, *) {
                    _view.overrideUserInterfaceStyle = isDark ? .dark : .light
                }
            }
        }

        let useSfSymbols = !sfSymbols.isEmpty
        numberOfSegments = useSfSymbols ? sfSymbols.count : labels.count
        guard numberOfSegments > 0 else { return }
        currentSelectedIndex = min(max(selectedIndex, 0), numberOfSegments - 1)

        // Container
        _view.backgroundColor = bgColor
        _view.layer.cornerRadius = viewHeight / 2.0
        _view.clipsToBounds = true

        // Thumb
        let thumbHeight = viewHeight - segmentPadding * 2
        let thumb = UIView()
        thumb.backgroundColor = tintColor
        thumb.layer.cornerRadius = thumbHeight / 2.0
        thumb.isUserInteractionEnabled = false
        if let outlineColor = outlineColor {
            thumb.layer.borderColor = outlineColor.cgColor
            thumb.layer.borderWidth = 1.0
        }
        thumbView = thumb
        _view.addSubview(thumb)

        // Segment buttons
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false

        for i in 0..<numberOfSegments {
            let button = UIButton(type: .custom)
            button.tag = i
            button.isEnabled = isControlEnabled
            button.addTarget(self, action: #selector(customSegmentTapped(_:)), for: .touchUpInside)

            if useSfSymbols {
                let symbolName = sfSymbols[i]
                if let image = UIImage(systemName: symbolName) {
                    let config = UIImage.SymbolConfiguration(pointSize: iconSize)
                    button.setImage(image.withConfiguration(config), for: .normal)
                    button.tintColor = iconColor ?? .white
                }
            } else {
                button.setTitle(labels[i], for: .normal)
                button.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
            }

            stack.addArrangedSubview(button)
            segmentButtons.append(button)
        }

        segmentStackView = stack
        _view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: _view.leadingAnchor, constant: segmentPadding),
            stack.trailingAnchor.constraint(equalTo: _view.trailingAnchor, constant: -segmentPadding),
            stack.topAnchor.constraint(equalTo: _view.topAnchor, constant: segmentPadding),
            stack.bottomAnchor.constraint(equalTo: _view.bottomAnchor, constant: -segmentPadding),
        ])

        updateCustomTextColors()
    }

    private func updateThumbPosition(animated: Bool) {
        guard let thumb = thumbView,
              let stack = segmentStackView,
              numberOfSegments > 0,
              currentSelectedIndex >= 0,
              currentSelectedIndex < numberOfSegments else { return }

        let stackFrame = stack.frame
        guard stackFrame.width > 0 else { return }

        let segWidth = stackFrame.width / CGFloat(numberOfSegments)
        let thumbFrame = CGRect(
            x: stackFrame.origin.x + CGFloat(currentSelectedIndex) * segWidth,
            y: stackFrame.origin.y,
            width: segWidth,
            height: stackFrame.height
        )

        if animated {
            UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseInOut) {
                thumb.frame = thumbFrame
            }
        } else {
            thumb.frame = thumbFrame
        }
    }

    private func updateCustomTextColors() {
        for (i, button) in segmentButtons.enumerated() {
            button.setTitleColor(i == currentSelectedIndex ? selectedTextColor : unselectedTextColor, for: .normal)
        }
    }

    @objc private func customSegmentTapped(_ sender: UIButton) {
        let index = sender.tag
        guard index != currentSelectedIndex,
              index >= 0,
              index < numberOfSegments,
              isControlEnabled else { return }

        currentSelectedIndex = index
        updateThumbPosition(animated: true)
        updateCustomTextColors()

        channel.invokeMethod("valueChanged", arguments: ["index": index])

        let impact = UIImpactFeedbackGenerator(style: .light)
        impact.impactOccurred()
    }

    // MARK: - Shared

    private func colorFromARGB(_ argb: Int) -> UIColor {
        let a = CGFloat((argb >> 24) & 0xFF) / 255.0
        let r = CGFloat((argb >> 16) & 0xFF) / 255.0
        let g = CGFloat((argb >> 8) & 0xFF) / 255.0
        let b = CGFloat(argb & 0xFF) / 255.0
        return UIColor(red: r, green: g, blue: b, alpha: a)
    }

    private func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "setSelectedIndex":
            if let args = call.arguments as? [String: Any],
               let index = args["index"] as? Int {
                if useCustomStyle {
                    if index >= 0 && index < numberOfSegments {
                        currentSelectedIndex = index
                        updateThumbPosition(animated: true)
                        updateCustomTextColors()
                    }
                } else if let control = segmentedControl {
                    if index >= 0 && index < control.numberOfSegments {
                        control.selectedSegmentIndex = index
                    } else if index == -1 {
                        control.selectedSegmentIndex = UISegmentedControl.noSegment
                    }
                }
            }
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
