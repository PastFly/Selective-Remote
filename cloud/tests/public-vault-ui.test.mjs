import assert from "node:assert/strict";
import test from "node:test";
import { localVaultRecordData, localVaultRecordSummary } from "../public/app.js";

test("Vault form values map to the four versioned record types", () => {
  assert.deepEqual(
    localVaultRecordData("host", { title: " Production ", target: "host.invalid", secret: "" }),
    { title: "Production", address: "host.invalid" },
  );
  assert.deepEqual(
    localVaultRecordData("credential", { title: "Admin", target: "root", secret: "synthetic-secret" }),
    { title: "Admin", username: "root", secret: "synthetic-secret" },
  );
  assert.deepEqual(
    localVaultRecordData("snippet", { title: "Status", target: "", secret: "uptime" }),
    { title: "Status", body: "uptime" },
  );
  assert.deepEqual(
    localVaultRecordData("forwarding", { title: "Database", target: "db.invalid:5432", secret: "local 15432" }),
    { title: "Database", destination: "db.invalid:5432", configuration: "local 15432" },
  );
});

test("Vault form mapping rejects incomplete and oversized records", () => {
  assert.throws(
    () => localVaultRecordData("credential", { title: "Admin", target: "root", secret: "" }),
    /invalid_local_record/,
  );
  assert.throws(
    () => localVaultRecordData("unknown", { title: "Unknown", target: "value", secret: "value" }),
    /invalid_local_record/,
  );
  assert.throws(
    () => localVaultRecordData("host", { title: "x".repeat(121), target: "host.invalid", secret: "" }),
    /invalid_local_record/,
  );
});

test("credential summaries never expose their secret", () => {
  const record = {
    type: "credential",
    data: { title: "Admin", username: "root", secret: "must-not-render" },
  };
  const summary = localVaultRecordSummary(record);

  assert.equal(summary, "root · секрет скрыт");
  assert.equal(summary.includes(record.data.secret), false);
});
