# Vault v2 registry foundation (dormant)

This PR implements only the first production foundation of the preliminary Hybrid Access / Vault v2 architecture. It does not implement grants, groups, ACL, per-resource encryption, v2 key wrappers, payload migration, sharing UI or Credential.Use. Existing Vaults stay `V1_ACTIVE`; no application route transitions their format.

## Resource identity and metadata

`shared_vaults.id` is the opaque identity of the Vault container. Migration `013_resource_registry_foundation.sql` adds `vault_resource_registry` for future Host, Credential, Snippet, Forwarding and Folder resources. It stores a globally unique UUID, immutable Team/Vault binding, coarse `policy_class` (`general`, `secret`, `folder`), optional opaque Folder parent ID, schema/resource version, creation time and deletion tombstone. The exact Host/Snippet/Forwarding subtype remains encrypted client data in the future format. There are no columns for hostname, username, Credential name, Folder display name, Snippet title/body or secret metadata.

The server still learns resource counts, the Folder graph, which rows are `secret`, lifecycle timestamps and future query timing. Existing v1 `shared_vaults.name` is already server visible; this foundation does not retroactively hide it. Registry access is internal and restricted to an admitted Owner/Admin key custodian of a `V2_PREPARING` Vault. No public resource route exists. A primary key prevents ID reuse while the Team/Vault exists; foreign keys bind Team/Vault and Folder parent class; a trigger rejects identity rebind, tombstone resurrection, active-child deletion and parent cycles. Tenant and Vault predicates are present on each internal registry operation.

Browser and Mac preparation models generate canonical random UUIDv4 IDs. Rename and same-Vault move retain an ID; copy, duplicate and import generate a new ID. The one-time Folder preparation maps path prefixes separately for Host and Snippet namespaces, gives each Folder an opaque ID, and reuses an existing staged map on retry. Folder rename/move updates the preparatory path projection while retaining the ID and descendant parent IDs. This map must eventually be stored inside an encrypted migration manifest; **this PR does not persist it into existing v1 Vault documents or switch current path-derived UI/DnD to IDs**. Doing so during v1 operation would require a separately reviewed compatibility and sync design for old clients. Existing hierarchy and drag-and-drop behavior remain untouched. No ACL decision uses a path or name.

## Format, capabilities and old API

The additive migration gives every old and new Vault `format_state=V1_ACTIVE` and `format_schema_version=1`. The schema declares `V2_PREPARING`, `V2_READY` and `V2_ACTIVE` for later work; the check constraint binds v1 to schema 1 and all v2 states to schema 2. There is no transition endpoint or background job.

`resource_registry_v2` is only an internal preparatory capability for an authenticated, admitted Owner/Admin device and server-verified `V2_PREPARING` state. `resource_acl_v2` is reserved and always false. A client-supplied version or capability string does not grant route eligibility. The internal capability query uses the active membership, epoch-bound admission, device and authoritative Vault format; no new user-facing response is added.

Legacy list/get/write/rename/key-device/wrapper queries require `V1_ACTIVE`. A hypothetical v2 Vault is absent from old list responses and old detail, write and wrapper calls fail with the existing non-enumerating Team error. The database additionally rejects inserts or updates into legacy whole-Vault revision and wrapper tables for any non-v1 Vault, including invitation preprovisioning. Old invitation queries exclude v2 Vaults. These are dormant fail-closed primitives; no v2 resource ciphertext or wrapper implementation is present.

## Rollout and verification boundary

Migration 013 is additive and tracked by checksum. Existing rows receive only the default format fields. Registry indexes cover Team/Vault/ID and active parent lookup; current v1 sync needs no registry decrypt, polling or per-render rebuild. Local Cloud tests include schema and SQL gate checks; the PostgreSQL 16 integration suite in CI exercises a temporary hypothetical v2 state, registry scope, tombstones and old-route rejection. Locally `TEST_DATABASE_URL` is absent, so that integration suite is skipped until CI. Full Swift and Release checks are separate evidence.

Before any format transition or live Folder-ID adoption, a later PR must supply the encrypted migration manifest, complete client parity, per-resource ciphertext/keys, atomic policy/key publication, admin recovery and security review. This foundation by itself makes **no granular secrecy or sharing claim**.
