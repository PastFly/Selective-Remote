// Deliberate operator entry point; never registered by server.mjs.
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import pg from "pg";
import { VaultMigrationStore } from "../src/vault-migration-store.mjs";
import { MigrationFence } from "../src/migration-fence.mjs";
import { reduceFenceEvents, fenceIntentDigest } from "../src/migration-fence-journal.mjs";
import { PublicationFenceCoordinator, readCommittedPublicationOutcome } from "../src/publication-fence-coordinator.mjs";
import { createStagingActivationGuard, readStagingControllerIdentity } from "../src/staging-activation-policy.mjs";
import { verifyMigrationCompatibility } from "../src/migration-compatibility.mjs";
export async function runStagingMigration(
  { environment, enabled, allowedVaultIDs, databaseURL, fencePath, policyPath, controllerIdentityPath },
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
      "upload-reader",
      "verify-identities",
      "validate",
      "discard",
      "activate",
      "check-compatibility",
      "reconcile-fence",
    ].includes(request?.operation) ||
    Object.keys(request).some(
      (k) =>
        ![
          "operation",
          "input",
          "object",
          "projection",
          "sidecar",
          "checkpoint",
          "manifest",
          "manifestHash",
          "intentID",
        ].includes(k),
    )
  )
    throw Error("invalid_migration_operation");
  if (request.operation === "reconcile-fence" &&
      (typeof request.intentID !== "string" || !/^(?:[a-f0-9]{8}-[a-f0-9]{4}-[1-8][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}|legacy:[a-f0-9]{64})$/.test(request.intentID)
       || Object.keys(request).some(key => !["operation", "intentID"].includes(key))))
    throw Error("invalid_migration_operation");
  if (request.operation === "activate" && (!policyPath || !controllerIdentityPath))
    throw Error("staging_activation_policy_required");
  const fence = new MigrationFence(fencePath);
  const activationGuard = request.operation === "activate"
    ? createStagingActivationGuard({policyPath, fence, controllerIdentity: await readStagingControllerIdentity(controllerIdentityPath)})
    : undefined;
  const pool = new pg.Pool({ connectionString: databaseURL, max: 2 }),
    store = new VaultMigrationStore(pool, {
      environment,
      enabled,
      allowedVaultIDs,
      fence,
      activationGuard,
    });
  try {
    if (request.operation === "reconcile-fence") {
      const rawIntent = (await fence.readRecords()).find(event =>
        event.type === "PENDING_INTENT" ? event.intentID === request.intentID :
          !event.version && "legacy:" + fenceIntentDigest(event) === request.intentID);
      const intent = rawIntent && reduceFenceEvents([rawIntent]).pending[0];
      if (!intent || intent.vaults.some(vault => !allowedVaultIDs.includes(vault.vaultID)))
        throw Error("migration_staging_only");
      return await new PublicationFenceCoordinator({fence}).reconcile({intentID: request.intentID,
        readCommittedOutcome: pending => readCommittedPublicationOutcome({query: (text, values) => pool.query(text, values), intent: pending})});
    }
    if (request.operation === "check-compatibility") {
      return await verifyMigrationCompatibility({
        query: (text, values) => pool.query(text, values),
        fence,
      });
    }
    if (request.operation === "verify-identities")
      return await store.verifyIdentityReservations(request.input);
    if (request.operation === "upload-reader")
      return await store.putReaderProjection(request.input, request.projection, request.sidecar, request.checkpoint);
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
    const chunks = []; let length = 0;
    for await (const chunk of process.stdin) {
      length += chunk.length;
      if (length > 96 * 1024 * 1024) throw Error("migration_input_limit");
      chunks.push(chunk);
    }
    const bytes = Buffer.concat(chunks);
    const result = await runStagingMigration(
      {
        environment: "staging",
        enabled: true,
        allowedVaultIDs: (process.env.MIGRATION_SYNTHETIC_VAULT_IDS ?? "")
          .split(",")
          .filter(Boolean),
        databaseURL: process.env.MIGRATION_STAGING_DATABASE_URL,
        fencePath: process.env.MIGRATION_FENCE_PATH,
        policyPath: process.env.MIGRATION_ACTIVATION_POLICY_PATH,
        controllerIdentityPath: process.env.MIGRATION_CONTROLLER_IDENTITY_PATH,
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
