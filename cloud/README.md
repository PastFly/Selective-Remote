# Selective Remote Cloud

Self-hosted Cloud foundation for Selective Remote v0.32. The API stores only
opaque encrypted Vault revisions; plaintext remote-access data remains on user
devices.

The final v0.32 product scope also includes Teams and shared Vaults. The backend
foundation implements durable Teams, memberships, the fixed four-role policy,
single-use 48-hour invitations, encrypted durable invitation delivery and
explicit Team/shared-Vault metadata endpoints. Shared ciphertext revisions,
device-bound key wrappers, rotation completion and client UI remain later
milestones; a metadata-only shared Vault is not yet usable for records.

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
key rotation. Migration `005_team_foundation.sql` implements only the durable
identity/access and metadata portion of that contract.

## Team API foundation

Authenticated Team routes derive the actor exclusively from the bearer
session. Every mutation requires a 16–128 character `Idempotency-Key` header;
the database stores and replays the committed response atomically.

- `GET|POST /v1/teams` lists or creates Teams; creation atomically grants the
  creator the first Owner membership.
- `GET /v1/teams/{teamID}/members` lists active members.
- `POST /v1/teams/{teamID}/invitations` queues a rate-limited invitation;
  Admins cannot invite Admins and invitations cannot directly grant Owner.
- `DELETE /v1/teams/{teamID}/invitations/{invitationID}` cancels a pending
  invitation and retires its undelivered outbox job.
- `POST /v1/team-invitations/accept` accepts a token once, only for the
  authenticated verified email, and creates the next membership epoch.
- `PATCH|DELETE /v1/teams/{teamID}/members/{membershipID}` changes a role or
  revokes membership under a transactionally locked role check. Self-mutation,
  Admin escalation and removal of the last Owner fail closed.
- `GET|POST /v1/teams/{teamID}/vaults` lists or creates shared-Vault metadata.
  Only Owner/Admin may create one.

The invitation table stores only an HMAC hash. The opaque token and recipient
are held in an AES-256-GCM outbox envelope under an independent runtime key;
multi-replica delivery uses a bounded `FOR UPDATE SKIP LOCKED` lease. Logs do
not contain recipients, tokens or mail-provider responses. Revoking a member
immediately marks every active shared Vault `rotation_required`; shared content
writes are deliberately absent until the wrapper/rotation protocol is complete.
The same revocation transaction creates one durable rotation task per affected
Vault and removed membership epoch.

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
