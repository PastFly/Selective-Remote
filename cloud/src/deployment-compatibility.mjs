import { readFile } from 'node:fs/promises';
import { readMigrationSchemaVersion, readActivePublications } from './migration-compatibility.mjs';

export const currentCapabilities = Object.freeze(JSON.parse(await readFile(new URL('../deployment-compatibility.json', import.meta.url), 'utf8')));
function requireCandidate(candidate) {
  const keys = ['fenceVersion', 'maxSchemaVersion', 'readerProjectionVersion', 'version', 'wholePublicationVersion'];
  if (!candidate || Object.keys(candidate).sort().join(',') !== keys.join(',')
      || candidate.version !== 1 || candidate.fenceVersion !== 2 || candidate.maxSchemaVersion !== 22
      || candidate.readerProjectionVersion !== 1 || candidate.wholePublicationVersion !== 1)
    throw Error('deployment_code_floor');
}
function requireResolved(snapshot) {
  if (!snapshot || !Array.isArray(snapshot.pending) || !Array.isArray(snapshot.committed) || !Array.isArray(snapshot.outcomes))
    throw Error('invalid_deployment_fence');
  if (snapshot.pending.length) throw Error('deployment_fence_pending');
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
  if (!['traffic', 'maintenance-upgrade'].includes(mode)) throw Error('invalid_deployment_mode');
  const before = await fence.snapshot();
  requireResolved(before);
  const version = await readMigrationSchemaVersion(query);
  if (version > candidate.maxSchemaVersion) throw Error('deployment_schema_floor');
  // Explicit maintenance keeps traffic closed. Only a pristine journal may
  // forward-upgrade an old V1 database; a retained intent/floor cannot be erased.
  if (mode === 'maintenance-upgrade' && version < 19 && !before.committed.length && !before.outcomes.length) {
    const after = await fence.snapshot();
    requireResolved(after);
    if (after.committed.length || after.outcomes.length) throw Error('deployment_schema_floor');
    return { compatible: true, schemaVersion: version, maintenanceOnly: true };
  }
  if (version < 19) throw Error('deployment_schema_floor');
  if (!Number.isSafeInteger(before.schemaFloor) || version < before.schemaFloor) throw Error('deployment_schema_floor');
  const publications = await readActivePublications(query, version);
  const after = await fence.snapshot();
  requireResolved(after);
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
  return { compatible: true, schemaVersion: version };
}
