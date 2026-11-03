import { readFile } from 'node:fs/promises';
import { readMigrationSchemaVersion, readActivePublications } from './migration-compatibility.mjs';
import { assertV1CommitFence, requireIndependentV1Anchor } from './v1-commit-fence.mjs';
import { assertV1DataFloor } from './v1-data-fence.mjs';

export const currentCapabilities = Object.freeze(JSON.parse(await readFile(new URL('../deployment-compatibility.json', import.meta.url), 'utf8')));
function requireCandidate(candidate) {
  const keys = ['fenceVersion', 'maxSchemaVersion', 'readerProjectionVersion', 'version', 'wholePublicationVersion'];
  const legacy = candidate && Object.keys(candidate).sort().join(',') === keys.join(',');
  const writerAware = candidate && Object.keys(candidate).sort().join(',') === [...keys, 'v1WriterProtocol'].sort().join(',')
    && candidate.v1WriterProtocol === 1;
  const emptyCreateAware = candidate && Object.keys(candidate).sort().join(',') === [...keys, 'v1WriterProtocol', 'emptyVaultCreationVersion'].sort().join(',')
    && candidate.v1WriterProtocol === 1 && candidate.emptyVaultCreationVersion === 1;
  const fields=Object.keys(candidate??{}).sort().join(',');
  const variants=[['v1AnchorProtocol'],['wrapperEnvelopeVersion'],['v1AnchorProtocol','wrapperEnvelopeVersion']];
  const extended=variants.some(extra=>fields===[...keys,'v1WriterProtocol','emptyVaultCreationVersion',...extra].sort().join(',')
    &&candidate.v1WriterProtocol===1&&candidate.emptyVaultCreationVersion===1&&extra.every(k=>candidate[k]===1));
  if ((!legacy && !writerAware && !emptyCreateAware && !extended)
      || candidate.version !== 1 || candidate.fenceVersion !== 2 || candidate.maxSchemaVersion !== 22
      || candidate.readerProjectionVersion !== 1 || candidate.wholePublicationVersion !== 1)
    throw Error('deployment_code_floor');
}
function requireWriterFloor(snapshot, candidate) {
  if (snapshot?.emptyVaultCreationVersion === 1 && candidate.emptyVaultCreationVersion !== 1) throw Error('deployment_code_floor');
  if (snapshot?.wrapperEnvelopeVersion === 1 && candidate.wrapperEnvelopeVersion !== 1) throw Error('deployment_code_floor');
  const floor = snapshot?.writerFloor ?? 0;
  if (![0, 1].includes(floor) || floor > (candidate.v1WriterProtocol ?? 0)) throw Error('deployment_writer_floor');
  return floor;
}
function requireResolved(snapshot) {
  if (!snapshot || !Array.isArray(snapshot.pending) || !Array.isArray(snapshot.committed) || !Array.isArray(snapshot.outcomes))
    throw Error('invalid_deployment_fence');
  if (snapshot.pending.length || snapshot.v1Pending?.length) throw Error('deployment_fence_pending');
}
function samePublication(record, row) {
  if (!row || row.teamID !== record.teamID || row.vaultID !== record.vaultID || row.manifestHash !== record.manifestHash) return false;
  if (record.generationID !== undefined)
    return row.generationID === record.generationID && row.sequence === record.sequence && row.headerHash === record.headerHash;
  return row.attemptID === record.attemptID;
}

// Only callers that arrive before a check starts may share that check. Later
// callers queue a fresh read, so a restore cannot reuse pre-restore evidence.
export function createDeploymentGuard(check, {
  maxWaiters = 64, maxCooldownMs = 250, maxWaitMs = 15000,
  now = () => performance.now(), delay = ms => new Promise(resolve => setTimeout(resolve, ms)),
} = {}) {
  if (typeof check !== 'function' || !Number.isSafeInteger(maxWaiters) || maxWaiters < 1
      || !Number.isFinite(maxCooldownMs) || maxCooldownMs < 0 || !Number.isSafeInteger(maxWaitMs)
      || maxWaitMs < 1 || typeof now !== 'function'
      || typeof delay !== 'function') throw Error('invalid_deployment_guard');
  let tail = Promise.resolve(), openBatch = null, waiters = 0, nextStart = 0;
  return async () => {
    if (waiters >= maxWaiters) throw Error('deployment_guard_busy');
    waiters += 1;
    let timeout;
    try {
      if (!openBatch) {
        const task = tail.catch(() => {}).then(async () => {
          const waitMs = Math.max(0, nextStart - now());
          if (waitMs) await delay(waitMs);
          if (openBatch === task) openBatch = null;
          const started = now();
          try { return await check(); }
          finally {
            const finished = now();
            nextStart = finished + Math.min(maxCooldownMs, Math.max(0, finished - started));
          }
        });
        openBatch = task;
        tail = task;
      }
      // Keep the slot occupied until the underlying check settles, even when
      // its caller times out. A stuck dependency cannot spawn unlimited work.
      const completion = openBatch.finally(() => { waiters -= 1; });
      const deadline = new Promise((_, reject) => {
        timeout = setTimeout(() => reject(Error('deployment_guard_timeout')), maxWaitMs);
      });
      return await Promise.race([completion, deadline]);
    } finally { clearTimeout(timeout); }
  };
}

