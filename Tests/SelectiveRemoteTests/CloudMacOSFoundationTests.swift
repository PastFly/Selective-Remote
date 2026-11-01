import CryptoKit
import Darwin
import Foundation
import Testing
@testable import SelectiveRemote

@Suite("macOS Cloud session and Team crypto foundation")
struct CloudMacOSFoundationTests {
    @Test("A background 401 identifies only its own session for UI invalidation")
    func authenticationLossNoticeIsBoundToOriginalSession() async throws {
        let endpoint = URL(string: "https://loss-notice-\(UUID()).example.invalid")!
        let store = SelectiveRemoteCloudMemoryTokenStore()
        store.saveToken(String(repeating: "a", count: 43), for: endpoint)
        let notices = CloudSessionNoticeSink()
        let client = SelectiveRemoteCloudAPIClient(tokenStore: store, dataLoader: { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        }, cleanupWarning: {}, sessionLost: { await notices.append($0) },
           publicationStore: { throw CancellationError() })
        let old = try await client.sessionBinding(endpoint: endpoint)
        _ = try? await client.currentUser(endpoint: endpoint)
        let event = try #require(await notices.events.first)
        #expect(event.matches(old))
        let epoch = SelectiveRemotePublicationLifecycle.epoch(endpoint: endpoint)
        try SelectiveRemotePublicationLifecycle.transitionIfCurrent(endpoint: endpoint, expectedEpoch: epoch) { _ in
            store.saveToken(String(repeating: "b", count: 43), for: endpoint)
        }
        let next = try await client.sessionBinding(endpoint: endpoint)
        #expect(!event.matches(next))
        #expect(await notices.events.count == 1)
    }
    @Test("A background authentication failure reports incomplete token cleanup")
    func backgroundAuthenticationLossReportsCleanupFailure() async throws {
        let endpoint = URL(string: "https://background-warning-\(UUID()).example.invalid")!
        let calls = CloudLogoutCallCounter()
        let store = CloudFailingRemovalTokenStore(value: String(repeating: "t", count: 43))
        let client = SelectiveRemoteCloudAPIClient(tokenStore: store, dataLoader: { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        }, cleanupWarning: { await calls.record() }, publicationStore: { throw CancellationError() })
        _ = try? await client.currentUser(endpoint: endpoint) // background caller may discard the error
        #expect(await calls.value == 1)
    }

    @Test("A successfully removed expired session does not produce a cleanup warning")
    func successfulAuthenticationCleanupHasNoWarning() async throws {
        let endpoint = URL(string: "https://background-clean-\(UUID()).example.invalid")!
        let calls = CloudLogoutCallCounter()
        let store = SelectiveRemoteCloudMemoryTokenStore()
        store.saveToken(String(repeating: "t", count: 43), for: endpoint)
        let client = SelectiveRemoteCloudAPIClient(tokenStore: store, dataLoader: { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        }, cleanupWarning: { await calls.record() }, publicationStore: { throw CancellationError() })
        _ = try? await client.currentUser(endpoint: endpoint)
        #expect(await calls.value == 0)
    }

    @Test("A delayed cleanup warning leaves the new account and its sync state intact", .timeLimit(.minutes(1)))
    @MainActor
    func delayedWarningDoesNotResetNewAccount() async throws {
        let endpoint = URL(string: "https://delayed-warning-\(UUID()).example.invalid")!
        let store = CloudFailingRemovalTokenStore(value: String(repeating: "a", count: 43))
        let presentation = SyncPresentationStore()
        let barrier = CloudLoginResponseBarrier()
        let client = SelectiveRemoteCloudAPIClient(tokenStore: store, dataLoader: { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        }, cleanupWarning: {
            await barrier.suspendResponse()
            await MainActor.run { presentation.reportUnconfirmedSessionCleanup() }
        }, publicationStore: { throw CancellationError() })
        let pending = Task { _ = try? await client.currentUser(endpoint: endpoint) }
        guard await barrier.waitForRequest() else { await barrier.resumeResponse(); Issue.record("Timed out waiting for warning"); return }
        let epoch = SelectiveRemotePublicationLifecycle.epoch(endpoint: endpoint)
        try SelectiveRemotePublicationLifecycle.transitionIfCurrent(endpoint: endpoint, expectedEpoch: epoch) { _ in
            try store.saveToken(String(repeating: "b", count: 43), for: endpoint)
        }
        presentation.setAccount(endpoint: endpoint.absoluteString, deviceID: UUID().uuidString)
        presentation.recordPersonalSuccess(revision: 9)
        let newGeneration = presentation.generation
        await barrier.resumeResponse()
        await pending.value
        #expect(try store.token(for: endpoint) == String(repeating: "b", count: 43))
        #expect(presentation.generation == newGeneration)
        #expect(presentation.personal.appliedRevision == 9)
        #expect(presentation.unconfirmedSessionCleanup)
    }

    @Test("A stale 401 cannot warn for or clear the newer account", .timeLimit(.minutes(1)))
    func staleUnauthorizedResponseDoesNotWarn() async throws {
        let endpoint = URL(string: "https://stale-warning-\(UUID()).example.invalid")!
        let store = CloudFailingRemovalTokenStore(value: String(repeating: "a", count: 43))
        let barrier = CloudLoginResponseBarrier(), calls = CloudLogoutCallCounter()
        let client = SelectiveRemoteCloudAPIClient(tokenStore: store, dataLoader: { request in
            await barrier.suspendResponse()
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        }, cleanupWarning: { await calls.record() }, publicationStore: { throw CancellationError() })
        let pending = Task { try await client.currentUser(endpoint: endpoint) }
        guard await barrier.waitForRequest() else { await barrier.resumeResponse(); Issue.record("Timed out waiting for request"); return }
        SelectiveRemotePublicationLifecycle.invalidate(endpoint: endpoint)
        try store.saveToken(String(repeating: "b", count: 43), for: endpoint)
        await barrier.resumeResponse()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(await calls.value == 0)
        #expect(try store.token(for: endpoint) == String(repeating: "b", count: 43))
    }

    @Test("A delayed sign-out never revokes a later account")
    func delayedBoundLogoutDoesNotRevokeNewAccount() async throws {
        let endpoint = URL(string: "https://bound-logout-\(UUID()).example.invalid")!
        let tokens = SelectiveRemoteCloudMemoryTokenStore()
        let calls = CloudLogoutCallCounter()
        tokens.saveToken(String(repeating: "a", count: 43), for: endpoint)
        let client = SelectiveRemoteCloudAPIClient(tokenStore: tokens, dataLoader: { request in
            await calls.record()
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
        }, publicationStore: { throw CancellationError() })
        let old = try await client.sessionBinding(endpoint: endpoint)
        SelectiveRemotePublicationLifecycle.invalidate(endpoint: endpoint)
        tokens.saveToken(String(repeating: "b", count: 43), for: endpoint)
        await #expect(throws: CancellationError.self) { try await client.logout(endpoint: endpoint, session: old) }
        #expect(await calls.value == 0)
        #expect(tokens.token(for: endpoint) == String(repeating: "b", count: 43))
    }

