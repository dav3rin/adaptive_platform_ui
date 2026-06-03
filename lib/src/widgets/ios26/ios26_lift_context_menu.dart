// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// ignore_for_file: deprecated_member_use_from_same_package

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../adaptive_context_menu.dart';
import 'ios26_context_menu_sheet.dart';

// The scale of the child at the time that the CupertinoContextMenu opens.
// This value was eyeballed from a physical device running iOS 13.1.2.
const double _kOpenScale = 1.03;

// The ratio for the borderRadius of the context menu preview image. This value
// was eyeballed by overlapping the CupertinoContextMenu with a context menu
// from iOS 16.0 in the XCode iPhone simulator.
const double _previewBorderRadiusRatio = 12.0;

// The duration of the transition used when a modal popup is shown. Eyeballed
// from a physical device running iOS 13.1.2.
const Duration _kModalPopupTransitionDuration = Duration(milliseconds: 240);

// The duration it takes for the CupertinoContextMenu to open.
// This value was eyeballed from the XCode simulator running iOS 16.0.
const Duration _previewLongPressTimeout = Duration(milliseconds: 800);

// The total length of the combined animations until the menu is fully open.
final int _animationDuration =
    _previewLongPressTimeout.inMilliseconds +
    _kModalPopupTransitionDuration.inMilliseconds;

// The final box shadow for the opening child widget.
// This value was eyeballed from the XCode simulator running iOS 16.0.
const List<BoxShadow> _endBoxShadow = <BoxShadow>[
  BoxShadow(color: Color(0x40000000), blurRadius: 10.0, spreadRadius: 0.5),
];

// ---------------------------------------------------------------------------
// Lift menu backdrop tint (no Flutter sheet placeholder during flight).
// ---------------------------------------------------------------------------

/// Black tint opacity over the shell when the menu is fully open (0..1).
const double _kSettleBackdropTintOpacity = 0.32;

/// Vertical gap between a full-screen preview and the menu sheet. Matches
/// [_ContextMenuRouteStaticState._kPadding] and Cupertino context menu spacing.
const double _kChildMenuGap = 20.0;

/// Extra padding below the action sheet, applied on top of [SafeArea] /
/// [MediaQuery.padding].
const double _kMenuSheetBottomPadding = 20.0;

/// Horizontal inset applied inside [_ContextMenuSheet] around [menuChild].
const double _kMenuSheetEdgeInset = 16.0;

/// Width of the menu row including [_kMenuSheetEdgeInset] on both sides.
double _menuSheetLayoutWidth() =>
    IOS26ContextMenuSheet.width + _kMenuSheetEdgeInset * 2;

/// Tint strength while the lift route is opening or closing ([openProgress] 0..1).
double _openBackdropTintOpacity(double openProgress) {
  if (openProgress <= 0) {
    return 0;
  }
  if (openProgress >= 1) {
    return _kSettleBackdropTintOpacity;
  }
  return _kSettleBackdropTintOpacity * Curves.easeOut.transform(openProgress);
}

/// Rounded hole punched out of the dim layer so the lifted preview stays at
/// full brightness. The action sheet is not cut out — a sheet-sized hole reads
/// like a misplaced placeholder and rarely matches the native glass footprint.
List<RRect> _dimmingCutoutsForPreview({
  required Rect previewRect,
  double previewCornerRadius = _previewBorderRadiusRatio,
}) {
  return <RRect>[
    RRect.fromRectAndRadius(
      previewRect,
      Radius.circular(previewCornerRadius),
    ),
  ];
}

/// Dim behind the shell with a cutout over the lifted preview only.
class _ContextMenuDimmingOverlay extends StatelessWidget {
  const _ContextMenuDimmingOverlay({
    required this.tintOpacity,
    this.cutouts = const <RRect>[],
  });

  final double tintOpacity;
  final List<RRect> cutouts;

