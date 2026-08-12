import AppKit
import Foundation

@main
struct SSHKeychainAskPass {
    @MainActor
    static func main() {
        let prompt = CommandLine.arguments.dropFirst().first
            ?? "Введите пароль или passphrase для SSH-подключения."
        let isPasswordPrompt = prompt.localizedCaseInsensitiveContains("password")

        // SSH password retrieval happens in the signed main application. The
        // helper receives only a random path to a short-lived 0600 file. This
        // avoids a second executable asking macOS Keychain for the same item,
        // which otherwise produces legacy “Always Allow” ACL dialogs on macOS.
        if isPasswordPrompt,
           let password = preparedPasswordFromEnvironment() {
            FileHandle.standardOutput.write(Data((password + "\n").utf8))
            return
        }

        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.activate(ignoringOtherApps: true)

        let usesEnglish = Locale.preferredLanguages.first?
            .lowercased().hasPrefix("en") == true
        let editTitle = usesEnglish ? "Edit" : "Правка"
        let pasteTitle = usesEnglish ? "Paste" : "Вставить"
        let selectAllTitle = usesEnglish ? "Select All" : "Выбрать всё"
        let mainMenu = NSMenu()
        let editMenuItem = NSMenuItem(title: editTitle, action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: editTitle)
        editMenu.addItem(withTitle: pasteTitle, action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: selectAllTitle, action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        application.mainMenu = mainMenu

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = isPasswordPrompt
            ? (usesEnglish ? "SSH Server Password" : "Пароль SSH-сервера")
            : (usesEnglish ? "SSH Key Passphrase" : "Passphrase SSH-ключа")
        alert.informativeText = prompt
        alert.addButton(withTitle: usesEnglish ? "Continue" : "Продолжить")
        alert.addButton(withTitle: usesEnglish ? "Cancel" : "Отмена")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = isPasswordPrompt ? (usesEnglish ? "Password" : "Пароль") : "Passphrase"
        let fieldMenu = NSMenu()
        fieldMenu.addItem(withTitle: pasteTitle, action: #selector(NSText.paste(_:)), keyEquivalent: "")
        fieldMenu.addItem(.separator())
        fieldMenu.addItem(withTitle: selectAllTitle, action: #selector(NSText.selectAll(_:)), keyEquivalent: "")
        field.menu = fieldMenu
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { exit(1) }
        FileHandle.standardOutput.write(Data((field.stringValue + "\n").utf8))
    }

    private static func preparedPasswordFromEnvironment() -> String? {
        guard let path = ProcessInfo.processInfo.environment["SELECTIVEREMOTE_ASKPASS_SECRET_FILE"],
              !path.isEmpty,
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let mode = attributes[.posixPermissions] as? NSNumber,
              mode.intValue & 0o077 == 0,
              let data = FileManager.default.contents(atPath: path),
              let password = String(data: data, encoding: .utf8),
              !password.isEmpty
        else { return nil }
        try? FileManager.default.removeItem(atPath: path)
        return password
    }
}
