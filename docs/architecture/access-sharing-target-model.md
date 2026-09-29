# Access & Sharing: proposed v2 target model

Status: architecture recommendation for Owner review, 2026-09-29. Nothing in this document is a present product entitlement. No backend ACL, migration or crypto change has been implemented. The current authority is the existing Team membership/epoch, device admission and whole-Vault wrapper model (`cloud/src/team-policy.mjs:1-18`; `cloud/src/postgres-store.mjs:1826-1949`). The recommended crypto transition is in [access-sharing-crypto-options.md](access-sharing-crypto-options.md).

## Principles and trust boundaries

1. **One identity root.** Use existing active Team membership IDs, roles, epochs and admitted devices. An access group is a Team-local set of these memberships, not a second user directory or invitation flow. Re-admission creates a new epoch; old grants cannot revive automatically.
2. **Separate policy from keys.** Server policy authorizes which opaque resource envelopes and wraps may be fetched or mutated. Client-side keys determine what ciphertext can be decrypted. Both gates must pass. An ACL row alone cannot narrow today's whole-Vault key.
3. **Minimal server visibility.** Register opaque Team/Vault/Folder/resource IDs, resource type, parent relationship, policy/key version, group membership, grant edges, expiry and timestamps. Keep Host address/name, Credential secret, Snippet body, Forwarding configuration, folder display name and private key encrypted. Server learns graph shape, type, counts and activity timing; this leakage is acknowledged.
4. **No silent widening.** Rename preserves identity. Copy/duplicate and cross-Vault/Team transfer create new resource IDs and receive no grants by default. Folder move/copy runs the preview contract; widening requires explicit confirmation, authorization and an atomic policy/key transaction.
5. **Truthful actions.** A button that a modified authorized client can bypass is UX policy, not a security boundary. Credential.Use without Reveal remains disabled until a separate protected operation model exists.

## V1 permission set

| Resource | Enforceable V1 | UX-only or deferred | Reason |
| --- | --- | --- | --- |
| Host | `View`, `Edit`, `ManageAccess` | `Connect` as UX action; security-grade Connect deferred | A viewer with address/config can launch another SSH/RDP client; real Connect restriction needs target credential/gateway control. Edit and grant mutations are server-checked. |
| Credential | `Reveal`, `Edit`, `ManageAccess`; separately encrypted metadata discovery may use `ViewMetadata` | `Use` disabled | A CEK recipient can reveal; Edit of a secret implies ability to handle plaintext unless rotation is separately brokered. ManageAccess is policy authority, not automatic decryption. |
| Snippet | `View`, `Edit`, `ManageAccess` | `Run` UX-only | A reader can copy and execute the body outside the app. |
| Forwarding | `View`; `Edit`/`ManageAccess` only after Mac/Cloud rule parity is specified and tested | `Run` UX-only or later brokered | Current Cloud record is not yet an executable Mac Team rule. No false runtime control. |
| Folder | `View` (discover permitted descendants), `ManageAccess` | Folder rename/move is an admin operation | Stable Folder ID and server-visible parent relation are required; View alone grants no secret/Connect/Run. |
| Vault | `View` container/discovery, `Create`, `Edit` scoped container metadata, `ManageAccess` | Whole-Vault v1 write does not carry into restricted v2 | A v2 Vault has no universal content key. Owner/Admin remain policy administrators under existing Team rules. |
| Team | Existing `owner/admin/editor/viewer` roles and active membership | A second admin/role graph is removed | Existing role policy and last-owner constraints remain authoritative. |

`V1_PERMISSION_SET`: the enforceable cells above, once v2 crypto/server protocol exists. `UX_ONLY_PERMISSIONS`: Host.Connect, Snippet.Run and Forwarding.Run when implemented as local launch controls. `DEFERRED_PERMISSIONS`: Credential.Use, security-grade Connect/Run, and Forwarding Edit/ManageAccess until execution parity. `REMOVED_PERMISSIONS`: explicit DENY, nested/dynamic groups, a second Team membership model, implicit `ManageAccess ⇒ Reveal`, and a universal v2 Vault decryption key.

## Flat groups and canonical grants

Group: immutable `groupID` UUID, `teamID`, encrypted display name or minimal server-visible name by explicit privacy decision, `createdBy`, `createdAt`, version, and a server-visible set of active `membershipID + epoch` edges. No nesting or dynamic rules. Owner/Admin may create/rename/delete groups, add/remove eligible Team members and assign grants using existing `manage_member`/new grant policy rooted in `cloud/src/team-policy.mjs`; Admin cannot alter Owner/Admin access or grant themselves authority outside their Team role. Group deletion revokes its grants and follows the rekey protocol. Last eligible key custodian cannot be removed without a replacement plan.

Canonical grant is a unique, versioned, append-audited record:

```text
grantID, teamID, vaultID, principalType(member|group), principalID,
membershipEpoch (for direct member grant), resourceType(vault|folder|record),
resourceID, permissionMask,
createdByMembershipID, createdAt, expiresAt?, revokedAt?, policyVersion
```

`sourceType` in Effective Access is **derived**, not a caller-supplied or stored authority: principal type yields direct/group, and the grant's resource versus the target's ancestry yields resource/Folder/Vault origin. Folder/Vault grants are explicit edges whose applicability is computed from server-registered ancestry. One active natural-key grant per `(team, vault, principal type/ID/epoch, resource type/ID)` can be updated idempotently; `grantID` remains stable for revoke and audit linkage. Idempotency keys are scoped to actor+operation+request hash, so a changed payload cannot reuse a key. Revocation is a tombstone/version increment; replay of an old create/update cannot resurrect it. Validate Team/Vault/principal/resource membership and type in one transaction. Grant expiry is server-enforced on every protected operation, not a UI timer. Audit references grant ID and permission delta without plaintext.

