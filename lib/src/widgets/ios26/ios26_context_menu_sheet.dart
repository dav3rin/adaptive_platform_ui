import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../adaptive_context_menu.dart';

/// Native iOS 26 glass "menu sheet" (options panel) hosted on a platform view.
///
/// A native reimplementation of a context-menu options list, embedded inside a
/// Flutter-driven lift route (see `IOS26LiftContextMenu`). Sized in Dart so the
/// route can lay it out without an async intrinsic-size round-trip.
///
/// Selecting a row calls [onSelected] with the action index.
class IOS26ContextMenuSheet extends StatefulWidget {
  const IOS26ContextMenuSheet({
    super.key,
    required this.actions,
    required this.onSelected,
  });

  final List<AdaptiveContextMenuAction> actions;
  final void Function(int index) onSelected;

  /// Fixed panel width, matching the system menu footprint.
  static const double width = 250.0;

  /// Per-row height.
  static const double rowHeight = 44.0;

  /// Computed panel height for [actions] (rows + hairline separators).
  static double heightFor(int actionCount) {
    if (actionCount <= 0) return rowHeight;
    return actionCount * rowHeight + (actionCount - 1) * 0.5;
  }

  @override
  State<IOS26ContextMenuSheet> createState() => _IOS26ContextMenuSheetState();
}

class _IOS26ContextMenuSheetState extends State<IOS26ContextMenuSheet> {
  MethodChannel? _channel;

  bool get _isDark =>
      MediaQuery.platformBrightnessOf(context) == Brightness.dark;

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = Size(
      IOS26ContextMenuSheet.width,
      IOS26ContextMenuSheet.heightFor(widget.actions.length),
    );

    if (kIsWeb || !Platform.isIOS) {
      return SizedBox.fromSize(size: size);
    }

    final labels = <String>[];
    final symbols = <String>[];
    final isDestructive = <bool>[];
    final enabled = <bool>[];
    for (final action in widget.actions) {
      labels.add(action.title);
      symbols.add(action.icon is String ? action.icon as String : '');
      isDestructive.add(action.isDestructive);
      enabled.add(!action.isDisabled);
    }

    return SizedBox.fromSize(
      size: size,
      child: UiKitView(
        viewType: 'adaptive_platform_ui/ios26_context_menu_sheet',
        creationParams: <String, dynamic>{
          'labels': labels,
          'sfSymbols': symbols,
          'isDestructive': isDestructive,
          'enabled': enabled,
          'isDark': _isDark,
        },
        creationParamsCodec: const StandardMessageCodec(),
        onPlatformViewCreated: _onCreated,
      ),
    );
  }

  void _onCreated(int id) {
    final channel =
        MethodChannel('adaptive_platform_ui/ios26_context_menu_sheet_$id');
    _channel = channel;
    channel.setMethodCallHandler(_onMethodCall);
  }

  Future<dynamic> _onMethodCall(MethodCall call) async {
    if (call.method == 'itemSelected') {
      final args = call.arguments as Map?;
      final idx = (args?['index'] as num?)?.toInt();
      if (idx != null && idx >= 0 && idx < widget.actions.length) {
        widget.onSelected(idx);
      }
    }
    return null;
  }
}
