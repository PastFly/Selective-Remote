from pathlib import Path
p=Path('Sources/SelectiveRemote/AppModel.swift');s=p.read_text();needle='''        guard let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(data, forKey: profilesKey)'''
hook='''        guard let data = try? JSONEncoder().encode(profiles) else { return }
        func syntheticFault(_ point: String) {
            let env = ProcessInfo.processInfo.environment
            guard env["GITHUB_ACTIONS"] == "true", env["RUNNER_ENVIRONMENT"] == "github-hosted",
                  env["USER"] == "runner", let root = env["RUNNER_TEMP"],
                  env["SR_GUI_FAULT_PHASE"] == point,
                  FileManager.default.fileExists(atPath: root + "/gui-fault-arm") else { return }
            do {
                try Data(point.utf8).write(to: URL(fileURLWithPath: root + "/gui-fault-reached"), options: .withoutOverwriting)
            } catch { exit(4) }
            fflush(nil)
            raise(SIGSTOP)
            exit(5)
        }
        syntheticFault("before")
        UserDefaults.standard.set(data, forKey: profilesKey)
        syntheticFault("after")'''
assert s.count(needle)==1;p.write_text(s.replace(needle,hook))
