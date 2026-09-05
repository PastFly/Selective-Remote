# Cloud 0.32 Team and shared Vault threat model

Status: design contract with the backend Team-access and ciphertext protocol implemented.
Durable Teams, memberships, four-role checks, membership epochs, hash-only
invitations, encrypted outbox delivery, audit events, idempotency receipts and
shared-Vault metadata, shared ciphertext revisions, approved P-256 devices,
per-device wrappers and atomic rotation completion are present. Browser/macOS
Team cryptography and UI are not yet implemented.

## Security outcome

An authorized Team member can use the same shared Hosts, Credentials,
Snippets and Forwarding records in the browser and macOS client. The Cloud API
authorizes every operation but cannot decrypt record content. Removing a
member stops access to later revisions and key generations. Data that the
member legitimately decrypted or cached before removal cannot be made secret
again and is outside that guarantee.

## Trust boundaries and threats

| Actor or component | Trusted for | Never trusted for |
|---|---|---|
| Browser/macOS client | Local plaintext handling, encryption, signature and key-generation checks | Another member's authorization or server revision order |
| Cloud API | Authentication, membership/role enforcement, revision serialization and durable audit metadata | Vault plaintext, Vault keys or silently selecting a conflict winner |
| PostgreSQL | Durable ciphertext, authorization state, sessions, invitations, generations and outbox jobs | Confidentiality when the application/database host is compromised |
| Team Owner/Admin | Membership actions allowed by role | Reading a Vault for which no key wrapper was granted |
| Removed/compromised member | Nothing after revocation | New revisions, current key generations or new wrappers |

The protocol must address stolen database backups, malicious cross-Team IDs,
replayed invitations, revoked sessions, concurrent edits, an offline removed
device, partial rotation, a compromised member device and multiple stateless
API replicas. It does not claim protection from malware running inside an
unlocked authorized client.

## Durable ownership model

- A Team has an immutable random ID, display metadata and at least one Owner.
- A Team owns one or more shared Vaults. A record belongs to exactly one Vault;
  personal and shared records never share encryption keys.
- Membership, role, invitation, device authorization, Vault revision and key
  generation are durable database state. API process memory is not
  authoritative.
- Every read/write names the Team and shared Vault scope explicitly. The API
  derives the authenticated user from the session and never accepts an owner
  user ID from the request body.
- Authorization is checked transactionally against the requested Team, Vault,
  membership status, role and current generation. Possession of ciphertext or
  a wrapper is not sufficient authorization.

## Role matrix

Cloud 0.32 uses four roles. A custom-role system is out of scope for 0.32.

| Operation | Owner | Admin | Editor | Viewer |
|---|:---:|:---:|:---:|:---:|
| Read shared ciphertext/current wrappers | Yes | Yes | Yes | Yes |
| Create/update/delete shared records | Yes | Yes | Yes | No |
| Create/rename shared Vault | Yes | Yes | No | No |
| Archive shared Vault | Yes | Yes | No | No |
| Invite Editor/Viewer | Yes | Yes | No | No |
| Invite/promote/demote Admin | Yes | No | No | No |
| Remove Editor/Viewer | Yes | Yes | No | No |
| Remove/demote Admin | Yes | No | No | No |
| Assign/remove Owner | Yes | No | No | No |
| Transfer ownership/delete Team | Yes | No | No | No |
| Start/complete key rotation | Yes | Yes | No | No |

An actor cannot change their own role, remove themselves as the last Owner or
remove/demote another Owner through an Admin permission. Team deletion and
ownership transfer require recent re-authentication. A Viewer who has a Vault
key can technically produce ciphertext, so the API must still reject Viewer
writes.

## Invitation lifecycle

1. Owner/Admin creates an invitation for one normalized email and an allowed
   role. Only an Owner can invite an Admin.
2. The server creates at least 256 bits of random token material, stores only a
   keyed hash, and sends the opaque token through the durable outbox.
3. An invitation expires after 48 hours and has explicit `pending`, `accepted`,
   `cancelled` or `expired` state. It is single-use.
4. Acceptance requires a verified account whose normalized email matches the
   invitation. The transaction locks the invite and membership uniqueness
   rows so two requests cannot accept it twice.
5. Cancellation and expiry make the token unusable immediately. Re-inviting
   creates a new token and does not revive an old one.
6. Acceptance creates membership but does not fabricate a Vault key. Each
   shared Vault remains unavailable until an authorized client publishes a
   wrapper for an authorized device.

Invitation endpoints use uniform public errors and rate limits. Audit events
contain actor, Team, target, role and timestamps but no token or Vault data.

## Device-bound key distribution

