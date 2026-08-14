import Foundation
import Testing
@testable import SelectiveRemote

struct ProjectSupportTests {
    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot().appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    @Test("Ссылки поддержки ведут на точные HTTPS-цели")
    func supportURLsAreExactAndSecure() throws {
        let yoomoney = try #require(
            URLComponents(url: ProjectSupport.yoomoneyURL, resolvingAgainstBaseURL: false)
        )
        let boosty = try #require(
            URLComponents(url: ProjectSupport.boostyURL, resolvingAgainstBaseURL: false)
        )
        let sberbank = try #require(
            URLComponents(url: ProjectSupport.sberbankURL, resolvingAgainstBaseURL: false)
        )

        #expect(yoomoney.scheme == "https")
        #expect(yoomoney.host == "yoomoney.ru")
        #expect(yoomoney.path == "/to/4100119600001192")
        #expect(yoomoney.queryItems == nil)

        #expect(boosty.scheme == "https")
        #expect(boosty.host == "boosty.to")
        #expect(boosty.path == "/pastfly/single-payment/donation/821124/target")
        #expect(boosty.queryItems == [URLQueryItem(name: "share", value: "target_link")])

        #expect(sberbank.scheme == "https")
        #expect(sberbank.host == "messenger.sbrf.ru")
        #expect(sberbank.path == "/sl/0pRZ8zDZzpoim1on3")
        #expect(sberbank.queryItems == nil)
    }

    @Test("Поддержка доступна из справки и системного меню")
    func supportEntryPointsExist() throws {
        let help = try source("Sources/SelectiveRemote/AppHelpView.swift")
        let app = try source("Sources/SelectiveRemote/SelectiveRemoteApp.swift")
        let funding = try source(".github/FUNDING.yml")

        #expect(help.contains("openURL(ProjectSupport.yoomoneyURL)"))
        #expect(help.contains("supportProjectYoomoneyButton"))
        #expect(help.contains("supportProjectMenu"))
        #expect(help.contains("openURL(ProjectSupport.boostyURL)"))
        #expect(help.contains("supportProjectBoostyButton"))
        #expect(help.contains("openURL(ProjectSupport.sberbankURL)"))
        #expect(help.contains("supportProjectSberbankButton"))
        #expect(app.contains("NSWorkspace.shared.open(ProjectSupport.yoomoneyURL)"))
        #expect(app.contains("NSWorkspace.shared.open(ProjectSupport.boostyURL)"))
        #expect(app.contains("NSWorkspace.shared.open(ProjectSupport.sberbankURL)"))
        #expect(funding.contains(ProjectSupport.yoomoneyURL.absoluteString))
        #expect(funding.contains(ProjectSupport.boostyURL.absoluteString))
        #expect(funding.contains(ProjectSupport.sberbankURL.absoluteString))
    }
}
