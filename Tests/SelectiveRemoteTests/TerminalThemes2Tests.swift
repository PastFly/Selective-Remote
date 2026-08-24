import Foundation
import Testing
@testable import SelectiveRemote

@Test("Terminal Themes 2.0 сохраняет старые raw identifiers")
func terminalThemeLegacyIdentifiersRemainStable() {
    #expect(TerminalThemePreset.midnight.rawValue == "midnight")
    #expect(TerminalThemePreset.hackerGreen.rawValue == "hackerGreen")
    #expect(TerminalThemePreset.solarizedDark.rawValue == "solarizedDark")
    #expect(TerminalThemePreset.dracula.rawValue == "dracula")
    #expect(TerminalThemePreset.light.rawValue == "light")
    #expect(TerminalThemePreset.tokyoNight.rawValue == "tokyoNight")
    #expect(TerminalThemePreset.nord.rawValue == "nord")
    #expect(TerminalThemePreset.oneDark.rawValue == "oneDark")
    #expect(TerminalThemePreset.gruvboxDark.rawValue == "gruvboxDark")
    #expect(TerminalThemePreset.catppuccinMocha.rawValue == "catppuccinMocha")
    #expect(TerminalThemePreset.monokai.rawValue == "monokai")
    #expect(TerminalThemePreset.rosePine.rawValue == "rosePine")
    #expect(TerminalThemePreset.solarizedLight.rawValue == "solarizedLight")
    #expect(TerminalThemePreset.custom.rawValue == "custom")
}

@Test("Terminal Themes 2.0 содержит 26 вариантов")
func terminalThemes2CatalogCount() {
    #expect(TerminalThemePreset.allCases.count == 34)
    #expect(TerminalThemePreset.allCases.contains(.kanagawaWave))
    #expect(TerminalThemePreset.allCases.contains(.lightOwl))
    #expect(TerminalThemePreset.allCases.contains(.catppuccinLatte))
    #expect(TerminalThemePreset.allCases.contains(.cyberpunk))
    #expect(TerminalThemePreset.allCases.contains(.ocean))
}

@Test("Избранные темы сохраняются между открытиями")
@MainActor func terminalThemeFavoritesPersist() throws {
    let suiteName = "SelectiveRemote.ThemeFavorites.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let original = TerminalAppearanceStore(defaults: defaults)
    original.toggleFavorite(.tokyoNight); original.toggleFavorite(.kanagawaWave)
    let restored = TerminalAppearanceStore(defaults: defaults)
    #expect(restored.isFavorite(.tokyoNight)); #expect(restored.isFavorite(.kanagawaWave)); #expect(!restored.isFavorite(.lightOwl))
}

@Test("Своя тема переживает переключение на встроенную тему")
@MainActor func customTerminalPaletteSurvivesPresetSwitch() throws {
    let suiteName = "SelectiveRemote.CustomTheme.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let original = TerminalAppearanceStore(defaults: defaults)
    original.updateBackground("#123456"); original.updateForeground("#DDEEFF")
    original.applyPreset(.dracula); original.applyPreset(.custom)
    #expect(original.palette.background == "#123456"); #expect(original.palette.foreground == "#DDEEFF")
    let restored = TerminalAppearanceStore(defaults: defaults)
    #expect(restored.selectedPreset == .custom); #expect(restored.palette.background == "#123456")
}

@Test("Старая custom palette мигрирует в отдельное хранилище")
@MainActor func legacyCustomPaletteMigrates() throws {
    let suiteName = "SelectiveRemote.CustomThemeMigration.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    var legacy = TerminalThemePreset.midnight.palette; legacy.background = "#223344"
    defaults.set("custom", forKey: "SelectiveRemote.terminal.preset.v1")
    defaults.set(try JSONEncoder().encode(legacy), forKey: "SelectiveRemote.terminal.palette.v1")
    let store = TerminalAppearanceStore(defaults: defaults)
    store.applyPreset(.nord); store.applyPreset(.custom)
    #expect(store.palette.background == "#223344")
}
