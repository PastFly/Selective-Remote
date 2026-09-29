# Trusted device-key authenticity foundation for 0.32

## Goal and boundary

Prepare a dormant, interoperable Mac/browser trust foundation so a future Vault v2 sender cannot wrap a CEK for an unverified server-supplied device key. This PR does not enable CEK delivery, migrate Vaults, add grants, or expose a production trust-mutation route. It advances the 0.32 critical path without declaring malicious-server-resistant E2EE complete.

## Existing system and root choice

The current device key is P-256 ECDH. Mac stores its private scalar in the protected local Cloud envelope; browser stores a non-extractable private CryptoKey in IndexedDB. The server accepts the public key at registration, pins equality on later sessions, and marks approval in the database. The fingerprint and recipient key both come from the server. Personal Vault uses a random AES key wrapped under a passphrase-derived key; it is not an existing account signing identity. Reusing the passphrase as a public-verifiable signing root would add an offline guessing oracle, so this design does not do so.

The first trusted client generates a separate P-256 ECDSA root key locally, stores its private key in protected local storage, and pins the root public-key fingerprint locally before sending anything to the server. It signs its own device certificate and an initial device-directory checkpoint. The server is an untrusted carrier of public records. A second client must receive the root fingerprint and latest checkpoint version through an authenticated out-of-band pairing step with the root custodian; it must never trust a root first learned only from the server. A browser can participate while honest code is running, but a server that delivers hostile JavaScript can alter browser behavior; this is an explicit unsolved web-origin boundary.

Only a device holding the root signing key can approve/revoke other devices in this foundation. A lost sole custodian cannot be silently replaced by the server: account trust reset, conspicuous user confirmation, and future Vault rekey/migration are required. The portable root recovery mechanism is a separate design gate. This deliberately limits availability to avoid inventing an unreviewed key-transfer protocol.

## Compared approaches

1. **Locally generated account root, signed directory (selected):** one pinned root signs device certificates and monotonic directory checkpoints. The certificate is portable and verifies offline. Custodian loss needs an explicit reset. This is the smallest cryptographic foundation that defeats server key substitution for clients holding an independently verified pin.
2. **Passphrase-derived signing root:** convenient recovery but a published verification key would permit offline password guesses, and password entry currently crosses the server login boundary. Rejected.
3. **Transparency log alone:** detects equivocation only with independent witnesses/gossip and availability; it cannot authenticate the first root by itself. A future supplement, not the initial root.
4. **WebAuthn/secure-enclave attestation or Team signing hierarchy:** platform and lifecycle differences require a larger protocol, especially browser and Team admission. Consider later after this foundation and threat review.

## Signed records and canonical format

Use P-256 ECDSA with SHA-256, X9.63 uncompressed 65-byte public keys, and fixed 64-byte `r || s` signatures. The certificate signs a domain-separated, versioned, length-prefixed binary record with: account UUID, device UUID, ECDH public key, key version, issuer root fingerprint, issued-at seconds, and certificate serial UUID. Its signature is a separate field. UUIDs are lowercase canonical text. Every field is bounded; unknown versions/fields/algorithms fail closed. No ambiguous JSON serialization is signed.

The root also signs a directory checkpoint containing account UUID, strictly increasing directory version, and sorted `(device UUID, key version, certificate digest)` entries. Removed/replaced devices disappear from the next checkpoint. The certificate digest uses the exact canonical certificate bytes plus signature. A verifier requires the locally pinned root, valid signatures, an exact matching active checkpoint entry, the expected account/device/key version, and checkpoint version at least the locally stored high-water mark. Successful verification advances the local high-water mark atomically with the accepted checkpoint. If the same device UUID appears with another key without a higher signed directory version and explicit replacement, reject it. Revoke removes the active entry; the next signed checkpoint invalidates old certificates for clients that see it.

The local pin is scoped to normalized Cloud endpoint and account UUID. A newly paired device imports a root fingerprint and checkpoint version through the trusted device, then verifies server-delivered records. Team membership epoch remains separately checked by the existing wrapper context and server admission; a production Team wrapper sender will also need a trusted authorization source for the expected account/Team recipient. This PR does not treat a server-controlled Team membership response as cryptographic proof of policy.

## Wrapper safety and anti-rollback

Expose one high-level dormant `wrapForVerifiedDevice` operation in both Mac and browser. It verifies root pin, signed certificate, signed checkpoint, identity/scope/version and local high-water before calling the existing resource wrapper primitive. A substituted public key, stale checkpoint/certificate, changed device ID, wrong account or revoked entry yields an error before a wrapper is produced. The lower-level wrapper primitive remains for existing tests and no production caller is added.

The local high-water rejects versions already observed to be stale. It cannot detect a new signed checkpoint that a malicious server suppresses before the client learns it, or prevent rollback on a fresh device unless its out-of-band pairing carries a current checkpoint. Certificate trust does not by itself authenticate future grants, Team membership, resource manifests, or server-delivered JavaScript. Those remain explicit 0.32 gates.

## Storage and operations

Add dormant, additive tables for one account root public key, immutable signed device certificates, and immutable signed directory checkpoints. Constrain account/device/version uniqueness and record size. No HTTP route or production registry/wrapper writer is added. Later API work must close the direct-SQL, last-wrapper DELETE and PREPARED-pointer gates before production mutation. Root private keys, CEKs, plaintext and raw signed records must not appear in logs or diagnostics.

## Verification

Tests first: canonical byte agreement between browser and Mac; first-device self certificate; a trusted custodian approving a new Mac/browser ECDH key; wrong account, device, key, serial, issuer, signature, algorithm, directory entry and version; server substitution before CEK wrapping; replacement and revocation; high-water rollback; malformed/truncated records; and browser-to-Mac signed fixture. PostgreSQL migration tests check additive schema/constraints without activating V2. Then run targeted and full Swift/Cloud suites, Release build, formal exact-head security scan, CI and Test DMG. Document the browser code-delivery, custodian loss, offline freshness and Team policy boundaries before requesting an exact-head Owner gate.
