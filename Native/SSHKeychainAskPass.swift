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
        alert.messageText = "Passphrase SSH-ключа"
        alert.informativeText = CommandLine.arguments.dropFirst().first
            ?? "Введите passphrase. Системный OpenSSH сохранит его в Keychain macOS."
        alert.addButton(withTitle: "Продолжить")
        alert.addButton(withTitle: "Отмена")

        let field = NSSecureTextField(
            frame: NSRect(x: 0, y: 0, width: 360, height: 24)
        )
        field.placeholderString = "Passphrase"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else {
            exit(1)
        }
        FileHandle.standardOutput.write(Data((field.stringValue + "\n").utf8))
    }
}
