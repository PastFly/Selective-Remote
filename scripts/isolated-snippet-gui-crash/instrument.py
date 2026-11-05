from pathlib import Path
p=Path('Sources/SelectiveRemote/NativeStorageMigration.swift');s=p.read_text();assert s.count('import Foundation')==1;s=s.replace('import Foundation','import Darwin\nimport Foundation',1)
anchor='''    /// The journal is committed before either collection is changed. A restart'''
hook='''    private static func syntheticFault(_ point: String) {
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
a='''        try recoverPendingSnippets(defaults)
    }

    static func recoverPendingSnippets''';b='''        syntheticFault("after-journal")
        try recoverPendingSnippets(defaults)
    }

    static func recoverPendingSnippets''';assert s.count(a)==1;s=s.replace(a,b)
a='''        defaults.set(groups, forKey: groupKey)
        defaults.set(templates, forKey: templateKey)''';b='''        defaults.set(groups, forKey: groupKey)
        syntheticFault("after-groups")
        defaults.set(templates, forKey: templateKey)''';assert s.count(a)==1;s=s.replace(a,b)
a='''        guard defaults.synchronize(), defaults.object(forKey: snippetJournalKey) == nil else { throw MigrationError.incompleteWrite }
    }

    private static func recoverPendingRestore''';b='''        guard defaults.synchronize(), defaults.object(forKey: snippetJournalKey) == nil else { throw MigrationError.incompleteWrite }
        syntheticFault("after-clear")
    }

    private static func recoverPendingRestore''';assert s.count(a)==1;s=s.replace(a,b);p.write_text(s)
