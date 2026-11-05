from pathlib import Path
p=Path('Sources/SelectiveRemote/NativeStorageMigration.swift');s=p.read_text()
a='''        try recoverPendingSnippets(defaults)
    }

    static func recoverPendingSnippets'''
b='''        let env = ProcessInfo.processInfo.environment
        if env["GITHUB_ACTIONS"] == "true", env["RUNNER_ENVIRONMENT"] == "github-hosted",
           env["USER"] == "runner", let root = env["RUNNER_TEMP"],
           env["SR_TEST_SNIPPET_FAILURE"] == "1",
           FileManager.default.fileExists(atPath: root + "/snippet-failure-arm") {
            throw MigrationError.incompleteWrite
        }
        try recoverPendingSnippets(defaults)
    }

    static func recoverPendingSnippets'''
assert s.count(a)==1;p.write_text(s.replace(a,b))
