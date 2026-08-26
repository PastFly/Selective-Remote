import AppKit
import SwiftUI

enum SFTPPropertiesTarget: Identifiable, Equatable {
    case local(SFTPLocalEntry)
    case remote(SFTPRemoteEntry, directory: String)

    var id: String {
        switch self {
        case let .local(entry):
            "local:\(entry.id)"
        case let .remote(entry, directory):
            "remote:\(directory):\(entry.id)"
        }
    }

    var name: String {
        switch self {
        case let .local(entry): entry.name
        case let .remote(entry, _): entry.name
        }
    }

    var path: String {
        switch self {
        case let .local(entry):
            entry.url.path
        case let .remote(entry, directory):
            SFTPService.joinedRemotePath(directory, entry.name)
        }
    }

    var isDirectory: Bool {
        switch self {
        case let .local(entry): entry.isDirectory
        case let .remote(entry, _): entry.isDirectory
        }
    }

    var isSymbolicLink: Bool {
        switch self {
        case let .local(entry): entry.isSymbolicLink
        case let .remote(entry, _): entry.isSymbolicLink
        }
    }

    var owner: String {
        switch self {
        case let .local(entry):
            entry.ownerID.map { "\(entry.owner) · UID \($0)" } ?? entry.owner
        case let .remote(entry, _): entry.owner
        }
    }

    var group: String {
        switch self {
        case let .local(entry):
            entry.groupID.map { "\(entry.group) · GID \($0)" } ?? entry.group
        case let .remote(entry, _): entry.group
        }
    }

    var permissions: String {
        switch self {
        case let .local(entry): entry.permissions
        case let .remote(entry, _): entry.permissions
        }
    }

    var modeText: String {
        switch self {
        case let .local(entry): entry.modeText
        case let .remote(entry, _): entry.modeText == "—" ? "" : entry.modeText
        }
    }

    var ownerIDText: String {
        ""
    }

    var groupIDText: String {
        ""
    }

    var sizeText: String {
        switch self {
        case let .local(entry): entry.sizeText
        case let .remote(entry, _): entry.sizeText
        }
    }

    var modifiedText: String {
        switch self {
        case let .local(entry): entry.modifiedText
        case let .remote(entry, _): entry.modifiedText
        }
    }

    var locationTitle: String {
        switch self {
        case .local: UpdateLocalization.text(ru: "Этот Mac", en: "This Mac")
        case .remote: UpdateLocalization.text(ru: "Удалённый сервер", en: "Remote server")
        }
    }
}

struct SFTPPropertiesView: View {
    @Environment(\.dismiss) private var dismiss
    let target: SFTPPropertiesTarget
    let onApply: (_ mode: String?, _ ownerID: Int?, _ groupID: Int?) -> Void

    @State private var mode: String
    @State private var ownerID: String
    @State private var groupID: String

