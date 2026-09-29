import assert from "node:assert/strict";
import test from "node:test";
import { CloudService } from "../src/service.mjs";

test("access preview and commit use the server session secret, never a client field", async () => {
  const seen = [];
  const access = {
    async previewAccessChange(input) { seen.push(input); return { token: "signed" }; },
    async commitAccessChange(input) { seen.push(input); return { applied: 1 }; },
  };
  const service = new CloudService({ access }, { sessionPepper: "server-secret" });
  const session = { user_id: "actor", device_id: "device" };
  const body = { request: { changes: [{ type: "GRANT_REVOKE" }] },
    token: "signed", sessionSecret: "attacker-secret" };
  await service.previewAccessChange(session, "team", "vault", body);
  await service.commitAccessChange(session, "team", "vault", body, "request:0123456789");
  assert.equal(seen.length, 2);
  for (const input of seen) {
    assert.equal(input.actorUserID, "actor");
    assert.equal(input.actorDeviceID, "device");
    assert.equal(input.sessionSecret, "server-secret");
  }
});

test("Team groups keep Vault context as a gate, not an ownership key", async () => {
  let seen;
  const access = { async createAccessGroup(input) { seen = input;
    return { group: { id: "group", team_id: "team", name: input.name } }; } };
  const service = new CloudService({ access }, { sessionPepper: "secret" });
  const result = await service.createAccessGroup({ user_id: "actor", device_id: "device" },
    "team", { vaultID: "22222222-2222-4222-8222-222222222222", name: "Operators" }, "request:0123456789");
  assert.equal(result.group.id, "group");
  assert.equal(seen.teamID, "team");
  assert.equal(seen.vaultID, "22222222-2222-4222-8222-222222222222");
  assert.equal(seen.actorDeviceID, "device");
});

test("Effective Access forwards only an explicit validated subject device", async () => {
  const subject = "11111111-1111-4111-8111-111111111111";
  const device = "22222222-2222-4222-8222-222222222222";
  const seen = [];
  const service = new CloudService({ access: {
    async getEffectiveAccess(input) { seen.push(input); return { policyEffective: {} }; },
  } }, { sessionPepper: "secret" });
  const session = { user_id: "actor", device_id: "actor-device" };
  await service.getEffectiveAccess(session, "team", "vault", "resource", subject);
  await service.getEffectiveAccess(session, "team", "vault", "resource", subject, device);
  assert.equal(seen[0].subjectDeviceID, null);
  assert.equal(seen[1].subjectDeviceID, device);
  assert.equal(seen[1].actorDeviceID, "actor-device");
  await assert.rejects(service.getEffectiveAccess(session, "team", "vault",
    "resource", subject, "invalid"), /invalid_access_request/);
  assert.equal(seen.length, 2);
});
