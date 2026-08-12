import Foundation
import Testing
@testable import SelectiveRemote

@Test("Старый профиль без типа мигрирует как RDP")
func migratesLegacyProfileToRDP() throws {
    let data = Data(
        """
        {
          "friendlyName": "Legacy",
          "host": "rdp.example.local",
          "username": "user"
        }
        """.utf8
    )

    let profile = try JSONDecoder().decode(ConnectionProfile.self, from: data)

    #expect(profile.connectionType == .rdp)
    #expect(profile.sshPort == 22)
    #expect(profile.portForwards.isEmpty)
}

@Test("Встроенный SSH получает безопасные аргументы без URL-обработчика")
func buildsEmbeddedSSHArguments() throws {
    var profile = ConnectionProfile(connectionType: .ssh)
    profile.host = "server.example.com"
    profile.username = "alice"
    profile.sshPort = 2_222

    let settings = try SSHConnectionSettings(profile: profile, identity: nil)
    let arguments = SSHService.interactiveSSHArguments(settings: settings)
    #expect(
        arguments == [
            "-p", "2222",
            "-o", "StrictHostKeyChecking=accept-new",
            "-S", "none",
            "-o", "ControlMaster=no",
            "-o", "User=alice",
            "-o", "PreferredAuthentications=publickey,keyboard-interactive,password",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-tt",
            "server.example.com"
        ]
    )
    #expect(!arguments.contains(where: { $0.hasPrefix("ssh://") }))
}

@Test("ssh-copy-id получает только отдельные аргументы и выбранный public key")
func buildsPublicKeyInstallationArguments() throws {
    var profile = ConnectionProfile(connectionType: .ssh)
    profile.host = "server.example.com"
    profile.username = "alice"
    profile.sshPort = 2200
    let settings = try SSHConnectionSettings(profile: profile, identity: nil)
    let controlPath = SSHService.controlPath(settings: settings)

    #expect(
        SSHService.copyPublicKeyArguments(
            settings: settings,
            publicKeyPath: "/Users/alice/.ssh/id_ed25519.pub"
        ) == [
            "-i", "/Users/alice/.ssh/id_ed25519.pub",
            "-p", "2200",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=60",
            "-o", "User=alice",
            "server.example.com"
        ]
    )
}

@Test("Установка SSH-ключа только дописывает authorized_keys и сохраняет старые ключи")
func appendsPublicKeyWithoutReplacingAuthorizedKeys() throws {
    var profile = ConnectionProfile(connectionType: .ssh)
    profile.host = "server.example.com"
    profile.username = "alice"
    profile.sshPort = 2200
    let settings = try SSHConnectionSettings(profile: profile, identity: nil)
    let publicKey = "ssh-ed25519 AAAATEST selective-remote"
    let arguments = SSHService.appendPublicKeyArguments(
        settings: settings,
        publicKeyText: publicKey
    )
    let remoteCommand = arguments.last ?? ""

    #expect(arguments.contains("server.example.com"))
    #expect(arguments.contains("ControlMaster=no"))
    #expect(remoteCommand.contains("grep -qxF"))
    #expect(remoteCommand.contains(">> \"$HOME/.ssh/authorized_keys\""))
    #expect(!remoteCommand.contains("; > \"$HOME/.ssh/authorized_keys\""))
    #expect(remoteCommand.contains("chmod 600"))
}

