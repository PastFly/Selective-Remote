import AppKit
import Foundation

@main
struct SSHKeychainAskPass {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .informational
        let prompt = CommandLine.arguments.dropFirst().first
            ?? "Введите пароль или passphrase для SSH-подключения."
        let isPasswordPrompt = prompt.localizedCaseInsensitiveContains("password")
        let usesEnglish = Locale.preferredLanguages.first?
            .lowercased().hasPrefix("en") == true

        let editTitle = usesEnglish ? "Edit" : "Правка"
        let pasteTitle = usesEnglish ? "Paste" : "Вставить"
        let selectAllTitle = usesEnglish ? "Select All" : "Выбрать всё"
        let mainMenu = NSMenu()
        let editMenuItem = NSMenuItem(
            title: editTitle,
            action: nil,
            keyEquivalent: ""
        )
        let editMenu = NSMenu(title: editTitle)
        editMenu.addItem(
            withTitle: pasteTitle,
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        )
        editMenu.addItem(
            withTitle: selectAllTitle,
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        application.mainMenu = mainMenu

        alert.messageText = isPasswordPrompt
            ? (usesEnglish ? "SSH Server Password" : "Пароль SSH-сервера")
            : (usesEnglish ? "SSH Key Passphrase" : "Passphrase SSH-ключа")
        alert.informativeText = prompt
        alert.addButton(withTitle: usesEnglish ? "Continue" : "Продолжить")
        alert.addButton(withTitle: usesEnglish ? "Cancel" : "Отмена")

        let field = NSSecureTextField(
            frame: NSRect(x: 0, y: 0, width: 360, height: 24)
        )
        field.placeholderString = isPasswordPrompt
            ? (usesEnglish ? "Password" : "Пароль")
            : "Passphrase"
        let fieldMenu = NSMenu()
        fieldMenu.addItem(
            withTitle: pasteTitle,
            action: #selector(NSText.paste(_:)),
            keyEquivalent: ""
        )
        fieldMenu.addItem(.separator())
        fieldMenu.addItem(
            withTitle: selectAllTitle,
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: ""
        )
        field.menu = fieldMenu
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else {
            exit(1)
        }
        FileHandle.standardOutput.write(Data((field.stringValue + "\n").utf8))
    }
}
