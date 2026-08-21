import AppKit
import Combine
import Foundation
import SwiftUI

struct TerminalPalette: Codable, Equatable, Sendable {
    var background: String
    var foreground: String
    var cursor: String
    var cursorAccent: String
    var selectionBackground: String
    var black: String
    var red: String
    var green: String
    var yellow: String
    var blue: String
    var magenta: String
    var cyan: String
    var white: String
    var brightBlack: String
    var brightRed: String
    var brightGreen: String
    var brightYellow: String
    var brightBlue: String
    var brightMagenta: String
    var brightCyan: String
    var brightWhite: String
}

enum TerminalThemePreset: String, CaseIterable, Identifiable, Sendable {
    case midnight
    case hackerGreen
    case solarizedDark
    case dracula
    case light
    case tokyoNight
    case nord
    case oneDark
    case gruvboxDark
    case catppuccinMocha
    case monokai
    case rosePine
    case solarizedLight
    case kanagawaWave
    case kanagawaDragon
    case nightOwl
    case lightOwl
    case ayuDark
    case ayuLight
    case gruvboxLight
    case catppuccinLatte
    case tokyoDay
    case nordLight
    case cyberpunk
    case ocean
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .midnight: "Selective Dark"
        case .hackerGreen: "Hacker Green"
        case .solarizedDark: "Solarized Dark"
        case .dracula: "Dracula"
        case .light: "Selective Light"
        case .tokyoNight: "Tokyo Night"
        case .nord: "Nord"
        case .oneDark: "One Dark"
        case .gruvboxDark: "Gruvbox Dark"
        case .catppuccinMocha: "Catppuccin Mocha"
        case .monokai: "Monokai"
        case .rosePine: "Rosé Pine"
        case .solarizedLight: "Solarized Light"
        case .kanagawaWave: "Kanagawa Wave"
        case .kanagawaDragon: "Kanagawa Dragon"
        case .nightOwl: "Night Owl"
        case .lightOwl: "Light Owl"
        case .ayuDark: "Ayu Dark"
        case .ayuLight: "Ayu Light"
        case .gruvboxLight: "Gruvbox Light"
        case .catppuccinLatte: "Catppuccin Latte"
        case .tokyoDay: "Tokyo Day"
        case .nordLight: "Nord Light"
        case .cyberpunk: "Cyberpunk"
        case .ocean: "Ocean"
        case .custom: "Своя тема"
        }
    }

    var palette: TerminalPalette {
        switch self {
        case .midnight, .custom:
            TerminalPalette(
                background: "#101421",
                foreground: "#DCE6F5",
                cursor: "#36D399",
                cursorAccent: "#101421",
                selectionBackground: "#32527B99",
                black: "#101421",
                red: "#FF6B7A",
                green: "#36D399",
                yellow: "#F9C74F",
                blue: "#61AFEF",
                magenta: "#C678DD",
                cyan: "#56D4DD",
                white: "#DCE6F5",
                brightBlack: "#6F7A91",
                brightRed: "#FF8793",
                brightGreen: "#64E6B8",
                brightYellow: "#FFE08A",
                brightBlue: "#8CCBFF",
                brightMagenta: "#E0A5F3",
                brightCyan: "#88EDF2",
                brightWhite: "#FFFFFF"
            )
        case .hackerGreen:
            TerminalPalette(
                background: "#07110C",
                foreground: "#39E680",
                cursor: "#8CFFB5",
                cursorAccent: "#07110C",
                selectionBackground: "#146B3A99",
                black: "#07110C",
                red: "#FF5C68",
                green: "#39E680",
                yellow: "#D7E64A",
                blue: "#5BB7FF",
                magenta: "#C882FF",
                cyan: "#4DE8D4",
                white: "#C7F7D8",
                brightBlack: "#39754F",
                brightRed: "#FF7A84",
                brightGreen: "#8CFFB5",
                brightYellow: "#F2FF85",
                brightBlue: "#8ED0FF",
                brightMagenta: "#DEADFF",
                brightCyan: "#86FFF0",
                brightWhite: "#EEFFF4"
            )
        case .solarizedDark:
            TerminalPalette(
                background: "#002B36",
                foreground: "#839496",
                cursor: "#93A1A1",
                cursorAccent: "#002B36",
                selectionBackground: "#586E7599",
                black: "#073642",
                red: "#DC322F",
                green: "#859900",
                yellow: "#B58900",
                blue: "#268BD2",
                magenta: "#D33682",
                cyan: "#2AA198",
                white: "#EEE8D5",
                brightBlack: "#002B36",
                brightRed: "#CB4B16",
                brightGreen: "#586E75",
                brightYellow: "#657B83",
                brightBlue: "#839496",
                brightMagenta: "#6C71C4",
                brightCyan: "#93A1A1",
                brightWhite: "#FDF6E3"
            )
        case .dracula:
            TerminalPalette(
                background: "#282A36",
                foreground: "#F8F8F2",
                cursor: "#F8F8F0",
                cursorAccent: "#282A36",
                selectionBackground: "#44475A99",
                black: "#21222C",
                red: "#FF5555",
                green: "#50FA7B",
                yellow: "#F1FA8C",
                blue: "#BD93F9",
                magenta: "#FF79C6",
                cyan: "#8BE9FD",
                white: "#F8F8F2",
                brightBlack: "#6272A4",
                brightRed: "#FF6E6E",
                brightGreen: "#69FF94",
                brightYellow: "#FFFFA5",
                brightBlue: "#D6ACFF",
                brightMagenta: "#FF92DF",
                brightCyan: "#A4FFFF",
                brightWhite: "#FFFFFF"
            )
        case .light:
            TerminalPalette(
                background: "#F7F8FA",
                foreground: "#20242B",
                cursor: "#1769E0",
                cursorAccent: "#F7F8FA",
                selectionBackground: "#7CB7FF66",
                black: "#20242B",
                red: "#C62828",
                green: "#16833B",
                yellow: "#9A6700",
                blue: "#1769E0",
                magenta: "#8E3BB8",
                cyan: "#007C91",
                white: "#E9ECF1",
                brightBlack: "#68707D",
                brightRed: "#E53935",
                brightGreen: "#22A447",
                brightYellow: "#BA8100",
                brightBlue: "#3B82F6",
                brightMagenta: "#A855C7",
                brightCyan: "#0891B2",
                brightWhite: "#FFFFFF"
            )
        case .tokyoNight:
            TerminalPalette(
                background: "#1A1B26",
                foreground: "#C0CAF5",
                cursor: "#C0CAF5",
                cursorAccent: "#1A1B26",
                selectionBackground: "#33467C99",
                black: "#15161E",
                red: "#F7768E",
                green: "#9ECE6A",
                yellow: "#E0AF68",
                blue: "#7AA2F7",
                magenta: "#BB9AF7",
                cyan: "#7DCFFF",
                white: "#A9B1D6",
                brightBlack: "#414868",
                brightRed: "#F7768E",
                brightGreen: "#9ECE6A",
                brightYellow: "#E0AF68",
                brightBlue: "#7AA2F7",
                brightMagenta: "#BB9AF7",
                brightCyan: "#7DCFFF",
                brightWhite: "#C0CAF5"
            )
        case .nord:
            TerminalPalette(
                background: "#2E3440",
                foreground: "#D8DEE9",
                cursor: "#88C0D0",
                cursorAccent: "#2E3440",
                selectionBackground: "#4C566A99",
                black: "#3B4252",
                red: "#BF616A",
                green: "#A3BE8C",
                yellow: "#EBCB8B",
                blue: "#81A1C1",
                magenta: "#B48EAD",
                cyan: "#88C0D0",
                white: "#E5E9F0",
                brightBlack: "#4C566A",
                brightRed: "#BF616A",
                brightGreen: "#A3BE8C",
                brightYellow: "#EBCB8B",
                brightBlue: "#81A1C1",
                brightMagenta: "#B48EAD",
                brightCyan: "#8FBCBB",
                brightWhite: "#ECEFF4"
            )
        case .oneDark:
            TerminalPalette(
                background: "#282C34",
                foreground: "#ABB2BF",
                cursor: "#528BFF",
                cursorAccent: "#282C34",
                selectionBackground: "#3E445199",
                black: "#1E2127",
                red: "#E06C75",
                green: "#98C379",
                yellow: "#E5C07B",
                blue: "#61AFEF",
                magenta: "#C678DD",
                cyan: "#56B6C2",
                white: "#ABB2BF",
                brightBlack: "#5C6370",
                brightRed: "#E88388",
                brightGreen: "#A8D08D",
                brightYellow: "#EFD18A",
                brightBlue: "#78B9F2",
                brightMagenta: "#D291E4",
                brightCyan: "#70C3CC",
                brightWhite: "#FFFFFF"
            )
        case .gruvboxDark:
            TerminalPalette(
                background: "#282828",
                foreground: "#EBDBB2",
                cursor: "#EBDBB2",
                cursorAccent: "#282828",
                selectionBackground: "#50494599",
                black: "#282828",
                red: "#CC241D",
                green: "#98971A",
                yellow: "#D79921",
                blue: "#458588",
                magenta: "#B16286",
                cyan: "#689D6A",
                white: "#A89984",
                brightBlack: "#928374",
                brightRed: "#FB4934",
                brightGreen: "#B8BB26",
                brightYellow: "#FABD2F",
                brightBlue: "#83A598",
                brightMagenta: "#D3869B",
                brightCyan: "#8EC07C",
                brightWhite: "#EBDBB2"
            )
        case .catppuccinMocha:
            TerminalPalette(
                background: "#1E1E2E",
                foreground: "#CDD6F4",
                cursor: "#F5E0DC",
                cursorAccent: "#1E1E2E",
                selectionBackground: "#585B7099",
                black: "#45475A",
                red: "#F38BA8",
                green: "#A6E3A1",
                yellow: "#F9E2AF",
                blue: "#89B4FA",
                magenta: "#F5C2E7",
                cyan: "#94E2D5",
                white: "#BAC2DE",
                brightBlack: "#585B70",
                brightRed: "#F38BA8",
                brightGreen: "#A6E3A1",
                brightYellow: "#F9E2AF",
                brightBlue: "#89B4FA",
                brightMagenta: "#F5C2E7",
                brightCyan: "#94E2D5",
                brightWhite: "#A6ADC8"
            )
        case .monokai:
            TerminalPalette(
                background: "#272822",
                foreground: "#F8F8F2",
                cursor: "#F8F8F0",
                cursorAccent: "#272822",
                selectionBackground: "#49483E99",
                black: "#272822",
                red: "#F92672",
                green: "#A6E22E",
                yellow: "#F4BF75",
                blue: "#66D9EF",
                magenta: "#AE81FF",
                cyan: "#A1EFE4",
                white: "#F8F8F2",
                brightBlack: "#75715E",
                brightRed: "#FD5FF0",
                brightGreen: "#A6E22E",
                brightYellow: "#E6DB74",
                brightBlue: "#66D9EF",
                brightMagenta: "#AE81FF",
                brightCyan: "#A1EFE4",
                brightWhite: "#F9F8F5"
            )
        case .rosePine:
            TerminalPalette(
                background: "#191724",
                foreground: "#E0DEF4",
                cursor: "#C4A7E7",
                cursorAccent: "#191724",
                selectionBackground: "#403D5299",
                black: "#26233A",
                red: "#EB6F92",
                green: "#9CCFD8",
                yellow: "#F6C177",
                blue: "#31748F",
                magenta: "#C4A7E7",
                cyan: "#EBBCBA",
                white: "#E0DEF4",
                brightBlack: "#6E6A86",
                brightRed: "#EB6F92",
                brightGreen: "#9CCFD8",
                brightYellow: "#F6C177",
                brightBlue: "#31748F",
                brightMagenta: "#C4A7E7",
                brightCyan: "#EBBCBA",
                brightWhite: "#F0ECFE"
            )
        case .kanagawaWave:
            TerminalThemeBuiltins.kanagawaWave
        case .kanagawaDragon:
            TerminalThemeBuiltins.kanagawaDragon
        case .nightOwl:
            TerminalThemeBuiltins.nightOwl
        case .lightOwl:
            TerminalThemeBuiltins.lightOwl
        case .ayuDark:
            TerminalThemeBuiltins.ayuDark
        case .ayuLight:
            TerminalThemeBuiltins.ayuLight
        case .gruvboxLight:
            TerminalThemeBuiltins.gruvboxLight
        case .catppuccinLatte:
            TerminalThemeBuiltins.catppuccinLatte
        case .tokyoDay:
            TerminalThemeBuiltins.tokyoDay
        case .nordLight:
            TerminalThemeBuiltins.nordLight
        case .cyberpunk:
            TerminalThemeBuiltins.cyberpunk
        case .ocean:
            TerminalThemeBuiltins.ocean
        case .solarizedLight:
            TerminalPalette(
                background: "#FDF6E3",
                foreground: "#657B83",
                cursor: "#586E75",
                cursorAccent: "#FDF6E3",
                selectionBackground: "#93A1A166",
                black: "#073642",
                red: "#DC322F",
                green: "#859900",
                yellow: "#B58900",
                blue: "#268BD2",
                magenta: "#D33682",
                cyan: "#2AA198",
                white: "#EEE8D5",
                brightBlack: "#002B36",
                brightRed: "#CB4B16",
                brightGreen: "#586E75",
                brightYellow: "#657B83",
                brightBlue: "#839496",
                brightMagenta: "#6C71C4",
                brightCyan: "#93A1A1",
                brightWhite: "#FDF6E3"
            )
        }
    }
}