@Test("SFTP использует ControlPath активной SSH-сессии")
func reusesActiveSSHControlSocketForSFTP() throws {
    var profile = ConnectionProfile(connectionType: .ssh)
    profile.host = "server.example.com"
    profile.username = "alice"
    profile.sshPort = 2200
    let settings = try SSHConnectionSettings(profile: profile, identity: nil)
    let arguments = SFTPService.connectionArguments(settings: settings)
    let controlPath = SSHService.controlPath(settings: settings)

    #expect(arguments.contains("ControlPath=\(controlPath)"))
    #expect(arguments.contains("ControlMaster=no"))
    #expect(arguments.contains("BatchMode=yes"))
    #expect(!arguments.contains("ControlMaster=auto"))
    #expect(!arguments.contains("NumberOfPasswordPrompts=1"))
    #expect(!arguments.contains("-b"))
    #expect(controlPath.utf8.count < 100)

    let masterArguments = SFTPService.persistentMasterArguments(settings: settings)
    #expect(masterArguments.contains("ControlPath=\(controlPath)"))
    #expect(masterArguments.contains("ControlMaster=yes"))
    #expect(masterArguments.contains("ControlPersist=600"))
    #expect(masterArguments.contains("BatchMode=no"))
    #expect(masterArguments.contains("NumberOfPasswordPrompts=1"))
    #expect(masterArguments.contains("PreferredAuthentications=publickey,keyboard-interactive,password"))
    #expect(masterArguments.contains("ConnectTimeout=15"))
    #expect(masterArguments.contains("-N"))

    var changedProfile = profile
    changedProfile.host = "other.example.com"
    let changedSettings = try SSHConnectionSettings(profile: changedProfile, identity: nil)
    #expect(SSHService.controlPath(settings: changedSettings) != controlPath)
}

@Test("SSH режим пароля отключает public key fallback")
func passwordOnlyAuthenticationArguments() throws {
    var profile = ConnectionProfile(connectionType: .ssh)
    profile.host = "server.example.com"
    profile.sshAuthenticationMode = .password
    let settings = try SSHConnectionSettings(profile: profile, identity: nil)
    let arguments = SSHService.commonSSHArguments(settings: settings, batchMode: false)
    #expect(arguments.contains("PreferredAuthentications=keyboard-interactive,password"))
    #expect(arguments.contains("PubkeyAuthentication=no"))
}

@Test("SSH proxy добавляет ProxyCommand для SOCKS5")
func socksProxyArguments() throws {
    var profile = ConnectionProfile(connectionType: .ssh)
    profile.host = "server.example.com"
    profile.sshProxyMode = .socks5
    profile.sshProxyHost = "127.0.0.1"
    profile.sshProxyPort = 1080
    let settings = try SSHConnectionSettings(profile: profile, identity: nil)
    let arguments = SSHService.commonSSHArguments(settings: settings, batchMode: false)
    let proxy = arguments.first(where: { $0.hasPrefix("ProxyCommand=") }) ?? ""
    #expect(proxy.contains("SelectiveRemoteSSHProxy"))
    #expect(proxy.contains("socks5"))
    #expect(proxy.contains("127.0.0.1"))
    #expect(proxy.contains("1080"))
    #expect(!proxy.contains("password"))
}

@Test("Активная SSH-сессия не требует повторной загрузки ключа в ssh-agent")
func activeSSHSessionSkipsAgentPreparation() {
    #expect(
        SSHKeyService.shouldLoadIdentityIntoAgent(
            hasIdentity: true,
            hasActiveControlSession: false
        )
    )
    #expect(
        !SSHKeyService.shouldLoadIdentityIntoAgent(
            hasIdentity: true,
            hasActiveControlSession: true
        )
    )
    #expect(
        !SSHKeyService.shouldLoadIdentityIntoAgent(
            hasIdentity: false,
            hasActiveControlSession: false
        )
    )
}

@Test("Фоновый SSH-туннель использует отдельный управляемый процесс")
func tunnelUsesDedicatedConnection() throws {
    var profile = ConnectionProfile(connectionType: .ssh)
    profile.host = "server.example.com"
    let settings = try SSHConnectionSettings(profile: profile, identity: nil)
    let arguments = SSHService.commonSSHArguments(
        settings: settings,
        batchMode: true,
        multiplexing: false
    )

    #expect(arguments.contains("ControlMaster=no"))
    #expect(arguments.contains("none"))
    #expect(!arguments.contains("ControlMaster=auto"))
    #expect(arguments.contains("BatchMode=yes"))
    #expect(!arguments.contains("ControlPersist=60"))
}

