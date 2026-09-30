import test from "node:test";
import assert from "node:assert/strict";
import { createAuthenticatedVaultClient } from "../public/vault-sync.js";

import { deviceTrustFailureCopy, deviceTrustRequestStatus } from "../public/device-trust-copy.js";

const deviceID = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
const userID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";

async function oldBackendClient(body = JSON.stringify({ error: "not_found" })) {
  const calls = [];
  const client = createAuthenticatedVaultClient({ fetchValue: async (path, options) => {
    calls.push(path);
    if (path === "/v1/auth/login") return new Response(JSON.stringify({
      token: "s".repeat(32), deviceID,
      user: { id: userID, email: "test@release.invalid", username: "release", displayName: "Release test" },
    }));
    return new Response(body, { status: 404 });
  } });
  await client.login({ email: "test@release.invalid", password: "synthetic-only", deviceID });
  return { client, calls };
}

test("old backend trust collection routes report unsupported capability without a success fallback", async () => {
  for (const body of [JSON.stringify({ error: "not_found" }), "<html>Not Found</html>"]) {
    const { client, calls } = await oldBackendClient(body);
    await assert.rejects(client.deviceTrustSnapshot(), /^Error: device_trust_unsupported$/);
    await assert.rejects(client.deviceTrustRequests(), /^Error: device_trust_unsupported$/);
    assert.equal(calls.filter(path => path.includes("device-trust")).length, 2);
    assert.notEqual(client.session(), null);
  }
});


test("untrusted backend text never becomes approval status or ordinary error copy", () => {
  for (const locale of ["ru", "en"]) {
    const raw = "internal_identifier_secret_500";
    assert.ok(!deviceTrustFailureCopy(new Error(raw), locale).includes(raw));
    assert.ok(!deviceTrustRequestStatus(raw, locale).includes(raw));
    assert.match(deviceTrustFailureCopy(new Error("device_trust_key_substitution"), locale),
      locale === "en" ? /Stop/ : /Не продолжайте/);
  }
});
