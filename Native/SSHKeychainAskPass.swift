import AppKit
import Foundation
import Security

@main
struct SSHKeychainAskPass {
    @MainActor
    static func main() {
        let prompt = CommandLine.arguments.dropFirst().first
            ?? "Введите пароль или passphrase для SSH-подключения."
        let isPasswordPrompt = prompt.localizedCaseInsensitiveContains("password")

        // Initialize an accessory application before asking Keychain for a
        // user-presence protected secret. This gives macOS a foreground owner
        // for the Touch ID / authentication sheet.
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.activate(ignoringOtherApps: true)

        if isPasswordPrompt,
           let password = storedPasswordFromEnvironment(prompt: prompt) {
            FileHandle.standardOutput.write(Data((password + "\n").utf8))
            return
        }

        let usesEnglish = Locale.preferredLanguages.first?
            .lowercased().hasPrefix("en") == true
        let editTitle = usesEnglish ? "Edit" : "Правка"
        let pasteTitle = usesEnglish ? "Paste" : "Вставить"
        let selectAllTitle = usesEnglish ? "Select All" : "Выбрать всё"
        let mainMenu = NSMenu()
        let editMenuItem = NSMenuItem(title: editTitle, action: nil, keyEquivalent: "")
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

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = isPasswordPrompt
            ? (usesEnglish ? "SSH Server Password" : "Пароль SSH-сервера")
            : (usesEnglish ? "SSH Key Passphrase" : "Passphrase SSH-ключа")
        alert.informativeText = prompt
        alert.addButton(withTitle: usesEnglish ? "Continue" : "Продолжить")
        alert.addButton(withTitle: usesEnglish ? "Cancel" : "Отмена")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
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

    private static func storedPasswordFromEnvironment(prompt: String) -> String? {
        let environment = ProcessInfo.processInfo.environment
        guard let service = environment["SELECTIVEREMOTE_KEYCHAIN_SERVICE"],
              let account = environment["SELECTIVEREMOTE_KEYCHAIN_ACCOUNT"],
              !service.isEmpty,
              !account.isEmpty
        else { return nil }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseOperationPrompt as String: prompt
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8),
              !password.isEmpty
        else { return nil }
        return password
    }
}