  @override
  Widget build(BuildContext context) {
    if (tintOpacity <= 0) {
      return const SizedBox.shrink();
    }
    return Positioned.fill(
      child: IgnorePointer(
        child: CustomPaint(
          painter: _DimmingCutoutPainter(
            opacity: tintOpacity,
            cutouts: cutouts,
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _DimmingCutoutPainter extends CustomPainter {
  const _DimmingCutoutPainter({required this.opacity, required this.cutouts});

  final double opacity;
  final List<RRect> cutouts;

  @override
  void paint(Canvas canvas, Size size) {
    final screen = Path()..addRect(Offset.zero & size);
    if (cutouts.isEmpty) {
      canvas.drawPath(
        screen,
        Paint()..color = Color.fromRGBO(0, 0, 0, opacity),
      );
      return;
    }
    var holes = Path();
    var hasHoles = false;
    for (final hole in cutouts) {
      final next = Path()..addRRect(hole);
      holes = hasHoles
          ? Path.combine(PathOperation.union, holes, next)
          : next;
      hasHoles = true;
    }
    final dim = Path.combine(PathOperation.difference, screen, holes);
    canvas.drawPath(
      dim,
      Paint()..color = Color.fromRGBO(0, 0, 0, opacity),
    );
  }

  @override
  bool shouldRepaint(covariant _DimmingCutoutPainter oldDelegate) {
    return oldDelegate.opacity != opacity || oldDelegate.cutouts != cutouts;
  }
}

typedef _DismissCallback =
    void Function(BuildContext context, double scale, double opacity);

/// A function that produces the preview when the CupertinoContextMenu is open.
///
/// Called every time the animation value changes.
typedef ContextMenuPreviewBuilder =
    Widget Function(
      BuildContext context,
      Animation<double> animation,
      Widget child,
    );

/// A function that builds the child and handles the transition between the
/// default child and the preview when the CupertinoContextMenu is open.
typedef CupertinoContextMenuBuilder =
    Widget Function(BuildContext context, Animation<double> animation);

// Given a GlobalKey, return the Rect of the corresponding RenderBox's
// paintBounds in global coordinates.
Rect _getRect(GlobalKey globalKey) {
  assert(globalKey.currentContext != null);
  final RenderBox renderBoxContainer =
      globalKey.currentContext!.findRenderObject()! as RenderBox;
  return Rect.fromPoints(
    renderBoxContainer.localToGlobal(renderBoxContainer.paintBounds.topLeft),
    renderBoxContainer.localToGlobal(
      renderBoxContainer.paintBounds.bottomRight,
    ),
  );
}

// The context menu arranges itself slightly differently based on the location
// on the screen of [CupertinoContextMenu.child] before the
// [CupertinoContextMenu] opens.
enum _ContextMenuLocation { center, left, right }

/// A full-screen modal route that opens when the [child] is long-pressed.
///
/// When open, the [IOS26LiftContextMenu] shows the child, or the widget returned
/// by [previewBuilder] if given, in a large full-screen [Overlay] with a list
/// of buttons specified by [actions]. The child/preview is placed in an
/// [Expanded] widget so that it will grow to fill the Overlay if its size is
/// unconstrained.
///
/// When closed, the [IOS26LiftContextMenu] displays the child as if the
/// [IOS26LiftContextMenu] were not there. Sizing and positioning is unaffected.
/// The menu can be closed like other [PopupRoute]s, such as by tapping the
/// background or by calling `Navigator.pop(context)`. Unlike [PopupRoute], it can
/// also be closed by swiping downwards.
///
/// The [previewBuilder] parameter is most commonly used to display a slight
/// variation of [child]. See [previewBuilder] for an example of rounding the
/// child's corners and allowing its aspect ratio to expand, similar to the
/// Photos app on iOS.
///
/// {@tool dartpad}
/// This sample shows a very simple [IOS26LiftContextMenu] for the Flutter logo.
/// Long press on it to open.
///
/// ** See code in examples/api/lib/cupertino/context_menu/cupertino_context_menu.0.dart **
/// {@end-tool}
///
/// {@tool dartpad}
/// This sample shows a similar CupertinoContextMenu, this time using [builder]
/// to add a border radius to the widget.
///
/// ** See code in examples/api/lib/cupertino/context_menu/cupertino_context_menu.1.dart **
/// {@end-tool}
///
/// See also:
///
///  * <https://developer.apple.com/design/human-interface-guidelines/ios/controls/context-menus/>
class IOS26LiftContextMenu extends StatefulWidget {
  /// [RouteSettings.name] for [_ContextMenuRoute]; used by app shell observers
  /// so the native tab bar is not hidden while the menu is open.
  static const String routeName = 'ios26_lift_context_menu';

  /// Create a context menu.
  ///
  /// The [actions] parameter cannot be empty.
  IOS26LiftContextMenu({
    super.key,
    required this.actions,
    this.onTap,
    this.onLiftMenuVisibilityChanged,
    this.enabled = true,
    this.openScaleX = _kOpenScale,
    this.openScaleY = _kOpenScale,
    required Widget this.child,
    this.replacementWidget,
    this.enableHapticFeedback = false,
    this.previewBuilder,
    this.previewFillsScreen = false,
    this.previewTargetRect,
    this.menuSheetBottomPadding = _kMenuSheetBottomPadding,
  }) : assert(actions.isNotEmpty),
       builder = ((BuildContext context, Animation<double> animation) => child);

  /// Creates a context menu with a custom [builder] controlling the widget.
  ///
  /// Use instead of the default constructor when it is needed to have a more
  /// custom animation.
  ///
  /// The [actions] parameter cannot be empty.
  const IOS26LiftContextMenu.builder({
    super.key,
    required this.actions,
    this.onTap,
    this.onLiftMenuVisibilityChanged,
    this.enabled = true,
    this.openScaleX = _kOpenScale,
    this.openScaleY = _kOpenScale,
    required this.builder,
    this.replacementWidget,
    this.enableHapticFeedback = false,
  }) : child = null,
       previewBuilder = null,
       previewFillsScreen = false,
       previewTargetRect = null,
       menuSheetBottomPadding = _kMenuSheetBottomPadding;

  /// Exposes the default border radius for matching iOS 16.0 behavior. This
  /// value was eyeballed from the iOS simulator running iOS 16.0.
  ///
  /// {@tool snippet}
  ///
  /// Below is example code in order to match the default border radius for an
  /// iOS 16.0 open preview.
  ///
  /// ```dart
  /// CupertinoContextMenu.builder(
  ///   actions: <Widget>[
  ///     CupertinoContextMenuAction(
  ///       child: const Text('Action one'),
  ///       onPressed: () {},
  ///     ),
  ///   ],
  ///   builder:(BuildContext context, Animation<double> animation) {
  ///     final Animation<BorderRadius?> borderRadiusAnimation = BorderRadiusTween(
  ///       begin: BorderRadius.circular(0.0),
  ///       end: BorderRadius.circular(CupertinoContextMenu.kOpenBorderRadius),
  ///     ).animate(
  ///       CurvedAnimation(
  ///         parent: animation,
  ///         curve: Interval(
  ///           CupertinoContextMenu.animationOpensAt,
  ///           1.0,
  ///         ),
  ///       ),
  ///     );
  ///
  ///     final Animation<Decoration> boxDecorationAnimation = DecorationTween(
  ///       begin: const BoxDecoration(
  ///        color: Color(0xFFFFFFFF),
  ///        boxShadow: <BoxShadow>[],
  ///       ),
  ///       end: const BoxDecoration(
  ///        color: Color(0xFFFFFFFF),
  ///        boxShadow: CupertinoContextMenu.kEndBoxShadow,
  ///       ),
  ///      ).animate(
  ///        CurvedAnimation(
  ///         parent: animation,
  ///         curve: Interval(
  ///           0.0,
  ///           CupertinoContextMenu.animationOpensAt,
  ///         ),
  ///       )
  ///     );
  ///
  ///     return Container(
  ///       decoration:
  ///         animation.value < CupertinoContextMenu.animationOpensAt ? boxDecorationAnimation.value : null,
  ///       child: FittedBox(
  ///         fit: BoxFit.cover,
  ///         child: ClipRRect(
  ///           borderRadius: borderRadiusAnimation.value ?? BorderRadius.circular(0.0),
  ///           child: SizedBox(
  ///             height: 150,
  ///             width: 150,
  ///             child: Image.network('https://flutter.github.io/assets-for-api-docs/assets/widgets/owl-2.jpg'),
  ///           ),
  ///         ),
  ///       )
  ///     );
  ///   },
  /// )
  /// ```
  ///
  /// {@end-tool}
  static const double kOpenBorderRadius = _previewBorderRadiusRatio;

  /// Exposes the final box shadow of the opening animation of the child widget
  /// to match the default behavior of the native iOS widget. This value was
  /// eyeballed from the iOS simulator running iOS 16.0.
  static const List<BoxShadow> kEndBoxShadow = _endBoxShadow;

  /// The point at which the CupertinoContextMenu begins to animate
  /// into the open position.
  ///
  /// A value between 0.0 and 1.0 corresponding to a point in [builder]'s
  /// animation. When passing in an animation to [builder] the range before
  /// [animationOpensAt] will correspond to the animation when the widget is
  /// pressed and held, and the range after is the animation as the menu is
  /// fully opening. For an example, see the documentation for [builder].
  static final double animationOpensAt =
      _previewLongPressTimeout.inMilliseconds / _animationDuration;

  /// A function that returns a widget to be used alternatively from [child].
  ///
  /// The widget returned by the function will be shown at all times: when the
  /// [IOS26LiftContextMenu] is closed, when it is in the middle of opening,
  /// and when it is fully open. This will overwrite the default animation that
  /// matches the behavior of an iOS 16.0 context menu.
  ///
  /// This builder can be used instead of the child when the intended child has
  /// a property that would conflict with the default animation, such as a
  /// border radius or a shadow, or if a more custom animation is needed.
  ///
  /// In addition to the current [BuildContext], the function is also called
  /// with an [Animation]. The complete animation goes from 0 to 1 when
  /// the CupertinoContextMenu opens, and from 1 to 0 when it closes, and it can
  /// be used to animate the widget in sync with this opening and closing.
  ///
  /// The animation works in two stages. The first happens on press and hold of
  /// the widget from 0 to [animationOpensAt], and the second stage for when the
  /// widget fully opens up to the menu, from [animationOpensAt] to 1.
  ///
  /// {@tool snippet}
  ///
  /// Below is an example of using [builder] to show an image tile setup to be
  /// opened in the default way to match a native iOS 16.0 app. The behavior
  /// will match what will happen if the simple child image was passed as just
  /// the [child] parameter, instead of [builder]. This can be manipulated to
  /// add more customizability to the widget's animation.
  ///
  /// ```dart
  /// CupertinoContextMenu.builder(
  ///   actions: <Widget>[
  ///     CupertinoContextMenuAction(
  ///       child: const Text('Action one'),
  ///       onPressed: () {},
  ///     ),
  ///   ],
  ///   builder:(BuildContext context, Animation<double> animation) {
  ///     final Animation<BorderRadius?> borderRadiusAnimation = BorderRadiusTween(
  ///       begin: BorderRadius.circular(0.0),
  ///       end: BorderRadius.circular(CupertinoContextMenu.kOpenBorderRadius),
  ///     ).animate(
  ///       CurvedAnimation(
  ///         parent: animation,
  ///         curve: Interval(
  ///           CupertinoContextMenu.animationOpensAt,
  ///           1.0,
  ///         ),
  ///       ),
  ///      );
  ///
  ///     final Animation<Decoration> boxDecorationAnimation = DecorationTween(
  ///       begin: const BoxDecoration(
  ///        color: Color(0xFFFFFFFF),
  ///        boxShadow: <BoxShadow>[],
  ///       ),
  ///       end: const BoxDecoration(
  ///        color: Color(0xFFFFFFFF),
  ///        boxShadow: CupertinoContextMenu.kEndBoxShadow,
  ///       ),
  ///      ).animate(
  ///        CurvedAnimation(
  ///         parent: animation,
  ///         curve: Interval(
  ///           0.0,
  ///           CupertinoContextMenu.animationOpensAt,
  ///         ),
  ///       ),
  ///     );
  ///
  ///     return Container(
  ///       decoration:
  ///         animation.value < CupertinoContextMenu.animationOpensAt ? boxDecorationAnimation.value : null,
  ///       child: FittedBox(
  ///         fit: BoxFit.cover,
  ///         child: ClipRRect(
  ///           borderRadius: borderRadiusAnimation.value ?? BorderRadius.circular(0.0),
  ///           child: SizedBox(
  ///             height: 150,
  ///             width: 150,
  ///             child: Image.network('https://flutter.github.io/assets-for-api-docs/assets/widgets/owl-2.jpg'),
  ///           ),
  ///         ),
  ///       ),
  ///     );
  ///   },
  /// )
  /// ```
  ///
  /// {@end-tool}
  ///
  /// {@tool dartpad}
  /// Additionally below is an example of a real world use case for [builder].
  ///
  /// If a widget is passed to the [child] parameter with properties that
  /// conflict with the default animation, in this case the border radius,
  /// unwanted behaviors can arise. Here a boxed shadow will wrap the widget as
  /// it is expanded. To handle this, a more custom animation and widget can be
  /// passed to the builder, using values exposed by [IOS26LiftContextMenu],
  /// like [IOS26LiftContextMenu.kEndBoxShadow], to match the native iOS
  /// animation as close as desired.
  ///
  /// ** See code in examples/api/lib/cupertino/context_menu/cupertino_context_menu.1.dart **
  /// {@end-tool}
  final CupertinoContextMenuBuilder builder;

  /// The widget that can be "opened" with the [IOS26LiftContextMenu].
  ///
  /// When the [IOS26LiftContextMenu] is long-pressed, the menu will open and
  /// this widget (or the widget returned by [previewBuilder], if provided) will
  /// be moved to the new route and placed inside of an [Expanded] widget. This
  /// allows the child to resize to fit in its place in the new route, if it
  /// doesn't size itself.
  ///
  /// When the [IOS26LiftContextMenu] is "closed", this widget acts like a
  /// [Container], i.e. it does not constrain its child's size or affect its
  /// position.
  final Widget? child;

  /// The actions that are shown in the menu.
  ///
  /// These actions are typically [CupertinoContextMenuAction]s.
  ///
  /// This parameter must not be empty.
  final List<AdaptiveContextMenuAction> actions;

  /// If true, clicking on the [CupertinoContextMenuAction]s will
  /// produce haptic feedback.
  ///
  /// Uses [HapticFeedback.heavyImpact] when activated.
  /// Defaults to false.
  final bool enableHapticFeedback;

  /// A function that returns an alternative widget to show when the
  /// [IOS26LiftContextMenu] is open.
  ///
  /// If not specified, [child] will be shown.
  ///
  /// The preview is often used to show a slight variation of the [child]. For
  /// example, the child could be given rounded corners in the preview but have
  /// sharp corners when in the page.
  ///
  /// In addition to the current [BuildContext], the function is also called
  /// with an [Animation] and the [child]. The animation goes from 0 to 1 when
  /// the CupertinoContextMenu opens, and from 1 to 0 when it closes, and it can
  /// be used to animate the preview in sync with this opening and closing. The
  /// child parameter provides access to the child displayed when the
  /// CupertinoContextMenu is closed.
  ///
  /// {@tool snippet}
  ///
  /// Below is an example of using [previewBuilder] to show an image tile that's
  /// similar to each tile in the iOS iPhoto app's context menu. Several of
  /// these could be used in a GridView for a similar effect.
  ///
  /// When opened, the child animates to show its full aspect ratio and has
  /// rounded corners. The larger size of the open CupertinoContextMenu allows
  /// the FittedBox to fit the entire image, even when it has a very tall or
  /// wide aspect ratio compared to the square of a GridView, so this animates
  /// into view as the CupertinoContextMenu is opened. The preview is swapped in
  /// right when the open animation begins, which includes the rounded corners.
  ///
  /// ```dart
  /// CupertinoContextMenu(
  ///   // The FittedBox in the preview here allows the image to animate its
  ///   // aspect ratio when the CupertinoContextMenu is animating its preview
  ///   // widget open and closed.
  ///   // ignore: deprecated_member_use
  ///   previewBuilder: (BuildContext context, Animation<double> animation, Widget child) {
  ///     return FittedBox(
  ///       fit: BoxFit.cover,
  ///       // This ClipRRect rounds the corners of the image when the
  ///       // CupertinoContextMenu is open, even though it's not rounded when
  ///       // it's closed. It uses the given animation to animate the corners
  ///       // in sync with the opening animation.
  ///       child: ClipRRect(
  ///         borderRadius: BorderRadius.circular(64.0 * animation.value),
  ///         child: Image.asset('assets/photo.jpg'),
  ///       ),
  ///     );
  ///   },
  ///   actions: <Widget>[
  ///     CupertinoContextMenuAction(
  ///       child: const Text('Action one'),
  ///       onPressed: () {},
  ///     ),
  ///   ],
  ///   child: FittedBox(
  ///     fit: BoxFit.cover,
  ///     child: Image.asset('assets/photo.jpg'),
  ///   ),
  /// )
  /// ```
  ///
  /// {@end-tool}

  final Function()? onTap;
  final ValueChanged<bool>? onLiftMenuVisibilityChanged;
  final bool enabled;

  final double openScaleX;
  final double openScaleY;

  /// Widget to display instead of the child when the context menu is active.
  /// If null, the child will be shown at animation value 0.0.
  final Widget? replacementWidget;

  /// Optional lift preview (backing, corners). When null, uses a row-safe
  /// [ClipRRect] at the lifted size (see [_IOS26LiftContextMenuState._openContextMenu]).
  final ContextMenuPreviewBuilder? previewBuilder;

  /// When true, the lift animates the preview to [previewTargetRect] (or
  /// [defaultFillPreviewTargetRect]) instead of staying at the pressed tile size.
  /// Use for grid tiles / images that should expand like the system photo menu.
  final bool previewFillsScreen;

  /// Override for the open preview's final bounds. Only used when
  /// [previewFillsScreen] is true.
  final Rect Function(BuildContext context, int actionCount)? previewTargetRect;

  /// Extra padding below the menu on top of [SafeArea] (e.g. floating tab bar).
  final double menuSheetBottomPadding;

  /// Bottom space below the menu: system safe area + [extraBottomPadding].
  static double bottomReservedHeight(
    BuildContext context, {
    double extraBottomPadding = _kMenuSheetBottomPadding,
  }) {
    return MediaQuery.paddingOf(context).bottom + extraBottomPadding;
  }

  /// Default open bounds for [previewFillsScreen]: nearly full width, square,
  /// leaving room for the glass action sheet below.
  static Rect defaultFillPreviewTargetRect(
    BuildContext context,
    int actionCount,
  ) {
    final media = MediaQuery.of(context);
    final size = media.size;
    final padding = media.padding;
    const horizontalInset = 16.0;
    const topInset = 12.0;
    final sheetHeight = IOS26ContextMenuSheet.heightFor(actionCount);
    final width = size.width - horizontalInset * 2;
    final bottomReserved = bottomReservedHeight(context);
    final maxHeight = size.height -
        padding.top -
        bottomReserved -
        sheetHeight -
        _kChildMenuGap -
        topInset;
    final height = math.min(width, math.max(0.0, maxHeight));
    return Rect.fromLTWH(
      horizontalInset,
      padding.top + topInset,
      width,
      height,
    );
  }

  @override
  State<IOS26LiftContextMenu> createState() => _IOS26LiftContextMenuState();
}

class _IOS26LiftContextMenuState extends State<IOS26LiftContextMenu>
    with TickerProviderStateMixin {
  final GlobalKey _childGlobalKey = GlobalKey();
  bool _childHidden = false;
  // Animates the child while it's opening.
  late AnimationController _openController;
  Rect? _decoyChildEndRect;
  OverlayEntry? _lastOverlayEntry;
  _ContextMenuRoute<void>? _route;
  final double _midpoint = IOS26LiftContextMenu.animationOpensAt / 2;

  @override
  void initState() {
    super.initState();
    _openController = AnimationController(
      duration: _previewLongPressTimeout,
      vsync: this,
      upperBound: IOS26LiftContextMenu.animationOpensAt,
    );
    _openController.addStatusListener(_onDecoyAnimationStatusChange);
  }

  void _listenerCallback() {
    if (_openController.status != AnimationStatus.reverse &&
        _openController.value >= _midpoint) {
      if (widget.enableHapticFeedback) {
        HapticFeedback.heavyImpact();
      }
      _openController.removeListener(_listenerCallback);
    }
  }

  void _notifyLiftMenuVisibilityChanged(bool visible) {
    final callback = widget.onLiftMenuVisibilityChanged;
    if (callback == null) return;
    if (visible) {
      callback(true);
      return;
    }
    SchedulerBinding.instance.addPostFrameCallback((_) {
      callback(false);
    });
  }

  // Determine the _ContextMenuLocation based on the location of the original
  // child in the screen.
  //
  // The location of the original child is used to determine how to horizontally
  // align the content of the open CupertinoContextMenu. For example, if the
  // child is near the center of the screen, it will also appear in the center
  // of the screen when the menu is open, and the actions will be centered below
  // it.
  _ContextMenuLocation get _contextMenuLocation {
    final Rect childRect = _getRect(_childGlobalKey);
    final double screenWidth = MediaQuery.sizeOf(context).width;

    final double center = screenWidth / 2;
    final bool centerDividesChild =
        childRect.left < center && childRect.right > center;
    final double distanceFromCenter = (center - childRect.center.dx).abs();
    if (centerDividesChild && distanceFromCenter <= childRect.width / 4) {
      return _ContextMenuLocation.center;
    }

    if (childRect.center.dx > center) {
      return _ContextMenuLocation.right;
    }

    return _ContextMenuLocation.left;
  }

  // Push the new route and open the CupertinoContextMenu overlay.
  void _openContextMenu() {
    setState(() {
      _childHidden = true;
    });

    final Rect? openChildTargetRect = widget.previewFillsScreen
        ? (widget.previewTargetRect ??
              IOS26LiftContextMenu.defaultFillPreviewTargetRect)(
            context,
            widget.actions.length,
          )
        : null;

    _route = _ContextMenuRoute<void>(
      settings: const RouteSettings(name: IOS26LiftContextMenu.routeName),
      actions: widget.actions,
      barrierLabel: CupertinoLocalizations.of(context).menuDismissLabel,
      contextMenuLocation: _contextMenuLocation,
      previousChildRect: _decoyChildEndRect!,
      openChildTargetRect: openChildTargetRect,
      previewFillsScreen: widget.previewFillsScreen,
      menuSheetBottomPadding: widget.menuSheetBottomPadding,
      openScaleX: widget.openScaleX,
      openScaleY: widget.openScaleY,
      builder: (BuildContext context, Animation<double> animation) {
        if (widget.child == null) {
          final Animation<double> localAnimation = Tween<double>(
            begin: IOS26LiftContextMenu.animationOpensAt,
            end: 1,
          ).animate(animation);
          return widget.builder(context, localAnimation);
        }
        final Widget preview = widget.previewBuilder != null
            ? widget.previewBuilder!(context, animation, widget.child!)
            : ClipRRect(
                borderRadius: BorderRadius.circular(
                  _previewBorderRadiusRatio * animation.value,
                ),
                child: widget.child!,
              );
        // Settled layout and in-flight sizing are handled by the route so the
        // preview can track the animating rect (square → aspect) without
        // clipping a fixed final-size child.
        if (widget.previewFillsScreen && openChildTargetRect != null) {
          return preview;
        }
        // Full-width rows have no intrinsic width; size to the lifted rect.
        // Avoid `FittedBox(cover)`, which would hand the row unbounded width.
        return SizedBox.fromSize(
          size: _decoyChildEndRect!.size,
          child: preview,
        );
      },
    );
    Navigator.of(context, rootNavigator: true).push<void>(_route!);
    _route!.animation!.addStatusListener(_routeAnimationStatusListener);
    _notifyLiftMenuVisibilityChanged(true);
  }

  void _onDecoyAnimationStatusChange(AnimationStatus animationStatus) {
    switch (animationStatus) {
      case AnimationStatus.dismissed:
        if (_route == null) {
          SchedulerBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            setState(() {
              _childHidden = false;
            });
          });
        }
        _lastOverlayEntry?.remove();
        _lastOverlayEntry?.dispose();
        _lastOverlayEntry = null;

      case AnimationStatus.completed:
        setState(() {
          _childHidden = true;
        });
        _openContextMenu();
        // Keep the decoy on the screen for one extra frame. We have to do this
        // because _ContextMenuRoute renders its first frame offscreen.
        // Otherwise there would be a visible flash when nothing is rendered for
        // one frame.
        SchedulerBinding.instance.addPostFrameCallback((Duration _) {
          _lastOverlayEntry?.remove();
          _lastOverlayEntry?.dispose();
          _lastOverlayEntry = null;
          if (!mounted) return;
          _openController.reset();
        }, debugLabel: 'removeContextMenuDecoy');

      case AnimationStatus.forward:
      case AnimationStatus.reverse:
        return;
    }
  }

  // Watch for when _ContextMenuRoute is closed and return to the state where
  // the CupertinoContextMenu just behaves as a Container.
  void _routeAnimationStatusListener(AnimationStatus status) {
    if (status == AnimationStatus.reverse) {
      _route?.animation?.addListener(_onRouteCloseAnimationTick);
      return;
    }
    if (status != AnimationStatus.dismissed) {
      return;
    }
    _route?.animation?.removeListener(_onRouteCloseAnimationTick);
    final route = _route;
    route?.animation?.removeStatusListener(_routeAnimationStatusListener);
    _route = null;
    _notifyLiftMenuVisibilityChanged(false);
    if (mounted && _childHidden) {
      setState(() {
        _childHidden = false;
      });
    }
  }

  /// Reveal the grid tile under the flying preview near the end of the dismiss
  /// flight so removing the route does not flash empty space.
  void _onRouteCloseAnimationTick() {
    final animation = _route?.animation;
    if (animation == null || animation.status != AnimationStatus.reverse) {
      return;
    }
    if (animation.value > 0.12 || !_childHidden || !mounted) {
      return;
    }
    setState(() {
      _childHidden = false;
    });
  }

  void _onTap() {
    _openController.removeListener(_listenerCallback);
    if (_openController.isAnimating && _openController.value < _midpoint) {
      _openController.reverse();
    }
    if (!_openController.isAnimating || _openController.value < _midpoint) {
      widget.onTap?.call();
    }
  }

  void _onTapCancel() {
    _openController.removeListener(_listenerCallback);
    if (_openController.isAnimating && _openController.value < _midpoint) {
      _openController.reverse();
    }
  }

  void _onTapUp(TapUpDetails details) {
    _openController.removeListener(_listenerCallback);
    if (_openController.isAnimating && _openController.value < _midpoint) {
      _openController.reverse();
    }
  }

  void _onTapDown(TapDownDetails details) {
    if (!widget.enabled) {
      return;
    }

    _openController.addListener(_listenerCallback);
    setState(() {
      _childHidden = true;
    });

    final Rect childRect = _getRect(_childGlobalKey);
    _decoyChildEndRect = Rect.fromCenter(
      center: childRect.center,
      width: childRect.width * widget.openScaleX,
      height: childRect.height * widget.openScaleY,
    );

    // Create a decoy child in an overlay directly on top of the original child.
    // doing the bounce animation using a decoy in the top level Overlay. The
    // decoy will pop on top of the AppBar if the child is partially behind it,
    // such as a top item in a partially scrolled view. However, if we don't use
    // an overlay, then the decoy will appear behind its neighboring widget when
    // it expands. This may be solvable by adding a widget to Scaffold that's
    // underneath the AppBar.
    _lastOverlayEntry = OverlayEntry(
      builder: (BuildContext context) {
        final Widget decoyChild = widget.previewBuilder != null
            ? widget.previewBuilder!(context, _openController, widget.child!)
            : widget.child!;
        return _DecoyChild(
          beginRect: childRect,
          controller: _openController,
          endRect: _decoyChildEndRect,
          child: decoyChild,
        );
      },
    );
    Overlay.of(
      context,
      rootOverlay: false,
      debugRequiredFor: widget,
    ).insert(_lastOverlayEntry!);
    _openController.forward();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.deferToChild,
      // onTap: () {
      //   if (!_openController.isAnimating) {
      //     widget.onTap?.call();
      //   }
      // },
      // onTapDown: (details) {
      //   _tapGestureRecognizer.add(details);
      // },
      onTapCancel: _onTapCancel,
      onTapDown: _onTapDown,
      onTapUp: _onTapUp,
      onTap: _onTap,

      child: MouseRegion(
        cursor: kIsWeb ? SystemMouseCursors.click : MouseCursor.defer,
        child: TickerMode(
          enabled: true,
          child: widget.replacementWidget != null
              ? KeyedSubtree(
                  key: _childGlobalKey,
                  child: _childHidden
                      ? widget.replacementWidget!
                      : widget.builder(context, _openController),
                )
              : Visibility.maintain(
                  key: _childGlobalKey,
                  visible: !_childHidden,
                  child: widget.builder(context, _openController),
                ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    final route = _route;
    if (route != null) {
      route.animation?.removeStatusListener(_routeAnimationStatusListener);
      // Do not [removeRoute] here — a parent rebuild (e.g. header blur toggle)
      // can dispose this tile while the menu is still open on the root
      // navigator, which would destroy the menu at the end of the flight.
      _route = null;
      _notifyLiftMenuVisibilityChanged(false);
    }

    _lastOverlayEntry?.remove();
    _lastOverlayEntry?.dispose();
    _lastOverlayEntry = null;

    _openController.removeStatusListener(_onDecoyAnimationStatusChange);
    _openController.dispose();
    super.dispose();
  }
}

// A floating copy of the CupertinoContextMenu's child.
//
// When the child is pressed, but before the CupertinoContextMenu opens, it does
// an animation where it slowly grows. This is implemented by hiding the
// original child and placing _DecoyChild on top of it in an Overlay. The use of
// an Overlay allows the _DecoyChild to appear on top of siblings of the
// original child.
class _DecoyChild extends StatefulWidget {
  const _DecoyChild({
    this.beginRect,
    required this.controller,
    this.endRect,
    this.child,
    this.builder,
  });

  final Rect? beginRect;
  final AnimationController controller;
  final Rect? endRect;
  final Widget? child;
  final CupertinoContextMenuBuilder? builder;

  @override
  _DecoyChildState createState() => _DecoyChildState();
}

class _DecoyChildState extends State<_DecoyChild>
    with TickerProviderStateMixin {
  late Animation<Rect?> _rect;
  late Animation<Decoration> _boxDecoration;

  @override
  void initState() {
    super.initState();

    const double beginPause = 1.0;
    const double openAnimationLength = 5.0;
    const double totalOpenAnimationLength = beginPause + openAnimationLength;
    final double endPause =
        ((totalOpenAnimationLength * _animationDuration) /
            _previewLongPressTimeout.inMilliseconds) -
        totalOpenAnimationLength;

    // The timing on the animation was eyeballed from the XCode iOS simulator
    // running iOS 16.0.
    // Because the animation no longer goes from 0.0 to 1.0, but to a number
    // depending on the ratio between the press animation time and the opening
    // animation time, a pause needs to be added to the end of the tween
    // sequence that completes that ratio. This is to allow the animation to
    // fully complete as expected without doing crazy math to the _kOpenScale
    // value. This change was necessary from the inclusion of the builder and
    // the complete animation value that it passes along.
    _rect = TweenSequence<Rect?>(<TweenSequenceItem<Rect?>>[
      TweenSequenceItem<Rect?>(
        tween: RectTween(
          begin: widget.beginRect,
          end: widget.beginRect,
        ).chain(CurveTween(curve: Curves.linear)),
        weight: beginPause,
      ),
      TweenSequenceItem<Rect?>(
        tween: RectTween(
          begin: widget.beginRect,
          end: widget.endRect,
        ).chain(CurveTween(curve: Curves.easeOutSine)),
        weight: openAnimationLength,
      ),
      TweenSequenceItem<Rect?>(
        tween: RectTween(
          begin: widget.endRect,
          end: widget.endRect,
        ).chain(CurveTween(curve: Curves.linear)),
        weight: endPause,
      ),
    ]).animate(widget.controller);

    // Transparent (not white) so the lifting card matches the dark app and
    // the route's settled preview, which is also transparent over the
    // dimmed backdrop.
    _boxDecoration =
        DecorationTween(
          begin: const BoxDecoration(
            color: Color(0x00000000),
            boxShadow: <BoxShadow>[],
          ),
          end: const BoxDecoration(
            color: Color(0x00000000),
            boxShadow: <BoxShadow>[],
          ),
        ).animate(
          CurvedAnimation(
            parent: widget.controller,
            curve: Interval(0.0, IOS26LiftContextMenu.animationOpensAt),
          ),
        );
  }

  Widget _buildAnimation(BuildContext context, Widget? child) {
    return Positioned.fromRect(
      rect: _rect.value!,
      child: Container(decoration: _boxDecoration.value, child: widget.child),
    );
  }

  Widget _buildBuilder(BuildContext context, Widget? child) {
    return Positioned.fromRect(
      rect: _rect.value!,
      child: widget.builder!(context, widget.controller),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        AnimatedBuilder(
          builder: widget.child != null ? _buildAnimation : _buildBuilder,
          animation: widget.controller,
        ),
      ],
    );
  }
}

// The open CupertinoContextMenu modal.
class _ContextMenuRoute<T> extends PopupRoute<T> {
  // Build a _ContextMenuRoute.
  _ContextMenuRoute({
    required List<AdaptiveContextMenuAction> actions,
    required _ContextMenuLocation contextMenuLocation,
    this.barrierLabel,
    CupertinoContextMenuBuilder? builder,
    super.filter,
    required Rect previousChildRect,
    this.openChildTargetRect,
    this.previewFillsScreen = false,
    this.menuSheetBottomPadding = _kMenuSheetBottomPadding,
    required this.openScaleY,
    required this.openScaleX,
    super.settings,
  }) : assert(actions.isNotEmpty),
       _actions = actions,
       _builder = builder,
       _contextMenuLocation = contextMenuLocation,
       _previousChildRect = previousChildRect;

  // Tap-to-dismiss only — dimming is [_ContextMenuBackdrop]'s tint overlay.
  static const Color _kModalBarrierColor = ui.Color(0x00000000);

  final List<AdaptiveContextMenuAction> _actions;
  final CupertinoContextMenuBuilder? _builder;
  final GlobalKey _childGlobalKey = GlobalKey();
  final _ContextMenuLocation _contextMenuLocation;
  bool _externalOffstage = false;
  bool _internalOffstage = false;
  Orientation? _lastOrientation;
  // The Rect of the child at the moment that the CupertinoContextMenu opens.
  final Rect _previousChildRect;

  /// When set, the lift animates to this rect instead of the measured child.
  final Rect? openChildTargetRect;

  final bool previewFillsScreen;

  final double menuSheetBottomPadding;

  double? _scale = 1.0;
  final GlobalKey _sheetGlobalKey = GlobalKey();

  static final CurveTween _curve = CurveTween(
    curve: Curves.fastEaseInToSlowEaseOut,
  );
  static final CurveTween _curveReverse = CurveTween(
    curve: Curves.easeInOutCubic,
  );
  static final RectTween _rectTween = RectTween();
  static final Animatable<Rect?> _rectAnimatable = _rectTween.chain(_curve);
  static final RectTween _rectTweenReverse = RectTween();
  static final Animatable<Rect?> _rectAnimatableReverse = _rectTweenReverse
      .chain(_curveReverse);
  static final RectTween _sheetRectTween = RectTween();
  final Animatable<Rect?> _sheetRectAnimatable = _sheetRectTween.chain(_curve);
  final Animatable<Rect?> _sheetRectAnimatableReverse = _sheetRectTween.chain(
    _curveReverse,
  );
  static final Tween<double> _sheetScaleTween = Tween<double>();
  static final Animatable<double> _sheetScaleAnimatable = _sheetScaleTween
      .chain(_curve);
  static final Animatable<double> _sheetScaleAnimatableReverse =
      _sheetScaleTween.chain(_curveReverse);
  @override
  final String? barrierLabel;

  @override
  Color get barrierColor => _kModalBarrierColor;

  @override
  bool get barrierDismissible => true;

  @override
  bool get semanticsDismissible => false;

  @override
  Duration get transitionDuration => _kModalPopupTransitionDuration;

  final double openScaleX;
  final double openScaleY;

  // Getting the RenderBox doesn't include the scale from the Transform.scale,
  // so it's manually accounted for here.
  static Rect _getScaledRect(GlobalKey globalKey, double scale) {
    final Rect childRect = _getRect(globalKey);
    final Size sizeScaled = childRect.size * scale;
    final Offset offsetScaled = Offset(
      childRect.left + (childRect.size.width - sizeScaled.width) / 2,
      childRect.top + (childRect.size.height - sizeScaled.height) / 2,
    );
    return offsetScaled & sizeScaled;
  }

  // Get the alignment for the _ContextMenuSheet's Transform.scale based on the
  // contextMenuLocation.
  static AlignmentDirectional getSheetAlignment(
    _ContextMenuLocation contextMenuLocation,
  ) {
    switch (contextMenuLocation) {
      case _ContextMenuLocation.center:
        return AlignmentDirectional.topCenter;
      case _ContextMenuLocation.right:
        return AlignmentDirectional.topEnd;
      case _ContextMenuLocation.left:
        return AlignmentDirectional.topStart;
    }
  }

  /// Final menu bounds for [previewFillsScreen] — matches settled column layout.
  static Rect _fillsScreenSheetRect(
    Rect childRect,
    _ContextMenuLocation contextMenuLocation,
    int actionCount,
  ) {
    final Size size = Size(
      _menuSheetLayoutWidth(),
      IOS26ContextMenuSheet.heightFor(actionCount),
    );
    final double top = childRect.bottom + _kChildMenuGap;
    final double left = switch (contextMenuLocation) {
      _ContextMenuLocation.center =>
        childRect.left + (childRect.width - size.width) / 2,
      _ContextMenuLocation.right => childRect.right - size.width,
      _ContextMenuLocation.left => childRect.left,
    };
    return Rect.fromLTWH(left, top, size.width, size.height);
  }

  // The place to start the sheetRect animation from.
  static Rect _getSheetRectBegin(
    Orientation? orientation,
    _ContextMenuLocation contextMenuLocation,
    Rect childRect,
    Rect sheetRect,
  ) {
    switch (contextMenuLocation) {
      case _ContextMenuLocation.center:
        final Offset target = orientation == Orientation.portrait
            ? childRect.bottomCenter
            : childRect.topCenter;
        final Offset centered = target - Offset(sheetRect.width / 2, 0.0);
        return centered & sheetRect.size;
      case _ContextMenuLocation.right:
        final Offset target = orientation == Orientation.portrait
            ? childRect.bottomRight
            : childRect.topRight;
        return (target - Offset(sheetRect.width, 0.0)) & sheetRect.size;
      case _ContextMenuLocation.left:
        final Offset target = orientation == Orientation.portrait
            ? childRect.bottomLeft
            : childRect.topLeft;
        return target & sheetRect.size;
    }
  }

  void _onDismiss(BuildContext context, double scale, double opacity) {
    _scale = scale;
    Navigator.of(context).pop();
  }

  // Take measurements on the child and _ContextMenuSheet and update the
  // animation tweens to match.
  void _updateTweenRects() {
    final Rect measuredChildRect = _scale == null
        ? _getRect(_childGlobalKey)
        : _getScaledRect(_childGlobalKey, _scale!);
    final Rect childRectEnd = openChildTargetRect ?? measuredChildRect;
    _rectTween.begin = _previousChildRect;
    _rectTween.end = childRectEnd;

    // When opening, the transition happens from the end of the child's bounce
    // animation to the final state. When closing, it goes from the final state
    // to the original position before the bounce.
    final Rect childRectOriginal = Rect.fromCenter(
      center: _previousChildRect.center,
      width: _previousChildRect.width / openScaleX,
      height: _previousChildRect.height / openScaleY,
    );

    final Rect sheetRect = openChildTargetRect != null && previewFillsScreen
        ? _fillsScreenSheetRect(
            openChildTargetRect!,
            _contextMenuLocation,
            _actions.length,
          )
        : _getRect(_sheetGlobalKey);
    final Rect sheetRectBegin = _getSheetRectBegin(
      _lastOrientation,
      _contextMenuLocation,
      openChildTargetRect ?? childRectOriginal,
      sheetRect,
    );
    _sheetRectTween.begin = sheetRectBegin;
    _sheetRectTween.end = sheetRect;
    _sheetScaleTween.begin = 0.0;
    _sheetScaleTween.end = _scale;

    _rectTweenReverse.begin = childRectOriginal;
    _rectTweenReverse.end = childRectEnd;
  }

  void _setOffstageInternally() {
    super.offstage = _externalOffstage || _internalOffstage;
    // It's necessary to call changedInternalState to get the backdrop to
    // update.
    changedInternalState();
  }

  @override
  bool didPop(T? result) {
    _updateTweenRects();
    return super.didPop(result);
  }

  @override
  set offstage(bool value) {
    _externalOffstage = value;
    _setOffstageInternally();
  }

  @override
  TickerFuture didPush() {
    _internalOffstage = true;
    _setOffstageInternally();

    // Render one frame offstage in the final position so that we can take
    // measurements of its layout and then animate to them.
    SchedulerBinding.instance.addPostFrameCallback((Duration _) {
      _updateTweenRects();
      _internalOffstage = false;
      _setOffstageInternally();
    }, debugLabel: 'renderContextMenuRouteOffstage');
    return super.didPush();
  }

  Widget _previewForFlightRect(
    BuildContext context,
    Animation<double> animation,
    Rect rect,
  ) {
    final Widget preview = _builder!(context, animation);
    if (previewFillsScreen && openChildTargetRect != null) {
      return SizedBox(width: rect.width, height: rect.height, child: preview);
    }
    return preview;
  }

  bool _usesSettledContextMenuLayout(Animation<double> animation) {
    if (animation.status == AnimationStatus.completed) {
      return true;
    }
    if (animation.status == AnimationStatus.reverse &&
        animation.value >= 0.99) {
      return true;
    }
    return false;
  }

  Widget _previewForSettledTarget(
    BuildContext context,
    Animation<double> animation,
  ) {
    final Widget preview = _builder!(context, animation);
    if (previewFillsScreen && openChildTargetRect != null) {
      return SizedBox(
        width: openChildTargetRect!.width,
        height: openChildTargetRect!.height,
        child: preview,
      );
    }
    return preview;
  }

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    // This is usually used to build the "page", which is then passed to
    // buildTransitions as child, the idea being that buildTransitions will
    // animate the entire page into the scene. In the case of _ContextMenuRoute,
    // two individual pieces of the page are animated into the scene in
    // buildTransitions, and a SizedBox.shrink() is returned here.
    return const SizedBox.shrink();
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return OrientationBuilder(
      builder: (BuildContext context, Orientation orientation) {
        _lastOrientation = orientation;

        // While the animation is running, render everything in a Stack so that
        // they're movable. Hold the settled layout for the first frames of the
        // dismiss flight so we do not unmount the native sheet mid-animation.
        if (!_usesSettledContextMenuLayout(animation)) {
          final bool reverse = animation.status == AnimationStatus.reverse;
          final Rect rect = reverse
              ? _rectAnimatableReverse.evaluate(animation)!
              : _rectAnimatable.evaluate(animation)!;
          final Rect sheetRect = reverse
              ? _sheetRectAnimatableReverse.evaluate(animation)!
              : _sheetRectAnimatable.evaluate(animation)!;
          final double sheetScale = reverse
              ? _sheetScaleAnimatableReverse.evaluate(animation)
              : _sheetScaleAnimatable.evaluate(animation);
          final double backdropTintOpacity = _openBackdropTintOpacity(
            animation.value,
          );
          final cutouts = _dimmingCutoutsForPreview(
            previewRect: rect,
            previewCornerRadius:
                _previewBorderRadiusRatio * animation.value.clamp(0.0, 1.0),
          );
          return Stack(
            fit: StackFit.expand,
            children: <Widget>[
              _ContextMenuDimmingOverlay(
                tintOpacity: backdropTintOpacity,
                cutouts: cutouts,
              ),
              if (!previewFillsScreen)
                Positioned.fromRect(
                  rect: sheetRect,
                  child: Transform.scale(
                    alignment: getSheetAlignment(_contextMenuLocation),
                    scale: sheetScale,
                    child: _ContextMenuSheet(
                      key: _sheetGlobalKey,
                      menuChild: SizedBox(
                        width: IOS26ContextMenuSheet.width,
                        height: IOS26ContextMenuSheet.heightFor(
                          _actions.length,
                        ),
                      ),
                      contextMenuLocation: _contextMenuLocation,
                      orientation: orientation,
                    ),
                  ),
                ),
              Positioned.fromRect(
                key: _childGlobalKey,
                rect: rect,
                child: _previewForFlightRect(context, animation, rect),
              ),
            ],
          );
        }

        // When the animation is done, just render everything in a static layout
        // in the final position.
        return _ContextMenuRouteStatic(
          actions: _actions,
          childGlobalKey: _childGlobalKey,
          contextMenuLocation: _contextMenuLocation,
          onDismiss: _onDismiss,
          orientation: orientation,
          openChildTargetRect: openChildTargetRect,
          previewFillsScreen: previewFillsScreen,
          menuSheetBottomPadding: menuSheetBottomPadding,
          sheetGlobalKey: _sheetGlobalKey,
          child: _previewForSettledTarget(context, animation),
        );
      },
    );
  }
}

// The final state of the _ContextMenuRoute after animating in and before
// animating out.
class _ContextMenuRouteStatic extends StatefulWidget {
  const _ContextMenuRouteStatic({
    this.actions,
    required this.child,
    this.childGlobalKey,
    required this.contextMenuLocation,
    this.onDismiss,
    required this.orientation,
    this.openChildTargetRect,
    this.previewFillsScreen = false,
    this.menuSheetBottomPadding = _kMenuSheetBottomPadding,
    this.sheetGlobalKey,
  });

  final List<AdaptiveContextMenuAction>? actions;
  final Widget child;
  final GlobalKey? childGlobalKey;
  final _ContextMenuLocation contextMenuLocation;
  final _DismissCallback? onDismiss;
  final Orientation orientation;
  final Rect? openChildTargetRect;
  final bool previewFillsScreen;
  final double menuSheetBottomPadding;
  final GlobalKey? sheetGlobalKey;

  @override
  _ContextMenuRouteStaticState createState() => _ContextMenuRouteStaticState();
}

class _ContextMenuRouteStaticState extends State<_ContextMenuRouteStatic>
    with TickerProviderStateMixin {
  // The child is scaled down as it is dragged down until it hits this minimum
  // value.
  static const double _kMinScale = 0.8;
  // The CupertinoContextMenuSheet disappears at this scale.
  static const double _kSheetScaleThreshold = 0.9;
  static const double _kPadding = 20.0;
  static const double _kDamping = 400.0;
  static const Duration _kMoveControllerDuration = Duration(milliseconds: 600);

  late Offset _dragOffset;
  double _lastScale = 1.0;
  late AnimationController _moveController;
  late AnimationController _sheetController;
  late Animation<Offset> _moveAnimation;
  late Animation<double> _sheetScaleAnimation;
  late Animation<double> _sheetOpacityAnimation;

  // The scale of the child changes as a function of the distance it is dragged.
  static double _getScale(
    Orientation orientation,
    double maxDragDistance,
    double dy,
  ) {
    final double dyDirectional = dy <= 0.0 ? dy : -dy;
    return math.max(
      _kMinScale,
      (maxDragDistance + dyDirectional) / maxDragDistance,
    );
  }

  void _onPanStart(DragStartDetails details) {
    _moveController.value = 1.0;
    _setDragOffset(Offset.zero);
  }

  void _onPanUpdate(DragUpdateDetails details) {
    _setDragOffset(_dragOffset + details.delta);
  }

  void _onPanEnd(DragEndDetails details) {
    // If flung, animate a bit before handling the potential dismiss.
    if (details.velocity.pixelsPerSecond.dy.abs() >= kMinFlingVelocity) {
      final bool flingIsAway = details.velocity.pixelsPerSecond.dy > 0;
      final double finalPosition = flingIsAway
          ? _moveAnimation.value.dy + 100.0
          : 0.0;

      if (flingIsAway && _sheetController.status != AnimationStatus.forward) {
        _sheetController.forward();
      } else if (!flingIsAway &&
          _sheetController.status != AnimationStatus.reverse) {
        _sheetController.reverse();
      }

      _moveAnimation = Tween<Offset>(
        begin: Offset(0.0, _moveAnimation.value.dy),
        end: Offset(0.0, finalPosition),
      ).animate(_moveController);
      _moveController.reset();
      _moveController.duration = const Duration(milliseconds: 64);
      _moveController.forward();
      _moveController.addStatusListener(_flingStatusListener);
      return;
    }

    // Dismiss if the drag is enough to scale down all the way.
    if (_lastScale == _kMinScale) {
      widget.onDismiss!(context, _lastScale, _sheetOpacityAnimation.value);
      return;
    }

    // Otherwise animate back home.
    _moveController.addListener(_moveListener);
    _moveController.reverse();
  }

  void _moveListener() {
    // When the scale passes the threshold, animate the sheet back in.
    if (_lastScale > _kSheetScaleThreshold) {
      _moveController.removeListener(_moveListener);
      if (_sheetController.status != AnimationStatus.dismissed) {
        _sheetController.reverse();
      }
    }
  }

  void _flingStatusListener(AnimationStatus status) {
    if (status != AnimationStatus.completed) {
      return;
    }

    // Reset the duration back to its original value.
    _moveController.duration = _kMoveControllerDuration;

    _moveController.removeStatusListener(_flingStatusListener);
    // If it was a fling back to the start, it has reset itself, and it should
    // not be dismissed.
    if (_moveAnimation.value.dy == 0.0) {
      return;
    }
    widget.onDismiss!(context, _lastScale, _sheetOpacityAnimation.value);
  }

  Alignment _getChildAlignment(
    Orientation orientation,
    _ContextMenuLocation contextMenuLocation,
  ) {
    switch (contextMenuLocation) {
      case _ContextMenuLocation.center:
        return orientation == Orientation.portrait
            ? Alignment.bottomCenter
            : Alignment.topRight;
      case _ContextMenuLocation.right:
        return orientation == Orientation.portrait
            ? Alignment.bottomCenter
            : Alignment.topLeft;
      case _ContextMenuLocation.left:
        return orientation == Orientation.portrait
            ? Alignment.bottomCenter
            : Alignment.topRight;
    }
  }

  void _setDragOffset(Offset dragOffset) {
    // Allow horizontal and negative vertical movement, but damp it.
    final double endX = _kPadding * dragOffset.dx / _kDamping;
    final double endY = dragOffset.dy >= 0.0
        ? dragOffset.dy
        : _kPadding * dragOffset.dy / _kDamping;
    setState(() {
      _dragOffset = dragOffset;
      _moveAnimation =
          Tween<Offset>(
            begin: Offset.zero,
            end: Offset(clampDouble(endX, -_kPadding, _kPadding), endY),
          ).animate(
            CurvedAnimation(parent: _moveController, curve: Curves.elasticIn),
          );

      // Fade the _ContextMenuSheet out or in, if needed.
      if (_lastScale <= _kSheetScaleThreshold &&
          _sheetController.status != AnimationStatus.forward &&
          _sheetScaleAnimation.value != 0.0) {
        _sheetController.forward();
      } else if (_lastScale > _kSheetScaleThreshold &&
          _sheetController.status != AnimationStatus.reverse &&
          _sheetScaleAnimation.value != 1.0) {
        _sheetController.reverse();
      }
    });
  }

  Widget _buildSettledMenuSheet(_ContextMenuLocation contextMenuLocation) {
    return AnimatedBuilder(
      animation: _sheetController,
      builder: _buildSheetAnimation,
      child: _ContextMenuSheet(
        key: widget.sheetGlobalKey,
        compactLayout: widget.previewFillsScreen,
        menuChild: IOS26ContextMenuSheet(
          actions: widget.actions!,
          onSelected: (index) {
            Navigator.of(context).pop();
            Future.microtask(widget.actions![index].onPressed);
          },
        ),
        contextMenuLocation: contextMenuLocation,
        orientation: widget.orientation,
      ),
    );
  }

  Alignment _sheetAlignmentForLocation(
    _ContextMenuLocation contextMenuLocation,
  ) {
    switch (contextMenuLocation) {
      case _ContextMenuLocation.center:
        return Alignment.topCenter;
      case _ContextMenuLocation.right:
        return Alignment.topRight;
      case _ContextMenuLocation.left:
        return Alignment.topLeft;
    }
  }

  /// Settled layout for full-screen previews (e.g. concept tiles): preview and
  /// sheet stacked at the top like the flight [Positioned.fromRect] geometry.
  /// Avoids [Expanded] splitting the column, which jumps when the menu mounts.
  List<Widget> _getChildrenFillsScreen(
    _ContextMenuLocation contextMenuLocation,
  ) {
    final Rect? target = widget.openChildTargetRect;
    final double topInset = target == null
        ? 0
        : math.max(0, target.top - MediaQuery.paddingOf(context).top);

    Widget preview = AnimatedBuilder(
      animation: _moveController,
      builder: _buildChildAnimation,
      child: widget.child,
    );
    if (topInset > 0) {
      preview = Padding(
        padding: EdgeInsets.only(top: topInset),
        child: preview,
      );
    }

    final sheet = _buildSettledMenuSheet(contextMenuLocation);

    return <Widget>[
      Align(alignment: Alignment.topCenter, child: preview),
      const SizedBox(height: _kChildMenuGap),
      Align(
        alignment: _sheetAlignmentForLocation(contextMenuLocation),
        child: sheet,
      ),
      const Spacer(),
    ];
  }

  // The order and alignment of the _ContextMenuSheet and the child depend on
  // both the orientation of the screen as well as the position on the screen of
  // the original child.
  List<Widget> _getChildren(
    Orientation orientation,
    _ContextMenuLocation contextMenuLocation,
  ) {
    if (widget.previewFillsScreen && orientation == Orientation.portrait) {
      return _getChildrenFillsScreen(contextMenuLocation);
    }

    final Expanded child = Expanded(
      child: Align(
        alignment: _getChildAlignment(
          widget.orientation,
          widget.contextMenuLocation,
        ),
        child: AnimatedBuilder(
          animation: _moveController,
          builder: _buildChildAnimation,
          child: widget.child,
        ),
      ),
    );
    const SizedBox spacer = SizedBox(width: _kPadding, height: _kPadding);
    final Expanded sheet = Expanded(
      child: _buildSettledMenuSheet(contextMenuLocation),
    );

    switch (contextMenuLocation) {
      case _ContextMenuLocation.center:
        return <Widget>[child, spacer, sheet];
      case _ContextMenuLocation.right:
        return orientation == Orientation.portrait
            ? <Widget>[child, spacer, sheet]
            : <Widget>[sheet, spacer, child];
      case _ContextMenuLocation.left:
        return <Widget>[child, spacer, sheet];
    }
  }

  // Build the animation for the _ContextMenuSheet.
  Widget _buildSheetAnimation(BuildContext context, Widget? child) {
    return Transform.scale(
      alignment: _ContextMenuRoute.getSheetAlignment(
        widget.contextMenuLocation,
      ),
      scale: _sheetScaleAnimation.value,
      child: FadeTransition(opacity: _sheetOpacityAnimation, child: child),
    );
  }

  // Build the animation for the child.
  Widget _buildChildAnimation(BuildContext context, Widget? child) {
    _lastScale = _getScale(
      widget.orientation,
      MediaQuery.sizeOf(context).height,
      _moveAnimation.value.dy,
    );
    return Transform.scale(
      key: widget.childGlobalKey,
      scale: _lastScale,
      child: child,
    );
  }

  // Build the animation for the overall draggable dismissible content.
  Widget _buildAnimation(BuildContext context, Widget? child) {
    return Transform.translate(offset: _moveAnimation.value, child: child);
  }

  @override
  void initState() {
    super.initState();
    _moveController = AnimationController(
      duration: _kMoveControllerDuration,
      value: 1.0,
      vsync: this,
    );
    _sheetController = AnimationController(
      duration: const Duration(milliseconds: 100),
      reverseDuration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _sheetScaleAnimation = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _sheetController,
        curve: Curves.linear,
        reverseCurve: Curves.easeInBack,
      ),
    );
    _sheetOpacityAnimation = Tween<double>(
      begin: 1.0,
      end: 0.0,
    ).animate(_sheetController);

    _setDragOffset(Offset.zero);
  }

  @override
  void dispose() {
    _moveController.dispose();
    _sheetController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> children = _getChildren(
      widget.orientation,
      widget.contextMenuLocation,
    );

    final bool fillsScreenPortrait =
        widget.previewFillsScreen && widget.orientation == Orientation.portrait;

    final content = SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: fillsScreenPortrait ? widget.menuSheetBottomPadding : 0,
        ),
        child: Align(
          alignment: Alignment.topLeft,
          child: GestureDetector(
            onPanEnd: _onPanEnd,
            onPanStart: _onPanStart,
            onPanUpdate: _onPanUpdate,
            child: AnimatedBuilder(
              animation: _moveController,
              builder: _buildAnimation,
              child: widget.orientation == Orientation.portrait
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: children,
                    )
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: children,
                    ),
            ),
          ),
        ),
      ),
    );

