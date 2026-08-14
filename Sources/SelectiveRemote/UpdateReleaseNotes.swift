import AppKit
import Foundation
import SwiftUI

enum UpdateReleaseNotesLanguage: String, Sendable {
    case russian
    case english

    var locale: Locale {
        switch self {
        case .russian: Locale(identifier: "ru")
        case .english: Locale(identifier: "en")
        }
    }

    func text(ru: String, en: String) -> String {
        switch self {
        case .russian: ru
        case .english: en
        }
    }

    static func preferred(defaults: UserDefaults = .standard) -> Self {
        switch defaults.string(forKey: "SelectiveRemote.applicationLanguage.v1") {
        case AppLanguage.russian.rawValue:
            return .russian
        case AppLanguage.english.rawValue:
            return .english
        default:
            let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
            return preferred.hasPrefix("ru") ? .russian : .english
        }
    }
}

struct UpdateReleaseNotesSection: Identifiable, Equatable, Sendable {
    let version: String
    let changes: [String]

    var id: String { version }
}

struct UpdateReleaseNotesHistory: Equatable, Sendable {
    let sections: [UpdateReleaseNotesSection]
    let language: UpdateReleaseNotesLanguage
    let usedBundledFallback: Bool
}

enum UpdateReleaseNotesError: LocalizedError {
    case invalidResponse
    case invalidText
    case targetVersionMissing(String)
    case bundledHistoryMissing

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            UpdateLocalization.text(
                ru: "Сервер истории изменений вернул некорректный ответ.",
                en: "The release-notes server returned an invalid response."
            )
        case .invalidText:
            UpdateLocalization.text(
                ru: "История изменений не является корректным UTF-8 текстом.",
                en: "The release-notes document is not valid UTF-8 text."
            )
        case let .targetVersionMissing(version):
            UpdateLocalization.text(
                ru: "В истории не найдено описание версии \(version).",
                en: "No release notes were found for version \(version)."
            )
        case .bundledHistoryMissing:
            UpdateLocalization.text(
                ru: "Локальная история изменений не найдена в приложении.",
                en: "The bundled release history is missing from the application."
            )
        }
    }
}

enum UpdateReleaseNotesParser {
    static func parse(
        _ markdown: String,
        currentVersion: String,
        targetVersion: String
    ) throws -> [UpdateReleaseNotesSection] {
        let filtered = allSections(markdown)
            .filter {
                compareVersions($0.version, currentVersion) == .orderedDescending
                    && compareVersions($0.version, targetVersion) != .orderedDescending
            }
            .sorted {
                compareVersions($0.version, $1.version) == .orderedDescending
            }

        guard filtered.contains(where: {
            compareVersions($0.version, targetVersion) == .orderedSame
        }) else {
            throw UpdateReleaseNotesError.targetVersionMissing(targetVersion)
        }
        return filtered
    }

    static func parseInstalledHistory(
        _ markdown: String,
        currentVersion: String,
        limit: Int = 12
    ) throws -> [UpdateReleaseNotesSection] {
        let filtered = allSections(markdown)
            .filter {
                compareVersions($0.version, currentVersion) != .orderedDescending
            }
            .sorted {
                compareVersions($0.version, $1.version) == .orderedDescending
            }

        guard filtered.contains(where: {
            compareVersions($0.version, currentVersion) == .orderedSame
        }) else {
            throw UpdateReleaseNotesError.targetVersionMissing(currentVersion)
        }
        return Array(filtered.prefix(max(1, limit)))
    }

    static func compareVersions(
        _ lhsVersion: String,
        _ rhsVersion: String
    ) -> ComparisonResult {
        let lhs = numericComponents(lhsVersion)
        let rhs = numericComponents(rhsVersion)
        let count = max(lhs.count, rhs.count)

        for index in 0..<count {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left < right { return .orderedAscending }
            if left > right { return .orderedDescending }
        }
        return .orderedSame
    }

