from pathlib import Path
p=Path('Sources/SelectiveRemote/UnifiedCredentialVault.swift');s=p.read_text();anchor='''    private func persist(_ secrets: [String: String]) throws {'''
hook='''    private func syntheticFault(_ point: String) {
        let env = ProcessInfo.processInfo.environment
        guard env["GITHUB_ACTIONS"] == "true", env["RUNNER_ENVIRONMENT"] == "github-hosted",
              env["USER"] == "runner", let root = env["RUNNER_TEMP"],
              env["SR_GUI_FAULT_PHASE"] == point,
              FileManager.default.fileExists(atPath: root + "/gui-fault-arm") else { return }
        do { try Data(point.utf8).write(to: URL(fileURLWithPath: root + "/gui-fault-reached"), options: .withoutOverwriting) }
        catch { exit(4) }
        fflush(nil)
        raise(SIGSTOP)
        exit(5)
    }

'''+anchor
assert s.count(anchor)==1;s=s.replace(anchor,hook)
a='''        let updateStatus = SecItemUpdate(
            key as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {''';b='''        syntheticFault("before")
        let updateStatus = SecItemUpdate(
            key as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            syntheticFault("after")''';assert s.count(a)==1;s=s.replace(a,b);p.write_text(s)
