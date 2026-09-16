import SwiftUI

struct SelectiveRemoteTeamSnippetEditorRequest: Identifiable {
    let id = UUID()
    let context: SelectiveRemoteTeamSnippetVaultContext
    let snippet: SelectiveRemoteTeamSnippet?
}

struct SelectiveRemoteTeamSnippetMutationMessage: Identifiable {
    let id = UUID()
    let text: String
    let isError: Bool
}

struct SelectiveRemoteTeamSnippetEditorView: View {
    let request: SelectiveRemoteTeamSnippetEditorRequest
    let onSave: (UUID, String, String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var folder: String
    @State private var command: String

    init(
        request: SelectiveRemoteTeamSnippetEditorRequest,
        onSave: @escaping (UUID, String, String, String) -> Void
    ) {
        self.request = request
        self.onSave = onSave
        _title = State(initialValue: request.snippet?.title ?? "")
        _folder = State(initialValue: request.snippet?.folder ?? "")
        _command = State(initialValue: request.snippet?.body ?? "")
    }

    private var isValid: Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title == trimmed
            && !title.isEmpty
            && title.count <= 120
            && !title.contains(where: { $0.isNewline })
            && folder == folder.trimmingCharacters(in: .whitespacesAndNewlines)
            && folder.count <= 120
            && !folder.contains(where: { $0.isNewline })
            && !command.isEmpty
            && command.count <= 32_768
            && !command.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
                    && $0.value != 9
                    && $0.value != 10
                    && $0.value != 13
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(request.snippet == nil
                    ? UpdateLocalization.text(ru: "Новый Team Snippet", en: "New Team Snippet")
                    : UpdateLocalization.text(ru: "Изменить Team Snippet", en: "Edit Team Snippet")
                )
                .font(.title2.bold())
                Text("\(request.context.teamName) / \(request.context.vaultName)")
                    .foregroundStyle(.secondary)
            }

            TextField(UpdateLocalization.text(ru: "Название", en: "Name"), text: $title)
                .textFieldStyle(.roundedBorder)

            TextField(
                UpdateLocalization.text(
                    ru: "Папка (например, Production/Deploy)",
                    en: "Folder (for example, Production/Deploy)"
                ),
                text: $folder
            )
            .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 8) {
                Text(UpdateLocalization.text(ru: "Команда", en: "Command"))
                    .font(.headline)
                TextEditor(text: $command)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55))
                    }
                    .frame(minHeight: 220)
            }

            Label(
                UpdateLocalization.text(
                    ru: "Сниппет будет зашифрован и синхронизирован внутри выбранного Team Vault.",
                    en: "The snippet will be encrypted and synchronized inside the selected Team Vault."
                ),
                systemImage: "lock.shield"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button(UpdateLocalization.text(ru: "Отмена", en: "Cancel")) { dismiss() }
                Button(request.snippet == nil
                    ? UpdateLocalization.text(ru: "Добавить", en: "Add")
                    : UpdateLocalization.text(ru: "Сохранить", en: "Save")
                ) {
                    onSave(request.snippet?.recordID ?? UUID(), title, command, folder)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
            }
        }
        .padding(24)
        .frame(width: 560, height: 520)
    }
}
