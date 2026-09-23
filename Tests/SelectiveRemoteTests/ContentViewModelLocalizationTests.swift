import Foundation
import Testing
@testable import SelectiveRemote

@Suite(.serialized)
struct ContentViewModelLocalizationTests {
    private let languageKey = "SelectiveRemote.applicationLanguage.v1"

    @Test("RDP key names follow the selected application language")
    func rdpRemappableKeyNames() {
        LocalizationTestLanguageLock.acquire()
        defer { LocalizationTestLanguageLock.release() }
        let previous = UserDefaults.standard.object(forKey: languageKey)
        defer { UserDefaults.standard.set(previous, forKey: languageKey) }

        UserDefaults.standard.set("english", forKey: languageKey)
        #expect(RDPRemappableKey.leftCommand.title == "Left Command")
        #expect(RDPRemappableKey.rightWindows.title == "Right Windows")

        UserDefaults.standard.set("russian", forKey: languageKey)
        #expect(RDPRemappableKey.leftCommand.title == "Левый Command")
        #expect(RDPRemappableKey.rightWindows.title == "Правая Windows")
    }

    @Test("A user-editable tunnel name remains exact when language changes")
    func userTunnelNameIsVerbatim() {
        LocalizationTestLanguageLock.acquire()
        defer { LocalizationTestLanguageLock.release() }
        let previous = UserDefaults.standard.object(forKey: languageKey)
        defer { UserDefaults.standard.set(previous, forKey: languageKey) }

        var rule = PortForwardRule(kind: .local)
        rule.name = "Локальный туннель"
        UserDefaults.standard.set("english", forKey: languageKey)
        #expect(rule.displayName == "Локальный туннель")

        UserDefaults.standard.set("russian", forKey: languageKey)
        #expect(rule.displayName == "Локальный туннель")
    }
}
