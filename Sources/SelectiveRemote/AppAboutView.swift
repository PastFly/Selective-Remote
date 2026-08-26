import AppKit
import SwiftUI

struct AppAboutView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 92, height: 92)

            VStack(spacing: 5) {
                Text(AppBrand.name)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("\(AppBuildInfo.fullText) · \(UpdateLocalization.text(ru: "сборка", en: "build")) \(AppBuildInfo.build)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("RDP · SSH · Mosh · Telnet · Serial · SFTP")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(UpdateLocalization.text(
                ru: "Локальный менеджер удалённых подключений для macOS. Профили работают без учётной записи, а пароли и связанные секреты защищены macOS Keychain.",
                en: "A local-first remote connection manager for macOS. Profiles work without an account, while passwords and related secrets are protected by macOS Keychain."
            ))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    Text(UpdateLocalization.text(ru: "Редакция", en: "Edition"))
                        .foregroundStyle(.secondary)
                    Text("Community")
                }
                GridRow {
                    Text(UpdateLocalization.text(ru: "Лицензия", en: "License"))
                        .foregroundStyle(.secondary)
                    Text("MIT")
                }
                GridRow {
                    Text(UpdateLocalization.text(ru: "Хранилище данных", en: "Data storage"))
                        .foregroundStyle(.secondary)
                    Text(UpdateLocalization.text(ru: "Локально на этом Mac", en: "Locally on this Mac"))
                }
                GridRow {
                    Text("macOS")
                        .foregroundStyle(.secondary)
                    Text(ProcessInfo.processInfo.operatingSystemVersionString)
                }
            }

            HStack(spacing: 10) {
                Button(UpdateLocalization.text(ru: "Проект на GitHub", en: "Project on GitHub"), systemImage: "chevron.left.forwardslash.chevron.right") {
                    openURL(ProjectSupport.githubURL)
                }
                Button(UpdateLocalization.text(ru: "Сайт проекта", en: "Project Website"), systemImage: "globe") {
                    openURL(ProjectSupport.websiteURL)
                }
            }
            .buttonStyle(.bordered)

            Text("© 2026 PastFly · Selective Remote")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(30)
        .frame(minWidth: 520, maxWidth: 520, minHeight: 500)
    }
}
