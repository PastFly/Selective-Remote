# Access & Sharing product integration

Target: `0.32.0`. Baseline: `36e443406f4268d527ae44eef3d9cdc92fd1c680`.
Owner authorized implementation, tests, non-main PR and Continuity without additional micro-approvals. A fresh exact-head Owner gate is mandatory before merge.

## Product composition

Mac stays workspace-first. A reusable native Share/Who has access sheet opens from Host, Credential, Snippet, Forwarding and Folder contextual actions. Cloud adds Access within existing Team management with Members, Groups and Resources tabs. Reuse existing navigation, theme tokens, authenticated transport, Notification Center and Audit. No new primary sidebar cluster. PR #210 is a visual reference only.

The share sheet shows the resource, a searchable paged user/group picker, selected chips, a resource-specific preset and labeled custom permission controls. The access list shows every contributing direct user, group and inherited path, including equivalent alternatives. Devices are an explicit selection within Effective Access; a user's rights never borrow the administrator's device usability.

Every mutation has read-only server preview, complete consequences, explicit confirmation, then signed-snapshot commit. Changing Team, Vault, recipient, permission or selection invalidates preview. A stale/expired/invalidated token requires a new preview, never an automatic altered commit. Pagination is bounded; empty filtered pages with a next cursor are not terminal. A failed batch changes nothing. Large selections require an intentional smaller selection, not silent partial success.

## Exact permission contract

| Kind | Bits | View preset | Edit preset | Manage preset |
|---|---|---:|---:|---:|
| HOST | View=1, Edit=4, ManageAccess=8 | 1 | 5 | 13 |
| CREDENTIAL | ViewMetadata=1, Reveal=2, Edit=4, ManageAccess=8 | 1 | 7 | 15 |
| SNIPPET | View=1, Edit=4, ManageAccess=8 | 1 | 5 | 13 |
| FORWARDING | View=1, ManageAccess=8 | 1 | absent | 9 |
| FOLDER | View=1, Manage=32 | 1 | absent | 33 |

Credential Edit requires Reveal, enforced by UI and server. No Credential.Use, Host.Connect, Snippet.Run or Forwarding.Run security permission. Folder Manage means structural management, not descendant ManageAccess. ManageAccess remains descriptive policy intent; Owner/Admin and the existing Team policy ceiling authorize preparation mutations. Do not promise delegated management.

Only container View inherits through all live Folder levels; it maps to Credential.ViewMetadata or the descendant kind's View. Reveal/Edit/ManageAccess/Create/Folder.Manage do not inherit. Revoke one path must say access remains when another equivalent path survives. Policy gain/loss counts come from server effective deltas, not deleted grant counts.

## Policy, crypto and lifecycle

`policyEffective` is user-scoped. `deviceUsability` is returned only for an explicit subject device. Show separate Policy, Key and Usability labels. `WRAP_PRESENT_UNVERIFIED` means key unverified and crypto-dependent usability UNKNOWN. Missing/unadmitted key means NO. Without a queried device show not checked, not YES. Plain policy permission never proves decryptability.

Existing production Vaults remain V1. Show “Granular access requires Vault v2”, and client-side migration blockers only when an already authorized, unlocked legacy document is available. No migrate/enable/activate button. Add a read-only scoped Access Vault directory and context API rather than changing the legacy V1 collection.

V2_PREPARING supports the existing dormant policy API and displays preparation intent. V2_READY shows controlled-activation readiness and blockers. V2_ACTIVE fixtures render the normal access surface, paths and device usability. **The merged active encrypted generation is frozen and has no fix-forward recipient publication API.** Preserve that boundary: real READY/ACTIVE group/grant/move writes return a useful `crypto_publication_required`/publication gate and never silently mutate recipients. Do not relax legacy AccessStore PREPARING predicates or expose operator migration APIs. Production activation and complete active-generation ACL delivery require their own crypto publication gate. This limitation must appear in the candidate report; fixture success is not production activation evidence.

