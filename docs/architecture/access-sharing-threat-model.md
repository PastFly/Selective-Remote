# Access & Sharing: threat model and release blockers

Status: architectural review, 2026-09-29. No production ACL exists. Assets are E2EE Host/Credential/Snippet/Forwarding content, resource and grant integrity, Team identities, device admission, audit truth and availability. Adversaries include an authenticated low-privilege Team member, a former member with offline copies, a malicious modified client, a cross-Team caller, a compromised endpoint and a curious/compromised server. The current v1 whole-Vault key is outside a future granular secrecy claim; see [current state](access-sharing-current-state.md).

| Threat | Attack path | Required design control / residual limit |
| --- | --- | --- |
| Cross-Team ID injection | Caller submits another Team's resource/principal UUID. | Resolve IDs under authenticated Team scope in every query/transaction; compound constraints, non-enumerating errors and tenant tests. |
| Cross-Vault ID injection | Grant, move or envelope request substitutes Vault UUID. | Immutable `(team,vault,type,resource)` binding in registry and ciphertext associated data; no cross-Vault grant by ID alone. |
| Resource ID/type spoofing or collision | Client reuses a UUID to inherit ACL, or changes type to gain action mask. | Server allocation/registration or uniqueness check; immutable type/scope, tombstones, authenticated metadata, import creates new ID. |
| Stale group membership | Removed member uses cached group list/wrap. | Server recomputes current membership for every protected request; rotate affected resource CEKs; cached plaintext cannot be reclaimed. |
| Stale membership epoch/device | Re-admitted or removed device replays an old session/wrap. | Bind direct grants, wraps and device admission to epoch/generation; reject stale tokens and rekey affected future versions. |
| Stale wrapper/key generation | Old wrapper decrypts a future record after revoke. | Fresh CEK/ciphertext and key version on revoke; never reuse old CEK for a new restricted version. Old ciphertext remains exposed to old holders. |
| Grant replay / revoke replay | Delayed request restores a tombstoned grant or overwrites newer policy. | Monotonic policy version, stable grant ID, idempotency scoped to payload, expected-version compare-and-swap, append-audited tombstone. |
| Old-client bypass/downgrade | 0.32 whole-Vault API returns restricted v2 data or accepts stale upload. | Separate v2 capability/schema/wrapper and endpoint gate; no v2 content in v1 document; block v1 writes after cutover. |
| Malicious modified client | Authorized client bypasses hidden Connect/Run/Use button and extracts decrypted data. | Never call UI controls a confidentiality boundary; enforce only server-gated operations and CEK isolation; broker/target control needed for security-grade Use. |
| Folder move privilege escalation | Resource enters inherited grant with broader audience unnoticed. | Stable parent IDs, full before/after preview, explicit widening confirmation, actor ManageAccess, atomic parent/policy/wrap transaction. |
| Bulk grant mistake | Wrong principal, scope or descendants receives secrets. | Exact IDs/counts and recipient per preview, permission delta, plaintext exposure warning, snapshot-bound token, bounded batch and audit. |
| Confused deputy/key custodian | ManageAccess actor asks another client to wrap secret to unauthorized device. | Custodian verifies signed/current server policy, member epoch, device binding and resource associated data; no ambient privileged wrap API. |
| Server metadata leakage | Server learns org graph, resource types, access relationships and timing. | Minimize to IDs/type/parent/grant/version; encrypt names/addresses/body; document leakage, retention and access to logs. Server cannot hide all graph metadata while enforcing it. |
| Notification leakage | Revoked user receives forbidden Host name or deep link. | Generic post-revoke wording, check authorization at open, no secret/resource names in push payload, coalescing. |
| Audit spoofing/omission | Client supplies actor/timestamp or mutation commits without event. | Server derives actor/epoch/time; policy and audit event in one transaction; append-only controls, operator access and integrity review. |
| Offline plaintext/cache/export | Former member keeps prior decrypt or backup. | State explicitly that revocation stops future online access and future-key versions, not historical knowledge; trusted client best-effort cache purge only. |
| Compromised device | Malware reads app memory or exercises a non-exportable key. | Device revoke, short sessions, hardware isolation where applicable and future rekey; no guarantee against active compromised endpoint. |
| Credential Use without Reveal | UI hides Reveal but ordinary client receives secret. | Keep Use disabled in v1. Target-issued short-lived credentials or narrow broker need separate threat model and trust disclosure. |
| Partial rekey/cutover | Policy permits new member without a wrap, or old member still receives new ciphertext under old CEK. | Staged, versioned policy+crypto commit; `ROTATION_PENDING` blocks protected writes/grants; recovery custodian and durable operation state. |

## Security blockers before production ACL

1. Define and implement immutable server resource/Folder registry with authenticated `(Team,Vault,type,ID,parent,version)` binding; reconcile existing credential ID conventions and import/copy semantics.
2. Implement a distinct v2 per-resource E2EE format, client-generated CEKs, bound wraps, capability gate and v1 API isolation. A server metadata ACL on the current whole-Vault key is insufficient.
3. Specify the exact server permission/Team-role matrix and transaction protocol for policy, ciphertext, wraps, moves, rekey and audit. Prove no partial publication or stale-version authority.
4. Implement revocation rotation and recovery at realistic group/resource fanout, with explicit offline/historical-data limitations.
5. Validate Mac and Cloud client parity, including current Forwarding execution gaps, and block old clients from restricted v2 resources.
6. Test the attack paths above, including modified clients and cross-Team/Vault requests, before any security guarantee or release claim.

## Unresolved decisions for Owner/security review

- Exact retention and visibility of server metadata, encrypted group names, audit records and resource type/parent edges.
- Who may act as key custodian/recovery custodian, how key loss is handled, and whether group keys are acceptable versus device-level wrapping at expected scale.
- Whether Host/Forwarding execution needs target-side/gateway enforcement; whether any future Credential.Use broker may hold reusable secrets and thereby change E2EE scope.
- Which v2 Vaults migrate first, whether v1 legacy Vaults remain indefinitely, and the precise minimum ACL-capable Mac/browser builds and admission protocol.
- Rotation latency and availability targets, maximum group/bulk fanout, and administrator recovery for a missing custodian.

No unresolved decision is silently treated as implemented. Owner choice of architecture and security model is required before writing production ACL code.
