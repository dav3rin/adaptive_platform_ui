import Flutter
import UIKit

/// Factory for creating iOS 26 native glass input bar platform views.
///
/// The glass input bar is a pill-shaped, blurred capsule with a
/// leading SF symbol button (e.g. `plus`) and an inline `UITextField`.
/// On iOS 26+ the backing visual effect is `UIGlassEffect` (real
/// Liquid Glass — system blur + dynamic tint + refraction). On older
/// iOS versions it falls back to `UIBlurEffect(style: .systemUltraThinMaterial)`.
class iOS26GlassInputBarFactory: NSObject, FlutterPlatformViewFactory {
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
        return iOS26GlassInputBar(
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

/// Custom container that re-applies the pill corner radius on every
/// layout pass. Used as the root `view()` returned from the platform
/// view so the radius tracks whatever frame Flutter assigns.
fileprivate class GlassInputBarContainer: UIView {
    var configuredCornerRadius: CGFloat = 0
    weak var effectView: UIVisualEffectView?

    override func layoutSubviews() {
        super.layoutSubviews()
        let radius = configuredCornerRadius > 0
            ? configuredCornerRadius
            : bounds.height / 2
        layer.cornerRadius = radius
        layer.cornerCurve = .continuous
        effectView?.layer.cornerRadius = radius
        effectView?.layer.cornerCurve = .continuous
    }
}

/// Native iOS 26 glass input bar implementation.
///
/// Layout:
///   [ (+)  Describe anything... ]    <- pill, ~52pt tall, full width
///
/// Method channel API (`adaptive_platform_ui/ios26_glass_input_bar_<id>`):
///
/// Calls from Flutter -> native:
///   - `focus`           : { } -> begins editing
///   - `blur`            : { } -> ends editing
///   - `setText`         : { text: String } -> programmatic text update
///   - `setPlaceholder`  : { placeholder: String }
///
/// Calls from native -> Flutter:
///   - `onTextChanged`   : { text: String }
///   - `onSubmit`        : { text: String }
///   - `onPlusTapped`    : { }
///   - `onFocusChanged`  : { focused: Bool }
class iOS26GlassInputBar: NSObject, FlutterPlatformView, UITextFieldDelegate {
    private let container: GlassInputBarContainer
    private var blurView: UIVisualEffectView!
    private var leadingButton: UIButton?
    private var trailingButton: UIButton?
    private var textField: UITextField!
    private var channel: FlutterMethodChannel

    private var placeholder: String = "Describe anything"
    private var leadingSymbol: String? = "plus"
    private var trailingSymbol: String?
    private var cornerRadius: CGFloat = 0
    private var textColor: UIColor = .white
    private var placeholderColor: UIColor = UIColor.white.withAlphaComponent(0.5)
    private var iconColor: UIColor = UIColor.white.withAlphaComponent(0.85)

    init(
        frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?,
        binaryMessenger messenger: FlutterBinaryMessenger
    ) {
        container = GlassInputBarContainer(frame: frame)

        if let config = args as? [String: Any] {
            if let p = config["placeholder"] as? String { placeholder = p }
            // leadingSymbol: nil/empty string suppresses the leading button entirely.
            if config.keys.contains("leadingSymbol") {
                if let s = config["leadingSymbol"] as? String, !s.isEmpty {
                    leadingSymbol = s
                } else {
                    leadingSymbol = nil
                }
            }
            if let s = config["trailingSymbol"] as? String, !s.isEmpty {
                trailingSymbol = s
            }
            if let r = config["cornerRadius"] as? Double {
                cornerRadius = CGFloat(r)
            }
            if let argb = config["textColor"] as? Int {
                textColor = UIColor(argb: argb)
            }
            if let argb = config["placeholderColor"] as? Int {
                placeholderColor = UIColor(argb: argb)
            }
            if let argb = config["iconColor"] as? Int {
                iconColor = UIColor(argb: argb)
            }
        }

        container.configuredCornerRadius = cornerRadius

        channel = FlutterMethodChannel(
            name: "adaptive_platform_ui/ios26_glass_input_bar_\(viewId)",
            binaryMessenger: messenger
        )

        super.init()

        buildHierarchy()

        channel.setMethodCallHandler { [weak self] (call, result) in
            self?.handleMethodCall(call, result: result)
        }
    }

    func view() -> UIView { return container }

    // MARK: - Build

    private func buildHierarchy() {
        container.backgroundColor = .clear
        container.clipsToBounds = true

        // Background blur — Liquid Glass on iOS 26, frosted fallback elsewhere.
        let effect: UIVisualEffect
        if #available(iOS 26.0, *) {
            effect = UIGlassEffect()
        } else {
            effect = UIBlurEffect(style: .systemUltraThinMaterial)
        }
        blurView = UIVisualEffectView(effect: effect)
        blurView.translatesAutoresizingMaskIntoConstraints = false
        blurView.clipsToBounds = true
        container.addSubview(blurView)
        container.effectView = blurView

        let symbolConfig = UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)

        // Optional leading symbol button.
        if let leading = leadingSymbol {
            let btn = UIButton(type: .system)
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.tintColor = iconColor
            btn.setImage(UIImage(systemName: leading, withConfiguration: symbolConfig), for: .normal)
            btn.addTarget(self, action: #selector(leadingTapped), for: .touchUpInside)
            blurView.contentView.addSubview(btn)
            leadingButton = btn
        }

        // Optional trailing symbol button.
        if let trailing = trailingSymbol {
            let btn = UIButton(type: .system)
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.tintColor = iconColor
            btn.setImage(UIImage(systemName: trailing, withConfiguration: symbolConfig), for: .normal)
            btn.addTarget(self, action: #selector(trailingTapped), for: .touchUpInside)
            blurView.contentView.addSubview(btn)
            trailingButton = btn
        }

        // Inline text field.
        textField = UITextField()
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.delegate = self
        textField.backgroundColor = .clear
        textField.borderStyle = .none
        textField.textColor = textColor
        textField.tintColor = .systemBlue
        textField.autocorrectionType = .yes
        textField.autocapitalizationType = .sentences
        textField.returnKeyType = .send
        textField.font = UIFont.systemFont(ofSize: 16, weight: .regular)
        textField.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: placeholderColor,
                .font: UIFont.systemFont(ofSize: 16, weight: .regular)
            ]
        )
        textField.addTarget(self, action: #selector(textChanged), for: .editingChanged)
        textField.addTarget(self, action: #selector(focusBegan), for: .editingDidBegin)
        textField.addTarget(self, action: #selector(focusEnded), for: .editingDidEnd)
        blurView.contentView.addSubview(textField)

        var constraints: [NSLayoutConstraint] = [
            blurView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            blurView.topAnchor.constraint(equalTo: container.topAnchor),
            blurView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            textField.topAnchor.constraint(equalTo: blurView.contentView.topAnchor),
            textField.bottomAnchor.constraint(equalTo: blurView.contentView.bottomAnchor),
        ]

        if let leading = leadingButton {
            constraints += [
                leading.leadingAnchor.constraint(equalTo: blurView.contentView.leadingAnchor, constant: 12),
                leading.centerYAnchor.constraint(equalTo: blurView.contentView.centerYAnchor),
                leading.widthAnchor.constraint(equalToConstant: 30),
                leading.heightAnchor.constraint(equalToConstant: 30),
                textField.leadingAnchor.constraint(equalTo: leading.trailingAnchor, constant: 4),
            ]
        } else {
            constraints += [
                textField.leadingAnchor.constraint(equalTo: blurView.contentView.leadingAnchor, constant: 16),
            ]
        }

        if let trailing = trailingButton {
            constraints += [
                trailing.trailingAnchor.constraint(equalTo: blurView.contentView.trailingAnchor, constant: -12),
                trailing.centerYAnchor.constraint(equalTo: blurView.contentView.centerYAnchor),
                trailing.widthAnchor.constraint(equalToConstant: 30),
                trailing.heightAnchor.constraint(equalToConstant: 30),
                textField.trailingAnchor.constraint(equalTo: trailing.leadingAnchor, constant: -4),
            ]
        } else {
            constraints += [
                textField.trailingAnchor.constraint(equalTo: blurView.contentView.trailingAnchor, constant: -16),
            ]
        }

        NSLayoutConstraint.activate(constraints)
    }

    // MARK: - Actions

    @objc private func leadingTapped() {
        // Legacy name kept for the +-button case.
        channel.invokeMethod("onPlusTapped", arguments: nil)
        channel.invokeMethod("onLeadingTapped", arguments: nil)
    }

    @objc private func trailingTapped() {
        channel.invokeMethod("onTrailingTapped", arguments: nil)
    }

    @objc private func textChanged() {
        channel.invokeMethod("onTextChanged", arguments: ["text": textField.text ?? ""])
    }

    @objc private func focusBegan() {
        channel.invokeMethod("onFocusChanged", arguments: ["focused": true])
    }

    @objc private func focusEnded() {
        channel.invokeMethod("onFocusChanged", arguments: ["focused": false])
    }

    // MARK: - UITextFieldDelegate

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        channel.invokeMethod("onSubmit", arguments: ["text": textField.text ?? ""])
        textField.resignFirstResponder()
        return true
    }

    // MARK: - Method channel

    private func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "focus":
            textField.becomeFirstResponder()
            result(nil)
        case "blur":
            textField.resignFirstResponder()
            result(nil)
        case "setText":
            if let args = call.arguments as? [String: Any], let text = args["text"] as? String {
                textField.text = text
                result(nil)
            } else {
                result(FlutterError(code: "INVALID_ARGS", message: "Expected text", details: nil))
            }
        case "setPlaceholder":
            if let args = call.arguments as? [String: Any], let p = args["placeholder"] as? String {
                placeholder = p
                textField.attributedPlaceholder = NSAttributedString(
                    string: p,
                    attributes: [
                        .foregroundColor: placeholderColor,
                        .font: UIFont.systemFont(ofSize: 16, weight: .regular)
                    ]
                )
                result(nil)
            } else {
                result(FlutterError(code: "INVALID_ARGS", message: "Expected placeholder", details: nil))
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    deinit {
        channel.setMethodCallHandler(nil)
    }
}