@Test("SFTP передаёт папки рекурсивно и безопасно цитирует пробелы")
func buildsRecursiveSFTPCommands() throws {
    let local = URL(fileURLWithPath: "/tmp/Local Folder")

    #expect(
        try SFTPService.uploadCommand(
            localURL: local,
            remotePath: "/srv/Remote Folder",
            isDirectory: true
        ) == #"put -pR "/tmp/Local Folder" "/srv/Remote Folder""#
    )
    #expect(
        try SFTPService.downloadCommand(
            remotePath: "/srv/Remote Folder",
            localURL: local,
            isDirectory: true
        ) == #"get -pR "/srv/Remote Folder" "/tmp/Local Folder""#
    )
    #expect(
        try SFTPService.uploadFileContentsCommand(
            localURL: local,
            remotePath: "/srv/config.ini"
        ) == #"put "/tmp/Local Folder" "/srv/config.ini""#
    )
    #expect(
        try SFTPService.uploadCommand(
            localURL: local,
            remotePath: "/srv/file.bin",
            isDirectory: false,
            resume: true
        ) == #"reput -p "/tmp/Local Folder" "/srv/file.bin""#
    )
    #expect(
        try SFTPService.downloadCommand(
            remotePath: "/srv/file.bin",
            localURL: local,
            isDirectory: false,
            resume: true
        ) == #"reget -p "/srv/file.bin" "/tmp/Local Folder""#
    )
}

@Test("Генерация ключа не перезаписывает существующий файл")
func refusesExistingKeyGenerationTarget() throws {
    let target = FileManager.default.temporaryDirectory
        .appendingPathComponent("SelectiveRemote-existing-\(UUID().uuidString)")
    try Data("occupied".utf8).write(to: target)
    defer { try? FileManager.default.removeItem(at: target) }

    #expect(throws: SSHKeyServiceError.self) {
        try SSHKeyService.prepareGeneration(
            SSHKeyGenerationRequest(
                algorithm: .ed25519,
                path: target.path,
                comment: "test"
            )
        )
    }
}

@Test("Генерация ключа требует абсолютный путь")
func rejectsRelativeKeyGenerationPath() {
    #expect(throws: SSHKeyServiceError.self) {
        try SSHKeyService.prepareGeneration(
            SSHKeyGenerationRequest(
                algorithm: .rsa4096,
                path: "relative/id_rsa",
                comment: "test"
            )
        )
    }
}

@Test("Passphrase нового ключа не передаётся в аргументах ssh-keygen")
func buildsInteractiveKeyGenerationArguments() throws {
    let parent = FileManager.default.temporaryDirectory
        .appendingPathComponent("SelectiveRemote-keygen-\(UUID().uuidString)")
    let target = parent.appendingPathComponent("id_ed25519")
    defer { try? FileManager.default.removeItem(at: parent) }

    let command = try SSHKeyService.prepareGeneration(
        SSHKeyGenerationRequest(
            algorithm: .ed25519,
            path: target.path,
            comment: "SelectiveRemote test"
        )
    )

    #expect(
        command.arguments == [
            "-t", "ed25519",
            "-a", "64",
            "-f", target.path,
            "-C", "SelectiveRemote test"
        ]
    )
    #expect(!command.arguments.contains("-N"))
    #expect(!command.arguments.contains("--new-passphrase"))
}

@Test("Host с управляющей shell-пунктуацией отклоняется")
func rejectsUnsafeSSHHost() {
    var profile = ConnectionProfile(connectionType: .ssh)
    profile.host = "server.example.com;touch"

    #expect(throws: SSHServiceError.self) {
        try SSHConnectionSettings(profile: profile, identity: nil)
    }
}

