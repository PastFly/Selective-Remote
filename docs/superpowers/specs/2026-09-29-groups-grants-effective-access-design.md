# Groups, grants, Effective Access and preview foundation

Status: Owner-approved written architecture with eight review clarifications; `SPEC_GATE=APPROVED`. Target: Selective Remote 0.32.0. Baseline: public `main` `e5e9c21d524fc16973671780f3e32aaf8506f41c`. PR #210 remains Draft and is a UX reference, not production code.

## Purpose and boundary

Add a server-authoritative, allow-only policy foundation for flat Team groups, direct user/group grants, Effective Access explanations, bounded previews and audited commits. Existing Vaults remain `V1_ACTIVE` and retain their current whole-Vault behavior. Policy mutation routes accept only a scoped `V2_PREPARING` Vault; no route changes a Vault format state, publishes a production CEK, serves v2 content, migrates a real Vault or activates ACL enforcement. A policy row in preparation is not a claim that a recipient can decrypt.

The current Team roles are `owner/admin/editor/viewer`. Existing Owner/Admin checks remain the administrative root; this change adds no second Team role system. The current registry stores immutable UUID, Team/Vault, `folder/secret/general` policy class, parent Folder, version and tombstone. Existing Vaults default to `V1_ACTIVE`. Migration 017 already serializes registry, wrapper and manifest mutations on the Vault row and prevents a pointer to PREPARED ciphertext.

## Identity, schema and privacy

Add additive migration 018. Extend the registry with nullable, immutable `policy_kind` in `HOST/CREDENTIAL/SNIPPET/FORWARDING/FOLDER`. New policy-bearing identities must supply it; older internal rows may remain null but cannot receive a grant until classified by a future explicit migration. Database checks bind `CREDENTIAL→secret`, `FOLDER→folder` and the other kinds to `general`. The server now learns the resource category but never stores its name, address, command, username or content in policy tables. This is the Owner-approved metadata tradeoff needed for distinct server-enforced permission masks.

Create Team-scoped flat groups with UUID, normalized server-visible name, creator, timestamps, monotonic version and deletion tombstone. A group belongs to its Team, never to a Vault: the V2_PREPARING Vault supplied at creation is only an authorization/capability gate. No group row has Vault ownership or a Vault deletion cascade. Deleting or rolling back one Vault leaves its reusable Team groups and group edges intact; Vault-scoped grants follow that Vault lifecycle. Names are case-insensitively unique among active groups in one Team and limited to 120 characters. This exposes group names to the server and authorized administrators; it does not expose Vault content. A group edge stores group ID, Team ID, member user ID, the exact active membership ID and epoch, creator, timestamps, version and removal tombstone. Composite references and triggers prevent cross-Team membership and old-epoch resurrection. No nested groups, dynamic rules or group keys.

Create versioned grant rows with UUID, Team/Vault, `USER/GROUP` principal, principal ID, bound membership ID+epoch for USER, target kind `VAULT/FOLDER/RESOURCE`, target ID, permission mask, creator, timestamps, version and revocation tombstone. A Vault target uses its existing Vault UUID; a Folder or Resource target binds to a live registry row in the same Team/Vault. One active grant per natural principal/target key is enforced by a partial unique index. Explicit grants are the only stored edges. `sourceType=DIRECT` for a grant on the queried target and `INHERITED_CONTAINER` for a Vault/ancestor Folder path is derived by the evaluator; inherited copies are never stored. Recreating a revoked grant requires a new ID and explicit preview/commit.

Indexes cover Team and active group names, group membership by group and membership epoch, active grants by Team/Vault/target and principal, and registry parent traversal. Audit metadata contains only opaque IDs, type, permission delta and versions.

## Permission contract

The only hard V1 masks are:

| Target | Allowed bits |
| --- | --- |
| Host | View, Edit, ManageAccess |
| Credential | ViewMetadata, Reveal, Edit, ManageAccess |
| Snippet | View, Edit, ManageAccess |
| Forwarding | View, ManageAccess |
| Folder | View, Manage |
| Vault | View, Create, Edit, ManageAccess |

