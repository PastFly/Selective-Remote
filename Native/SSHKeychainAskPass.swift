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
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else {
            exit(1)
        }
        FileHandle.standardOutput.write(Data((field.stringValue + "\n").utf8))
    }
}