The active reader compares the complete Team group/edge/policy-revision snapshot. Therefore any group mutation, even unrelated group create/rename, is blocked while a Team has a current ACTIVE publication or live READY attempt. Serialize the final freeze check and mutation using a group-table ROW EXCLUSIVE lock that conflicts with publication's SHARE ROW EXCLUSIVE lock; the Team row lock alone does not exclude publication. Expose group-mutation availability separately from PREPARING grant availability; a PREPARING context must not invalidate another published Vault.

## Backend additions needed by product integration

The native per-Vault Access entry can select registered resources from the bounded authenticated metadata directory and verify the exact row before opening the real resource sheet. This provides API-backed routing while legacy contextual models lack a persisted V2 identity mapping. It does not associate registry IDs with legacy records or reveal V1 names as V2 labels.

Current `listAccessResources` and exact `getAccessResource` use the server's PREPARING-only authorization context. READY/ACTIVE can expose lifecycle context, but these registry metadata reads still reject there. Therefore the native picker is deliberately mounted only for PREPARING; showing it for READY/ACTIVE would be a nonfunctional route. A future authorized READY/ACTIVE read surface needs a separate, reviewed server contract and active-generation crypto publication design. This task does not relax the merged AccessStore predicate or imply active resource delivery.

1. Authenticated scoped read-only Access Vault/context directory, including lifecycle and explicit operation availability, with no ciphertext/key material. Resource metadata supports both bounded pages and an exact Team/Vault/resource lookup with identical authorization, so editing an off-page grant never guesses its policy kind or scans the entire inventory.
2. Bounded server group search, group-member list and registry resource list (opaque IDs, kind, parent and version only). Reuse existing bounded Team member search. Never send encrypted-name search text to the server; search authorized decrypted labels locally and label that scope honestly.
3. Signed group-operation preview and commit for create/rename/delete/member add/remove. Bind actor membership/device, Team revision, Vault context, group/edge/subject versions, affected Vault policies and request. Recheck after locks within the same mutation transaction. Existing HTTP mutations must not provide an unsigned bypass.
4. Show affected grants/resources and effective deltas for group changes within existing bounds. Overflow fails closed, including `group_grants_must_be_revoked_first` with safe count and a paged bounded revoke workflow. Team groups do not become Vault-owned.
5. Correct revoke-only bulk audit classification; committed nonzero effective deltas alone produce notification candidates. Preview and equivalent-path removal produce none.

Server session is authoritative. Unknown/cross-Team/cross-Vault IDs, old memberships/epochs, stale roles and unsigned preview requests fail closed without enumeration. SQL invariants and existing locking/retry conventions remain in force. Do not add a second role hierarchy.

## Identity, Personal copy and moves

Resolve only exact Team/Vault/registry resource identities. A scoped display ID, Folder path or local forwarding rule ID is not an ACL UUID. If a materialized resource has no authoritative mapping, show the typed preparation prerequisite; never create fake policy IDs. V2 synthetic fixtures use explicit verified mappings for all five kinds.

Personal Share opens explicit **Copy to Team Vault** with Team/Vault/Folder selection. Keep the original. A new copy uses fresh resource IDs and remaps credential references; it must not overwrite a previous copy. After successful encrypted copy, offer access configuration for the resulting Team resource with honest V1 readiness. No fake Personal ACL and no deletion without an explicit future move flow.

Preserve accepted V1 DnD, drag payloads, reorder behavior and same-Vault constraints. Gate registered V2 ancestry moves through preview/confirm/commit before local persistence in both sidebar and main-list paths. Failed/stale preview or published-resource crypto gate persists nothing. Paths and Folder namespaces remain encrypted client state.

## Privacy, notifications and audit

Render resource labels only through a scope-validated local decrypted resolver. Otherwise show kind and opaque ID. A V1 plaintext document must not become an unauthorized V2 label catalog. No resource contents, secrets, preview tokens or keys in Audit/notifications/logs. DOM construction uses text nodes, not untrusted HTML.

