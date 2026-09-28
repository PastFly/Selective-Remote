# Guided Known Hosts Recovery design

Baseline: public `main` `063e109694d4307343dab8ee7271b114e20a5ffd` (tree `72cd165f50722a40e9238067d62ef4f51edab96b`). This work belongs only to post-0.32 branch `codex/post-032-guided-known-hosts`; the frozen 0.32 RC remains buildable from the baseline.

## Intent and boundary

When OpenSSH stops a connection for a changed host key, the application may offer a guided replacement only if it can identify one exact endpoint and one exact user `known_hosts` entry. A scan is an observation, never proof of identity. The user must compare the new fingerprint through an independent channel and explicitly confirm it. Unsupported or ambiguous cases stay on the existing manual recovery path. Cancellation never edits files or retries.

The guide extends `SSHKnownHostsService`, the existing SSH connection paths, and one native sheet. It does not alter authentication selection, AskPass routing, the production SSH host-key policy, the Cloud API, or the public 0.32 source.

## Trusted route and candidate

The connection settings provide destination host/port/profile ID and, when present, managed Jump Host host/port/profile ID. The role is never inferred from a human-readable SSH prompt. A failure signature only triggers investigation. A managed Jump Host is scanned directly; the destination is observed through a restricted OpenSSH probe over the configured transport. The probe writes a key only to an isolated private temporary `known_hosts`. Its Jump helper is forced to use strict verification against the real user file, regardless of the normal profile policy. Both probe processes ignore user SSH configuration and multiplexing. A candidate is eligible only when an OpenSSH-compatible endpoint lookup selects unambiguous ordinary or hashed entries and exactly one stored algorithm changed; marker, duplicate-algorithm, multi-host and custom host-key configuration ambiguities fail closed. This does not label an unproven hop as the culprit.

The candidate freezes the endpoint, role, profile ID, old entry and line, full source-file bytes, observed algorithm/key bytes and both fingerprints. The UI displays host, port, role, algorithm, old and observed fingerprints. It explains that a reinstall and an attack can produce the same warning and explicitly says that network observation is not independent verification.

## Confirmation and transaction

The confirmation control is separate from opening the sheet and is never a default Enter action. On confirmation the service scans the same route again, compares algorithm and key bytes with the shown observation, rereads the file, proves the exact original entry and full source snapshot still match, and refuses on any discrepancy.

For a supported regular file under an unambiguous path, create an exclusive, uniquely named backup before mutation. Backup mode is `0600` or stricter than the original; never overwrite another backup. Retain a bounded number of application-owned backups only after a successful replacement, without touching user-created backups. Write replacement bytes to an exclusive sibling temporary file, sync it, preserve original mode, atomically rename and verify the resulting file. An application-owned advisory lock serializes its own attempts without a stale crash lock; the service performs a last source-state check immediately before rename. Changes by non-cooperating external writers remain a file-system concurrency boundary requiring a scoped security review and fail-closed handling wherever detected. No other line, comment, algorithm or hostname changes.

## Recovery result and retry

Only a verified successful replacement enables a one-shot retry of the original connection intent. The retry re-resolves profile/settings and retains the original authentication role isolation. Failed, cancelled or ambiguous attempts never retry. The existing error and manual Known Hosts screen remain available. No key material or passwords are written to new logs.

## UI and acceptance

One native sheet presents RU/EN copy, fingerprint copying, independent-verification guidance, Cancel as the safe default, an explicit confirmation control, progress, failure and success through existing status surfaces. Escape cancels. VoiceOver reads role, endpoint, algorithm and both fingerprints. Test direct, managed Jump Host and destination-through-jump separately. Check Graphite/Light and RU/EN in a real app build. Owner manual acceptance of an exact Test DMG remains the final gate.
