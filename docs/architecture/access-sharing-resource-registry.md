# Vault v2 resource registry: identity and metadata

Status: implementability proposal, 2026-09-29. No production registry exists. Public main at review: `c554e26c3a36a95d439f35258137ec6625755fb5`. Existing record UUIDs live inside the whole encrypted Vault document (`Sources/SelectiveRemote/CloudVaultRecordModel.swift:169-223`); merge/conflict resolution keys by that UUID (`:385-505`). Host folders are normalized paths (`HostFolderTree.swift:2-40`), while browser Snippet folders are separately inferred from record paths (`cloud/public/team-snippet-browser.js:1-36`). Current source evidence and gaps are in [current state](access-sharing-current-state.md).

## Canonical v2 row and invariants

One server-registered row per Vault, Folder and content resource. A Vault is the container root; its existing server UUID remains stable. Content resources are Host, Credential, Snippet and Forwarding. Folder has encrypted display metadata and an immutable opaque ID. No name, title, hostname or path is an authorization identity.

| Field | Rule |
| --- | --- |
| `resourceID` | Canonical random UUID from a cryptographic RNG. Immutable, unique within Team across active rows **and tombstones**. Vault row uses existing `vaultID` as its resource identity. |
| `teamID`, `vaultID` | Server-resolved scope, immutable for an ID. Never copied from an unverified client claim. A cross-Vault/Team transfer creates a new ID. |
| `resourceType` | Actual Host/Credential/Snippet/Forwarding/Folder/Vault type is encrypted in the client payload. Server retains only immutable `policyClass`: `container`, `folder`, `secret` (Credential), `general` (Host/Snippet/Forwarding). |
| `parentFolderID` | Nullable opaque ID, same Team/Vault, acyclic, bounded depth. A folder's parent is a Folder or Vault root; a content resource's parent is a Folder or Vault root. Versioned on move. |
| `cryptoDomain` | `resource-part` for independently encrypted content and Folder metadata, `container-only` for the Vault row. A Credential has `metadata` and `secret` parts with separate keys; other content has one `payload` part. No Team root or Folder key can decrypt all descendant content. |
| `schemaVersion` | V2 registry/envelope format identifier. Unsupported versions fail closed. It is distinct from an app release number. |
| `createdAt`, `deletedAt` | Server timestamps. Delete marks a tombstone; resurrection under the same ID is forbidden. |
| `version` | Monotonic registry metadata revision; separate `contentRevision`, `keyEpoch` and Vault `policyVersion` are defined in [concurrency](access-sharing-v2-concurrency.md). |

Server uniqueness and foreign-key/transaction checks bind `(teamID, vaultID, resourceID, policyClass)` permanently. A random UUID from a client is a **proposal** until the server registers it. The server rejects duplicates, type/scope changes, unknown parents, cycles and references to tombstones. Client authenticated encryption binds exact Team/Vault/ID/class/parent/**part**/content revision/key epoch; the client also verifies the actual encrypted type is compatible with `policyClass`. The server cannot prove semantic truth of encrypted contents: an authorized malicious editor could put a secret into a `general` resource. This remains an explicit limitation, not a server-enforced classification guarantee.

## Stable identity operations

| Operation | Identity/key result |
| --- | --- |
| Rename | Same ID, CEK and parent; new encrypted display metadata and content revision. |
| Move within Vault | Same ID; parent and registry revision change in one previewed policy/key transaction. Re-encrypt affected payload to bind new parent. Rotate affected descendants' CEKs if their decrypting audience changes. |
| Copy, duplicate, import from Personal, or cross-Vault/Team transfer | New random ID and fresh CEK. Explicit source grants and wrappers do not follow; destination inheritance is previewed before publication. Source remains independently addressable until an authorized move tombstones it. |
| Sync/conflict | Existing ID remains attached to the same immutable scope/class. Competing content revisions resolve under that ID; a conflicting ID with a different type/scope is quarantined, never merged or aliased. |
| Delete | Tombstone retains ID/scope/class and highest version with minimal metadata. Server will never register that ID again during Team lifetime; grants/wrappers are revoked and later compacted without losing the non-reuse marker. |

Mac and browser v2 clients use the same canonical lowercase UUID string, cryptographic RNG and registration response. They do **not** derive a new Credential ID from a Host ID. The current Mac Personal exporter derives some Credential IDs from source IDs (`CloudPersonalVaultSync.swift:154-293`), while browser upsert can generate random IDs (`cloud/public/team-vault-sync.js:706-716`): v1 IDs are input to a migration map, not assumed to be a universal identity contract. Unknown/colliding IDs receive a new v2 ID and encrypted legacy alias; no v1 grant is imported implicitly. A normal collision is rejected and retried with a fresh UUID; an existing row with a different immutable binding is a security error, not an overwrite.

## Folder migration

The migration client takes an immutable v1 revision snapshot, canonicalizes Host paths using the existing Host normalizer and Snippet paths using the browser's different rules, then builds separate `hosts` and `snippets` legacy namespaces. Equal-looking labels across those namespaces **do not** silently become one ACL Folder. A later explicit merge requires an access preview. For each unique path prefix within its namespace it allocates a random Folder UUID, records parent UUID and stores the name only in an encrypted Folder metadata envelope. Unfiled records attach to the Vault root.

The resulting `legacy namespace + canonical path -> folderID` table is encrypted in the staged migration manifest. Retries reuse that same staged mapping and IDs; an invalidated migration generation discards it and never publishes partial Folder rows. Ambiguous normalized paths, conflicts and dangling references block cutover for authorized resolution. After activation, rename and move edit the encrypted name/parent while preserving Folder ID; clients stop deriving ACL ancestry from display paths. Folder delete is a previewed child move or is rejected if nonempty. The stage/activation protocol is in [migration state machine](access-sharing-v2-migration-state-machine.md).

## Server-visible metadata and leakage

Minimum: Team/Vault/opaque resource and parent IDs; `policyClass`; part labels (`payload` or `metadata`/`secret`), schema, registry, policy and key versions; lifecycle timestamps/tombstone; grant/group/recipient edges needed for enforcement; ciphertext size/hash and access timing. Server does **not** need the exact Host/Snippet/Forwarding subtype, hostname, username, Credential label/secret, Snippet title/body, Folder name or plaintext path. It **does** need `policyClass=secret` and the two part labels to apply the distinct Credential.Reveal mask, and `folder`/`container` to enforce acyclic ancestry and inheritance. This reveals which resources are secrets, their two-part structure and graph shape. Actual encrypted type and class are authenticated together by client encryption; immutability prevents post-registration class switching. The legacy `shared_vaults.name` is already server-visible and cannot be erased from historical logs by a v2 registry design. V2 must use an encrypted display name or opaque placeholder for future Vault-name storage; historical v1 name exposure remains.

Do not publish resource names in audit/notification payloads or unscoped list responses. Use policy-filtered, paged registry reads. Exact retention of metadata and compact tombstones remains an Owner/privacy decision. The registry cannot conceal access graph, counts, timing or ciphertext sizes while the server enforces ACL; [threat model](access-sharing-threat-model.md) records that limit.
