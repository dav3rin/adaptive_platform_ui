import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

/// Native iOS 26+ pill input bar with Liquid Glass background.
///
/// Renders a `UIVisualEffectView` (using `UIGlassEffect` on iOS 26+,
/// `UIBlurEffect(systemUltraThinMaterial)` on older iOS) containing a
/// leading SF symbol button and an inline `UITextField`. Falls back to
/// a Cupertino [CupertinoTextField] on non-iOS platforms — callers
/// should already only mount this widget on iOS 26+ (it costs a
/// platform view roundtrip).
///
/// Use [controller] / [onChanged] / [onSubmitted] like a normal
/// Flutter text field; [onPlusTapped] fires when the leading symbol
/// is pressed; [onFocusChanged] fires when the native text field
/// begins/ends editing.
class IOS26GlassInputBar extends StatefulWidget {
  const IOS26GlassInputBar({
    super.key,
    this.placeholder = 'Describe anything',
    this.leadingSymbol = 'plus',
    this.trailingSymbol,
    this.height = 52,
    this.cornerRadius,
    this.textColor = const Color(0xFFFFFFFF),
    this.placeholderColor = const Color(0x80FFFFFF),
    this.iconColor = const Color(0xD9FFFFFF),
    this.controller,
    this.onChanged,
    this.onSubmitted,
    this.onPlusTapped,
    this.onLeadingTapped,
    this.onTrailingTapped,
    this.onFocusChanged,
    this.autofocus = false,
    this.maxLines = 1,
  });

  final String placeholder;

  /// SF Symbol name for the leading button. Pass null or an empty
  /// string to suppress the leading button entirely.
  final String? leadingSymbol;

  /// SF Symbol name for an optional trailing button (e.g. a grid
  /// picker). When null, no trailing button is rendered.
  final String? trailingSymbol;

  final double height;

  /// Corner radius for the pill. When null, the native side uses
  /// `height / 2` (true capsule).
  final double? cornerRadius;

  final Color textColor;
  final Color placeholderColor;
  final Color iconColor;

  /// Optional text controller mirrored into the native text field.
  /// Two-way binding: programmatic changes push to native, user edits
  /// push back into the controller's text.
  final TextEditingController? controller;

  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  /// Deprecated alias for [onLeadingTapped] — kept for backwards
  /// compatibility with the original `plus`-only API.
  final VoidCallback? onPlusTapped;
  final VoidCallback? onLeadingTapped;
  final VoidCallback? onTrailingTapped;
  final ValueChanged<bool>? onFocusChanged;

  /// Focus the native text field automatically as soon as the platform
  /// view is ready (after `onPlatformViewCreated` wires the channel).
  /// On the non-iOS fallback this is forwarded to
  /// `CupertinoTextField.autofocus`.
  final bool autofocus;

  /// Maximum number of lines the bar grows to before the inner text
  /// view starts scrolling internally. The bar starts at `height`
  /// (one line) and expands upward as the user types/wraps, up to
  /// `maxLines * lineHeight`. On the non-iOS fallback this is
  /// forwarded to `CupertinoTextField.maxLines`.
  final int maxLines;

  @override
  State<IOS26GlassInputBar> createState() => IOS26GlassInputBarState();
}

class IOS26GlassInputBarState extends State<IOS26GlassInputBar> {
  MethodChannel? _channel;
  String _lastNativeText = '';

  /// Current bar height. Initialised to `widget.height` (one line) and
  /// driven up to `maxLines * lineHeight` by `onHeightChanged` from
  /// the native side as the user types and the text wraps.
  late double _currentHeight = widget.height;

  /// Programmatically focus the native text field.
  Future<void> focus() async {
    await _channel?.invokeMethod<void>('focus');
  }

  /// Programmatically blur (dismiss the keyboard).
  Future<void> blur() async {
    await _channel?.invokeMethod<void>('blur');
  }

  @override
  void initState() {
    super.initState();
    widget.controller?.addListener(_pushControllerTextToNative);
  }

