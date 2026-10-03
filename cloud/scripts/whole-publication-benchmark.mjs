import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { writeFile } from 'node:fs/promises';
import { performance } from 'node:perf_hooks';
import { fileURLToPath } from 'node:url';
import { tmpdir } from 'node:os';
import { basename, dirname, resolve } from 'node:path';

// This guard deliberately runs before importing storage, fixtures, or PostgreSQL.
export function validateBenchmarkTarget(env = process.env) {
  if (env.WHOLE_PUBLICATION_BENCHMARK !== '1') throw Error('benchmark_opt_in_required');
  let url;
  try { url = new URL(env.TEST_DATABASE_URL); } catch { throw Error('loopback_test_database_required'); }
  if (!['postgres:', 'postgresql:'].includes(url.protocol)
    || !['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname)
    || !/^\/[a-z][a-z0-9_]*_test$/.test(url.pathname) || url.search || url.hash) {
    throw Error('loopback_test_database_required');
  }
  return { connectionString: env.TEST_DATABASE_URL, databaseName: url.pathname.slice(1) };
}

export function validateBenchmarkOutput(env = process.env) {
  const raw = env.WHOLE_PUBLICATION_BENCHMARK_OUTPUT ?? `pr-b-whole-benchmark-${Date.now()}.json`;
  if (typeof raw !== 'string') throw Error('benchmark_output_path_invalid');
  const output = raw === basename(raw) ? resolve(tmpdir(), raw) : resolve(raw);
  const directories = new Set([resolve(tmpdir()), '/tmp', ...(process.platform === 'darwin' ? ['/private/tmp'] : [])]);
  if (!directories.has(dirname(output)) || !/^pr-b-whole-benchmark-[a-zA-Z0-9_-]+\.json$/.test(basename(output))) {
    throw Error('benchmark_output_path_invalid');
  }
  return output;
}

async function main() {
  const target = validateBenchmarkTarget();
  const names = (process.env.WHOLE_PUBLICATION_BENCHMARK_SCENARIOS ??
    'resources100,resources1000,resources1001,vaults10,vaults11,wrappers10000,wrappers10001').split(',');
  const scenarios = {
    resources100: { resources: 100 }, resources1000: { resources: 1000 },
    resources1001: { resources: 1000, overflowResource: true },
    vaults10: { vaults: 10 }, vaults11: { vaults: 11, overflowVault: true },
    wrappers10000: { resources: 999, devices: 10, custody: 10 },
    wrappers10001: { resources: 999, devices: 10, custody: 1, overflowResource: true },
  };
  if (names.some(name => !Object.hasOwn(scenarios, name))) throw Error('invalid_benchmark_scenario');
  const output = validateBenchmarkOutput();
  // All imports that can reach storage remain after the target guard.
  const [{ default: pg }, { applyMigrations }, fixture, migration, document, wholeClient, crypto, publication, publicationStore, policy] = await Promise.all([
    import('pg'), import('../src/migrations.mjs'), import('../tests/whole-publication-fixtures.mjs'),
    import('../tests/vault-v2-migration-db-fixtures.mjs'), import('../tests/vault-v2-migration-fixtures.mjs'),
    import('../public/whole-publication-client.js'), import('../public/resource-crypto-v2.js'),
    import('../public/vault-publication-v1.js'), import('../src/vault-publication-store.mjs'), import('../src/whole-publication-policy.mjs'),
  ]);
  const pool = new pg.Pool({ connectionString: target.connectionString, max: 1 });
  const queryCost = { count: 0, milliseconds: 0 };
  pool.on('connect', client => {
    const query = client.query;
    client.query = function (...args) {
      queryCost.count++;
      const started = performance.now(); let finished = false;
      const finish = () => { if (!finished) { finished = true; queryCost.milliseconds += performance.now() - started; } };
      const last = args.length - 1;
      if (typeof args[last] === 'function') {
        const callback = args[last]; args[last] = (...values) => { finish(); callback(...values); };
      }
      try {
        const result = query.apply(this, args);
        return result?.finally ? result.finally(finish) : result;
      } catch (error) { finish(); throw error; }
    };
  });
  const report = { version: 1, recordedAt: new Date().toISOString(), database: target.databaseName,
    node: process.version, scope: 'isolated local fixtures; no production capacity or runtime acceptance claim',
    scenarios: [], plans: [] };
  const persist = () => writeFile(output, JSON.stringify(report, null, 2) + '\n');
  const emit = value => console.log(JSON.stringify(value));
  async function stage(result, name, work) {
    const before = { ...queryCost }, start = performance.now(), initial = process.memoryUsage();
    let heapPeakBytes = initial.heapUsed, rssPeakBytes = initial.rss;
    let completed = false;
    const sample = () => { const m = process.memoryUsage(); heapPeakBytes = Math.max(heapPeakBytes, m.heapUsed); rssPeakBytes = Math.max(rssPeakBytes, m.rss); };
    const sampling = setInterval(sample, 25);
    try {
      const value = await work(); completed = true; return value;
    } finally {
      clearInterval(sampling); sample();
      const after = process.memoryUsage();
      const measurement = { name, completed, milliseconds: performance.now() - start, queries: queryCost.count - before.count,
        queryMilliseconds: queryCost.milliseconds - before.milliseconds,
        heapBeforeBytes: initial.heapUsed, heapAfterBytes: after.heapUsed, heapPeakBytes,
        rssBeforeBytes: initial.rss, rssAfterBytes: after.rss, rssPeakBytes };
      result.stages.push(measurement); emit({ scenario: result.name, stage: measurement }); await persist();
    }
  }
  const jsonBytes = value => Buffer.byteLength(JSON.stringify(value));
  function inventory(count) {
    // One real Folder plus count-1 live Hosts. This counts generated folders in the bound.
    return document.legacy(Array.from({ length: count - 1 }, (_, i) => document.record('host', {
      title: `Benchmark host ${i}`, hostname: 'synthetic.example.test', port: 22, folder: 'Benchmark',
    })));
  }
  async function state(teamID) {
    return (await pool.query(`SELECT jsonb_build_object(
      'pointers',(SELECT jsonb_agg(jsonb_build_array(id,active_publication_attempt_id,access_policy_version) ORDER BY id) FROM shared_vaults WHERE team_id=$1),
      'operations',(SELECT count(*) FROM team_publication_operations WHERE team_id=$1),
      'generations',(SELECT count(*) FROM team_publication_generations WHERE team_id=$1),
      'receipts',(SELECT count(*) FROM team_publication_receipts WHERE team_id=$1),
      'outbox',(SELECT count(*) FROM team_publication_outbox WHERE team_id=$1),
      'audit',(SELECT count(*) FROM team_audit_events WHERE team_id=$1)) AS state`, [teamID])).rows[0].state;
  }
  async function seed(options) {
    if (options.vaults) return fixture.seedPublishedTeam(pool, options.vaults);
    let base = null, custodians;
    if (options.devices) {
      base = await migration.seedMigration(pool);
      const extras = await migration.addSyntheticDevices(pool, base, options.devices - 1);
      base.recipient.checkpoint = (await pool.query('SELECT directory_json FROM device_trust_directories_v1 WHERE account_id=$1 ORDER BY version DESC LIMIT 1', [base.accountID])).rows[0].directory_json;
      base.benchmarkDevices = extras;
      custodians = [base.recipient, ...extras.map(d => ({ ...base.recipient, deviceID: d.deviceID,
        certificate: d.certificate, publicKey: d.identity.publicKey }))];
    }
    const f = await fixture.seedPublishedVault(pool, { document: inventory(options.resources), base,
      ...(options.custody === 10 ? { custodianDeviceIDs: custodians.map(d => d.deviceID), custodianTargets: custodians } : {}) });
    const request = fixture.requestFor(f);
    if (options.custody === 10) {
      // Fail visibly if the shared fixture has not supplied genuine predecessor custody.
      assert.equal(f.out.manifest.payload.reader.custodianDeviceIDs.length, 10, 'ten genuine predecessor custodians required');
      request.vaults[0].custodianDeviceIDs = custodians.map(d => d.deviceID).sort();
    }
    return { f, request };
  }
  function identity(f, predecessors) {
    return () => ({ endpoint: f.endpoint, accountID: f.accountID, deviceID: f.deviceID,
      sessionID: f.sessionID, keyVersion: 1, predecessors });
  }
  async function upload(store, f, preview, prepared, result) {
    await store.start(f.input, preview.token, preview.request);
    const checkpoint = { version: prepared.checkpoint.version, nonce: prepared.checkpoint.nonce, ciphertext: prepared.checkpoint.ciphertext };
    let maxRequestBytes = jsonBytes({ token: preview.token, request: preview.request }), requests = 1, projectionChunks = 0, uploadedParts = 0;
    for (const generation of prepared.generations) {
      for (const object of generation.objects) {
        maxRequestBytes = Math.max(maxRequestBytes, jsonBytes({ object })); requests++;
        await store.putPart(f.input, prepared.request.operationID, generation.vaultID, object);
        uploadedParts++;
        if (uploadedParts % 100 === 0) emit({ scenario: result.name, uploadedParts });
      }
      const bytes = Buffer.from(JSON.stringify({ projection: generation.readerProjection, sidecar: generation.administrativeSidecar, checkpoint }));
      const sha256 = createHash('sha256').update(bytes).digest('hex'), count = Math.ceil(bytes.length / (512 * 1024));
      for (let index = 0; index < count; index++) {
        const chunk = { version: 1, index, count, sha256, data: bytes.subarray(index * 512 * 1024, (index + 1) * 512 * 1024).toString('base64url') };
        maxRequestBytes = Math.max(maxRequestBytes, jsonBytes(chunk)); requests++; projectionChunks++;
        const saved = await store.putProjectionChunk(f.input, prepared.request.operationID, generation.vaultID, chunk);
        assert.equal(saved.complete, index === count - 1);
      }
    }
    const manifests = prepared.generations.map(g => ({ vaultID: g.vaultID, manifest: g.manifest }));
    requests++; maxRequestBytes = Math.max(maxRequestBytes, jsonBytes({ manifests }));
    assert.ok(maxRequestBytes <= 1024 * 1024);
    result.upload = { requests, projectionChunks, maxRequestBytes };
    const ready = await store.validate(f.input, prepared.request.operationID, manifests);
    assert.equal(ready.state, 'READY'); return ready;
  }
  async function readAll(f, prepared, receipt) {
    const reader = new publicationStore.VaultPublicationStore(pool, { ...f.config, cursorSecret: 'synthetic-local-benchmark-cursor-secret' });
    let parts = 0, sidecars = 0, bytes = 0, pages = 0, folders = 0, hosts = 0;
    for (const committed of receipt.vaults) {
      const input = { ...f.input, vaultID: committed.vaultID, generationID: committed.generationID, headerHash: committed.headerHash };
      const h = await reader.header(input);
      assert.equal(await publication.verifyReaderHeader({ header: h.header, rootPublicKey: f.root.publicKey, teamID: input.teamID, vaultID: input.vaultID }), committed.headerHash);
      const descriptors = []; let cursor = null;
      do {
        const page = await reader.directory({ ...input, cursor }); pages++;
        assert.ok(page.descriptors.length <= 100); descriptors.push(...page.descriptors); cursor = page.nextCursor;
      } while (cursor);
      await publication.verifyReaderInventory({ inventory: h.inventory, descriptors, header: h.header, rootPublicKey: f.root.publicKey, subject: h.subject });
      for (const descriptor of descriptors) {
        const part = await reader.part({ ...input, resourceID: descriptor.payload.resourceID, part: descriptor.payload.part });
        await publication.verifyReaderDescriptor({ ...part, header: h.header, rootPublicKey: f.root.publicKey });
        const wrapper = part.entry.wrapper, cek = await crypto.unwrapResourceCEK({ wrapper, context: wrapper.context, privateKey: f.identity.privateKey });
        let plaintext;
        try { plaintext = JSON.parse(new TextDecoder().decode(await crypto.decryptResourcePart({ envelope: part.envelope, context: part.envelope.context, cek }))); }
        finally { cek.fill(0); }
        assert.equal(plaintext.link.generationID, committed.generationID);
        assert.equal(plaintext.link.resourceID, descriptor.payload.resourceID);
        assert.equal(plaintext.link.part, descriptor.payload.part);
        if (plaintext.link.kind === 'FOLDER') folders++;
        if (plaintext.link.kind === 'HOST') hosts++;
        bytes += jsonBytes(part); parts++;
      }
      const stored = (await pool.query('SELECT p.administrative_sidecar,a.manifest FROM vault_publication_projections p JOIN vault_migration_attempts a ON a.id=p.attempt_id WHERE p.attempt_id=$1', [committed.generationID])).rows[0];
      assert.deepEqual(stored.manifest, prepared.generations.find(g => g.vaultID === committed.vaultID).manifest);
      const sidecar = stored.administrative_sidecar, wrapper = sidecar.wrappers.find(w => w.context.deviceID === f.deviceID);
      assert.equal(await publication.publicationHash('ciphertext', sidecar.envelope), stored.manifest.payload.reader.sidecarCommitment.envelopeHash);
      const cek = await crypto.unwrapResourceCEK({ wrapper, context: wrapper.context, privateKey: f.identity.privateKey });
      try {
        const plaintext = JSON.parse(new TextDecoder().decode(await crypto.decryptResourcePart({ envelope: sidecar.envelope, context: sidecar.envelope.context, cek })));
        assert.equal(plaintext.generationID, committed.generationID);
      } finally { cek.fill(0); }
      sidecars++; bytes += jsonBytes(sidecar);
    }
    assert.equal(parts, prepared.generations.reduce((n, g) => n + g.objects.length, 0));
    return { parts, sidecars, folders, hosts, pages, transportEncodedBytes: bytes };
  }
  async function verifyFreshKeys(f, prepared) {
    const predecessors = new Map((f.vaults ?? [f]).map(v => [v.input.vaultID, v.out]));
    let parts = 0;
    for (const generation of prepared.generations) {
      const old = predecessors.get(generation.vaultID);
      const previous = new Map([...old.objects, old.administrativeSidecar].map(o => [`${o.resourceID}/${o.part}`, o]));
      for (const object of [...generation.objects, generation.administrativeSidecar]) {
        const prior = object === generation.administrativeSidecar ? old.administrativeSidecar : previous.get(`${object.resourceID}/${object.part}`); assert.ok(prior);
        assert.notEqual(object.envelope.nonce, prior.envelope.nonce);
        const openKey = async value => {
          const wrapper = value.wrappers.find(w => w.context.deviceID === f.deviceID);
          return crypto.unwrapResourceCEK({ wrapper, context: wrapper.context, privateKey: f.identity.privateKey });
        };
        const a = await openKey(prior), b = await openKey(object);
        try { assert.ok(a.some((byte, index) => byte !== b[index]), 'every successor CEK must be fresh'); }
        finally { a.fill(0); b.fill(0); }
        parts++;
      }
    }
    return { freshCEKsAndNonces: parts };
  }
  async function verifyOtherDeviceWrappers(f, prepared) {
    let wrappers = 0;
    for (const generation of prepared.generations) {
      const stored = (await pool.query('SELECT object FROM vault_migration_parts WHERE attempt_id=$1 ORDER BY resource_id,part', [generation.generationID])).rows;
      const published = (await pool.query('SELECT p.projection,p.administrative_sidecar,a.manifest FROM vault_publication_projections p JOIN vault_migration_attempts a ON a.id=p.attempt_id WHERE p.attempt_id=$1', [generation.generationID])).rows[0];
      const projection = published.projection;
      const targets = [f.recipient, ...f.benchmarkDevices.map(d => ({ ...f.recipient, deviceID: d.deviceID,
        certificate: d.certificate, publicKey: d.identity.publicKey }))];
      const sidecarProof = await publication.prepareAdministrativeSidecarCommitment(published.administrative_sidecar, targets);
      assert.deepEqual(sidecarProof.commitment, published.manifest.payload.reader.sidecarCommitment);
      const descriptors = new Map(projection.descriptors.map(d => [`${d.payload.resourceID}/${d.payload.part}`, d]));
      for (const device of f.benchmarkDevices ?? []) {
        const recipient = projection.recipients.find(r => r.inventory.payload.deviceID === device.deviceID); assert.ok(recipient);
        const proofs = new Map(recipient.proofs.map(p => [`${p.resourceID}/${p.part}`, p]));
        for (const { object } of stored) {
          const key = `${object.resourceID}/${object.part}`, item = proofs.get(key); assert.ok(item);
          await publication.verifyReaderDescriptor({ descriptor: descriptors.get(key), header: projection.header,
            rootPublicKey: f.root.publicKey, envelope: object.envelope, entry: item.entry, proof: item.proof });
          const wrapper = item.entry.wrapper, cek = await crypto.unwrapResourceCEK({ wrapper, context: wrapper.context, privateKey: device.identity.privateKey });
          try {
            const plaintext = JSON.parse(new TextDecoder().decode(await crypto.decryptResourcePart({ envelope: object.envelope, context: object.envelope.context, cek })));
            assert.equal(plaintext.link.generationID, generation.generationID); assert.equal(plaintext.link.resourceID, object.resourceID);
          } finally { cek.fill(0); }
          wrappers++;
        }
        const item = sidecarProof.items.find(p => p.entry.wrapper.context.deviceID === device.deviceID);
        if (item) {
          await publication.verifyWrapperProof({ ...item, root: sidecarProof.commitment.wrapperRoot });
          const wrapper = item.entry.wrapper, cek = await crypto.unwrapResourceCEK({ wrapper, context: wrapper.context, privateKey: device.identity.privateKey });
          try {
            const plaintext = JSON.parse(new TextDecoder().decode(await crypto.decryptResourcePart({ envelope: published.administrative_sidecar.envelope, context: published.administrative_sidecar.envelope.context, cek })));
            assert.equal(plaintext.generationID, generation.generationID);
          } finally { cek.fill(0); }
          wrappers++;
        }
      }
    }
    return { certifiedOtherDevices: f.benchmarkDevices?.length ?? 0, wrappersDecryptedFromCommittedStorage: wrappers };
  }
  async function plans(f, request, prepared, scenario) {
    const generation = prepared.generations[0], resource = generation.objects[0];
    // The recipient cursor filters signed descriptors in application memory after this projection lookup.
    const statements = [
      ['active_projection_for_cursor', `SELECT a.*,p.projection,p.header_hash FROM shared_vaults v JOIN vault_migration_attempts a ON a.id=v.active_publication_attempt_id AND a.team_id=v.team_id AND a.vault_id=v.id JOIN vault_publication_projections p ON p.attempt_id=a.id AND p.team_id=a.team_id AND p.vault_id=a.vault_id WHERE v.team_id=$1 AND v.id=$2 AND v.format_state='V2_ACTIVE' AND v.format_schema_version=2 AND a.state='V2_ACTIVE' AND a.manifest->'payload'->'reader' IS NOT NULL AND NOT v.rotation_required AND v.access_policy_version=(a.scope->>'policyVersion')::bigint`, [f.input.teamID, generation.vaultID]],
      ['part_identity_lookup', 'SELECT object FROM vault_migration_parts WHERE attempt_id=$1 AND resource_id=$2 AND part=$3', [generation.generationID, resource.resourceID, resource.part]],
      ['identity_reservation_lookup', 'SELECT id,kind,deleted_at FROM vault_resource_identity_reservations WHERE team_id=$1 AND vault_id=$2 AND id=ANY($3::uuid[])', [f.input.teamID, generation.vaultID, generation.objects.map(o => o.resourceID)]],
      ['operation_lookup', 'SELECT *,to_jsonb(effective_at) AS effective_time FROM team_publication_operations WHERE id=$1', [request.operationID]],
      ['operation_scope_index', 'SELECT id FROM team_publication_operations WHERE team_id=$1 AND actor_user_id=$2 AND actor_device_id=$3 ORDER BY created_at LIMIT 100', [f.input.teamID, f.accountID, f.deviceID]],
      ['outbox_pending', 'SELECT * FROM team_publication_outbox WHERE delivered_at IS NULL AND available_at<=now() ORDER BY available_at,id LIMIT 100', []],
      ['projection_chunk_cursor', 'SELECT chunk_index,chunk_data FROM team_publication_upload_chunks WHERE operation_id=$1 AND vault_id=$2 ORDER BY chunk_index', [request.operationID, generation.vaultID]],
    ];
    await pool.query('ANALYZE');
    for (const [name, sql, values] of statements) {
      const plan = (await pool.query('EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ' + sql, values)).rows[0]['QUERY PLAN'][0];
      report.plans.push({ scenario, operationID: request.operationID, name, sql, plan }); emit({ scenario, explain: name, ...plan });
    }
  }
  try {
    report.postgres = (await pool.query('SELECT version() AS version')).rows[0].version;
    assert.match(report.postgres, /PostgreSQL 16\./);
    await applyMigrations(pool, fileURLToPath(new URL('../migrations/', import.meta.url)), { info() {} });
    report.migrations = (await pool.query('SELECT version,name,checksum_sha256 FROM schema_migrations ORDER BY version')).rows;
    for (const name of names) {
      const options = scenarios[name], result = { name, stages: [] }; report.scenarios.push(result);
      const { f, request } = await stage(result, 'initial_published_generation', () => seed(options));
      const store = fixture.storeFor(pool, f);
      const before = await state(f.input.teamID);
      if (options.overflowResource) {
        const resourceID = document.uuid();
        request.vaults[0].resources.push({ id: resourceID, kind: 'HOST', parentFolderID: null, sourceOrdinal: options.resources });
        request.vaults[0].contentChanges.push({ resourceID, part: 'GENERAL' });
        if (options.devices) {
          // Initial migration grants each resource explicitly; the new Host needs its own ten-device fanout.
          const grant = request.vaults[0].policy.find(g => g.targetKind === 'RESOURCE' && g.principalKind === 'USER'); assert.ok(grant);
          request.vaults[0].policy.push({ ...grant, id: document.uuid(), targetID: resourceID });
        }
      }
      if (options.overflowResource || options.overflowVault) {
        let rejected;
        await stage(result, 'boundary_rejection', async () => {
          try { await store.preview(f.input, request); } catch (error) { rejected = error; }
          assert.ok(rejected, 'overflow must reject'); assert.equal(rejected.message, 'publication_limit');
          assert.deepEqual(await state(f.input.teamID), before);
        });
        result.rejection = { code: rejected.code ?? rejected.message, counts: rejected.counts, noStateChanges: true };
        result.status = 'typed_limit'; await persist(); emit({ scenario: name, ...result.rejection }); continue;
      }
      const preview = await stage(result, 'paged_signed_preview', async () => {
        Object.assign(request, policy.validateWholePublicationRequest(request, (await store.context(f.input)).current));
        const first = await store.preview(f.input, request);
        return wholeClient.collectWholePublicationPreview({ request, getIdentity: identity(f, first.binding.predecessors),
          transport: { preview: (value, page) => store.preview(f.input, value, page) } });
      });
      const originalExpiry = store.tokens.claims(preview.token).expiresAt;
      result.counts = preview.binding.counts;
      if (name === 'wrappers10000') assert.equal(result.counts.wrappers, 10000);
      const prepared = await stage(result, 'fresh_prepare_encrypt_all_parts', () => fixture.prepareWholeFixture(f, preview));
      result.freshCrypto = await stage(result, 'verify_fresh_cek_and_nonce_each_part_and_sidecar', () => verifyFreshKeys(f, prepared));
      result.bytes = { preparedCiphertextAndSidecar: prepared.generations.reduce((n, g) => n + g.objects.reduce((p, o) => p + jsonBytes(o), 0) + jsonBytes(g.administrativeSidecar), 0),
        projections: prepared.generations.reduce((n, g) => n + jsonBytes(g.readerProjection), 0),
        encryptedCheckpoint: jsonBytes(prepared.checkpoint) };
      await stage(result, 'upload_chunks_and_ready', () => upload(store, f, preview, prepared, result));
      let commitToken = preview.token;
      if (Date.now() + 5000 >= originalExpiry) {
        // Renew only consent for the already immutable operation, never widen it.
        commitToken = await stage(result, 'same_operation_exact_binding_preview_renewal', async () => {
          const renewed = await store.preview(f.input, request);
          assert.deepEqual(renewed.binding, preview.binding);
          assert.deepEqual(renewed.request, preview.request);
          assert.deepEqual(renewed.generations, preview.generations);
          return renewed.token;
        });
        result.previewRenewal = { originalExpired: Date.now() >= originalExpiry, exactBindingRetained: true };
      }
      const receipt = await stage(result, 'atomic_commit', () => store.commit(f.input, request.operationID, commitToken, request));
      assert.equal(receipt.vaults.length, request.vaults.length);
      await stage(result, 'receipt_manifest_readback', async () => {
        assert.deepEqual(await store.receipt(f.input, request.operationID), receipt);
        for (const v of receipt.vaults) {
          const readback = await store.readback(f.input, request.operationID, v.vaultID);
          assert.equal(readback.headerHash, v.headerHash); assert.equal(readback.header.payload.sequence, 2);
        }
      });
      result.readback = await stage(result, 'recipient_verify_decrypt_all_parts', () => readAll(f, prepared, receipt));
      if (f.benchmarkDevices?.length) result.otherDevices = await stage(result, 'certified_other_devices_verify_decrypt_committed_storage', () => verifyOtherDeviceWrappers(f, prepared));
      await plans(f, request, prepared, name); result.status = 'committed_and_decrypted'; await persist();
      emit({ scenario: name, status: result.status, counts: result.counts, bytes: result.bytes, upload: result.upload, readback: result.readback });
    }
    report.maxRSSKiB = process.resourceUsage().maxRSS; await persist(); emit({ complete: true, output });
  } catch (error) {
    const failed = report.scenarios.at(-1); if (failed) failed.status = 'failed';
    report.maxRSSKiB = process.resourceUsage().maxRSS;
    report.failure = { scenario: failed?.name, code: error.code ?? error.message, message: error.message, stack: error.stack };
    await persist(); throw error;
  } finally { await pool.end(); }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  main().catch(error => { console.error(error.message); process.exitCode = 1; });
}