Use existing Notification Center for committed effective gains/losses addressed to the current authenticated account only, with stable deduplication and no plaintext names in persistence. Group membership and other-user administration remain primarily Audit. Localize known group/grant/bulk/move Audit actions using safe metadata.

## Interaction and verification

Complete RU/EN, Light/Graphite, restrained text/icon states. Mac keyboard, VoiceOver labels, focus, Escape/Enter/Space. Cloud semantic controls, ARIA, focus restoration/trapping, mobile and reduced motion. Native normal/narrow and Cloud desktop/tablet/mobile must render actual product components. Include loading/empty/error, V1/preparing/ready/active fixture, direct/group/multiple paths, unavailable key and UNKNOWN.

Scale fixtures: 5/100/1000 members and 50/500/5000 resources with bounded pages and no giant matrix. Test stale responses across Team/Vault changes, malformed DTOs, denied plaintext canaries, stale role/member/preview, cross-scope IDs, alternate paths, batch overflow, group delete overflow, Personal copy identity and both DnD paths.

Local synthetic rendering is `LOCAL_VISUAL_PREVIEW`, never `AUTHENTICATED_STAGING_E2E`. Define test session mode and origin before browser acceptance. Real HTTPS staging acceptance is deferred until separately authorized deployment and Owner credentials/manual validation.

## Draft PR #210 parity and remaining design inputs

PR #210 remains an open Draft reference. Its synthetic interaction prototype is superseded for the current release by the authenticated Cloud Access Manager and native resource sheet. The table records the usable design input without treating the prototype as production evidence.

| PR #210 material | 0.32.0 status | Remaining decision |
|---|---|---|
| Synthetic Mac/Cloud Share, Who and Effective flows | Real authenticated Cloud and native components implemented against the PREPARING API; registered resources can be chosen from the native per-Vault server directory. Legacy item menus explain missing identity mapping. | Verify the rendered acceptance matrix and the later persisted V2 mapping/materialization before item-specific routing. |
| Permission vocabulary and policy-only Effective display | Five resource masks, all contributing paths and separate device usability follow the approved #217 contract. | Do not reuse prototype Forwarding/Folder labels that differ from #217. |
| Per-part CEKs, direct device wraps and revocation comparison | Design input only; no production CEK delivery or active-generation fix-forward publication. | Specify, implement and verify key publication, authenticated recipient binding, anti-rollback and recovery in separate bounded work. |
| Migration state machine and old-client rollout | Design input only; V1 remains whole-Vault. Copy retains the Personal original and creates fresh V1 record/linked Credential identities. | Specify recoverable V1→V2 migration, authoritative record/Folder registry mapping and old-client gates before activation. |

The current implementation's committed notifications use only effective deltas for the authenticated account; Audit labels are safe server action metadata. No stage, deployment or V2 activation was inferred from the local fixtures. Recommend closing #210 only after its unique crypto, migration and rollout inputs are extracted into accepted follow-up documents; do not merge or close it automatically.

Required gates: targeted tests, PostgreSQL 16 integration/concurrency/scale checks, full Cloud tests, full Swift regression, Release build, rendered matrix, independent review, formal exact-head Codex Security scan, CI, Test DMG, verified Continuity and fresh Owner gate. Final #210 audit extracts useful remaining docs and recommends closure; no wholesale merge or automatic closure.

## Invariants

`TARGET_RELEASE=0.32.0`
`PRODUCTION_V2_ACTIVATED=NO`
`PRODUCTION_MIGRATION_RUN=NO`
`PRODUCTION_CEK_DELIVERY=NO`
`PRODUCTION_CLOUD_DEPLOYED=NO`
`TAG_CREATED=NO`
`RELEASE_PUBLISHED=NO`
`PUBLIC_FEED_CHANGED=NO`

No official signing/notarization. Next acceptance: Owner validates candidate, then separately authorized staging deployment and real V1→V2 E2E. Production fix-forward key publication remains an explicit prerequisite for active access mutations.