enum TerminalFontChoice: String, CaseIterable, Identifiable, Sendable {
    case sfMono
    case menlo
    case monaco
    case courier

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sfMono: "SF Mono"
        case .menlo: "Menlo"
        case .monaco: "Monaco"
        case .courier: "Courier New"
        }
    }

    var cssValue: String {
        switch self {
        case .sfMono: #""SF Mono", SFMono-Regular, Menlo, monospace"#
        case .menlo: #"Menlo, Monaco, monospace"#
        case .monaco: #"Monaco, Menlo, monospace"#
        case .courier: #""Courier New", Courier, monospace"#
        }
    }
}

enum TerminalCursorStyle: String, CaseIterable, Identifiable, Sendable {
    case block
    case bar
    case underline

    var id: String { rawValue }

    var title: String {
        switch self {
        case .block: "Блок"
        case .bar: "Вертикальный"
        case .underline: "Подчёркивание"
        }
    }
}

enum TerminalSyntaxScope: String, CaseIterable, Identifiable, Sendable {
    case currentLine
    case visibleCommands

    var id: String { rawValue }

    var title: String {
        switch self {
        case .currentLine: "Текущая строка"
        case .visibleCommands: "Все команды на экране"
        }
    }
}

struct TerminalSyntaxPalette: Codable, Equatable, Sendable {
    var command: String
    var option: String
    var string: String
    var path: String
    var variable: String
    var number: String
    var operation: String
    var comment: String

