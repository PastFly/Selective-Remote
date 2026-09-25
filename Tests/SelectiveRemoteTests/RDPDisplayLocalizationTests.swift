import CoreGraphics
import Foundation
import Testing
@testable import SelectiveRemote

@Suite(.serialized)
@MainActor
struct RDPDisplayLocalizationTests {
    private let languageKey = "SelectiveRemote.applicationLanguage.v1"

    @Test("Known display rate and physical name survive RU to EN to RU without relaunch")
    func knownRateAndExternalName() {
        LocalizationTestLanguageLock.acquire()
        defer { LocalizationTestLanguageLock.release() }
        let previous = UserDefaults.standard.object(forKey: languageKey)
        defer { UserDefaults.standard.set(previous, forKey: languageKey) }

        let display = makeDisplay(name: "Встроенный дисплей Retina", refreshRate: 120)
        UserDefaults.standard.set("russian", forKey: languageKey)
        #expect(display.refreshText == "120 Гц")
        UserDefaults.standard.set("english", forKey: languageKey)
        #expect(display.refreshText == "120 Hz")
        #expect(display.name == "Встроенный дисплей Retina")
        UserDefaults.standard.set("russian", forKey: languageKey)
        #expect(display.refreshText == "120 Гц")
    }

    @Test("Unknown display rate follows the active language")
    func unknownRate() {
        LocalizationTestLanguageLock.acquire()
        defer { LocalizationTestLanguageLock.release() }
        let previous = UserDefaults.standard.object(forKey: languageKey)
        defer { UserDefaults.standard.set(previous, forKey: languageKey) }

        let display = makeDisplay(name: "HP E243m", refreshRate: 0)
        UserDefaults.standard.set("english", forKey: languageKey)
        #expect(display.refreshText == "refresh rate unknown")
        UserDefaults.standard.set("russian", forKey: languageKey)
        #expect(display.refreshText == "частота неизвестна")
        #expect(display.name == "HP E243m")
    }

    @Test("Display discovery status rerenders after language switches and new discoveries")
    func discoveryStatusFollowsLanguage() {
        LocalizationTestLanguageLock.acquire()
        defer { LocalizationTestLanguageLock.release() }
        let previous = UserDefaults.standard.object(forKey: languageKey)
        defer { UserDefaults.standard.set(previous, forKey: languageKey) }

        UserDefaults.standard.set("russian", forKey: languageKey)
        let model = AppModel()
        let count = model.displays.count
        #expect(model.statusMessage == "Обнаружено дисплеев: \(count)")

        UserDefaults.standard.set("english", forKey: languageKey)
        #expect(model.statusMessage == "Displays found: \(count)")
        model.refreshDisplays()
        #expect(model.statusMessage == "Displays found: \(model.displays.count)")

        UserDefaults.standard.set("russian", forKey: languageKey)
        #expect(model.statusMessage == "Обнаружено дисплеев: \(model.displays.count)")

        model.statusMessage = "Remote Windows says: Готово"
        UserDefaults.standard.set("english", forKey: languageKey)
        #expect(model.statusMessage == "Remote Windows says: Готово")
    }

