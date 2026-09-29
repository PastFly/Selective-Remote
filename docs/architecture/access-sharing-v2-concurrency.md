# Vault v2 policy, key and content publication protocol

Status: design only, 2026-09-29. This protocol is not implemented in the current whole-Vault API. It makes [key lifecycle](access-sharing-v2-key-lifecycle.md) and [Effective Access](access-sharing-effective-access.md) checkable without pretending that server policy alone proves a recipient can decrypt.

## Version tuple, not coincidental integer equality

| Field | Owner and update |
| --- | --- |
| `vaultPolicyVersion` | Server monotonic counter for Team/Vault grants, groups, membership impact and capability gate. |
| `registryVersion` | Server monotonic revision of a resource's immutable binding, parent and lifecycle state. |
| `accessRevision` | Server revision of the resource's effective recipient/policy snapshot, including path changes. |
| `contentRevision` | Monotonic version of each encrypted part's ciphertext; protected writes compare-and-swap affected parts. |
| `keyEpoch` | Monotonic CEK generation **per part**; increases whenever a previously entitled device must lose access to future versions of that part. |
| `manifestRevision` | Published pointer revision identifying **one exact tuple** of registry, access and every part's content revision, key epoch, ciphertext hash and wrap-set hash. |
| `membershipEpoch` / `deviceKeyID` | Existing identity/admission context, checked on every protected operation and bound into wraps. |

These counters need **compatible references**, not equal numeric values. An unrelated grant in the same Vault may advance `vaultPolicyVersion` without changing this resource's ciphertext. A grant addition may advance `accessRevision` and wrap set while reusing the affected part CEK and ciphertext. The reader must require that the current server policy snapshot, published manifest, resource row, action-relevant part ciphertext and selected current wrap refer to the **same committed tuple**. Client AEAD AAD binds content identity/parent/part/content revision/key epoch; an authenticated manifest binds each part's ciphertext hash and authorized wrap-set to the policy/registry revisions. A naive `policyVersion == envelopeVersion == resourceVersion` integer comparison would force unnecessary re-encryption or permit accidental mismatches.

## Prepare → validate → publish

1. **Preview, no mutation.** Server evaluates current policy at snapshot `S`, exact selected IDs/descendants/recipients, expected versions and required wraps/rekeys. Returns a short-lived token bound to actor membership+epoch/device, Team/Vault, request hash, `S`, affected IDs/counts and expiry. A token is not an authorization grant.
2. **Prepare hidden candidate.** Authorized client/custodian generates new ciphertext/CEK when required and recipient-specific wraps; uploads them to a staging generation inaccessible to ordinary list/get/wrapper APIs. For a pure add, stage wraps of the current CEK; for a loss of decryption, first publish the deny/`ROTATION_PENDING` state as described below, then stage fresh CEK/ciphertext and surviving wraps.
3. **Validate.** Server checks tenant and role/ManageAccess, active Team membership/epoch/device, immutable registry bindings, current group membership, expected versions, canonical recipient device set **per part**, wrapper context fields, ciphertext hash/size, no duplicate nonce tuple, complete required wrap rows, batch bounds, preview hash and idempotency payload. Credential Edit without Reveal is rejected. The custodian verifies recipient key identity and the policy intent before wrapping. Server cannot decrypt a wrap to prove its CEK is correct; clients verify actual unwrap/AEAD and report `KEY_UNAVAILABLE` if it fails.
4. **Publish one bounded transaction.** Lock Team/Vault policy and affected registry/manifest rows in a stable order. Re-evaluate current policy and descendants; any change since `S` returns `409` with no mutation and a new preview is required. Atomically write grants/group/parent changes, increment versions, switch every affected published manifest pointer, expose staged ciphertext/wraps and append server-derived audit events. No partially published batch. Large work uses a durable operation with bounded independently atomic chunks and a preview/authorization check per chunk; partial completion is never reported as all-or-nothing.
5. **Read.** Server selects one committed manifest under current membership/device/grant policy and returns only permitted ciphertext/current wrap. Client checks manifest references, AAD, key epoch and decrypt. Missing or mismatched tuple, wrap, capability, registry row or pending rotation blocks the affected protected operation and yields a typed repair state to authorized users.

An ordinary grant requiring decryption is **not published without a structurally complete staged wrap set** for currently eligible devices. This prevents a policy grant becoming visible while no key envelope has been issued. It does **not** guarantee every offline recipient can decrypt: a malformed wrap or device-key mismatch is only proven by recipient unwrap. Therefore API/UX distinguish `POLICY_ALLOWED`, `CRYPTO_AVAILABLE` (current matching wrapper present and locally validated where possible) and `EFFECTIVE_USABLE`. Policy-only ManageAccess can exist without a content wrap.

## Revoke is deliberately two-phase

The first atomic transaction revokes the path or member/device, advances policy and denies **future server delivery** of resources and old wraps; it sets `ROTATION_PENDING` where a now-unauthorized device could know a CEK. It cannot retract ciphertext/keys already fetched. Until a custodian publishes a fresh CEK/ciphertext/wrap tuple, new protected content writes and grant fulfillment on that resource fail closed. A second transaction publishes the fresh key epoch and returns it to `ACTIVE`. If a person still has another authorized path to the same resource, the evaluator may avoid rekey for that person; a device revocation still rekeys because that device itself loses entitlement.

The server must not equate policy denial with cryptographic erasure. If no custodian is online, the resource stays `ROTATION_PENDING`; no server-created recovery key or silent use of the old CEK. The Owner sees a repair action and bounded queue status. A historical snapshot encrypted to an old CEK remains readable by a former holder who retained it.

## API concurrency, preview and replay

Protected writes require `If-Match`-style expected `contentRevision`, `registryVersion`, `accessRevision`, `keyEpoch` and current policy snapshot. Move/Folder operations include all affected descendants in the read set. On any mismatch or expired preview token: `409`, no mutation, recompute preview; no silent conflict winner for ACL/crypto state. The request's idempotency key is scoped to actor+route+Team/Vault+canonical payload hash and stores pending/terminal result. Exact replay returns the same outcome, changed payload with same key fails. Revoked/tombstoned grant IDs and stale wrapped-key generations cannot be replayed into current policy.

The server's transactional publication protects against ordinary races, crashes and malicious **clients**. A malicious server can still lie about policy or roll back a complete previously valid snapshot unless an independently authenticated device-key directory and anti-rollback checkpoint are added. Those are explicit unresolved requirements before claiming malicious-server-resistant E2EE. [Threat model](access-sharing-threat-model.md).
