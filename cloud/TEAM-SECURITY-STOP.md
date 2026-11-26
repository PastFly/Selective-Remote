# V1 Team traffic and rollback

Team and invitation endpoints, device trust mutations and Team Vault writes
default to closed. The isolated two-account acceptance option is restricted to
its named staging users and deadline.

The registered production profile may explicitly enable the V1 Team endpoints
with `CLOUD_PRODUCTION_TEAM_ENABLED=true`. It requires HTTPS, open registration,
an independent journal and TLS anchor, schema 23, writer floor 1 and Team
authorization history in format 2. Both publication flags must be off and the
publication Vault allowlist must be empty. The server checks the SQL guards,
retained Vault state and authorization digest before serving requests. Team
operations continue to enforce session, membership, device and Vault permissions.
An older database with mismatched retained history fails readiness.

Released clients fetch public metadata before choosing the Team write protocol.
The registered Team runtime advertises the V1 writer while it can serve Team
traffic. The authenticated Personal availability check and Personal write endpoint
independently enforce Personal eligibility. Enabling Team alone keeps both
closed for every account, including during a rollback with an unexpired
production Personal window. The rollback release can explicitly close that
window. Its retained history continues to require a compatible release afterwards.

Host controller settings pin the eligible release images. The journal and its
TLS anchor must survive application/database rollback independently. See
`tests/v1-registration-fence-http.test.mjs` for registered HTTP behavior and
`tests/v1-team-authorization-postgres.test.mjs` and
`tests/v1-session-rollback-p0.test.mjs` for authorization and session recovery.
