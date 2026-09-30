import assert from "node:assert/strict";
import test from "node:test";
import { CloudService } from "../src/service.mjs";

// Removing the public signed-preview gate must make every legacy route fail this test.
test("all original public group mutations reject unsigned requests before store writes", async () => {
  const fail = async () => {
    assert.fail("unsigned mutation reached store");
  };
  const service = new CloudService(
    {
      access: {
        createAccessGroup: fail,
        renameAccessGroup: fail,
        deleteAccessGroup: fail,
        addAccessGroupMember: fail,
        removeAccessGroupMember: fail,
      },
    },
    { sessionPepper: "synthetic" },
  );
  const session = { user_id: "actor", device_id: "device" };
  const body = {
    vaultID: "22222222-2222-4222-8222-222222222222",
    name: "Operators",
    expectedVersion: 1,
  };
  for (const [method, args] of [
    ["createAccessGroup", [session, "team", body, "synthetic:12345678"]],
    [
      "renameAccessGroup",
      [session, "team", "group", body, "synthetic:12345678"],
    ],
    [
      "deleteAccessGroup",
      [session, "team", "group", body, "synthetic:12345678"],
    ],
    [
      "addAccessGroupMember",
      [session, "team", "group", body, "synthetic:12345678"],
    ],
    [
      "removeAccessGroupMember",
      [session, "team", "group", "edge", body, "synthetic:12345678"],
    ],
  ])
    await assert.rejects(service[method](...args), /access_preview_conflict/);
});

test("group signed adapter uses authoritative session identity and secret", async () => {
  const seen = [];
  const service = new CloudService(
    {
      access: {
        async previewAccessGroupChange(input) {
          seen.push(input);
          return {};
        },
        async commitAccessGroupChange(input) {
          seen.push(input);
          return {};
        },
      },
    },
    { sessionPepper: "server" },
  );
  const session = { user_id: "actor", device_id: "device" };
  const body = {
    request: { type: "GROUP_CREATE", name: "Team" },
    token: "signed",
    sessionSecret: "untrusted",
    actorUserID: "untrusted",
  };
  await service.previewAccessGroupChange(session, "team", "vault", body);
  await service.commitAccessGroupChange(
    session,
    "team",
    "vault",
    body,
    "synthetic:123456789",
  );
  assert.ok(
    seen.every(
      (i) =>
        i.actorUserID === "actor" &&
        i.actorDeviceID === "device" &&
        i.sessionSecret === "server",
    ),
  );
});
