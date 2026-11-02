// A database-side barrier for the legacy whole-Vault write cutover. This module
// is intentionally not wired to deployment: an independent, durable controller
// floor and restore policy are still required before this can protect rollback.
const marker = 'selective_remote.v1_writer_protocol';
const tables = [
  ['personal_vaults', 'UPDATE OF revision, envelope_version, wrapped_key, ciphertext, nonce, auth_tag, content_hash'],
  ['shared_vaults', 'UPDATE OF revision, key_generation, envelope_version, ciphertext, nonce, auth_tag, content_hash'],
  ['vault_revisions', 'INSERT OR UPDATE'],
  ['shared_vault_revisions', 'INSERT OR UPDATE'],
];

export async function installV1CommitFence(pool) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    // DDL waits for transactions that already modified any protected table.
    // Once it commits, later old writers cannot cross this boundary.
    await client.query('LOCK TABLE public.personal_vaults, public.shared_vaults, public.vault_revisions, public.shared_vault_revisions IN ACCESS EXCLUSIVE MODE');
    await client.query(`CREATE OR REPLACE FUNCTION public.selective_remote_require_framed_v1_writer()
      RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF pg_catalog.current_setting('selective_remote.v1_writer_protocol', true) IS DISTINCT FROM 'framed-v1' THEN
          RAISE EXCEPTION 'v1_writer_upgrade_required' USING ERRCODE = 'P0001';
        END IF;
        RETURN NEW;
      END $$`);
    for (const [table, events] of tables) {
      await client.query(`DROP TRIGGER IF EXISTS selective_remote_framed_v1_writer ON public.${table}`);
      await client.query(`CREATE TRIGGER selective_remote_framed_v1_writer BEFORE ${events} ON public.${table}
        FOR EACH ROW EXECUTE FUNCTION public.selective_remote_require_framed_v1_writer()`);
    }
    await client.query('COMMIT');
  } catch (error) {
    try { await client.query('ROLLBACK'); } catch {}
    throw error;
  } finally { client.release(); }
}

export async function useFramedV1Writer(client) {
  await client.query('SELECT pg_catalog.set_config($1, $2, true)', [marker, 'framed-v1']);
}
