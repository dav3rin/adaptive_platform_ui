import Combine
import Flutter
import SwiftUI
import UIKit

/// Factory for the iOS 26 jobs indicator platform view.
class iOS26JobsIndicatorViewFactory: NSObject, FlutterPlatformViewFactory {
    private let messenger: FlutterBinaryMessenger

    init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
        super.init()
    }

    func create(
        withFrame frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?
    ) -> FlutterPlatformView {
        return iOS26JobsIndicatorPlatformView(
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

/// SwiftUI port of the Flutter `JobsIndicator`
/// (`lib/ui/flatland/tabs/create_tab/components/jobs_indicator.dart`).
///
/// Visual states:
///   • Idle: SF symbol (default `cloud.fill`) inside a circle, with an
///     optional count badge in the top-right corner when `count > 0`.
///   • Active: a glowing indeterminate ring with the count rendered in
///     the center. Engaged for `activeDuration` whenever the count
///     *increases* relative to the previous value, then cross-fades
///     back to idle.
///
/// Tapping anywhere on the indicator fires the `onTapped` closure
/// (forwarded to Dart via the platform-view method channel).
class iOS26JobsIndicatorPlatformView: NSObject, FlutterPlatformView {
    private let _container = UIView()
    private let _channel: FlutterMethodChannel
    private let _hosting: UIHostingController<JobsIndicatorView>
    private let _model = JobsIndicatorModel()

    init(
        frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?,
        binaryMessenger messenger: FlutterBinaryMessenger
    ) {
        let params = args as? [String: Any] ?? [:]

        let initialCount = params["count"] as? Int ?? 0
        let size = (params["size"] as? Double).map { CGFloat($0) } ?? 32
        let iconName = params["iconName"] as? String ?? "cloud.fill"
        let iconColorArgb = params["iconColor"] as? Int
        let badgeColorArgb = params["badgeColor"] as? Int
        let badgeTextColorArgb = params["badgeTextColor"] as? Int
        let backgroundColorArgb = params["backgroundColor"] as? Int
        let spinnerTextSize = (params["spinnerTextSize"] as? Double).map { CGFloat($0) } ?? 10
        let badgeTextSize = (params["badgeTextSize"] as? Double).map { CGFloat($0) } ?? 11

        _model.count = initialCount
        _model.lastCount = initialCount
        _model.size = size
        _model.spinnerTextSize = spinnerTextSize
        _model.badgeTextSize = badgeTextSize
        _model.iconName = iconName
        _model.iconColor = Color(uiColor: iconColorArgb.map { UIColor(argb: $0) } ?? UIColor.white.withAlphaComponent(0.85))
        _model.badgeColor = Color(uiColor: badgeColorArgb.map { UIColor(argb: $0) } ?? UIColor.systemBlue)
        _model.badgeTextColor = Color(uiColor: badgeTextColorArgb.map { UIColor(argb: $0) } ?? .white)
        _model.backgroundColor = Color(uiColor: backgroundColorArgb.map { UIColor(argb: $0) } ?? UIColor.black.withAlphaComponent(0.9))

        _channel = FlutterMethodChannel(
            name: "adaptive_platform_ui/ios26_jobs_indicator_\(viewId)",
            binaryMessenger: messenger
        )

        let model = _model
        let onTapped: () -> Void = { [weak _channel = _channel] in
            _channel?.invokeMethod("pressed", arguments: nil)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        _hosting = UIHostingController(rootView: JobsIndicatorView(model: model, onTapped: onTapped))
        _hosting.view.backgroundColor = .clear

        super.init()

        _container.frame = frame
        _container.backgroundColor = .clear
        _container.addSubview(_hosting.view)
        _hosting.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            _hosting.view.leadingAnchor.constraint(equalTo: _container.leadingAnchor),
            _hosting.view.trailingAnchor.constraint(equalTo: _container.trailingAnchor),
            _hosting.view.topAnchor.constraint(equalTo: _container.topAnchor),
            _hosting.view.bottomAnchor.constraint(equalTo: _container.bottomAnchor),
        ])

        _channel.setMethodCallHandler { [weak self] call, result in
            self?.handleMethodCall(call, result: result)
        }
    }

    func view() -> UIView { _container }

    private func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "setCount":
            if let args = call.arguments as? [String: Any],
               let count = args["count"] as? Int {
                _model.setCount(count)
            }
            result(nil)
        case "pulse":
            // Force the spinner state regardless of count change. Useful
            // for "I just submitted a job, but the count hasn't bumped
            // yet" scenarios.
            _model.triggerSpinner()
            result(nil)
        case "setTextSizes":
            if let args = call.arguments as? [String: Any] {
                if let spinner = args["spinnerTextSize"] as? Double {
                    _model.spinnerTextSize = CGFloat(spinner)
                }
                if let badge = args["badgeTextSize"] as? Double {
                    _model.badgeTextSize = CGFloat(badge)
                }
            }
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}

// MARK: - SwiftUI

/// Observable model the SwiftUI view renders against. Mutated from
/// the platform-view shell (`setCount`, `pulse`); SwiftUI redraws and
/// runs the appropriate transition.
final class JobsIndicatorModel: ObservableObject {
    @Published var count: Int = 0
    @Published var showSpinner: Bool = false

    var lastCount: Int = 0
    var size: CGFloat = 32
    @Published var spinnerTextSize: CGFloat = 10
    @Published var badgeTextSize: CGFloat = 11
    var iconName: String = "cloud.fill"
    var iconColor: Color = .white.opacity(0.85)
    var badgeColor: Color = .blue
    var badgeTextColor: Color = .white
    var backgroundColor: Color = .black.opacity(0.9)
    var activeDuration: TimeInterval = 5

    private var hideTask: Task<Void, Never>?

    func setCount(_ next: Int) {
        let previous = lastCount
        lastCount = next
        count = next
        if next > previous {
            triggerSpinner()
        }
    }

    func triggerSpinner() {
        hideTask?.cancel()
        showSpinner = true
        let duration = activeDuration
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard let self = self, !Task.isCancelled else { return }
            self.showSpinner = false
        }
    }
}

