import assert from "node:assert/strict";
import { hashPassword, verifyPassword } from "../src/security.mjs";

assert.equal(process.env.UV_THREADPOOL_SIZE, "1", "Run with UV_THREADPOOL_SIZE=1 set before Node starts");
assert.equal(process.env.NODE_OPTIONS, "--max-old-space-size=96", "Use the reviewed staging heap limit");

// Public test input only; never pass real credentials to this probe.
const password = "closed-staging-probe-not-a-real-password";
const hashes = await Promise.all(Array.from({ length: 4 }, () => hashPassword(password)));
for (const hash of hashes) assert.match(hash, /^scrypt\$v=1\$N=131072,r=8,p=1\$/);
assert.ok((await Promise.all(hashes.map(hash => verifyPassword(password, hash)))).every(Boolean));
assert.equal(await verifyPassword("wrong-staging-test-password", hashes[0]), false);

const maxRSSKiB = process.resourceUsage().maxRSS;
assert.ok(maxRSSKiB > 0 && maxRSSKiB < 320 * 1024, "KDF probe exceeded the Cloud memory budget");
console.log(`STAGING_KDF_PROBE_OK max-rss-kib=${maxRSSKiB}`);
