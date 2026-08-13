import Foundation
import SwiftUI

struct TerminalRemoteService: Codable, Equatable, Identifiable, Sendable {
    let name: String
    let activeState: String
    let subState: String

    var id: String { name }

    var statusLabel: String {
        let state = activeState.trimmingCharacters(in: .whitespacesAndNewlines)
        let sub = subState.trimmingCharacters(in: .whitespacesAndNewlines)
        if state.isEmpty { return sub.isEmpty ? "unknown" : sub }
        return sub.isEmpty || sub == state ? state : "\(state) · \(sub)"
    }

    var isActive: Bool { activeState == "active" }
}

struct TerminalRemoteContainer: Codable, Equatable, Identifiable, Sendable {
    let tool: String
    let name: String
    let status: String

    var id: String { "\(tool):\(name)" }
}

enum ServerCommandCategory: String, CaseIterable, Identifiable, Sendable {
    case system
    case services
    case containers
    case network
    case disks
    case logs
    case security

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Система"
        case .services: "Службы"
        case .containers: "Контейнеры"
        case .network: "Сеть"
        case .disks: "Диски"
        case .logs: "Журналы"
        case .security: "Безопасность"
        }
    }

    var systemImage: String {
        switch self {
        case .system: "cpu"
        case .services: "gearshape.2"
        case .containers: "shippingbox"
        case .network: "network"
        case .disks: "externaldrive"
        case .logs: "doc.text.magnifyingglass"
        case .security: "lock.shield"
        }
    }
}

enum ServerCommandActionStyle: Equatable, Sendable {
    case readOnly
    case mutating
}

struct ServerCommandAction: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String
    let command: String
    let systemImage: String
    let style: ServerCommandActionStyle

    init(
        _ title: String,
        detail: String,
        command: String,
        systemImage: String,
        style: ServerCommandActionStyle = .readOnly
    ) {
        self.id = command
        self.title = title
        self.detail = detail
        self.command = command
        self.systemImage = systemImage
        self.style = style
    }
}

enum ServerCommandCatalog {
    static func actions(
        for category: ServerCommandCategory,
        context: TerminalRemoteContextSnapshot
    ) -> [ServerCommandAction] {
        switch category {
        case .system:
            systemActions(context)
        case .services, .containers:
            []
        case .network:
            networkActions(context)
        case .disks:
            diskActions(context)
        case .logs:
            logActions(context)
        case .security:
            securityActions(context)
        }
    }

    static func serviceActions(
        _ service: TerminalRemoteService,
        context: TerminalRemoteContextSnapshot
    ) -> [ServerCommandAction] {
        guard isSafeRemoteIdentifier(service.name), context.hasCommand("systemctl") else {
            return []
        }
        var result = [
            ServerCommandAction(
                "Статус",
                detail: "Показать состояние и последние строки журнала",
                command: "systemctl status \(service.name) --no-pager",
                systemImage: "info.circle"
            ),
            ServerCommandAction(
                "Restart",
                detail: "Перезапустить службу через systemd",
                command: "sudo systemctl restart \(service.name)",
                systemImage: "arrow.clockwise",
                style: .mutating
            ),
            ServerCommandAction(
                "Reload",
                detail: "Перечитать конфигурацию без полного restart",
                command: "sudo systemctl reload \(service.name)",
                systemImage: "arrow.triangle.2.circlepath",
                style: .mutating
            )
        ]
        if context.hasCommand("journalctl") {
            result.append(
                ServerCommandAction(
                    "Журнал",
                    detail: "Последние 100 записей systemd journal",
                    command: "journalctl -u \(service.name) -n 100 --no-pager",
                    systemImage: "doc.text"
                )
            )
        }
        return result
    }

    static func containerActions(
        _ container: TerminalRemoteContainer
    ) -> [ServerCommandAction] {
        guard isSafeRemoteIdentifier(container.name), ["docker", "podman"].contains(container.tool) else {
            return []
        }
        let tool = container.tool
        return [
            ServerCommandAction(
                "Статус",
                detail: "Показать runtime state контейнера",
                command: "\(tool) inspect --format '{{.State.Status}}' \(container.name)",
                systemImage: "info.circle"
            ),
            ServerCommandAction(
                "Restart",
                detail: "Перезапустить контейнер",
                command: "\(tool) restart \(container.name)",
                systemImage: "arrow.clockwise",
                style: .mutating
            ),
            ServerCommandAction(
                "Журнал",
                detail: "Последние 100 строк и дальнейший вывод",
                command: "\(tool) logs --tail 100 -f \(container.name)",
                systemImage: "doc.text"
            ),
            ServerCommandAction(
                "Shell",
                detail: "Открыть интерактивный shell контейнера",
                command: "\(tool) exec -it \(container.name) sh",
                systemImage: "terminal"
            )
        ]
    }

