# Protected production V1 rollout

## Assign the anchor

The anchor operator assigns a dedicated writable PostgreSQL primary, its TLS hostname and CA, a deployment UUID, and an execute-only service role. Record who owns anchor backups and failover. They must be independent of the Cloud host, its primary database and its controller journal. Use the grants and primary requirements in [the anchor specification](INDEPENDENT-FENCE-ANCHOR.md) and install [the schema](scripts/independent-fence-anchor.sql) under the separate administrator. For a first installation with a verified empty journal, provision one row at position zero with the genesis digest returned by `fenceHistoryHead([])` in `src/fence-history-head.mjs`. Never derive a replacement head from a restored journal. A local test fixture demonstrates TLS and protocol behavior only.

## Prepare and verify the controller

Build the rollback and forward images from the reviewed source commits and preload both into Docker. Pin each image’s **local image ID** and matching `org.opencontainers.image.revision` label in the protected settings. The rollback image must implement production Team protocol 1 and Team authorization format 2. The forward image must additionally implement production Personal pilot protocol 1. Preserve the same release pair when changing the active image.

Prepare the independently reviewed controller bundle outside both the release checkout and `/var/lib/selective-remote-controller`. Include the forward controller scripts, migration files, manifest, runtime dependencies and independently verified Node binary. Generate the bundle and runtime checksums against the reviewed contents. Keep the controller and its files root-owned, including its parent directories. Stage the replacement on the same filesystem as the installed bundle, verify its checksum from the approved release record, and preserve the old bundle. Serialize replacement with existing controller operations using the existing state directory’s `controller.lock`. Switch only the controller directory, protected settings and reviewed environment. Leave the journal, archives, backup directory and database mount in place. The staging first-install tool is for a fresh host.

Pin the separately prepared environment and Compose files in `settings.json`. Set `registrationMode` to `production-v1`, `anchorProtocol` to `1`, `anchorDeploymentID` to the assigned UUID, and `productionReleasePair` to an object with `rollback` and `forward` entries, each containing `sourceSHA` and `imageDigest`. Set the top-level source and image to the chosen entry. Use an HTTPS Cloud origin, open registration, `CLOUD_PRODUCTION_TEAM_ENABLED=true`, both V2 publication flags false and empty V2 allowlist. The rollback environment requires Personal pilot support off. The forward environment may enable `CLOUD_PRODUCTION_PERSONAL_PILOT_ENABLED`. Supply the anchor URL and CA through the protected environment.

Run the installed `/opt/selective-remote-controller/scripts/staging-controller.sh --verify-installation`. Its attestation checks the bundle, reviewed environment, Compose files, and both image identities.

## First transition from schema 22

1. Restore a current PostgreSQL backup in isolation. With the pair and an independent test anchor, run the installed launcher with `--inspect-production-baseline` against the restored copy. It returns only the schema version and a digest of the Vault data and Team authorization projection. Rehearse the steps below on this restore. Retain the backup checksum, restore result, digest and both image IDs.
2. In the target controller settings, pin that independently verified digest as `productionBootstrapDigest`. The explicit `--bootstrap-production-pair` action compares the target to this digest before closing ingress, drains the Cloud clients, applies migration 23 and arms the SQL guards. It rechecks the same data under database locks, anchors the baseline and checks both images. It finishes with ingress closed. On a mismatch, take a current backup and repeat the restore comparison. Keep the retained journal and anchor through failures and retries.
3. Run `--verify-production-pair` and then run the installed launcher without arguments. This starts the pinned Cloud app and opens the proxy after its readiness probe succeeds. Verify HTTPS, open signup, Team access with synthetic identities, and closed Personal writes outside the pilot. Remove the optional bootstrap digest from the protected settings after the transition.

For a previously armed baseline, start with `--verify-production-pair`. A different anchor head, restored database, missing guard, unrecognized history, or open pilot stops startup.

## Scoped Personal check and rollback

On the forward image, run the installed launcher with `--production-personal-pilot open PILOT_ID OWNER_ID VAULT_ID MINUTES`. Supply one synthetic account and its Personal Vault, a fresh UUID for the operation, and a duration from 1 through 60 minutes. Check the ordinary client write and readback. Close explicitly with `--production-personal-pilot close PILOT_ID`. The close operation works with either compatible image. Verify closure with `--verify-production-pair`.

To roll back, select the pinned rollback source and image and disable the Personal pilot flag in the protected environment. Update its environment digest. Keep the same independent anchor, journal, database and declared image pair. Use `--verify-production-pair` followed by the normal launcher. It rechecks the authorization and Vault floors before the proxy can open.
