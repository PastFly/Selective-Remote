import assert from 'node:assert/strict';
import test from 'node:test';
import { validateInstallerCapabilities } from '../scripts/staging-reviewed-installer.mjs';
import { currentCapabilities } from '../src/deployment-compatibility.mjs';

test('staging installer accepts only the reviewed writer-capable metadata', () => {
  assert.equal(validateInstallerCapabilities(currentCapabilities),true);
  const {v1WriterProtocol:_,...old}=currentCapabilities;
  for(const invalid of [old,{...currentCapabilities,v1WriterProtocol:0},{...currentCapabilities,v1WriterProtocol:2},{...currentCapabilities,extra:true}])
    assert.throws(()=>validateInstallerCapabilities(invalid),/staging_install_candidate_code/);
});

test('registered staging requires the full reviewed Team protocol 2 manifest', () => {
  const { v1ProductionTeamVersion, v1ProductionPersonalPilotVersion, ...registered } = currentCapabilities;
  const { v1TeamAuthorizationRegistrationVersion, ...earlier } = registered;
  const { v1TeamAuthorizationProtocol, ...missingProtocol } = registered;
  assert.doesNotThrow(() => validateInstallerCapabilities(registered));
  assert.doesNotThrow(() => validateInstallerCapabilities(earlier));
  for (const invalid of [
    missingProtocol,
    { ...registered, v1TeamAuthorizationRegistrationVersion: 2 },
    { ...registered, v1TeamAuthorizationProtocol: 1 },
    { ...registered, maxSchemaVersion: 22 },
    { ...registered, unreviewed: true },
  ]) {
    assert.throws(() => validateInstallerCapabilities(invalid), /staging_install_candidate_code/);
  }
});
