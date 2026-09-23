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
        case .standard: "Обычный"
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

    // On macOS dynamicTypeSize alone is barely visible for many controls.
    // Use a native point-size baseline; never scale the whole window.
    var bodyPointSize: CGFloat {
        switch self {
        case .small: 11.5
        case .standard: 13.0
        case .large: 15.5
        case .extraLarge: 18.0
        }
    }
}

private struct AppTextSizeModifier: ViewModifier {
    let size: AppTextSize

    func body(content: Content) -> some View {
        content
            .font(.system(size: size.bodyPointSize))
            .dynamicTypeSize(size.dynamicTypeSize)
    }
}

extension View {
    func appTextSize(_ size: AppTextSize) -> some View {
        modifier(AppTextSizeModifier(size: size))
    }

    func modernMenuPicker(minWidth: CGFloat? = nil) -> some View {
        modifier(ModernMenuPickerModifier(minWidth: minWidth))
    }
}

private struct ModernMenuPickerModifier: ViewModifier {
    let minWidth: CGFloat?
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .pickerStyle(.menu)
            .tint(.primary)
            .padding(.horizontal, 10)
            .frame(minWidth: minWidth, minHeight: 34)
            .background(
                isHovered ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(
                        isHovered ? Color.accentColor.opacity(0.58) : Color.primary.opacity(0.13),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(isHovered ? 0.1 : 0.04), radius: isHovered ? 8 : 3, y: 2)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.16), value: isHovered)
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
    static let shared = AppAppearanceStore()

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
        // Keep controls and text fully opaque. Only the material backdrop fades.
        alphaValue = enabled ? windowSettings.opacity : 1
        window.alphaValue = 1
        window.hasShadow = true
    }
}

struct AppAppearanceSettingsSection: View {
    @EnvironmentObject private var language: AppLanguageStore
    @ObservedObject var store: AppAppearanceStore

    var body: some View {
        Group {
            Section(language.localized("appearance.section.theme")) {
                Picker(language.localized("appearance.theme"), selection: $store.theme) {
                    ForEach(AppTheme.allCases) { item in
                        Text(LocalizedStringKey(item.title)).tag(item)
                    }
                }
                .modernMenuPicker()
                Picker(language.localized("appearance.text_size"), selection: $store.textSize) {
                    ForEach(AppTextSize.allCases) { item in
                        Text(LocalizedStringKey(item.title)).tag(item)
                    }
                }
                .modernMenuPicker()
                Picker(language.localized("appearance.density"), selection: $store.density) {
                    ForEach(AppDensity.allCases) { item in
                        Text(LocalizedStringKey(item.title)).tag(item)
                    }
                }
                .modernMenuPicker()
                Text(language.localized("appearance.help.text_size"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(language.localized("appearance.section.window")) {
                Toggle(language.localized("appearance.transparent_window"), isOn: $store.transparencyEnabled)
                LabeledContent(language.localized("appearance.opacity")) {
                    HStack {
                        Slider(value: $store.opacity, in: 0.55...1.0, step: 0.01)
                            .frame(width: 180)
                        Text("\(store.opacityPercent)%")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                .disabled(!store.transparencyEnabled)
                Text(language.localized("appearance.help.opacity"))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

struct AppAppearanceRoot<Content: View>: View {
    @ObservedObject var store: AppAppearanceStore
    let content: Content

    init(store: AppAppearanceStore, @ViewBuilder content: () -> Content) {
        self.store = store
        self.content = content()
    }

    var body: some View {
        content
            .background {
                AppWindowBackdrop(appearance: store.snapshot)
                    .ignoresSafeArea()
            }
            .preferredColorScheme(store.theme.colorScheme)
            .appTextSize(store.textSize)
            .controlSize(store.density.controlSize)
    }
}

/// Auxiliary document-style windows must keep a visible system frame even
/// when transparency is enabled for the main workspace.
struct AppAuxiliaryWindowRoot<Content: View>: View {
    @ObservedObject private var language = AppLanguageStore.shared
    @ObservedObject var store: AppAppearanceStore
    let content: Content

    init(store: AppAppearanceStore, @ViewBuilder content: () -> Content) {
        self.store = store
        self.content = content()
    }

    var body: some View {
        content
            .id(language.selection)
            .environment(\.locale, language.locale)
            .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
            .preferredColorScheme(store.theme.colorScheme)
            .appTextSize(store.textSize)
            .controlSize(store.density.controlSize)
    }
}