    @Test("Bound logout still revokes its known session when Keychain cannot be read")
    func boundLogoutReadFailureStillRevokes() async throws {
        let endpoint = URL(string: "https://bound-unreadable-\(UUID()).example.invalid")!
        let token = String(repeating: "a", count: 43), calls = CloudLogoutCallCounter()
        let store = CloudIntermittentReadTokenStore(value: token)
        let client = SelectiveRemoteCloudAPIClient(tokenStore: store, dataLoader: { request in
            await calls.record()
            #expect(request.url?.path == "/v1/auth/logout")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
        }, cleanupWarning: {}, publicationStore: { throw CancellationError() })
        let session = try await client.sessionBinding(endpoint: endpoint)
        store.setUnreadable(true)
        await #expect(throws: SelectiveRemoteCloudError.logoutUnconfirmed) {
            try await client.logout(endpoint: endpoint, session: session)
        }
        store.setUnreadable(false)
        #expect(await calls.value == 1)
        #expect(await client.hasStoredSession(endpoint: endpoint) == false)
    }

    @Test("A known old token remains quarantined after the next login")
    func boundLogoutQuarantinesKnownTokenAcrossNextLogin() async throws {
        let endpoint = URL(string: "https://bound-quarantine-\(UUID()).example.invalid")!
        let oldToken = String(repeating: "a", count: 43)
        let store = CloudIntermittentReadTokenStore(value: oldToken)
        let client = SelectiveRemoteCloudAPIClient(tokenStore: store, dataLoader: { _ in
            throw URLError(.notConnectedToInternet)
        }, cleanupWarning: {}, publicationStore: { throw CancellationError() })
        let old = try await client.sessionBinding(endpoint: endpoint)
        store.setUnreadable(true)
        _ = try? await client.logout(endpoint: endpoint, session: old)
        store.setUnreadable(false)
        let epoch = SelectiveRemotePublicationLifecycle.epoch(endpoint: endpoint)
        try SelectiveRemotePublicationLifecycle.transitionIfCurrent(endpoint: endpoint, expectedEpoch: epoch) { _ in
            try store.saveToken(String(repeating: "b", count: 43), for: endpoint)
        }
        #expect(await client.hasStoredSession(endpoint: endpoint))
        try store.saveToken(oldToken, for: endpoint) // Simulate an older process restoring its envelope.
        #expect(await client.hasStoredSession(endpoint: endpoint) == false)
    }

    @Test("Failed local logout warns before waiting for the network", .timeLimit(.minutes(1)))
    func logoutWarningDoesNotWaitForNetwork() async throws {
        let endpoint = URL(string: "https://logout-warning-\(UUID()).example.invalid")!
        let store = CloudFailingRemovalTokenStore(value: String(repeating: "a", count: 43))
        let calls = CloudLogoutCallCounter(), barrier = CloudLoginResponseBarrier()
        let client = SelectiveRemoteCloudAPIClient(tokenStore: store, dataLoader: { request in
            await barrier.suspendResponse()
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
        }, cleanupWarning: { await calls.record() }, publicationStore: { throw CancellationError() })
        let pending = Task { try? await client.logout(endpoint: endpoint) }
        guard await barrier.waitForRequest() else { await barrier.resumeResponse(); Issue.record("Timed out waiting for logout"); return }
        #expect(await calls.value == 1)
        await barrier.resumeResponse()
        await pending.value
        #expect(await calls.value == 1)
    }

    @Test("A session-bound Team request never switches to a later account", .timeLimit(.minutes(1)))
    func boundTeamRequestDoesNotUseNewAccount() async throws {
        let endpoint = URL(string: "https://bound-team-\(UUID()).example.invalid")!
        let oldToken = String(repeating: "a", count: 43), newToken = String(repeating: "b", count: 43)
        let tokens = SelectiveRemoteCloudMemoryTokenStore()
        tokens.saveToken(oldToken, for: endpoint)
        let session = SelectiveRemotePublicationSession(endpoint: endpoint, accountID: UUID(), deviceID: UUID(),
                                                        token: oldToken, tokenStore: tokens)
        let barrier = CloudLoginResponseBarrier(), calls = CloudLogoutCallCounter()
        let client = SelectiveRemoteCloudAPIClient(tokenStore: tokens, dataLoader: { request in
            await calls.record()
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(oldToken)")
            await barrier.suspendResponse()
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, boundPublicationSession: session, publicationStore: { throw CancellationError() })
        let pending = Task { try await client.authorizedResponse(endpoint: endpoint, path: "v1/teams", method: "PUT") }
        guard await barrier.waitForRequest() else { await barrier.resumeResponse(); Issue.record("Timed out waiting for request"); return }
        SelectiveRemotePublicationLifecycle.invalidate(endpoint: endpoint)
        tokens.saveToken(newToken, for: endpoint)
        await barrier.resumeResponse()
        await #expect(throws: CancellationError.self) { try await pending.value }
        await #expect(throws: CancellationError.self) {
            try await client.authorizedResponse(endpoint: endpoint, path: "v1/teams", method: "PUT")
        }
        #expect(await calls.value == 1)
    }

    @Test("Logout revokes and quarantines a session when local token removal fails")
    func failedTokenRemovalStillRevokesAndQuarantines() async throws {
        let endpoint = URL(string: "https://logout-failure-\(UUID()).example.invalid")!
        let token = String(repeating: "t", count: 43)
        let calls = CloudLogoutCallCounter()
        let tokenStore = CloudFailingRemovalTokenStore(value: token)
        let client = SelectiveRemoteCloudAPIClient(
            tokenStore: tokenStore,
            dataLoader: { request in
                await calls.record()
                #expect(request.url?.path == "/v1/auth/logout")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
            },
            publicationStore: { throw CancellationError() }
        )
        do {
            try await client.logout(endpoint: endpoint)
            Issue.record("Local token removal failure must be reported")
        } catch {
            #expect(error as? SelectiveRemoteCloudError == .logoutUnconfirmed)
        }
        #expect(await calls.value == 1)
        #expect(await client.hasStoredSession(endpoint: endpoint) == false)
        try tokenStore.saveToken(String(repeating: "n", count: 43), for: endpoint)
        #expect(await client.hasStoredSession(endpoint: endpoint) == true)
    }

    @Test("Offline logout with a storage failure warns that the old session may survive restart")
    func offlineLogoutAndStorageFailureAreNotReportedAsSafe() async throws {
        let endpoint = URL(string: "https://offline-logout-\(UUID()).example.invalid")!
        let store = CloudFailingRemovalTokenStore(value: String(repeating: "t", count: 43))
        let client = SelectiveRemoteCloudAPIClient(tokenStore: store, dataLoader: { _ in
            throw URLError(.notConnectedToInternet)
        }, publicationStore: { throw CancellationError() })
        do {
            try await client.logout(endpoint: endpoint)
            Issue.record("A failed local and remote logout must not be reported as successful")
        } catch {
            #expect(error as? SelectiveRemoteCloudError == .logoutUnconfirmed)
            #expect(error.localizedDescription.contains("Cloud"))
        }
        #expect(await client.hasStoredSession(endpoint: endpoint) == false)
    }

    @Test("Logout blocks a formerly readable token when credential storage temporarily fails")
    func logoutReadFailureQuarantinesEndpointUntilNewLogin() async throws {
        let endpoint = URL(string: "https://logout-read-failure-\(UUID()).example.invalid")!
        let oldToken = String(repeating: "o", count: 43)
        let store = CloudIntermittentReadTokenStore(value: oldToken)
        let client = SelectiveRemoteCloudAPIClient(tokenStore: store, dataLoader: { _ in
            Issue.record("Cannot revoke an unreadable token")
            throw CancellationError()
        }, publicationStore: { throw CancellationError() })
        let priorEpoch = SelectiveRemotePublicationLifecycle.epoch(endpoint: endpoint)
        store.setUnreadable(true)
        do { try await client.logout(endpoint: endpoint); Issue.record("Logout must fail closed") }
        catch { #expect(error as? SelectiveRemoteCloudError == .logoutUnconfirmed) }
        store.setUnreadable(false)
        #expect(SelectiveRemotePublicationLifecycle.epoch(endpoint: endpoint) != priorEpoch)
        #expect(await client.hasStoredSession(endpoint: endpoint) == false)
        let epoch = SelectiveRemotePublicationLifecycle.epoch(endpoint: endpoint)
        try SelectiveRemotePublicationLifecycle.transitionIfCurrent(endpoint: endpoint, expectedEpoch: epoch) { _ in
            try store.saveToken(String(repeating: "n", count: 43), for: endpoint)
        }
        #expect(await client.hasStoredSession(endpoint: endpoint) == true)
    }

    @Test("A 401 with unreadable credential storage quarantines the session and reports incomplete cleanup")
    func unauthorizedWithUnreadableStorageStillQuarantines() async throws {
        let endpoint = URL(string: "https://unauthorized-read-failure-\(UUID()).example.invalid")!
        let store = CloudIntermittentReadTokenStore(value: String(repeating: "t", count: 43))
        let client = SelectiveRemoteCloudAPIClient(tokenStore: store, dataLoader: { request in
            store.setUnreadable(true)
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        }, publicationStore: { throw CancellationError() })
        do { _ = try await client.currentUser(endpoint: endpoint); Issue.record("A 401 must reject the session") }
        catch { #expect(error as? SelectiveRemoteCloudError == .logoutUnconfirmed) }
        store.setUnreadable(false)
        #expect(await client.hasStoredSession(endpoint: endpoint) == false)
        #expect(SyncIssue.classifyPersonal(SelectiveRemoteCloudError.logoutUnconfirmed) == .sessionExpired)
        #expect(SelectiveRemoteVaultPublicationCoordinator.authenticationLoss(SelectiveRemoteCloudError.logoutUnconfirmed))
    }

    @Test("login keeps the bearer token in the session store and authenticates later requests")
    func authenticatedFoundation() async throws {
        let endpoint = try SelectiveRemoteCloudEndpoint.normalized("https://authenticated-foundation.example.invalid")
        let deviceID = try #require(UUID(uuidString: "44444444-4444-4444-8444-444444444444"))
        let userID = try #require(UUID(uuidString: "66666666-6666-4666-8666-666666666666"))
        let membershipID = try #require(UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
        let teamID = try #require(UUID(uuidString: "11111111-1111-4111-8111-111111111111"))
        let token = String(repeating: "t", count: 43)
        let store = SelectiveRemoteCloudMemoryTokenStore()
        let stub = CloudHTTPStub { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/v1/auth/login"):
                let body = try #require(request.httpBody)
                let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                #expect(object["password"] as? String == "synthetic-password")
                return Self.response(request, status: 200, json: [
                    "token": token,
                    "user": [
                        "id": userID.uuidString.lowercased(),
                        "email": "user@example.invalid",
                        "username": "user",
                        "displayName": "User",
                        "createdAt": "2026-09-10T00:00:00.000Z"
                    ],
                    "deviceID": deviceID.uuidString.lowercased()
                ])
            case ("GET", "/v1/me"):
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
                return Self.response(request, status: 200, json: [
                    "id": userID.uuidString.lowercased(), "email": "user@example.invalid", "username": "user", "displayName": "User",
                    "deviceID": deviceID.uuidString.lowercased()
                ])
            case ("GET", "/v1/teams"):
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
                return Self.response(request, status: 200, json: ["teams": [[
                    "id": teamID.uuidString.lowercased(),
                    "name": "Platform",
                    "membershipID": membershipID.uuidString.lowercased(),
                    "role": "owner",
                    "membershipEpoch": 3,
                    "createdAt": "2026-09-06T00:00:00.000Z",
                    "updatedAt": "2026-09-06T00:00:00.000Z"
                ]]])
            case ("POST", "/v1/auth/logout"):
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
                return Self.response(request, status: 204, json: nil)
            default:
                Issue.record("Unexpected request: \(request.httpMethod ?? "nil") \(request.url?.path ?? "nil")")
                return Self.response(request, status: 500, json: ["error": "unexpected_request"])
            }
        }
        let client = SelectiveRemoteCloudAPIClient(
            tokenStore: store,
            dataLoader: { request in try stub.data(for: request) }
        )

        let user = try await client.login(
            endpoint: endpoint,
            email: " user@example.invalid ",
            password: "synthetic-password",
            device: .thisMac(id: deviceID, name: "Synthetic Mac")
        )
        #expect(user == SelectiveRemoteCloudUser(id: userID, email: "user@example.invalid", username: "user", displayName: "User"))
        #expect(store.token(for: endpoint) == token)
        let hasStoredSession = await client.hasStoredSession(endpoint: endpoint)
        #expect(hasStoredSession)
        #expect(try await client.currentUser(endpoint: endpoint) == user)
        let teams = try await client.teams(endpoint: endpoint)
        #expect(teams.count == 1)
        #expect(teams[0].role == .owner)
        #expect(teams[0].membershipEpoch == 3)
        let restoredClient = SelectiveRemoteCloudAPIClient(
            tokenStore: store,
            dataLoader: { request in try stub.data(for: request) }
        )
        #expect(await restoredClient.hasStoredSession(endpoint: endpoint))
        #expect(try await restoredClient.currentUser(endpoint: endpoint) == user)
        try await restoredClient.logout(endpoint: endpoint)
        #expect(store.token(for: endpoint) == nil)
    }

    @Test("Logout with an empty store rejects a pending successful login response", .timeLimit(.minutes(1)))
    func logoutBeforeLoginResponseCannotRestoreSession() async throws {
        let endpoint = URL(string: "https://pending-login-logout.example.invalid")!
        let deviceID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
        let store = SelectiveRemoteCloudMemoryTokenStore()
        let barrier = CloudLoginResponseBarrier()
        let client = SelectiveRemoteCloudAPIClient(
            tokenStore: store,
            dataLoader: { request in
                guard request.httpMethod == "POST", request.url?.path == "/v1/auth/login" else {
                    Issue.record("Empty-session logout must not send an HTTP request")
                    return Self.response(request, status: 500, json: nil)
                }
                await barrier.suspendResponse()
                return Self.response(request, status: 200, json: [
                    "token": String(repeating: "p", count: 43),
                    "user": ["id": "66666666-6666-4666-8666-666666666666", "email": "pending@example.invalid", "username": "pending", "displayName": "Pending", "createdAt": "2026-10-28T00:00:00.000Z"],
                    "deviceID": deviceID.uuidString.lowercased()
                ])
            },
            publicationStore: { throw CancellationError() }
        )
        let pending = Task {
            try await client.loginWithSession(
                endpoint: endpoint, email: "pending@example.invalid", password: "synthetic-password",
                device: .init(id: deviceID, name: "Synthetic Mac", platform: "macos", appVersion: "test", publicKey: nil)
            )
        }
        guard await barrier.waitForRequest() else { await barrier.resumeResponse(); Issue.record("Timed out waiting for login"); return }
        #expect(store.token(for: endpoint) == nil)
        do { try await client.logout(endpoint: endpoint) }
        catch { Issue.record("Empty-session logout should succeed: \(error)") }
        #expect(store.token(for: endpoint) == nil)
        await barrier.resumeResponse()
        switch await pending.result {
        case .success: Issue.record("A login response started before logout must not restore the session")
        case let .failure(error): #expect(error is CancellationError)
        }
        #expect(store.token(for: endpoint) == nil)
        #expect(await client.hasStoredSession(endpoint: endpoint) == false)
    }

    @Test("Logout removes an invalid raw token without a network request")
    func logoutClearsInvalidRawTokenLocally() async throws {
        let endpoint = URL(string: "https://invalid-token-logout.example.invalid")!
        let store = SelectiveRemoteCloudMemoryTokenStore()
        store.saveToken("invalid-short-token", for: endpoint)
        let client = SelectiveRemoteCloudAPIClient(
            tokenStore: store,
            dataLoader: { request in
                Issue.record("Invalid raw token must not be sent to the logout endpoint")
                return Self.response(request, status: 500, json: nil)
            },
            publicationStore: { throw CancellationError() }
        )
        #expect(await client.hasStoredSession(endpoint: endpoint) == false)
        do { try await client.logout(endpoint: endpoint) }
        catch { Issue.record("Logout must clear invalid local credentials: \(error)") }
        #expect(store.token(for: endpoint) == nil)
    }

    @Test("native Team management creates Teams, invitations and Shared Vaults")
    func nativeTeamManagement() async throws {
        let endpoint = try SelectiveRemoteCloudEndpoint.normalized("https://cloud.example.invalid")
        let teamID = try #require(UUID(uuidString: "11111111-1111-4111-8111-111111111111"))
        let membershipID = try #require(UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
        let userID = try #require(UUID(uuidString: "66666666-6666-4666-8666-666666666666"))
        let invitationID = try #require(UUID(uuidString: "77777777-7777-4777-8777-777777777777"))
        let linkInvitationID = try #require(UUID(uuidString: "88888888-8888-4888-8888-888888888888"))
        let vaultID = try #require(UUID(uuidString: "22222222-2222-4222-8222-222222222222"))
        let store = SelectiveRemoteCloudMemoryTokenStore()
        store.saveToken(String(repeating: "t", count: 43), for: endpoint)
        let stub = CloudHTTPStub { request in
            #expect(request.value(forHTTPHeaderField: "Idempotency-Key")?.hasPrefix("macos:") == true
                || request.httpMethod == "GET")
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/v1/teams"):
                #expect(Self.stringBodyValue(request, key: "name") == "Platform")
                return Self.response(request, status: 201, json: ["team": [
                    "id": teamID.canonicalCloudString, "name": "Platform",
                    "membershipID": membershipID.canonicalCloudString, "role": "owner", "membershipEpoch": 1,
                    "createdAt": "2026-09-09T00:00:00.000Z", "updatedAt": "2026-09-09T00:00:00.000Z"
                ]])
            case ("GET", "/v1/teams/\(teamID.canonicalCloudString)/members"):
                if let components = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false),
                   components.queryItems != nil {
                    if components.queryItems?.first(where: { $0.name == "search" })?.value == "legacy" {
                        return Self.response(request, status: 200, json: ["members": [[
                            "id": membershipID.canonicalCloudString, "userID": userID.canonicalCloudString,
                            "username": "owner", "displayName": "Owner", "role": "owner",
                            "epoch": 1, "joinedAt": "2026-09-09T00:00:00.000Z"
                        ]]])
                    }
                    #expect(components.queryItems?.first(where: { $0.name == "search" })?.value == "owner")
                    #expect(components.queryItems?.first(where: { $0.name == "role" })?.value == "owner")
                    #expect(components.queryItems?.first(where: { $0.name == "limit" })?.value == "50")
                    return Self.response(request, status: 200, json: [
                        "members": [[
                            "id": membershipID.canonicalCloudString, "userID": userID.canonicalCloudString,
                            "username": "owner", "displayName": "Owner", "role": "owner",
                            "epoch": 1, "joinedAt": "2026-09-09T00:00:00.000Z"
                        ]],
                        "nextCursor": NSNull(),
                        "total": 1,
                    ])
                }
                return Self.response(request, status: 200, json: ["members": [[
                    "id": membershipID.canonicalCloudString, "userID": userID.canonicalCloudString,
                    "username": "owner", "displayName": "Owner", "role": "owner",
                    "epoch": 1, "joinedAt": "2026-09-09T00:00:00.000Z"
                ]]])
            case ("POST", "/v1/teams/\(teamID.canonicalCloudString)/invitations"):
                #expect(Self.stringBodyValue(request, key: "role") == "viewer")
                if Self.stringBodyValue(request, key: "type") == "link" {
                    return Self.response(request, status: 201, json: ["invitation": [
                        "id": linkInvitationID.canonicalCloudString, "teamID": teamID.canonicalCloudString,
                        "teamName": "Platform", "type": "link", "targetUsername": NSNull(),
                        "role": "viewer", "status": "pending",
                        "acceptanceURL": "https://cloud.example.invalid/#accept-team-invitation?token=\(String(repeating: "x", count: 43))",
                        "createdAt": "2026-09-09T00:00:00.000Z", "expiresAt": "2026-09-11T00:00:00.000Z"
                    ]])
                }
                #expect(Self.stringBodyValue(request, key: "username") == "viewer")
                return Self.response(request, status: 201, json: ["invitation": [
                    "id": invitationID.canonicalCloudString, "teamID": teamID.canonicalCloudString,
                    "teamName": "Platform", "type": "username", "targetUsername": "viewer",
                    "role": "viewer", "status": "pending", "acceptanceURL": NSNull(),
                    "createdAt": "2026-09-09T00:00:00.000Z", "expiresAt": "2026-09-11T00:00:00.000Z"
                ]])
            case ("GET", "/v1/teams/\(teamID.canonicalCloudString)/invitations"):
                return Self.response(request, status: 200, json: ["invitations": [[
                    "id": invitationID.canonicalCloudString, "teamID": teamID.canonicalCloudString,
                    "teamName": "Platform", "type": "username", "targetUsername": "viewer",
                    "role": "viewer", "status": "pending", "acceptanceURL": NSNull(),
                    "createdAt": "2026-09-09T00:00:00.000Z", "expiresAt": "2026-09-11T00:00:00.000Z"
                ]]])
            case ("GET", "/v1/team-invitations"):
                return Self.response(request, status: 200, json: ["invitations": [[
                    "id": invitationID.canonicalCloudString, "teamID": teamID.canonicalCloudString,
                    "teamName": "Platform", "type": "username", "targetUsername": "viewer",
                    "role": "viewer", "status": "pending", "acceptanceURL": NSNull(),
                    "createdAt": "2026-09-09T00:00:00.000Z", "expiresAt": "2026-09-11T00:00:00.000Z"
                ]]])
            case ("POST", "/v1/team-invitations/accept"):
                #expect(Self.stringBodyValue(request, key: "invitationID") == invitationID.canonicalCloudString)
                return Self.response(request, status: 200, json: ["membership": [
                    "id": membershipID.canonicalCloudString, "userID": userID.canonicalCloudString,
                    "username": "viewer", "displayName": "Viewer", "role": "viewer",
                    "epoch": 1, "joinedAt": "2026-09-09T00:00:00.000Z"
                ]])
            case ("DELETE", "/v1/teams/\(teamID.canonicalCloudString)/invitations/\(linkInvitationID.canonicalCloudString)"):
                return Self.response(request, status: 200, json: ["cancelled": true])
            case ("POST", "/v1/teams/\(teamID.canonicalCloudString)/vaults"):
                #expect(Self.stringBodyValue(request, key: "name") == "Production")
                return Self.response(request, status: 201, json: ["vault": [
                    "id": vaultID.canonicalCloudString, "teamID": teamID.canonicalCloudString,
                    "name": "Production", "revision": 0, "keyGeneration": 1,
                    "rotationRequired": false, "createdAt": "2026-09-09T00:00:00.000Z",
                    "updatedAt": "2026-09-09T00:00:00.000Z"
                ]])
            default:
                Issue.record("Unexpected Team management request")
                return Self.response(request, status: 500, json: ["error": "unexpected_request"])
            }
        }
        let client = SelectiveRemoteCloudAPIClient(tokenStore: store, dataLoader: { request in
            try stub.data(for: request)
        })

        #expect(try await client.createTeam(endpoint: endpoint, name: " Platform ").name == "Platform")
        #expect(try await client.teamMembers(endpoint: endpoint, teamID: teamID).first?.role == .owner)
        let memberPage = try await client.teamMembersPage(
            endpoint: endpoint,
            teamID: teamID,
            search: "owner",
            role: .owner
        )
        #expect(memberPage.members.first?.role == .owner)
        #expect(memberPage.total == 1)
        #expect(memberPage.nextCursor == nil)
        let legacyPage = try await client.teamMembersPage(
            endpoint: endpoint,
            teamID: teamID,
            search: "legacy"
        )
        #expect(legacyPage.members.isEmpty)
        #expect(legacyPage.total == 0)
        #expect(try await client.inviteTeamMember(
            endpoint: endpoint, teamID: teamID, username: " @Viewer ", role: .viewer
        ).targetUsername == "viewer")
        #expect(try await client.teamInvitations(endpoint: endpoint, teamID: teamID).count == 1)
        #expect(try await client.pendingTeamInvitations(endpoint: endpoint).first?.teamName == "Platform")
        let link = try await client.createTeamInvitationLink(endpoint: endpoint, teamID: teamID, role: .viewer)
        #expect(link.id == linkInvitationID)
        #expect(link.acceptanceURL?.hasSuffix(String(repeating: "x", count: 43)) == true)
        #expect(try await client.acceptTeamInvitation(
            endpoint: endpoint, invitationID: invitationID
        ).username == "viewer")
        try await client.cancelTeamInvitation(
            endpoint: endpoint, teamID: teamID, invitationID: linkInvitationID
        )
        #expect(try await client.createSharedVault(
            endpoint: endpoint, teamID: teamID, name: " Production "
        ).id == vaultID)
    }

    @Test("registration sends the device public identity and requires exact verification response")
    func registrationFoundation() async throws {
        let endpoint = try SelectiveRemoteCloudEndpoint.normalized("https://cloud.example.invalid")
        let deviceID = try #require(UUID(uuidString: "44444444-4444-4444-8444-444444444444"))
        let store = SelectiveRemoteCloudMemoryTokenStore()
        let stub = CloudHTTPStub { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/v1/auth/register")
            let body = try #require(request.httpBody)
            let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(Set(object.keys) == ["email", "password", "username", "displayName", "device"])
            #expect(object["email"] as? String == "user@example.invalid")
            #expect(object["password"] as? String == "synthetic-password")
            #expect(object["displayName"] as? String == "User")
            #expect(object["username"] as? String == "leonid")
            let device = try #require(object["device"] as? [String: Any])
            #expect(device["id"] as? String == deviceID.canonicalCloudString)
            #expect(device["name"] as? String == "Synthetic Mac")
            #expect(device["platform"] as? String == "macos")
            return Self.response(request, status: 201, json: ["verificationRequired": true])
        }
        let client = SelectiveRemoteCloudAPIClient(
            tokenStore: store,
            dataLoader: { request in try stub.data(for: request) }
        )

        try await client.register(
            endpoint: endpoint,
            displayName: " User ",
            username: " Leonid ",
            email: " user@example.invalid ",
            password: "synthetic-password",
            device: .thisMac(id: deviceID, name: "Synthetic Mac")
        )
        #expect(store.token(for: endpoint) == nil)
    }

    @Test("registration rejects an extended or false verification response")
    func registrationRejectsInvalidResponses() async throws {
        let endpoint = try SelectiveRemoteCloudEndpoint.normalized("https://cloud.example.invalid")
        let deviceID = try #require(UUID(uuidString: "44444444-4444-4444-8444-444444444444"))
        let invalidResponses: [[String: Any]] = [
            ["verificationRequired": false],
            ["verificationRequired": true, "unexpected": true]
        ]
        for json in invalidResponses {
            let payload = try JSONSerialization.data(withJSONObject: json)
            let client = SelectiveRemoteCloudAPIClient(
                tokenStore: SelectiveRemoteCloudMemoryTokenStore(),
                dataLoader: { request in
                    let url = try #require(request.url)
                    let response = try #require(HTTPURLResponse(
                        url: url,
                        statusCode: 201,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    ))
                    return (payload, response)
                }
            )
            await #expect(throws: SelectiveRemoteCloudError.invalidResponse) {
                try await client.register(
                    endpoint: endpoint,
                    displayName: "User",
                    username: "user",
                    email: "user@example.invalid",
                    password: "synthetic-password",
                    device: .thisMac(id: deviceID, name: "Synthetic Mac")
                )
            }
        }
    }

    @Test("macOS account inventory rejects extended user and Team responses")
    func accountInventoryRejectsExtendedResponses() async throws {
        let endpoint = try SelectiveRemoteCloudEndpoint.normalized("https://cloud.example.invalid")
        let token = String(repeating: "t", count: 43)
        let userID = try #require(UUID(uuidString: "66666666-6666-4666-8666-666666666666"))
        let membershipID = try #require(UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
        let teamID = try #require(UUID(uuidString: "11111111-1111-4111-8111-111111111111"))
        let store = SelectiveRemoteCloudMemoryTokenStore()
        store.saveToken(token, for: endpoint)
        let client = SelectiveRemoteCloudAPIClient(
            tokenStore: store,
            dataLoader: { request in
                switch request.url?.path {
                case "/v1/me":
                    Self.response(request, status: 200, json: [
                        "id": userID.canonicalCloudString,
                        "email": "user@example.invalid",
                        "displayName": "User",
                        "unexpected": true
                    ])
                case "/v1/teams":
                    Self.response(request, status: 200, json: ["teams": [[
                        "id": teamID.canonicalCloudString,
                        "name": "Platform",
                        "membershipID": membershipID.canonicalCloudString,
                        "role": "owner",
                        "membershipEpoch": 3,
                        "createdAt": "2026-09-07T00:00:00.000Z",
                        "updatedAt": "2026-09-07T00:00:00.000Z",
                        "unexpected": true
                    ]]])
                default:
                    Self.response(request, status: 500, json: ["error": "unexpected_request"])
                }
            }
        )

        await #expect(throws: SelectiveRemoteCloudError.invalidResponse) {
            try await client.currentUser(endpoint: endpoint)
        }
        await #expect(throws: SelectiveRemoteCloudError.invalidResponse) {
            try await client.teams(endpoint: endpoint)
        }
    }

    @Test("a 401 response deletes the stored macOS Cloud session")
    func unauthorizedClearsSession() async throws {
        let endpoint = try SelectiveRemoteCloudEndpoint.normalized("https://unauthorized-foundation.example.invalid")
        let store = SelectiveRemoteCloudMemoryTokenStore()
        store.saveToken(String(repeating: "t", count: 43), for: endpoint)
        let client = SelectiveRemoteCloudAPIClient(
            tokenStore: store,
            dataLoader: { request in Self.response(request, status: 401, json: ["error": "unauthorized"]) }
        )
        await #expect(throws: SelectiveRemoteCloudError.authenticationRequired) {
            try await client.currentUser(endpoint: endpoint)
        }
        #expect(store.token(for: endpoint) == nil)
    }

    @Test("browser and macOS use the same P-256 fingerprint and Team envelope context")
    func sharedCryptoFixture() throws {
        let url = try #require(Bundle.module.url(
            forResource: "team-vault-v1",
            withExtension: "json",
            subdirectory: "Fixtures"
        ))
        let fixture = try JSONDecoder().decode(TeamVaultFixture.self, from: Data(contentsOf: url))
        #expect(fixture.version == 1)
        #expect(SelectiveRemoteTeamVaultCrypto.deviceFingerprint(fixture.publicKey) == fixture.fingerprint)

        let wrapper = try SelectiveRemoteTeamWrapperContext(
            teamID: try fixture.wrapper.teamID.uuid,
            vaultID: try fixture.wrapper.vaultID.uuid,
            keyGeneration: fixture.wrapper.keyGeneration,
            membershipID: try fixture.wrapper.membershipID.uuid,
            membershipEpoch: fixture.wrapper.membershipEpoch,
            deviceID: try fixture.wrapper.deviceID.uuid
        )
        #expect(SelectiveRemoteTeamVaultCrypto.wrapperContext(wrapper).base64URL == fixture.wrapper.contextBase64URL)
        #expect(SelectiveRemoteTeamVaultCrypto.wrapperContextHash(wrapper) == fixture.wrapper.contextHash)
        #expect(try SelectiveRemoteTeamVaultCrypto.payloadContext(
            teamID: fixture.payload.teamID.uuid,
            vaultID: fixture.payload.vaultID.uuid,
            keyGeneration: fixture.payload.keyGeneration
        ).base64URL == fixture.payload.contextBase64URL)
        #expect(try SelectiveRemoteTeamVaultCrypto.payloadContentHash(
            teamID: fixture.payload.teamID.uuid,
            vaultID: fixture.payload.vaultID.uuid,
            keyGeneration: fixture.payload.keyGeneration,
            nonce: fixture.payload.nonce,
            ciphertext: fixture.payload.ciphertext,
            authTag: fixture.payload.authTag
        ) == fixture.payload.contentHash)
    }

    @Test("macOS rejects a private or extended Team JWK before cryptographic use")
    func rejectsExtendedJWK() {
        let data = Data(#"{"kty":"EC","crv":"P-256","x":"axfR8uEsQkf4vOblY6RA8ncDfYEt6zOg9KE5RdiYwpY","y":"T-NC4v4af5uO5-tKfA-eFivOM1drMV7Oy7ZAaDe_UfU","ext":true,"key_ops":[],"d":"secret"}"#.utf8)
        #expect(throws: SelectiveRemoteTeamCryptoError.invalidPublicKey) {
            try JSONDecoder().decode(SelectiveRemoteTeamDevicePublicKey.self, from: data)
        }
    }

    @Test("device identity converges on one device-only stored P-256 key")
    func persistentDeviceIdentity() async throws {
        let endpoint = try SelectiveRemoteCloudEndpoint.normalized("https://cloud.example.invalid")
        let deviceID = try #require(UUID(uuidString: "44444444-4444-4444-8444-444444444444"))
        let store = SelectiveRemoteTeamDeviceMemoryKeyStore()
        let first = try await SelectiveRemoteTeamDeviceIdentityManager(store: store)
            .identity(endpoint: endpoint, deviceID: deviceID)
        let second = try await SelectiveRemoteTeamDeviceIdentityManager(store: store)
            .identity(endpoint: endpoint, deviceID: deviceID)
        #expect(first.deviceID == deviceID)
        #expect(first.publicKey == second.publicKey)
        #expect(first.privateKey.rawRepresentation == second.privateKey.rawRepresentation)
    }

    @Test("macOS deterministic wrapper decrypts in the browser fixture format")
    func sharedKeyWrapFixture() throws {
        let fixture = try Self.fixture()
        let deviceID = try fixture.wrapper.deviceID.uuid
        let identity = try SelectiveRemoteTeamDeviceIdentity(
            deviceID: deviceID,
            privateKeyRepresentation: try fixture.keyWrap.recipientPrivateScalar.base64URLData
        )
        #expect(identity.publicKey == fixture.publicKey)
        let context = try SelectiveRemoteTeamWrapperContext(
            teamID: try fixture.wrapper.teamID.uuid,
            vaultID: try fixture.wrapper.vaultID.uuid,
            keyGeneration: fixture.wrapper.keyGeneration,
            membershipID: try fixture.wrapper.membershipID.uuid,
            membershipEpoch: fixture.wrapper.membershipEpoch,
            deviceID: deviceID
        )
        let wrapper = try SelectiveRemoteTeamVaultCrypto.wrapVaultKey(
            try fixture.keyWrap.vaultKey.base64URLData,
            for: fixture.publicKey,
            context: context,
            ephemeralPrivateKeyRepresentation: try fixture.keyWrap.ephemeralPrivateScalar.base64URLData,
            nonce: try fixture.keyWrap.nonce.base64URLData
        )
        #expect(wrapper.ephemeralPublicKey == fixture.keyWrap.ephemeralPublicKey)
        #expect(wrapper.ciphertext == fixture.keyWrap.ciphertext)
        #expect(wrapper.authTag == fixture.keyWrap.authTag)
        #expect(wrapper.contextHash == fixture.wrapper.contextHash)
        let expectedVaultKey = try fixture.keyWrap.vaultKey.base64URLData
        #expect(try SelectiveRemoteTeamVaultCrypto.unwrapVaultKey(
            wrapper,
            with: identity,
            teamID: context.teamID,
            vaultID: context.vaultID,
            keyGeneration: context.keyGeneration
        ) == expectedVaultKey)

        let otherVaultID = try #require(UUID(uuidString: "33333333-3333-4333-8333-333333333333"))
        #expect(throws: SelectiveRemoteTeamCryptoError.wrapperContextMismatch) {
            try SelectiveRemoteTeamVaultCrypto.unwrapVaultKey(
                wrapper,
                with: identity,
                teamID: context.teamID,
                vaultID: otherVaultID,
                keyGeneration: context.keyGeneration
            )
        }
    }

    @Test("macOS deterministic payload decrypts in the browser fixture format")
    func sharedPayloadFixture() throws {
        let fixture = try Self.fixture()
        let payload = try fixture.payload.plaintext.base64URLData
        let vaultKey = try fixture.keyWrap.vaultKey.base64URLData
        let teamID = try fixture.payload.teamID.uuid
        let vaultID = try fixture.payload.vaultID.uuid
        let envelope = try SelectiveRemoteTeamVaultCrypto.encryptPayload(
            payload,
            vaultKey: vaultKey,
            teamID: teamID,
            vaultID: vaultID,
            keyGeneration: fixture.payload.keyGeneration,
            baseRevision: fixture.payload.baseRevision,
            nonce: try fixture.payload.nonce.base64URLData
        )
        #expect(envelope.ciphertext == fixture.payload.ciphertext)
        #expect(envelope.authTag == fixture.payload.authTag)
        #expect(envelope.contentHash == fixture.payload.contentHash)
        #expect(try SelectiveRemoteTeamVaultCrypto.decryptPayload(
            envelope,
            vaultKey: vaultKey,
            teamID: teamID,
            vaultID: vaultID
        ) == payload)

        let otherTeamID = try #require(UUID(uuidString: "99999999-9999-4999-8999-999999999999"))
        #expect(throws: SelectiveRemoteTeamCryptoError.payloadContentHashMismatch) {
            try SelectiveRemoteTeamVaultCrypto.decryptPayload(
                envelope,
                vaultKey: vaultKey,
                teamID: otherTeamID,
                vaultID: vaultID
            )
        }
    }

    @Test("typed macOS Team Vault transport preserves conditional conflict state")
    func teamVaultTransport() async throws {
        let endpoint = try SelectiveRemoteCloudEndpoint.normalized("https://cloud.example.invalid")
        let teamID = try #require(UUID(uuidString: "11111111-1111-4111-8111-111111111111"))
        let vaultID = try #require(UUID(uuidString: "22222222-2222-4222-8222-222222222222"))
        let deviceID = try #require(UUID(uuidString: "44444444-4444-4444-8444-444444444444"))
        let membershipID = try #require(UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
        let fixture = try Self.fixture()
        let identity = try SelectiveRemoteTeamDeviceIdentity(
            deviceID: deviceID,
            privateKeyRepresentation: try fixture.keyWrap.recipientPrivateScalar.base64URLData
        )
        let wrapper = try Self.fixtureWrapper(fixture, identity: identity)
        let token = String(repeating: "t", count: 43)
        let store = SelectiveRemoteCloudMemoryTokenStore()
        store.saveToken(token, for: endpoint)
        let stub = CloudHTTPStub { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/v1/teams/\(teamID.canonicalCloudString)/vaults"):
                return Self.response(request, status: 200, json: ["vaults": [[
                    "id": vaultID.canonicalCloudString,
                    "teamID": teamID.canonicalCloudString,
                    "name": "Operations",
                    "revision": 5,
                    "keyGeneration": 7,
                    "rotationRequired": false,
                    "createdAt": "2026-09-06T00:00:00.000Z",
                    "updatedAt": "2026-09-06T00:00:00.000Z"
                ]]])
            case ("GET", "/v1/teams/\(teamID.canonicalCloudString)/vaults/\(vaultID.canonicalCloudString)/key-devices"):
                return Self.response(request, status: 200, json: ["devices": [[
                    "membershipID": membershipID.canonicalCloudString,
                    "membershipEpoch": 3,
                    "deviceID": deviceID.canonicalCloudString,
                    "publicKeyAlgorithm": "p256-ecdh-v1",
                    "publicKey": [
                        "kty": fixture.publicKey.kty, "crv": fixture.publicKey.crv,
                        "x": fixture.publicKey.x, "y": fixture.publicKey.y,
                        "ext": fixture.publicKey.ext, "key_ops": fixture.publicKey.keyOps
                    ],
                    "hasWrapper": true
                ]]])
            case ("GET", "/v1/teams/\(teamID.canonicalCloudString)/vaults/\(vaultID.canonicalCloudString)"):
                return Self.response(request, status: 200, json: [
                    "id": vaultID.canonicalCloudString,
                    "teamID": teamID.canonicalCloudString,
                    "name": "Operations",
                    "revision": 5,
                    "keyGeneration": 7,
                    "rotationRequired": false,
                    "envelopeVersion": fixture.payload.envelopeVersion,
                    "ciphertext": fixture.payload.ciphertext,
                    "nonce": fixture.payload.nonce,
                    "authTag": fixture.payload.authTag,
                    "contentHash": fixture.payload.contentHash,
                    "wrapper": NSNull(),
                    "createdAt": "2026-09-06T00:00:00.000Z",
                    "updatedAt": "2026-09-06T00:00:00.000Z"
                ])
            case ("POST", "/v1/teams/\(teamID.canonicalCloudString)/vaults/\(vaultID.canonicalCloudString)/wrappers"):
                #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "macos:team:vault:grant-1")
                let body = try #require(request.httpBody)
                let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                #expect(Set(object.keys) == ["keyGeneration", "wrapper"])
                #expect(object["keyGeneration"] as? Int == 7)
                let encodedWrapper = try #require(object["wrapper"] as? [String: Any])
                #expect(encodedWrapper["deviceID"] as? String == deviceID.canonicalCloudString)
                return Self.response(request, status: 201, json: [
                    "granted": true,
                    "keyGeneration": 7,
                    "deviceID": deviceID.canonicalCloudString
                ])
            case ("PUT", "/v1/teams/\(teamID.canonicalCloudString)/vaults/\(vaultID.canonicalCloudString)"):
                #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "macos:team:vault:synthetic-1")
                #expect(request.httpBody.map { String(decoding: $0, as: UTF8.self) }?.contains("schemaVersion") == false)
                return Self.response(request, status: 409, json: [
                    "conflict": true, "revision": 6, "keyGeneration": 7
                ])
            default:
                Issue.record("Unexpected request: \(request.httpMethod ?? "nil") \(request.url?.path ?? "nil")")
                return Self.response(request, status: 500, json: ["error": "unexpected_request"])
            }
        }
        let client = SelectiveRemoteCloudAPIClient(
            tokenStore: store,
            dataLoader: { request in try stub.data(for: request) }
        )
        #expect(try await client.sharedVaults(endpoint: endpoint, teamID: teamID).map(\.id) == [vaultID])
        #expect(try await client.teamKeyDevices(
            endpoint: endpoint,
            teamID: teamID,
            vaultID: vaultID
        ).map(\.deviceID) == [deviceID])
        let grant = try await client.grantSharedVaultWrapper(
            endpoint: endpoint,
            teamID: teamID,
            vaultID: vaultID,
            keyGeneration: 7,
            wrapper: wrapper,
            idempotencyKey: "macos:team:vault:grant-1"
        )
        #expect(grant == .init(granted: true, keyGeneration: 7, deviceID: deviceID))
        let remote = try await client.sharedVault(endpoint: endpoint, teamID: teamID, vaultID: vaultID)
        let downloadedEnvelope = try remote.payloadEnvelope
        let envelope = try #require(downloadedEnvelope)
        #expect(envelope.contentHash == fixture.payload.contentHash)
        let result = try await client.putSharedVault(
            endpoint: endpoint,
            teamID: teamID,
            vaultID: vaultID,
            upload: .init(envelope: envelope, wrappers: nil),
            idempotencyKey: "macos:team:vault:synthetic-1"
        )
        #expect(result == .init(conflict: true, revision: 6, keyGeneration: 7, rotationCompleted: nil))
    }

    @Test("current macOS key holder provisions another admitted device")
    func teamVaultWrapperProvisioning() async throws {
        let fixture = try Self.fixture()
        let endpoint = try SelectiveRemoteCloudEndpoint.normalized("https://cloud.example.invalid")
        let teamID = try fixture.wrapper.teamID.uuid
        let vaultID = try fixture.wrapper.vaultID.uuid
        let deviceID = try fixture.wrapper.deviceID.uuid
        let membershipID = try fixture.wrapper.membershipID.uuid
        let recipientID = try #require(UUID(uuidString: "55555555-5555-4555-8555-555555555555"))
        let recipientMembershipID = try #require(
            UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
        )
        let identity = try SelectiveRemoteTeamDeviceIdentity(
            deviceID: deviceID,
            privateKeyRepresentation: try fixture.keyWrap.recipientPrivateScalar.base64URLData
        )
        let recipient = try SelectiveRemoteTeamDeviceIdentity(
            deviceID: recipientID,
            privateKeyRepresentation: Data(repeating: 0x03, count: 32)
        )
        let actorWrapper = try Self.fixtureWrapper(fixture, identity: identity)
        let keyDevices: [SelectiveRemoteCloudTeamKeyDevice] = [
            .init(
                membershipID: membershipID,
                membershipEpoch: fixture.wrapper.membershipEpoch,
                deviceID: deviceID,
                publicKeyAlgorithm: "p256-ecdh-v1",
                publicKey: identity.publicKey,
                hasWrapper: true
            ),
            .init(
                membershipID: recipientMembershipID,
                membershipEpoch: 1,
                deviceID: recipientID,
                publicKeyAlgorithm: "p256-ecdh-v1",
                publicKey: recipient.publicKey,
                hasWrapper: false
            )
        ]
        let remote = TeamVaultRemoteStub(
            envelope: Self.remoteEnvelope(fixture, wrapper: actorWrapper),
            writeResult: .init(
                conflict: false,
                revision: 6,
                keyGeneration: fixture.wrapper.keyGeneration,
                rotationCompleted: false
            ),
            keyDevices: keyDevices
        )
        let coordinator = try SelectiveRemoteTeamVaultSyncCoordinator(
            endpoint: endpoint,
            remote: remote,
            snapshots: SelectiveRemoteTeamVaultMemorySnapshotStore()
        )

        #expect(try await coordinator.provisionMissingWrappers(
            teamID: teamID,
            vaultID: vaultID,
            identity: identity
        ) == 1)
        let grants = await remote.recordedGrants()
        let grantedWrapper = try #require(grants.first?.wrapper)
        #expect(grants.count == 1)
        #expect(grants.first?.keyGeneration == fixture.wrapper.keyGeneration)
        #expect(grants.first?.idempotencyKey.hasPrefix("macos:team-vault:grant:") == true)
        #expect(try SelectiveRemoteTeamVaultCrypto.unwrapVaultKey(
            grantedWrapper,
            with: recipient,
            teamID: teamID,
            vaultID: vaultID,
            keyGeneration: fixture.wrapper.keyGeneration
        ) == fixture.keyWrap.vaultKey.base64URLData)
    }

    @Test("macOS background cycle provisions wrappers and refreshes ciphertext")
    func teamVaultBackgroundSync() async throws {
        let fixture = try Self.fixture()
        let endpoint = try SelectiveRemoteCloudEndpoint.normalized("https://cloud.example.invalid")
        let teamID = try fixture.wrapper.teamID.uuid
        let vaultID = try fixture.wrapper.vaultID.uuid
        let deviceID = try fixture.wrapper.deviceID.uuid
        let membershipID = try fixture.wrapper.membershipID.uuid
        let recipientID = try #require(UUID(uuidString: "55555555-5555-4555-8555-555555555555"))
        let recipientMembershipID = try #require(
            UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
        )
        let identity = try SelectiveRemoteTeamDeviceIdentity(
            deviceID: deviceID,
            privateKeyRepresentation: try fixture.keyWrap.recipientPrivateScalar.base64URLData
        )
        let recipient = try SelectiveRemoteTeamDeviceIdentity(
            deviceID: recipientID,
            privateKeyRepresentation: Data(repeating: 0x03, count: 32)
        )
        let team = SelectiveRemoteCloudTeam(
            id: teamID,
            name: "Platform",
            membershipID: membershipID,
            role: .viewer,
            membershipEpoch: fixture.wrapper.membershipEpoch,
            createdAt: "2026-09-09T00:00:00.000Z",
            updatedAt: "2026-09-09T00:00:00.000Z"
        )
        let vault = SelectiveRemoteCloudSharedVault(
            id: vaultID,
            teamID: teamID,
            name: "Operations",
            revision: fixture.payload.baseRevision + 1,
            keyGeneration: fixture.wrapper.keyGeneration,
            rotationRequired: false,
            createdAt: "2026-09-09T00:00:00.000Z",
            updatedAt: "2026-09-09T00:00:00.000Z"
        )
        let remote = TeamVaultRemoteStub(
            envelope: Self.remoteEnvelope(
                fixture,
                wrapper: try Self.fixtureWrapper(fixture, identity: identity)
            ),
            writeResult: .init(
                conflict: false,
                revision: 6,
                keyGeneration: fixture.wrapper.keyGeneration,
                rotationCompleted: false
            ),
            teams: [team],
            vaults: [vault],
            keyDevices: [
                .init(
                    membershipID: membershipID,
                    membershipEpoch: fixture.wrapper.membershipEpoch,
                    deviceID: deviceID,
                    publicKeyAlgorithm: "p256-ecdh-v1",
                    publicKey: identity.publicKey,
                    hasWrapper: true
                ),
                .init(
                    membershipID: recipientMembershipID,
                    membershipEpoch: 1,
                    deviceID: recipientID,
                    publicKeyAlgorithm: "p256-ecdh-v1",
                    publicKey: recipient.publicKey,
                    hasWrapper: false
                )
            ]
        )
        let keyStore = SelectiveRemoteTeamDeviceMemoryKeyStore()
        _ = try keyStore.savePrivateKeyIfAbsent(
            try fixture.keyWrap.recipientPrivateScalar.base64URLData,
            for: endpoint,
            deviceID: deviceID
        )
        let snapshots = SelectiveRemoteTeamVaultMemorySnapshotStore()
        let materialized = TeamVaultMaterializedSnapshotSink()
        let autoSync = SelectiveRemoteTeamVaultAutoSync(
            remote: remote,
            identityManager: SelectiveRemoteTeamDeviceIdentityManager(store: keyStore),
            snapshotStore: { snapshots },
            snapshotConsumer: { await materialized.replace(with: $0) }
        )

        let report = try await autoSync.synchronizeOnce(
            endpoint: endpoint,
            deviceID: deviceID
        )
        #expect(report.scannedVaults == 1)
        #expect(report.synchronizedVaults == 1)
        #expect(report.wrappersGranted == 1)
        #expect(report.pendingWrappers == 0)
        #expect(report.failures == 0)
        #expect(try snapshots.load(endpoint: endpoint, teamID: teamID, vaultID: vaultID) != nil)
        let published = await materialized.snapshots()
        #expect(published.count == 1)
        #expect(published.first?.teamID == teamID)
        #expect(published.first?.vaultID == vaultID)
        #expect(published.first?.role == .viewer)
        let expectedPayload = try fixture.payload.plaintext.base64URLData
        #expect(published.first?.payload == expectedPayload)
    }

    @Test("Team Vault coordinator stages and acknowledges one causal upload")
    func teamVaultSyncUpload() async throws {
        let fixture = try Self.fixture()
        let endpoint = try SelectiveRemoteCloudEndpoint.normalized("https://cloud.example.invalid")
        let teamID = try fixture.wrapper.teamID.uuid
        let vaultID = try fixture.wrapper.vaultID.uuid
        let deviceID = try fixture.wrapper.deviceID.uuid
        let identity = try SelectiveRemoteTeamDeviceIdentity(
            deviceID: deviceID,
            privateKeyRepresentation: try fixture.keyWrap.recipientPrivateScalar.base64URLData
        )
        let wrapper = try Self.fixtureWrapper(fixture, identity: identity)
        let remote = TeamVaultRemoteStub(
            envelope: Self.remoteEnvelope(fixture, wrapper: wrapper),
            writeResult: .init(conflict: false, revision: 6, keyGeneration: 7, rotationCompleted: false)
        )
        let storage = SelectiveRemoteTeamVaultMemorySnapshotStore()
        let coordinator = try SelectiveRemoteTeamVaultSyncCoordinator(
            endpoint: endpoint,
            remote: remote,
            snapshots: storage
        )

        let refreshed = try await coordinator.refresh(
            teamID: teamID,
            vaultID: vaultID,
            identity: identity
        )
        guard case let .synchronized(initial) = refreshed else {
            Issue.record("Expected the first remote revision to be synchronized")
            return
        }
        let initialPayload = try fixture.payload.plaintext.base64URLData
        #expect(initial.payload == initialPayload)
        #expect(initial.snapshot.serverRevision == 5)
        #expect(initial.snapshot.localRevision == initial.snapshot.syncedLocalRevision)

        let editedPayload = Data("synthetic local edit".utf8)
        let staged = try await coordinator.stage(
            editedPayload,
            expected: initial.snapshot,
            teamID: teamID,
            vaultID: vaultID,
            identity: identity
        )
        #expect(staged.snapshot.envelope.baseRevision == 5)
        #expect(staged.snapshot.localRevision == 2)
        #expect(staged.snapshot.syncedLocalRevision == 1)

        let pushed = try await coordinator.push(
            teamID: teamID,
            vaultID: vaultID,
            identity: identity
        )
        guard case let .uploaded(uploaded) = pushed else {
            Issue.record("Expected the staged payload to upload")
            return
        }
        #expect(uploaded.payload == editedPayload)
        #expect(uploaded.snapshot.serverRevision == 6)
        #expect(uploaded.snapshot.localRevision == uploaded.snapshot.syncedLocalRevision)
        let writes = await remote.recordedWrites()
        #expect(writes.count == 1)
        #expect(writes.first?.upload.envelope == staged.snapshot.envelope)
        #expect(writes.first?.idempotencyKey.contains(staged.snapshot.envelope.contentHash) == true)
    }

    @Test("Concurrent Team snapshot writers preserve one complete version", .timeLimit(.minutes(1)))
    func teamSnapshotCompareAndSwapPreservesNewerVersion() async throws {
        let fixture = try Self.fixture()
        let endpoint = URL(string: "https://cas-\(UUID()).example.invalid")!
        let teamID = try fixture.wrapper.teamID.uuid, vaultID = try fixture.wrapper.vaultID.uuid
        let deviceID = try fixture.wrapper.deviceID.uuid
        let identity = try SelectiveRemoteTeamDeviceIdentity(deviceID: deviceID,
            privateKeyRepresentation: try fixture.keyWrap.recipientPrivateScalar.base64URLData)
        let wrapper = try Self.fixtureWrapper(fixture, identity: identity)
        let remote = TeamVaultRemoteStub(envelope: Self.remoteEnvelope(fixture, wrapper: wrapper),
            writeResult: .init(conflict: false, revision: 6, keyGeneration: 7, rotationCompleted: false))
        let firstMemory = SelectiveRemoteTeamVaultMemorySnapshotStore()
        let firstCoordinator = try SelectiveRemoteTeamVaultSyncCoordinator(endpoint: endpoint, remote: remote, snapshots: firstMemory)
        guard case let .synchronized(initial) = try await firstCoordinator.refresh(teamID: teamID, vaultID: vaultID, identity: identity)
        else { Issue.record("Expected an initial synthetic snapshot"); return }
        let editedA = try await firstCoordinator.stage(Data("edit A".utf8), expected: initial.snapshot, teamID: teamID, vaultID: vaultID, identity: identity)
        let secondMemory = SelectiveRemoteTeamVaultMemorySnapshotStore()
        try secondMemory.save(initial.snapshot, endpoint: endpoint)
        let secondCoordinator = try SelectiveRemoteTeamVaultSyncCoordinator(endpoint: endpoint, remote: remote, snapshots: secondMemory)
        let editedB = try await secondCoordinator.stage(Data("edit B".utf8), expected: initial.snapshot, teamID: teamID, vaultID: vaultID, identity: identity)
        let sharedMemory = SelectiveRemoteTeamVaultMemorySnapshotStore()
        try sharedMemory.save(initial.snapshot, endpoint: endpoint)
        let sharedCoordinator = try SelectiveRemoteTeamVaultSyncCoordinator(endpoint: endpoint, remote: remote, snapshots: sharedMemory)
        let concurrent = try await sharedCoordinator.stage(Data("concurrent edit".utf8), expected: initial.snapshot, teamID: teamID, vaultID: vaultID, identity: identity)
        // This payload was built from initial, before the concurrent edit.
        await #expect(throws: SelectiveRemoteTeamVaultSnapshotError.concurrentChange) {
            try await sharedCoordinator.stage(Data("stale edit".utf8), expected: initial.snapshot, teamID: teamID, vaultID: vaultID, identity: identity)
        }
        #expect(try sharedMemory.load(endpoint: endpoint, teamID: teamID, vaultID: vaultID) == concurrent.snapshot)
        let directory = FileManager.default.temporaryDirectory.appending(path: "sr-team-cas-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeA = try SelectiveRemoteTeamVaultFileSnapshotStore(root: directory)
        let storeB = try SelectiveRemoteTeamVaultFileSnapshotStore(root: directory)
        try storeA.save(initial.snapshot, endpoint: endpoint)
        let successes = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            group.addTask { (try? storeA.saveIfCurrent(editedA.snapshot, endpoint: endpoint, replacing: initial.snapshot)) != nil }
            group.addTask { (try? storeB.saveIfCurrent(editedB.snapshot, endpoint: endpoint, replacing: initial.snapshot)) != nil }
            var values: [Bool] = []
            for await value in group { values.append(value) }
            return values
        }
        #expect(successes.filter { $0 }.count == 1)
        let stored = try #require(try storeA.load(endpoint: endpoint, teamID: teamID, vaultID: vaultID))
        #expect(stored == editedA.snapshot || stored == editedB.snapshot)
        let endpointID = SHA256.hash(data: Data(endpoint.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let lockPath = directory.appending(path: endpointID).appending(path: "\(teamID.canonicalCloudString)-\(vaultID.canonicalCloudString).v2.json.lock").path
        let descriptor = Darwin.open(lockPath, O_RDWR | O_CLOEXEC)
        guard descriptor >= 0 else { Issue.record("Expected a temporary lockfile"); return }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { Issue.record("Could not lock temporary file"); return }
        defer { flock(descriptor, LOCK_UN) }
        #expect(throws: SelectiveRemoteTeamVaultSnapshotError.concurrentChange) {
            try storeB.saveIfCurrent(initial.snapshot, endpoint: endpoint, replacing: stored)
        }

        // A 0.31 process does not use the new lock. Its retained file must not
        // be overwritten, and a later differing legacy edit must stop sync.
        let oldRoot = directory.appending(path: "legacy-case", directoryHint: .isDirectory)
        let oldDir = oldRoot.appending(path: endpointID, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        let legacyURL = oldDir.appending(path: "\(teamID.canonicalCloudString)-\(vaultID.canonicalCloudString).json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let legacyBytes = try encoder.encode(initial.snapshot)
        try legacyBytes.write(to: legacyURL, options: .atomic)
        let migrated = try SelectiveRemoteTeamVaultFileSnapshotStore(root: oldRoot)
        #expect(try migrated.load(endpoint: endpoint, teamID: teamID, vaultID: vaultID) == initial.snapshot)
        try migrated.saveIfCurrent(editedA.snapshot, endpoint: endpoint, replacing: initial.snapshot)
        #expect(try Data(contentsOf: legacyURL) == legacyBytes)
        try encoder.encode(editedB.snapshot).write(to: legacyURL, options: .atomic)
        #expect(throws: SelectiveRemoteTeamVaultSnapshotError.concurrentChange) {
            try migrated.load(endpoint: endpoint, teamID: teamID, vaultID: vaultID)
        }

        // If the old process writes during the new commit, neither version
        // may overwrite the other and the result must be reported as uncertain.
        let raceRoot = directory.appending(path: "legacy-race", directoryHint: .isDirectory)
        let raceDir = raceRoot.appending(path: endpointID, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: raceDir, withIntermediateDirectories: true)
        let raceLegacy = raceDir.appending(path: "\(teamID.canonicalCloudString)-\(vaultID.canonicalCloudString).json")
        try legacyBytes.write(to: raceLegacy, options: .atomic)
        let changedLegacy = try encoder.encode(editedB.snapshot)
        let racedStore = try SelectiveRemoteTeamVaultFileSnapshotStore(root: raceRoot, beforeCommit: {
            try changedLegacy.write(to: raceLegacy, options: .atomic)
        })
        #expect(throws: SelectiveRemoteTeamVaultSnapshotError.concurrentChange) {
            try racedStore.saveIfCurrent(editedA.snapshot, endpoint: endpoint, replacing: initial.snapshot)
        }
        #expect(try Data(contentsOf: raceLegacy) == changedLegacy)
        let raceVersioned = raceLegacy.deletingPathExtension().appendingPathExtension("v2.json")
        #expect(FileManager.default.fileExists(atPath: raceVersioned.path))
        #expect(throws: SelectiveRemoteTeamVaultSnapshotError.concurrentChange) {
            try racedStore.load(endpoint: endpoint, teamID: teamID, vaultID: vaultID)
        }

        // A failed remove must retain the previously dirty new-version copy,
        // not just the replacement tombstone and the racing legacy copy.
        let priorRoot = directory.appending(path: "legacy-prior-dirty", directoryHint: .isDirectory)
        let priorDir = priorRoot.appending(path: endpointID, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: priorDir, withIntermediateDirectories: true)
        let priorLegacy = priorDir.appending(path: "\(teamID.canonicalCloudString)-\(vaultID.canonicalCloudString).json")
        try legacyBytes.write(to: priorLegacy, options: .atomic)
        let priorStore = try SelectiveRemoteTeamVaultFileSnapshotStore(root: priorRoot)
        try priorStore.saveIfCurrent(editedA.snapshot, endpoint: endpoint, replacing: initial.snapshot)
        let priorVersioned = priorLegacy.deletingPathExtension().appendingPathExtension("v2.json")
        let dirtyBytes = try Data(contentsOf: priorVersioned)
        let racingRemove = try SelectiveRemoteTeamVaultFileSnapshotStore(root: priorRoot, beforeCommit: {
            try changedLegacy.write(to: priorLegacy, options: .atomic)
        })
        #expect(throws: SelectiveRemoteTeamVaultSnapshotError.concurrentChange) {
            try racingRemove.remove(endpoint: endpoint, teamID: teamID, vaultID: vaultID)
        }
        let recoveryCopy = priorVersioned.appendingPathExtension("previous")
        let keptPrior = FileManager.default.fileExists(atPath: recoveryCopy.path)
        #expect(keptPrior)
        if keptPrior { #expect(try Data(contentsOf: recoveryCopy) == dirtyBytes) }
        #expect(try Data(contentsOf: priorLegacy) == changedLegacy)

        // A temporary read failure during post-check must leave an explicit
        // pending marker; restoring the old bytes must not silently erase X.
        let uncertainRoot = directory.appending(path: "uncertain-commit", directoryHint: .isDirectory)
        let uncertainDir = uncertainRoot.appending(path: endpointID, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: uncertainDir, withIntermediateDirectories: true)
        let uncertainLegacy = uncertainDir.appending(path: "\(teamID.canonicalCloudString)-\(vaultID.canonicalCloudString).json")
        try legacyBytes.write(to: uncertainLegacy, options: .atomic)
        let uncertainBase = try SelectiveRemoteTeamVaultFileSnapshotStore(root: uncertainRoot)
        try uncertainBase.saveIfCurrent(editedA.snapshot, endpoint: endpoint, replacing: initial.snapshot)
        let uncertainCurrent = uncertainLegacy.deletingPathExtension().appendingPathExtension("v2.json")
        let uncertainPriorBytes = try Data(contentsOf: uncertainCurrent)
        let uncertainStore = try SelectiveRemoteTeamVaultFileSnapshotStore(root: uncertainRoot, beforeCommit: {
            try FileManager.default.removeItem(at: uncertainLegacy)
            guard Darwin.mkfifo(uncertainLegacy.path, 0o600) == 0 else { throw CocoaError(.fileWriteUnknown) }
        })
        #expect(throws: SelectiveRemoteTeamVaultSnapshotError.invalidSnapshot) {
            try uncertainStore.remove(endpoint: endpoint, teamID: teamID, vaultID: vaultID)
        }
        try FileManager.default.removeItem(at: uncertainLegacy)
        try legacyBytes.write(to: uncertainLegacy, options: .atomic)
        #expect(throws: SelectiveRemoteTeamVaultSnapshotError.concurrentChange) {
            try uncertainBase.save(initial.snapshot, endpoint: endpoint)
        }
        #expect(try Data(contentsOf: uncertainCurrent.appendingPathExtension("previous")) == uncertainPriorBytes)

        // Removing the new copy must not resurrect the retained old copy.
        let removedRoot = directory.appending(path: "legacy-tombstone", directoryHint: .isDirectory)
        let removedDir = removedRoot.appending(path: endpointID, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: removedDir, withIntermediateDirectories: true)
        let removedLegacy = removedDir.appending(path: "\(teamID.canonicalCloudString)-\(vaultID.canonicalCloudString).json")
        try legacyBytes.write(to: removedLegacy, options: .atomic)
        let removedStore = try SelectiveRemoteTeamVaultFileSnapshotStore(root: removedRoot)
        try removedStore.remove(endpoint: endpoint, teamID: teamID, vaultID: vaultID)
        #expect(try Data(contentsOf: removedLegacy) == legacyBytes)
        #expect(try removedStore.load(endpoint: endpoint, teamID: teamID, vaultID: vaultID) == nil)
        try changedLegacy.write(to: removedLegacy, options: .atomic)
        #expect(throws: SelectiveRemoteTeamVaultSnapshotError.concurrentChange) {
            try removedStore.load(endpoint: endpoint, teamID: teamID, vaultID: vaultID)
        }

        // The server may acknowledge a PUT before an old process changes its
        // copy. Do not claim the write failed or discard either local copy.
        let ackRoot = directory.appending(path: "legacy-after-put", directoryHint: .isDirectory)
        let ackDir = ackRoot.appending(path: endpointID, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: ackDir, withIntermediateDirectories: true)
        let ackLegacy = ackDir.appending(path: "\(teamID.canonicalCloudString)-\(vaultID.canonicalCloudString).json")
        try legacyBytes.write(to: ackLegacy, options: .atomic)
        let ackStore = try SelectiveRemoteTeamVaultFileSnapshotStore(root: ackRoot)
        try ackStore.saveIfCurrent(editedA.snapshot, endpoint: endpoint, replacing: initial.snapshot)
        let ackRemote = TeamVaultRemoteStub(envelope: Self.remoteEnvelope(fixture, wrapper: wrapper),
            writeResult: .init(conflict: false, revision: 6, keyGeneration: 7, rotationCompleted: false),
            afterWrite: { try changedLegacy.write(to: ackLegacy, options: .atomic) })
        let ackCoordinator = try SelectiveRemoteTeamVaultSyncCoordinator(endpoint: endpoint, remote: ackRemote, snapshots: ackStore)
        await #expect(throws: SelectiveRemoteTeamVaultSyncError.localAcknowledgementUnconfirmed) {
            try await ackCoordinator.push(teamID: teamID, vaultID: vaultID, identity: identity)
        }
        #expect(await ackRemote.recordedWrites().count == 1)
        #expect(try Data(contentsOf: ackLegacy) == changedLegacy)
        #expect(FileManager.default.fileExists(atPath: ackLegacy.deletingPathExtension().appendingPathExtension("v2.json").path))

        // A corrupted new file must not silently fall back to the old copy.
        let corruptRoot = directory.appending(path: "legacy-corrupt", directoryHint: .isDirectory)
        let corruptDir = corruptRoot.appending(path: endpointID, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: corruptDir, withIntermediateDirectories: true)
        let corruptLegacy = corruptDir.appending(path: "\(teamID.canonicalCloudString)-\(vaultID.canonicalCloudString).json")
        try legacyBytes.write(to: corruptLegacy, options: .atomic)
        let corruptStore = try SelectiveRemoteTeamVaultFileSnapshotStore(root: corruptRoot)
        try corruptStore.saveIfCurrent(editedA.snapshot, endpoint: endpoint, replacing: initial.snapshot)
        try Data("not a snapshot".utf8).write(to: corruptLegacy.deletingPathExtension().appendingPathExtension("v2.json"), options: .atomic)
        #expect(throws: SelectiveRemoteTeamVaultSnapshotError.invalidSnapshot) {
            try corruptStore.load(endpoint: endpoint, teamID: teamID, vaultID: vaultID)
        }
        #expect(try Data(contentsOf: corruptLegacy) == legacyBytes)

        // An unreadable or replaced file is not equivalent to an absent file.
        let fifoRoot = directory.appending(path: "legacy-fifo", directoryHint: .isDirectory)
        let fifoDir = fifoRoot.appending(path: endpointID, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fifoDir, withIntermediateDirectories: true)
        let fifo = fifoDir.appending(path: "\(teamID.canonicalCloudString)-\(vaultID.canonicalCloudString).json")
        guard Darwin.mkfifo(fifo.path, 0o600) == 0 else { Issue.record("Could not create synthetic FIFO"); return }
        let fifoStore = try SelectiveRemoteTeamVaultFileSnapshotStore(root: fifoRoot)
        #expect(throws: SelectiveRemoteTeamVaultSnapshotError.invalidSnapshot) {
            try fifoStore.load(endpoint: endpoint, teamID: teamID, vaultID: vaultID)
        }

        let lostRoot = directory.appending(path: "missing-current", directoryHint: .isDirectory)
        let lostStore = try SelectiveRemoteTeamVaultFileSnapshotStore(root: lostRoot)
        try lostStore.save(initial.snapshot, endpoint: endpoint)
        let lostDir = lostRoot.appending(path: endpointID, directoryHint: .isDirectory)
        let lostCurrent = lostDir.appending(path: "\(teamID.canonicalCloudString)-\(vaultID.canonicalCloudString).v2.json")
        try FileManager.default.removeItem(at: lostCurrent)
        #expect(throws: SelectiveRemoteTeamVaultSnapshotError.concurrentChange) {
            try lostStore.load(endpoint: endpoint, teamID: teamID, vaultID: vaultID)
        }

        // A valid snapshot from another Team at this path must never be
        // replaced or tombstoned by any write method.
        let scopeRoot = directory.appending(path: "wrong-scope", directoryHint: .isDirectory)
        let scopeDir = scopeRoot.appending(path: endpointID, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scopeDir, withIntermediateDirectories: true)
        let scopeCurrent = scopeDir.appending(path: "\(teamID.canonicalCloudString)-\(vaultID.canonicalCloudString).v2.json")
        var foreign = try #require(try JSONSerialization.jsonObject(with: legacyBytes) as? [String: Any])
        foreign["teamID"] = UUID().uuidString.lowercased()
        let foreignBytes = try JSONSerialization.data(withJSONObject: ["version": 1, "legacyDigest": NSNull(), "snapshot": foreign], options: [.sortedKeys])
        try foreignBytes.write(to: scopeCurrent, options: .atomic)
        let scopeStore = try SelectiveRemoteTeamVaultFileSnapshotStore(root: scopeRoot)
        #expect(throws: SelectiveRemoteTeamVaultSnapshotError.invalidSnapshot) {
            try scopeStore.load(endpoint: endpoint, teamID: teamID, vaultID: vaultID)
        }
        #expect(throws: SelectiveRemoteTeamVaultSnapshotError.invalidSnapshot) {
            try scopeStore.save(initial.snapshot, endpoint: endpoint)
        }
        #expect(throws: SelectiveRemoteTeamVaultSnapshotError.invalidSnapshot) {
            try scopeStore.saveIfCurrent(initial.snapshot, endpoint: endpoint, replacing: nil)
        }
        #expect(throws: SelectiveRemoteTeamVaultSnapshotError.invalidSnapshot) {
            try scopeStore.remove(endpoint: endpoint, teamID: teamID, vaultID: vaultID)
        }
        #expect(try Data(contentsOf: scopeCurrent) == foreignBytes)

        // Independent Vaults share an endpoint directory in production.
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let unrelatedRoot = directory.appending(path: "unrelated-vaults")
        let blocking = try SelectiveRemoteTeamVaultFileSnapshotStore(root: unrelatedRoot, beforeCommit: {
            entered.signal()
            guard release.wait(timeout: .now() + 45) == .success else { throw CocoaError(.fileWriteUnknown) }
        })
        let otherStore = try SelectiveRemoteTeamVaultFileSnapshotStore(root: unrelatedRoot)
        let otherVaultID = UUID()
        let otherKey = try fixture.keyWrap.vaultKey.base64URLData
        let otherWrapper = try SelectiveRemoteTeamVaultCrypto.wrapVaultKey(otherKey, for: identity.publicKey,
            context: .init(teamID: teamID, vaultID: otherVaultID, keyGeneration: fixture.payload.keyGeneration,
                           membershipID: try fixture.wrapper.membershipID.uuid, membershipEpoch: fixture.wrapper.membershipEpoch,
                           deviceID: deviceID))
        let otherEnvelope = try SelectiveRemoteTeamVaultCrypto.encryptPayload(Data("other Vault".utf8), vaultKey: otherKey,
            teamID: teamID, vaultID: otherVaultID, keyGeneration: fixture.payload.keyGeneration, baseRevision: 0)
        let otherSnapshot = try SelectiveRemoteTeamVaultSnapshot(teamID: teamID, vaultID: otherVaultID, deviceID: deviceID,
            keyGeneration: fixture.payload.keyGeneration, localRevision: 1, serverRevision: 0, syncedLocalRevision: 0,
            envelope: otherEnvelope, wrapper: otherWrapper)
        let pending = Task {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { try blocking.save(initial.snapshot, endpoint: endpoint); continuation.resume() }
                    catch { continuation.resume(throwing: error) }
                }
            }
        }
        let reached = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: entered.wait(timeout: .now() + 45) == .success) }
        }
        guard reached else {
            release.signal()
            _ = await pending.result
            Issue.record("The synthetic writer did not start")
            return
        }
        do { try otherStore.save(otherSnapshot, endpoint: endpoint) }
        catch {
            release.signal()
            _ = await pending.result
            throw error
        }
        release.signal()
        try await pending.value
        #expect(try otherStore.load(endpoint: endpoint, teamID: teamID, vaultID: otherVaultID) == otherSnapshot)
    }

    @Test("A delayed Team stage cannot overwrite a new account's local edit", .timeLimit(.minutes(1)))
    func delayedTeamStageCannotOverwriteNewAccount() async throws {
        let fixture = try Self.fixture()
        let endpoint = URL(string: "https://stage-race-\(UUID()).example.invalid")!
        let teamID = try fixture.wrapper.teamID.uuid, vaultID = try fixture.wrapper.vaultID.uuid
        let deviceID = try fixture.wrapper.deviceID.uuid
        let identity = try SelectiveRemoteTeamDeviceIdentity(deviceID: deviceID,
            privateKeyRepresentation: try fixture.keyWrap.recipientPrivateScalar.base64URLData)
        let wrapper = try Self.fixtureWrapper(fixture, identity: identity)
        let remote = TeamVaultRemoteStub(envelope: Self.remoteEnvelope(fixture, wrapper: wrapper),
            writeResult: .init(conflict: false, revision: 6, keyGeneration: 7, rotationCompleted: false))
        let store = ControlledTeamSnapshotStore(), tokens = SelectiveRemoteCloudMemoryTokenStore()
        let original = try SelectiveRemoteTeamVaultSyncCoordinator(endpoint: endpoint, remote: remote, snapshots: store)
        _ = try await original.refresh(teamID: teamID, vaultID: vaultID, identity: identity)
        let oldToken = String(repeating: "a", count: 43), newToken = String(repeating: "b", count: 43)
        tokens.saveToken(oldToken, for: endpoint)
        let oldSession = SelectiveRemotePublicationSession(endpoint: endpoint, accountID: UUID(), deviceID: deviceID,
                                                            token: oldToken, tokenStore: tokens)
        let oldCoordinator = try SelectiveRemoteTeamVaultSyncCoordinator(endpoint: endpoint, remote: remote, snapshots: store, session: oldSession)
        let expected = try #require(try store.load(endpoint: endpoint, teamID: teamID, vaultID: vaultID))
        let candidateStore = SelectiveRemoteTeamVaultMemorySnapshotStore()
        try candidateStore.save(expected, endpoint: endpoint)
        let next = try SelectiveRemoteTeamVaultSyncCoordinator(endpoint: endpoint, remote: remote, snapshots: candidateStore)
        let newer = try await next.stage(Data("new edit".utf8), expected: expected, teamID: teamID, vaultID: vaultID, identity: identity)
        // Inject the account transition after the old read but before its
        // commit, without blocking a cooperative executor thread.
        store.afterNextLoad {
            SelectiveRemotePublicationLifecycle.invalidate(endpoint: endpoint)
            tokens.saveToken(newToken, for: endpoint)
            try store.saveIfCurrent(newer.snapshot, endpoint: endpoint, replacing: expected)
        }
        await #expect(throws: CancellationError.self) {
            try await oldCoordinator.stage(Data("old edit".utf8), expected: expected, teamID: teamID, vaultID: vaultID, identity: identity)
        }
        #expect(try store.load(endpoint: endpoint, teamID: teamID, vaultID: vaultID) == newer.snapshot)
    }

    @Test("Team Vault coordinator initializes encrypted host data for the approved device set")
    func teamVaultInitialization() async throws {
        let endpoint = try SelectiveRemoteCloudEndpoint.normalized("https://cloud.example.invalid")
        let teamID = try #require(UUID(uuidString: "11111111-1111-4111-8111-111111111111"))
        let vaultID = try #require(UUID(uuidString: "22222222-2222-4222-8222-222222222222"))
        let deviceID = try #require(UUID(uuidString: "44444444-4444-4444-8444-444444444444"))
        let membershipID = try #require(UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
        let identity = try SelectiveRemoteTeamDeviceIdentity(
            deviceID: deviceID,
            privateKeyRepresentation: Data(repeating: 0x31, count: 32)
        )
        let empty = SelectiveRemoteCloudSharedVaultEnvelope(
            id: vaultID, teamID: teamID, name: "Operations", revision: 0,
            keyGeneration: 1, rotationRequired: false, envelopeVersion: nil,
            ciphertext: nil, nonce: nil, authTag: nil, contentHash: nil, wrapper: nil,
            createdAt: "2026-09-08T00:00:00.000Z", updatedAt: "2026-09-08T00:00:00.000Z"
        )
        let remote = TeamVaultRemoteStub(
            envelope: empty,
            writeResult: .init(conflict: false, revision: 1, keyGeneration: 1, rotationCompleted: false)
        )
        let storage = SelectiveRemoteTeamVaultMemorySnapshotStore()
        let coordinator = try SelectiveRemoteTeamVaultSyncCoordinator(
            endpoint: endpoint, remote: remote, snapshots: storage
        )
        let payload = Data(#"{"records":["synthetic-host"]}"#.utf8)
        let outcome = try await coordinator.initialize(
            payload: payload,
            teamID: teamID,
            vaultID: vaultID,
            identity: identity,
            keyDevices: [.init(
                membershipID: membershipID,
                membershipEpoch: 1,
                deviceID: deviceID,
                publicKeyAlgorithm: "p256-ecdh-v1",
                publicKey: identity.publicKey,
                hasWrapper: false
            )]
        )
        guard case let .uploaded(uploaded) = outcome else {
            Issue.record("Expected initialization to commit")
            return
        }
        #expect(uploaded.payload == payload)
        #expect(uploaded.snapshot.serverRevision == 1)
        #expect(uploaded.snapshot.syncedLocalRevision == 1)
        let writes = await remote.recordedWrites()
        #expect(writes.count == 1)
        #expect(writes[0].upload.wrappers?.count == 1)
        #expect(writes[0].upload.envelope.baseRevision == 0)
        let vaultKey = try SelectiveRemoteTeamVaultCrypto.unwrapVaultKey(
            uploaded.snapshot.wrapper,
            with: identity,
            teamID: teamID,
            vaultID: vaultID,
            keyGeneration: 1
        )
        #expect(try SelectiveRemoteTeamVaultCrypto.decryptPayload(
            uploaded.snapshot.envelope,
            vaultKey: vaultKey,
            teamID: teamID,
            vaultID: vaultID
        ) == payload)
    }

    @Test("Team Vault coordinator preserves the dirty snapshot and both conflict versions")
    func teamVaultSyncConflict() async throws {
        let fixture = try Self.fixture()
        let endpoint = try SelectiveRemoteCloudEndpoint.normalized("https://cloud.example.invalid")
        let teamID = try fixture.wrapper.teamID.uuid
        let vaultID = try fixture.wrapper.vaultID.uuid
        let deviceID = try fixture.wrapper.deviceID.uuid
        let identity = try SelectiveRemoteTeamDeviceIdentity(
            deviceID: deviceID,
            privateKeyRepresentation: try fixture.keyWrap.recipientPrivateScalar.base64URLData
        )
        let wrapper = try Self.fixtureWrapper(fixture, identity: identity)
        let remote = TeamVaultRemoteStub(
            envelope: Self.remoteEnvelope(fixture, wrapper: wrapper),
            writeResult: .init(conflict: true, revision: 6, keyGeneration: 7, rotationCompleted: nil)
        )
        let storage = SelectiveRemoteTeamVaultMemorySnapshotStore()
        let coordinator = try SelectiveRemoteTeamVaultSyncCoordinator(
            endpoint: endpoint,
            remote: remote,
            snapshots: storage
        )
        _ = try await coordinator.refresh(teamID: teamID, vaultID: vaultID, identity: identity)

        let localPayload = Data("synthetic local conflict".utf8)
        let staged = try await coordinator.stage(
            localPayload,
            expected: try #require(try storage.load(endpoint: endpoint, teamID: teamID, vaultID: vaultID)),
            teamID: teamID,
            vaultID: vaultID,
            identity: identity
        )
        let remotePayload = Data("synthetic remote conflict".utf8)
        let remoteCiphertext = try SelectiveRemoteTeamVaultCrypto.encryptPayload(
            remotePayload,
            vaultKey: try fixture.keyWrap.vaultKey.base64URLData,
            teamID: teamID,
            vaultID: vaultID,
            keyGeneration: fixture.payload.keyGeneration,
            baseRevision: 5,
            nonce: Data(repeating: 0x23, count: 12)
        )
        await remote.setEnvelope(.init(
            id: vaultID,
            teamID: teamID,
            name: "Operations",
            revision: 6,
            keyGeneration: fixture.payload.keyGeneration,
            rotationRequired: false,
            envelopeVersion: remoteCiphertext.envelopeVersion,
            ciphertext: remoteCiphertext.ciphertext,
            nonce: remoteCiphertext.nonce,
            authTag: remoteCiphertext.authTag,
            contentHash: remoteCiphertext.contentHash,
            wrapper: wrapper,
            createdAt: "2026-09-06T00:00:00.000Z",
            updatedAt: "2026-09-07T00:00:00.000Z"
        ))

        let pushed = try await coordinator.push(
            teamID: teamID,
            vaultID: vaultID,
            identity: identity
        )
        guard case let .conflict(conflict) = pushed else {
            Issue.record("Expected an explicit causal conflict")
            return
        }
        #expect(conflict.local.payload == localPayload)
        #expect(conflict.remote.payload == remotePayload)
        #expect(conflict.local.snapshot.envelope == staged.snapshot.envelope)
        let preserved = try storage.load(endpoint: endpoint, teamID: teamID, vaultID: vaultID)
        #expect(preserved == staged.snapshot)

        let newerRemotePayload = Data("synthetic newer remote conflict".utf8)
        let newerRemoteCiphertext = try SelectiveRemoteTeamVaultCrypto.encryptPayload(
            newerRemotePayload,
            vaultKey: try fixture.keyWrap.vaultKey.base64URLData,
            teamID: teamID,
            vaultID: vaultID,
            keyGeneration: fixture.payload.keyGeneration,
            baseRevision: 6,
            nonce: Data(repeating: 0x24, count: 12)
        )
        await remote.setEnvelope(.init(
            id: vaultID,
            teamID: teamID,
            name: "Operations",
            revision: 7,
            keyGeneration: fixture.payload.keyGeneration,
            rotationRequired: false,
            envelopeVersion: newerRemoteCiphertext.envelopeVersion,
            ciphertext: newerRemoteCiphertext.ciphertext,
            nonce: newerRemoteCiphertext.nonce,
            authTag: newerRemoteCiphertext.authTag,
            contentHash: newerRemoteCiphertext.contentHash,
            wrapper: wrapper,
            createdAt: "2026-09-06T00:00:00.000Z",
            updatedAt: "2026-09-07T01:00:00.000Z"
        ))
        let staleResolution = try await coordinator.resolveConflict(
            conflict,
            resolvedPayload: Data("must not upload".utf8),
            teamID: teamID,
            vaultID: vaultID,
            identity: identity
        )
        guard case let .conflict(updatedConflict) = staleResolution else {
            Issue.record("Expected a changed remote version to return a new conflict")
            return
        }
        #expect(updatedConflict.remote.revision == 7)
        #expect(updatedConflict.remote.payload == newerRemotePayload)
        #expect(try storage.load(endpoint: endpoint, teamID: teamID, vaultID: vaultID) == staged.snapshot)
        let staleResolutionWrites = await remote.recordedWrites()
        #expect(staleResolutionWrites.count == 1)

        let resolvedPayload = Data("synthetic joined conflict resolution".utf8)
        await remote.setWriteFailure(.unknownOutcome)
        await #expect(throws: TeamVaultRemoteStubFailure.unknownOutcome) {
            try await coordinator.resolveConflict(
                updatedConflict,
                resolvedPayload: resolvedPayload,
                teamID: teamID,
                vaultID: vaultID,
                identity: identity
            )
        }
        let storedPendingResolution = try storage.load(
            endpoint: endpoint,
            teamID: teamID,
            vaultID: vaultID
        )
        let pendingResolution = try #require(storedPendingResolution)
        #expect(pendingResolution.envelope.baseRevision == 7)
        #expect(pendingResolution.localRevision > pendingResolution.syncedLocalRevision)

        await remote.setWriteFailure(nil)
        await remote.setWriteResult(.init(
            conflict: false,
            revision: 8,
            keyGeneration: fixture.payload.keyGeneration,
            rotationCompleted: false
        ))
        let resolution = try await coordinator.push(
            teamID: teamID,
            vaultID: vaultID,
            identity: identity
        )
        guard case let .uploaded(uploaded) = resolution else {
            Issue.record("Expected the explicit conflict resolution to upload")
            return
        }
        #expect(uploaded.payload == resolvedPayload)
        #expect(uploaded.snapshot.serverRevision == 8)
        #expect(uploaded.snapshot.envelope.baseRevision == 7)
        #expect(uploaded.snapshot.localRevision == uploaded.snapshot.syncedLocalRevision)
        let resolutionWrites = await remote.recordedWrites()
        #expect(resolutionWrites.count == 3)
        #expect(resolutionWrites.last?.upload.envelope.baseRevision == 7)
        #expect(resolutionWrites[1].idempotencyKey == resolutionWrites[2].idempotencyKey)
        #expect(resolutionWrites.last?.idempotencyKey != resolutionWrites.first?.idempotencyKey)
    }

    @Test("Team Vault conflict resolution preserves an edit staged during remote revalidation")
    func teamVaultConflictResolutionReentrancy() async throws {
        let fixture = try Self.fixture()
        let endpoint = try SelectiveRemoteCloudEndpoint.normalized("https://cloud.example.invalid")
        let teamID = try fixture.wrapper.teamID.uuid
        let vaultID = try fixture.wrapper.vaultID.uuid
        let identity = try SelectiveRemoteTeamDeviceIdentity(
            deviceID: try fixture.wrapper.deviceID.uuid,
            privateKeyRepresentation: try fixture.keyWrap.recipientPrivateScalar.base64URLData
        )
        let wrapper = try Self.fixtureWrapper(fixture, identity: identity)
        let remote = TeamVaultRemoteStub(
            envelope: Self.remoteEnvelope(fixture, wrapper: wrapper),
            writeResult: .init(conflict: true, revision: 6, keyGeneration: 7, rotationCompleted: nil)
        )
        let storage = SelectiveRemoteTeamVaultMemorySnapshotStore()
        let coordinator = try SelectiveRemoteTeamVaultSyncCoordinator(
            endpoint: endpoint,
            remote: remote,
            snapshots: storage
        )
        _ = try await coordinator.refresh(teamID: teamID, vaultID: vaultID, identity: identity)
        _ = try await coordinator.stage(
            Data("synthetic original local conflict".utf8),
            expected: try #require(try storage.load(endpoint: endpoint, teamID: teamID, vaultID: vaultID)),
            teamID: teamID,
            vaultID: vaultID,
            identity: identity
        )

        let remotePayload = Data("synthetic remote conflict".utf8)
        let remoteCiphertext = try SelectiveRemoteTeamVaultCrypto.encryptPayload(
            remotePayload,
            vaultKey: try fixture.keyWrap.vaultKey.base64URLData,
            teamID: teamID,
            vaultID: vaultID,
            keyGeneration: fixture.payload.keyGeneration,
            baseRevision: 5,
            nonce: Data(repeating: 0x26, count: 12)
        )
        await remote.setEnvelope(.init(
            id: vaultID,
            teamID: teamID,
            name: "Operations",
            revision: 6,
            keyGeneration: fixture.payload.keyGeneration,
            rotationRequired: false,
            envelopeVersion: remoteCiphertext.envelopeVersion,
            ciphertext: remoteCiphertext.ciphertext,
            nonce: remoteCiphertext.nonce,
            authTag: remoteCiphertext.authTag,
            contentHash: remoteCiphertext.contentHash,
            wrapper: wrapper,
            createdAt: "2026-09-06T00:00:00.000Z",
            updatedAt: "2026-09-07T00:00:00.000Z"
        ))
        let pushed = try await coordinator.push(teamID: teamID, vaultID: vaultID, identity: identity)
        guard case let .conflict(conflict) = pushed else {
            Issue.record("Expected an explicit conflict")
            return
        }

        let barrier = TeamVaultReadBarrier()
        await remote.setReadBarrier(barrier)
        let resolving = Task {
            try await coordinator.resolveConflict(
                conflict,
                resolvedPayload: Data("must not replace racing edit".utf8),
                teamID: teamID,
                vaultID: vaultID,
                identity: identity
            )
        }
        await barrier.waitUntilSuspended()
        let racingPayload = Data("synthetic racing local edit".utf8)
        let racing = try await coordinator.stage(
            racingPayload,
            expected: try #require(try storage.load(endpoint: endpoint, teamID: teamID, vaultID: vaultID)),
            teamID: teamID,
            vaultID: vaultID,
            identity: identity
        )
        await barrier.resume()

        await #expect(throws: SelectiveRemoteTeamVaultSyncError.staleConflict) {
            try await resolving.value
        }
        let preserved = try storage.load(endpoint: endpoint, teamID: teamID, vaultID: vaultID)
        #expect(preserved == racing.snapshot)
        let writes = await remote.recordedWrites()
        #expect(writes.count == 1)
    }

    @Test("Team Vault record workflow requires a complete causal choice before upload")
    func teamVaultRecordConflictWorkflow() async throws {
        let fixture = try Self.fixture()
        let endpoint = try SelectiveRemoteCloudEndpoint.normalized("https://cloud.example.invalid")
        let teamID = try fixture.wrapper.teamID.uuid
        let vaultID = try fixture.wrapper.vaultID.uuid
        let identity = try SelectiveRemoteTeamDeviceIdentity(
            deviceID: try fixture.wrapper.deviceID.uuid,
            privateKeyRepresentation: try fixture.keyWrap.recipientPrivateScalar.base64URLData
        )
        let wrapper = try Self.fixtureWrapper(fixture, identity: identity)
        let remote = TeamVaultRemoteStub(
            envelope: Self.remoteEnvelope(fixture, wrapper: wrapper),
            writeResult: .init(conflict: true, revision: 6, keyGeneration: 7, rotationCompleted: nil)
        )
        let storage = SelectiveRemoteTeamVaultMemorySnapshotStore()
        let coordinator = try SelectiveRemoteTeamVaultSyncCoordinator(
            endpoint: endpoint,
            remote: remote,
            snapshots: storage
        )
        _ = try await coordinator.refresh(teamID: teamID, vaultID: vaultID, identity: identity)

        let deviceA = try #require(UUID(uuidString: "11111111-1111-4111-8111-111111111111"))
        let deviceB = try #require(UUID(uuidString: "22222222-2222-4222-8222-222222222222"))
        let recordID = try #require(UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
        let localRecord = try SelectiveRemoteVaultRecord(
            id: recordID,
            type: .host,
            version: .init([deviceA: 2]),
            modifiedAt: "2026-09-07T01:00:00.000Z",
            data: .object(["title": .string("Local")])
        )
        let remoteRecord = try SelectiveRemoteVaultRecord(
            id: recordID,
            type: .host,
            version: .init([deviceA: 1, deviceB: 1]),
            modifiedAt: "2026-09-07T02:00:00.000Z",
            data: .object(["title": .string("Remote")])
        )
        let localDocument = try SelectiveRemoteVaultDocument(records: [localRecord])
        let remoteDocument = try SelectiveRemoteVaultDocument(records: [remoteRecord])
        _ = try await coordinator.stage(
            localDocument.encoded(),
            expected: try #require(try storage.load(endpoint: endpoint, teamID: teamID, vaultID: vaultID)),
            teamID: teamID,
            vaultID: vaultID,
            identity: identity
        )
        let remoteCiphertext = try SelectiveRemoteTeamVaultCrypto.encryptPayload(
            remoteDocument.encoded(),
            vaultKey: try fixture.keyWrap.vaultKey.base64URLData,
            teamID: teamID,
            vaultID: vaultID,
            keyGeneration: fixture.payload.keyGeneration,
            baseRevision: 5,
            nonce: Data(repeating: 0x27, count: 12)
        )
        await remote.setEnvelope(.init(
            id: vaultID,
            teamID: teamID,
            name: "Operations",
            revision: 6,
            keyGeneration: fixture.payload.keyGeneration,
            rotationRequired: false,
            envelopeVersion: remoteCiphertext.envelopeVersion,
            ciphertext: remoteCiphertext.ciphertext,
            nonce: remoteCiphertext.nonce,
            authTag: remoteCiphertext.authTag,
            contentHash: remoteCiphertext.contentHash,
            wrapper: wrapper,
            createdAt: "2026-09-06T00:00:00.000Z",
            updatedAt: "2026-09-07T02:00:00.000Z"
        ))

        let pushed = try await coordinator.push(teamID: teamID, vaultID: vaultID, identity: identity)
        guard case let .conflict(transportConflict) = pushed else {
            Issue.record("Expected a transport conflict")
            return
        }
        let prepared = try await coordinator.prepareRecordConflict(transportConflict)
        #expect(prepared.mergedDocument.records.isEmpty)
        #expect(prepared.recordConflicts.map(\.id) == [recordID])
        await #expect(throws: SelectiveRemoteVaultDocumentError.incompleteConflictResolutions) {
            try await coordinator.resolveRecordConflicts(
                prepared,
                resolutions: [],
                resolvedAt: "2026-09-07T03:00:00.000Z",
                teamID: teamID,
                vaultID: vaultID,
                identity: identity
            )
        }

        await remote.setWriteResult(.init(
            conflict: false,
            revision: 7,
            keyGeneration: fixture.payload.keyGeneration,
            rotationCompleted: false
        ))
        let resolved = try await coordinator.resolveRecordConflicts(
            prepared,
            resolutions: [.init(id: recordID, choice: .remote)],
            resolvedAt: "2026-09-07T03:00:00.000Z",
            teamID: teamID,
            vaultID: vaultID,
            identity: identity
        )
        guard case let .uploaded(snapshot, document) = resolved else {
            Issue.record("Expected a resolved record upload")
            return
        }
        #expect(snapshot.snapshot.serverRevision == 7)
        #expect(document.records[0].data == .object(["title": .string("Remote")]))
        #expect(document.records[0].version.counters == [
            deviceA: 2,
            deviceB: 1,
            identity.deviceID: 1
        ])
        let writes = await remote.recordedWrites()
        #expect(writes.count == 2)
        #expect(writes.last?.upload.envelope.baseRevision == 6)
    }

    @Test("Team Vault coordinator fails closed while key rotation is required")
    func teamVaultSyncRotationGate() async throws {
        let fixture = try Self.fixture()
        let endpoint = try SelectiveRemoteCloudEndpoint.normalized("https://cloud.example.invalid")
        let identity = try SelectiveRemoteTeamDeviceIdentity(
            deviceID: try fixture.wrapper.deviceID.uuid,
            privateKeyRepresentation: try fixture.keyWrap.recipientPrivateScalar.base64URLData
        )
        let wrapper = try Self.fixtureWrapper(fixture, identity: identity)
        var blocked = Self.remoteEnvelope(fixture, wrapper: wrapper)
        blocked.rotationRequired = true
        let remote = TeamVaultRemoteStub(
            envelope: blocked,
            writeResult: .init(conflict: false, revision: 6, keyGeneration: 7, rotationCompleted: false)
        )
        let coordinator = try SelectiveRemoteTeamVaultSyncCoordinator(
            endpoint: endpoint,
            remote: remote,
            snapshots: SelectiveRemoteTeamVaultMemorySnapshotStore()
        )
        await #expect(throws: SelectiveRemoteTeamVaultSyncError.rotationRequired) {
            try await coordinator.refresh(
                teamID: try fixture.wrapper.teamID.uuid,
                vaultID: try fixture.wrapper.vaultID.uuid,
                identity: identity
            )
        }
    }

    @Test("offline Team Vault storage persists only the strict ciphertext snapshot")
    func ciphertextOnlySnapshot() throws {
        let fixture = try Self.fixture()
        let endpoint = try SelectiveRemoteCloudEndpoint.normalized("https://cloud.example.invalid")
        let teamID = try fixture.wrapper.teamID.uuid
        let vaultID = try fixture.wrapper.vaultID.uuid
        let deviceID = try fixture.wrapper.deviceID.uuid
        let identity = try SelectiveRemoteTeamDeviceIdentity(
            deviceID: deviceID,
            privateKeyRepresentation: try fixture.keyWrap.recipientPrivateScalar.base64URLData
        )
        let wrapper = try SelectiveRemoteTeamVaultCrypto.wrapVaultKey(
            try fixture.keyWrap.vaultKey.base64URLData,
            for: identity.publicKey,
            context: SelectiveRemoteTeamWrapperContext(
                teamID: teamID,
                vaultID: vaultID,
                keyGeneration: fixture.payload.keyGeneration,
                membershipID: try fixture.wrapper.membershipID.uuid,
                membershipEpoch: fixture.wrapper.membershipEpoch,
                deviceID: deviceID
            ),
            ephemeralPrivateKeyRepresentation: try fixture.keyWrap.ephemeralPrivateScalar.base64URLData,
            nonce: try fixture.keyWrap.nonce.base64URLData
        )
        let envelope = try SelectiveRemoteTeamVaultCrypto.encryptPayload(
            try fixture.payload.plaintext.base64URLData,
            vaultKey: try fixture.keyWrap.vaultKey.base64URLData,
            teamID: teamID,
            vaultID: vaultID,
            keyGeneration: fixture.payload.keyGeneration,
            baseRevision: fixture.payload.baseRevision,
            nonce: try fixture.payload.nonce.base64URLData
        )
        let snapshot = try SelectiveRemoteTeamVaultSnapshot(
            teamID: teamID,
            vaultID: vaultID,
            deviceID: deviceID,
            keyGeneration: fixture.payload.keyGeneration,
            localRevision: 2,
            serverRevision: 5,
            syncedLocalRevision: 1,
            envelope: envelope,
            wrapper: wrapper
        )
        let root = FileManager.default.temporaryDirectory
            .appending(path: "selective-remote-team-vault-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try SelectiveRemoteTeamVaultFileSnapshotStore(root: root)
        try storage.save(snapshot, endpoint: endpoint)
        #expect(try storage.load(endpoint: endpoint, teamID: teamID, vaultID: vaultID) == snapshot)
        let files = try FileManager.default.subpathsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".json") }
        let storedFile = try #require(files.first)
        let fileURL = root.appending(path: storedFile)
        let bytes = try Data(contentsOf: fileURL)
        #expect(!String(decoding: bytes, as: UTF8.self).contains("schemaVersion"))
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        try storage.remove(endpoint: endpoint, teamID: teamID, vaultID: vaultID)
        #expect(try storage.load(endpoint: endpoint, teamID: teamID, vaultID: vaultID) == nil)
    }

    private static func fixture() throws -> TeamVaultFixture {
        let url = try #require(Bundle.module.url(
            forResource: "team-vault-v1",
            withExtension: "json",
            subdirectory: "Fixtures"
        ))
        return try JSONDecoder().decode(TeamVaultFixture.self, from: Data(contentsOf: url))
    }

    private static func fixtureWrapper(
        _ fixture: TeamVaultFixture,
        identity: SelectiveRemoteTeamDeviceIdentity
    ) throws -> SelectiveRemoteTeamVaultKeyWrapper {
        try SelectiveRemoteTeamVaultCrypto.wrapVaultKey(
            fixture.keyWrap.vaultKey.base64URLData,
            for: identity.publicKey,
            context: SelectiveRemoteTeamWrapperContext(
                teamID: try fixture.wrapper.teamID.uuid,
                vaultID: try fixture.wrapper.vaultID.uuid,
                keyGeneration: fixture.wrapper.keyGeneration,
                membershipID: try fixture.wrapper.membershipID.uuid,
                membershipEpoch: fixture.wrapper.membershipEpoch,
                deviceID: identity.deviceID
            ),
            ephemeralPrivateKeyRepresentation: fixture.keyWrap.ephemeralPrivateScalar.base64URLData,
            nonce: fixture.keyWrap.nonce.base64URLData
        )
    }

    private static func remoteEnvelope(
        _ fixture: TeamVaultFixture,
        wrapper: SelectiveRemoteTeamVaultKeyWrapper
    ) -> SelectiveRemoteCloudSharedVaultEnvelope {
        .init(
            id: UUID(uuidString: fixture.wrapper.vaultID)!,
            teamID: UUID(uuidString: fixture.wrapper.teamID)!,
            name: "Operations",
            revision: fixture.payload.baseRevision + 1,
            keyGeneration: fixture.payload.keyGeneration,
            rotationRequired: false,
            envelopeVersion: fixture.payload.envelopeVersion,
            ciphertext: fixture.payload.ciphertext,
            nonce: fixture.payload.nonce,
            authTag: fixture.payload.authTag,
            contentHash: fixture.payload.contentHash,
            wrapper: wrapper,
            createdAt: "2026-09-06T00:00:00.000Z",
            updatedAt: "2026-09-06T00:00:00.000Z"
        )
    }

    private static func stringBodyValue(_ request: URLRequest, key: String) -> String? {
        guard let body = request.httpBody,
              let value = try? JSONSerialization.jsonObject(with: body),
              let object = value as? [String: Any]
        else { return nil }
        return object[key] as? String
    }

    private static func response(
        _ request: URLRequest,
        status: Int,
        json: Any?
    ) -> (Data, URLResponse) {
        let data = json.map { try! JSONSerialization.data(withJSONObject: $0) } ?? Data()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (data, response)
    }
}

