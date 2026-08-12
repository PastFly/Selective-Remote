import SwiftUI

struct AppHelpView: View {
    private struct HelpSection: Identifiable {
        let id = UUID()
        let title: String
        let systemImage: String
        let text: String
    }

    private let sections: [HelpSection] = [
        .init(
            title: "Подключения",
            systemImage: "rectangle.connected.to.line.below",
            text: "Создавайте RDP и SSH-профили в левом меню. Для SSH доступны Terminal, SFTP, Forwarding, SSH-ключи, Touch ID и диагностика. Правый клик по профилю открывает быстрые действия."
        ),
        .init(
            title: "Terminal Workspace",
            systemImage: "terminal",
            text: "Терминал поддерживает независимые вкладки и несколько панелей. ⌘K открывает палитру действий. Групповой ввод включайте только когда нужно отправлять одну команду в несколько активных панелей."
        ),
        .init(
            title: "SFTP",
            systemImage: "folder.badge.gearshape",
            text: "Двухпанельный SFTP поддерживает Drag & Drop, множественный выбор, очередь передач, паузу и продолжение, редактирование файлов и историю навигации."
        ),
        .init(
            title: "Keychain",
            systemImage: "key.viewfinder",
            text: "Приватные SSH-ключи остаются файлами в ~/.ssh. Keychain используется для паролей и passphrase. В разделе Keychain можно управлять SSH ID, Touch ID Key, OpenSSH certificates и Known Hosts."
        ),
        .init(
            title: "Forwarding",
            systemImage: "arrow.left.arrow.right",
            text: "Поддерживаются Local, Remote и Dynamic/SOCKS туннели. Двойной клик запускает туннель, а контекстное меню позволяет остановить, перезапустить, скопировать или удалить его."
        ),
        .init(
            title: "Безопасность",
            systemImage: "lock.shield",
            text: "Изменение SSH host key не принимается автоматически. Пароли не экспортируются вместе с профилями. Для Touch ID Key используются отдельные ECDSA-ключи."
        )
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.accentColor.opacity(0.14))
                        Image(systemName: "network")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .frame(width: 64, height: 64)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Selective Remote")
                            .font(.largeTitle.bold())
                        Text(AppBuildInfo.fullText)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text("RDP · SSH · Terminal · SFTP · Forwarding")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                Text("Краткая справка")
                    .font(.title2.bold())

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 280), spacing: 14)],
                    spacing: 14
                ) {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 10) {
                            Label(section.title, systemImage: section.systemImage)
                                .font(.headline)
                            Text(section.text)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
                        .padding(18)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.07))
                        }
                    }
                }

                GroupBox("Полезные сочетания клавиш") {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 9) {
                        GridRow { Text("⌘K").monospaced(); Text("Quick Connect") }
                        GridRow { Text("⇧⌘K").monospaced(); Text("Палитра действий терминала") }
                        GridRow { Text("Esc").monospaced(); Text("Закрыть диагностику и вспомогательные окна") }
                        GridRow { Text("⌘W").monospaced(); Text("Закрыть активное окно") }
                        GridRow { Text("⇧⌘Y").monospaced(); Text("История и подсказки команд терминала") }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                }
            }
            .padding(28)
        }
        .frame(minWidth: 760, minHeight: 620)
    }
}