@Test("Локальный forwarding формируется одним аргументом OpenSSH")
func buildsLocalForwarding() throws {
    var rule = PortForwardRule(kind: .local)
    rule.bindAddress = "127.0.0.1"
    rule.sourcePort = 5_432
    rule.destinationHost = "db.internal"
    rule.destinationPort = 5_432

    #expect(
        try SSHService.forwardingArguments(rule)
            == ["-L", "127.0.0.1:5432:db.internal:5432"]
    )
}

@Test("SOCKS forwarding не требует конечного host")
func buildsDynamicForwarding() throws {
    var rule = PortForwardRule(kind: .dynamic)
    rule.bindAddress = "127.0.0.1"
    rule.sourcePort = 1_080

    #expect(
        try SSHService.forwardingArguments(rule)
            == ["-D", "127.0.0.1:1080"]
    )
}

@Test("SFTP parser сохраняет пробелы в именах и ставит папки первыми")
func parsesSFTPListing() {
    let output = """
    drwxr-xr-x    3 alice staff        96 Jul 27 12:00 Project Files
    -rw-r--r--    1 alice staff      2048 Jul 27 12:01 release notes.txt
    lrwxr-xr-x    1 alice staff        12 Jul 27 12:02 current -> Project Files
    """

    let entries = SFTPService.parseListing(output)

    #expect(entries.map(\.name) == ["Project Files", "current", "release notes.txt"])
    #expect(entries[0].isDirectory)
    #expect(entries[1].isSymbolicLink)
    #expect(entries[2].size == 2_048)
    #expect(entries[0].owner == "alice")
    #expect(entries[0].group == "staff")
    #expect(entries[0].permissions == "drwxr-xr-x")
    #expect(entries[0].modeText == "0755")
    #expect(entries[2].modifiedText == "Jul 27 12:01")
}

@Test("SFTP parser читает реальный каталог Debian с приглашением OpenSSH")
func parsesDebianSFTPListingWithPromptAndUnknownLinkCount() {
    let output = """
    Connected to 203.0.113.10.
    sftp> ls -la "/etc/"
      drwxr-xr-x    ? root root      4096 Jul 13 15:14 /etc/.
      drwxr-xr-x   18 root root      4096 Feb  9 12:48 /etc/..
      -rw-r--r--    1 root root      3981 May  6  2025 /etc/adduser.conf
      drwxr-xr-x.   2 root root      4096 Mar 18 10:59 /etc/alternatives
      -rw-r--r--+   1 root root        44 Aug 14  2025 /etc/file with spaces.conf
    """

    let entries = SFTPService.parseListing(output, directory: "/etc/")

    #expect(entries.map(\.name) == [
        "alternatives",
        "adduser.conf",
        "file with spaces.conf"
    ])
    #expect(entries[0].ownerText == "root:root")
    #expect(entries[0].permissions == "drwxr-xr-x.")
    #expect(entries[1].modifiedText == "May 6 2025")
    #expect(entries[2].size == 44)
}

@Test("SFTP parser принимает ISO-дату и вариант без link count")
func parsesSFTPListingWithISODate() {
    let output = """
    -rw------- 1000 1000 1536 2025-08-14 09:27 numeric owner.txt
    drwxr-xr-x deploy www-data 4096 2026/07/28 16:05 releases
    """

    let entries = SFTPService.parseListing(output)

    #expect(entries.map(\.name) == ["releases", "numeric owner.txt"])
    #expect(entries[0].owner == "deploy")
    #expect(entries[0].group == "www-data")
    #expect(entries[0].modifiedText == "2026/07/28 16:05")
    #expect(entries[0].modificationDate != nil)
    #expect(entries[1].owner == "1000")
    #expect(entries[1].group == "1000")
    #expect(entries[1].modificationDate != nil)
}

@Test("Сортировка SFTP меняет поле и направление, но оставляет папки сверху")
func sortsSFTPEntriesWithDirectoriesFirst() {
    let output = """
    drwxr-xr-x    3 alice staff        96 Jul 27 12:00 Project Files
    -rw-r--r--    1 alice staff      2048 Jul 27 12:01 release notes.txt
    lrwxr-xr-x    1 alice staff        12 Jul 27 12:02 current -> Project Files
    """
    let entries = SFTPService.parseListing(output)
    let sorted = SFTPRemoteEntrySorter.sorted(
        entries,
        by: .size,
        direction: .descending
    )

    #expect(sorted.map(\.name) == ["Project Files", "release notes.txt", "current"])
}

