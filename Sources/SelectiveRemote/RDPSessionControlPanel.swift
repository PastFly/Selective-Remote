import AppKit
import SwiftUI

@MainActor
final class RDPSessionControlPanelController: NSObject, NSWindowDelegate {
    static let shared = RDPSessionControlPanelController()
    private var panel: NSPanel?

    func show(model: AppModel) {
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 640),
                styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.title = "Управление RDP"
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            self.panel = panel
        }
        panel?.contentView = NSHostingView(
            rootView: RDPSessionControlPanelView(model: model)
        )
        panel?.center()
        panel?.orderFrontRegardless()
    }
}

private struct RDPSessionControlPanelView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Активные RDP-сессии", systemImage: "display.2")
                    .font(.headline)
                Spacer()
                Text("\(model.runningSessionCount)")
                    .foregroundStyle(.secondary)
            }

            if model.runningSessions.isEmpty {
                ContentUnavailableView(
                    "Нет активных сессий",
                    systemImage: "display.slash",
                    description: Text("Панель останется доступна во всех Spaces.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.runningSessions) { session in
                            sessionCard(session)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(minWidth: 390, minHeight: 500)
    }

    private func sessionCard(_ session: RDPSessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.profileName).fontWeight(.semibold)
                    Text("\(session.host) · \(session.phase.rawValue)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Переподключить", systemImage: "arrow.clockwise") {
                    model.reconnect(profileID: session.id)
                }
                .labelStyle(.iconOnly)
                .help("Переподключить RDP и применить изменённые параметры")
                Button("Отключить", systemImage: "xmark.circle.fill", role: .destructive) {
                    model.disconnect(profileID: session.id)
                }
                .labelStyle(.iconOnly)
                .help("Отключить эту RDP-сессию")
            }

            Text("Команды Windows")
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: 7
            ) {
                commandButton(.windows, session: session)
                commandButton(.language, session: session)
                commandButton(.altTab, session: session)
                commandButton(.controlAltDelete, session: session)
                commandButton(.printScreen, session: session)
                commandButton(.fullScreen, session: session)
            }

            Divider()
            HStack(spacing: 16) {
                Toggle("Звук", isOn: soundBinding(session.id))
                    .help("Воспроизводить звук удалённого компьютера на Mac")
                Toggle("Микрофон", isOn: microphoneBinding(session.id))
                    .help("Передавать микрофон Mac в Windows после переподключения")
                Toggle("Камера", isOn: cameraBinding(session.id))
                    .help("Передавать выбранную камеру в Windows после переподключения")
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            Text("Каналы применяются после переподключения; кнопка ↻ делает это автоматически.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(11)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }

    private func commandButton(
        _ command: RDPSessionCommand,
        session: RDPSessionSummary
    ) -> some View {
        Button(command.title, systemImage: command.systemImage) {
            model.sendRDPCommand(command, profileID: session.id)
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(command.helpText)
        .disabled(session.phase != .connected)
    }

    private func profile(_ id: UUID) -> ConnectionProfile? {
        model.profiles.first(where: { $0.id == id })
    }

    private func soundBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { profile(id)?.audioMode != .muted },
            set: { model.setSoundEnabled($0, profileID: id) }
        )
    }

    private func microphoneBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { profile(id)?.redirectMicrophone == true },
            set: { model.setMicrophoneEnabled($0, profileID: id) }
        )
    }

    private func cameraBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { profile(id)?.redirectCamera == true },
            set: { model.setCameraEnabled($0, profileID: id) }
        )
    }
}