    init(theme: TerminalPalette) {
        command = theme.brightBlue
        option = theme.cyan
        string = theme.green
        path = theme.blue
        variable = theme.magenta
        number = theme.yellow
        operation = theme.brightMagenta
        comment = theme.brightBlack
    }
}

struct TerminalAppearanceSnapshot: Codable, Equatable, Sendable {
    let fontFamily: String
    let fontSize: Double
    let lineHeight: Double
    let cursorStyle: String
    let cursorBlink: Bool
    let syntaxHighlighting: Bool
    let syntaxScope: String
    let syntaxHistoryOpacity: Double
    let syntaxBoldCommands: Bool
    let syntaxPalette: TerminalSyntaxPalette
    let padding: Double
    let theme: TerminalPalette
}

@MainActor
final class TerminalAppearanceStore: ObservableObject {
    private enum Key {
        static let preset = "SelectiveRemote.terminal.preset.v1"
        static let palette = "SelectiveRemote.terminal.palette.v1"
        static let font = "SelectiveRemote.terminal.font.v1"
        static let fontSize = "SelectiveRemote.terminal.fontSize.v1"
        static let lineHeight = "SelectiveRemote.terminal.lineHeight.v1"
        static let cursorStyle = "SelectiveRemote.terminal.cursorStyle.v1"
        static let cursorBlink = "SelectiveRemote.terminal.cursorBlink.v1"
        static let syntaxHighlighting = "SelectiveRemote.terminal.syntaxHighlighting.v1"
        static let syntaxScope = "SelectiveRemote.terminal.syntaxScope.v1"
        static let syntaxFollowTheme = "SelectiveRemote.terminal.syntaxFollowTheme.v1"
        static let syntaxHistoryOpacity = "SelectiveRemote.terminal.syntaxHistoryOpacity.v1"
        static let syntaxBoldCommands = "SelectiveRemote.terminal.syntaxBoldCommands.v1"
        static let syntaxPalette = "SelectiveRemote.terminal.syntaxPalette.v1"
        static let padding = "SelectiveRemote.terminal.padding.v1"
        static let customPalette = "SelectiveRemote.terminal.customPalette.v1"
        static let themeFavorites = "SelectiveRemote.terminal.themeFavorites.v1"

