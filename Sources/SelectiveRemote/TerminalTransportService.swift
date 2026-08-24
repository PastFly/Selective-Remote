import Foundation

struct TerminalTransportLaunchConfiguration: Equatable {
    let executable: String
    let arguments: [String]
    let title: String
    let logKind: TerminalSessionLogKind
    let activityKind: ConnectionActivityKind
    let target: String
}

enum TerminalTransportServiceError: LocalizedError, Equatable {
    case helperUnavailable
    case invalidTelnetEndpoint
    case invalidSerialConfiguration

    var errorDescription: String? {
        switch self {
        case .helperUnavailable:
            "В сборке отсутствует Terminal Transport Helper. Переустановите Selective Remote."
        case .invalidTelnetEndpoint:
            "Укажите корректный адрес и порт Telnet."
        case .invalidSerialConfiguration:
            "Выберите доступное устройство /dev/cu.* и корректные параметры Serial."
        }
    }
}

enum TerminalTransportService {
    static let supportedBaudRates = [
        300, 600, 1_200, 2_400, 4_800, 9_600, 19_200, 38_400, 57_600, 115_200
    ]

    static func availableSerialDevices(fileManager: FileManager = .default) -> [String] {
        let names = (try? fileManager.contentsOfDirectory(atPath: "/dev")) ?? []
        return names
            .filter { $0.hasPrefix("cu.") }
            .map { "/dev/\($0)" }
            .sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    static func helperPath(
        bundleURL: URL = Bundle.main.bundleURL,
        executableURL: URL? = Bundle.main.executableURL,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        let bundled = bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent("SelectiveRemoteTerminalBridge")
            .path
        var candidates = [bundled]
        if let executableURL {
            candidates.append(
                executableURL.deletingLastPathComponent()
                    .appendingPathComponent("SelectiveRemoteTerminalBridge")
                    .path
            )
        }
        return candidates.first(where: isExecutable)
    }

    static func launchConfiguration(
        connection: TerminalTabConnection,
        helperPath: String? = nil,
        helperLookup: () -> String? = { TerminalTransportService.helperPath() }
    ) throws -> TerminalTransportLaunchConfiguration {
        guard let executable = helperPath ?? helperLookup() else {
            throw TerminalTransportServiceError.helperUnavailable
        }
        switch connection.kind {
        case .telnet:
            guard connection.isValidTelnetConnection else {
                throw TerminalTransportServiceError.invalidTelnetEndpoint
            }
            let target = "\(connection.normalizedHost):\(connection.port)"
            return TerminalTransportLaunchConfiguration(
                executable: executable,
                arguments: ["telnet", connection.normalizedHost, String(connection.port)],
                title: "Telnet · \(target)",
                logKind: .telnet,
                activityKind: .telnet,
                target: target
            )
        case .serial:
            guard connection.isValidSerialConnection,
                  let device = connection.serialDevicePath,
                  let baudRate = connection.serialBaudRate,
                  let dataBits = connection.serialDataBits,
                  let stopBits = connection.serialStopBits
            else { throw TerminalTransportServiceError.invalidSerialConfiguration }
            let parity = connection.serialParity ?? .none
            let flow = connection.serialFlowControl ?? .none
            return TerminalTransportLaunchConfiguration(
                executable: executable,
                arguments: [
                    "serial", device, String(baudRate), String(dataBits),
                    parity.rawValue, String(stopBits), flow.rawValue
                ],
                title: "Serial · \(URL(fileURLWithPath: device).lastPathComponent)",
                logKind: .serial,
                activityKind: .serial,
                target: "\(device) · \(baudRate) baud · \(dataBits)\(parity.rawValue.prefix(1).uppercased())\(stopBits)"
            )
        default:
            throw TerminalTransportServiceError.invalidTelnetEndpoint
        }
    }

    static func userFacingFailure(
        output: String,
        connection: TerminalTabConnection,
        exitCode: Int32
    ) -> String? {
        guard exitCode != 0 else { return nil }
        let normalized = output.lowercased()
        switch connection.kind {
        case .telnet where normalized.contains("telnet: cannot resolve"):
            return "Не удалось разрешить адрес Telnet-сервера. Проверьте hostname или IP."
        case .telnet where normalized.contains("telnet: cannot connect"):
            return "Telnet-сервер недоступен. Проверьте адрес, порт и сетевой доступ."
        case .serial where normalized.contains("already in use"):
            return "Serial-устройство уже используется другим приложением."
        case .serial where normalized.contains("serial: cannot open"):
            return "Не удалось открыть Serial-устройство. Проверьте подключение и права доступа."
        default:
            return nil
        }
    }
}
