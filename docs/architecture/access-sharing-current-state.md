# Access & Sharing: current state and resource identity

Status: design evidence, 2026-09-29. Public `main` is `c554e26c3a36a95d439f35258137ec6625755fb5`. The detailed [read-only audit](https://github.com/PastFly/Selective-Remote-Continuity/blob/9b1fbbd78fc052fe7c4961b66966366631f4bbfe/checkpoints/2026-09-29-access-sharing-current-audit.md) was made at `99a6cb9e3297ebba32ff51af2c725893251ae4ba`. Subsequent PRs #209 and #211 changed sidebar Sync UI, rendering tests and one source-contract test; they did not change the authorization, Vault model or crypto files. The paths below were rechecked on the PR #210 branch, whose non-prototype source matches current main in these areas. This is not a production ACL.

## Authorization inventory

| Area | State | Exact source evidence |
| --- | --- | --- |
| Team roles | IMPLEMENTED | Owner/Admin/Editor/Viewer and operation matrix: `cloud/src/team-policy.mjs:1-18,41-65`. |
| Team membership and epoch | IMPLEMENTED | `cloud/migrations/005_team_foundation.sql:13-32`; new epoch on re-admission: `cloud/src/postgres-store.mjs:1488-1508`. |
| Vault membership | PARTIAL | All active Team members can list Team Vaults; independent Vault-member ACL absent: `cloud/src/postgres-store.mjs:1684-1703`. Device admission and wrapper gate decryption: `:1826-1859`. |
| Resource ownership/authorization | ABSENT at record scope | Record ID/type are inside encrypted document: `Sources/SelectiveRemote/CloudVaultRecordModel.swift:169-223`; whole-Vault API: `cloud/src/server.mjs:434-522`. |
| Credential | PARTIAL | Role gates organization edits, but Mac reveal/copy and browser copy lack Use/Reveal separation: `CloudTeamCredentials.swift:263-342,920-955`; `cloud/public/app.js:2207-2240`. |
| Host | PARTIAL | Role-gated Mac mutation, no per-Host server decision: `CloudTeamHostMutation.swift:32-319`; `cloud/src/postgres-store.mjs:1870-1907`. |
| Snippet | PARTIAL | Role-gated mutation, no per-Snippet grant: `CloudTeamSnippetMutation.swift:46-213`. |
| Forwarding | PARTIAL | Record type and browser editor exist, but Mac Team execution parity and per-rule authorization do not: `CloudVaultRecordModel.swift:20-29`; `CloudTeamHostMutation.swift:130-142`; `cloud/public/app.js:3650-3670`. |
| Folder | ABSENT as security principal | Host folders normalize path strings: `HostFolderTree.swift:2-40`; snippet folders are inferred from encrypted record paths: `cloud/public/team-snippet-browser.js:1-36`. |
| Server enforcement | IMPLEMENTED for Team/Vault; ABSENT for records | Active membership, device, role, wrapper, revision and key generation: `cloud/src/postgres-store.mjs:1826-1949`. Server sees an opaque whole-Vault ciphertext. |
| Mac enforcement | PARTIAL | Trusted-client role gates and Team sync materialization: `CloudTeamHostMutation.swift:32-35`; `CloudTeamVaultAutoSync.swift:116-249`. |
| Cloud browser enforcement | PARTIAL | Role-gated controls and local decryption: `cloud/public/app.js:1805-1811`; `cloud/public/team-vault-sync.js:336-360`. |
| Crypto boundary | IMPLEMENTED at whole-Vault scope | Wrappers bind Team/Vault/generation/member epoch/device: `cloud/public/team-vault-crypto.js:323-380`; one Vault key decrypts entire payload: `:451-492`. |
| Audit | PARTIAL | Existing Team Audit and whole-Vault revision events, no record-level events: `cloud/migrations/005_team_foundation.sql:134-148`; `cloud/src/postgres-store.mjs:1941-1947,2237-2252`. |
| Invitations | IMPLEMENTED | Email/link/username, role, expiry and admission: `cloud/src/service.mjs:438-508`; `cloud/src/postgres-store.mjs:1441-1578`. |
| Access groups and direct shares | ABSENT | No group/grant entities in `005_team_foundation.sql:13-114`; invitations create Team membership rather than resource grants. |

## Stable identity audit

| Type | Present identity | Rename, move, sync and conflict | Gap for ACL |
| --- | --- | --- | --- |
| Vault | Server UUID `shared_vaults.id` (`005_team_foundation.sql:95-114`). | Name can change without ID. Revisions and wrappers bind Vault UUID (`006_team_vault_crypto.sql:34-78`). | Existing key is whole-Vault; UUID is stable but not a granular access domain. |
| Host | `SelectiveRemoteVaultRecord.id` UUID; Mac Team host uses `ConnectionProfile.id` and retains `recordID` on edit/organize (`CloudTeamHostMutation.swift:32-139,183-240`). Browser upsert retains editing ID (`cloud/public/app.js:3640-3667`). | Record merge/conflict resolves by UUID (`CloudVaultRecordModel.swift:385-505`). Folder move within the same Vault preserves ID; cross-Vault drag is rejected (`CloudTeamHostMutation.swift:344-406`). | UUID is client-controlled and hidden inside ciphertext. Server must register and bind `(Team,Vault,type,ID)` to authenticated ciphertext; copied/cross-boundary Host needs a new ID. |
| Credential | Record UUID. Mac Host-linked credential derives an ID from Host UUID + kind (`CloudTeamHostMutation.swift:245-310`); standalone credential keeps ID on organize (`CloudTeamCredentials.swift:263-342`). Browser edits retain ID; new records get random UUID (`cloud/public/team-vault-sync.js:706-716`). | Same-Vault record update/merge retains UUID. Host-linked credential follows Host folder; browser and Mac may use different creation conventions. | Alias/migration map must reconcile derived and random IDs. Secret must become a separate envelope; a credential reference is not permission. |
| Snippet | Record UUID; Mac create/update retain `recordID` (`CloudTeamSnippetMutation.swift:46-213`); browser upsert retains editing ID. | Same-Vault rename/folder update and conflict resolution retain UUID. | Folder path is not an identity; server must bind ID/type to a ciphertext revision. |
| Forwarding | Record UUID; personal exporter uses `IndependentPortForward.id` (`CloudPersonalVaultSync.swift:154-293`), browser upsert uses random UUID or existing ID (`team-vault-sync.js:706-716`). | Vault record merge retains UUID. Current Team Mac execution parity is incomplete. | Do not promise Run authorization until executable rule semantics and enforcement are designed. |
| Folder | Host `group`/Snippet `folder` path string; no stable opaque Folder ID (`HostFolderTree.swift:2-40`; `team-snippet-browser.js:1-36`). | Rename or move changes the path; a path can disappear and reappear from records. | Assign immutable Folder UUIDs and parent IDs in ACL v2 migration. Never attach grants to path/display name. |

`RESOURCE_ID_MODEL`: existing opaque UUIDs are stable for ordinary in-Vault record edits and conflict resolution, but are not server-authenticated resource identities. Vault UUID is server-stable. Folder lacks UUID. `STABLE_IDS_EXIST`: partial. `GAPS`: folder identity, client-supplied record type/ID spoofing, cross-boundary copy/import semantics, credential ID reconciliation and server-visible ID-to-ciphertext binding. `MIGRATION_REQUIRED`: yes, for an ACL-capable format; do not rewrite frozen 0.32 or current production data in this phase.

For v2, allocate a new server-registered opaque resource ID when copying/duplicating, importing from Personal, crossing Vault or Team boundaries, or resolving an ID collision. Preserve ID on rename and same-Vault move. Keep an encrypted client-side legacy-ID mapping for migration/recovery only; never import legacy ACL grants implicitly. The server binds Team ID, Vault ID, resource type, resource ID, parent Folder ID and ciphertext version as authenticated associated data. Reuse of a tombstoned ID with another type/scope is forbidden.