    static func count(
        for category: ServerCommandCategory,
        context: TerminalRemoteContextSnapshot
    ) -> Int {
        switch category {
        case .services: context.services.count
        case .containers: context.containers.count
        default: actions(for: category, context: context).count
        }
    }

    private static func systemActions(_ context: TerminalRemoteContextSnapshot) -> [ServerCommandAction] {
        var result: [ServerCommandAction] = []
        addIf(context, "uptime", to: &result,
              action: .init("Uptime", detail: "Время работы и load average", command: "uptime", systemImage: "clock"))
        addIf(context, "uname", to: &result,
              action: .init("Kernel", detail: "Версия ядра и архитектура", command: "uname -a", systemImage: "cpu"))
        addIf(context, "hostnamectl", to: &result,
              action: .init("Host", detail: "Hostname, OS и kernel", command: "hostnamectl", systemImage: "server.rack"))
        addIf(context, "free", to: &result,
              action: .init("Memory", detail: "Использование оперативной памяти", command: "free -h", systemImage: "memorychip"))
        addIf(context, "vmstat", to: &result,
              action: .init("VM stats", detail: "Короткий снимок CPU, memory и IO", command: "vmstat 1 5", systemImage: "waveform.path.ecg"))

        if context.hasCommand("apt") || context.hasCommand("apt-get") {
            result.append(.init("Обновления APT", detail: "Показать доступные обновления Debian/Ubuntu", command: "apt list --upgradable 2>/dev/null", systemImage: "shippingbox"))
        } else if context.hasCommand("dnf") {
            result.append(.init("Обновления DNF", detail: "Проверить доступные обновления RHEL/Fedora", command: "dnf check-update", systemImage: "shippingbox"))
        } else if context.hasCommand("yum") {
            result.append(.init("Обновления YUM", detail: "Проверить доступные обновления", command: "yum check-update", systemImage: "shippingbox"))
        } else if context.hasCommand("pacman") {
            result.append(.init("Обновления Pacman", detail: "Показать доступные обновления Arch Linux", command: "pacman -Qu", systemImage: "shippingbox"))
        } else if context.hasCommand("zypper") {
            result.append(.init("Обновления Zypper", detail: "Показать доступные обновления openSUSE", command: "zypper list-updates", systemImage: "shippingbox"))
        }
        return result
    }

    private static func networkActions(_ context: TerminalRemoteContextSnapshot) -> [ServerCommandAction] {
        var result: [ServerCommandAction] = []
        addIf(context, "ip", to: &result,
              action: .init("Интерфейсы", detail: "Краткий список адресов интерфейсов", command: "ip -brief address", systemImage: "network"))
        addIf(context, "ip", to: &result,
              action: .init("Маршруты", detail: "Текущая таблица маршрутизации", command: "ip route", systemImage: "arrow.triangle.branch"))
        addIf(context, "ss", to: &result,
              action: .init("Сокеты", detail: "Слушающие TCP/UDP порты и процессы", command: "ss -lntup", systemImage: "point.3.connected.trianglepath.dotted"))
        addIf(context, "resolvectl", to: &result,
              action: .init("DNS", detail: "Состояние systemd-resolved", command: "resolvectl status", systemImage: "globe"))
        addIf(context, "ping", to: &result,
              action: .init("Проверить сеть", detail: "4 ICMP-запроса к 1.1.1.1", command: "ping -c 4 1.1.1.1", systemImage: "dot.radiowaves.left.and.right"))
        return result
    }

    private static func diskActions(_ context: TerminalRemoteContextSnapshot) -> [ServerCommandAction] {
        var result: [ServerCommandAction] = []
        addIf(context, "df", to: &result,
              action: .init("Файловые системы", detail: "Размер, тип и свободное место", command: "df -hT", systemImage: "externaldrive"))
        addIf(context, "lsblk", to: &result,
              action: .init("Блочные устройства", detail: "Диски, файловые системы и точки монтирования", command: "lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS", systemImage: "externaldrive.badge.checkmark"))
        addIf(context, "findmnt", to: &result,
              action: .init("Mounts", detail: "Дерево смонтированных файловых систем", command: "findmnt", systemImage: "point.bottomleft.forward.to.point.topright.scurvepath"))
        if context.hasCommand("du"), context.hasCommand("sort"), context.hasCommand("tail") {
            result.append(.init("Крупные каталоги /", detail: "20 крупнейших каталогов первого уровня", command: "du -xhd1 / 2>/dev/null | sort -h | tail -20", systemImage: "chart.bar"))
        }
        return result
    }

