# Vault v2 old-client and mixed-Team gate

Status: design only, 2026-09-29. Frozen 0.32 clients know the v1 whole-Vault API and key wrapper, not a v2 per-resource format. The compatibility boundary must be **server enforced**; a UI label or client-version string is insufficient. See [migration](access-sharing-v2-migration-state-machine.md).

## Exact gate

1. Store a server-authoritative, immutable-per-generation Vault `format=v1|v2`, v2 schema generation and migration/cutover state. No v2 resource ciphertext or CEK wrapper may be embedded in a v1 whole-Vault document.
2. Introduce `resource_acl_v2` as a negotiated protocol capability bound to authenticated session, admitted device ID/key, membership ID/epoch and a server-issued short-lived capability context. The server checks the v2 request shape and current policy **on every call**. An arbitrary `User-Agent` or `X-Version` claim does not grant access. This is compatibility negotiation, **not** proof that client software is unmodified; a modified authorized client remains in the threat model.
3. For a v2 Vault, all legacy whole-Vault GET/HEAD/PUT/rotation/wrapper/list-detail paths return a typed upgrade/capability-required response **without ciphertext, wraps or names**. An old list may omit v2 Vaults or show only a generic upgrade count; it cannot leak restricted catalog rows. Old idempotent retries after cutover also fail.
4. Only v2 catalog, resource, grant and wrapper endpoints serve v2 data, after the Team membership/epoch/device gate and per-resource policy/key checks. No v1 fallback or automatic downgrade is allowed. Server-side format marker survives backup/restore and deploy rollback; a binary that cannot enforce it must refuse to start or serve those Vaults.
5. V2 clients may still read/write separate v1 Vaults under the existing coarse rules, clearly labeled as legacy. A Team may contain both Vault formats. **One Vault never mixes v1 and v2 ciphertext or keys.**

An honest 0.32 app cannot parse or decrypt a v2 resource envelope and receives no data via its known API. A malicious 0.32-derived client can mimic a new capability handshake, so the actual secrecy boundary remains per-resource policy and CEK distribution to authorized devices. Capability alone is not a trusted software attestation. Already downloaded v1 ciphertext/plaintext and old wrappers remain in an offline cache; the server can stop future sync but cannot retroactively erase them.

## Behavior matrix

| Client / Vault | Read | Write and conflict upload | Expected UX |
| --- | --- | --- | --- |
| 0.32 / v1 | Existing coarse Team/Vault behavior | Existing v1 revision rules | Legacy Vault, no granular claim |
| 0.32 / v2 | No v2 catalog, ciphertext or wrappers | Reject old whole-Vault and stale queued writes | Upgrade required; other v1 Vaults remain usable |
| ACL-aware admitted client / v1 | Existing v1 flow, labeled coarse | Existing v1 flow | Migration may be initiated only by authorized Owner/Admin |
| ACL-aware admitted client / v2 | Policy-filtered paged catalog; current resource envelope/wrap only | Current version, grant, epoch and key checks | Distinguish policy allowed from key pending/usable |
| Stale/offline former member or device | Local old copies may remain | Server rejects on reconnect by epoch/device/policy | Explicit loss of future access; no remote-erasure promise |

Cloud browser asset caching is not a security gate. A stale JavaScript bundle may render old UI, but the authoritative server format check prevents v2 data from crossing a v1 route. V2 deployment must be coordinated so that a rollback of Cloud/API binaries cannot accidentally reactivate the v1 handler for a migrated Vault. This is a release blocker, not an optional UX detail.
