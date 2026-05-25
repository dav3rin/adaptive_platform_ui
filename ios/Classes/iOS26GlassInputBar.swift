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
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        let radius = configuredCornerRadius > 0
            ? configuredCornerRadius
            : bounds.height / 2
        layer.cornerRadius = radius
        layer.cornerCurve = .continuous
        effectView?.layer.cornerRadius = radius
        effectView?.layer.cornerCurve = .continuous
        onLayout?()
    }
}

/// Native iOS 26 glass input bar implementation.
///
/// Layout:
///   [ (+)  Describe anything... ]    <- pill, full width, grows from
///                                       single-line height up to
///                                       `maxLines` of text before
///                                       enabling internal scroll.
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
///   - `onHeightChanged` : { height: Double } -> emitted whenever the
///                                                content's intrinsic
///                                                height changes; the
///                                                Flutter side resizes
///                                                its `SizedBox`.
class iOS26GlassInputBar: NSObject, FlutterPlatformView, UITextViewDelegate {
    private let container: GlassInputBarContainer
    private var blurView: UIVisualEffectView!
    private var leadingButton: UIButton?
    private var trailingButton: UIButton?
    private var textView: UITextView!
    private var placeholderLabel: UILabel!
    private var channel: FlutterMethodChannel

    private var placeholder: String = "Describe anything"
    private var leadingSymbol: String? = "plus"
    private var trailingSymbol: String?
    private var cornerRadius: CGFloat = 0
    private var textColor: UIColor = .white
    private var placeholderColor: UIColor = UIColor.white.withAlphaComponent(0.5)
    private var iconColor: UIColor = UIColor.white.withAlphaComponent(0.85)
    private var minHeight: CGFloat = 52
    private var maxLines: Int = 1
    private var fontSize: CGFloat = 16
    private var lastReportedHeight: CGFloat = -1

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
            if let h = config["minHeight"] as? Double {
                minHeight = CGFloat(h)
            }
            if let n = config["maxLines"] as? Int, n >= 1 {
                maxLines = n
            }
        }

        container.configuredCornerRadius = cornerRadius

        channel = FlutterMethodChannel(
            name: "adaptive_platform_ui/ios26_glass_input_bar_\(viewId)",
            binaryMessenger: messenger
        )

        super.init()

        buildHierarchy()

        // The first time the container picks up a real width from
        // Flutter, push an initial onHeightChanged so the SizedBox on
        // the Flutter side can settle to the right baseline height
        // (and any subsequent text-driven growth gets reported too).
        container.onLayout = { [weak self] in
            self?.updateHeight()
        }

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

        // Inline text view. UITextView (not UITextField) so the
        // content can grow vertically and word-wrap up to `maxLines`
        // before internal scrolling kicks in.
        let font = UIFont.systemFont(ofSize: fontSize, weight: .regular)
        textView = UITextView()
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.delegate = self
        textView.backgroundColor = .clear
        textView.textColor = textColor
        textView.tintColor = .systemBlue
        textView.autocorrectionType = .yes
        textView.autocapitalizationType = .sentences
        textView.returnKeyType = .send
        textView.font = font
        // We control scroll enablement ourselves: off while content
        // fits within maxLines, on once it overflows so the bar stops
        // growing and the text scrolls inside it.
        textView.isScrollEnabled = false
        // Trim the default UITextView insets so the text aligns the
        // same way it used to inside the old UITextField.
        textView.textContainerInset = UIEdgeInsets(top: 14, left: 0, bottom: 14, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        blurView.contentView.addSubview(textView)

        // UITextView has no built-in placeholder; overlay a label and
        // toggle its visibility in `textViewDidChange`.
        placeholderLabel = UILabel()
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.text = placeholder
        placeholderLabel.textColor = placeholderColor
        placeholderLabel.font = font
        placeholderLabel.numberOfLines = 1
        placeholderLabel.isUserInteractionEnabled = false
        blurView.contentView.addSubview(placeholderLabel)

        var constraints: [NSLayoutConstraint] = [
            blurView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            blurView.topAnchor.constraint(equalTo: container.topAnchor),
            blurView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            textView.topAnchor.constraint(equalTo: blurView.contentView.topAnchor),
            textView.bottomAnchor.constraint(equalTo: blurView.contentView.bottomAnchor),

            // The placeholder lives on the first text-line; with the
            // textContainerInset above (14pt) this lines up with the
            // text the user types.
            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
            placeholderLabel.trailingAnchor.constraint(equalTo: textView.trailingAnchor),
            placeholderLabel.topAnchor.constraint(equalTo: textView.topAnchor, constant: 14),
        ]

        if let leading = leadingButton {
            constraints += [
                leading.leadingAnchor.constraint(equalTo: blurView.contentView.leadingAnchor, constant: 12),
                // Pin to top, not center: when the bar grows past one
                // line the leading button stays anchored at the top
                // (matches how the placeholder + first line sit).
                leading.topAnchor.constraint(equalTo: blurView.contentView.topAnchor, constant: 11),
                leading.widthAnchor.constraint(equalToConstant: 30),
                leading.heightAnchor.constraint(equalToConstant: 30),
                textView.leadingAnchor.constraint(equalTo: leading.trailingAnchor, constant: 4),
            ]
        } else {
            constraints += [
                textView.leadingAnchor.constraint(equalTo: blurView.contentView.leadingAnchor, constant: 16),
            ]
        }

        if let trailing = trailingButton {
            constraints += [
                trailing.trailingAnchor.constraint(equalTo: blurView.contentView.trailingAnchor, constant: -12),
                trailing.topAnchor.constraint(equalTo: blurView.contentView.topAnchor, constant: 11),
                trailing.widthAnchor.constraint(equalToConstant: 30),
                trailing.heightAnchor.constraint(equalToConstant: 30),
                textView.trailingAnchor.constraint(equalTo: trailing.leadingAnchor, constant: -4),
            ]
        } else {
            constraints += [
                textView.trailingAnchor.constraint(equalTo: blurView.contentView.trailingAnchor, constant: -16),
            ]
        }

        NSLayoutConstraint.activate(constraints)
    }

    // MARK: - Height tracking

    /// Computed cap: enough vertical room for `maxLines` lines of
    /// text plus the textContainerInset above/below.
    private var maxContentHeight: CGFloat {
        let lineHeight = textView.font?.lineHeight ?? fontSize * 1.2
        let inset = textView.textContainerInset.top + textView.textContainerInset.bottom
        return ceil(lineHeight * CGFloat(maxLines) + inset)
    }

    /// Recompute the bar's natural height from the text view's
    /// content, clamp it to `[minHeight, maxContentHeight]`, flip
    /// scroll on/off accordingly, and notify Flutter so it can resize
    /// the platform view's container.
    ///
    /// The scroll-enabled flip + auto-scroll-to-caret are wrapped in
    /// a UIKit spring so the moment the bar reaches `maxLines` (and
    /// internal scrolling takes over from outward growth) reads as
    /// one continuous motion rather than a hard cut. The Flutter
    /// side animates its `SizedBox` height with a matching ease-out
    /// curve, so both sides land together.
    private func updateHeight() {
        guard textView.bounds.width > 0 else { return }
        let fit = textView.sizeThatFits(
            CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)
        )
        let cap = maxContentHeight
        let needed = ceil(fit.height)
        let overflow = needed > cap
        if textView.isScrollEnabled != overflow {
            UIView.animate(
                withDuration: 0.22,
                delay: 0,
                usingSpringWithDamping: 0.95,
                initialSpringVelocity: 0,
                options: [.curveEaseOut, .allowUserInteraction],
                animations: {
                    self.textView.isScrollEnabled = overflow
                    if overflow {
                        // Keep the caret visible at the bottom of
                        // the now-scrollable area.
                        let bottom = max(
                            0,
                            self.textView.contentSize.height - self.textView.bounds.height
                        )
                        self.textView.contentOffset = CGPoint(x: 0, y: bottom)
                    }
                }
            )
        }
        let newHeight = max(minHeight, min(needed, cap))
        if abs(newHeight - lastReportedHeight) < 0.5 { return }
        lastReportedHeight = newHeight
        channel.invokeMethod("onHeightChanged", arguments: ["height": Double(newHeight)])
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

    // MARK: - UITextViewDelegate

    func textViewDidChange(_ textView: UITextView) {
        placeholderLabel.isHidden = !textView.text.isEmpty
        channel.invokeMethod("onTextChanged", arguments: ["text": textView.text ?? ""])
        updateHeight()
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        channel.invokeMethod("onFocusChanged", arguments: ["focused": true])
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        channel.invokeMethod("onFocusChanged", arguments: ["focused": false])
    }

    /// UITextView's return key inserts a newline by default. We hijack
    /// it to mean "submit" instead — the prompt bar shouldn't accept
    /// hard newlines (it's still a chat-style input, just one that
    /// can wrap up to N lines visually).
    func textView(
        _ textView: UITextView,
        shouldChangeTextIn range: NSRange,
        replacementText text: String
    ) -> Bool {
        if text == "\n" {
            channel.invokeMethod("onSubmit", arguments: ["text": textView.text ?? ""])
            textView.resignFirstResponder()
            return false
        }
        return true
    }

    // MARK: - Method channel

    private func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "focus":
            textView.becomeFirstResponder()
            result(nil)
        case "blur":
            textView.resignFirstResponder()
            result(nil)
        case "setText":
            if let args = call.arguments as? [String: Any], let text = args["text"] as? String {
                textView.text = text
                placeholderLabel.isHidden = !text.isEmpty
                updateHeight()
                result(nil)
            } else {
                result(FlutterError(code: "INVALID_ARGS", message: "Expected text", details: nil))
            }
        case "setPlaceholder":
            if let args = call.arguments as? [String: Any], let p = args["placeholder"] as? String {
                placeholder = p
                placeholderLabel.text = p
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
