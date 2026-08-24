import Foundation
import Testing
@testable import SelectiveRemote

@Test("Legacy terminal connections decode without transport fields")
func terminalTransportLegacyCodableDefaults() throws {
    let legacy = #"{"kind":"custom","host":"example.test","username":"root","port":22}"#
        .data(using: .utf8)!
    let connection = try JSONDecoder().decode(TerminalTabConnection.self, from: legacy)
    #expect(connection.kind == .custom)
    #expect(connection.serialDevicePath == nil)
    #expect(connection.serialBaudRate == nil)

    let serial = TerminalTabConnection.serial(
        devicePath: "/dev/cu.usbserial-test",
        baudRate: 115_200,
        dataBits: 8,
        parity: .even,
        stopBits: 1,
        flowControl: .hardware
    )
    let restored = try JSONDecoder().decode(
        TerminalTabConnection.self,
        from: JSONEncoder().encode(serial)
    )
    #expect(restored == serial)
}

@Test("Telnet launch uses the bundled transport helper")
func telnetTransportLaunch() throws {
    let connection = TerminalTabConnection.telnet(host: "router.example", port: 2_323)
    let launch = try TerminalTransportService.launchConfiguration(
        connection: connection,
        helperPath: "/Applications/Selective Remote.app/Contents/Helpers/SelectiveRemoteTerminalBridge"
    )
    #expect(launch.arguments == ["telnet", "router.example", "2323"])
    #expect(launch.logKind == .telnet)
    #expect(launch.activityKind == .telnet)
    #expect(launch.target == "router.example:2323")
}

@Test("Serial launch preserves line settings")
func serialTransportLaunch() throws {
    let connection = TerminalTabConnection.serial(
        devicePath: "/dev/cu.usbserial-test",
        baudRate: 57_600,
        dataBits: 7,
        parity: .odd,
        stopBits: 2,
        flowControl: .software
    )
    let launch = try TerminalTransportService.launchConfiguration(
        connection: connection,
        helperPath: "/helper"
    )
    #expect(launch.arguments == [
        "serial", "/dev/cu.usbserial-test", "57600", "7", "odd", "2", "software"
    ])
    #expect(launch.logKind == .serial)
    #expect(launch.target.contains("7O2"))
}

@Test("Terminal transports validate endpoints and explain common failures")
func terminalTransportValidationAndFailures() {
    #expect(!TerminalTabConnection.telnet(host: "", port: 23).isValidTelnetConnection)
    #expect(!TerminalTabConnection.serial(devicePath: "/dev/tty.usbserial").isValidSerialConnection)
    #expect(
        TerminalTransportService.userFacingFailure(
            output: "Telnet: cannot connect to router:23",
            connection: .telnet(host: "router"),
            exitCode: 69
        )?.contains("Telnet-сервер недоступен") == true
    )
    #expect(
        TerminalTransportService.userFacingFailure(
            output: "Serial: device is already in use.",
            connection: .serial(devicePath: "/dev/cu.test"),
            exitCode: 73
        )?.contains("уже используется") == true
    )
}

@Test("Distribution build bundles, verifies and signs Terminal Transport Helper")
func terminalTransportHelperBuildIntegration() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let buildScript = try String(
        contentsOf: root.appendingPathComponent("scripts/build_app.sh"),
        encoding: .utf8
    )
    #expect(buildScript.contains("SelectiveRemoteTerminalBridge"))
    #expect(buildScript.contains("verify_portable_binary \"$TERMINAL_BRIDGE_HELPER\""))
    #expect(buildScript.contains("sign_code \"$TERMINAL_BRIDGE_HELPER\""))
}
