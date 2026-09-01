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

1. Select and review the immutable PostgreSQL image/digest. Pull it before the
   storage step; do not combine storage preparation with a major upgrade.
2. Determine the numeric `postgres` UID/GID from that exact image using an
   isolated, no-network inspection. Record the image digest and IDs privately.
3. Export the six non-secret `POSTGRES_DATA_*` values documented by
   `scripts/validate-postgres-storage.sh --help`.
4. Run `validate-postgres-storage.sh --prepare` once. It creates only a missing
   direct-child directory after all mount checks pass. It never recursively
   changes the mount root.
5. Use `start-staging-guarded.sh` for every allowed start. Put the storage
   profile after `compose.yaml` so `!override` replaces the named volume.
   The wrapper parses the rendered model without printing it and refuses to
   start unless the bind, restart policy, closed registration and unpublished
   PostgreSQL/API ports match the contract.

Example order for a new host with ordinary 80/443 ingress:

```bash
scripts/start-staging-guarded.sh \
  compose.yaml \
  compose.postgres-bind.yaml
```

Add other reviewed overlays after `compose.yaml` and before the storage
profile as their documentation requires. The exact storage profile must be
included once and must always be the final Compose file.

## Acceptance before real data

- The final Compose input is the exact reviewed storage profile containing
  `create_host_path: false`; its digest is verified before storage checks.
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