    private static func logActions(_ context: TerminalRemoteContextSnapshot) -> [ServerCommandAction] {
        var result: [ServerCommandAction] = []
        addIf(context, "journalctl", to: &result,
              action: .init("Предупреждения", detail: "Последние warning/error из systemd journal", command: "journalctl -p warning -n 100 --no-pager", systemImage: "exclamationmark.triangle"))
        if context.hasCommand("journalctl"), context.hasCommand("tail") {
            result.append(.init("Журнал за сегодня", detail: "Последние 200 событий текущего дня", command: "journalctl --since today --no-pager | tail -200", systemImage: "calendar"))
        }
        if context.hasCommand("dmesg"), context.hasCommand("tail") {
            result.append(.init("Kernel log", detail: "Последние 100 сообщений ядра", command: "dmesg | tail -100", systemImage: "cpu"))
        }
        return result
    }

    private static func securityActions(_ context: TerminalRemoteContextSnapshot) -> [ServerCommandAction] {
        var result: [ServerCommandAction] = []
        addIf(context, "who", to: &result,
              action: .init("Сеансы", detail: "Сейчас вошедшие пользователи", command: "who", systemImage: "person.2"))
        addIf(context, "last", to: &result,
              action: .init("Последние входы", detail: "Последние 20 login-сессий", command: "last -n 20", systemImage: "clock.arrow.circlepath"))
        addIf(context, "ufw", to: &result,
              action: .init("UFW", detail: "Текущее состояние firewall", command: "sudo ufw status verbose", systemImage: "shield"))
        addIf(context, "firewall-cmd", to: &result,
              action: .init("firewalld", detail: "Состояние и активные правила", command: "firewall-cmd --state && firewall-cmd --list-all", systemImage: "shield"))
        addIf(context, "getenforce", to: &result,
              action: .init("SELinux", detail: "Текущий enforcing mode", command: "getenforce", systemImage: "lock.shield"))
        addIf(context, "sestatus", to: &result,
              action: .init("SELinux details", detail: "Расширенное состояние SELinux", command: "sestatus", systemImage: "lock.shield"))
        addIf(context, "fail2ban-client", to: &result,
              action: .init("Fail2ban", detail: "Состояние jails", command: "sudo fail2ban-client status", systemImage: "hand.raised"))
        return result
    }

    private static func addIf(
        _ context: TerminalRemoteContextSnapshot,
        _ command: String,
        to result: inout [ServerCommandAction],
        action: ServerCommandAction
    ) {
        if context.hasCommand(command) { result.append(action) }
    }

    static func isSafeRemoteIdentifier(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= 160
            && value.unicodeScalars.allSatisfy { scalar in
                CharacterSet.alphanumerics.contains(scalar)
                    || "@_.:-".unicodeScalars.contains(scalar)
            }
    }
}

struct ServerCommandsView: View {
    let context: TerminalRemoteContextSnapshot
    let isRefreshing: Bool
    let onRefresh: () -> Void
    let onRun: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var category: ServerCommandCategory = .system
    @State private var searchText = ""

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .frame(minWidth: 920, idealWidth: 1040, minHeight: 600, idealHeight: 680)
        .background(.regularMaterial)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Команды сервера")
                    .font(.title2.weight(.semibold))
                Text(context.systemLabel.isEmpty ? context.hostLabel : context.systemLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)

            List {
                ForEach(ServerCommandCategory.allCases) { item in
                    Button {
                        category = item
                        searchText = ""
                    } label: {
                        HStack(spacing: 9) {
                            Label(LocalizedStringKey(item.title), systemImage: item.systemImage)
                            Spacer()
                            Text("\(ServerCommandCatalog.count(for: item, context: context))")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 5)
                    .padding(.horizontal, 6)
                    .background(
                        category == item ? Color.accentColor.opacity(0.14) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                }
            }
            .listStyle(.sidebar)

            Button("Обновить сведения", systemImage: "arrow.clockwise") { onRefresh() }
                .disabled(isRefreshing)
                .padding(14)
        }
        .frame(width: 230)
    }

