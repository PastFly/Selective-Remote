import AppKit
import Combine
import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case russian
    case english

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Системный"
        case .russian: "Русский"
        case .english: "English"
        }
    }

    var locale: Locale {
        switch self {
        case .system: .current
        case .russian: Locale(identifier: "ru")
        case .english: Locale(identifier: "en")
        }
    }

    var usesEnglish: Bool {
        switch self {
        case .english: true
        case .russian: false
        case .system:
            Locale.preferredLanguages.first?.lowercased().hasPrefix("en") == true
        }
    }
}

@MainActor
final class AppLanguageStore: ObservableObject {
    static let shared = AppLanguageStore()
    private static let storageKey = "SelectiveRemote.applicationLanguage.v1"

    @Published var selection: AppLanguage {
        didSet {
            defaults.set(selection.rawValue, forKey: Self.storageKey)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selection = AppLanguage(
            rawValue: defaults.string(forKey: Self.storageKey) ?? ""
        ) ?? .system
    }

    var locale: Locale { selection.locale }

    func localized(_ key: String) -> String {
        UpdateLocalization.key(key, english: selection.usesEnglish)
    }
}

/// Native menu titles are created by AppKit from the process language, not from
/// SwiftUI's per-window locale. Keep titles in sync without replacing commands,
/// key equivalents, targets, or enabled states.
@MainActor
enum RuntimeMenuLocalization {
    private static var currentLanguage: AppLanguage = .system
    private static var menuUpdateObserver: NSObjectProtocol?

    static let nativeTitles: [(ru: String, en: String)] = [
        ("Файл", "File"), ("Правка", "Edit"), ("Вид", "View"),
        ("Окно", "Window"), ("Справка", "Help"),
        ("Сессия", "Session"),
        ("Закрыть", "Close"), ("Закрыть окно", "Close Window"),
        ("Новый", "New"), ("Открыть…", "Open…"), ("Сохранить", "Save"),
        ("Отменить", "Undo"), ("Повторить", "Redo"),
        ("Вырезать", "Cut"), ("Копировать", "Copy"),
        ("Вставить", "Paste"), ("Выбрать всё", "Select All"),
        ("Найти", "Find"), ("Найти далее", "Find Next"),
        ("Показать панель инструментов", "Show Toolbar"),
        ("Скрыть панель инструментов", "Hide Toolbar"),
        ("Настроить панель инструментов…", "Customize Toolbar…"),
        ("Перейти в полноэкранный режим", "Enter Full Screen"),
        ("Выйти из полноэкранного режима", "Exit Full Screen"),
        ("Свернуть", "Minimize"), ("Масштабировать", "Zoom"),
        ("Развернуть все окна", "Bring All to Front"),
        ("Поиск", "Search"), ("Настройки…", "Settings…"),
        ("Службы", "Services"), ("Скрыть Selective Remote", "Hide Selective Remote"),
        ("Скрыть остальные", "Hide Others"), ("Показать все", "Show All"),
        ("Завершить Selective Remote", "Quit Selective Remote")
    ]

    static func apply(to menu: NSMenu, language: AppLanguage) {
        let pairs = nativeTitles + AppCopy.translations
            .filter { $0.key.hasPrefix("menu.") || $0.key == "help.support.title" }
            .map(\.value)
        let isSessionMenu = ["Session", "Сессия", "Сеанс"].contains(menu.title)
        for item in menu.items {
            if item.title == "Cloud" { continue }
            // A Session submenu title is a user-supplied profile name, even if
            // it happens to equal a built-in title such as "File".
            if !(isSessionMenu && item.submenu != nil),
               let pair = pairs.first(where: { $0.ru == item.title || $0.en == item.title }) {
                item.title = language.usesEnglish ? pair.en :
                    (pair.en == "Session" ? "Сеанс" : pair.ru)
            }
            if let submenu = item.submenu {
                apply(to: submenu, language: language)
                submenu.title = item.title
            }
        }
    }

    static func refresh(_ language: AppLanguage) {
        currentLanguage = language
        if menuUpdateObserver == nil {
            menuUpdateObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didUpdateNotification,
                object: NSApplication.shared,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    guard let menu = NSApplication.shared.mainMenu else { return }
                    apply(to: menu, language: currentLanguage)
                }
            }
        }
        // SwiftUI may rebuild Commands after the selection changes. Apply to
        // the resulting NSMenu on the next main run-loop turn.
        DispatchQueue.main.async {
            guard let menu = NSApplication.shared.mainMenu else { return }
            apply(to: menu, language: language)
            (NSApplication.shared.delegate as? SelectiveRemoteApplicationDelegate)?
                .refreshAuxiliaryTitles()
        }
    }
}

struct AppRuntimeLanguageObserver: View {
    @EnvironmentObject private var language: AppLanguageStore

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onAppear { RuntimeMenuLocalization.refresh(language.selection) }
            .onChange(of: language.selection) { _, newValue in
                RuntimeMenuLocalization.refresh(newValue)
                UpdateReleaseNotesWindowController.shared.refreshLanguageIfPresented()
            }
    }
}