    init(
        target: SFTPPropertiesTarget,
        onApply: @escaping (_ mode: String?, _ ownerID: Int?, _ groupID: Int?) -> Void
    ) {
        self.target = target
        self.onApply = onApply
        _mode = State(initialValue: target.modeText)
        _ownerID = State(initialValue: target.ownerIDText)
        _groupID = State(initialValue: target.groupIDText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(
                    systemName: target.isDirectory
                        ? "folder.fill"
                        : target.isSymbolicLink ? "link" : "doc.text"
                )
                .font(.system(size: 34))
                .foregroundStyle(target.isDirectory ? Color.blue : Color.secondary)

                VStack(alignment: .leading, spacing: 3) {
                    Text(target.name)
                        .font(.title2.bold())
                        .lineLimit(2)
                    Text(target.locationTitle)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            GroupBox("Общие сведения") {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 9) {
                    metadataRow("Путь", target.path, monospaced: true)
                    metadataRow(
                        "Тип",
                        target.isDirectory
                            ? "Папка"
                            : target.isSymbolicLink ? "Символическая ссылка" : "Файл"
                    )
                    metadataRow("Размер", target.sizeText)
                    metadataRow("Изменён", target.modifiedText)
                    metadataRow("Владелец", target.owner)
                    metadataRow("Группа", target.group)
                    metadataRow("Доступ", "\(target.permissions) · \(target.modeText)")
                }
                .padding(8)
            }

            GroupBox("POSIX-права и владелец") {
                VStack(alignment: .leading, spacing: 12) {
                    Grid(
                        alignment: .leading,
                        horizontalSpacing: 28,
                        verticalSpacing: 10
                    ) {
                        GridRow {
                            Text("Кому")
                                .font(.headline)
                            Text("Чтение")
                                .font(.headline)
                            Text("Запись")
                                .font(.headline)
                            Text("Выполнение")
                                .font(.headline)
                        }
                        permissionRow(
                            "Владелец",
                            read: 0o400,
                            write: 0o200,
                            execute: 0o100
                        )
                        Divider()
                        permissionRow(
                            "Группа",
                            read: 0o040,
                            write: 0o020,
                            execute: 0o010
                        )
                        Divider()
                        permissionRow(
                            "Остальные",
                            read: 0o004,
                            write: 0o002,
                            execute: 0o001
                        )
                    }

                    Divider()

                    HStack(spacing: 18) {
                        LabeledContent("Восьмеричный режим") {
                            TextField("0644", text: $mode)
                                .textFieldStyle(.roundedBorder)
                                .font(.body.monospacedDigit())
                                .frame(width: 90)
                        }
                        LabeledContent("UID") {
                            TextField("без изменения", text: $ownerID)
                                .textFieldStyle(.roundedBorder)
                                .font(.body.monospacedDigit())
                                .frame(width: 116)
                        }
                        LabeledContent("GID") {
                            TextField("без изменения", text: $groupID)
                                .textFieldStyle(.roundedBorder)
                                .font(.body.monospacedDigit())
                                .frame(width: 116)
                        }
                    }

                    Text(UpdateLocalization.text(
                        ru: "Галочки и восьмеричный режим синхронизированы. UID/GID меняются только если у текущего пользователя есть соответствующие права. Пустое поле оставляет значение без изменения.",
                        en: "The checkboxes and octal mode stay synchronized. UID/GID change only when the current user has sufficient permission. An empty field leaves the value unchanged."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(8)
            }

            HStack {
                Spacer()
                Button("Закрыть", role: .cancel) {
                    dismiss()
                }
                Button("Применить") {
                    onApply(
                        mode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? nil
                            : mode,
                        parsedID(ownerID),
                        parsedID(groupID)
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!valuesAreValid)
            }
        }
        .padding(24)
        .frame(minWidth: 700, minHeight: 590)
    }

    @ViewBuilder
    private func permissionRow(
        _ title: String,
        read: Int,
        write: Int,
        execute: Int
    ) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(minWidth: 120, alignment: .leading)
            Toggle("Чтение для: \(title)", isOn: permissionBinding(read))
                .labelsHidden()
            Toggle("Запись для: \(title)", isOn: permissionBinding(write))
                .labelsHidden()
            Toggle("Выполнение для: \(title)", isOn: permissionBinding(execute))
                .labelsHidden()
        }
        .toggleStyle(SelectiveRemoteCheckboxToggleStyle())
    }

    private func permissionBinding(_ mask: Int) -> Binding<Bool> {
        Binding(
            get: { currentModeValue & mask != 0 },
            set: { isEnabled in
                var value = currentModeValue
                if isEnabled {
                    value |= mask
                } else {
                    value &= ~mask
                }
                mode = String(format: "%04o", value)
            }
        )
    }

    private var currentModeValue: Int {
        let candidate = mode.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalized = try? SFTPPermissionFormatter.normalizedMode(candidate),
           let value = Int(normalized, radix: 8)
        {
            return value
        }
        if let normalized = try? SFTPPermissionFormatter.normalizedMode(target.modeText),
           let value = Int(normalized, radix: 8)
        {
            return value
        }
        return 0
    }

    @ViewBuilder
    private func metadataRow(
        _ label: String,
        _ value: String,
        monospaced: Bool = false
    ) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Group {
                if monospaced {
                    Text(value).font(.body.monospaced())
                } else {
                    Text(value)
                }
            }
            .textSelection(.enabled)
            .lineLimit(2)
            .truncationMode(.middle)
        }
    }

    private var valuesAreValid: Bool {
        let modeValue = mode.trimmingCharacters(in: .whitespacesAndNewlines)
        let modeValid = modeValue.isEmpty
            || (try? SFTPPermissionFormatter.normalizedMode(modeValue)) != nil
        return modeValid && idIsValid(ownerID) && idIsValid(groupID)
    }

    private func idIsValid(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        guard let number = Int(trimmed) else { return false }
        return number >= 0
    }

    private func parsedID(_ value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : Int(trimmed)
    }
}

struct SFTPRemoteEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let document: SFTPRemoteTextDocument
    let onSave: (String) -> Void

    @State private var text: String

    init(
        document: SFTPRemoteTextDocument,
        onSave: @escaping (String) -> Void
    ) {
        self.document = document
        self.onSave = onSave
        _text = State(initialValue: document.text)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "doc.text")
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(document.name)
                        .font(.headline)
                    Text(document.remotePath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text("\(text.count) символов")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("Отмена", role: .cancel) {
                    dismiss()
                }
                Button("Сохранить на сервер") {
                    onSave(text)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
            }
            .padding(16)

            Divider()

            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(minWidth: 880, minHeight: 620)
    }
}
