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