@Test("SFTP формирует безопасные команды свойств, переименования и удаления")
func buildsSFTPFileManagementCommands() throws {
    #expect(
        try SFTPService.renameCommand(
            from: "/srv/old name.txt",
            to: "/srv/new name.txt"
        ) == #"rename "/srv/old name.txt" "/srv/new name.txt""#
    )
    #expect(
        try SFTPService.removeCommand(
            remotePath: "/srv/empty folder",
            isDirectory: true
        ) == #"rmdir "/srv/empty folder""#
    )
    #expect(
        try SFTPService.attributeCommands(
            remotePath: "/srv/report.txt",
            mode: "640",
            ownerID: 1_001,
            groupID: 42
        ) == [
            #"chmod 0640 "/srv/report.txt""#,
            #"chown 1001 "/srv/report.txt""#,
            #"chgrp 42 "/srv/report.txt""#
        ]
    )
}

@Test("SFTP отклоняет опасные имена и некорректные права")
func validatesSFTPFileManagementInput() {
    #expect(throws: SFTPServiceError.self) {
        try SFTPService.validatedName("../escape")
    }
    #expect(throws: SFTPServiceError.self) {
        try SFTPService.validatedName("report\nrm important")
    }
    #expect(throws: SFTPServiceError.self) {
        try SFTPPermissionFormatter.normalizedMode("0899")
    }
    #expect(
        SFTPPermissionFormatter.symbolic(
            mode: 0o4755,
            isDirectory: false,
            isSymbolicLink: false
        ) == "-rwsr-xr-x"
    )
    #expect(
        SFTPPermissionFormatter.octal(fromSymbolic: "-rwSr--r--") == "4644"
    )
}

@Test("Хлебные крошки SFTP сохраняют абсолютные и домашние пути")
func buildsSFTPBreadcrumbs() {
    #expect(
        SFTPService.breadcrumbs(for: "/var/log").map(\.path)
            == ["/", "/var", "/var/log"]
    )
    #expect(
        SFTPService.breadcrumbs(for: "projects/release").map(\.path)
            == [".", "projects", "projects/release"]
    )
}

@Test("Фильтр SFTP нечувствителен к регистру и игнорирует пробелы по краям")
func filtersSFTPEntriesByName() {
    #expect(SFTPNameFilter.matches("Release Notes.txt", query: " notes "))
    #expect(SFTPNameFilter.matches("Документы", query: "ДОК"))
    #expect(!SFTPNameFilter.matches("authorized_keys", query: "config"))
    #expect(SFTPNameFilter.matches("anything", query: "   "))
}

@Test("Импорт .rdp всегда создаёт RDP-профиль")
func importedRDPKeepsProtocol() throws {
    let data = Data("full address:s:pc.example.local\r\n".utf8)
    let profile = try RDPFileCodec.decode(data)

    #expect(profile.connectionType == .rdp)
}

@Test("Новый архив профилей использует схему 2")
func exportsProfileArchiveSchemaTwo() throws {
    var profile = ConnectionProfile(connectionType: .ssh)
    profile.sshIdentityID = UUID()
    let data = try SelectiveRemoteProfileCodec.encode([profile])
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let decoded = try SelectiveRemoteProfileCodec.decode(data)

    #expect(object?["schemaVersion"] as? Int == 2)
    #expect(decoded.first?.sshIdentityID == nil)
}

