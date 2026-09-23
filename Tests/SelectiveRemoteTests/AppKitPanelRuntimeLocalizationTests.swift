import AppKit
import Testing
@testable import SelectiveRemote

@Suite("AppKit panel runtime localization")
struct AppKitPanelRuntimeLocalizationTests {
    @MainActor
    @Test("SFTP selection panels use the chosen app language")
    func sftpSelectionPanels() {
        let folderPanel = NSOpenPanel()
        SFTPWorkspacePanelLocalization.configureLocalFolder(folderPanel, english: true)
        #expect(folderPanel.title == "Choose a Local Folder")
        SFTPWorkspacePanelLocalization.configureLocalFolder(folderPanel, english: false)
        #expect(folderPanel.title == "Выберите локальную папку")

        let applicationPanel = NSOpenPanel()
        SFTPWorkspacePanelLocalization.configureApplication(applicationPanel, english: true)
        #expect(applicationPanel.title == "Choose an Application")
    }

    @MainActor
    @Test("SSH CA import panel title and action follow the chosen app language")
    func sshCAImportPanel() {
        let panel = NSOpenPanel()
        SSHCertificateAuthorityService.configureImportPanel(panel, english: true)
        #expect(panel.title == "Import SSH CA Public Key")
        #expect(panel.prompt == "Import")
        SSHCertificateAuthorityService.configureImportPanel(panel, english: false)
        #expect(panel.title == "Импортировать SSH CA public key")
        #expect(panel.prompt == "Импортировать")
    }

    @MainActor
    @Test("RDP utility panel title follows the chosen app language")
    func rdpControlPanel() {
        let panel = NSPanel()
        RDPSessionControlPanelController.configureTitle(panel, english: true)
        #expect(panel.title == "RDP Controls")
        RDPSessionControlPanelController.configureTitle(panel, english: false)
        #expect(panel.title == "Управление RDP")
    }
}
