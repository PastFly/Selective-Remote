import Darwin
import Foundation

enum RDPSessionCommand: String, CaseIterable, Identifiable {
    case windows
    case language
    case controlAltDelete = "ctrl-alt-delete"
    case altTab = "alt-tab"
    case printScreen = "print-screen"
    case fullScreen = "fullscreen"
    case disconnect

    var id: String { rawValue }

    var title: String {
        switch self {
        case .windows: "Windows"
        case .language: "Сменить язык"
        case .controlAltDelete: "Ctrl+Alt+Delete"
        case .altTab: "Alt+Tab"
        case .printScreen: "Print Screen"
        case .fullScreen: "Полный экран / окно"
        case .disconnect: "Отключить"
        }
    }

    var systemImage: String {
        switch self {
        case .windows: "square.grid.2x2"
        case .language: "globe"
        case .controlAltDelete: "lock.desktopcomputer"
        case .altTab: "rectangle.2.swap"
        case .printScreen: "camera.viewfinder"
        case .fullScreen: "rectangle.inset.filled"
        case .disconnect: "xmark.circle"
        }
    }

    var helpText: String {
        switch self {
        case .windows:
            "Открыть меню Пуск в Windows"
        case .language:
            "Отправить Win+Space и переключить язык Windows"
        case .controlAltDelete:
            "Отправить защищённое сочетание Ctrl+Alt+Delete"
        case .altTab:
            "Переключиться на следующее окно Windows"
        case .printScreen:
            "Сделать снимок экрана средствами Windows"
        case .fullScreen:
            "Переключить RDP между полным экраном и окном"
        case .disconnect:
            "Завершить выбранную RDP-сессию"
        }
    }
}

enum RDPSessionCommandSender {
    static func send(_ command: RDPSessionCommand, to pipeURL: URL) throws {
        let descriptor = Darwin.open(pipeURL.path, O_WRONLY | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw FreeRDPError.launchFailed("канал управления RDP ещё не готов")
        }
        defer { Darwin.close(descriptor) }
        let data = Data((command.rawValue + "\n").utf8)
        let written = data.withUnsafeBytes { bytes in
            Darwin.write(descriptor, bytes.baseAddress, bytes.count)
        }
        guard written == data.count else {
            throw FreeRDPError.launchFailed("не удалось передать команду RDP")
        }
    }
}
