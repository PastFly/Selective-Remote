// Experimental database-side barrier. Do not wire its arming operation into
// deployment: a post-barrier backup can still hide later V1 writes because the
// independent journal does not yet retain per-Vault revision/ciphertext minima.
const marker = 'selective_remote.v1_writer_protocol';
const functionBody = `
      BEGIN
        IF pg_catalog.current_setting('selective_remote.v1_writer_protocol', true) IS DISTINCT FROM 'framed-v1' THEN
          RAISE EXCEPTION 'v1_writer_upgrade_required' USING ERRCODE = 'P0001';
        END IF;
        RETURN NEW;
      END `;
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
      RETURNS trigger LANGUAGE plpgsql AS $$${functionBody}$$`);
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

export async function holdV1CommitFence(client) {
  // Hold the table locks through COMMIT/ROLLBACK: a concurrent restore or DDL
  // cannot invalidate the verified triggers after the check and before write.
  await client.query('LOCK TABLE public.personal_vaults, public.shared_vaults, public.vault_revisions, public.shared_vault_revisions IN ROW EXCLUSIVE MODE');
  await assertV1CommitFence((sql, values) => client.query(sql, values));
  await useFramedV1Writer(client);
}

// Test-only candidate. Closing ingress and draining connections are necessary
// but do not fix the missing per-Vault restore history described above.
export async function armV1CommitFence({ pool, fence }) {
  await fence.assertWritable();
  const before = await fence.snapshot();
  const floor = before?.writerFloor ?? 0;
  if (![0, 1].includes(floor) || before?.pending?.length) throw Error('deployment_writer_floor');
  const client = await pool.connect();
  try {
    const result = await client.query(`SELECT count(*)::int AS count FROM pg_catalog.pg_stat_activity
      WHERE datname=pg_catalog.current_database() AND pid<>pg_catalog.pg_backend_pid()
        AND backend_type='client backend'`);
    if (Number(result.rows[0]?.count) !== 0) throw Error('v1_writer_not_drained');
  } finally { client.release(); }
  // Never reinstall missing triggers when a retained floor already exists: it
  // could be a restored older database whose lost writes must not be hidden.
  if (!floor) await installV1CommitFence(pool);
  await assertV1CommitFence((sql, values) => pool.query(sql, values));
  if (!floor) await fence.append({ version: 2, type: 'V1_WRITER_FLOOR', writerProtocol: 1 });
  const after = await fence.snapshot();
  if (after?.writerFloor !== 1 || after.pending?.length) throw Error('deployment_writer_floor');
  await assertV1CommitFence((sql, values) => pool.query(sql, values));
  return { writerFloor: 1 };
}

// This only verifies the database component. An independently retained floor,
// protected controller and restricted DDL privileges are still mandatory.
export async function assertV1CommitFence(query) {
  const expected = new Map(tables.map(([name, event]) => [name, {
    type: event.startsWith('UPDATE OF ') ? 19 : 23,
    columns: event.startsWith('UPDATE OF ') ? event.slice(10).split(', ') : [],
  }]));
  const result = await query(`SELECT c.relname, t.tgtype, t.tgenabled, t.tgnargs,
      t.tgdeferrable, t.tginitdeferred, t.tgconstraint,
      pg_catalog.pg_get_expr(t.tgqual,t.tgrelid) AS condition,
      ARRAY(SELECT a.attname::text FROM pg_catalog.unnest(t.tgattr::int2[]) WITH ORDINALITY AS x(num,ord)
        JOIN pg_catalog.pg_attribute a ON a.attrelid=c.oid AND a.attnum=x.num ORDER BY x.ord) AS columns,
      p.prosrc,p.prosecdef,p.proconfig,pn.nspname AS proc_schema,p.proname,l.lanname,
      p.prorettype='pg_catalog.trigger'::pg_catalog.regtype AS returns_trigger
    FROM pg_catalog.pg_trigger t JOIN pg_catalog.pg_class c ON c.oid=t.tgrelid
    JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
    JOIN pg_catalog.pg_proc p ON p.oid=t.tgfoid
    JOIN pg_catalog.pg_namespace pn ON pn.oid=p.pronamespace
    JOIN pg_catalog.pg_language l ON l.oid=p.prolang
    WHERE n.nspname='public' AND t.tgname='selective_remote_framed_v1_writer' AND NOT t.tgisinternal`);
  if (!result || !Array.isArray(result.rows) || result.rows.length !== expected.size) throw Error('v1_writer_fence_missing');
  for (const row of result.rows) {
    const rule = expected.get(row.relname);
    if (!rule || Number(row.tgtype) !== rule.type || row.tgenabled !== 'O' || Number(row.tgnargs) !== 0
      || row.tgdeferrable !== false || row.tginitdeferred !== false || Number(row.tgconstraint) !== 0
      || row.condition !== null || !Array.isArray(row.columns) || row.columns.join(',') !== rule.columns.join(',')
      || row.prosrc !== functionBody || row.prosecdef !== false || row.proconfig !== null
      || row.proc_schema !== 'public' || row.proname !== 'selective_remote_require_framed_v1_writer'
      || row.lanname !== 'plpgsql' || row.returns_trigger !== true) throw Error('v1_writer_fence_missing');
    expected.delete(row.relname);
  }
  if (expected.size) throw Error('v1_writer_fence_missing');
  return true;
}