        static let all = [
            preset, palette, font, fontSize, lineHeight, cursorStyle, cursorBlink,
            syntaxHighlighting, syntaxScope, syntaxFollowTheme, syntaxHistoryOpacity,
            syntaxBoldCommands, syntaxPalette, padding, customPalette, themeFavorites
        ]
    }

    @Published private(set) var selectedPreset: TerminalThemePreset
    @Published private(set) var palette: TerminalPalette
    @Published private(set) var favoritePresetIDs: Set<String>
    @Published var font: TerminalFontChoice {
        didSet { saveScalar(font.rawValue, key: Key.font) }
    }
    @Published var fontSize: Double {
        didSet { saveScalar(clampedFontSize, key: Key.fontSize) }
    }
    @Published var lineHeight: Double {
        didSet { saveScalar(clampedLineHeight, key: Key.lineHeight) }
    }
    @Published var cursorStyle: TerminalCursorStyle {
        didSet { saveScalar(cursorStyle.rawValue, key: Key.cursorStyle) }
    }
    @Published var cursorBlink: Bool {
        didSet { saveScalar(cursorBlink, key: Key.cursorBlink) }
    }
    @Published var syntaxHighlighting: Bool {
        didSet { saveScalar(syntaxHighlighting, key: Key.syntaxHighlighting) }
    }
    @Published var syntaxScope: TerminalSyntaxScope {
        didSet { saveScalar(syntaxScope.rawValue, key: Key.syntaxScope) }
    }
    @Published var syntaxFollowTheme: Bool {
        didSet { saveScalar(syntaxFollowTheme, key: Key.syntaxFollowTheme) }
    }
    @Published var syntaxHistoryOpacity: Double {
        didSet { saveScalar(clampedSyntaxHistoryOpacity, key: Key.syntaxHistoryOpacity) }
    }
    @Published var syntaxBoldCommands: Bool {
        didSet { saveScalar(syntaxBoldCommands, key: Key.syntaxBoldCommands) }
    }
    @Published private(set) var syntaxCustomPalette: TerminalSyntaxPalette
    @Published var padding: Double {
        didSet { saveScalar(clampedPadding, key: Key.padding) }
    }

