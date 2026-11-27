import pg from "pg";
import { loadConfig } from "../src/config.mjs";
import { createConfiguredMigrationFence } from "../src/configured-migration-fence.mjs";
import { upgradeTeamAuthorizationFormat } from "../src/v1-team-authorization.mjs";
import { isPrivatePersonalPilotEnvironment } from "../src/v1-write-fence.mjs";

let pool, runtime;
try {
    const args = process.argv.slice(2);
    if (args.length && (args.length !== 1 || args[0] !== "--preflight")) {
        throw new Error("invalid_deployment_arguments");
    }
    const config = loadConfig();
    if (!isPrivatePersonalPilotEnvironment(config) || !config.deployment.anchor
        || config.deployment.fencePath !== "/publication-fence/journal") {
        throw new Error("deployment_team_authorization_upgrade_scope");
    }
    runtime = createConfiguredMigrationFence(config.deployment);
    pool = new pg.Pool({ connectionString: config.databaseURL, max: 1 });
    const result = await upgradeTeamAuthorizationFormat({ pool, fence: runtime.fence, preflight: args.length === 1 });
    process.stdout.write(JSON.stringify(result) + "\n");
} catch (error) {
    process.stderr.write(/^[a-z_]+$/u.test(error?.message ?? "") ? error.message + "\n" : "deployment_team_authorization_upgrade_failed\n");
    process.exitCode = 1;
} finally {
    await pool?.end();
    await runtime?.close();
}
