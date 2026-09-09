# Selective Remote Cloud

Self-hosted Cloud foundation for Selective Remote v0.32. The API stores only
opaque encrypted Vault revisions; plaintext remote-access data remains on user
devices.

The final v0.32 product scope also includes Teams and shared Vaults. The backend
foundation implements durable Teams, memberships, the fixed four-role policy,
account-bound `@username` invitations, revocable 48-hour single-use links,
legacy encrypted email invitation delivery and
explicit Team/shared-Vault metadata endpoints. Shared ciphertext revisions,
P-256 device registration/approval, per-device key wrappers and fail-closed
rotation completion are implemented in the backend. The browser now has the
interoperable cryptographic/client layer: non-exportable P-256 identities,
ECDH/HKDF/AES-GCM wrappers, scope-bound shared payload envelopes, strict Team
API calls, Team/member/shared-Vault UI and causal shared-record synchronization.
The portal also lists account devices, shows canonical SHA-256 public-key
fingerprints, approves a matching new key only from an approved device, revokes
other devices, and completes required rotations. Invitation acceptance records
a Team- and membership-epoch-scoped admission for only the authenticated
session's registered P-256 device; it does not grant account-wide device trust.
Any active member device that already holds the current Vault wrapper can then
provision missing current-generation wrappers for other active authorized Team
devices. Owners can rename Teams,
atomically transfer ownership after password re-authentication, and archive a
Team behind exact-name confirmation. Archiving immediately closes Team access,
retires pending invitations/outbox work and rotation tasks, soft-archives its
Vaults, and retains ciphertext and audit history. The remaining client
milestone is the complete macOS implementation and cross-client acceptance.
The macOS foundation now provides typed login/logout/current-user/Team
transport, device-only Keychain bearer-session and P-256 device-identity
storage, strict fingerprint/context/content-hash primitives, and interoperable
ECDH/HKDF/AES-GCM Team Vault-key wrap/unwrap. This bounded macOS layer adds
scope/generation-bound Team payload encryption/decryption, strict shared-Vault
list/key-device/download/conditional-upload transport and atomic local storage
of ciphertext-only offline snapshots. A deterministic synthetic JSON fixture is
produced exactly by Swift and decrypted by the browser tests. The bounded sync
coordinator accepts clean remote revisions, stages encrypted offline edits with
deterministic retry identity, rejects rollback or same-revision divergence,
fails closed during rotation and preserves both decrypted versions plus the
dirty ciphertext snapshot on a 409. An explicit caller-provided resolution is
accepted only while both the dirty local snapshot and observed remote version
still match; it is re-encrypted from the observed remote revision and stays
dirty until the exact conditional upload acknowledgement. Personal-Vault
recovery wrapping, record-level conflict UI and end-to-end service acceptance
remain pending.

The browser portal can create and unlock a client-encrypted personal Vault,
perform local CRUD, sign in with an existing verified account and manually
synchronize opaque revisions through the personal-Vault API. The bearer session
exists only in page memory. IndexedDB contains ciphertext, a random device UUID
and non-secret revision acknowledgement metadata, never the session token,
recovery passphrase, raw Vault key or decrypted records. Concurrent record
conflicts and server revision conflicts stop upload instead of overwriting.
The browser requires an explicit choice for every concurrent record or
tombstone, joins both causal histories locally, and leaves the resolution dirty
until the next conditional upload. A clean browser can import the encrypted
remote Vault through a dedicated recovery form; the phrase is cleared after
each attempt and never sent or persisted. Registration remains disabled in the
closed-staging configuration.

The mandatory Team/shared-Vault security contract is documented in
`docs/cloud-v0.32-team-threat-model.md`. It fixes the four-role matrix,
invitation lifecycle, device-bound wrappers, membership epochs and fail-closed
key rotation. Migration `005_team_foundation.sql` implements durable
identity/access metadata; `006_team_vault_crypto.sql` adds the plaintext-blind
ciphertext, device-wrapper and rotation transaction layer;
`008_usernames.sql` adds public account handles; and
`009_team_invitation_modes.sql` binds the new invitation transports.

## Team API foundation