struct JobsIndicatorView: View {
    @ObservedObject var model: JobsIndicatorModel
    let onTapped: () -> Void

    var body: some View {
        ZStack {
            if model.showSpinner && model.count > 0 {
                SpinningState(model: model)
                    .transition(.opacity)
            } else {
                IdleState(model: model)
                    .transition(.opacity)
            }
        }
        .frame(width: model.size + 4, height: model.size + 4)
        .contentShape(Rectangle())
        .onTapGesture { onTapped() }
        .animation(.easeInOut(duration: 0.3), value: model.showSpinner)
    }
}

private struct IdleState: View {
    @ObservedObject var model: JobsIndicatorModel

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Circle()
                .fill(model.backgroundColor)
                .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
                .frame(width: model.size, height: model.size)
                .overlay(
                    Image(systemName: model.iconName)
                        .font(.system(size: model.size * 0.5, weight: .medium))
                        .foregroundStyle(model.iconColor)
                )

            if model.count > 0 {
                let badgeDiameter = max(14, model.badgeTextSize + 4)
                Text("\(model.count)")
                    .font(.system(size: model.badgeTextSize, weight: .semibold))
                    .foregroundStyle(model.badgeTextColor)
                    .frame(width: badgeDiameter, height: badgeDiameter)
                    .background(model.badgeColor, in: Circle())
                    .offset(x: 2, y: -2)
            }
        }
        .frame(width: model.size, height: model.size, alignment: .topTrailing)
    }
}

private struct SpinningState: View {
    @ObservedObject var model: JobsIndicatorModel
    @State private var rotation: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .fill(model.backgroundColor)
                .frame(width: model.size, height: model.size)

            // Comet-tail arc: gradient fades along the stroke; `.butt`
            // caps avoid a round blob at the transparent tail (`.round`
            // leaves a visible dot where the fade meets zero opacity).
            // Glow is a separate short segment so shadow doesn't pool on
            // the faded end.
            Group {
                let arcTrimEnd: CGFloat = 0.75
                let ringSize = model.size - 2

                Circle()
                    .trim(from: 0, to: arcTrimEnd)
                    .stroke(
                        AngularGradient(
                            stops: [
                                .init(color: .white.opacity(0), location: 0),
                                .init(color: .white.opacity(0), location: 0.55),
                                .init(color: .white.opacity(0.35), location: 0.68),
                                .init(color: .white, location: arcTrimEnd),
                            ],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .butt)
                    )
                    .frame(width: ringSize, height: ringSize)

                Circle()
                    .trim(from: arcTrimEnd * 0.72, to: arcTrimEnd)
                    .stroke(
                        Color.white.opacity(0.85),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .butt)
                    )
                    .frame(width: ringSize, height: ringSize)
                    .shadow(color: Color.white.opacity(0.65), radius: 2.5)
            }
            .rotationEffect(.degrees(rotation))

            Text("\(model.count)")
                .font(.system(size: model.spinnerTextSize, weight: .semibold))
                .foregroundStyle(.white)
        }
        .onAppear {
            withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }
}
