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
      [temp + "/evidence/baseline-persistence.json", temp + "/evidence/late-persistence.json", temp + "/evidence/mixed-persistence.json", temp + "/evidence/collections.json", temp + "/evidence/both-collections.json"].contains(CommandLine.arguments[2]) else { fail("isolated runner identity") }
let version = CommandLine.arguments[1]
let late = CommandLine.arguments[2].hasSuffix("/late-persistence.json")
let liveOld = CommandLine.arguments[2].hasSuffix("/collections.json")
let liveCurrent = CommandLine.arguments[2].hasSuffix("/both-collections.json")
let current = CommandLine.arguments[2].hasSuffix("/mixed-persistence.json")
guard (!(current || liveCurrent) || version == "032") && (!liveOld || version == "031") else { fail("credential version") }
guard let data = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])),
      let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let host = report["baselineHost"] as? [String: Any],
      host["friendlyName"] as? String == (liveOld ? "TEST-ONLY-CODEX-LIVE-OLD" : liveCurrent ? "TEST-ONLY-CODEX-LIVE-NEW" : current ? "TEST-ONLY-CODEX-CURRENT-HOST" : late ? "TEST-ONLY-CODEX-LATE-HOST" : "TEST-ONLY-CODEX-UPGRADE-HOST"),
      let rawID = host["id"] as? String, let hostID = UUID(uuidString: rawID)?.uuidString else { fail("synthetic host identity") }
let service = "local.selectiveremote.credentials.unified." + (version == "031" ? "v1" : "v2")
let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service, kSecAttrAccount as String: "credential-vault",
    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
    kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
var raw: CFTypeRef?
let status = SecItemCopyMatching(query as CFDictionary, &raw)
guard status == errSecSuccess, let payload = raw as? Data,
      let values = try? JSONSerialization.jsonObject(with: payload) as? [String: String],
      values["local.selectiveremote.credentials.v2\u{1f}\(hostID).ssh"] == (liveOld ? "TEST-ONLY-CODEX-LIVE-OLD-SECRET" : liveCurrent ? "TEST-ONLY-CODEX-LIVE-NEW-SECRET" : current ? "TEST-ONLY-CODEX-CURRENT-SECRET" : late ? "TEST-ONLY-CODEX-LATE-SECRET" : "TEST-ONLY-CODEX-UPGRADE-SECRET") else {
    fail("credential missing or unavailable, status=\(status)")
}
print("SYNTHETIC_KEYCHAIN_\(version)=PASS")
