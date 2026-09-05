import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const serverSource = await readFile(new URL("../src/server.mjs", import.meta.url), "utf8");

test("Team routes are authenticated, explicitly scoped and idempotent", () => {
  assert.ok(serverSource.indexOf("service.authenticate(bearerToken(request))")
    < serverSource.indexOf('url.pathname === "/v1/teams"'));
  for (const fragment of [
    "/v1/teams",
    "/v1/team-invitations/accept",
    "teamInvitationsMatch",
    "teamInvitationMatch",
    "teamMemberMatch",
    "teamVaultsMatch",
    "teamVaultMatch",
    "teamVaultDevicesMatch",
    "teamVaultWrappersMatch",
  ]) assert.match(serverSource, new RegExp(fragment.replaceAll("/", "\\/")));
  assert.match(serverSource, /idempotencyKey\(request\)/);
  assert.match(serverSource, /maxTeamBodyBytes = 16 \* 1024/);
  assert.match(serverSource, /team_invitation_create_user/);
  assert.match(serverSource, /team_invitation_accept_ip/);
  assert.match(serverSource, /service\.putSharedVault/);
  assert.match(serverSource, /service\.approveDeviceKey/);
  assert.match(serverSource, /service\.bootstrapDeviceKey/);
  assert.match(serverSource, /service\.grantSharedVaultWrapper/);
  assert.ok(serverSource.indexOf('url.pathname === "/v1/devices/bootstrap-key"')
    < serverSource.indexOf("const deviceMatch"));
  assert.match(serverSource, /device_key_bootstrap_user/);
  assert.match(serverSource, /device_key_bootstrap_ip/);
});

test("malformed or cross-scope Team identifiers use the same not-found boundary", () => {
  assert.match(serverSource, /!isUUID\(teamMembersMatch\[1\]\).*team_not_found/s);
  assert.match(serverSource, /!isUUID\(teamMemberMatch\[1\]\) \|\| !isUUID\(teamMemberMatch\[2\]\).*team_not_found/s);
  assert.match(serverSource, /!isUUID\(teamVaultsMatch\[1\]\).*team_not_found/s);
  assert.match(serverSource, /!isUUID\(teamVaultMatch\[1\]\) \|\| !isUUID\(teamVaultMatch\[2\]\).*team_not_found/s);
});

test("invitation outbox is pumped with one-process overlap protection", () => {
  assert.match(serverSource, /outboxPumpRunning/);
  assert.match(serverSource, /queueTeamInvitationOutboxDispatch/);
  assert.match(serverSource, /clearInterval\(outboxTimer\)/);
});
