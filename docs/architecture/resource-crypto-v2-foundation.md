# Dormant per-resource crypto v2 foundation

This branch adds only a format, local cryptographic primitives, and closed storage. Existing and new Vaults default to `V1_ACTIVE`. No production route calls `publishResourceCryptoVersion`, no client reads these tables, and no code converts a Vault to V2. Registry mutation APIs remain gated on separate concurrent direct-SQL hardening.

## Device identity and trust gate

The admitted device is identified by its device UUID plus a P-256 ECDH public key. On macOS the 32-byte private scalar is held in a protected local Keychain envelope scoped to endpoint and device. In the browser a non-extractable WebCrypto private `CryptoKey` is stored in IndexedDB. The server accepts the client public key at first registration, pins equality on later login, and serves key fingerprints and wrapper targets. The approval UI can show a fingerprint, but its value comes from the same server. The server can substitute a key before a sender wraps the CEK; the present mechanism does not cryptographically authenticate the device key against a separate trust anchor. A compromised web origin can also use browser keys despite their non-extractable flag.

The current V1 policy often accepts `key_approved_at OR current-epoch admission`. Thus globally approved devices can bypass a fresh membership-epoch admission. V2 storage requires an explicit current-epoch admission, but this does not cure key substitution. **Production wrapper creation, retrieval and E2EE claims remain blocked** until device-key fingerprints are independently verified or signed enrollment/key-directory records are checked with anti-rollback, and all V2 recipient selection uses current-epoch admission. Proof of possession alone cannot defeat malicious server substitution.

The intended server model for the dormant format is honest-but-curious confidentiality. A malicious server can withhold or replay ciphertext, substitute recipient public keys, or serve stale manifests. Full malicious-server protection additionally needs authenticated device keys and a client anti-rollback anchor. No production CEK distribution is enabled here.

## Format

- CEK: 32 random bytes from CryptoKit or WebCrypto. One fresh CEK per resource part and immutable key version. `GENERAL` is for ordinary resources; `METADATA` and `SECRET` are separate future Credential parts. No Credential data is split or migrated.
- Ciphertext: `formatVersion=2`, `algorithm=AES-256-GCM`, `aadVersion=2`, normalized scope and independent `keyVersion`, `policyVersion`, `registryVersion`, `resourceVersion`, `manifestVersion`, 96-bit random nonce, ciphertext, 128-bit tag. Maximum plaintext is 24 MiB. All versions are positive safe integers; the five counters need not be equal.
- Wrapper: `wrapperVersion=2`, ephemeral P-256 ECDH, HKDF-SHA256 with salt `SHA256(wrapperAAD)` and info `selective-remote/resource-wrapper-key/v2`, AES-256-GCM, 96-bit random nonce and 128-bit tag. Scope includes Team, Vault, resource, part, key version, membership ID and epoch, and device ID.
- AAD: UTF-8 domain ending in NUL, two bytes `00 02`, then each field in a fixed order as a two-byte big-endian byte length and canonical UTF-8 bytes. UUIDs are lowercase. Ciphertext and wrapper have different domains. The schema version is in the binary header. This encoding has no separator ambiguity; browser and macOS fixture tests compare exact bytes and open the same wrapper/ciphertext.
- The shared ciphertext cannot bind a single device ID: that belongs to each device wrapper. The ciphertext authenticates independent policy/registry/resource/manifest versions; the wrapper authenticates recipient and membership epoch. Both bind Team/Vault/resource/part/key version.

Nonce generation uses the platform CSPRNG on every encryption. The storage key `(Team, Vault, resource, part, keyVersion)` admits one immutable ciphertext for a fresh CEK; rotation advances key version with a new CEK. The low-level dormant encrypt function can be called repeatedly with a caller-supplied CEK; it uses a new random nonce each time, but no finite random process can mathematically guarantee collision never occurs. Production publication must enforce the one-ciphertext-per-CEK discipline and never reuse a CEK after duplication or re-encryption. Raw CEK buffers should be cleared after use where feasible; Swift `Data` and WebCrypto internal copies do not promise complete memory zeroization. Keys, plaintext, wrappers and ciphertext are never logged by these primitives.

## Storage and publication

Migration 014 adds scoped ciphertext versions, wrapper rows, and per-part manifest pointers. Foreign keys bind Team/Vault/resource, wrapper version to ciphertext version, and membership to epoch. Triggers reject V1 Vaults, archived or tombstoned resources, wrappers without current-epoch admission, and pointers without a wrapper. The existing registry UUID primary key prevents tombstone reuse. No migration updates an existing Vault format state.

The internal store primitive requires an admitted custodian in `V2_PREPARING`, locks the resource row, compares its registry version and the manifest pointer, inserts one ciphertext and its entire wrapper set, then advances the pointer and marks the old version obsolete in one transaction. Stale versions or any insert failure roll back. Concurrent calls on the same resource serialize on the resource row; only one expected-manifest compare can succeed. A lost connection during `COMMIT` remains an ambiguous outcome until read-back; a future production API needs an idempotent publication identifier and recovery protocol. Direct SQL concurrency with registry mutation is still a separate required hardening gate before any production registry write route.

## Performance snapshot

Local Node 26.7.0 WebCrypto benchmark on the development Mac, 1 KiB plaintext, includes encryption and decryption: 100 resources 25.1 ms; 1000 resources 188.3 ms. Device wrapping: 10 wrappers 5.8 ms; 100 wrappers 21.5 ms. These are local microbenchmarks, not server latency. Fanout is linear in recipient devices and storage/transfer size; no caching or batching policy is chosen yet.

## Boundaries and next gates

No groups, grants, ACL checks, Effective Access backend, Access Manager backend, Credential.Use without Reveal, V2 activation, migration, or sharing UI are included. V1 wrapper, sync, invitation and admission paths are unchanged. Before grants/policy work, review this exact head. Before production wrapper use, independently authenticate recipient device keys, require current-epoch admission, and define manifest anti-rollback and ambiguous-commit recovery. Before any production registry mutation API, close concurrent direct-SQL uniqueness, isolation, stale-snapshot and tombstone races.
