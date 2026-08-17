import SwiftUI

enum TerminalThemeTone: Sendable {
    case dark
    case light
    case custom
}

extension TerminalThemePreset {
    var tone: TerminalThemeTone {
        switch self {
        case .light, .solarizedLight, .lightOwl, .ayuLight,
             .gruvboxLight, .catppuccinLatte, .tokyoDay, .nordLight:
            .light
        case .custom:
            .custom
        default:
            .dark
        }
    }
}

enum TerminalThemeBuiltins {
    static let kanagawaWave = TerminalPalette(
        background: "#1F1F28", foreground: "#DCD7BA", cursor: "#C8C093", cursorAccent: "#1F1F28",
        selectionBackground: "#2D4F6799", black: "#16161D", red: "#C34043", green: "#76946A",
        yellow: "#C0A36E", blue: "#7E9CD8", magenta: "#957FB8", cyan: "#6A9589", white: "#C8C093",
        brightBlack: "#727169", brightRed: "#E82424", brightGreen: "#98BB6C", brightYellow: "#E6C384",
        brightBlue: "#7FB4CA", brightMagenta: "#938AA9", brightCyan: "#7AA89F", brightWhite: "#DCD7BA"
    )
    static let kanagawaDragon = TerminalPalette(
        background: "#181616", foreground: "#C5C9C5", cursor: "#C8C093", cursorAccent: "#181616",
        selectionBackground: "#39383699", black: "#0D0C0C", red: "#C4746E", green: "#8A9A7B",
        yellow: "#C4B28A", blue: "#8BA4B0", magenta: "#A292A3", cyan: "#8EA4A2", white: "#C8C093",
        brightBlack: "#625E5A", brightRed: "#E46876", brightGreen: "#87A987", brightYellow: "#E6C384",
        brightBlue: "#7FB4CA", brightMagenta: "#938AA9", brightCyan: "#7AA89F", brightWhite: "#DCD7BA"
    )
    static let nightOwl = TerminalPalette(
        background: "#011627", foreground: "#D6DEEB", cursor: "#80A4C2", cursorAccent: "#011627",
        selectionBackground: "#1D3B5399", black: "#011627", red: "#EF5350", green: "#22DA6E",
        yellow: "#ADDB67", blue: "#82AAFF", magenta: "#C792EA", cyan: "#21C7A8", white: "#D6DEEB",
        brightBlack: "#575656", brightRed: "#EF5350", brightGreen: "#22DA6E", brightYellow: "#FFEB95",
        brightBlue: "#82AAFF", brightMagenta: "#C792EA", brightCyan: "#7FDBCA", brightWhite: "#FFFFFF"
    )
    static let lightOwl = TerminalPalette(
        background: "#FBFBFB", foreground: "#403F53", cursor: "#90A7B2", cursorAccent: "#FBFBFB",
        selectionBackground: "#D6DEEB99", black: "#403F53", red: "#DE3D3B", green: "#08916A",
        yellow: "#DAAA01", blue: "#288ED7", magenta: "#D6438A", cyan: "#08916A", white: "#F0F0F0",
        brightBlack: "#7A8181", brightRed: "#E75545", brightGreen: "#49A87A", brightYellow: "#E0B71D",
        brightBlue: "#5CA7E4", brightMagenta: "#E06C9F", brightCyan: "#3AAFA0", brightWhite: "#FFFFFF"
    )
    static let ayuDark = TerminalPalette(
        background: "#0A0E14", foreground: "#B3B1AD", cursor: "#E6B450", cursorAccent: "#0A0E14",
        selectionBackground: "#25334099", black: "#01060E", red: "#FF3333", green: "#C2D94C",
        yellow: "#E6B450", blue: "#59C2FF", magenta: "#D2A6FF", cyan: "#95E6CB", white: "#C7C7C7",
        brightBlack: "#686868", brightRed: "#FF6565", brightGreen: "#EAFE84", brightYellow: "#FFF779",
        brightBlue: "#73D0FF", brightMagenta: "#D2A6FF", brightCyan: "#95E6CB", brightWhite: "#FFFFFF"
    )
    static let ayuLight = TerminalPalette(
        background: "#FAFAFA", foreground: "#5C6166", cursor: "#FF9940", cursorAccent: "#FAFAFA",
        selectionBackground: "#D1E4F499", black: "#000000", red: "#F07171", green: "#86B300",
        yellow: "#F2AE49", blue: "#399EE6", magenta: "#A37ACC", cyan: "#4CBF99", white: "#D9D8D7",
        brightBlack: "#8A9199", brightRed: "#F07171", brightGreen: "#86B300", brightYellow: "#F2AE49",
        brightBlue: "#399EE6", brightMagenta: "#A37ACC", brightCyan: "#4CBF99", brightWhite: "#FFFFFF"
    )
    static let gruvboxLight = TerminalPalette(
        background: "#FBF1C7", foreground: "#3C3836", cursor: "#3C3836", cursorAccent: "#FBF1C7",
        selectionBackground: "#D5C4A166", black: "#FBF1C7", red: "#CC241D", green: "#98971A",
        yellow: "#D79921", blue: "#458588", magenta: "#B16286", cyan: "#689D6A", white: "#7C6F64",
        brightBlack: "#928374", brightRed: "#9D0006", brightGreen: "#79740E", brightYellow: "#B57614",
        brightBlue: "#076678", brightMagenta: "#8F3F71", brightCyan: "#427B58", brightWhite: "#3C3836"
    )
    static let catppuccinLatte = TerminalPalette(
        background: "#EFF1F5", foreground: "#4C4F69", cursor: "#DC8A78", cursorAccent: "#EFF1F5",
        selectionBackground: "#ACB0BE66", black: "#5C5F77", red: "#D20F39", green: "#40A02B",
        yellow: "#DF8E1D", blue: "#1E66F5", magenta: "#EA76CB", cyan: "#179299", white: "#ACB0BE",
        brightBlack: "#6C6F85", brightRed: "#D20F39", brightGreen: "#40A02B", brightYellow: "#DF8E1D",
        brightBlue: "#1E66F5", brightMagenta: "#EA76CB", brightCyan: "#179299", brightWhite: "#4C4F69"
    )
    static let tokyoDay = TerminalPalette(
        background: "#E1E2E7", foreground: "#3760BF", cursor: "#3760BF", cursorAccent: "#E1E2E7",
        selectionBackground: "#99A7DF66", black: "#B4B5B9", red: "#F52A65", green: "#587539",
        yellow: "#8C6C3E", blue: "#2E7DE9", magenta: "#9854F1", cyan: "#007197", white: "#6172B0",
        brightBlack: "#A1A6C5", brightRed: "#F52A65", brightGreen: "#587539", brightYellow: "#8C6C3E",
        brightBlue: "#2E7DE9", brightMagenta: "#9854F1", brightCyan: "#007197", brightWhite: "#3760BF"
    )
    static let nordLight = TerminalPalette(
        background: "#ECEFF4", foreground: "#2E3440", cursor: "#5E81AC", cursorAccent: "#ECEFF4",
        selectionBackground: "#D8DEE999", black: "#3B4252", red: "#BF616A", green: "#A3BE8C",
        yellow: "#D08770", blue: "#5E81AC", magenta: "#B48EAD", cyan: "#88C0D0", white: "#E5E9F0",
        brightBlack: "#4C566A", brightRed: "#BF616A", brightGreen: "#A3BE8C", brightYellow: "#EBCB8B",
        brightBlue: "#81A1C1", brightMagenta: "#B48EAD", brightCyan: "#8FBCBB", brightWhite: "#FFFFFF"
    )
    static let cyberpunk = TerminalPalette(
        background: "#0B1020", foreground: "#EAF6FF", cursor: "#FCEE0A", cursorAccent: "#0B1020",
        selectionBackground: "#2B145E99", black: "#090A14", red: "#FF2A6D", green: "#00E5A8",
        yellow: "#FCEE0A", blue: "#05D9E8", magenta: "#D300C5", cyan: "#00F0FF", white: "#D7F7FF",
        brightBlack: "#4B527E", brightRed: "#FF5C8D", brightGreen: "#5CFFD2", brightYellow: "#FFF45C",
        brightBlue: "#4DEBFF", brightMagenta: "#FF4DE1", brightCyan: "#7AFFFF", brightWhite: "#FFFFFF"
    )
    static let ocean = TerminalPalette(
        background: "#0B1F2A", foreground: "#D7F0F7", cursor: "#59D6D6", cursorAccent: "#0B1F2A",
        selectionBackground: "#164A5C99", black: "#071820", red: "#FF6B6B", green: "#67D391",
        yellow: "#FFD166", blue: "#58A6FF", magenta: "#C792EA", cyan: "#49D6C8", white: "#CFE8EF",
        brightBlack: "#52717C", brightRed: "#FF8A8A", brightGreen: "#8BE7AA", brightYellow: "#FFE08A",
        brightBlue: "#83C3FF", brightMagenta: "#D9ACF5", brightCyan: "#78E8DD", brightWhite: "#FFFFFF"
    )
}

