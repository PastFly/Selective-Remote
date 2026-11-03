function schemaVersion(result) {
  const value = Array.isArray(result?.rows) && result.rows.length === 1
    ? result.rows[0]?.version
    : undefined;
  // pg returns bigint as a decimal string. Do not coerce null, arrays or
  // noncanonical numeric strings into a valid deployment schema.
  const version = typeof value === "string" && /^(0|[1-9][0-9]*)$/.test(value)
    ? Number(value)
    : typeof value === "number" ? value : NaN;
  if (!Number.isSafeInteger(version) || version < 0)
    throw Error("deployment_schema_floor");
  return version;
}

export async function readMigrationSchemaVersion(query) {
  let schema;
  try {
    schema = await query("SELECT max(version) AS version FROM schema_migrations");
  } catch (error) {
    // A database older than the migration ledger cannot satisfy the floor.
    if (error.code === "42P01") throw Error("deployment_schema_floor");
    throw error;
  }
  return schemaVersion(schema);
}

export async function readActivePublications(query, version) {
  const sql = version < 20
    ? 'SELECT v.team_id AS "teamID",v.id AS "vaultID",v.active_publication_attempt_id AS "attemptID",a.manifest_hash AS "manifestHash" FROM shared_vaults v LEFT JOIN vault_migration_attempts a ON a.id=v.active_publication_attempt_id AND a.team_id=v.team_id AND a.vault_id=v.id AND a.state=\'V2_ACTIVE\' WHERE v.format_state=\'V2_ACTIVE\''
    : `SELECT v.team_id AS "teamID",v.id AS "vaultID",v.active_publication_attempt_id AS "attemptID",v.active_publication_attempt_id AS "generationID",
        a.manifest_hash AS "manifestHash",p.header_hash AS "headerHash",p.projection->'header'->'payload'->>'sequence' AS sequence
       FROM shared_vaults v LEFT JOIN vault_migration_attempts a ON a.id=v.active_publication_attempt_id AND a.team_id=v.team_id AND a.vault_id=v.id AND a.state='V2_ACTIVE'
       LEFT JOIN vault_publication_projections p ON p.attempt_id=a.id AND p.team_id=a.team_id AND p.vault_id=a.vault_id
       WHERE v.format_state='V2_ACTIVE'`;
  const result = await query(sql);
  if (!Array.isArray(result?.rows)) throw Error("deployment_fence_mismatch");
  return result.rows.map((row) => {
    if (!row || typeof row !== "object") throw Error("deployment_fence_mismatch");
    if (row.sequence == null) return row;
    return { ...row, sequence: schemaVersion({ rows: [{ version: row.sequence }] }) };
  });
}

export async function verifyMigrationCompatibility({ query, fence }) {
  const version = await readMigrationSchemaVersion(query);
  await fence.verifySchemaFloor(version);
  const publications = await readActivePublications(query, version);
  // Reread retained evidence after the DB await: a new requirement must not be
  // skipped just because the earlier schema check passed.
  await fence.verify({ schemaVersion: version, publications });
  return { compatible: true };
}