    @Test("Display event messages use current locale even after a prior event")
    func displayEventMessagesFollowLanguage() {
        LocalizationTestLanguageLock.acquire()
        defer { LocalizationTestLanguageLock.release() }
        let previous = UserDefaults.standard.object(forKey: languageKey)
        defer { UserDefaults.standard.set(previous, forKey: languageKey) }

        let events: [(RDPDisplayStatus, String, String)] = [
            (.changing, "Конфигурация дисплеев меняется — ожидаем стабилизацию",
             "Display configuration is changing — waiting for it to stabilize"),
            (.updated(2), "Конфигурация дисплеев обновлена: 2",
             "Display configuration updated: 2"),
            (.monitorDisconnected, "Монитор отключён — подключитесь повторно, чтобы использовать доступные дисплеи",
             "Monitor disconnected — reconnect to use the available displays"),
            (.macBookClosed, "Экран MacBook закрыт — перестраиваем RDP на внешние дисплеи",
             "MacBook screen closed — moving RDP to external displays"),
            (.reconnecting(2, 3), "RDP: переподключение, попытка 2/3",
             "RDP: reconnecting, attempt 2/3")
        ]
        UserDefaults.standard.set("russian", forKey: languageKey)
        for (event, ru, _) in events { #expect(event.text == ru) }
        UserDefaults.standard.set("english", forKey: languageKey)
        for (event, _, en) in events { #expect(event.text == en) }
        UserDefaults.standard.set("russian", forKey: languageKey)
        for (event, ru, _) in events { #expect(event.text == ru) }
    }

    @Test("Display reconnect reason is recomputed while remote-provided text stays exact")
    func reconnectReasonDoesNotKeepOldLocale() {
        LocalizationTestLanguageLock.acquire()
        defer { LocalizationTestLanguageLock.release() }
        let previous = UserDefaults.standard.object(forKey: languageKey)
        defer { UserDefaults.standard.set(previous, forKey: languageKey) }

        UserDefaults.standard.set("russian", forKey: languageKey)
        let displayReconnect = SmartReconnectProgress(
            attempt: 1, maximumAttempts: 3, nextAttemptAt: nil,
            reason: "Конфигурация мониторов изменилась",
            displayReason: .topologyChangedShort
        )
        let remoteReconnect = SmartReconnectProgress(
            attempt: 1, maximumAttempts: 3, nextAttemptAt: nil,
            reason: "Windows: соединение потеряно"
        )
        #expect(displayReconnect.reason == "Конфигурация мониторов изменилась")
        UserDefaults.standard.set("english", forKey: languageKey)
        #expect(displayReconnect.reason == "Monitor configuration changed")
        #expect(remoteReconnect.reason == "Windows: соединение потеряно")
        UserDefaults.standard.set("russian", forKey: languageKey)
        #expect(displayReconnect.reason == "Конфигурация мониторов изменилась")
    }

    @Test("Missing-display fallback localizes while a supplied display name is untouched")
    func displayNameFallbackPreservesExternalNames() {
        LocalizationTestLanguageLock.acquire()
        defer { LocalizationTestLanguageLock.release() }
        let previous = UserDefaults.standard.object(forKey: languageKey)
        defer { UserDefaults.standard.set(previous, forKey: languageKey) }

        let supplied = makeDisplay(name: "Встроенный дисплей Retina", refreshRate: 120)
        UserDefaults.standard.set("russian", forKey: languageKey)
        #expect(RDPDisplayLabels.name(for: nil) == "Дисплей")
        UserDefaults.standard.set("english", forKey: languageKey)
        #expect(RDPDisplayLabels.name(for: nil) == "Display")
        #expect(RDPDisplayLabels.name(for: supplied) == "Встроенный дисплей Retina")
        UserDefaults.standard.set("russian", forKey: languageKey)
        #expect(RDPDisplayLabels.name(for: supplied) == "Встроенный дисплей Retina")
    }

    @Test("Personal and Team scope labels follow RU to EN to RU")
    func hostScopeLabelsFollowLanguage() {
        LocalizationTestLanguageLock.acquire()
        defer { LocalizationTestLanguageLock.release() }
        let previous = UserDefaults.standard.object(forKey: languageKey)
        defer { UserDefaults.standard.set(previous, forKey: languageKey) }

        UserDefaults.standard.set("russian", forKey: languageKey)
        #expect(HostScopeLabels.personal == "Личные")
        #expect(HostScopeLabels.team == "Командные")
        UserDefaults.standard.set("english", forKey: languageKey)
        #expect(HostScopeLabels.personal == "Personal")
        #expect(HostScopeLabels.team == "Team")
        UserDefaults.standard.set("russian", forKey: languageKey)
        #expect(HostScopeLabels.personal == "Личные")
        #expect(HostScopeLabels.team == "Командные")
    }

    @Test("Confirmed display additions, removals and unstable events use the active locale")
    func topologyEventsAfterSwitch() {
        LocalizationTestLanguageLock.acquire()
        defer { LocalizationTestLanguageLock.release() }
        let previous = UserDefaults.standard.object(forKey: languageKey)
        defer { UserDefaults.standard.set(previous, forKey: languageKey) }

        let builtIn = makeDisplay(id: "built-in", name: "Встроенный дисплей Retina", refreshRate: 120)
        let external = makeDisplay(id: "external", name: "HP E243m", refreshRate: 60)
        let model = AppModel()

        UserDefaults.standard.set("english", forKey: languageKey)
        model.handleConfirmedDisplayChange(
            previousIDs: [builtIn.id],
            firstSnapshot: [builtIn, external],
            secondSnapshot: [builtIn, external]
        )
        #expect(model.statusMessage == "Display configuration updated: 2")
        #expect(model.displays.map(\.name) == ["Встроенный дисплей Retina", "HP E243m"])

        UserDefaults.standard.set("russian", forKey: languageKey)
        #expect(model.statusMessage == "Конфигурация дисплеев обновлена: 2")
        model.handleConfirmedDisplayChange(
            previousIDs: [builtIn.id, external.id],
            firstSnapshot: [builtIn],
            secondSnapshot: [builtIn]
        )
        #expect(model.statusMessage == "Конфигурация дисплеев обновлена: 1")

        UserDefaults.standard.set("english", forKey: languageKey)
        #expect(model.statusMessage == "Display configuration updated: 1")
        model.handleConfirmedDisplayChange(
            previousIDs: [builtIn.id],
            firstSnapshot: [builtIn, external],
            secondSnapshot: [builtIn]
        )
        #expect(model.statusMessage == "Display configuration is changing — waiting for it to stabilize")
        UserDefaults.standard.set("russian", forKey: languageKey)
        #expect(model.statusMessage == "Конфигурация дисплеев меняется — ожидаем стабилизацию")
    }

    @Test("Displayed topology reconnect error rerenders, while unrelated errors remain verbatim")
    func topologyErrorAfterSwitch() {
        LocalizationTestLanguageLock.acquire()
        defer { LocalizationTestLanguageLock.release() }
        let previous = UserDefaults.standard.object(forKey: languageKey)
        defer { UserDefaults.standard.set(previous, forKey: languageKey) }

        let model = AppModel()
        UserDefaults.standard.set("russian", forKey: languageKey)
        model.setDisplayErrorStatus(.topologyChangedShort)
        #expect(model.errorMessage == "Конфигурация мониторов изменилась")
        UserDefaults.standard.set("english", forKey: languageKey)
        #expect(model.errorMessage == "Monitor configuration changed")
        UserDefaults.standard.set("russian", forKey: languageKey)
        #expect(model.errorMessage == "Конфигурация мониторов изменилась")

        model.errorMessage = "Remote Windows says: недоступно"
        UserDefaults.standard.set("english", forKey: languageKey)
        #expect(model.errorMessage == "Remote Windows says: недоступно")
    }

    private func makeDisplay(id: String = "test-display", name: String, refreshRate: Double) -> DisplayDescriptor {
        DisplayDescriptor(
            id: id, systemID: 1, name: name,
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            pixelWidth: 1920, pixelHeight: 1080, refreshRate: refreshRate,
            isBuiltIn: false, isSystemMain: true
        )
    }
}
