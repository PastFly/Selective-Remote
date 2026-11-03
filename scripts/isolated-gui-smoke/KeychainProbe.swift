import CryptoKit
import Darwin
import Foundation
import Security

func fail(_ message: String) -> Never { fputs("KEYCHAIN_BLOCKED: \(message)\n", stderr); exit(2) }
let env = ProcessInfo.processInfo.environment
var console = stat()
guard env["GITHUB_ACTIONS"] == "true", env["USER"] == "runner", getuid() > 0,
      stat("/dev/console", &console) == 0, console.st_uid == getuid(),
      let temp = env["RUNNER_TEMP"], CommandLine.arguments.count == 3,
      CommandLine.arguments[1] == "031" || CommandLine.arguments[1] == "032",
      [temp + "/evidence/baseline-persistence.json", temp + "/evidence/rdp-baseline.json"].contains(CommandLine.arguments[2]) else { fail("isolated runner identity") }
let version = CommandLine.arguments[1]
let isRDP = CommandLine.arguments[2].hasSuffix("/rdp-baseline.json")
guard let data = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])),
      let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let host = report["baselineHost"] as? [String: Any],
      host["friendlyName"] as? String == (isRDP ? "TEST-ONLY-CODEX-RDP" : "TEST-ONLY-CODEX-UPGRADE-HOST"),
      let rawID = host["id"] as? String, let hostID = UUID(uuidString: rawID)?.uuidString else { fail("synthetic host identity") }
let service = "local.selectiveremote.credentials.unified." + (version == "031" ? "v1" : "v2")
let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service, kSecAttrAccount as String: "credential-vault",
    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
    kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
var raw: CFTypeRef?
let status = SecItemCopyMatching(query as CFDictionary, &raw)
guard status == errSecSuccess, let payload = raw as? Data,
      let values = try? JSONSerialization.jsonObject(with: payload) as? [String: String] else {
    fail("credential missing or unavailable, status=\(status)")
}
if isRDP {
    guard values["local.selectiveremote.credentials\u{1f}\(hostID)"] == "TEST-ONLY-CODEX-RDP-SECRET",
          values["local.selectiveremote.credentials\u{1f}\(hostID).gateway"] == "TEST-ONLY-CODEX-GATEWAY-SECRET" else { fail("synthetic RDP or gateway credential missing") }
    print("SYNTHETIC_RDP_GATEWAY_KEYCHAIN_\(version)=PASS")
} else {
    guard values["local.selectiveremote.credentials.v2\u{1f}\(hostID).ssh"] == "TEST-ONLY-CODEX-UPGRADE-SECRET" else { fail("synthetic SSH credential missing") }
    print("SYNTHETIC_KEYCHAIN_\(version)=PASS")
}