@Suite("Account-password Personal Vault enrollment")
struct AccountPasswordPersonalVaultEnrollmentTests {
    @Test("macOS derives the browser-compatible passphrase and unwraps the Vault key")
    func accountPasswordRoundTrip() throws {
        let password = "correct horse battery"
        let passphrase = try SelectiveRemotePersonalVaultCrypto.accountPassphrase(password)
        #expect(passphrase == "selective-remote:account-password:v1:correct horse battery")
        let document = try SelectiveRemoteVaultDocument(records: [], tombstones: [])
        let setup = try SelectiveRemotePersonalVaultCrypto.createSetup(
            document,
            recoveryPhrase: passphrase,
            baseRevision: 0
        )

        let unwrapped = try SelectiveRemotePersonalVaultCrypto.unwrapVaultKey(
            setup.envelope.wrappedKey,
            passphrase: passphrase
        )
        #expect(unwrapped == setup.vaultKey)
        #expect(try SelectiveRemotePersonalVaultCrypto.open(setup.envelope, vaultKey: unwrapped) == document)
        #expect(throws: SelectiveRemotePersonalVaultError.self) {
            try SelectiveRemotePersonalVaultCrypto.unwrapVaultKey(
                setup.envelope.wrappedKey,
                passphrase: "selective-remote:account-password:v1:different password"
            )
        }
    }

    @Test("canonically equivalent account passwords derive the same passphrase")
    func unicodeNormalization() throws {
        #expect(
            try SelectiveRemotePersonalVaultCrypto.accountPassphrase("mot-de-passe-café")
                == SelectiveRemotePersonalVaultCrypto.accountPassphrase("mot-de-passe-cafe\u{301}")
        )
    }

    @Test("a newly enrolled remote Vault cannot upload before initial download")
    func remoteEnrollmentUploadGate() throws {
        let material = try SelectiveRemotePersonalVaultKeyMaterial(
            vaultID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            vaultKey: Data(repeating: 1, count: 32),
            wrappedKey: .init(salt: Data(repeating: 2, count: 16), value: Data(repeating: 3, count: 40)),
            revision: 2,
            documentHash: Data(repeating: 4, count: 32),
            requiresInitialDownload: true
        )
        #expect(material.requiresInitialDownload == true)
        #expect(!material.allowsUpload)
    }
}