    private let defaults: UserDefaults
    private let storageNamespace: String?
    private var customPalette: TerminalPalette

    init(
        defaults: UserDefaults = .standard,
        storageNamespace: String? = nil,
        cloneGlobalIfMissing: Bool = false
    ) {
        self.defaults = defaults
        self.storageNamespace = storageNamespace

        let resolvedKey: (String) -> String = { key in
            guard let storageNamespace, !storageNamespace.isEmpty else { return key }
            return "\(key).scope.\(storageNamespace)"
        }

        if storageNamespace != nil,
           cloneGlobalIfMissing,
           defaults.object(forKey: resolvedKey(Key.preset)) == nil {
            for key in Key.all {
                if let value = defaults.object(forKey: key) {
                    defaults.set(value, forKey: resolvedKey(key))
                }
            }
        }

        let preset = defaults.string(forKey: resolvedKey(Key.preset))
            .flatMap(TerminalThemePreset.init(rawValue:)) ?? .midnight
        let legacyPalette = defaults.data(forKey: resolvedKey(Key.palette))
            .flatMap { try? JSONDecoder().decode(TerminalPalette.self, from: $0) }
        let storedCustomPalette = defaults.data(forKey: resolvedKey(Key.customPalette))
            .flatMap { try? JSONDecoder().decode(TerminalPalette.self, from: $0) }
        let migratedCustomPalette = storedCustomPalette
            ?? (preset == .custom ? legacyPalette : nil)
            ?? TerminalThemePreset.midnight.palette

        selectedPreset = preset
        customPalette = migratedCustomPalette
        palette = preset == .custom
            ? migratedCustomPalette
            : (legacyPalette ?? preset.palette)
        favoritePresetIDs = Set(
            defaults.stringArray(forKey: resolvedKey(Key.themeFavorites)) ?? []
        )

        if storedCustomPalette == nil,
           preset == .custom,
           let data = try? JSONEncoder().encode(migratedCustomPalette) {
            defaults.set(data, forKey: resolvedKey(Key.customPalette))
        }

        font = defaults.string(forKey: resolvedKey(Key.font))
            .flatMap(TerminalFontChoice.init(rawValue:)) ?? .sfMono
        let storedFontSize = defaults.double(forKey: resolvedKey(Key.fontSize))
        fontSize = storedFontSize > 0 ? min(max(storedFontSize, 10), 28) : 14
        let storedLineHeight = defaults.double(forKey: resolvedKey(Key.lineHeight))
        lineHeight = storedLineHeight > 0 ? min(max(storedLineHeight, 1.0), 1.6) : 1.15
        cursorStyle = defaults.string(forKey: resolvedKey(Key.cursorStyle))
            .flatMap(TerminalCursorStyle.init(rawValue:)) ?? .block
        cursorBlink = defaults.object(forKey: resolvedKey(Key.cursorBlink)) as? Bool ?? true
        syntaxHighlighting = defaults.object(
            forKey: resolvedKey(Key.syntaxHighlighting)
        ) as? Bool ?? true
        syntaxScope = defaults.string(forKey: resolvedKey(Key.syntaxScope))
            .flatMap(TerminalSyntaxScope.init(rawValue:)) ?? .visibleCommands
        syntaxFollowTheme = defaults.object(
            forKey: resolvedKey(Key.syntaxFollowTheme)
        ) as? Bool ?? true
        let storedSyntaxHistoryOpacity = defaults.double(
            forKey: resolvedKey(Key.syntaxHistoryOpacity)
        )
        syntaxHistoryOpacity = storedSyntaxHistoryOpacity > 0
            ? min(max(storedSyntaxHistoryOpacity, 0.45), 1.0)
            : 0.82
        syntaxBoldCommands = defaults.object(
            forKey: resolvedKey(Key.syntaxBoldCommands)
        ) as? Bool ?? true
        syntaxCustomPalette = defaults.data(forKey: resolvedKey(Key.syntaxPalette))
            .flatMap { try? JSONDecoder().decode(TerminalSyntaxPalette.self, from: $0) }
            ?? TerminalSyntaxPalette(
                theme: preset == .custom
                    ? migratedCustomPalette
                    : (legacyPalette ?? preset.palette)
            )
        let storedPadding = defaults.double(forKey: resolvedKey(Key.padding))
        padding = defaults.object(forKey: resolvedKey(Key.padding)) == nil
            ? 10
            : min(max(storedPadding, 0), 28)
    }

