import 'package:flutter/services.dart';

/// iOS 26+ Native Tab Bar with Search Support
///
/// This widget enables the native iOS 26 tab bar with search functionality.
/// When enabled, it replaces the Flutter app's root with a native UITabBarController.
///
/// **Important**: This is an experimental API and may significantly impact your app's
/// navigation structure. Use with caution.
///
/// Example:
/// ```dart
/// @override
/// void initState() {
///   super.initState();
///   IOS26NativeSearchTabBar.enable(
///     tabs: [
///       NativeTabConfig(title: 'Home', sfSymbol: 'house.fill'),
///       NativeTabConfig(title: 'Search', sfSymbol: 'magnifyingglass', isSearchTab: true),
///       NativeTabConfig(title: 'Profile', sfSymbol: 'person.fill'),
///     ],
///     onTabSelected: (index) {
///       print('Tab selected: $index');
///     },
///     onSearchQueryChanged: (query) {
///       print('Search query: $query');
///     },
///   );
/// }
/// ```
class IOS26NativeSearchTabBar {
  static const MethodChannel _channel = MethodChannel(
    'adaptive_platform_ui/native_tab_bar',
  );

  static bool _isEnabled = false;

  /// Enable native tab bar mode
  ///
  /// This will replace your app's root view controller with a native
  /// UITabBarController. Your Flutter content will be displayed within
  /// the selected tab.
  static Future<void> enable({
    required List<NativeTabConfig> tabs,
    int selectedIndex = 0,
    void Function(int index)? onTabSelected,
    void Function(String query)? onSearchQueryChanged,
    void Function(String query)? onSearchSubmitted,
    VoidCallback? onSearchCancelled,
    VoidCallback? onSearchActivated,
    VoidCallback? onSearchDeactivated,
  }) async {
    final nativeEnabled = await isEnabled();
    if (_isEnabled && nativeEnabled) {
      return;
    }
    // Hot restart / failed prior enable can leave Dart and native out of sync.
    _isEnabled = false;

    // Setup method call handler for callbacks
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onTabSelected':
          final index = call.arguments['index'] as int;
          onTabSelected?.call(index);
          break;
        case 'onSearchQueryChanged':
          final query = call.arguments['query'] as String;
          onSearchQueryChanged?.call(query);
          break;
        case 'onSearchSubmitted':
          final query = call.arguments['query'] as String;
          onSearchSubmitted?.call(query);
          break;
        case 'onSearchCancelled':
          onSearchCancelled?.call();
          break;
        case 'onSearchActivated':
          onSearchActivated?.call();
          break;
        case 'onSearchDeactivated':
          onSearchDeactivated?.call();
          break;
      }
    });

    // Enable native tab bar
    await _channel.invokeMethod('enableNativeTabBar', {
      'tabs': tabs
          .map(
            (tab) => {
              'title': tab.title,
              'sfSymbol': tab.sfSymbol,
              'isSearch': tab.isSearchTab,
            },
          )
          .toList(),
      'selectedIndex': selectedIndex,
    });

    _isEnabled = true;
  }

  /// Disable native tab bar and return to Flutter-only mode.
  ///
  /// Pass [force: true] when hiding due to navigation cover so the native
  /// overlay is removed even if Dart's `_isEnabled` flag is out of sync or
  /// an in-flight `enable()` has not finished yet.
  static Future<void> disable({bool force = false}) async {
    if (!force && !_isEnabled) {
      return;
    }

    final nativeEnabled = force || _isEnabled || await isEnabled();
    if (nativeEnabled) {
      await _channel.invokeMethod('disableNativeTabBar');
    }
    _isEnabled = false;
  }

  /// Set the selected tab index
  static Future<void> setSelectedIndex(int index) async {
    await _channel.invokeMethod('setSelectedIndex', {'index': index});
  }

  /// Animate the native tab bar overlay's alpha (and a subtle glass
  /// dissolve / slide on the tab bar pill itself) without tearing down
  /// the underlying `UITabBarController`.
  ///
  /// Uses `UIViewPropertyAnimator` on the native side so the iOS 26
  /// liquid-glass material interpolates instead of popping.
  ///
  /// Use this to keep the bar's appearance/disappearance in sync with
  /// Flutter route transitions (full [disable]/[enable] looks abrupt
  /// because it tears down and rebuilds the native VC hierarchy).
  ///
  /// [delay] is a head-start the Flutter route push gets before the
  /// bar starts fading out — set to ~50ms when hiding so the bar
  /// doesn't vanish before the new route's content begins sliding in.
  static Future<void> setHidden(
    bool hidden, {
    bool animated = true,
    Duration duration = const Duration(milliseconds: 240),
    Duration delay = Duration.zero,
  }) async {
    await _channel.invokeMethod('setOverlayHidden', {
      'hidden': hidden,
      'animated': animated,
      'durationMs': duration.inMilliseconds,
      'delayMs': delay.inMilliseconds,
    });
  }

  /// Show the search bar (activates the search controller)
  static Future<void> showSearch() async {
    await _channel.invokeMethod('showSearch');
  }

  /// Hide the search bar
  static Future<void> hideSearch() async {
    await _channel.invokeMethod('hideSearch');
  }

  /// Check if native tab bar is currently enabled
  static Future<bool> isEnabled() async {
    try {
      final result = await _channel.invokeMethod<bool>('isEnabled');
      return result ?? false;
    } catch (e) {
      return false;
    }
  }
}

/// Configuration for a native tab
class NativeTabConfig {
  /// The title of the tab
  final String title;

  /// SF Symbol name for the tab icon (iOS only)
  final String? sfSymbol;

  /// Whether this tab is a search tab
  ///
  /// Only one tab should be marked as a search tab.
  /// When selected, the tab bar will transform into a search bar on iOS 26+.
  final bool isSearchTab;

  const NativeTabConfig({
    required this.title,
    this.sfSymbol,
    this.isSearchTab = false,
  });
}
