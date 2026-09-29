# Vault v2 resource key and wrapper lifecycle

Status: implementability proposal, 2026-09-29; no crypto code or format changed. Current whole-Vault AES-GCM payload and wrappers are tied to Team/Vault/key generation/member epoch/device (`cloud/public/team-vault-crypto.js:323-380,451-492`). They cannot enforce granular content secrecy. The following is a **new, isolated** v2 protocol; its concrete cipher suite and key-directory authentication require security review before implementation. AEAD associated data and nonce uniqueness follow [RFC 5116](https://www.rfc-editor.org/rfc/rfc5116.html); [RFC 9180](https://www.rfc-editor.org/rfc/rfc9180.html) is a candidate standard for device key encapsulation, not an implemented choice.

## Hierarchy and object binding

```text
Existing Team membership + epoch + admitted device  -> outer online gate
Vault v2 catalog/policyVersion                      -> scope, not decryption key
resourceID + part + keyEpoch -> random CEK          -> one encrypted part
eligible device public key -> recipient-specific wrap of that part CEK
```

An admitted, authorized key-custodian client generates a fresh random 256-bit CEK for each new encrypted **part**. Host/Snippet/Forwarding and Folder metadata have one part; Credential has independently encrypted `metadata` (label and nonsecret details) and `secret` (password/private key/passphrase) parts. `ViewMetadata` distributes only the metadata CEK; `Reveal` distributes the secret CEK. `Edit` of Credential requires `Reveal` plus mutation permission, so it cannot be granted as a blind independent secret edit in V1. It encrypts each current part with a unique AEAD nonce. Authenticated associated data binds protocol/schema, Team ID, Vault ID, resource ID, immutable policy class, direct parent ID, **part label**, part content revision and part key epoch. The server stores ciphertext, nonce/tag/hash, an opaque resource/key manifest and individually bound device wraps; it never needs plaintext or CEK. A Vault-level catalog/admin right is **not** a Team root key and cannot decrypt every resource. Do not derive resource CEKs from the legacy Vault key, a Folder key or a shared Team root.

Each wrap binds Team/Vault/resource/**part**/part key epoch plus member ID/epoch, admitted device ID/key identity, policy class, wrap-suite version and expiry if any. The server must deliver only the current published wrap authorized for that actor, resource and action-relevant part. The client checks the full context, registry/payload AAD and published manifest before decrypting. The existing P-256 ECDH device material suggests an interoperable starting point, but v2 must independently review algorithm, nonce generation, device-key authenticity and cross-platform vectors. `extractable=false` or hiding a field does not make a decrypted secret invisible to the authorized client ([Web Cryptography Level 2](https://www.w3.org/TR/WebCryptoAPI/)).

An authorized custodian signs or otherwise authenticates grant intent and the recipient device-key binding before creating wraps. The current server-supplied device directory is **not yet an independently verifiable key-transparency system**. Without additional authentication, a malicious server or compromised administrator able to substitute device keys can trick a custodian into wrapping to an attacker key. Thus malicious-server-resistant E2EE is an unresolved security claim and a production blocker; the interim trust model is honest-but-curious server plus uncompromised custodian/device directory.

## V1 group crypto choice: direct device wraps

Let `R` be resources reachable via a grant, `P(r)` encrypted parts of resource `r`, `D(r,p)` admitted devices with the relevant action for part `p`, and `A` the resource parts on which a removed principal loses **all** decrypting paths. Counts below exclude replicas and history. A group is a **policy principal only** in V1; it has no decryption key. Its membership is expanded to eligible devices when staging wraps. The same recipient may have direct and group paths, but gets one current wrap per resource/part/device/key epoch, deduplicated across paths.

| Strategy | WRAPPER_COUNT | GROUP_MEMBER_ADD_COST | GROUP_MEMBER_REMOVE_COST / REVOKE_COST | OFFLINE_SUPPORT | COMPROMISE_BLAST_RADIUS | ROTATION_COMPLEXITY |
| --- | --- | --- | --- | --- | --- | --- |
| A. Per-device wraps **chosen V1** | `Σr Σp∈P(r) D(r,p)` | One wrap per new eligible device and authorized part; no CEK rotation for pure add | Re-evaluate alternate paths; for each part in `A`, fresh CEK+ciphertext and wraps for remaining devices | Already fetched authorized versions only | One device exposes only parts wrapped to it | High fanout, one key regime; bounded per-part queue |
| B. Flat-group key | Approx. one resource→group wrap per grant plus one group-key wrap/device, with overlap overhead | Rewrap group key to device; current resources become readable | New group key **and resource CEKs** for resources the removed member learned; rewrapping unchanged CEKs is insufficient | Same historical limit | Group key exposes all group resources | Group generation plus resource generations and overlap handling |
| C. Access-domain/sub-Vault key | One wrap/device/domain plus resources/domain | Usually cheap inside same domain | Rotate domain and all content keys previously learned by removed member | Same historical limit | Domain compromise affects whole domain | Broad rekey on move/removal; direct exceptions proliferate domains |
| D. Hybrid group/domain + per-device | Depends on partition and overlap | Some grants cheap | Both rotation protocols and cross-domain transitions | Same historical limit | Maximum of chosen domain/group/device exposure | Multiple generation protocols and confused-deputy cases |

For 100 members × 1,000 **single-part** resources, two admitted devices each and universal grants, A would mean up to 200,000 current wraps; 1,000 × 10,000 with the same assumptions could reach 20 million. Credential metadata/secret parts add their own rows according to their distinct audiences. These are **worst-case illustrations**, not measured capacity. V1 needs bounded grant/bulk sizes, paged recipient manifests, rekey queue limits and a performance gate before rollout. Choosing a group key solely to reduce rows would hide its removal and compromise costs.

## Lifecycle by event

| Event | CEK, wraps and policy response |
| --- | --- |
| New resource | Client proposes new registry ID, CEK and ciphertext; stages wraps for current eligible devices; publish only with matching policy/manifest version. |
| Direct or group grant / group member add | Resolve all affected devices from current Team epoch/admission and each newly permitted part. Authorized custodian stages wraps of the **current part CEK**, deduplicated per device; policy and wraps become visible together. No wrap means `POLICY_ALLOWED` but not `EFFECTIVE_USABLE`. |
| New device admission | Existing Team admission is only the outer gate. Device initially has no v2 resource wrap; authorized online custodian validates membership/epoch and device key, stages wraps for resources with active effective grants. Until published, `KEY_PENDING`; never give a whole-Vault substitute. |
| Direct grant/group membership removal | Server transaction immediately stops future API/wrap delivery for rights actually lost. If an alternate path still authorizes the same member/device, no CEK rotation is required for that reason alone. Otherwise affected resources enter `ROTATION_PENDING`; custodian creates new CEKs/ciphertext and surviving-device wraps. |
| Team exclusion, Vault access removal, epoch advance | Revoke online session/resource API; invalidate old-epoch wraps. Rotate every resource CEK the removed epoch could know before publishing future content, irrespective of previous group paths. Re-admission never reuses old wraps. |
| Device revoke | Even if its member retains other devices, rotate CEKs for resources the revoked device could know, then wrap only current admitted devices. |
| Same-Vault move | Preserve resource ID. Recompute inherited audience and preview. Parent change requires fresh payload authentication; if any principal loses or gains decryption, use a fresh CEK and wraps. A Folder move may require bounded descendant rekey. |
| Copy/duplicate/import/cross-Vault transfer | Fresh resource ID and CEK; re-encrypt under destination Team/Vault/parent AAD; no old wraps or grants copied. |

Revocation has two phases with different guarantees: the server policy transaction stops **future online delivery immediately**; key rotation protects **future ciphertext versions** when a custodian completes it. While rotation is pending, no new protected content version or grant fulfillment may publish under the old CEK. Existing authorized readers may keep the last version according to policy, but a removed/offline client may already have old ciphertext, CEK or plaintext. No protocol can erase that copy. A compromised custodian/endpoint can leak plaintext and requires incident handling beyond key rotation.

### Exact revocation matrix

`NEW_KEY_ACCESS_STOP` below means no new wrap is served to the excluded device/epoch and no new content version is published under a CEK it could know. It does **not** mean its old CEK disappears. `OLD_CIPHERTEXT_RISK` is present whenever that device previously fetched ciphertext or plaintext.

| Event | SERVER_ACCESS_STOP | NEW_KEY_ACCESS_STOP | KEY_ROTATION_REQUIRED | CONTENT_REENCRYPT_REQUIRED | OLD_CIPHERTEXT_RISK | OFFLINE_CLIENT_LIMITATION |
| --- | --- | --- | --- | --- | --- | --- |
| User removed from flat group | Immediate for rights lost after union of alternate paths | Immediately deny new wraps; hold new writes until rotation | Only resources where this member/device loses its final decrypting path | Yes on those resources | Former group member may retain old CEK/ciphertext | No remote purge |
| Direct grant revoked | Same path-union rule | Same | Only if no other decrypting path remains | Yes when rotating | Prior direct recipient may retain old version | No remote purge |
| Team member excluded | Immediate for all Team v2 resources | No old-epoch wrap; hold writes until affected rotations | Every CEK that excluded epoch/device could know | Yes | Entire formerly accessible set | No remote purge |
| Device revoked | Immediate for that device, even when member remains | No wrapper to revoked device; hold writes until rotations | Every CEK that device could know | Yes | Revoked device retains downloaded data | Device may never reconnect |
| Resource/Folder moved | Commit checks new policy and stops narrowed paths; widening is previewed | No new version under old audience when audience changes | Yes if effective decrypting device set changes | Always for moved payload's new-parent AAD; descendants when their audience changes | Narrowed readers may retain old-location ciphertext | Offline copy unaffected |
| Vault access removed | Immediate for the Vault catalog/resources | No new wraps; hold writes until affected rotations | All CEKs exposed through removed Vault entitlement | Yes | Prior Vault copies remain | No remote purge |
| Membership epoch advanced | Immediate for old epoch | Old-epoch wraps invalid; hold writes until affected rotations | All CEKs known to old-epoch devices unless they remain legitimately authorized through separately revalidated admission | Yes for affected keys | Old epoch may keep prior versions | No remote purge |

Policy-only rights that never delivered a CEK do not by themselves require content re-encryption on revoke. A recipient who still has an independent authorized path remains entitled and need not be excluded by a group/direct-path revocation. A revoked **device**, however, must be excluded even if its user keeps access through other devices.

## Credential V1 and future extension

Credential v1 has encrypted metadata plus a separately keyed secret payload. `ViewMetadata` requires only the metadata CEK. `Reveal` authorizes secret CEK delivery and therefore allows the recipient to read plaintext. `Edit` requires `Reveal` plus the server mutation right; an Edit-only grant is invalid in V1. `ManageAccess` is policy authority and never implicitly supplies either CEK. `Use without Reveal` is disabled, and no broker exists in this phase. A future operation grant may reference the same immutable resource ID but have a distinct operation/target binding and **no secret CEK delivery**: target-issued short-lived SSH certificates, hardware signing, or a narrow broker are separate protocol profiles with their own audit and trust disclosure. A Cloud broker that sees a reusable secret changes that secret's E2EE boundary; it cannot be introduced by merely adding a permission bit.

The [versioned publication protocol](access-sharing-v2-concurrency.md) makes the state transitions precise. The [security threat model](access-sharing-threat-model.md) lists malicious server, admin and device risks.