Authenticated Team routes derive the actor exclusively from the bearer
session. Every mutation requires a 16–128 character `Idempotency-Key` header;
the database stores and replays the committed response atomically.

- `GET|POST /v1/teams` lists or creates Teams; creation atomically grants the
  creator the first Owner membership.
- `PATCH /v1/teams/{teamID}` renames an active Team under an Owner lock.
- `POST /v1/teams/{teamID}/ownership-transfer` re-authenticates the Owner,
  promotes one active target member and demotes the actor to Admin atomically.
- `DELETE /v1/teams/{teamID}` requires rate-limited password re-authentication
  and exact current-name confirmation, then transactionally soft-archives the
  Team and Vaults while retiring pending invitations, delivery and rotations.
- `GET /v1/teams/{teamID}/members` lists active members.
- `GET|POST /v1/teams/{teamID}/invitations` lists manageable active
  invitations or creates a rate-limited invitation by public `@username` or a
  revocable 48-hour single-use link. Admins cannot invite Admins and
  invitations cannot directly grant Owner.
- `GET /v1/team-invitations` lists active account-bound invitations for the
  authenticated user's public `@username` without exposing account email.
- `DELETE /v1/teams/{teamID}/invitations/{invitationID}` cancels a pending
  invitation, retires any undelivered legacy outbox job and invalidates a link.
- `POST /v1/team-invitations/accept` accepts either an account-bound invitation
  ID or an opaque link token once, creates the next membership epoch and
  atomically admits only the accepting authenticated session device to that
  exact membership epoch after verifying its registered P-256 public key.
  Account-wide device approval remains unchanged.
- `PATCH|DELETE /v1/teams/{teamID}/members/{membershipID}` changes a role or
  revokes membership under a transactionally locked role check. Self-mutation,
  Admin escalation and removal of the last Owner fail closed.
- `GET|POST /v1/teams/{teamID}/vaults` lists or creates shared-Vault metadata.
  Only Owner/Admin may create one.
- `POST /v1/devices/{deviceID}` approves a new device key from the current
  already-approved device after the submitted canonical public JWK matches the
  locked registered key. Password login alone never approves a Team key.
- `POST /v1/devices/bootstrap-key` is the bounded legacy-account exception:
  after authenticated password re-verification and user/IP rate limits, it can
  approve only the current registered key and only while the account has zero
  approved devices. The user row serializes competing first-device attempts.
- `GET /v1/teams/{teamID}/vaults/{vaultID}/key-devices` returns the exact
  active authorized device set (account-approved or admitted to the exact
  membership epoch) to Owner/Admin clients or to any active member whose
  current session device already has a wrapper for this Vault generation.
- `GET|PUT /v1/teams/{teamID}/vaults/{vaultID}` downloads the current opaque
  envelope/current-device wrapper or conditionally writes a ciphertext
  revision. Viewer writes are rejected.
- `POST /v1/teams/{teamID}/vaults/{vaultID}/wrappers` idempotently grants a
  current-generation wrapper to one active authorized Team device. The actor's
  current session device must itself be authorized, active in the exact
  membership epoch and already hold this Vault generation's wrapper. Vault
  initialization and rotation remain Owner/Admin-only.

The invitation table stores only an HMAC token hash plus the public target
account ID for `@username` invitations. A link's recoverable token is held only
in a domain-separated AES-256-GCM envelope so an idempotent create retry can
return the same URL; cancellation or acceptance makes its hash unusable and
deletes the dedicated envelope. Legacy email delivery keeps the opaque token
and recipient in a separate AES-256-GCM outbox envelope under the runtime key;
multi-replica delivery uses a bounded `FOR UPDATE SKIP LOCKED` lease. Public
invitation responses, logs and audit metadata contain no email, token or
mail-provider response. Revoking a member
immediately marks every active shared Vault `rotation_required`; revoking an
approved device does the same and invalidates all of its sessions. Writes then
remain frozen until Owner/Admin conditionally commits a new full ciphertext,
the next key generation and exactly one wrapper for every currently active
approved device in a single PostgreSQL transaction. Partial/stale rotation is
rejected and the same transaction completes its durable rotation tasks.