private enum TerminalThemeCatalogFilter: String, CaseIterable, Identifiable {
    case all, dark, light, favorites
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "Все"
        case .dark: "Тёмные"
        case .light: "Светлые"
        case .favorites: "Избранное"
        }
    }
}

struct TerminalThemeSelector: View {
    @ObservedObject var store: TerminalAppearanceStore
    @State private var showsCatalog = false

    var body: some View {
        LabeledContent("Тема терминала") {
            Button { showsCatalog.toggle() } label: {
                HStack(spacing: 10) {
                    TerminalThemePreview(palette: store.palette).frame(width: 52, height: 30)
                    Text(store.selectedPreset.title).lineLimit(1)
                    Spacer(minLength: 10)
                    Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 9).padding(.vertical, 6).frame(width: 255)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.09)) }
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showsCatalog, arrowEdge: .trailing) {
                TerminalThemeCatalogView(store: store)
            }
        }
    }
}

private struct TerminalThemeCatalogView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: TerminalAppearanceStore
    @State private var query = ""
    @State private var filter: TerminalThemeCatalogFilter = .all

    private var visibleThemes: [TerminalThemePreset] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return TerminalThemePreset.allCases.filter { preset in
            let matchesFilter: Bool
            switch filter {
            case .all: matchesFilter = true
            case .dark: matchesFilter = preset.tone == .dark
            case .light: matchesFilter = preset.tone == .light
            case .favorites: matchesFilter = store.isFavorite(preset)
            }
            return matchesFilter && (needle.isEmpty || preset.title.localizedCaseInsensitiveContains(needle))
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Поиск тем", text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).frame(height: 34)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            Picker("Фильтр", selection: $filter) {
                ForEach(TerminalThemeCatalogFilter.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden().pickerStyle(.segmented)
            Divider()

            if visibleThemes.isEmpty {
                ContentUnavailableView(
                    filter == .favorites ? "Нет избранных тем" : "Темы не найдены",
                    systemImage: filter == .favorites ? "star" : "magnifyingglass",
                    description: Text(filter == .favorites ? "Добавьте тему в избранное кнопкой со звездой." : "Измените поиск или фильтр.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) { ForEach(visibleThemes) { themeRow($0) } }
                        .padding(.vertical, 2)
                }
            }
        }
        .padding(12).frame(width: 390, height: 430)
    }

    private func themeRow(_ preset: TerminalThemePreset) -> some View {
        let selected = store.selectedPreset == preset
        return HStack(spacing: 8) {
            Button {
                store.applyPreset(preset)
                dismiss()
            } label: {
                HStack(spacing: 11) {
                    TerminalThemePreview(palette: preset == .custom ? store.customThemePalette : preset.palette)
                        .frame(width: 64, height: 38)
                    Text(preset.title).font(.subheadline.weight(selected ? .semibold : .regular)).foregroundStyle(.primary).lineLimit(1)
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button { store.toggleFavorite(preset) } label: {
                Image(systemName: store.isFavorite(preset) ? "star.fill" : "star")
                    .foregroundStyle(store.isFavorite(preset) ? Color.accentColor : Color.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(store.isFavorite(preset) ? "Убрать из избранного" : "Добавить в избранное")

            Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(Color.accentColor)
                .opacity(selected ? 1 : 0).frame(width: 18)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(selected ? Color.accentColor.opacity(0.10) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct TerminalThemePreview: View {
    let palette: TerminalPalette
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) { dot(palette.red); dot(palette.yellow); dot(palette.green) }
            HStack(spacing: 3) { line(palette.blue, 22); line(palette.foreground, 12) }
            HStack(spacing: 3) { line(palette.cyan, 15); line(palette.magenta, 20) }
        }
        .padding(6).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(color(palette.background), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.12)) }
    }
    private func dot(_ value: String) -> some View { Circle().fill(color(value)).frame(width: 4, height: 4) }
    private func line(_ value: String, _ width: CGFloat) -> some View { Capsule().fill(color(value)).frame(width: width, height: 3) }
    private func color(_ value: String) -> Color { Color(nsColor: TerminalColorCodec.nsColor(value)) }
}