    private var detail: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: category.systemImage)
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(category.title))
                        .font(.title2.weight(.semibold))
                    Text(contextSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isRefreshing {
                    ProgressView().controlSize(.small)
                }
                Button("Закрыть") { dismiss() }
            }
            .padding(16)

            Divider()

            Group {
                if category == .services {
                    servicesView
                } else if category == .containers {
                    containersView
                } else {
                    actionsView
                }
            }
            .searchable(text: $searchText, prompt: "Поиск команд")
        }
    }

    private var contextSummary: String {
        var parts: [String] = []
        if !context.hostLabel.isEmpty { parts.append(context.hostLabel) }
        if let refreshedAt = context.refreshedAt {
            parts.append("обновлено \(refreshedAt.formatted(date: .omitted, time: .shortened))")
        }
        return parts.joined(separator: " · ")
    }

    private var filteredServices: [TerminalRemoteService] {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return context.services
        }
        return context.services.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.statusLabel.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var filteredContainers: [TerminalRemoteContainer] {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return context.containers
        }
        return context.containers.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.tool.localizedCaseInsensitiveContains(searchText)
                || $0.status.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var filteredActions: [ServerCommandAction] {
        let actions = ServerCommandCatalog.actions(for: category, context: context)
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return actions
        }
        return actions.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
                || $0.detail.localizedCaseInsensitiveContains(searchText)
                || $0.command.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var servicesView: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if filteredServices.isEmpty {
                    emptyState(
                        icon: "gearshape.2",
                        title: "Службы не обнаружены",
                        detail: context.hasCommand("systemctl")
                            ? "systemd доступен, но probe не вернул службы. Обновите сведения о сервере."
                            : "systemctl на этом сервере не обнаружен."
                    )
                }
                ForEach(filteredServices) { service in
                    serviceRow(service)
                }
            }
            .padding(14)
        }
    }

    private func serviceRow(_ service: TerminalRemoteService) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Circle()
                    .fill(serviceColor(service))
                    .frame(width: 9, height: 9)
                Text(service.name)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled)
                Spacer()
                Text(service.statusLabel)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }

            HStack(spacing: 8) {
                ForEach(ServerCommandCatalog.serviceActions(service, context: context)) { action in
                    actionButton(action)
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07))
        }
    }

    private var containersView: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if filteredContainers.isEmpty {
                    emptyState(
                        icon: "shippingbox",
                        title: "Контейнеры не обнаружены",
                        detail: context.hasCommand("docker") || context.hasCommand("podman")
                            ? "Docker/Podman обнаружен, но запущенных или остановленных контейнеров probe не вернул."
                            : "Docker и Podman на этом сервере не обнаружены."
                    )
                }
                ForEach(filteredContainers) { container in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 9) {
                            Image(systemName: "shippingbox.fill")
                                .foregroundStyle(.orange)
                            Text(container.name)
                                .font(.system(.body, design: .monospaced).weight(.semibold))
                                .textSelection(.enabled)
                            Text(container.tool)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.primary.opacity(0.06), in: Capsule())
                            Spacer()
                            Text(container.status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        HStack(spacing: 8) {
                            ForEach(ServerCommandCatalog.containerActions(container)) { action in
                                actionButton(action)
                            }
                        }
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.07))
                    }
                }
            }
            .padding(14)
        }
    }

    private var actionsView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 10)], spacing: 10) {
                if filteredActions.isEmpty {
                    emptyState(
                        icon: category.systemImage,
                        title: "Команды не обнаружены",
                        detail: "Для этой категории на текущем сервере не найдено подходящих утилит."
                    )
                    .gridCellColumns(2)
                }
                ForEach(filteredActions) { action in
                    Button { run(action) } label: {
                        HStack(alignment: .top, spacing: 11) {
                            Image(systemName: action.systemImage)
                                .font(.title3)
                                .foregroundStyle(action.style == .mutating ? Color.orange : Color.accentColor)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(LocalizedStringKey(action.title))
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text(LocalizedStringKey(action.detail))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.leading)
                                Text(action.command)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(2)
                                    .textSelection(.enabled)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.right.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.07))
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
        }
    }

    private func actionButton(_ action: ServerCommandAction) -> some View {
        Button {
            run(action)
        } label: {
            Label(LocalizedStringKey(action.title), systemImage: action.systemImage)
        }
        .buttonStyle(.bordered)
        .tint(action.style == .mutating ? Color.orange : Color.accentColor)
        .help(action.detail)
    }

    private func run(_ action: ServerCommandAction) {
        dismiss()
        onRun(action.command)
    }

    private func serviceColor(_ service: TerminalRemoteService) -> Color {
        switch service.activeState {
        case "active": .green
        case "failed": .red
        case "activating", "deactivating", "reloading": .orange
        default: .secondary
        }
    }

    private func emptyState(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(LocalizedStringKey(title))
                .font(.headline)
            Text(LocalizedStringKey(detail))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .padding(20)
    }
}
