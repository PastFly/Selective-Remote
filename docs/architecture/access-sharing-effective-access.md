# Access & Sharing: effective access and preview contract

Status: proposed v2 algorithm, 2026-09-29. The current product has no resource ACL. This document describes a future server decision and client key check, not the JavaScript prototype's security behavior. See [target model](access-sharing-target-model.md) and [migration](access-sharing-migration.md).

## Identity and decision inputs

All IDs are immutable and server-bound to `teamID`, `vaultID`, coarse policy class and ciphertext version. Exact resource type stays encrypted. A member is identified by `membershipID + epoch`; a device by admitted device ID/generation. A session supplies no authoritative group, parent or grant claim. The evaluator loads them from one consistent policy snapshot.

Inputs: active Team membership/role/epoch; device admission and capability; Vault v2 state/access; active flat-group membership; active direct, group, Vault and ancestor-Folder grants; server-registered resource identity/parent/state; grant expiry; policy version; current ciphertext/key generation and recipient wrap availability. The server can verify existence and authorized delivery of a wrap but cannot prove the client successfully decrypted it. The client must check authenticated associated data and actual unwrap/decryption. The output therefore distinguishes `POLICY_ALLOWED`, `CRYPTO_AVAILABLE` and `EFFECTIVE_USABLE`; no UI may claim plaintext access from policy alone. `CRYPTO_AVAILABLE` is `UNKNOWN` until a recipient device verifies unwrap and ciphertext.

Team Owner/Admin grants policy administration only under existing Team policy. It does not silently grant decryption of every v2 resource. `activeV2VaultAccess` below means an admitted catalog/container entitlement, **not** possession of the legacy whole-Vault key. `ManageAccess` is never a synonym for `Reveal`, and a key custodian must supply valid wraps for any new decrypting recipient.

## Deterministic evaluator

`permissionMask` is intersected with the action set for the resource type. A Folder `View` maps only to descendant `View` or Credential `ViewMetadata`; Folder `ManageAccess` maps to descendant policy management, never Reveal. Vault `View` maps to discovery/ordinary View but never Credential Reveal; Vault `Create` and container `Edit` are container operations, not child Edit. Broader descendant Edit/Reveal requires an explicit resource grant in V1. `ViewMetadata` on a Credential means only its deliberately encrypted/sanitized catalog representation; it never includes a secret. An inherited Folder/Vault path applies only if the immutable ancestry chain is valid in the same Vault. No deny rules or nested groups exist.

```text
evaluate(teamID, membershipID, epoch, deviceID, resourceID, now, snapshot):
  r = snapshot.resourceBoundTo(teamID, resourceID)
  if r missing: return blocked("NOT_FOUND_OR_UNAUTHORIZED")
  if not activeMembership(teamID, membershipID, epoch): return blocked("MEMBERSHIP_OR_EPOCH")
  if not admittedDevice(teamID, membershipID, epoch, deviceID): return blocked("DEVICE")
  if not capability(deviceID, "resource_acl_v2"): return blocked("CLIENT_VERSION")
  if not activeV2VaultAccess(membershipID, epoch, r.vaultID): return blocked("VAULT")
  if r.state not in {ACTIVE, READABLE_ROTATION_PENDING}: return blocked("RESOURCE_STATE")
  if not validBoundAncestry(r, snapshot): return blocked("PARENT_OR_SCOPE")

  principals = {member(membershipID, epoch)}
             union activeFlatGroupsFor(membershipID, epoch, teamID)
  candidateEdges = activeUnexpiredGrants(principals, r, ancestors(r), now,
                                         snapshot.policyVersion)
  paths = []
  for edge in candidateEdges sorted by stable grantID:
    if not sameTeamVaultAndPolicyClass(edge, r): continue
    allowed = mapScopeMaskToTargetActions(edge.resourceType, edge.mask, r.policyClass)
              intersect permittedActions(r.policyClass)
    if allowed is empty: continue
    paths.append({grantID, principal, directOrAncestor, ancestorChain,
                  actions: allowed, expiry, policyVersion})
  policyAllowed = union(paths.actions)
  policyAllowed = applyExistingTeamRoleMutationCeiling(policyAllowed,
                                                        membership.role)
  if r.policyClass == secret and Reveal not in policyAllowed:
    policyAllowed.remove(Edit)
  cryptoAvailable = {}
  usable = {}
  for action in policyAllowed:
    part = encryptedPartNeeded(action, r.policyClass)
    if part is NONE: usable.add(action); cryptoAvailable[action] = NOT_REQUIRED; continue
    wrap = currentAuthorizedWrapInPublishedManifest(r, part, membershipID,
                                                   epoch, deviceID, snapshot.partKeyEpoch(part))
    cryptoAvailable[action] = wrap ? UNKNOWN_UNTIL_CLIENT_VERIFIES : NO
    if wrap and clientProvesCurrentUnwrapAndAEAD(r, part, snapshot.publishedManifest):
      cryptoAvailable[action] = YES
      usable.add(action)
  if rotationPending(r): usable.remove(protectedWriteAndGrantActions)
  blockedReasons = specificMissingPreconditionsAndActions(policyAllowed,
                                                          cryptoAvailable, r.state)
  return {POLICY_ALLOWED: policyAllowed, CRYPTO_AVAILABLE: cryptoAvailable,
          EFFECTIVE_USABLE: usable, contributingPaths: paths, blockedReasons,
          vaultPolicyVersion, registryVersion, accessRevision,
          partContentRevisions, partKeyEpochs, manifestRevision}
```

