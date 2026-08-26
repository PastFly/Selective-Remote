import Foundation
import SwiftUI

enum ProjectSupport {
    static let githubURL = URL(string: "https://github.com/PastFly/Selective-Remote")!
    static let websiteURL = URL(string: "https://pastfly.github.io/Selective-Remote/")!
    static let yoomoneyURL = URL(
        string: "https://yoomoney.ru/to/4100119600001192"
    )!
    static let boostyURL = URL(
        string: "https://boosty.to/pastfly/single-payment/donation/821124/target?share=target_link"
    )!
    static let sberbankURL = URL(
        string: "https://messenger.sbrf.ru/sl/0pRZ8zDZzpoim1on3"
    )!
}

struct AppHelpView: View {
    @Environment(\.openURL) private var openURL

    private struct HelpSection: Identifiable {
        let id = UUID()
        let title: String
        let systemImage: String
        let text: String
    }

    private var sections: [HelpSection] { [
        .init(
            title: UpdateLocalization.text(ru: "Подключения", en: "Connections"),
            systemImage: "rectangle.connected.to.line.below",
            text: UpdateLocalization.text(
                ru: "Создавайте RDP и SSH-профили в левом меню. Для SSH доступны Terminal, SFTP, Forwarding, SSH-ключи, Touch ID и диагностика. Правый клик по профилю открывает быстрые действия.",
                en: "Create RDP and SSH profiles from the sidebar. SSH profiles provide Terminal, SFTP, Forwarding, SSH keys, Touch ID, and diagnostics. Right-click a profile for quick actions."
            )
        ),
        .init(
            title: "Terminal Workspace",
            systemImage: "terminal",
            text: UpdateLocalization.text(
                ru: "Терминал поддерживает независимые вкладки и несколько панелей. ⌘K открывает палитру действий. Групповой ввод включайте только когда нужно отправлять одну команду в несколько активных панелей.",
                en: "The terminal supports independent tabs and multiple panes. ⌘K opens the command palette. Enable broadcast input only when the same command must be sent to several active panes."
            )
        ),
        .init(
            title: "SFTP",
            systemImage: "folder.badge.gearshape",
            text: UpdateLocalization.text(
                ru: "Двухпанельный SFTP поддерживает Drag & Drop, множественный выбор, очередь передач, паузу и продолжение, редактирование файлов и историю навигации.",
                en: "The dual-pane SFTP workspace supports drag and drop, multiple selection, transfer queues, pause and resume, file editing, and navigation history."
            )
        ),
        .init(
            title: "Keychain",
            systemImage: "key.viewfinder",
            text: UpdateLocalization.text(
                ru: "Приватные SSH-ключи остаются файлами в ~/.ssh. Keychain используется для паролей и passphrase. В разделе Keychain можно управлять SSH ID, Touch ID Key, OpenSSH certificates и Known Hosts.",
                en: "Private SSH keys remain files in ~/.ssh. Keychain stores passwords and passphrases. The Keychain section manages SSH IDs, Touch ID keys, OpenSSH certificates, and known hosts."
            )
        ),
        .init(
            title: "Forwarding",
            systemImage: "arrow.left.arrow.right",
            text: UpdateLocalization.text(
                ru: "Поддерживаются Local, Remote и Dynamic/SOCKS туннели. Двойной клик запускает туннель, а контекстное меню позволяет остановить, перезапустить, скопировать или удалить его.",
                en: "Local, Remote, and Dynamic/SOCKS tunnels are supported. Double-click to start a tunnel; use the context menu to stop, restart, copy, or delete it."
            )
        ),
        .init(
            title: UpdateLocalization.text(ru: "Безопасность", en: "Security"),
            systemImage: "lock.shield",
            text: UpdateLocalization.text(
                ru: "Изменение SSH host key не принимается автоматически. Пароли не экспортируются вместе с профилями. Для Touch ID Key используются отдельные ECDSA-ключи.",
                en: "SSH host key changes are never accepted automatically. Passwords are not included in profile exports. Touch ID keys use separate ECDSA identities."
            )
        )
    ] }

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

                Text(UpdateLocalization.text(ru: "Краткая справка", en: "Quick Help"))
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

                HStack(alignment: .center, spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.accentColor.opacity(0.12))
                        Image(systemName: "heart.circle.fill")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .frame(width: 48, height: 48)

                    VStack(alignment: .leading, spacing: 5) {
                        Text("Поддержать проект")
                            .font(.headline)
                        Text("Selective Remote остаётся бесплатным и открытым. Если приложение оказалось полезным, вы можете поддержать дальнейшую разработку.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Выбранный способ поддержки откроется в браузере")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    Spacer(minLength: 12)

                    Menu {
                        Button("ЮMoney", systemImage: "creditcard") {
                            openURL(ProjectSupport.yoomoneyURL)
                        }
                        .accessibilityIdentifier("supportProjectYoomoneyButton")
                        Button("Boosty", systemImage: "heart") {
                            openURL(ProjectSupport.boostyURL)
                        }
                        .accessibilityIdentifier("supportProjectBoostyButton")
                        Button("СберБанк", systemImage: "building.columns") {
                            openURL(ProjectSupport.sberbankURL)
                        }
                        .accessibilityIdentifier("supportProjectSberbankButton")
                    } label: {
                        Label("Поддержать проект", systemImage: "heart.fill")
                            .frame(minWidth: 160)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .fixedSize()
                    .help("Выбрать способ поддержки")
                    .accessibilityIdentifier("supportProjectMenu")
                }
                .padding(18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.07))
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
