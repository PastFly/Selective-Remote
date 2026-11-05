from pathlib import Path
p=Path('Sources/SelectiveRemote/NativeStorageMigration.swift');s=p.read_text();assert s.count('import Foundation')==1;s=s.replace('import Foundation','import Darwin\nimport Foundation',1)
anchor='''    static func prepare(_ defaults: any NativePreferencesAccess) throws {'''
hook='''    private static func syntheticMigrationFault(_ point: String) {
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
a='''            guard defaults.synchronize(), defaults.object(forKey: snapshotKey) as? Data == bytes else { throw MigrationError.incompleteWrite }
            snapshot = source''';b='''            guard defaults.synchronize(), defaults.object(forKey: snapshotKey) as? Data == bytes else { throw MigrationError.incompleteWrite }
            syntheticMigrationFault("after-snapshot")
            snapshot = source''';assert s.count(a)==1;s=s.replace(a,b)
a='''        guard defaults.synchronize(), defaults.object(forKey: markerKey) as? String == complete else { throw MigrationError.incompleteWrite }
    }

    private static func decodeSnapshot''';b='''        guard defaults.synchronize(), defaults.object(forKey: markerKey) as? String == complete else { throw MigrationError.incompleteWrite }
        syntheticMigrationFault("after-marker")
    }

    private static func decodeSnapshot''';assert s.count(a)==1;s=s.replace(a,b);p.write_text(s)
