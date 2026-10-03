# PR C staging acceptance — local controller evidence

This record currently covers local Tasks4–5 only. It does not claim a staging rollout, live activation, or production readiness.

The independently retained controller selects an exact reviewed image/source, checks protected settings and Compose/storage mounts, and runs its own retained compatibility checker before migrations and again before traffic. The checked, migrated and serving environments are bound by exact comparison, using one protected effective environment for checker/migrator. The Compose project is fixed to cloud; foreign existing projects or Docker public listeners reject before migration. Candidate metadata is copied from the selected stopped image without executing candidate code. The checkout launcher cannot choose arbitrary Compose files or start an old image directly. Initial schema12 maintenance is explicit and requires closed traffic and a pristine existing journal.

Local PostgreSQL16 tests used actual custom-format `pg_dump`/`pg_restore` into separate temporary databases. Real initial activations and signed two-Vault whole-publication commits established the newer external history. The controller rejected:

- schema12 restore before any publication query, migration or service start, including the maintenance exception;
- schema22 restore missing the retained Vaults;
- predecessor generation restore;
- an independently committed same-sequence fork with different signed headers;
- a V2_ACTIVE row with a missing pointer, retained by the LEFT JOIN enumeration;
- missing/corrupt journal, unresolved complete multi-Vault intent, unsupported old image capabilities, changed image/source pins and unsafe rendered mounts.

Every negative preserved the independently retained journal bytes and the database's Vault rows. An ordinary synthetic V1 Vault was included in the restore baseline. The standalone check executable returned the same typed denials as the query-order trace. No shared or live database was restored/reset.

The combined controller/storage suite passed **25/25, zero failures/skips**, in 4.841 seconds. Local log: `/tmp/pr-c-controller-review-final-green.log`. The exact command, provisioning contract, initial RED evidence and file ownership are recorded in `.superpowers/sdd/2026-10-03-staging-controller-fence/task-4-report.md`.

The production orchestration itself ran with a substituted command transport for local tests; the checker and PostgreSQL restore were real. Actual Linux/Docker deployment, protected backup restoration evidence from the observed staging runtime, pinned runtime/source/image/controller identities, traffic reopening and lifecycle acceptance remain to be recorded by Tasks6–7. Restoring or deleting both DB and external journal is outside this protection model.

Independent review found and corrected three launcher adapter issues: effective DB/environment divergence, Compose project drift, and valid normalized bind:false omission. Three regression tests failed before the fixes; the final25-test suite includes their GREEN results plus extra env-file rejection and scoped registration validation. Registration remains closed unless the pinned environment explicitly enables the shared exact two-address staging allowlist. No actual email addresses or settings were enabled by this local work.
