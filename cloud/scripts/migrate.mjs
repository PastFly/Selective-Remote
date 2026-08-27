import pg from "pg";
import { fileURLToPath } from "node:url";
import { applyMigrations } from "../src/migrations.mjs";

const databaseURL = process.env.DATABASE_URL;
if (!databaseURL) throw new Error("DATABASE_URL is required");

const migrationsDirectory = fileURLToPath(new URL("../migrations/", import.meta.url));
const pool = new pg.Pool({ connectionString: databaseURL, max: 1 });

try {
  await applyMigrations(pool, migrationsDirectory, {
    info(message) { console.log(JSON.stringify({ level: "info", message })); },
  });
} finally {
  await pool.end();
}
