import assert from "node:assert/strict";
import test from "node:test";
import { createResourceIdentity, prepareFolderIdentities,
  renameFolderIdentity, moveFolderIdentity, copyResourceIdentity,
  duplicateResourceIdentity, importResourceIdentity } from "../public/resource-identity.js";

const teamID = "84f6c860-0d26-4ef5-8652-27cb8b991b70";
const vaultID = "bc01823b-1401-4058-9488-f4f6d1839b3b";
const nextIDs = [
  "af810efa-fc88-43c4-8557-4105a5ff8140",
  "c109ab71-06cc-43a1-a37e-bc354ffec608",
  "00e3977b-c4c6-4317-98a9-ef4166c57910",
  "60275e39-febe-4021-b7f9-61173ef56bc0",
  "8b29a8c6-3bf1-493b-9a54-b0a531c455eb",
  "407aeeb1-c136-49ed-b093-3e589209e409",
  "6f461ae8-0c38-44fa-b439-42b3bf2380cb",
  "bf668ed4-04e4-4f47-89c7-b6ad2b482b02",
  "2ab21a55-46f1-4df8-b907-55ef36207ac0",
  "b33cef9c-e9e7-4a55-8795-788477b45c1e",
];
function generator() { return nextIDs.shift(); }

test("resource IDs are random v4 UUIDs and copy gets a new identity", () => {
  const original = createResourceIdentity({ teamID, vaultID, policyClass: "general" }, generator);
  const copied = copyResourceIdentity(original, generator);
  assert.equal(original.id, "af810efa-fc88-43c4-8557-4105a5ff8140");
  assert.equal(copied.id, "c109ab71-06cc-43a1-a37e-bc354ffec608");
  assert.equal(copied.teamID, teamID);
  assert.equal(copied.vaultID, vaultID);
  assert.notEqual(duplicateResourceIdentity(original, generator).id, original.id);
  assert.notEqual(importResourceIdentity(original, generator).id, original.id);
});

test("one-time folder preparation separates Host and Snippet namespaces and keeps nested parents", () => {
  const prepared = prepareFolderIdentities({
    teamID, vaultID, hostPaths: ["Ops/Prod", "Sales/Prod"], snippetPaths: ["Ops/Prod"],
  }, generator);
  assert.equal(prepared.length, 6);
  const hostOps = prepared.find((folder) => folder.namespace === "host" && folder.path === "Ops");
  const hostProd = prepared.find((folder) => folder.namespace === "host" && folder.path === "Ops/Prod");
  const snippetOps = prepared.find((folder) => folder.namespace === "snippet" && folder.path === "Ops");
  assert.equal(hostProd.parentFolderID, hostOps.id);
  assert.notEqual(hostOps.id, snippetOps.id);
  const renamed = renameFolderIdentity(prepared, hostOps.id, "Operations");
  assert.equal(renamed.find((folder) => folder.id === hostProd.id).path, "Operations/Prod");
  assert.equal(renamed.find((folder) => folder.id === hostOps.id).id, hostOps.id);
  assert.equal(renamed.find((folder) => folder.id === snippetOps.id).path, "Ops");
  const sales = prepared.find((folder) => folder.namespace === "host" && folder.path === "Sales");
  const moved = moveFolderIdentity(renamed, hostOps.id, sales.id);
  assert.equal(moved.find((folder) => folder.id === hostOps.id).path, "Sales/Operations");
  assert.equal(moved.find((folder) => folder.id === hostProd.id).path, "Sales/Operations/Prod");
  assert.equal(moved.find((folder) => folder.id === hostOps.id).parentFolderID, sales.id);
  assert.throws(() => moveFolderIdentity(prepared, hostOps.id, hostProd.id), /folder_cycle/u);
  assert.deepEqual(prepareFolderIdentities({ teamID, vaultID, hostPaths: ["Ops/Prod", "Sales/Prod"],
    snippetPaths: ["Ops/Prod"], existing: prepared }, () => {
      throw new Error("must reuse staged map");
    }), prepared);
});