@Test("Touch ID Key принимает только обычный ECDSA-ключ")
func touchIDKeyCompatibilityIsECDSAOnly() {
    let ecdsa = SSHKeyRecord(
        name: "touchid",
        privateKeyPath: "/tmp/id_ecdsa",
        publicKeyPath: "/tmp/id_ecdsa.pub",
        fingerprint: "SHA256:test",
        algorithm: "ECDSA"
    )
    let ed25519 = SSHKeyRecord(
        name: "regular",
        privateKeyPath: "/tmp/id_ed25519",
        publicKeyPath: "/tmp/id_ed25519.pub",
        fingerprint: "SHA256:test2",
        algorithm: "ED25519"
    )
    let securityKey = SSHKeyRecord(
        name: "fido",
        privateKeyPath: "/tmp/id_ecdsa_sk",
        publicKeyPath: "/tmp/id_ecdsa_sk.pub",
        fingerprint: "SHA256:test3",
        algorithm: "ECDSA-SK"
    )

    #expect(SSHKeyService.isTouchIDCompatible(ecdsa))
    #expect(!SSHKeyService.isTouchIDCompatible(ed25519))
    #expect(!SSHKeyService.isTouchIDCompatible(securityKey))
}

@Test("OpenSSH certificate ищется рядом с приватным ключом")
func findsOpenSSHCertificateNextToPrivateKey() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let privateURL = directory.appendingPathComponent("id_ed25519")
    let certificateURL = URL(fileURLWithPath: privateURL.path + "-cert.pub")
    FileManager.default.createFile(atPath: certificateURL.path, contents: Data())

    let key = SSHKeyRecord(
        name: "cert-test",
        privateKeyPath: privateURL.path,
        publicKeyPath: privateURL.path + ".pub",
        fingerprint: "SHA256:test",
        algorithm: "ED25519"
    )

    #expect(SSHKeyService.certificateURL(for: key)?.path == certificateURL.path)
}

@Test("OpenSSH certificate подключается через CertificateFile")
func addsCertificateFileToSSHArguments() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let privateURL = directory.appendingPathComponent("id_ed25519")
    FileManager.default.createFile(atPath: privateURL.path, contents: Data("-----BEGIN OPENSSH PRIVATE KEY-----\n".utf8))
    let certificateURL = URL(fileURLWithPath: privateURL.path + "-cert.pub")
    FileManager.default.createFile(atPath: certificateURL.path, contents: Data())

    let key = SSHKeyRecord(
        name: "cert-test",
        privateKeyPath: privateURL.path,
        publicKeyPath: privateURL.path + ".pub",
        fingerprint: "SHA256:test",
        algorithm: "ED25519"
    )
    var profile = ConnectionProfile(connectionType: .ssh)
    profile.host = "server.example.com"
    profile.sshAuthenticationMode = .key
    let settings = try SSHConnectionSettings(profile: profile, identity: key)
    let arguments = SSHService.commonSSHArguments(settings: settings, batchMode: false)

    #expect(arguments.contains("CertificateFile=\(certificateURL.path)"))
}

@Test("Touch ID режим отклоняет Ed25519 identity на уровне SSH settings")
func touchIDModeRejectsEd25519Identity() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let privateURL = directory.appendingPathComponent("id_ed25519")
    FileManager.default.createFile(atPath: privateURL.path, contents: Data("-----BEGIN OPENSSH PRIVATE KEY-----\n".utf8))

    let key = SSHKeyRecord(
        name: "wrong-touchid-key",
        privateKeyPath: privateURL.path,
        publicKeyPath: nil,
        fingerprint: "SHA256:test",
        algorithm: "ED25519"
    )
    var profile = ConnectionProfile(connectionType: .ssh)
    profile.host = "server.example.com"
    profile.sshAuthenticationMode = .touchIDKey

    do {
        _ = try SSHConnectionSettings(profile: profile, identity: key)
        Issue.record("Touch ID mode accepted a non-ECDSA key")
    } catch let error as SSHServiceError {
        if case .incompatibleTouchIDKey = error {
            // Expected.
        } else {
            Issue.record("Unexpected SSH error: \(error.localizedDescription)")
        }
    }
}