    private static func allSections(_ markdown: String) -> [UpdateReleaseNotesSection] {
        var sections: [UpdateReleaseNotesSection] = []
        var activeVersion: String?
        var activeChanges: [String] = []

        func flushActiveSection() {
            guard let activeVersion, !activeChanges.isEmpty else { return }
            sections.append(
                UpdateReleaseNotesSection(
                    version: activeVersion,
                    changes: activeChanges
                )
            )
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("## ") {
                flushActiveSection()
                activeChanges = []
                activeVersion = normalizedVersionHeading(String(line.dropFirst(3)))
                continue
            }

            guard activeVersion != nil, line.hasPrefix("- ") else { continue }
            let change = String(line.dropFirst(2))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !change.isEmpty {
                activeChanges.append(change)
            }
        }
        flushActiveSection()
        return sections
    }

    private static func normalizedVersionHeading(_ heading: String) -> String? {
        var value = heading.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("v") || value.hasPrefix("V") {
            value.removeFirst()
        }
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...4).contains(components.count),
              components.allSatisfy({ !$0.isEmpty && Int($0) != nil })
        else { return nil }
        return components.map(String.init).joined(separator: ".")
    }

    private static func numericComponents(_ version: String) -> [Int] {
        var value = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("v") || value.hasPrefix("V") {
            value.removeFirst()
        }
        let result = value.split(separator: ".").map { component -> Int in
            Int(component.prefix(while: { $0.isNumber })) ?? 0
        }
        return result.isEmpty ? [0] : result
    }
}

enum UpdateReleaseNotesService {
    private enum Source {
        case remote(URL)
        case bundled(name: String)
    }

    private struct Candidate {
        let source: Source
        let language: UpdateReleaseNotesLanguage
    }

    private static let russianFallbackURL = URL(
        string: "https://raw.githubusercontent.com/PastFly/Selective-Remote/main/CHANGELOG.md"
    )!
    private static let englishFallbackURL = URL(
        string: "https://raw.githubusercontent.com/PastFly/Selective-Remote/main/CHANGELOG_EN.md"
    )!

    static func fetch(
        manifest: SelectiveRemoteUpdateManifest,
        currentVersion: String,
        language: UpdateReleaseNotesLanguage,
        session: URLSession = .shared,
        bundle: Bundle = .main
    ) async throws -> UpdateReleaseNotesHistory {
        try await fetchFromCandidates(
            updateCandidates(for: manifest, language: language),
            session: session,
            bundle: bundle
        ) { markdown in
            try UpdateReleaseNotesParser.parse(
                markdown,
                currentVersion: currentVersion,
                targetVersion: manifest.version
            )
        }
    }

    static func fetchInstalled(
        currentVersion: String,
        language: UpdateReleaseNotesLanguage,
        limit: Int = 12,
        session: URLSession = .shared,
        bundle: Bundle = .main
    ) async throws -> UpdateReleaseNotesHistory {
        try await fetchFromCandidates(
            generalCandidates(language: language),
            session: session,
            bundle: bundle
        ) { markdown in
            try UpdateReleaseNotesParser.parseInstalledHistory(
                markdown,
                currentVersion: currentVersion,
                limit: limit
            )
        }
    }

    static func fetchPostUpdate(
        previousVersion: String,
        currentVersion: String,
        language: UpdateReleaseNotesLanguage,
        session: URLSession = .shared,
        bundle: Bundle = .main
    ) async throws -> UpdateReleaseNotesHistory {
        try await fetchFromCandidates(
            generalCandidates(language: language),
            session: session,
            bundle: bundle
        ) { markdown in
            try UpdateReleaseNotesParser.parse(
                markdown,
                currentVersion: previousVersion,
                targetVersion: currentVersion
            )
        }
    }

