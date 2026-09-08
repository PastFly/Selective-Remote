# Cloud-triggered Snippet execution

## Status

Design gate only. This document does not enable remote command execution.

The browser cannot safely connect directly to a private SSH Host, and the Cloud service must never receive an SSH password, private key, plaintext Snippet, or plaintext command output. Browser-triggered execution therefore requires an opt-in trusted execution agent running inside the signed macOS application (or a future separately reviewed headless agent).

## First supported slice

- SSH Hosts only; RDP automation is out of scope.
- Existing, versioned Snippets only; no arbitrary command text from the browser.
- One explicitly selected Host and one explicitly selected online agent.
- Manual approval on the trusted Mac for every run.
- Personal Vault only until Team RBAC and shared-key authorization are proven end to end.
- Bounded runtime, output size, and concurrency.

## Cryptographic route

1. The browser signs an execution intent containing the actor, Host record ID and version, Snippet record ID and version, agent device ID, nonce, expiry, and idempotency key.
2. The browser encrypts the job to the approved agent device public key. Cloud stores only routing metadata and ciphertext.
3. The macOS agent validates the signature, account session, device binding, nonce, expiry, record versions, and local approval before decrypting.
4. The agent resolves the Host and Credential locally, reads secrets from Keychain, and opens SSH without exporting the secret.
5. The agent encrypts bounded output to the requesting browser session key. Cloud relays ciphertext and coarse status only.
6. The audit record stores actor, device, Host/Snippet identifiers and versions, timestamps, decision, exit class, and ciphertext hashes. It excludes command text, output, credentials, and private connection data.

## Required server controls

- Authenticated durable job queue addressed to one approved device.
- Short expiry, unique nonce, idempotency, replay rejection, and cancellation.
- Per-user, per-device, per-Host, and per-Team rate limits.
- Atomic claim/complete transitions and bounded encrypted output chunks.
- Device revocation terminates delivery and invalidates unclaimed jobs.
- Team role checks are repeated when queued, claimed, and completed.
- No generic shell endpoint and no server-side SSH client.

## Required macOS controls

- Execution disabled by default and enabled per device.
- Native approval sheet showing Host, Snippet name, immutable version/hash, requesting account, and expiry.
- No shell interpolation by Cloud. The agent executes the exact locally decrypted Snippet using the existing SSH transport.
- Passwords and private keys remain in Keychain and are never placed in job or audit payloads.
- Redaction and hard byte/time limits before output encryption.
- Immediate stop on version mismatch, revoked device, expired job, lost authorization, or unknown crypto marker.

## Implementation gates

1. Threat-model review and protocol test vectors.
2. Server queue with synthetic ciphertext only.
3. macOS receive/approve/reject loop with no SSH execution.
4. Synthetic local SSH target and encrypted result round trip.
5. Team RBAC, revocation, replay, cancellation, timeout, and audit tests.
6. Owner-tested DMG before any production deployment.
