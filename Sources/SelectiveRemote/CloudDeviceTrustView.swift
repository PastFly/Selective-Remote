import SwiftUI

struct SelectiveRemoteCloudDeviceTrustView: View {
    let endpoint: URL
    let client: SelectiveRemoteCloudAPIClient

    @Environment(\.dismiss) private var dismiss
    @AppStorage("SelectiveRemote.cloud.device-id.v1") private var storedDeviceID = ""
    @State private var coordinator: SelectiveRemoteCloudDeviceTrustCoordinator?
    @State private var inspection: SelectiveRemoteCloudDeviceTrustCoordinator.Inspection?
    @State private var requests: [SelectiveRemoteCloudDeviceTrustRequest] = []
    @State private var challenges: [UUID: SelectiveRemoteCloudDeviceTrustCoordinator.PendingApproval] = [:]
    @State private var comparison: [UUID: String] = [:]
    @State private var pairingFingerprint = ""
    @State private var pairingCheckpoint = ""
    @State private var rootLossAcknowledged = false
    @State private var revocationTarget: UUID?
    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var successMessage: String?

    private func text(_ ru: String, _ en: String) -> String {
        UpdateLocalization.text(ru: ru, en: en)
    }

    var body: some View {
        Form {
            Section {
                Text(text("Доверие устройств", "Device Trust"))
                    .font(.title2.bold())
                Text(text(
                    "Подписанное подтверждение новых устройств. Сравнивайте отпечаток на обоих устройствах напрямую. Данные сервера без такой проверки не устанавливают доверие.",
                    "Signed approval for new devices. Compare fingerprints directly on both devices. Server data alone does not establish trust."
                ))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if let successMessage {
                    Label(successMessage, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            if let inspection {
                Section(text("Этот Mac", "This Mac")) {
                    Text(Self.fingerprint(inspection.identity.publicKey))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    switch inspection.phase {
                    case .firstDevice, .publishPending:
                        Text(text(
                            "Это первое доверенное устройство аккаунта. Закрытый корень будет создан и сохранён в Keychain этого Mac. Если потерять все устройства с корнем, потребуется отдельное восстановление и смена ключей.",
                            "This is the first trusted account device. The private root will be created in this Mac's Keychain. Losing every root holder requires separate recovery and rekey."
                        ))
                        Toggle(text("Я понимаю последствия потери корня", "I understand root loss"),
                            isOn: $rootLossAcknowledged)
                        Button(inspection.phase == .firstDevice
                            ? text("Создать корень доверия", "Create trust root")
                            : text("Повторить публикацию", "Retry publication")) {
                            perform { _ = try await coordinator?.bootstrap() }
                        }
                        .disabled(isBusy || !rootLossAcknowledged)
                    case .pairingRequired:
                        Text(text(
                            "Получите отпечаток корня и код контрольной точки с уже доверенного устройства напрямую. Скопированные только из Cloud значения не подтверждают его личность.",
                            "Get the root fingerprint and checkpoint code directly from a trusted device. Values copied only from Cloud do not establish its identity."
                        ))
                        TextField(text("Отпечаток корня", "Root fingerprint"),
                                  text: $pairingFingerprint)
                        TextField(text("Код контрольной точки", "Checkpoint code"),
                                  text: $pairingCheckpoint)
                        Button(text("Сравнить и привязать", "Compare and pair")) {
                            perform { _ = try await coordinator?.pair(
                                fingerprint: pairingFingerprint,
                                checkpointDigest: pairingCheckpoint) }
                        }
                        .disabled(isBusy || pairingFingerprint.isEmpty || pairingCheckpoint.isEmpty)
                    case .pinMissing:
                        Text(text(
                            "Локальная отметка доверия отсутствует. Требуется восстановление через проверенное устройство.",
                            "The local trust pin is missing. Recovery through a trusted device is required."
                        ))
                    case .custodian, .paired, .certified, .revoked:
                        if let pin = inspection.pin {
                            LabeledContent(text("Корень", "Root"), value: pin.rootFingerprint)
                                .textSelection(.enabled)
                            LabeledContent(text("Контрольная точка", "Checkpoint"),
                                value: pin.checkpointDigest)
                                .textSelection(.enabled)
                        }
                        if inspection.phase == .revoked {
                            Text(text("Сертификат этого Mac больше не активен.",
                                      "This Mac's certificate is no longer active."))
                                .foregroundStyle(.orange)
                        } else if inspection.phase == .certified {
                            Label(text("Сертификат проверен", "Certificate verified"),
                                  systemImage: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                        }
                        if inspection.phase == .paired && ownRequest == nil {
                            Button(text("Запросить подтверждение", "Request approval")) {
                                perform { try await coordinator?.requestApproval() }
                            }
                            .disabled(isBusy)
                        }
                        if [SelectiveRemoteCloudDeviceTrustCoordinator.Phase.certified,
                            .custodian].contains(inspection.phase), ownRequest == nil {
                            Button(text("Запросить замену ключа", "Request key replacement")) {
                                perform { try await coordinator?.requestRekey() }
                            }
                            .disabled(isBusy)
                        }
                    }
                }

                if let ownRequest {
                    Section(text("Заявка этого Mac", "This Mac's request")) {
                        Text("\(ownRequest.status) · \(ownRequest.createdAt)")
                        Text(Self.fingerprint(ownRequest.publicKey))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        if ownRequest.status == "challenged", ownRequest.challengeState == "offered" {
                            Button(text("Ответить на проверку ключа", "Answer key challenge")) {
                                perform { try await coordinator?.answer(ownRequest) }
                            }
                            .disabled(isBusy)
                        }
                    }
                }

                if inspection.phase == .custodian {
                    Section(text("Ожидают подтверждения", "Awaiting approval")) {
                        ForEach(requests.filter { $0.deviceID != inspection.identity.deviceID
                            || $0.keyVersion > 1 }) { request in
                            if ["pending", "challenged", "answered"].contains(request.status) {
                                requestCard(request)
                            }
                        }
                    }
                    if let active = inspection.snapshot.checkpoint?.payload.entries {
                        Section(text("Подтверждённые устройства", "Certified devices")) {
                            ForEach(active.filter { $0.deviceID != inspection.identity.deviceID },
                                    id: \.deviceID) { entry in
                                HStack {
                                    Text(entry.deviceID.canonicalCloudString)
                                        .font(.system(.caption, design: .monospaced))
                                    Spacer()
                                    Button(text("Отозвать", "Revoke"), role: .destructive) {
                                        revocationTarget = entry.deviceID
                                    }
                                    .disabled(isBusy)
                                }
                            }
                        }
                    }
                }
            } else if isBusy {
                ProgressView(text("Проверяем доверие…", "Checking trust…"))
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 640, idealWidth: 760, minHeight: 500, idealHeight: 650)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(text("Обновить", "Refresh"), systemImage: "arrow.clockwise") {
                    Task { await refresh() }
                }
                .disabled(isBusy)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(text("Готово", "Done")) { dismiss() }
            }
        }
        .confirmationDialog(text("Отозвать устройство?", "Revoke device?"),
            isPresented: Binding(get: { revocationTarget != nil },
                set: { if !$0 { revocationTarget = nil } })) {
            if let target = revocationTarget {
                Button(text("Отозвать подпись и завершить сессии", "Revoke certificate and sessions"),
                       role: .destructive) {
                    revocationTarget = nil
                    perform { try await coordinator?.revoke(target) }
                }
            }
        } message: {
            Text(text("Новые ключи больше не будут доступны; уже полученные данные нельзя стереть удалённо.",
                      "Future keys will be unavailable; previously received data cannot be erased remotely."))
        }
        .task { await load() }
    }

    private var ownRequest: SelectiveRemoteCloudDeviceTrustRequest? {
        guard let deviceID = inspection?.identity.deviceID else { return nil }
        return requests.first { $0.deviceID == deviceID
            && ["pending", "challenged", "answered"].contains($0.status) }
    }

    @ViewBuilder
    private func requestCard(_ request: SelectiveRemoteCloudDeviceTrustRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(request.name) · \(request.platform)").font(.headline)
            Text(request.createdAt).font(.caption).foregroundStyle(.secondary)
            Text(Self.fingerprint(request.publicKey))
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            if request.status == "pending" || request.challengeState == nil {
                TextField(text("Введите отпечаток с нового устройства", "Enter fingerprint from new device"),
                    text: Binding(get: { comparison[request.id] ?? "" },
                                  set: { comparison[request.id] = $0 }))
                Button(text("Проверить устройство", "Verify device")) {
                    perform {
                        if let value = try await coordinator?.startApproval(request,
                            confirmedFingerprint: comparison[request.id] ?? "") {
                            challenges[request.id] = value
                        }
                    }
                }
                .disabled(isBusy || (comparison[request.id] ?? "").isEmpty)
            } else if let pending = challenges[request.id] {
                Button(text("Проверить ответ и подтвердить", "Verify answer and approve")) {
                    perform {
                        try await coordinator?.finishApproval(pending)
                        challenges.removeValue(forKey: request.id)
                    }
                }
                .disabled(isBusy)
            } else {
                Text(text("Challenge начат в другом окне. Дождитесь истечения и начните заново.",
                          "Challenge began in another window. Wait for expiry and restart."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button(text("Отклонить", "Reject"), role: .destructive) {
                perform { try await coordinator?.reject(request.id) }
            }
            .disabled(isBusy)
        }
        .padding(.vertical, 6)
    }

    private static func fingerprint(_ key: SelectiveRemoteTeamDevicePublicKey) -> String {
        SelectiveRemoteCloudDeviceTrustCoordinator.keyFingerprint(key)
    }

    private func load() async {
        guard let deviceID = UUID(uuidString: storedDeviceID),
              deviceID.isSelectiveRemoteCloudUUID else {
            errorMessage = text("Сначала войдите в Cloud на этом Mac.",
                "Sign in to Cloud on this Mac first.")
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let user = try await client.currentUser(endpoint: endpoint)
            coordinator = SelectiveRemoteCloudDeviceTrustCoordinator(endpoint: endpoint,
                client: client, accountID: user.id, deviceID: deviceID)
            await refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    private func refresh() async {
        guard let coordinator else { return }
        do {
            let checked = try await coordinator.inspect()
            inspection = checked
            requests = try await client.deviceTrustRequests(endpoint: endpoint)
            if checked.rekeyCommitted {
                successMessage = text("Новый ключ подтверждён и сохранён в Keychain. Перезапустите Team Vault синхронизацию.",
                    "The new key is certified and saved in Keychain. Restart Team Vault sync.")
            }
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        isBusy = true
        errorMessage = nil
        Task { @MainActor in
            defer { isBusy = false }
            do {
                try await operation()
                await refresh()
            } catch { errorMessage = error.localizedDescription }
        }
    }
}
