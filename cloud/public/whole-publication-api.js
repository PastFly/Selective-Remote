import { publicationHash } from './vault-publication-v1.js';
import { accessID } from './access-model.js';
import { canonicalMigrationJSON, toBase64 } from './vault-v2-migration.js';

const encoder = new TextEncoder(), MAX_CHUNK = 512 * 1024, MAX_TOTAL = 128 * 1024 * 1024;
const headers = Object.freeze({ 'X-Vault-Schema-Version': '2', 'X-Vault-Capability': 'resource_acl_v2', 'X-Publication-Version': '1' });
const fail = code => { throw Error(code); };
const same = (a, b) => canonicalMigrationJSON(a) === canonicalMigrationJSON(b);

export function createWholePublicationTransport({ request, teamID, getIdentity, cryptoValue = globalThis.crypto }) {
  const team = accessID(teamID), base = `/v1/teams/${team}/publication`;
  const op = operationID => `${base}/operations/${accessID(operationID)}`;
  if (typeof request !== 'function' || typeof getIdentity !== 'function') fail('invalid_publication_transport');
  function capture() {
    const identity = getIdentity(); if (!identity) fail('authentication_required');
    const frozen = JSON.parse(canonicalMigrationJSON(identity));
    return () => { const current = getIdentity(); if (!current || !same(current, frozen)) fail('publication_context_changed'); };
  }
  async function json(path, body) {
    const guard = capture(); guard(); let response;
    const encoded=body===undefined?undefined:canonicalMigrationJSON(body);if(encoded!==undefined&&encoder.encode(encoded).length>1024*1024)fail('publication_limit');
    try { response = await request(path, { method: body === undefined ? 'GET' : 'POST', headers: { ...headers },
      ...(body === undefined ? {} : { body: encoded }) }); }
    catch (error) { if (error instanceof TypeError) fail('publication_network_unavailable'); throw error; }
    guard(); let result;
    try { result = await response.json(); } catch { fail('publication_response_invalid'); }
    guard();
    if (!response.ok) {
      const error = Error(response.status === 401 ? 'authentication_required' : typeof result?.error === 'string' ? result.error : 'publication_request_failed');
      error.status = response.status; throw error;
    }
    return result;
  }
  const checkRequest = value => {
    if (value?.version !== 1 || value.teamID !== team || !value.operationID) fail('publication_scope_mismatch');
    accessID(value.operationID); return value;
  };
  return {
    async context({operationID}={}) {
      const value = await json(operationID===undefined ? base+'/context' : op(operationID)+'/context');
      if (value?.teamID !== team) fail('publication_scope_mismatch');
      const recovery=value.recoveryOnly===true;
      if(recovery && (operationID===undefined || value.operationState!=='COMMITTED' || value.actorRole!==null
        || ['groups','edges','memberships'].some(k=>!Array.isArray(value[k])||value[k].length)
        || !Array.isArray(value.current)||value.current.some(v=>['resources','policy','custodianDeviceIDs'].some(k=>!Array.isArray(v[k])||v[k].length))))fail('publication_unavailable');
      if (value.publicationAvailable !== true || value.environment !== 'staging' || !recovery && !['owner', 'admin'].includes(value.actorRole)
        || !Array.isArray(value.current) || !value.current.length || value.current.length > 10
        || value.current.some(v => v.teamID !== team) || !Number.isSafeInteger(value.actorKeyVersion) || value.actorKeyVersion < 1) fail('publication_unavailable');
      accessID(value.sessionID); return value;
    },
    preview(value, { token, cursor } = {}) {
      return json(base + '/preview', { request: checkRequest(value), ...(token === undefined ? {} : { token }), ...(cursor === undefined ? {} : { cursor }) });
    },
    start(token, value) { return json(base + '/start', { token, request: checkRequest(value) }); },
    putPart(operationID, vaultID, object) {
      if (encoder.encode(canonicalMigrationJSON({object})).length > 1024 * 1024) fail('publication_limit');
      return json(`${op(operationID)}/parts/${accessID(vaultID)}`, { object });
    },
    async putProjection(operationID, vaultID, projection, sidecar, checkpoint, checkTrust = async () => {}) {
      const guard = capture(), bytes = encoder.encode(canonicalMigrationJSON({ projection, sidecar, ...(checkpoint === undefined ? {} : { checkpoint }) }));
      if (!bytes.length || bytes.length > MAX_TOTAL) fail('publication_limit');
      const count = Math.ceil(bytes.length / MAX_CHUNK);
      const sha256 = Array.from(new Uint8Array(await cryptoValue.subtle.digest('SHA-256', bytes)), b => b.toString(16).padStart(2, '0')).join(''); guard();
      const headerHash = await publicationHash('header', projection.header, cryptoValue); guard();
      for (let index = 0; index < count; index++) {
        await checkTrust();
        guard(); const result = await json(`${op(operationID)}/projection-chunks/${accessID(vaultID)}`, {
          version: 1, index, count, sha256, data: toBase64(bytes.subarray(index * MAX_CHUNK, Math.min(bytes.length, (index + 1) * MAX_CHUNK))) }); guard();
        if (typeof result?.complete !== 'boolean') fail('publication_response_invalid');
        if (result.complete) {
          if (result.headerHash !== headerHash) fail('publication_response_invalid');
          return;
        }
        if (index === count - 1) fail('publication_response_invalid');
      }
    },
    validate(operationID, manifests) { return json(op(operationID) + '/validate', { manifests }); },
    commit(operationID, token, value) {
      if (accessID(operationID) !== checkRequest(value).operationID) fail('publication_scope_mismatch');
      return json(op(operationID) + '/commit', { token, request: value });
    },
    async receipt(operationID) {
      try { return await json(op(operationID) + '/receipt'); }
      catch (error) { if (['publication_receipt_not_found', 'publication_not_committed'].includes(error.message)) return null; throw error; }
    },
    readback(operationID, vaultID) { return json(`${op(operationID)}/readback/${accessID(vaultID)}`); },
    discard(operationID) { return json(op(operationID) + '/discard', {}); },
    repairDirectory(preview, vaultID, cursor) { return json(base + '/repair/directory', { token: preview.token,
      request: checkRequest(preview.request), vaultID: accessID(vaultID), ...(cursor == null ? {} : { cursor }) }); },
    repairPart(preview, vaultID, resourceID, part) {
      if (!['GENERAL', 'METADATA', 'SECRET', 'ADMINISTRATIVE'].includes(part)) fail('invalid_resource_part');
      return json(base + '/repair/part', { token: preview.token, request: checkRequest(preview.request), vaultID: accessID(vaultID), resourceID: accessID(resourceID), part });
    },
  };
}
