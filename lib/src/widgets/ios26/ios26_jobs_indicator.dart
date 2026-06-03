import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import '../../style/sf_symbol.dart';
import '../adaptive_button.dart';

/// Native iOS 26+ jobs indicator pill.
///
/// Renders a SwiftUI view that shows an SF symbol (default `cloud.fill`)
/// inside a circular pill with an optional count badge. Whenever
/// [processingCount] *increases*, it cross-fades to a glowing
/// indeterminate spinner with the count in the center for ~5s, then
/// fades back to the icon-with-badge state.
///
/// On non-iOS platforms it falls back to a plain Cupertino button with
/// a static icon — this widget is meant for iOS 26+ chrome only;
/// callers should already gate it behind a platform check.
class IOS26JobsIndicator extends StatefulWidget {
  const IOS26JobsIndicator({
    super.key,
    required this.processingCount,
    this.onPressed,
    this.size = 32,
    this.iconName = 'cloud.fill',
    this.iconColor = const Color(0xD9FFFFFF),
    this.badgeColor = const Color(0xFF007AFF),
    this.badgeTextColor = const Color(0xFFFFFFFF),
    this.backgroundColor,
    this.useGlassBackground = true,
    this.spinnerTextSize = 10,
    this.badgeTextSize = 11,
    this.semanticsIdentifier,
    this.semanticsLabel,
  });

  /// Number of jobs currently processing. The widget tracks changes
  /// internally — when this value increases between builds, the native
  /// side runs the 5-second spinner animation.
  final int processingCount;

  final VoidCallback? onPressed;

  /// Pill diameter. The badge sits just outside the top-right edge.
  final double size;

  /// SF Symbol shown in the idle state. Defaults to `cloud.fill` to
  /// match the original Flutter [JobsIndicator].
  final String iconName;

  final Color iconColor;
  final Color badgeColor;
  final Color badgeTextColor;
  /// Pill fill when [useGlassBackground] is false. Omit (null) with glass enabled
  /// so the native side uses Liquid Glass instead of a solid backing.
  final Color? backgroundColor;

  /// When true (default), the native pill uses iOS 26 Liquid Glass — matching
  /// [AdaptiveButton.sfSymbol] / flatland_2 [IconPill].
  final bool useGlassBackground;

  /// Font size for the count shown in the center while the spinner
  /// is active. Matches the original Flutter [JobsIndicator] default
  /// of 10 at a 32pt pill.
  final double spinnerTextSize;

  /// Font size for the count badge in the idle (cloud + badge) state.
  /// Matches the original Flutter `_NumCount` default of 11.
  final double badgeTextSize;

  final String? semanticsIdentifier;
  final String? semanticsLabel;

  @override
  State<IOS26JobsIndicator> createState() => _IOS26JobsIndicatorState();
}

class _IOS26JobsIndicatorState extends State<IOS26JobsIndicator> {
  MethodChannel? _channel;
  int _lastPushedCount = 0;

  @override
  void initState() {
    super.initState();
    _lastPushedCount = widget.processingCount;
  }

  @override
  void didUpdateWidget(covariant IOS26JobsIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.processingCount != _lastPushedCount) {
      _lastPushedCount = widget.processingCount;
      _channel?.invokeMethod<void>('setCount', {
        'count': widget.processingCount,
      });
    }
    if (widget.spinnerTextSize != oldWidget.spinnerTextSize ||
        widget.badgeTextSize != oldWidget.badgeTextSize) {
      _channel?.invokeMethod<void>('setTextSizes', {
        'spinnerTextSize': widget.spinnerTextSize,
        'badgeTextSize': widget.badgeTextSize,
      });
    }
  }

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }

  Future<dynamic> _handleMethod(MethodCall call) async {
    if (call.method == 'pressed') {
      widget.onPressed?.call();
    }
    return null;
  }

  int _argb(Color color) {
    return (((color.a * 255.0).round() & 0xFF) << 24) |
        (((color.r * 255.0).round() & 0xFF) << 16) |
        (((color.g * 255.0).round() & 0xFF) << 8) |
        ((color.b * 255.0).round() & 0xFF);
  }

  Map<String, dynamic> _creationParams() => {
        'count': widget.processingCount,
        'size': widget.size,
        'iconName': widget.iconName,
        'iconColor': _argb(widget.iconColor),
        'badgeColor': _argb(widget.badgeColor),
        'badgeTextColor': _argb(widget.badgeTextColor),
        if (widget.backgroundColor != null)
          'backgroundColor': _argb(widget.backgroundColor!),
        'useGlassBackground': widget.useGlassBackground,
        'spinnerTextSize': widget.spinnerTextSize,
        'badgeTextSize': widget.badgeTextSize,
      };

  @override
  Widget build(BuildContext context) {
    Widget child;
    if (kIsWeb || !Platform.isIOS) {
      child = _buildFallback();
    } else {
      // Pill is square with a few extra pts of slop so the count
      // badge isn't clipped at the corner.
      final boxSide = widget.size + 4;
      child = SizedBox(
        width: boxSide,
        height: boxSide,
        child: UiKitView(
          viewType: 'adaptive_platform_ui/ios26_jobs_indicator',
          creationParams: _creationParams(),
          creationParamsCodec: const StandardMessageCodec(),
          gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
            Factory<TapGestureRecognizer>(() => TapGestureRecognizer()),
          },
          onPlatformViewCreated: (int id) {
            _channel = MethodChannel(
              'adaptive_platform_ui/ios26_jobs_indicator_$id',
            );
            _channel!.setMethodCallHandler(_handleMethod);
          },
        ),
      );
    }

    if (widget.semanticsIdentifier == null && widget.semanticsLabel == null) {
      return child;
    }
    return Semantics(
      identifier: widget.semanticsIdentifier,
      label: widget.semanticsLabel,
      button: true,
      child: child,
    );
  }

  Widget _buildFallback() {
    if (widget.useGlassBackground) {
      return SizedBox(
        width: widget.size,
        height: widget.size,
        child: AdaptiveButton.sfSymbol(
          onPressed: widget.onPressed,
          useSmoothRectangleBorder: false,
          size: AdaptiveButtonSize.large,
          minSize: Size(widget.size, widget.size),
          sfSymbol: SFSymbol(
            widget.iconName,
            size: widget.size * 0.5,
            color: widget.iconColor,
          ),
        ),
      );
    }

    return CupertinoButton(
      padding: EdgeInsets.zero,
      minimumSize: Size(widget.size, widget.size),
      onPressed: widget.onPressed,
      child: Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          color: widget.backgroundColor ?? const Color(0xE6000000),
          shape: BoxShape.circle,
          border: Border.all(color: const Color(0x2EFFFFFF)),
        ),
        alignment: Alignment.center,
        child: Icon(
          CupertinoIcons.cloud_fill,
          size: widget.size * 0.5,
          color: widget.iconColor,
        ),
      ),
    );
  }
}