    var snapshot: TerminalAppearanceSnapshot {
        TerminalAppearanceSnapshot(
            fontFamily: font.cssValue,
            fontSize: clampedFontSize,
            lineHeight: clampedLineHeight,
            cursorStyle: cursorStyle.rawValue,
            cursorBlink: cursorBlink,
            syntaxHighlighting: syntaxHighlighting,
            syntaxScope: syntaxScope.rawValue,
            syntaxHistoryOpacity: clampedSyntaxHistoryOpacity,
            syntaxBoldCommands: syntaxBoldCommands,
            syntaxPalette: effectiveSyntaxPalette,
            padding: clampedPadding,
            theme: palette
        )
    }

    var customThemePalette: TerminalPalette { customPalette }

    var effectiveSyntaxPalette: TerminalSyntaxPalette {
        syntaxFollowTheme
            ? TerminalSyntaxPalette(theme: palette)
            : syntaxCustomPalette
    }

    func applyPreset(_ preset: TerminalThemePreset) {
        if preset == .custom {
            selectedPreset = .custom
            palette = customPalette
            savePresetAndPalette()
            return
        }
        selectedPreset = preset
        palette = preset.palette
        savePresetAndPalette()
    }

    func isFavorite(_ preset: TerminalThemePreset) -> Bool {
        favoritePresetIDs.contains(preset.rawValue)
    }

    func toggleFavorite(_ preset: TerminalThemePreset) {
        if favoritePresetIDs.contains(preset.rawValue) {
            favoritePresetIDs.remove(preset.rawValue)
        } else {
            favoritePresetIDs.insert(preset.rawValue)
        }
        defaults.set(favoritePresetIDs.sorted(), forKey: storageKey(Key.themeFavorites))
    }

    func updateBackground(_ value: String) {
        guard let hex = TerminalColorCodec.normalizedHex(value) else { return }
        updatePalette {
            $0.background = hex
            $0.cursorAccent = hex
        }
    }

    func updateForeground(_ value: String) {
        guard let hex = TerminalColorCodec.normalizedHex(value) else { return }
        updatePalette { $0.foreground = hex }
    }

    func updateCursor(_ value: String) {
        guard let hex = TerminalColorCodec.normalizedHex(value) else { return }
        updatePalette { $0.cursor = hex }
    }

    func reset() {
        font = .sfMono
        fontSize = 14
        lineHeight = 1.15
        cursorStyle = .block
        cursorBlink = true
        syntaxHighlighting = true
        syntaxScope = .visibleCommands
        syntaxFollowTheme = true
        syntaxHistoryOpacity = 0.82
        syntaxBoldCommands = true
        syntaxCustomPalette = TerminalSyntaxPalette(
            theme: TerminalThemePreset.midnight.palette
        )
        saveSyntaxPalette()
        padding = 10
        customPalette = TerminalThemePreset.midnight.palette
        saveCustomPalette()
        applyPreset(.midnight)
    }

    func copySettings(from source: TerminalAppearanceStore) {
        selectedPreset = source.selectedPreset
        palette = source.palette
        customPalette = source.customThemePalette
        favoritePresetIDs = source.favoritePresetIDs
        font = source.font
        fontSize = source.fontSize
        lineHeight = source.lineHeight
        cursorStyle = source.cursorStyle
        cursorBlink = source.cursorBlink
        syntaxHighlighting = source.syntaxHighlighting
        syntaxScope = source.syntaxScope
        syntaxFollowTheme = source.syntaxFollowTheme
        syntaxHistoryOpacity = source.syntaxHistoryOpacity
        syntaxBoldCommands = source.syntaxBoldCommands
        syntaxCustomPalette = source.syntaxCustomPalette
        padding = source.padding
        saveCustomPalette()
        saveSyntaxPalette()
        savePresetAndPalette()
        defaults.set(
            favoritePresetIDs.sorted(),
            forKey: storageKey(Key.themeFavorites)
        )
    }

    func updateSyntaxColor(
        _ keyPath: WritableKeyPath<TerminalSyntaxPalette, String>,
        _ value: String
    ) {
        guard let hex = TerminalColorCodec.normalizedHex(value) else { return }
        var changed = syntaxCustomPalette
        changed[keyPath: keyPath] = hex
        syntaxCustomPalette = changed
        saveSyntaxPalette()
    }

    func resetSyntaxPaletteToTheme() {
        syntaxCustomPalette = TerminalSyntaxPalette(theme: palette)
        saveSyntaxPalette()
    }

    private var clampedFontSize: Double { min(max(fontSize, 10), 28) }
    private var clampedLineHeight: Double { min(max(lineHeight, 1.0), 1.6) }
    private var clampedSyntaxHistoryOpacity: Double {
        min(max(syntaxHistoryOpacity, 0.45), 1.0)
    }
    private var clampedPadding: Double { min(max(padding, 0), 28) }

    private func updatePalette(_ update: (inout TerminalPalette) -> Void) {
        var changed = palette
        update(&changed)
        palette = changed
        customPalette = changed
        selectedPreset = .custom
        saveCustomPalette()
        savePresetAndPalette()
    }

