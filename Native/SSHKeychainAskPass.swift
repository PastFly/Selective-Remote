import AppKit
import Foundation

@main
struct SSHKeychainAskPass {
    @MainActor
    static func main() {
        #if SSH_ASKPASS_TESTING
        let testInvocation = recordSyntheticInvocation()
        #endif
        let prompt = CommandLine.arguments.dropFirst().first
            ?? "Введите пароль или passphrase для SSH-подключения."
        let isPasswordPrompt = prompt.localizedCaseInsensitiveContains("password")
        let environment = ProcessInfo.processInfo.environment
        let terminalPasswordAttempt = isPasswordPrompt
            ? environment["SELECTIVEREMOTE_TERMINAL_PASSWORD_STATE_FILE"] : nil
        let preparedSecretIsInScope = hasTrustedCredentialScope(environment)

        // SSH password retrieval happens in the signed main application. The
        // helper receives only a random path to a short-lived 0600 file. This
        // avoids a second executable asking macOS Keychain for the same item,
        // which otherwise produces legacy “Always Allow” ACL dialogs on macOS.
        if let terminalPasswordAttempt {
            let prepared = preparedSecretIsInScope ? readPreparedSecret(
                path: environment["SELECTIVEREMOTE_ASKPASS_SECRET_FILE"],
                removeAfterRead: false
            ) : nil
            switch claimTerminalPasswordInteraction(
                statePath: terminalPasswordAttempt,
                hasPreparedPassword: prepared != nil
            ) {
            case .saved:
                guard let prepared else { exit(1) }
                FileHandle.standardOutput.write(Data((prepared + "\n").utf8))
                return
            case .denied:
                exit(1)
            case .manual:
                break
            }
        } else if isPasswordPrompt, preparedSecretIsInScope,
                  let password = readPreparedSecret(path: environment["SELECTIVEREMOTE_ASKPASS_SECRET_FILE"]) {
            FileHandle.standardOutput.write(Data((password + "\n").utf8))
            return
        }

        #if SSH_ASKPASS_TESTING
        if let response = syntheticResponse(invocation: testInvocation) {
            if response == "cancel" {
                cancelTerminalAttempt(terminalPasswordAttempt != nil)
                exit(1)
            }
            let answer = response == "correct" ? "synthetic-correct" : "synthetic-wrong"
            FileHandle.standardOutput.write(Data((answer + "\n").utf8))
            return
        }
        #endif

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

        guard alert.runModal() == .alertFirstButtonReturn,
              !field.stringValue.isEmpty else {
            cancelTerminalAttempt(terminalPasswordAttempt != nil)
            exit(1)
        }
        FileHandle.standardOutput.write(Data((field.stringValue + "\n").utf8))
    }

    private static func cancelTerminalAttempt(_ isTerminalPasswordAttempt: Bool) {
        guard isTerminalPasswordAttempt else { return }
        // Terminal SSH runs as the PTY process-group leader. Stop only
        // that process when the user cancels its password prompt.
        let parent = getppid()
        if parent > 1, getpgrp() == parent {
            _ = kill(parent, SIGTERM)
        }
    }

    #if SSH_ASKPASS_TESTING
    private static func recordSyntheticInvocation() -> Int {
        guard let path = ProcessInfo.processInfo.environment["SR_TEST_ASKPASS_COUNT_FILE"] else {
            return 1
        }
        let url = URL(fileURLWithPath: path)
        let previous = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? (previous + "x").write(to: url, atomically: true, encoding: .utf8)
        return previous.count + 1
    }

    private static func syntheticResponse(invocation: Int) -> String? {
        let responses = ProcessInfo.processInfo.environment["SR_TEST_ASKPASS_RESPONSES"]?
            .split(separator: ",")
            .map(String.init) ?? []
        guard !responses.isEmpty else { return nil }
        return responses[min(invocation - 1, responses.count - 1)]
    }
    #endif

    private enum TerminalPasswordInteraction {
        case saved
        case manual
        case denied
    }

    private static func claimTerminalPasswordInteraction(
        statePath: String,
        hasPreparedPassword: Bool
    ) -> TerminalPasswordInteraction {
        let descriptor = open(statePath, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return .denied }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_uid == getuid(),
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_mode & 0o077 == 0,
              flock(descriptor, LOCK_EX) == 0 else { return .denied }
        defer { _ = flock(descriptor, LOCK_UN) }

        var buffer = [UInt8](repeating: 0, count: 32)
        let count = read(descriptor, &buffer, buffer.count)
        guard count > 0,
              let state = String(bytes: buffer.prefix(count), encoding: .utf8) else {
            return .denied
        }
        let components = state.split(separator: ",", omittingEmptySubsequences: false)
        guard components.count == 2,
              var savedUses = Int(components[0]),
              var manualUses = Int(components[1]),
              (0...2).contains(savedUses),
              (0...1).contains(manualUses) else { return .denied }

        let decision: TerminalPasswordInteraction
        if hasPreparedPassword, savedUses < 2 {
            savedUses += 1
            decision = .saved
        } else if manualUses == 0 {
            manualUses += 1
            decision = .manual
        } else {
            return .denied
        }
        let updated = Array("\(savedUses),\(manualUses)".utf8)
        guard lseek(descriptor, 0, SEEK_SET) == 0,
              ftruncate(descriptor, 0) == 0,
              write(descriptor, updated, updated.count) == updated.count else {
            return .denied
        }
        return decision
    }

    private static func hasTrustedCredentialScope(_ environment: [String: String]) -> Bool {
        guard let target = environment["SELECTIVEREMOTE_ASKPASS_TARGET_IDENTITY"],
              let credential = environment["SELECTIVEREMOTE_ASKPASS_CREDENTIAL_IDENTITY"],
              let ownerText = environment["SELECTIVEREMOTE_ASKPASS_OWNER_PID"],
              let ownerPID = Int32(ownerText), ownerPID > 1,
              !target.isEmpty, target == credential,
              target.hasPrefix("destination|") || target.hasPrefix("jump|") else { return false }
        // A ProxyJump from an unmanaged SSH config inherits the outer process's
        // environment. Its nested ssh is not a direct child of the process that
        // prepared this target's credential, so it must request manual input.
        var process = kinfo_proc()
        var identifiers: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getppid()]
        var length = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&identifiers, u_int(identifiers.count), &process, &length, nil, 0) == 0,
              length == MemoryLayout<kinfo_proc>.stride else { return false }
        if process.kp_eproc.e_ppid == ownerPID { return true }
        guard environment["SELECTIVEREMOTE_ASKPASS_ROUTING_DEPTH"] == "mosh" else { return false }
        // Mosh forks once before exec'ing SSH. The scoped launcher is the
        // parent of that Mosh process; an additional SSH ProxyCommand child
        // sits one level deeper and remains outside this credential scope.
        identifiers[3] = process.kp_eproc.e_ppid
        length = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&identifiers, u_int(identifiers.count), &process, &length, nil, 0) == 0,
              length == MemoryLayout<kinfo_proc>.stride else { return false }
        return process.kp_eproc.e_ppid == ownerPID
    }

    private static func readPreparedSecret(
        path: String?,
        removeAfterRead: Bool = true
    ) -> String? {
        guard let path,
              !path.isEmpty,
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let mode = attributes[.posixPermissions] as? NSNumber,
              mode.intValue & 0o077 == 0,
              let data = FileManager.default.contents(atPath: path),
              let password = String(data: data, encoding: .utf8),
              !password.isEmpty
        else { return nil }
        if removeAfterRead {
            try? FileManager.default.removeItem(atPath: path)
        }
        return password
    }
}