    private static func fetchFromCandidates(
        _ candidates: [Candidate],
        session: URLSession,
        bundle: Bundle,
        parser: (String) throws -> [UpdateReleaseNotesSection]
    ) async throws -> UpdateReleaseNotesHistory {
        var lastError: Error?

        for candidate in candidates {
            do {
                let markdown: String
                let bundled: Bool
                switch candidate.source {
                case let .remote(url):
                    markdown = try await fetchMarkdown(url, session: session)
                    bundled = false
                case let .bundled(name):
                    markdown = try bundledMarkdown(name: name, bundle: bundle)
                    bundled = true
                }
                return UpdateReleaseNotesHistory(
                    sections: try parser(markdown),
                    language: candidate.language,
                    usedBundledFallback: bundled
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }

        throw lastError ?? UpdateReleaseNotesError.bundledHistoryMissing
    }

    private static func updateCandidates(
        for manifest: SelectiveRemoteUpdateManifest,
        language: UpdateReleaseNotesLanguage
    ) -> [Candidate] {
        var result: [Candidate] = []

        func appendRemote(_ url: URL?, language: UpdateReleaseNotesLanguage) {
            guard let url else { return }
            guard !result.contains(where: { candidate in
                if case let .remote(existing) = candidate.source {
                    return existing.absoluteString == url.absoluteString
                }
                return false
            }) else { return }
            result.append(Candidate(source: .remote(url), language: language))
        }

        switch language {
        case .russian:
            appendRemote(manifest.releaseNotesHistoryURL, language: .russian)
            appendRemote(russianFallbackURL, language: .russian)
            appendRemote(manifest.releaseNotesHistoryENURL, language: .english)
            appendRemote(englishFallbackURL, language: .english)
        case .english:
            appendRemote(manifest.releaseNotesHistoryENURL, language: .english)
            appendRemote(englishFallbackURL, language: .english)
            appendRemote(manifest.releaseNotesHistoryURL, language: .russian)
            appendRemote(russianFallbackURL, language: .russian)
        }
        appendBundledFallbacks(to: &result, language: language)
        return result
    }

    private static func generalCandidates(
        language: UpdateReleaseNotesLanguage
    ) -> [Candidate] {
        switch language {
        case .russian:
            return [
                Candidate(source: .bundled(name: "CHANGELOG"), language: .russian),
                Candidate(source: .remote(russianFallbackURL), language: .russian),
                Candidate(source: .bundled(name: "CHANGELOG_EN"), language: .english),
                Candidate(source: .remote(englishFallbackURL), language: .english)
            ]
        case .english:
            return [
                Candidate(source: .bundled(name: "CHANGELOG_EN"), language: .english),
                Candidate(source: .remote(englishFallbackURL), language: .english),
                Candidate(source: .bundled(name: "CHANGELOG"), language: .russian),
                Candidate(source: .remote(russianFallbackURL), language: .russian)
            ]
        }
    }

    private static func appendBundledFallbacks(
        to result: inout [Candidate],
        language: UpdateReleaseNotesLanguage
    ) {
        switch language {
        case .russian:
            result.append(Candidate(source: .bundled(name: "CHANGELOG"), language: .russian))
            result.append(Candidate(source: .bundled(name: "CHANGELOG_EN"), language: .english))
        case .english:
            result.append(Candidate(source: .bundled(name: "CHANGELOG_EN"), language: .english))
            result.append(Candidate(source: .bundled(name: "CHANGELOG"), language: .russian))
        }
    }

    private static func fetchMarkdown(
        _ url: URL,
        session: URLSession
    ) async throws -> String {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 12

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else {
            throw UpdateReleaseNotesError.invalidResponse
        }
        guard let markdown = String(data: data, encoding: .utf8) else {
            throw UpdateReleaseNotesError.invalidText
        }
        return markdown
    }

    private static func bundledMarkdown(
        name: String,
        bundle: Bundle
    ) throws -> String {
        guard let url = bundle.url(forResource: name, withExtension: "md") else {
            throw UpdateReleaseNotesError.bundledHistoryMissing
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw UpdateReleaseNotesError.invalidText
        }
        return text
    }
}

private enum UpdateReleaseNotesPresentation {
    case update(manifest: SelectiveRemoteUpdateManifest, installedVersion: String)
    case installed(version: String)
    case postUpdate(previousVersion: String, currentVersion: String)

    var targetVersion: String {
        switch self {
        case let .update(manifest, _): manifest.version
        case let .installed(version): version
        case let .postUpdate(_, currentVersion): currentVersion
        }
    }

    var identity: String {
        switch self {
        case let .update(manifest, installedVersion):
            "update-\(installedVersion)-\(manifest.version)"
        case let .installed(version):
            "installed-\(version)"
        case let .postUpdate(previousVersion, currentVersion):
            "post-\(previousVersion)-\(currentVersion)"
        }
    }
}

@MainActor
final class UpdateReleaseNotesWindowController: NSObject, NSWindowDelegate {
    static let shared = UpdateReleaseNotesWindowController()

    private var window: NSWindow?
    private var hostingController: NSHostingController<AnyView>?

    func show(
        manifest: SelectiveRemoteUpdateManifest,
        currentVersion: String
    ) {
        show(.update(manifest: manifest, installedVersion: currentVersion))
    }

    func showInstalledHistory(currentVersion: String) {
        show(.installed(version: currentVersion))
    }

    func showPostUpdate(previousVersion: String, currentVersion: String) {
        show(.postUpdate(previousVersion: previousVersion, currentVersion: currentVersion))
    }

    private func show(_ presentation: UpdateReleaseNotesPresentation) {
        let language = UpdateReleaseNotesLanguage.preferred()
        let content = AnyView(
            UpdateReleaseNotesView(
                presentation: presentation,
                language: language,
                onClose: { [weak self] in
                    self?.window?.performClose(nil)
                }
            )
            .id("\(presentation.identity)-\(language.rawValue)")
            .environment(\.locale, language.locale)
        )

        let window: NSWindow
        if let existing = self.window, let hostingController {
            hostingController.rootView = content
            window = existing
        } else {
            let hosting = NSHostingController(rootView: content)
            let created = NSWindow(contentViewController: hosting)
            created.setContentSize(NSSize(width: 780, height: 700))
            created.minSize = NSSize(width: 640, height: 520)
            created.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            created.isReleasedWhenClosed = false
            created.delegate = self
            created.center()

            self.hostingController = hosting
            self.window = created
            window = created
        }

        window.title = language.text(
            ru: "Что нового в \(AppBrand.name)",
            en: "What's New in \(AppBrand.name)"
        )
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct UpdateReleaseNotesView: View {
    let presentation: UpdateReleaseNotesPresentation
    let language: UpdateReleaseNotesLanguage
    let onClose: () -> Void

    @State private var sections: [UpdateReleaseNotesSection] = []
    @State private var displayedLanguage: UpdateReleaseNotesLanguage?
    @State private var usedBundledFallback = false
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 18)

            Divider()

            Group {
                if isLoading {
                    loadingView
                } else if let errorMessage {
                    errorView(errorMessage)
                } else {
                    historyView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                Text(footerText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(language.text(ru: "Готово", en: "Done")) {
                    onClose()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(minWidth: 640, minHeight: 520)
        .task {
            await load()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: headerIcon)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 8) {
                Text(headerTitle)
                    .font(.title2.bold())

                switch presentation {
                case let .update(manifest, installedVersion):
                    versionTransition(
                        leftTitle: language.text(ru: "Установлено", en: "Installed"),
                        leftVersion: versionWithCurrentBuild(installedVersion),
                        rightTitle: language.text(ru: "Доступно", en: "Available"),
                        rightVersion: versionWithBuild(
                            manifest.version,
                            build: String(manifest.build)
                        )
                    )
                case let .installed(version):
                    versionPill(
                        title: language.text(ru: "Установлено", en: "Installed"),
                        version: versionWithCurrentBuild(version),
                        emphasized: true
                    )
                case let .postUpdate(previousVersion, currentVersion):
                    versionTransition(
                        leftTitle: language.text(ru: "Было", en: "Previous"),
                        leftVersion: previousVersion,
                        rightTitle: language.text(ru: "Теперь", en: "Now"),
                        rightVersion: versionWithCurrentBuild(currentVersion)
                    )
                }
            }
            Spacer()
        }
    }

    private var headerIcon: String {
        switch presentation {
        case .postUpdate: "checkmark.seal.fill"
        case .update: "sparkles"
        case .installed: "clock.arrow.circlepath"
        }
    }

    private var headerTitle: String {
        switch presentation {
        case .update, .installed:
            language.text(
                ru: "Что нового в \(AppBrand.name)",
                en: "What's New in \(AppBrand.name)"
            )
        case let .postUpdate(_, currentVersion):
            language.text(
                ru: "\(AppBrand.name) обновлён до \(currentVersion)",
                en: "\(AppBrand.name) was updated to \(currentVersion)"
            )
        }
    }

    private var footerText: String {
        switch presentation {
        case .update:
            language.text(
                ru: "Показаны изменения после установленной версии.",
                en: "Showing changes after the installed version."
            )
        case .installed:
            language.text(
                ru: "История установленной и предыдущих версий.",
                en: "History for the installed and previous versions."
            )
        case .postUpdate:
            language.text(
                ru: "Показаны изменения, полученные при этом обновлении.",
                en: "Showing changes included in this update."
            )
        }
    }

    private func versionWithCurrentBuild(_ version: String) -> String {
        guard let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String,
              !build.isEmpty
        else { return version }
        return versionWithBuild(version, build: build)
    }

    private func versionWithBuild(_ version: String, build: String) -> String {
        "\(version) · \(language.text(ru: "сборка", en: "build")) \(build)"
    }

    @ViewBuilder
    private func versionTransition(
        leftTitle: String,
        leftVersion: String,
        rightTitle: String,
        rightVersion: String
    ) -> some View {
        HStack(spacing: 10) {
            versionPill(title: leftTitle, version: leftVersion, emphasized: false)
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
            versionPill(title: rightTitle, version: rightVersion, emphasized: true)
        }
    }

    private func versionPill(
        title: String,
        version: String,
        emphasized: Bool
    ) -> some View {
        HStack(spacing: 5) {
            Text(title)
            Text(version)
                .monospacedDigit()
                .fontWeight(.semibold)
        }
        .font(.caption)
        .foregroundStyle(emphasized ? Color.accentColor : Color.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            emphasized ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.10),
            in: Capsule()
        )
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text(language.text(
                ru: "Загружаем историю изменений…",
                en: "Loading release history…"
            ))
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(language.text(
                ru: "Не удалось загрузить историю изменений",
                en: "Unable to load release history"
            ))
            .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .textSelection(.enabled)
            Button(language.text(ru: "Повторить", en: "Retry")) {
                Task { await load() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var historyView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if usedBundledFallback {
                    Label(
                        language.text(
                            ru: "Показана история, встроенная в приложение — доступ к сети не требуется.",
                            en: "Showing the release history bundled with the app — no network access is required."
                        ),
                        systemImage: "wifi.slash"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        Color.secondary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .padding(.bottom, 12)
                }

                if let displayedLanguage, displayedLanguage != language {
                    Label(
                        language.text(
                            ru: "Русская история недоступна; показана английская версия.",
                            en: "English release notes are unavailable; showing the Russian version."
                        ),
                        systemImage: "globe"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        Color.secondary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .padding(.bottom, 18)
                }

                ForEach(Array(sections.enumerated()), id: \.element.id) { item in
                    releaseSection(
                        item.element,
                        isLast: item.offset == sections.count - 1
                    )
                }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 22)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func releaseSection(
        _ section: UpdateReleaseNotesSection,
        isLast: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 10) {
                Text(section.version)
                    .font(.title3.bold())
                    .monospacedDigit()

                if UpdateReleaseNotesParser.compareVersions(
                    section.version,
                    presentation.targetVersion
                ) == .orderedSame {
                    Text(language.text(ru: "Последняя", en: "Latest"))
                        .font(.caption.bold())
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array(section.changes.enumerated()), id: \.offset) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Circle()
                            .fill(Color.secondary.opacity(0.65))
                            .frame(width: 5, height: 5)
                        markdownText(item.element)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .textSelection(.enabled)

            if !isLast {
                Divider()
                    .padding(.vertical, 9)
            }
        }
    }

    private func markdownText(_ value: String) -> Text {
        if let attributed = try? AttributedString(markdown: value) {
            return Text(attributed)
        }
        return Text(value)
    }

    @MainActor
    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let history: UpdateReleaseNotesHistory
            switch presentation {
            case let .update(manifest, installedVersion):
                history = try await UpdateReleaseNotesService.fetch(
                    manifest: manifest,
                    currentVersion: installedVersion,
                    language: language
                )
            case let .installed(version):
                history = try await UpdateReleaseNotesService.fetchInstalled(
                    currentVersion: version,
                    language: language
                )
            case let .postUpdate(previousVersion, currentVersion):
                history = try await UpdateReleaseNotesService.fetchPostUpdate(
                    previousVersion: previousVersion,
                    currentVersion: currentVersion,
                    language: language
                )
            }
            guard !Task.isCancelled else { return }
            sections = history.sections
            displayedLanguage = history.language
            usedBundledFallback = history.usedBundledFallback
            isLoading = false
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            sections = []
            displayedLanguage = nil
            usedBundledFallback = false
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }
}