@Suite("Personal Vault initial download decoder")
struct PersonalVaultInitialDownloadDecoderTests {
    @Test("macOS export round-trips into typed local resources")
    func exportedResourcesRoundTrip() throws {
        var profile = ConnectionProfile(connectionType: .ssh)
        profile.host = "host.example"
        profile.friendlyName = "Production"
        let snippet = TerminalCommandTemplate(
            id: UUID(), profileID: UUID(uuidString: "5A17407D-9F03-4F7B-80FB-BD06D3FA50B1")!,
            title: "Uptime", command: "uptime", category: "Ops",
            targets: [.localTerminal], updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let forward = IndependentPortForward(
            connection: .custom(host: "jump.example", username: "root", port: 22),
            kind: .local
        )
        let exported = try SelectiveRemotePersonalVaultExporter.makeExport(
            profiles: [profile], credentials: [], snippets: [snippet], forwarding: [forward],
            deviceID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        )

        let decoded = try SelectiveRemotePersonalVaultImporter.decode(exported.document)
        #expect(decoded.profiles.first?.id == profile.id)
        #expect(decoded.profiles.first?.friendlyName == profile.friendlyName)
        #expect(decoded.profiles.first?.host == profile.host)
        #expect(decoded.profiles.first?.connectionType == profile.connectionType)
        #expect(decoded.snippets == [snippet])
        #expect(decoded.forwarding == [forward])
        #expect(decoded.credentials.isEmpty)
    }

    @Test("web Host and Snippet receive bounded local defaults")
    func webRecords() throws {
        let version = try SelectiveRemoteVaultVersion([
            UUID(uuidString: "33333333-3333-4333-8333-333333333333")!: 1
        ])
        let hostID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
        let snippetID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
        let document = try SelectiveRemoteVaultDocument(records: [
            try .init(id: hostID, type: .host, version: version, modifiedAt: "2026-09-10T00:00:00.000Z", data: .object([
                "title": .string("Web Host"), "address": .string("web.example"), "username": .string("admin"),
                "connectionType": .string("ssh"), "port": .number(2_222),
                "folder": .string("Work/Production"), "tags": .array([.string("linux"), .string("prod")]),
                "description": .string("Created in browser")
            ])),
            try .init(id: snippetID, type: .snippet, version: version, modifiedAt: "2026-09-10T00:00:00.000Z", data: .object([
                "title": .string("Status"), "body": .string("uptime")
            ]))
        ])
        let decoded = try SelectiveRemotePersonalVaultImporter.decode(document)
        #expect(decoded.profiles.first?.id == hostID)
        #expect(decoded.profiles.first?.connectionType == .ssh)
        #expect(decoded.profiles.first?.sshPort == 2_222)
        #expect(decoded.profiles.first?.group == "Work/Production")
        #expect(decoded.profiles.first?.tags == ["linux", "prod"])
        #expect(decoded.profiles.first?.profileDescription == "Created in browser")
        #expect(decoded.snippets.first?.id == snippetID)
    }

    @Test("standalone browser Credential does not block native Vault materialization")
    func standaloneBrowserCredential() throws {
        let version = try SelectiveRemoteVaultVersion([
            UUID(uuidString: "33333333-3333-4333-8333-333333333333")!: 1
        ])
        let record = try SelectiveRemoteVaultRecord(
            id: UUID(uuidString: "66666666-6666-4666-8666-666666666666")!,
            type: .credential,
            version: version,
            modifiedAt: "2026-09-10T00:00:00.000Z",
            data: .object([
                "title": .string("Standalone"),
                "username": .string("operator"),
                "secret": .string("synthetic-secret")
            ])
        )

        let decoded = try SelectiveRemotePersonalVaultImporter.decode(
            SelectiveRemoteVaultDocument(records: [record])
        )
        #expect(decoded.credentials.isEmpty)
    }

    @Test("empty Mac accepts additions while an ID collision blocks the whole plan")
    func conflictAwarePlan() throws {
        var remote = ConnectionProfile(connectionType: .ssh)
        remote.host = "remote.example"
        let snapshot = SelectiveRemotePersonalVaultImportSnapshot(
            profiles: [remote], credentials: [], snippets: [], forwarding: [], tombstoneIDs: []
        )
        let clean = SelectiveRemotePersonalVaultImporter.plan(
            snapshot: snapshot, localProfiles: [], localSnippets: [], localForwarding: []
        )
        #expect(clean.canApply)
        #expect(clean.profiles == [remote])

        var local = remote
        local.host = "local.example"
        let blocked = SelectiveRemotePersonalVaultImporter.plan(
            snapshot: snapshot, localProfiles: [local], localSnippets: [], localForwarding: []
        )
        #expect(!blocked.canApply)
        #expect(blocked.conflictIDs == [remote.id])
        #expect(blocked.profiles.isEmpty)
    }

    @Test("remote tombstones never silently delete local resources")
    func tombstoneCollision() {
        let local = ConnectionProfile(connectionType: .rdp)
        let snapshot = SelectiveRemotePersonalVaultImportSnapshot(
            profiles: [], credentials: [], snippets: [], forwarding: [], tombstoneIDs: [local.id]
        )
        let plan = SelectiveRemotePersonalVaultImporter.plan(
            snapshot: snapshot, localProfiles: [local], localSnippets: [], localForwarding: []
        )
        #expect(!plan.canApply)
        #expect(plan.conflictIDs == [local.id])
    }
}

private final class CloudHTTPStub: @unchecked Sendable {
    let handler: @Sendable (URLRequest) throws -> (Data, URLResponse)

