import Testing
@testable import SelectiveRemote

@Suite("Forwarding Manager runtime copy")
struct ForwardingRuntimeLocalizationTests {
    @Test("Summary, direct route, and log heading follow the selected language")
    func visibleLabels() {
        #expect(ForwardingManagerCopy.summaryTitle(.active, english: true) == "Active tunnels")
        #expect(ForwardingManagerCopy.summaryTitle(.profile, english: false) == "Туннель профиля")
        #expect(ForwardingManagerCopy.summaryTitle(.independent, english: false) == "Независимый туннель")
        #expect(ForwardingManagerCopy.errorDetail(hasErrors: false, english: true) == "no problems")
        #expect(ForwardingManagerCopy.errorDetail(hasErrors: true, english: true) == "needs attention")
        #expect(ForwardingManagerCopy.hopTitle(count: 1, english: false) == "Напрямую")
        #expect(ForwardingManagerCopy.logHeading(english: false) == "Журнал SSH-туннеля")
    }

    @Test("Generated log labels localize while values remain exact")
    func logSummaryLabels() {
        #expect(ForwardingManagerCopy.logSummaryHeading(english: false) == "[Selective Remote] Сводка работы туннеля")
        #expect(ForwardingManagerCopy.logLine(.state, value: "Работает", english: false) == "Состояние: Работает")
        #expect(ForwardingManagerCopy.logLine(.ownership, value: "Custom team", english: false) == "Принадлежность: Custom team")
        #expect(ForwardingManagerCopy.ownershipTitle(.profile, english: false) == "Профиль")
        #expect(ForwardingManagerCopy.logLine(.lastRuntimeError, value: "raw OpenSSH output", english: true) == "Last runtime error: raw OpenSSH output")
        #expect(ForwardingManagerCopy.listenerStatus(confirmed: false, english: false) == "ещё не подтверждён")
    }
}
