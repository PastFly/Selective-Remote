import AppKit
import Combine
import SwiftUI

struct AppWindowAppearanceSnapshot: Equatable, Sendable {
    let transparencyEnabled: Bool
    let opacity: Double
}

@MainActor
final class AppAppearanceStore: ObservableObject {
    private enum Key {
        static let transparencyEnabled = "SelectiveRemote.window.transparencyEnabled.v1"
        static let opacity = "SelectiveRemote.window.opacity.v1"
    }

    @Published var transparencyEnabled: Bool {
        didSet {
            defaults.set(transparencyEnabled, forKey: Key.transparencyEnabled)
        }
    }
    @Published var opacity: Double {
        didSet {
            defaults.set(clampedOpacity, forKey: Key.opacity)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        transparencyEnabled = defaults.bool(forKey: Key.transparencyEnabled)
        let storedOpacity = defaults.double(forKey: Key.opacity)
        opacity = storedOpacity > 0
            ? min(max(storedOpacity, 0.55), 1.0)
            : 0.88
    }

    var snapshot: AppWindowAppearanceSnapshot {
        AppWindowAppearanceSnapshot(
            transparencyEnabled: transparencyEnabled,
            opacity: clampedOpacity
        )
    }

    var opacityPercent: Int {
        Int((clampedOpacity * 100).rounded())
    }

    func reset() {
        transparencyEnabled = false
        opacity = 0.88
    }

    private var clampedOpacity: Double {
        min(max(opacity, 0.55), 1.0)
    }
}

struct AppWindowBackdrop: NSViewRepresentable {
    let appearance: AppWindowAppearanceSnapshot

    func makeNSView(context: Context) -> WindowBackdropView {
        let view = WindowBackdropView()
        view.apply(appearance)
        return view
    }

    func updateNSView(_ view: WindowBackdropView, context: Context) {
        view.apply(appearance)
    }
}

final class WindowBackdropView: NSVisualEffectView {
    // NSView already exposes `appearance: NSAppearance?`; keep the window
    // transparency state under a distinct name to avoid an accidental override.
    private var windowSettings = AppWindowAppearanceSnapshot(
        transparencyEnabled: false,
        opacity: 1
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .underWindowBackground
        blendingMode = .behindWindow
        state = .active
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        material = .underWindowBackground
        blendingMode = .behindWindow
        state = .active
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateWindow()
    }

    func apply(_ appearance: AppWindowAppearanceSnapshot) {
        windowSettings = appearance
        isHidden = !appearance.transparencyEnabled
        updateWindow()
    }

    private func updateWindow() {
        guard let window else { return }
        let enabled = windowSettings.transparencyEnabled
        window.isOpaque = !enabled
        window.backgroundColor = enabled ? .clear : .windowBackgroundColor
        window.titlebarAppearsTransparent = enabled
        window.alphaValue = enabled ? windowSettings.opacity : 1
        window.hasShadow = true
    }
}

struct AppAppearanceSettingsSection: View {
    @ObservedObject var store: AppAppearanceStore

    var body: some View {
        Section("Окно приложения") {
            Toggle("Прозрачное окно", isOn: $store.transparencyEnabled)

            LabeledContent("Непрозрачность") {
                HStack {
                    Slider(value: $store.opacity, in: 0.55...1.0, step: 0.01)
                        .frame(width: 180)
                    Text("\(store.opacityPercent)%")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }
            .disabled(!store.transparencyEnabled)

            Text(
                "Системное размытие остаётся активным. Чем меньше значение, "
                    + "тем прозрачнее всё окно вместе с текстом и кнопками."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