  @override
  void didUpdateWidget(covariant IOS26GlassInputBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?.removeListener(_pushControllerTextToNative);
      widget.controller?.addListener(_pushControllerTextToNative);
    }
    if (oldWidget.placeholder != widget.placeholder) {
      _channel?.invokeMethod<void>('setPlaceholder', {
        'placeholder': widget.placeholder,
      });
    }
  }

  @override
  void dispose() {
    widget.controller?.removeListener(_pushControllerTextToNative);
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }

  void _pushControllerTextToNative() {
    final text = widget.controller?.text ?? '';
    if (text == _lastNativeText) return;
    _lastNativeText = text;
    _channel?.invokeMethod<void>('setText', {'text': text});
  }

  Future<dynamic> _handleMethod(MethodCall call) async {
    switch (call.method) {
      case 'onTextChanged':
        final text = (call.arguments as Map?)?['text'] as String? ?? '';
        _lastNativeText = text;
        if (widget.controller != null && widget.controller!.text != text) {
          widget.controller!.text = text;
        }
        widget.onChanged?.call(text);
        break;
      case 'onSubmit':
        final text = (call.arguments as Map?)?['text'] as String? ?? '';
        widget.onSubmitted?.call(text);
        break;
      case 'onPlusTapped':
        widget.onPlusTapped?.call();
        break;
      case 'onLeadingTapped':
        widget.onLeadingTapped?.call();
        break;
      case 'onTrailingTapped':
        widget.onTrailingTapped?.call();
        break;
      case 'onFocusChanged':
        final focused = (call.arguments as Map?)?['focused'] as bool? ?? false;
        widget.onFocusChanged?.call(focused);
        break;
      case 'onHeightChanged':
        final height = (call.arguments as Map?)?['height'];
        if (height is num && mounted) {
          final next = height.toDouble();
          if ((next - _currentHeight).abs() > 0.5) {
            setState(() => _currentHeight = next);
          }
        }
        break;
    }
    return null;
  }

  int _colorToArgb(Color color) {
    return (((color.a * 255.0).round() & 0xFF) << 24) |
        (((color.r * 255.0).round() & 0xFF) << 16) |
        (((color.g * 255.0).round() & 0xFF) << 8) |
        ((color.b * 255.0).round() & 0xFF);
  }

  Map<String, dynamic> _creationParams() {
    return {
      'placeholder': widget.placeholder,
      // null is sent as an explicit suppression of the leading button;
      // omit the key when the caller didn't override it.
      if (widget.leadingSymbol == null)
        'leadingSymbol': ''
      else
        'leadingSymbol': widget.leadingSymbol,
      if (widget.trailingSymbol != null)
        'trailingSymbol': widget.trailingSymbol,
      if (widget.cornerRadius != null) 'cornerRadius': widget.cornerRadius,
      'textColor': _colorToArgb(widget.textColor),
      'placeholderColor': _colorToArgb(widget.placeholderColor),
      'iconColor': _colorToArgb(widget.iconColor),
      'minHeight': widget.height,
      'maxLines': widget.maxLines,
    };
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb || !Platform.isIOS) {
      return _buildFallback(context);
    }

    // AnimatedContainer drives the platform view's frame size between
    // line-counts. UIKit re-lays out the UITextView each animation
    // frame, so the bar opens / closes with the same easing the rest
    // of iOS 26 uses for inline-edit growth (Mail compose, iMessage).
    // Curve approximates the standard Apple ease-out used for
    // capsule resize — short, no overshoot, no Material lateness.
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      height: _currentHeight,
      child: UiKitView(
        viewType: 'adaptive_platform_ui/ios26_glass_input_bar',
        creationParams: _creationParams(),
        creationParamsCodec: const StandardMessageCodec(),
        // Let UIKit own all touches inside the bar — the native text
        // field needs raw input and the plus button is a real UIButton.
        gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
          Factory<TapGestureRecognizer>(() => TapGestureRecognizer()),
        },
        onPlatformViewCreated: (int id) {
          _channel = MethodChannel(
            'adaptive_platform_ui/ios26_glass_input_bar_$id',
          );
          _channel!.setMethodCallHandler(_handleMethod);
          // Push initial controller text (if any) once the native side
          // is ready.
          final text = widget.controller?.text ?? '';
          if (text.isNotEmpty) {
            _lastNativeText = text;
            _channel!.invokeMethod<void>('setText', {'text': text});
          }
          if (widget.autofocus) {
            _channel!.invokeMethod<void>('focus');
          }
        },
      ),
    );
  }

  Widget _buildFallback(BuildContext context) {
    // Cupertino-only fallback so the widget at least functions when
    // run on a non-iOS platform during development.
    return SizedBox(
      height: widget.height,
      child: CupertinoTextField(
        controller: widget.controller,
        placeholder: widget.placeholder,
        autofocus: widget.autofocus,
        minLines: 1,
        maxLines: widget.maxLines,
        placeholderStyle: TextStyle(color: widget.placeholderColor),
        style: TextStyle(color: widget.textColor),
        decoration: BoxDecoration(
          color: const Color(0x33FFFFFF),
          borderRadius: BorderRadius.circular(
            widget.cornerRadius ?? widget.height / 2,
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        onChanged: widget.onChanged,
        onSubmitted: widget.onSubmitted,
      ),
    );
  }
}
