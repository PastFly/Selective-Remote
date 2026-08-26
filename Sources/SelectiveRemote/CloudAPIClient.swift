import Foundation

enum SelectiveRemoteCloudError: LocalizedError, Equatable {
    case invalidEndpoint
    case insecureEndpoint
    case invalidResponse
    case serviceError(Int, String?)
    case incompatibleAPI(Int)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            UpdateLocalization.text(
                ru: "Укажите корректный адрес Selective Remote Cloud.",
                en: "Enter a valid Selective Remote Cloud address."
            )
        case .insecureEndpoint:
            UpdateLocalization.text(
                ru: "Для Cloud требуется HTTPS. HTTP разрешён только для localhost.",
                en: "Cloud requires HTTPS. HTTP is allowed only for localhost."
            )
        case .invalidResponse:
            UpdateLocalization.text(
                ru: "Cloud вернул некорректный ответ.",
                en: "Cloud returned an invalid response."
            )
        case let .serviceError(status, code):
            UpdateLocalization.text(
                ru: "Cloud недоступен (HTTP \(status)\(code.map { ": \($0)" } ?? "")).",
                en: "Cloud is unavailable (HTTP \(status)\(code.map { ": \($0)" } ?? ""))."
            )
        case let .incompatibleAPI(version):
            UpdateLocalization.text(
                ru: "Версия Cloud API \(version) пока не поддерживается.",
                en: "Cloud API version \(version) is not supported yet."
            )
        }
    }
}

struct SelectiveRemoteCloudMetadata: Codable, Equatable, Sendable {
    var apiVersion: Int
    var vaultSchemaVersion: Int
    var registrationEnabled: Bool
}

enum SelectiveRemoteCloudEndpoint {
    static let production = "https://cloud.pastfly.ru"

    static func normalized(_ value: String) throws -> URL {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              let host = url.host,
              !host.isEmpty,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil
        else { throw SelectiveRemoteCloudError.invalidEndpoint }

        let isLocal = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (scheme == "http" && isLocal) else {
            throw SelectiveRemoteCloudError.insecureEndpoint
        }
        return url
    }
}

final class SelectiveRemoteCloudAPIClient: @unchecked Sendable {
    private let session: URLSession
    private let decoder = JSONDecoder()

    init(session: URLSession = .shared) {
        self.session = session
    }

    func metadata(endpoint: URL) async throws -> SelectiveRemoteCloudMetadata {
        let url = endpoint.appending(path: "v1/meta")
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("SelectiveRemote/\(AppBuildInfo.version)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SelectiveRemoteCloudError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let service = try? decoder.decode(CloudServiceError.self, from: data)
            throw SelectiveRemoteCloudError.serviceError(http.statusCode, service?.error)
        }
        guard let metadata = try? decoder.decode(SelectiveRemoteCloudMetadata.self, from: data) else {
            throw SelectiveRemoteCloudError.invalidResponse
        }
        guard metadata.apiVersion == 1 else {
            throw SelectiveRemoteCloudError.incompatibleAPI(metadata.apiVersion)
        }
        return metadata
    }
}

private struct CloudServiceError: Decodable {
    var error: String
}
