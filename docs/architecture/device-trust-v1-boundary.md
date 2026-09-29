# Device-key trust v1 boundary (dormant 0.32 foundation)

## Existing state

Mac and browser already generate P-256 ECDH device keys locally. The Mac private scalar is held in the protected Cloud envelope; the browser key is non-extractable in IndexedDB. The server accepts the public key at registration, checks equality in later sessions, and records an approval timestamp. Those checks do not authenticate a key to a different client: the server can substitute both the public key and its displayed fingerprint. Personal Vault password wrapping is not an account signing root. Existing v1 Vaults and Team membership remain unchanged by this foundation.

## Trust bootstrap and pairing

The first trusted client generates a separate P-256 ECDSA account root. The Mac stores its scalar in the protected local envelope; the browser stores a non-extractable signing CryptoKey in IndexedDB. The client pins the SHA-256 fingerprint of the root's X9.63 public key locally for the normalized Cloud endpoint and account UUID. It signs its own ECDH device certificate and the initial directory checkpoint. The server carries these public records but cannot make an unpaired client trust a root.

A second device needs the root fingerprint, endpoint, account UUID, current signed directory digest and version from an authenticated out-of-band exchange with the custodian. The custodian signs a certificate for the second device's ECDH public key, and a higher-version directory checkpoint that includes it. Merely receiving those values from the Cloud API is insufficient. Pairing UI, transport and account recovery remain separate implementation gates; there is no production pairing route in this PR.

The sole root custodian can approve, replace or revoke device keys. A replacement requires a new signed certificate with a higher key version and a higher directory version. Revocation removes the device from the next signed directory. Loss of the sole custodian requires an explicit trust reset and future Vault rekey; the server cannot silently create a replacement root. A portable root recovery mechanism needs a separate reviewed design.

## Verification and limits

The dormant wrapper gate compares the root to the local pin, verifies raw P-256 ECDSA signatures over domain-separated canonical bytes, checks account/device/key version, matches the exact certificate digest in the active signed directory, rejects rollback below the local high-water version and persists the accepted high-water before wrapping. A same-version directory must retain the previously pinned digest. A failed check produces no wrapper. The low-level v2 wrapper primitive remains available for tests but has no production caller.

Signed records have fixed fields and lengths; unknown algorithms or versions fail. The browser and Mac formats are cross-checked with a browser-produced fixture. PostgreSQL migration 015 adds append-only-by-update public record tables, scoped uniqueness and size constraints. There is no public write API or production mutation path. Direct-SQL insert/delete races, signed-directory version allocation and registry/wrapper concurrency still require hardening before any production API.

The high-water mark only detects a rollback after the client has learned a newer checkpoint. A malicious server can suppress a checkpoint that the client has never seen; offline clients need a fresh authenticated pairing or witness before they can know the latest state. A compromised web origin can ship hostile JavaScript and bypass browser verification. Device certificate trust does not prove Team membership, grants, ACL policy, resource manifests or browser code integrity. Those remain separate 0.32 release gates. Nothing in this foundation activates `V2_ACTIVE`, CEK delivery, grants, groups or ACL enforcement.
