import assert from "node:assert/strict";
import test from "node:test";
import { vaultFoundationCapabilities } from "../src/vault-format.mjs";

const session = { user_id: "1f386e3d-d7b7-4365-a116-19f68e7f512d",
  device_id: "33cc880e-084a-4d9a-b1ea-f99d2ff86032" };

test("all current v1 Vaults keep legacy access with both v2 capabilities inactive", () => {
  assert.deepEqual(vaultFoundationCapabilities({ session, formatState: "V1_ACTIVE",
    formatSchemaVersion: 1, registryRouteEligible: false }), {
    formatState: "V1_ACTIVE", legacyWholeVault: true,
    resource_registry_v2: false, resource_acl_v2: false,
  });
});

test("a client version claim cannot activate a reserved ACL capability", () => {
  const input = { session: { ...session, app_version: "999.0", resource_acl_v2: true },
    formatState: "V2_PREPARING", formatSchemaVersion: 2, registryRouteEligible: true };
  const caps = vaultFoundationCapabilities(input);
  assert.equal(caps.legacyWholeVault, false);
  assert.equal(caps.resource_registry_v2, true);
  assert.equal(caps.resource_acl_v2, false);
  assert.equal(vaultFoundationCapabilities({ ...input, registryRouteEligible: false })
    .resource_registry_v2, false);
  assert.throws(() => vaultFoundationCapabilities({ ...input, session: null }),
    /authentication_required/u);
});

test("hypothetical active v2 stays unusable until later implementation", () => {
  const caps = vaultFoundationCapabilities({ session, formatState: "V2_ACTIVE",
    formatSchemaVersion: 2, registryRouteEligible: true });
  assert.equal(caps.legacyWholeVault, false);
  assert.equal(caps.resource_registry_v2, false);
  assert.equal(caps.resource_acl_v2, false);
});
