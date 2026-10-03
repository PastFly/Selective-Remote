# Dedicated PostgreSQL filesystem for closed staging

This optional profile replaces the default Docker-managed `postgres-data`
volume with an explicit host bind. It is intended for a host where PostgreSQL
has a separately mounted filesystem. It does not change the default profile.

The profile is not a backup, HA, disk-resize procedure or permission to expose
the service. Registration must remain disabled, PostgreSQL/API ports must stay
unpublished, and the existing image/security/backup gates still apply.

## Safety model

- The source is a direct child of a verified mount, never the mount root.
- Device, filesystem, writable state, ownership and mode are checked.
- Symlink traversal and an unexpected nested mount are rejected.
- Compose automatic source-directory creation is disabled. Because Compose
  2.40.3 omits the explicit `false` from rendered JSON, the exact reviewed
  storage profile is digest-checked and must be the final Compose file.
- All services use `on-failure:3`, so Docker daemon startup does not bypass the
  operator's guarded startup path.
- A successful preflight does not prove backup/restore or mount-loss recovery.

## Preparation sequence

1. Confirm that the pinned PostgreSQL `tag@sha256` identity matches the reviewed
   target architecture. Pull it before the storage step; do not combine storage
   preparation with a major upgrade.
2. Determine the numeric `postgres` UID/GID from that exact image using an
   isolated, no-network inspection. Record the image digest and IDs privately.
3. Export the six non-secret `POSTGRES_DATA_*` values documented by
   `scripts/validate-postgres-storage.sh --help`.
4. Run `validate-postgres-storage.sh --prepare` once. It creates only a missing
   direct-child directory after all mount checks pass. It never recursively
   changes the mount root.
5. Provision the reviewed controller separately at
   `/opt/selective-remote-controller`, with its protected Node runtime, retained
   checker/dependencies, checksum manifest and root-owned `settings.json`.
   Settings pin the exact source, image, controller, environment-file digest,
   six storage values and ordered Compose paths/digests. The checkout launcher
   accepts no arbitrary Compose inputs. `--help` is safe before provisioning.
6. Put the reviewed Compose files into the protected settings in this order:
   `compose.yaml`, the applicable ingress/resource overlays,
   `compose.publication-fence.yaml`, then `compose.postgres-bind.yaml` last.
   The storage profile must appear exactly once. Explicitly provision the
   independent journal outside the checkout, PostgreSQL data and backup roots;
   startup never initializes missing history.
7. Use the retained controller for every allowed start. It checks the pinned
   image metadata, storage/source/rendered model and DB/journal compatibility,
   closes traffic, migrates the exact image, repeats compatibility checks and
   starts only the pinned cloud/caddy services. It uses the separately retained
   Node runtime and pinned checker image; no system Node installation is needed.

Normal start, using only the reviewed protected settings:

```bash
scripts/start-staging-guarded.sh
```

An initial schema12/V1 upgrade additionally requires the explicit
`--maintenance-upgrade` argument. This closes traffic before checking that the
existing independent journal is pristine and permits the forward migration.
It does not allow an old image, unresolved intent or retained newer history to
be bypassed. See `docs/security/pr-c-staging-acceptance.md` for the scope and
limits of the local controller/restore evidence.

## Acceptance before real data

- The final Compose input is the exact reviewed storage profile containing
  `create_host_path: false`; its digest is verified before any startup.
- Rendered model contains exactly one PostgreSQL mount at
  `/var/lib/postgresql/data`, of type `bind`, with the reviewed source and no
  unsafe bind options.
- PostgreSQL and API ports are not published; registration is false.
- Actual container Mounts match the reviewed model without printing Env.
- Missing mount, wrong device/filesystem, symlink path, wrong ownership and
  missing data path all fail before Compose starts.
- A controlled reboot test shows containers do not auto-start around the guard.
- Backup and restore helpers are tested with the exact final Compose project and
  ordered overlays; an encrypted off-host copy and isolated restore are proven.

Never test mount loss by unmounting a live database. Use disposable fixtures and
synthetic data until the lifecycle and recovery procedure are accepted.
