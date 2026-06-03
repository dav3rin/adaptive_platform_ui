import Flutter
import UIKit

/// Main plugin class for Adaptive Platform UI
/// Registers platform views and handles plugin lifecycle
public class AdaptivePlatformUiPlugin: NSObject, FlutterPlugin {

    public static func register(with registrar: FlutterPluginRegistrar) {
        // Initialize iOS 26+ Native Tab Bar Manager
        if #available(iOS 26.0, *) {
            iOS26NativeTabBarManager.shared.setup(messenger: registrar.messenger())
        }

        // Register iOS 26 Button platform view factory
        let ios26ButtonFactory = iOS26ButtonViewFactory(messenger: registrar.messenger())
        registrar.register(
            ios26ButtonFactory,
            withId: "adaptive_platform_ui/ios26_button"
        )

        // Register iOS 26 Switch platform view factory
        let ios26SwitchFactory = iOS26SwitchViewFactory(messenger: registrar.messenger())
        registrar.register(
            ios26SwitchFactory,
            withId: "adaptive_platform_ui/ios26_switch"
        )

        // Register iOS 26 Slider platform view factory
        let ios26SliderFactory = iOS26SliderViewFactory(messenger: registrar.messenger())
        registrar.register(
            ios26SliderFactory,
            withId: "adaptive_platform_ui/ios26_slider"
        )

        // Register iOS 26 SegmentedControl platform view factory
        let ios26SegmentedControlFactory = iOS26SegmentedControlViewFactory(messenger: registrar.messenger())
        registrar.register(
            ios26SegmentedControlFactory,
            withId: "adaptive_platform_ui/ios26_segmented_control"
        )

        // Register iOS 26 AlertDialog platform view factory
        let ios26AlertDialogFactory = iOS26AlertDialogViewFactory(messenger: registrar.messenger())
        registrar.register(
            ios26AlertDialogFactory,
            withId: "adaptive_platform_ui/ios26_alert_dialog"
        )

        // Register iOS 26 PopupMenuButton platform view factory
        let ios26PopupMenuButtonFactory = iOS26PopupMenuButtonViewFactory(messenger: registrar.messenger())
        registrar.register(
            ios26PopupMenuButtonFactory,
            withId: "adaptive_platform_ui/ios26_popup_menu_button"
        )

        // Register iOS 26 ContextMenu Sheet platform view factory.
        // Native glass options panel embedded in a Flutter-driven lift route
        // (the real UIMenu can't be presented programmatically). See
        // [iOS26ContextMenuSheetView.swift].
        let ios26ContextMenuSheetFactory = iOS26ContextMenuSheetViewFactory(messenger: registrar.messenger())
        registrar.register(
            ios26ContextMenuSheetFactory,
            withId: "adaptive_platform_ui/ios26_context_menu_sheet"
        )

        // Register iOS 26 TabBar platform view factory
        let ios26TabBarFactory = iOS26TabBarViewFactory(messenger: registrar.messenger())
        registrar.register(
            ios26TabBarFactory,
            withId: "adaptive_platform_ui/ios26_tab_bar"
        )

        // Register iOS 26 Toolbar platform view factory
        let ios26ToolbarFactory = iOS26ToolbarFactory(messenger: registrar.messenger())
        registrar.register(
            ios26ToolbarFactory,
            withId: "adaptive_platform_ui/ios26_toolbar"
        )

        // Register iOS 26 Blur View platform view factory
        let ios26BlurViewFactory = iOS26BlurViewFactory(messenger: registrar.messenger())
        registrar.register(
            ios26BlurViewFactory,
            withId: "adaptive_platform_ui/ios26_blur_view"
        )

        // Register iOS 26 Glass Input Bar platform view factory.
        // Pill-shaped UITextField inside a UIGlassEffect / UIVisualEffectView
        // with a leading SF symbol button (e.g. `plus`). See
        // [iOS26GlassInputBar.swift] for the method-channel API.
        let ios26GlassInputBarFactory = iOS26GlassInputBarFactory(messenger: registrar.messenger())
        registrar.register(
            ios26GlassInputBarFactory,
            withId: "adaptive_platform_ui/ios26_glass_input_bar"
        )

        // Register iOS 26 Jobs Indicator platform view factory.
        // SwiftUI cloud/spinner that pulses for 5s when its count
        // increases. See [iOS26JobsIndicatorView.swift].
        let ios26JobsIndicatorFactory = iOS26JobsIndicatorViewFactory(messenger: registrar.messenger())
        registrar.register(
            ios26JobsIndicatorFactory,
            withId: "adaptive_platform_ui/ios26_jobs_indicator"
        )
    }
}