// This is also executed by the independent host controller against a selected
// image's metadata. The controller pins that image and this checker separately.
export async function verifyDeploymentCompatibility({ query, fence, candidate, mode = 'traffic' }) {
  requireCandidate(candidate);
  if(fence?.anchor&&candidate.v1AnchorProtocol!==1)throw Error('deployment_code_floor');
  if (!['traffic', 'maintenance-upgrade'].includes(mode)) throw Error('invalid_deployment_mode');
  const before = await fence.snapshot();
  requireResolved(before);
  const beforeWriterFloor = requireWriterFloor(before, candidate);
  if (beforeWriterFloor) requireIndependentV1Anchor(fence);
  const version = await readMigrationSchemaVersion(query);
  if (version > candidate.maxSchemaVersion) throw Error('deployment_schema_floor');
  // Explicit maintenance keeps traffic closed. Only a pristine journal may
  // forward-upgrade an old V1 database; a retained intent/floor cannot be erased.
  if (mode === 'maintenance-upgrade' && version < 19 && !before.committed.length && !before.outcomes.length) {
    if (beforeWriterFloor) throw Error('deployment_writer_floor');
    const after = await fence.snapshot();
    requireResolved(after);
    if (requireWriterFloor(after, candidate)) throw Error('deployment_writer_floor');
    if (after.committed.length || after.outcomes.length) throw Error('deployment_schema_floor');
    return { compatible: true, schemaVersion: version, maintenanceOnly: true };
  }
  if (version < 19) throw Error('deployment_schema_floor');
  if (!Number.isSafeInteger(before.schemaFloor) || version < before.schemaFloor) throw Error('deployment_schema_floor');
  const publications = await readActivePublications(query, version);
  const after = await fence.snapshot();
  requireResolved(after);
  const afterWriterFloor = requireWriterFloor(after, candidate);
  if (afterWriterFloor) requireIndependentV1Anchor(fence);
  if (afterWriterFloor < beforeWriterFloor) throw Error('deployment_writer_floor');
  if (afterWriterFloor) {
    await assertV1CommitFence(query);
    await assertV1DataFloor(query,after);
    const final=await fence.snapshot();
    requireResolved(final);
    if(requireWriterFloor(final,candidate)!==afterWriterFloor
      ||JSON.stringify([final.v1BaselineID,final.v1Committed,final.v1Outcomes])
        !==JSON.stringify([after.v1BaselineID,after.v1Committed,after.v1Outcomes]))throw Error('deployment_v1_history_changed');
  }
  if (!Number.isSafeInteger(after.schemaFloor) || version < after.schemaFloor
      || after.committed.some(record => version < record.schemaFloor)) throw Error('deployment_schema_floor');
  // Every active pointer must be recorded as well as every recorded pointer
  // present. A recreated empty journal must not authorize an already-V2 DB.
  const byScope = new Map();
  for (const row of publications) {
    if (!row || typeof row.teamID !== 'string' || typeof row.vaultID !== 'string') throw Error('deployment_fence_mismatch');
    const key = `${row.teamID}\0${row.vaultID}`;
    if (byScope.has(key)) throw Error('deployment_fence_mismatch');
    byScope.set(key, row);
  }
  if (publications.length !== after.committed.length
      || after.committed.some(record => !samePublication(record, byScope.get(`${record.teamID}\0${record.vaultID}`))))
    throw Error('deployment_fence_mismatch');
  return { compatible: true, schemaVersion: version, ...(afterWriterFloor ? { writerFloor: afterWriterFloor } : {}) };
}