    private func saveCustomPalette() {
        if let data = try? JSONEncoder().encode(customPalette) {
            defaults.set(data, forKey: storageKey(Key.customPalette))
        }
    }

    private func saveSyntaxPalette() {
        if let data = try? JSONEncoder().encode(syntaxCustomPalette) {
            defaults.set(data, forKey: storageKey(Key.syntaxPalette))
        }
    }

    private func savePresetAndPalette() {
        defaults.set(selectedPreset.rawValue, forKey: storageKey(Key.preset))
        if let data = try? JSONEncoder().encode(palette) {
            defaults.set(data, forKey: storageKey(Key.palette))
        }
    }

    private func saveScalar(_ value: Any, key: String) {
        defaults.set(value, forKey: storageKey(key))
    }

    private func storageKey(_ key: String) -> String {
        guard let storageNamespace, !storageNamespace.isEmpty else { return key }
        return "\(key).scope.\(storageNamespace)"
    }
}

struct TerminalAppearanceView: View {
    @EnvironmentObject private var language: AppLanguageStore
    @ObservedObject var store: TerminalAppearanceStore
    @ObservedObject var appAppearance: AppAppearanceStore
    var includesApplicationSettings = true
    var individualTitle: String? = nil
    var copyFrom: TerminalAppearanceStore? = nil

