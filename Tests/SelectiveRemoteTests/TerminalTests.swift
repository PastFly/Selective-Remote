import Foundation
import Testing
@testable import SelectiveRemote

@Test("Терминал игнорирует промежуточную почти нулевую геометрию SwiftUI")
@MainActor
func ignoresTransientTinyTerminalGeometry() {
    let session = TerminalSessionModel()

    session.resize(columns: 2, rows: 1)
    #expect(session.terminalColumns == 100)
    #expect(session.terminalRows == 30)

    session.resize(columns: 184, rows: 52)
    #expect(session.terminalColumns == 184)
    #expect(session.terminalRows == 52)
}

@Test("Тема, шрифт и размер терминала сохраняются между открытиями")
@MainActor
func persistsTerminalAppearance() throws {
    let suiteName = "SelectiveRemote.TerminalTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let original = TerminalAppearanceStore(defaults: defaults)
    original.applyPreset(.hackerGreen)
    original.font = .menlo
    original.fontSize = 19
    original.lineHeight = 1.3
    original.cursorStyle = .bar
    original.cursorBlink = false
    original.padding = 6

    let restored = TerminalAppearanceStore(defaults: defaults)
    #expect(restored.selectedPreset == .hackerGreen)
    #expect(restored.palette == TerminalThemePreset.hackerGreen.palette)
    #expect(restored.font == .menlo)
    #expect(restored.fontSize == 19)
    #expect(restored.lineHeight == 1.3)
    #expect(restored.cursorStyle == .bar)
    #expect(restored.cursorBlink == false)
    #expect(restored.padding == 6)

    let encoded = try JSONEncoder().encode(restored.snapshot)
    let json = try #require(
        JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    #expect(json["fontFamily"] as? String == TerminalFontChoice.menlo.cssValue)
    #expect((json["theme"] as? [String: Any])?["background"] as? String == "#07110C")
}

@Test("Терминал предлагает расширенный набор встроенных тем")
func exposesExpandedTerminalThemes() {
    #expect(TerminalThemePreset.allCases.count == 14)
    #expect(TerminalThemePreset.allCases.contains(.tokyoNight))
    #expect(TerminalThemePreset.allCases.contains(.catppuccinMocha))
    #expect(TerminalThemePreset.allCases.contains(.rosePine))
    #expect(TerminalThemePreset.solarizedLight.palette.background == "#FDF6E3")
}

@Test("Бренд приложения везде называется Selective Remote")
func usesSelectiveRemoteBrand() {
    #expect(AppBrand.name == "Selective Remote")
    #expect(AppBrand.tagline == "RDP · SSH · SFTP")
}

@Test("Прозрачность окна сохраняется между запусками")
@MainActor
func persistsApplicationTransparency() throws {
    let suiteName = "SelectiveRemote.AppAppearanceTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let original = AppAppearanceStore(defaults: defaults)
    original.transparencyEnabled = true
    original.opacity = 0.73

    let restored = AppAppearanceStore(defaults: defaults)
    #expect(restored.transparencyEnabled)
    #expect(restored.opacity == 0.73)
    #expect(restored.opacityPercent == 73)
    #expect(restored.snapshot.transparencyEnabled)
}

@Test("Состояние прозрачности не перекрывает NSView.appearance")
func windowTransparencyAvoidsNSAppearanceOverride() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let sourceURL = projectRoot
        .appendingPathComponent("Sources/SelectiveRemote/AppAppearance.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    #expect(source.contains("private var windowSettings"))
    #expect(!source.contains("private var appearance = AppWindowAppearanceSnapshot"))
}

@Test("CSP разрешает геометрию xterm, но не сторонние скрипты")
func terminalContentSecurityPolicySupportsXtermLayout() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let htmlURL = projectRoot
        .appendingPathComponent("Sources/SelectiveRemote/TerminalResources/terminal.html")
    let html = try String(contentsOf: htmlURL, encoding: .utf8)

    #expect(html.contains("style-src 'self' 'unsafe-inline'"))
    #expect(html.contains("script-src 'self'"))
    #expect(!html.contains("script-src 'self' 'unsafe-inline'"))
}

@Test("Палитра терминала не использует падающий bridge SwiftUI Color в NSColor")
func terminalPaletteAvoidsSwift63ColorBridge() throws {
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let sourceURL = projectRoot
        .appendingPathComponent("Sources/SelectiveRemote/TerminalAppearance.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    #expect(source.contains("NSColorWell"))
    #expect(source.contains("@MainActor @objc func colorChanged"))
    #expect(!source.contains("NSColor(color)"))
    #expect(!source.contains("ColorPicker("))
}