Inheritance is **allow-only**. A Vault-level grant is an explicit administrative/broad read grant, never inferred from Team role alone in a restricted v2 Vault. A Folder `View` grant gives descendant discovery and the target type's ordinary `View` (Credential `ViewMetadata` only); Folder `ManageAccess` grants policy management over its subtree but no secret plaintext. A child resource still needs a decryptable CEK wrap for content. Broader descendant Edit/Reveal must be explicit resource grants in V1. No explicit DENY. Effective rights are union of active direct, group, Vault and ancestor-Folder paths *after* Team/device/Vault/key prerequisites. A path contributes only actions allowed by the resource type and the actual cryptographic access state. Granting `ManageAccess` cannot imply `Reveal` or mint a wrap without a key custodian.

## Move, copy and delete

- **Rename:** keep immutable ID, policy and CEK; update encrypted name and version only.
- **Within same Folder / between Folders in one Vault:** keep resource ID; compute before/after for every affected principal/action, including inherited paths and wraps. Require explicit confirmation for any widening, `ManageAccess` authority, expected policy/resource versions and an atomic metadata/crypto commit. If encryption state cannot be updated, reject the move.
- **Between Vaults or Teams:** create a new ID and CEK in the destination, client decrypts/re-encrypts under destination policy, stages destination ciphertext/wraps, commits destination, then tombstones source. Never temporarily serve destination through legacy whole-Vault API. Explicit grants must be reselected; they do not follow automatically.
- **Folder delete:** reject nonempty folder or require a previewed move of descendants to a chosen parent, then revoke folder grants and rotate affected keys. Never silently promote children to a more permissive parent.
- **Duplicate/copy/import:** new ID and CEK, no inherited direct grant from source. Destination parent grants apply only after preview; identity collisions fail, not overwrite.
- **Offline or stale client:** no protected write/move/grant against stale policy version. Rejoin through current epoch/capability and reconcile only ciphertext versions it remains authorized to access.

## Bounded server API design (no URLs fixed)

| Surface | Inputs and enforcement | Output |
| --- | --- | --- |
| Groups list/create/update/delete/member edges | Team-scoped, Owner/Admin policy, epoch/version preconditions, idempotency, page cursor and rate limit | Opaque IDs, minimal metadata, policy version; no cross-Team enumeration |
| Resource catalog and envelope fetch | Active membership/device, Vault gate, effective grant, key/wrap availability, pagination | Only permitted metadata, ciphertext and recipient wrap; no whole restricted Vault document |
| Grants create/change/revoke/list | Team/Vault/resource/principal IDs resolved server-side; ManageAccess, version/idempotency, expiry bounds, key-custodian proof/staged wraps | Stable grant ID, audit event, rotation state and new policy version |
| Effective Access explanation | Owner/Admin or self-scoped view; same evaluator as enforcement, bounded page | Effective actions, every contributing path, blocked reasons, version, no secret |
| Access preview and bulk grant/revoke/move | Exact resource ID set, principal, requested action mask, expected policy version; read-only evaluation | Before/after per affected member/resource/action, alternative paths, required key changes, warnings, expiry and preview token bound to snapshot |
| Commit preview | Validate preview token, expected versions, selected IDs and authorization again in one transaction; stage ciphertext/wraps as needed | New policy version, per-resource result and audit IDs; fail all or explicit bounded chunk protocol |

Use uniform unauthorized/not-found responses where existence would leak data. Enforce tenant isolation in SQL constraints and query predicates; client IDs are never trusted as scope. Bounded batch sizes and cursor pagination are required. Audit emission and policy mutation share the same transaction. Do not use a stale preview as authority.

## Audit, notification and scale

Extend existing `team_audit_events` with `group.created`, `group.member.added/removed`, `grant.created/changed/revoked`, `resource.moved` and crypto-rotation lifecycle. Record actor membership/epoch, opaque principal/resource IDs/type, permission delta, policy version and timestamp; no secret, address, command body or private key. `GRANT RECEIVED`: notify recipient once when actionable. `REVOCATION`: notify affected recipient once when meaningful, without leaking now-forbidden resource details. `GROUP MEMBERSHIP CHANGE`: audit-only by default, notify only if it changes actionable access. `ACCESS REQUIRES ACTION`: notify responsible Owner/Admin. Coalesce/rate-limit and re-evaluate authorization when an item opens. Ordinary edit and repeated projection churn stay Audit/Activity, not Notification Center spam.

At 10 users/100 resources, direct indexed checks are sufficient. At 100/1000, index `(teamID,vaultID,resourceID)`, `(principalID,active)`, `(groupID,membershipID,epoch)`, `(parentFolderID)` and active grants; cache a versioned effective projection per affected principal/resource, update incrementally on grant/group/move/epoch/key events. At 1000/10000, use bounded background recomputation and page only requested slices, with generation/version invalidation and no O(users×resources) transfer or whole-Vault decrypt per render. A stale projection cannot authorize access: writes and envelope fetches re-check authoritative current policy. Measure fanout and key rotation cost before claiming scale readiness.

These decisions are provisional until Owner reviews the design. The [prototype](../prototypes/access-sharing-033/README.md) remains synthetic and in-memory; its path labels and preview algorithm demonstrate UX, not server enforcement.