    var body: some View {
        Form {
            if let individualTitle {
                Section("Индивидуальное оформление") {
                    Label(individualTitle, systemImage: "rectangle.inset.filled.and.person.filled")
                        .font(.headline)
                    Text("Тема, шрифт, курсор, подсветка синтаксиса и своя палитра сохраняются только для этой вкладки терминала.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let copyFrom {
                        Button("Скопировать общее оформление", systemImage: "square.on.square") {
                            store.copySettings(from: copyFrom)
                        }
                    }
                }
            }

            if includesApplicationSettings {
            Section("Язык приложения") {
                Picker("Язык", selection: $language.selection) {
                    ForEach(AppLanguage.allCases) { item in
                        Text(LocalizedStringKey(item.title)).tag(item)
                    }
                }
                Text("Интерфейс переключается сразу. Системный режим использует язык macOS.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            AppAppearanceSettingsSection(store: appAppearance)
            }

            Section("Терминал") {
                TerminalThemeSelector(store: store)

                DisclosureGroup("Шрифт и курсор") {
                    Picker("Шрифт", selection: $store.font) {
                    ForEach(TerminalFontChoice.allCases) { font in
                        Text(font.title).tag(font)
                    }
                }

                LabeledContent("Размер") {
                    HStack {
                        Slider(value: $store.fontSize, in: 10...28, step: 1)
                            .frame(width: 180)
                        Text("\(Int(store.fontSize)) pt")
                            .monospacedDigit()
                            .frame(width: 42, alignment: .trailing)
                    }
                }

                LabeledContent("Межстрочный интервал") {
                    HStack {
                        Slider(value: $store.lineHeight, in: 1.0...1.6, step: 0.05)
                            .frame(width: 180)
                        Text(store.lineHeight.formatted(.number.precision(.fractionLength(2))))
                            .monospacedDigit()
                            .frame(width: 42, alignment: .trailing)
                    }
                }

                Picker("Курсор", selection: $store.cursorStyle) {
                    ForEach(TerminalCursorStyle.allCases) { style in
                        Text(LocalizedStringKey(style.title)).tag(style)
                    }
                }
                Toggle("Мигающий курсор", isOn: $store.cursorBlink)

                LabeledContent("Внутренний отступ") {
                    HStack {
                        Slider(value: $store.padding, in: 0...28, step: 1)
                            .frame(width: 180)
                        Text("\(Int(store.padding)) px")
                            .monospacedDigit()
                            .frame(width: 42, alignment: .trailing)
                    }
                }
                }

                DisclosureGroup("Подсветка синтаксиса") {
                    Toggle("Подсветка команд", isOn: $store.syntaxHighlighting)

                    Picker("Область", selection: $store.syntaxScope) {
                        ForEach(TerminalSyntaxScope.allCases) { scope in
                            Text(scope.title).tag(scope)
                        }
                    }

                    Toggle("Цвета из темы", isOn: $store.syntaxFollowTheme)
                    Toggle("Выделять команды жирным", isOn: $store.syntaxBoldCommands)

                    LabeledContent("Предыдущие команды") {
                        HStack {
                            Slider(
                                value: $store.syntaxHistoryOpacity,
                                in: 0.45...1.0,
                                step: 0.05
                            )
                            .frame(width: 150)
                            Text("\(Int(store.syntaxHistoryOpacity * 100))%")
                                .monospacedDigit()
                                .frame(width: 42, alignment: .trailing)
                        }
                    }

                    if !store.syntaxFollowTheme {
                        Divider()

                        TerminalColorControl(
                            title: "Команда",
                            value: Binding(
                                get: { store.syntaxCustomPalette.command },
                                set: { store.updateSyntaxColor(\.command, $0) }
                            )
                        )
                        TerminalColorControl(
                            title: "Параметр",
                            value: Binding(
                                get: { store.syntaxCustomPalette.option },
                                set: { store.updateSyntaxColor(\.option, $0) }
                            )
                        )
                        TerminalColorControl(
                            title: "Строка",
                            value: Binding(
                                get: { store.syntaxCustomPalette.string },
                                set: { store.updateSyntaxColor(\.string, $0) }
                            )
                        )
                        TerminalColorControl(
                            title: "Путь",
                            value: Binding(
                                get: { store.syntaxCustomPalette.path },
                                set: { store.updateSyntaxColor(\.path, $0) }
                            )
                        )
                        TerminalColorControl(
                            title: "Переменная",
                            value: Binding(
                                get: { store.syntaxCustomPalette.variable },
                                set: { store.updateSyntaxColor(\.variable, $0) }
                            )
                        )
                        TerminalColorControl(
                            title: "Число",
                            value: Binding(
                                get: { store.syntaxCustomPalette.number },
                                set: { store.updateSyntaxColor(\.number, $0) }
                            )
                        )
                        TerminalColorControl(
                            title: "Оператор",
                            value: Binding(
                                get: { store.syntaxCustomPalette.operation },
                                set: { store.updateSyntaxColor(\.operation, $0) }
                            )
                        )
                        TerminalColorControl(
                            title: "Комментарий",
                            value: Binding(
                                get: { store.syntaxCustomPalette.comment },
                                set: { store.updateSyntaxColor(\.comment, $0) }
                            )
                        )

                        HStack {
                            Spacer()
                            Button("Сбросить цвета к текущей теме") {
                                store.resetSyntaxPaletteToTheme()
                            }
                        }
                    }

                    Text(
                        store.syntaxScope == .visibleCommands
                            ? "Подсвечиваются shell-команды в видимой области. Вывод сервера и его ANSI-цвета не изменяются."
                            : "Подсвечивается только текущая shell-команда. Вывод сервера и его ANSI-цвета не изменяются."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                DisclosureGroup("Своя тема") {
                    TerminalColorControl(
                    title: "Фон",
                    value: Binding(
                        get: { store.palette.background },
                        set: { store.updateBackground($0) }
                    )
                )
                TerminalColorControl(
                    title: "Текст",
                    value: Binding(
                        get: { store.palette.foreground },
                        set: { store.updateForeground($0) }
                    )
                )
                TerminalColorControl(
                    title: "Курсор",
                    value: Binding(
                        get: { store.palette.cursor },
                        set: { store.updateCursor($0) }
                    )
                )
                }
            }

            HStack {
                Spacer()
                Button("Сбросить оформление") {
                    store.reset()
                    if includesApplicationSettings {
                        appAppearance.reset()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(12)
        .frame(width: 430, height: 640)
    }
}

private struct TerminalColorControl: View {
    let title: String
    @Binding var value: String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Text(value.uppercased())
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                TerminalColorWell(value: $value)
                    .frame(width: 44, height: 24)
            }
        }
    }
}

private struct TerminalColorWell: NSViewRepresentable {
    @Binding var value: String

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value)
    }

    func makeNSView(context: Context) -> NSColorWell {
        let well = NSColorWell(frame: .zero)
        well.isBordered = true
        well.color = TerminalColorCodec.nsColor(value)
        well.target = context.coordinator
        well.action = #selector(Coordinator.colorChanged(_:))
        return well
    }

    func updateNSView(_ well: NSColorWell, context: Context) {
        context.coordinator.value = $value
        well.color = TerminalColorCodec.nsColor(value)
    }

    final class Coordinator: NSObject {
        var value: Binding<String>

        init(value: Binding<String>) {
            self.value = value
        }

        @MainActor @objc func colorChanged(_ sender: NSColorWell) {
            value.wrappedValue = TerminalColorCodec.hex(sender.color)
        }
    }
}

enum TerminalColorCodec {
    static func normalizedHex(_ hex: String) -> String? {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard cleaned.count == 6,
              let value = UInt64(cleaned, radix: 16)
        else { return nil }
        return String(format: "#%06llX", value)
    }

    static func nsColor(_ hex: String) -> NSColor {
        guard let normalized = normalizedHex(hex),
              let value = UInt64(normalized.dropFirst(), radix: 16)
        else { return .white }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    static func hex(_ color: NSColor) -> String {
        guard let converted = color.usingColorSpace(.sRGB) else {
            return "#FFFFFF"
        }
        let red = Int((converted.redComponent * 255).rounded())
        let green = Int((converted.greenComponent * 255).rounded())
        let blue = Int((converted.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}
