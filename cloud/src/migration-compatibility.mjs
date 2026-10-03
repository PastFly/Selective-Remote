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

export async function verifyMigrationCompatibility({ query, fence }) {
  let schema;
  try {
    schema = await query("SELECT max(version) AS version FROM schema_migrations");
  } catch (error) {
    // A database older than the migration ledger cannot satisfy the floor.
    if (error.code === "42P01") throw Error("deployment_schema_floor");
    throw error;
  }
  const version = schemaVersion(schema);
  await fence.verifySchemaFloor(version);
  const publications = await query(
    'SELECT a.team_id AS "teamID",a.vault_id AS "vaultID",a.id AS "attemptID",a.manifest_hash AS "manifestHash" FROM vault_migration_attempts a JOIN shared_vaults v ON v.active_publication_attempt_id=a.id WHERE a.state=\'V2_ACTIVE\' AND v.format_state=\'V2_ACTIVE\'',
  );
  // Reread retained evidence after the DB await: a new requirement must not be
  // skipped just because the earlier schema check passed.
  await fence.verify({ schemaVersion: version, publications: publications.rows });
  return { compatible: true };
}
