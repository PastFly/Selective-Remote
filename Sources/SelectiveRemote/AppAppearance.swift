import AppKit
import Combine
import SwiftUI

struct AppWindowAppearanceSnapshot: Equatable, Sendable {
    let transparencyEnabled: Bool
    let opacity: Double
}

enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "Системная"
        case .light: "Светлая"
        case .dark: "Тёмная"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum AppTextSize: String, CaseIterable, Identifiable, Sendable {
    case small
    case standard
    case large
    case extraLarge

    var id: String { rawValue }
    var title: String {
        switch self {
        case .small: "Маленький"
        case .standard: "По умолчанию"
        case .large: "Большой"
        case .extraLarge: "Очень большой"
        }
    }
    var dynamicTypeSize: DynamicTypeSize {
        switch self {
        case .small: .small
        case .standard: .medium
        case .large: .large
        case .extraLarge: .xxLarge
        }
    }
}

enum AppDensity: String, CaseIterable, Identifiable, Sendable {
    case compact
    case standard
    case comfortable

    var id: String { rawValue }
    var title: String {
        switch self {
        case .compact: "Компактная"
        case .standard: "Стандартная"
        case .comfortable: "Комфортная"
        }
    }
    var controlSize: ControlSize {
        switch self {
        case .compact: .small
        case .standard: .regular
        case .comfortable: .large
        }
    }
}

@MainActor
final class AppAppearanceStore: ObservableObject {
    private enum Key {
        static let transparencyEnabled = "SelectiveRemote.window.transparencyEnabled.v1"
        static let opacity = "SelectiveRemote.window.opacity.v1"
        static let appTheme = "SelectiveRemote.appearance.theme.v1"
        static let textSize = "SelectiveRemote.appearance.textSize.v1"
        static let density = "SelectiveRemote.appearance.density.v1"
    }

    @Published var transparencyEnabled: Bool {
        didSet { defaults.set(transparencyEnabled, forKey: Key.transparencyEnabled) }
    }
    @Published var opacity: Double {
        didSet { defaults.set(clampedOpacity, forKey: Key.opacity) }
    }
    @Published var theme: AppTheme {
        didSet { defaults.set(theme.rawValue, forKey: Key.appTheme) }
    }
    @Published var textSize: AppTextSize {
        didSet { defaults.set(textSize.rawValue, forKey: Key.textSize) }
    }
    @Published var density: AppDensity {
        didSet { defaults.set(density.rawValue, forKey: Key.density) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        transparencyEnabled = defaults.bool(forKey: Key.transparencyEnabled)
        let storedOpacity = defaults.double(forKey: Key.opacity)
        opacity = storedOpacity > 0 ? min(max(storedOpacity, 0.55), 1.0) : 0.88
        theme = AppTheme(rawValue: defaults.string(forKey: Key.appTheme) ?? "") ?? .system
        textSize = AppTextSize(rawValue: defaults.string(forKey: Key.textSize) ?? "") ?? .standard
        density = AppDensity(rawValue: defaults.string(forKey: Key.density) ?? "") ?? .standard
    }

    var snapshot: AppWindowAppearanceSnapshot {
        AppWindowAppearanceSnapshot(
            transparencyEnabled: transparencyEnabled,
            opacity: clampedOpacity
        )
    }

    var opacityPercent: Int { Int((clampedOpacity * 100).rounded()) }

    func reset() {
        theme = .system
        textSize = .standard
        density = .standard
        transparencyEnabled = false
        opacity = 0.88
    }

    private var clampedOpacity: Double { min(max(opacity, 0.55), 1.0) }
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
        Group {
            Section("Внешний вид") {
                Picker("Тема приложения", selection: $store.theme) {
                    ForEach(AppTheme.allCases) { item in
                        Text(LocalizedStringKey(item.title)).tag(item)
                    }
                }
                Picker("Размер текста", selection: $store.textSize) {
                    ForEach(AppTextSize.allCases) { item in
                        Text(LocalizedStringKey(item.title)).tag(item)
                    }
                }
                Picker("Плотность интерфейса", selection: $store.density) {
                    ForEach(AppDensity.allCases) { item in
                        Text(LocalizedStringKey(item.title)).tag(item)
                    }
                }
                Text("Масштаб меняет native-размер текста и элементов управления. Retina/DPI macOS остаётся системным.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
}