The `clientProves...` line is a **local client check**, not a server oracle. Server responses can report `POLICY_ALLOWED` and part-specific wrap presence, never assert `EFFECTIVE_USABLE` for another device. On a Credential, `ViewMetadata` checks only its metadata part; `Reveal` and `Edit` check the secret part. `ManageAccess` needs policy authority but no content CEK. The server enforces `policyAllowed` at list, envelope/wrap fetch, writes and grant changes using the authoritative snapshot. A write additionally checks expected registry/access/content/key versions and a current eligible custodian. The client displays usable content rights only after validating the current published manifest, wrap and authenticated ciphertext. Policy paths still appear when a missing/broken wrap blocks use, with `blockedReasons=KEY_UNAVAILABLE`, so the Owner can repair the key state. `ROTATION_PENDING` may allow still-entitled readers to use the prior current version but blocks new protected writes and grants. Response details are redacted for a caller who cannot discover the resource; external not-found and unauthorized shapes are indistinguishable. Exact version semantics are in [concurrency](access-sharing-v2-concurrency.md).

## Multiple independent paths

Illustrative Host `host-7` in Vault `Production`, Folder `ssh`. Member `alex` is in flat group `Support L2`. Two grants on this Host both carry `View`:

| Path | Grant | Explanation | Before group revoke | After group revoke |
| --- | --- | --- | --- | --- |
| 1 | group grant on Host | `Support L2 → Production → host-7` | Contributes `View` | Removed |
| 2 | direct grant on Host | `alex → host-7` | Contributes `View` | Still contributes `View` |

The union remains `View` after revoking path 1. A removal operation targets the exact `grantID`, never an action name on the member; the preview shows path 2 as a remaining alternative. A real restriction on connecting requires target credential/gateway control, beyond this v1 ACL.

## Preview and commit

Preview is a **read-only, bounded** server operation. Input: exact selected opaque resource IDs (or bounded, resolved descendant selection), recipient member/group ID, requested permission delta, operation kind (`grant`, `change`, `revoke`, `move`), expected policy/resource/key versions and idempotency context. Validate actor scope before resolving recipients/resources. Never accept client-computed effective rights or a path label as authority.

Output is paged and includes each affected `(member, resource, action)` before/after, every contributing path, paths remaining after revoke, recipients added/removed, inherited descendants, old/new parent, key/wrap/rotation work, expiry, warnings, exact count and a short-lived snapshot-bound preview token. Explicit warnings cover access widening on move, Credential plaintext exposure through Reveal, offline revocation limits, old-client lockout and missing key custodian. For a group change, expand only affected members at preview time; for large jobs use bounded pages and a signed aggregate count, then force an explicit chunked commit protocol.

Commit rechecks actor, membership epoch, device, resource identity, all expected versions, preview token/selection hash, descendant set and policy under a transaction. A changed snapshot invalidates the preview. Atomic small batch means all policy and corresponding ciphertext/wrap staging succeeds or none becomes visible. Large batches use a durable operation with individually tracked chunks; no chunk may claim access until its key state and policy agree. Audit events identify the committed delta. Replaying the idempotency key with a different payload fails.

The current [prototype](../prototypes/access-sharing-033/README.md) computes demonstrations from folder labels and browser-memory grants. It has no authoritative epoch, server envelope, key wrap or transaction. Its paths illustrate this output shape only.
