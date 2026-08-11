import Combine
import Foundation

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
}

@MainActor
final class AppLanguageStore: ObservableObject {
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
}
