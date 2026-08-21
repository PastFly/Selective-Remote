import SwiftUI

enum TerminalPaneThemeChoice: Int, CaseIterable, Identifiable, Sendable {
    case inherited = 0
    case ocean = 1
    case hackerGreen = 2
    case dracula = 3
    case rosePine = 4
    case solarizedLight = 5

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .inherited: "Общее оформление"
        case .ocean: TerminalThemePreset.ocean.title
        case .hackerGreen: TerminalThemePreset.hackerGreen.title
        case .dracula: TerminalThemePreset.dracula.title
        case .rosePine: TerminalThemePreset.rosePine.title
        case .solarizedLight: TerminalThemePreset.solarizedLight.title
        }
    }

    var preset: TerminalThemePreset? {
        switch self {
        case .inherited: nil
        case .ocean: .ocean
        case .hackerGreen: .hackerGreen
        case .dracula: .dracula
        case .rosePine: .rosePine
        case .solarizedLight: .solarizedLight
        }
    }

    static func normalized(_ colorIndex: Int) -> TerminalPaneThemeChoice {
        TerminalPaneThemeChoice(rawValue: max(0, colorIndex) % allCases.count) ?? .inherited
    }
}

extension TerminalAppearanceSnapshot {
    func applyingPaneTheme(colorIndex: Int) -> TerminalAppearanceSnapshot {
        guard let preset = TerminalPaneThemeChoice.normalized(colorIndex).preset else {
            return self
        }
        let panePalette = preset.palette
        return TerminalAppearanceSnapshot(
            fontFamily: fontFamily,
            fontSize: fontSize,
            lineHeight: lineHeight,
            cursorStyle: cursorStyle,
            cursorBlink: cursorBlink,
            syntaxHighlighting: syntaxHighlighting,
            syntaxScope: syntaxScope,
            syntaxHistoryOpacity: syntaxHistoryOpacity,
            syntaxBoldCommands: syntaxBoldCommands,
            syntaxPalette: TerminalSyntaxPalette(theme: panePalette),
            padding: padding,
            theme: panePalette
        )
    }
}

@MainActor
func setTerminalPaneTheme(
    _ choice: TerminalPaneThemeChoice,
    tabID: UUID,
    workspace: TerminalWorkspaceModel
) {
    guard let tab = workspace.tabs.first(where: { $0.id == tabID }) else { return }
    let count = TerminalPaneThemeChoice.allCases.count
    let current = TerminalPaneThemeChoice.normalized(tab.colorIndex).rawValue
    let steps = (choice.rawValue - current + count) % count
    guard steps > 0 else { return }
    for _ in 0..<steps {
        workspace.cycleColor(tabID)
    }
}

struct TerminalPaneThemePicker: View {
    let colorIndex: Int
    let select: (TerminalPaneThemeChoice) -> Void

    private var current: TerminalPaneThemeChoice {
        .normalized(colorIndex)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Цвет этой панели")
                .font(.headline)
            Text("Шрифт, курсор и остальные параметры остаются общими.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(TerminalPaneThemeChoice.allCases) { choice in
                Button {
                    select(choice)
                } label: {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(previewColor(choice))
                            .frame(width: 24, height: 18)
                            .overlay {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.15))
                            }
                        Text(choice.title)
                        Spacer(minLength: 12)
                        if choice == current {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    choice == current ? Color.accentColor.opacity(0.10) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            }
        }
        .padding(14)
        .frame(width: 290)
    }

    private func previewColor(_ choice: TerminalPaneThemeChoice) -> Color {
        let palette = choice.preset?.palette ?? TerminalThemePreset.midnight.palette
        return Color(nsColor: TerminalColorCodec.nsColor(palette.background))
    }
}