    init(handler: @escaping @Sendable (URLRequest) throws -> (Data, URLResponse)) {
        self.handler = handler
    }

    func data(for request: URLRequest) throws -> (Data, URLResponse) {
        try handler(request)
    }
}

private enum TeamVaultRemoteStubFailure: Error, Equatable, Sendable {
    case unknownOutcome
}

private actor TeamVaultReadBarrier {
    private var suspended = false
    private var continuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        suspended = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilSuspended() async {
        while !suspended {
            await Task.yield()
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private actor TeamVaultRemoteStub: SelectiveRemoteTeamVaultAutoSyncRemote {
    struct RecordedWrite: Equatable, Sendable {
        let upload: SelectiveRemoteCloudTeamVaultUpload
        let idempotencyKey: String
    }

    struct RecordedGrant: Equatable, Sendable {
        let wrapper: SelectiveRemoteTeamVaultKeyWrapper
        let keyGeneration: Int
        let idempotencyKey: String
    }

    private var envelope: SelectiveRemoteCloudSharedVaultEnvelope
    private var writeResult: SelectiveRemoteCloudTeamVaultWriteResult
    private var writeFailure: TeamVaultRemoteStubFailure?
    private var readBarrier: TeamVaultReadBarrier?
    private var writes: [RecordedWrite] = []
    private var grants: [RecordedGrant] = []
    private var teamValues: [SelectiveRemoteCloudTeam]
    private var vaultValues: [SelectiveRemoteCloudSharedVault]
    private var keyDeviceValues: [SelectiveRemoteCloudTeamKeyDevice]
    private let afterWrite: @Sendable () throws -> Void

    init(
        envelope: SelectiveRemoteCloudSharedVaultEnvelope,
        writeResult: SelectiveRemoteCloudTeamVaultWriteResult,
        teams: [SelectiveRemoteCloudTeam] = [],
        vaults: [SelectiveRemoteCloudSharedVault] = [],
        keyDevices: [SelectiveRemoteCloudTeamKeyDevice] = [],
        afterWrite: @escaping @Sendable () throws -> Void = {}
    ) {
        self.envelope = envelope
        self.writeResult = writeResult
        teamValues = teams
        vaultValues = vaults
        keyDeviceValues = keyDevices
        self.afterWrite = afterWrite
    }

    func hasStoredSession(endpoint _: URL) async -> Bool {
        true
    }

    func teams(endpoint _: URL) async throws -> [SelectiveRemoteCloudTeam] {
        teamValues
    }

    func sharedVaults(
        endpoint _: URL,
        teamID: UUID
    ) async throws -> [SelectiveRemoteCloudSharedVault] {
        #expect(vaultValues.allSatisfy { $0.teamID == teamID })
        return vaultValues
    }

    func teamKeyDevices(
        endpoint _: URL,
        teamID: UUID,
        vaultID: UUID
    ) async throws -> [SelectiveRemoteCloudTeamKeyDevice] {
        #expect(envelope.teamID == teamID)
        #expect(envelope.id == vaultID)
        return keyDeviceValues
    }

    func grantSharedVaultWrapper(
        endpoint _: URL,
        teamID: UUID,
        vaultID: UUID,
        keyGeneration: Int,
        wrapper: SelectiveRemoteTeamVaultKeyWrapper,
        idempotencyKey: String
    ) async throws -> SelectiveRemoteCloudTeamVaultWrapperGrant {
        #expect(envelope.teamID == teamID)
        #expect(envelope.id == vaultID)
        #expect(envelope.keyGeneration == keyGeneration)
        guard let index = keyDeviceValues.firstIndex(where: { $0.deviceID == wrapper.deviceID }) else {
            throw SelectiveRemoteCloudError.invalidRequest
        }
        grants.append(.init(
            wrapper: wrapper,
            keyGeneration: keyGeneration,
            idempotencyKey: idempotencyKey
        ))
        keyDeviceValues[index].hasWrapper = true
        return .init(granted: true, keyGeneration: keyGeneration, deviceID: wrapper.deviceID)
    }

    func sharedVault(
        endpoint _: URL,
        teamID: UUID,
        vaultID: UUID
    ) async throws -> SelectiveRemoteCloudSharedVaultEnvelope {
        #expect(envelope.teamID == teamID)
        #expect(envelope.id == vaultID)
        if let readBarrier {
            self.readBarrier = nil
            await readBarrier.suspend()
        }
        return envelope
    }

    func putSharedVault(
        endpoint _: URL,
        teamID: UUID,
        vaultID: UUID,
        upload: SelectiveRemoteCloudTeamVaultUpload,
        idempotencyKey: String
    ) async throws -> SelectiveRemoteCloudTeamVaultWriteResult {
        #expect(envelope.teamID == teamID)
        #expect(envelope.id == vaultID)
        writes.append(.init(upload: upload, idempotencyKey: idempotencyKey))
        if let writeFailure {
            throw writeFailure
        }
        try afterWrite()
        return writeResult
    }

    func setEnvelope(_ value: SelectiveRemoteCloudSharedVaultEnvelope) {
        envelope = value
    }

    func setWriteResult(_ value: SelectiveRemoteCloudTeamVaultWriteResult) {
        writeResult = value
    }

    func setWriteFailure(_ value: TeamVaultRemoteStubFailure?) {
        writeFailure = value
    }

    func setReadBarrier(_ value: TeamVaultReadBarrier?) {
        readBarrier = value
    }

    func recordedWrites() -> [RecordedWrite] {
        writes
    }

    func recordedGrants() -> [RecordedGrant] {
        grants
    }
}

private struct TeamVaultFixture: Decodable, Sendable {
    var version: Int
    var publicKey: SelectiveRemoteTeamDevicePublicKey
    var fingerprint: String
    var wrapper: Wrapper
    var keyWrap: KeyWrap
    var payload: Payload

    struct Wrapper: Decodable, Sendable {
        var teamID: String
        var vaultID: String
        var keyGeneration: Int
        var membershipID: String
        var membershipEpoch: Int
        var deviceID: String
        var contextBase64URL: String
        var contextHash: String
    }

    struct Payload: Decodable, Sendable {
        var teamID: String
        var vaultID: String
        var keyGeneration: Int
        var contextBase64URL: String
        var envelopeVersion: Int
        var baseRevision: Int
        var plaintext: String
        var nonce: String
        var ciphertext: String
        var authTag: String
        var contentHash: String
    }

    struct KeyWrap: Decodable, Sendable {
        var recipientPrivateScalar: String
        var ephemeralPrivateScalar: String
        var ephemeralPublicKey: SelectiveRemoteTeamDevicePublicKey
        var vaultKey: String
        var nonce: String
        var ciphertext: String
        var authTag: String
    }
}

private extension String {
    var uuid: UUID {
        get throws {
            guard let value = UUID(uuidString: self) else {
                throw SelectiveRemoteTeamCryptoError.invalidEnvelope
            }
            return value
        }
    }

    var base64URLData: Data {
        get throws {
            guard let value = Data(selectiveRemoteBase64URL: self) else {
                throw SelectiveRemoteTeamCryptoError.invalidEnvelope
            }
            return value
        }
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}


private actor TeamVaultMaterializedSnapshotSink {
    private var values: [SelectiveRemoteTeamVaultMaterializedSnapshot] = []

    func replace(with snapshots: [SelectiveRemoteTeamVaultMaterializedSnapshot]) {
        values = snapshots
    }

    func snapshots() -> [SelectiveRemoteTeamVaultMaterializedSnapshot] {
        values
    }
}


@Suite("Unified Cloud Keychain envelope")
struct CloudSecureEnvelopeModelTests {
    @Test("session and one device key round-trip in a single envelope")
    func roundTrip() throws {
        let key = Data(repeating: 0x2a, count: 32)
        let input = SelectiveRemoteCloudSecureEnvelope(
            sessionToken: "session-token",
            teamDevicePrivateKeys: ["device-id": key],
            personalVaultKeyMaterials: ["device-id": Data([4, 5, 6])]
        )
        let encoded = try JSONEncoder().encode(input)
        let decoded = try JSONDecoder().decode(
            SelectiveRemoteCloudSecureEnvelope.self,
            from: encoded
        )
        #expect(decoded == input)
        #expect(!decoded.isEmpty)
        #expect(decoded.teamDevicePrivateKeys["device-id"] == key)
        #expect(decoded.personalVaultKeyMaterials["device-id"] == Data([4, 5, 6]))
    }

    @Test("empty envelope is removable")
    func emptyEnvelope() {
        #expect(SelectiveRemoteCloudSecureEnvelope().isEmpty)
    }

    @Test("older unified envelopes decode before Personal Vault material is added")
    func legacyEnvelopeDecoding() throws {
        let legacy = try JSONSerialization.data(withJSONObject: [
            "sessionToken": "token",
            "teamDevicePrivateKeys": [String: String]()
        ])
        let decoded = try JSONDecoder().decode(
            SelectiveRemoteCloudSecureEnvelope.self,
            from: legacy
        )
        #expect(decoded.sessionToken == "token")
        #expect(decoded.personalVaultKeyMaterials.isEmpty)
    }
}

// Two explicit continuation handshakes: request entered and response released.
// No sleeps, polling, real HTTP, token-store callbacks, or Keychain.
private actor CloudLoginResponseBarrier {
    private var entered = false
    private var released = false
    private var enteredWaiter: CheckedContinuation<Bool, Never>?
    private var responseWaiter: CheckedContinuation<Void, Never>?

    func suspendResponse() async {
        entered = true
        enteredWaiter?.resume(returning: true)
        enteredWaiter = nil
        if released { return }
        await withCheckedContinuation { continuation in
            responseWaiter = continuation
            Task {
                try? await Task.sleep(nanoseconds: 45_000_000_000)
                if responseWaiter != nil {
                    Issue.record("Timed out waiting to release response")
                    resumeResponse()
                }
            }
        }
    }
    func waitForRequest() async -> Bool {
        if entered { return true }
        return await withCheckedContinuation { continuation in
            enteredWaiter = continuation
            Task {
                try? await Task.sleep(nanoseconds: 45_000_000_000)
                enteredWaiter?.resume(returning: false)
                enteredWaiter = nil
            }
        }
    }
    func resumeResponse() {
        released = true
        responseWaiter?.resume()
        responseWaiter = nil
    }
}

private actor CloudLogoutCallCounter {
    private(set) var value = 0
    func record() { value += 1 }
}

private actor CloudSessionNoticeSink {
    private(set) var events: [SelectiveRemoteCloudSessionLoss] = []
    func append(_ event: SelectiveRemoteCloudSessionLoss) { events.append(event) }
}

private final class CloudFailingRemovalTokenStore: SelectiveRemoteCloudTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String
    init(value: String) { self.value = value }
    func token(for endpoint: URL) throws -> String? { lock.withLock { value } }
    func saveToken(_ token: String, for endpoint: URL) throws { lock.withLock { value = token } }
    func removeToken(for endpoint: URL) throws { throw CocoaError(.fileWriteNoPermission) }
}

private final class CloudIntermittentReadTokenStore: SelectiveRemoteCloudTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    private var unreadable = false
    init(value: String) { self.value = value }
    func setUnreadable(_ value: Bool) { lock.withLock { unreadable = value } }
    func token(for endpoint: URL) throws -> String? {
        try lock.withLock {
            if unreadable { throw CocoaError(.fileReadNoPermission) }
            return value
        }
    }
    func saveToken(_ token: String, for endpoint: URL) throws { lock.withLock { value = token } }
    func removeToken(for endpoint: URL) throws { lock.withLock { value = nil } }
}

private final class ControlledTeamSnapshotStore: SelectiveRemoteTeamVaultSnapshotStore, @unchecked Sendable {
    private let storage = SelectiveRemoteTeamVaultMemorySnapshotStore()
    private let lock = NSLock()
    private var nextLoadHook: (@Sendable () throws -> Void)?
    func afterNextLoad(_ hook: @escaping @Sendable () throws -> Void) { lock.withLock { nextLoadHook = hook } }
    func load(endpoint: URL, teamID: UUID, vaultID: UUID) throws -> SelectiveRemoteTeamVaultSnapshot? {
        let value = try storage.load(endpoint: endpoint, teamID: teamID, vaultID: vaultID)
        let hook = lock.withLock { let previous = nextLoadHook; nextLoadHook = nil; return previous }
        try hook?()
        return value
    }
    func save(_ snapshot: SelectiveRemoteTeamVaultSnapshot, endpoint: URL) throws {
        try storage.save(snapshot, endpoint: endpoint)
    }
    func saveIfCurrent(_ snapshot: SelectiveRemoteTeamVaultSnapshot, endpoint: URL,
                       replacing expected: SelectiveRemoteTeamVaultSnapshot?) throws {
        try storage.saveIfCurrent(snapshot, endpoint: endpoint, replacing: expected)
    }
    func remove(endpoint: URL, teamID: UUID, vaultID: UUID) throws {
        try storage.remove(endpoint: endpoint, teamID: teamID, vaultID: vaultID)
    }
}
