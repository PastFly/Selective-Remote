import pg from "pg";
import { loadConfig } from "../src/config.mjs";
import { createConfiguredMigrationFence } from "../src/configured-migration-fence.mjs";
import { currentCapabilities, verifyDeploymentCompatibility } from "../src/deployment-compatibility.mjs";
import { isUUID } from "../src/security.mjs";
import { isPrivatePersonalPilotEnvironment } from "../src/v1-write-fence.mjs";

let pool, configuredFence;
try {
  const args = process.argv.slice(2);
  const [action, pilotID, ownerID, vaultID, minutes] = args;
  const open = action === "open" && args.length === 5 && [ownerID, vaultID].every(isUUID)
    && /^(?:[1-9]|[1-5][0-9]|60)$/.test(minutes);
  const close = action === "close" && args.length === 2;
  if (!isUUID(pilotID) || (!open && !close)) throw Error("invalid_personal_pilot_arguments");

  const config = loadConfig();
  if (!isPrivatePersonalPilotEnvironment(config) || !config.deployment.anchor) {
    throw Error("personal_pilot_environment_unavailable");
  }
  pool = new pg.Pool({ connectionString: config.databaseURL, max: 1, connectionTimeoutMillis: 5000 });
  configuredFence = createConfiguredMigrationFence(config.deployment);
  const evidence = await verifyDeploymentCompatibility({
    query: (sql, values) => pool.query(sql, values),
    fence: configuredFence.fence, candidate: currentCapabilities,
  });
  if (evidence.writerFloor !== 1) throw Error("personal_pilot_writer_floor_unavailable");
  const issuedAt = Date.now();
  await configuredFence.fence.append(open
    ? { version: 2, type: "V1_PERSONAL_PILOT_OPENED", pilotID, ownerID, vaultID,
      issuedAt, expiresAt: issuedAt + Number(minutes) * 60_000 }
    : { version: 2, type: "V1_PERSONAL_PILOT_CLOSED", pilotID });
  process.stdout.write(open ? "personal_pilot_opened\n" : "personal_pilot_closed\n");
} catch (error) {
  process.stderr.write(/^[a-z_]+$/.test(error?.message ?? "") ? error.message + "\n" : "personal_pilot_failed\n");
  process.exitCode = 1;
} finally {
  await configuredFence?.close();
  await pool?.end();
}