Each authorized device owns a non-exportable P-256 ECDH private key when the
platform supports it; its public key and attestation metadata are registered
with the account. Before implementation, browser/macOS interoperability
fixtures must lock the exact encoding and algorithms:

- P-256 ECDH;
- HKDF-SHA-256;
- AES-256-GCM key wrapping;
- canonical UTF-8 context joined with NUL separators: protocol label
  `selective-remote/team-vault-wrapper/v1`, Team ID, Vault ID, decimal key
  generation, membership ID, decimal membership epoch and device ID. The API
  verifies its base64url SHA-256 hash before storing a wrapper.

For every shared Vault generation, an authorized client creates one random
256-bit Vault key, encrypts the normalized Vault document locally, and creates
a context-bound wrapper for each authorized member device. The server stores
the ciphertext, public metadata and wrappers but never the Vault key or ECDH
shared secret. A wrapper for one Team/Vault/generation/device must fail when
replayed in any other context.

A newly registered device requires approval from an existing authorized
device or a separately reviewed account-recovery flow. Email/password login
alone does not grant old shared-Vault keys. Device revocation invalidates its
sessions and excludes it from all later wrapper sets.

## Removal and rotation

Membership removal is a fail-closed state transition:

1. In one database transaction, mark membership revoked, invalidate any
   Team-scoped grants, reject its Team reads/writes immediately, mark every
   affected shared Vault `rotation_required`, and enqueue durable idempotent
   rotation work. A global account session may remain valid for the user's
   personal Vault, but every Team operation rechecks active membership and can
   no longer authorize it.
2. Until an Owner/Admin client completes rotation, existing authorized members
   may download the last authorized ciphertext but shared writes are frozen.
   The removed member receives neither reads nor wrappers even during this
   interval.
3. An authorized rotating client downloads the latest ciphertext, decrypts it
   locally, generates a new Vault key/generation, re-encrypts the full current
   document and builds wrappers only for currently authorized devices.
4. The API conditionally commits the new ciphertext, generation and complete
   wrapper set against the locked prior revision/generation. Partial wrapper
   sets and stale rotations are rejected.
5. Retry uses an idempotency key. Competing rotations produce one committed
   generation; losers refetch and stop or retry from current state.

This guarantees that a removed member cannot obtain revisions encrypted under
the new generation. It cannot erase plaintext, keys or old ciphertext already
cached by that member. Re-invitation creates a new membership epoch and only
receives current-generation wrappers; it does not reactivate revoked sessions
or wrappers.

## Revision and conflict rules

- Each shared Vault has one monotonically increasing server revision and one
  current key generation.
- Writes use optimistic concurrency against both revision and generation.
- Record version vectors and tombstones use the same causal model as the
  personal Vault. Concurrent versions are returned to an authorized client;
  timestamps never choose a winner.
- Conflict resolution joins both histories, creates a new local causal event
  and uploads conditionally. The server never sees the selected plaintext.
- Role changes and rotation cannot be smuggled inside an encrypted record
  revision; they use separate authorized endpoints and durable transactions.

## API and storage invariants

- Personal endpoints continue to accept only `personal/self`. Team APIs use a
  separate explicit `/v1/teams/{teamID}/vaults/{vaultID}` scope.
- Cross-Team identifiers return the same public not-found/forbidden shape and
  never disclose membership or Vault existence.
- Every mutation has an idempotency key and bounded payload. Database unique
  constraints enforce membership epoch, invitation token hash, revision and
  generation invariants.
- Key/member/rotation mail or background work uses a durable outbox; no
  authoritative queue lives in one Node process.
- Logs and metrics exclude ciphertext bodies, wrappers, invitation tokens,
  passphrases, record titles and decrypted fields.

## Required acceptance tests

- Allow/deny tests for every role and operation, including Viewer writes,
  Admin-to-Owner escalation and cross-Team ID substitution.
- Invitation expiry, cancellation, double acceptance, re-invitation and
  verified-email mismatch.
- Browser/macOS cryptographic fixtures for key agreement, context binding,
  wrapping, ciphertext and malformed/downgraded envelopes.
- Multiple devices per member, new-device approval and device revocation.
- Concurrent record edits/deletes, explicit conflict resolution and stale
  revision/generation rejection.
- Removal during an active session and on an offline device; no later
  ciphertext or wrapper is returned to the removed membership epoch.
- Rotation retry, competing rotators, incomplete wrapper sets, process crash
  and multi-replica outbox execution.
- Server/database inspection proving no personal or shared plaintext/key is
  present.

Team/shared Vault release status remains `planned_required`: the server-side
access and ciphertext protocol is implemented, but interoperable browser/macOS
cryptography, Team UI and the complete acceptance suite must pass before Cloud
0.32 is complete.
