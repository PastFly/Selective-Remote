import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { fenceIntentDigest, productionPilotClosed, productionPilotOpened, reduceFenceEvents } from '../src/migration-fence-journal.mjs';

const ownerID = randomUUID(), vaultID = randomUUID(), pilotID = randomUUID();
const vault = { vaultKind:'PERSONAL', ownerID, vaultID, revision:1, ciphertextHash:'1'.repeat(64), envelopeHash:'2'.repeat(64) };
const baseline = [{ version:2, type:'V1_BASELINE', baselineID:randomUUID(), vaults:[vault] },
  { version:2, type:'V1_WRITER_FLOOR', writerProtocol:1 }];
const team = { version:2, type:'V1_TEAM_AUTHORIZATION_BASELINE', authorizationProtocol:2, digest:'a'.repeat(64) };
const open = { version:2, type:productionPilotOpened, ownerID, vaultID, pilotID, issuedAt:1000, expiresAt:61000 };
const close = { version:2, type:productionPilotClosed, pilotID };
const v1 = { version:2, type:'V1_PENDING_INTENT', operationID:randomUUID(), intentID:randomUUID(),
  ...vault, baseRevision:1, revision:2, pilotID };

test('production pilot history distinguishes staging, requires format 2 and remembers its reader floor after close', () => {
  assert.throws(() => reduceFenceEvents([...baseline, open]), /deployment_fence_conflict/);
  assert.throws(() => reduceFenceEvents([...baseline, { ...team, authorizationProtocol:1 }, open]), /deployment_fence_conflict/);
  assert.throws(() => reduceFenceEvents([...baseline, team, open, { ...close, type:'V1_PERSONAL_PILOT_CLOSED' }]), /deployment_fence_conflict/);
  assert.throws(() => reduceFenceEvents([...baseline, team, { ...open, type:'V1_PERSONAL_PILOT_OPENED' }, close]), /deployment_fence_conflict/);
  const current = [...baseline, team, open];
  const {pilotID: ignored, ...unscoped} = v1;
  assert.throws(() => reduceFenceEvents([...current, unscoped]), /deployment_fence_conflict/);
  assert.throws(() => reduceFenceEvents([...current, close, unscoped]), /deployment_fence_conflict/);
  assert.throws(() => reduceFenceEvents([...current, close, {...open, type:'V1_PERSONAL_PILOT_OPENED', pilotID:randomUUID()}]), /deployment_fence_conflict/);
  assert.equal(reduceFenceEvents(current).personalWritePilot.type, productionPilotOpened);
  assert.throws(() => reduceFenceEvents([...current, v1, close]), /deployment_fence_conflict/);
  assert.throws(() => reduceFenceEvents([...current, { ...v1, ownerID:randomUUID() }]), /deployment_fence_conflict/);
  const confirm = {version:2,type:'V1_CONFIRMED_COMMIT',intentID:v1.intentID,intentDigest:fenceIntentDigest(v1)};
  const closed = reduceFenceEvents([...current, v1, confirm, close]);
  assert.equal(closed.productionPersonalPilotHistory, true);
  assert.equal(closed.personalWritePilot, undefined);
  assert.throws(() => reduceFenceEvents([...current, close, open]), /deployment_fence_conflict/);
});

test('confirmed deletion revokes the owner while a production window can still be explicitly closed', () => {
  const deletion = { version:2, type:'V1_ACCOUNT_DELETION_PENDING_INTENT', userID:ownerID, vault,
    intentID:randomUUID(), authorizationIntentID:randomUUID(), changes:[], previousDigest:team.digest, nextDigest:'b'.repeat(64) };
  const committed = {version:2,type:'V1_CONFIRMED_COMMIT',intentID:deletion.intentID,intentDigest:fenceIntentDigest(deletion)};
  const events = [...baseline, team, open, deletion, committed];
  assert.throws(() => reduceFenceEvents([...events, v1]), /deployment_fence_conflict/);
  const state = reduceFenceEvents([...events, close]);
  assert.equal(state.v1Committed.length, 0);
  assert.equal(state.v1TeamAuthorization.digest, deletion.nextDigest);
  assert.equal(state.personalWritePilot, undefined);
});
