// Deliberate operator entry point; never registered by server.mjs.
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import pg from "pg";
import { VaultMigrationStore } from "../src/vault-migration-store.mjs";
import { MigrationFence } from "../src/migration-fence.mjs";
export async function runStagingMigration(
  { environment, enabled, allowedVaultIDs, databaseURL, fencePath },
  request,
) {
  if (
    environment !== "staging" ||
    enabled !== true ||
    !Array.isArray(allowedVaultIDs) ||
    !allowedVaultIDs.length ||
    !databaseURL ||
    !fencePath
  )
    throw Error("migration_staging_only");
  if (
    ![
      "preview",
      "start",
      "upload",
      "validate",
      "discard",
      "activate",
      "check-compatibility",
    ].includes(request?.operation) ||
    Object.keys(request).some(
      (k) =>
        ![
          "operation",
          "input",
          "object",
          "checkpoint",
          "manifest",
          "manifestHash",
        ].includes(k),
    )
  )
    throw Error("invalid_migration_operation");
  const pool = new pg.Pool({ connectionString: databaseURL, max: 2 }),
    fence = new MigrationFence(fencePath),
    store = new VaultMigrationStore(pool, {
      environment,
      enabled,
      allowedVaultIDs,
      fence,
    });
  try {
    if (request.operation === "check-compatibility") {
      const schema = (
        await pool.query(
          "SELECT max(version) AS version FROM schema_migrations",
        )
      ).rows[0];
      const publications = (
        await pool.query(
          'SELECT a.team_id AS "teamID",a.vault_id AS "vaultID",a.id AS "attemptID",a.manifest_hash AS "manifestHash" FROM vault_migration_attempts a JOIN shared_vaults v ON v.active_publication_attempt_id=a.id WHERE a.state=\'V2_ACTIVE\' AND v.format_state=\'V2_ACTIVE\'',
        )
      ).rows;
      await fence.verify({
        schemaVersion: Number(schema.version),
        publications,
      });
      return { compatible: true };
    }
    if (request.operation === "upload")
      return await store.putPart(
        request.input,
        request.object,
        request.checkpoint,
      );
    if (request.operation === "validate")
      return await store.validate(request.input, request.manifest);
    if (request.operation === "activate")
      return await store.activate(request.input, request.manifestHash);
    return await store[request.operation](request.input);
  } finally {
    await pool.end();
  }
}
if (
  process.argv[1] &&
  resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  try {
    // Guard before reading stdin or opening any database connection.
    if (
      process.env.MIGRATION_ENVIRONMENT !== "staging" ||
      process.env.MIGRATION_SYNTHETIC_ENABLED !== "YES"
    )
      throw Error("migration_staging_only");
    const bytes = await readFile(0);
    if (bytes.length > 64 * 1024 * 1024) throw Error("migration_input_limit");
    const result = await runStagingMigration(
      {
        environment: "staging",
        enabled: true,
        allowedVaultIDs: (process.env.MIGRATION_SYNTHETIC_VAULT_IDS ?? "")
          .split(",")
          .filter(Boolean),
        databaseURL: process.env.MIGRATION_STAGING_DATABASE_URL,
        fencePath: process.env.MIGRATION_FENCE_PATH,
      },
      JSON.parse(bytes),
    );
    // Output contains opaque public descriptors, signed records or encrypted parts only.
    process.stdout.write(JSON.stringify(result) + "\n");
  } catch (e) {
    process.stderr.write(
      /^[a-z_]+$/.test(e.message)
        ? e.message + "\n"
        : "migration_operator_failed\n",
    );
    process.exitCode = 1;
  }
}
