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
  if (row.teamID !== record.teamID || row.vaultID !== record.vaultID || row.manifestHash !== record.manifestHash) return false;
  if (record.generationID !== undefined)
    return row.generationID === record.generationID && row.sequence === record.sequence && row.headerHash === record.headerHash;
  return row.attemptID === record.attemptID;
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
  await fence.verifySchemaFloor(version);
  const publications = await readActivePublications(query, version);
  await fence.verify({ schemaVersion: version, publications });
  const after = await fence.snapshot();
  requireResolved(after);
  if (after.committed.some(record => version < record.schemaFloor)) throw Error('deployment_schema_floor');
  // Every active pointer must be recorded as well as every recorded pointer
  // present. A recreated empty journal must not authorize an already-V2 DB.
  if (publications.length !== after.committed.length
      || after.committed.some(record => !publications.some(row => samePublication(record, row))))
    throw Error('deployment_fence_mismatch');
  return { compatible: true, schemaVersion: version };
}