Credential Edit without Credential Reveal is an INVALID grant. Create and change reject that mask before writing; the evaluator rejects a malformed persisted grant rather than widening it. A database trigger enforces Edit ⇒ Reveal against the immutable Credential policy kind, where a row-local CHECK cannot safely reference the registry. ManageAccess never implies Reveal. Owner/Admin role remains an outer requirement for every group or grant mutation, even when a grant contains ManageAccess; an Editor/Viewer cannot acquire policy-administration authority from a grant. Folder Manage permits authorized structural operations but does not imply ManageAccess over descendants. Host.Connect, Snippet.Run and Forwarding.Run are UX-only convenience actions, not server security permissions. Credential.Use is absent and disabled.

## Allow-only inheritance and move

Effective rights are the union of every active direct user grant, current-epoch group path and applicable Vault/Folder ancestor path, then intersected with target-kind masks and outer gates. There is no explicit DENY. The exact inheritance mapping for an active Vault.View or Folder.View grant is:

| Descendant kind | Inherited bit |
| --- | --- |
| Host | Host.View |
| Credential | Credential.ViewMetadata |
| Snippet | Snippet.View |
| Forwarding | Forwarding.View |
| Folder | Folder.View |

The mapping propagates through any number of live Folder levels along the current same-Vault ancestor chain. Each Vault/Folder path remains separately explainable. Folder.View reaches its nested Folders and resources; a leaf View reaches no siblings. Tombstoned, cross-Vault or cyclic ancestry fails closed. Edit, Reveal, ManageAccess, Create and Folder Manage do not inherit. Rename does not alter access. A tombstoned or invalid ancestor contributes no path.

Before any parent change, the server computes before/after rights for the bounded affected subtree. Access widening or loss requires a preview and explicit commit with unchanged versions. A cross-Vault move is not a policy-only operation and is rejected. Migration 017 forbids changing a published registry identity under a current pointer. This PR therefore commits a move only for an unpublished `V2_PREPARING` identity; a published resource returns a typed `crypto_publication_required` result until a later atomic ciphertext/parent publication flow exists. No drag-and-drop path can bypass that gate.

## Effective Access

One evaluator reads authoritative Team membership/role/epoch, admitted device, client capability, Vault state, registry identity/ancestry, group edges, grants, current pointer and wrapper availability from a consistent database snapshot. It returns `policyAllowed`, per-permission `cryptoAvailable`, `effectiveUsable`, every contributing path with grant and principal IDs, and typed blocked reasons. A user with both group and direct View paths retains the direct path after group revocation; both paths are shown before, and the remaining one after.

The server can establish whether a current eligible wrapper exists, but cannot prove that a client decrypted it. `cryptoAvailable` is `NO` or `WRAP_PRESENT_UNVERIFIED`. `effectiveUsable` is exactly `YES | NO | UNKNOWN`: `KEY_UNAVAILABLE` or a failed outer authorization gate yields `NO`; `WRAP_PRESENT_UNVERIFIED` yields `UNKNOWN` for a crypto-dependent action; `YES` requires an action with no crypto dependency or authenticated client evidence for the current manifest, unwrap and ciphertext. Policy allowed alone never means crypto usability. Policy-only management actions can be usable without a CEK if the server gates pass. A missing wrapper leaves a policy path visible to an authorized administrator with `KEY_UNAVAILABLE`; it never turns into a content-delivery authorization. Unscoped or unauthorized callers receive indistinguishable not-found responses rather than an enumeration channel.

## API and authorization

Add authenticated Team group list/create/rename/delete and member add/remove endpoints, plus Vault-scoped grant list/create/change/revoke, Effective Access, preview and commit endpoints. Group and grant mutations require existing Owner/Admin role, active membership and current admitted device. Admin cannot change an Owner/Admin target's access beyond existing Team policy ceilings. Read/list APIs use Team/Vault predicates, bounded cursor pagination and minimal metadata. V1 Vaults receive a fail-closed format response and their existing endpoints remain unchanged.

Group names and membership are Team-scoped; grants, evaluation and preview are Vault-scoped. Group creation requires an explicit same-Team `V2_PREPARING` Vault context as authorization/capability evidence, not ownership; the group remains reusable by other preparing Vaults in that Team. No group or grant route changes V1 behavior, and no grant can attach to a V1 Vault. Group deletion tombstones the group, its edges and at most 1,000 active grants in one transaction and one bounded audit record set; above 1,000 grants the server returns typed fail-closed `group_grants_must_be_revoked_first`, with no partial deletion. Count with `LIMIT 1001` and expose only `1001+` on overflow. The caller must revoke grants in bounded batches of at most 1,000, each with fresh preview and authorization, then retry deletion. The mutation ceiling comes from existing Team policy, without a second role hierarchy:

| Team role | Group mutation | Ordinary member/resource grant mutation | Owner/Admin target mutation |
| --- | --- | --- | --- |
| Owner | Allowed with active membership, admitted device and V2 gate | Allowed within masks and preview gate | Allowed subject to existing Team invariants |
| Admin | Allowed with the same gates | Allowed within masks and preview gate | Denied by the existing Owner/Admin target ceiling |
| Editor | Denied | Denied | Denied |
| Viewer | Denied | Denied | Denied |

Tests cover all four roles and target classes through the existing Team policy; a grant never confers policy-administration authority.

The routes never accept client-supplied effective permissions, group claims, path labels or crypto success as authority.

## Preview, bulk and concurrency

Preview is read-only with respect to policy and returns before/after permissions for each affected user/resource, every alternate remaining path, counts, widening/loss, required key/wrapper work and warnings. It issues a short-lived stateless HMAC token bound to actor membership+epoch/device, canonical request hash, Team/Vault, Team policy revision, Vault policy version, registry versions, selected descendants and expiry. A domain-separated key derived from the existing server session secret signs the token; no token or secret enters Audit. Commit verifies the token and re-evaluates authorization and the same read set after locks. Expiry, server/session-secret rotation or restart, or any changed version/selection invalidates the outstanding preview and returns a typed conflict requiring re-preview, with no partial mutation. Commit always requires a valid server-signed token; unsigned or fallback commit is forbidden.

One Team policy revision advances on group/edge changes; one Vault policy version advances on grants and previewed moves. Policy writers use migration-017 Vault serialization, then the dedicated Team policy revision row, then sorted target IDs. Group-only writers lock the Team policy revision row without taking a Vault lock. Group deletion first locks every affected Vault row in sorted UUID order, then the Team policy row, and refuses an over-limit fanout. Protected commits recheck active membership/epoch/device and resource state inside the transaction. Direct SQL constraints/triggers preserve scope, mask, tombstone and version invariants; the application enforces actor role, preview token, output redaction and key-work classification. Bounded full-transaction retry handles `40P01/40001`; stale CAS remains a conflict.

One batch contains at most 50 resources, 20 explicit principals and 1,000 expanded user-resource pairs. Larger requests fail with a bounded-size error; no partial success is reported. A valid batch commits all policy rows, revision increments and audit records in one transaction or none. Durable idempotency receipts return the same result for an exact replay and conflict on changed payload. Lists and preview details page at 50 rows.

## Audit, notifications and verification

Extend existing Team Audit in the same transaction with `group.created/renamed/deleted`, `group.member.added/removed`, `grant.created/changed/revoked`, `bulk_grant.applied`, `bulk_revoke.applied` and `resource.move_access_changed`. Record actor, opaque principal/resource, permission delta and timestamp; no secret or plaintext resource content. Only a committed change to effective access can create a Notification Center candidate; preview creates none. Revoke of one path while an equivalent effective permission remains creates no access-revoked notification. Access granted/revoked for the current user is a Notification Center candidate only; group membership and another user's administrative changes are normally audit-only. This PR does not emit one notification per policy row or add UI.

Tests start with failing cases for Team/Vault/principal injection, stale epochs and versions, tombstones, duplicate grants/idempotency, all independent paths, missing wrapper, stale preview, move widening, group removal versus evaluation, concurrent grant changes and all-or-nothing bulk rollback. PostgreSQL 16 CI applies migrations 1–18 from a fresh database and runs the concurrency matrix. Representative `EXPLAIN (ANALYZE, BUFFERS)` covers effective user/resource, who-has-access, resources-by-principal and group listing with approximately 100 members and 1,000 resources where practical. Full Cloud tests, Swift regression, Release build, Test DMG and formal exact-head Codex Security scan gate the Draft PR. No merge to public `main` without a fresh exact-head Owner approval.

## Deferred production gates

This foundation does not activate V2, migrate real Vaults, deliver CEKs, provide a production Access Manager UI or enforce resource ACL on V1 content endpoints. Production policy publication with complete recipient wraps, trusted device-key deployment, root recovery, safe V1→V2 migration, old-client behavior and manual acceptance remain separate gates. PR #210 stays Draft. No production Cloud deployment, tag, release or public feed change is part of this work.