The browser wrapper contract is fixed for macOS interoperability. It derives
256 ECDH bits on P-256, imports them as HKDF-SHA-256 material, uses the SHA-256
wrapper-context digest as HKDF salt and
`selective-remote/team-vault-wrapper-key/v1` as HKDF info, then AES-256-GCM
encrypts the raw 32-byte Vault key with the full canonical context as AAD.
Shared payload AES-GCM AAD binds protocol, Team, Vault and key generation.
Private device keys are non-exportable and stored as structured-cloned
`CryptoKey` values in IndexedDB; simultaneous tabs converge through a
create-if-absent transaction.

The Team portal keeps its bearer session and decrypted shared-Vault keys only
in page memory. It persists one strict ciphertext-only IndexedDB snapshot per
Team/Vault scope, supports the four versioned record types and performs manual
optimistic synchronization. Concurrent record or tombstone edits block upload
until the user chooses every winner explicitly. Membership or device revocation
freezes writes at `rotation_required`. Owner/Admin rotation decrypts and merges
only in memory, generates a new key, wraps it for the exact current approved
device set and conditionally uploads the full ciphertext plus wrappers. Local
state changes only after the atomic server acknowledgement. A competing writer
leaves the losing snapshot untouched; an unknown network result is reconciled
against the exact revision, generation and content hash before local commit.

## Local verification

```bash
npm ci
npm test
cp .env.example .env
# Replace every placeholder secret before starting the stack.
docker compose up --build
```

Registration is intentionally disabled in the example configuration. Email
verification, password reset and request throttling are implemented, but it
must stay disabled on a public host until SMTP delivery is configured and the
complete flow passes manual security review. Enabling it fails closed unless
the verification-token pepper and all SMTP settings are present. SMTP uses
implicit TLS when `SMTP_SECURE=true`; otherwise the client requires STARTTLS
and rejects invalid certificates.

Registration creates an unverified account and sends a one-time link; it does
not return a bearer session. Password login and session lookup remain blocked
until the token is consumed. SMTP connectivity is verified before the service
starts whenever registration is enabled. The rate-limited resend flow can
recover a pending account after a delivery failure. Password reset is
implemented and covered by automated tests, but still requires manual
end-to-end review, so registration must remain disabled.

`POST /v1/auth/resend-verification` returns the same accepted response for
unknown, disabled, verified and pending accounts. Pending accounts receive a
replacement one-time link; provider failures are logged without the recipient
or provider response and do not change the public response. Recovery responses
use a common minimum delay and do not wait for SMTP delivery, reducing account
enumeration through response timing.

`POST /v1/auth/request-password-reset` uses the same generic accepted response
for unknown, disabled, unverified and eligible accounts. Reset links carry an
opaque token in the URL fragment; the browser removes it from history before
showing the password form. `POST /v1/auth/reset-password` consumes a valid token
once, replaces the scrypt password hash and revokes every existing session.
Queued recovery mail is held in process; an abrupt process or host failure can
drop that delivery, in which case the user can submit another rate-limited
request.

Authentication endpoints use persistent fixed-window limits keyed by HMACs of
the client IP and, where applicable, the normalized email address. Raw IPs and
emails are not stored in the rate-limit table. The bundled Caddy proxy
overwrites the client-IP header and authenticates it with an independent shared
secret; direct or spoofed headers fall back to the socket peer address.

The Cloud container applies numbered SQL migrations before starting the API.
Applied filenames and SHA-256 checksums are recorded in `schema_migrations`.
Never edit an applied migration; add the next numbered file instead.

All base and runtime container images are referenced as `tag@sha256`. Treat
digest changes as reviewed dependency upgrades: verify the exact image on the
target architecture, run the complete test and staging gates, then update the
tag and digest together. Do not replace these references with mutable tags.

## Production host

The supplied Caddy configuration expects `cloud.pastfly.ru` to resolve to the
Ubuntu host. Only Caddy publishes host ports; PostgreSQL is private to the
Compose network.

See [`DEPLOY-UBUNTU.md`](DEPLOY-UBUNTU.md) for the read-only preflight, required
ports, secret generation, guarded PostgreSQL backup/restore drill, first launch
and verification steps. Caddy uses the Let’s Encrypt production ACME endpoint
and renews certificates automatically.