    final List<RRect> cutouts;
    if (widget.previewFillsScreen && widget.openChildTargetRect != null) {
      final preview = widget.openChildTargetRect!;
      cutouts = _dimmingCutoutsForPreview(previewRect: preview);
    } else {
      cutouts = const <RRect>[];
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        _ContextMenuDimmingOverlay(
          tintOpacity: _kSettleBackdropTintOpacity,
          cutouts: cutouts,
        ),
        content,
      ],
    );
  }
}

// The menu that displays when CupertinoContextMenu is open. It consists of a
// list of actions that are typically CupertinoContextMenuActions.
class _ContextMenuSheet extends StatelessWidget {
  const _ContextMenuSheet({
    super.key,
    required this.menuChild,
    required _ContextMenuLocation contextMenuLocation,
    required Orientation orientation,
    this.compactLayout = false,
  }) : _contextMenuLocation = contextMenuLocation,
       _orientation = orientation;

  /// The self-sized menu panel (native glass sheet when settled).
  final Widget menuChild;
  final _ContextMenuLocation _contextMenuLocation;
  final Orientation _orientation;

  /// When true, omit internal [Spacer]s so the menu stays at its measured
  /// height (matches the flight [Positioned.fromRect] sheet slot).
  final bool compactLayout;

  // Get the children, whose order depends on orientation and
  // contextMenuLocation.
  List<Widget> getChildren(BuildContext context) {
    final Widget menu = Padding(
      padding: const EdgeInsets.symmetric(horizontal: _kMenuSheetEdgeInset),
      child: menuChild,
    );

    if (compactLayout) {
      return <Widget>[SizedBox(width: _menuSheetLayoutWidth(), child: menu)];
    }

    switch (_contextMenuLocation) {
      case _ContextMenuLocation.center:
        return _orientation == Orientation.portrait
            ? <Widget>[const Spacer(), menu, const Spacer()]
            : <Widget>[menu, const Spacer()];
      case _ContextMenuLocation.right:
        return <Widget>[const Spacer(), menu];
      case _ContextMenuLocation.left:
        return <Widget>[menu, const Spacer()];
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: getChildren(context),
    );
  }
}
