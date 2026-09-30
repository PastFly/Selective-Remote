import test from "node:test";
import assert from "node:assert/strict";
import {
  permissionsFor,
  presetMask,
  validateMask,
  normalizeMutation,
  accessLabel,
  effectiveSummary,
} from "../public/access-model.js";
const id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
test("resource masks and Credential dependency are exact", () => {
  assert.deepEqual(
    ["HOST", "CREDENTIAL", "SNIPPET", "FORWARDING", "FOLDER"].map((k) =>
      presetMask(k, "manage"),
    ),
    [13, 15, 13, 9, 33],
  );
  assert.equal(permissionsFor("CREDENTIAL")[0].name, "ViewMetadata");
  assert.throws(
    () => validateMask("CREDENTIAL", 5),
    /invalid_access_permissions/,
  );
  assert.equal(presetMask("CREDENTIAL", "edit"), 7);
  assert.throws(() => validateMask("FORWARDING", 5));
});
test("opaque labels require scoped locally authorized resolver and UNKNOWN stays unknown", () => {
  assert.equal(
    accessLabel(
      { teamID: id, vaultID: id, id, policyKind: "HOST" },
      () => null,
    ),
    `HOST · ${id}`,
  );
  assert.equal(accessLabel({ id, policyKind: "CREDENTIAL" }, () => null,
    (kind) => kind === "CREDENTIAL" ? "Учётные данные" : kind), `Учётные данные · ${id}`);
  assert.equal(
    effectiveSummary({
      policyEffective: { policyAllowed: true, policyMask: 1, paths: [] },
      deviceUsability: { effectiveUsable: "UNKNOWN" },
    }).usable,
    "UNKNOWN",
  );
});
test("canonical ids, positive bigint versions and whole-batch bounds", () => {
  const value = normalizeMutation({
    type: "GROUP_RENAME",
    groupID: id.toUpperCase(),
    expectedVersion: "2",
    name: " Team ",
  });
  assert.equal(value.groupID, id);
  assert.equal(value.expectedVersion, 2);
  assert.throws(
    () =>
      normalizeMutation({
        type: "GROUP_DELETE",
        groupID: id,
        expectedVersion: "9007199254740993",
      }),
    /invalid_access_version/,
  );
  assert.throws(
    () =>
      normalizeMutation({
        changes: Array.from({ length: 51 }, () => ({
          type: "GRANT_REVOKE",
          grantID: id,
          expectedVersion: 1,
        })),
      }),
    /access_batch_too_large/,
  );
  assert.throws(() => normalizeMutation({ type: "constructor" }));
});
