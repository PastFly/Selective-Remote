import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { clientIPAddress } from "../src/request-security.mjs";

const proxySecret = "a".repeat(64);

test("client IP trusts a proxy header only with the shared secret", () => {
  assert.equal(clientIPAddress({
    headers: {
      "x-selective-proxy-secret": proxySecret,
      "x-selective-client-ip": "203.0.113.42",
    },
    socket: { remoteAddress: "172.20.0.3" },
  }, proxySecret), "203.0.113.42");

  assert.equal(clientIPAddress({
    headers: {
      "x-selective-proxy-secret": "b".repeat(64),
      "x-selective-client-ip": "203.0.113.42",
    },
    socket: { remoteAddress: "::ffff:172.20.0.3" },
  }, proxySecret), "172.20.0.3");
});

test("invalid addresses share a fail-closed unknown bucket", () => {
  assert.equal(clientIPAddress({
    headers: {
      "x-selective-proxy-secret": proxySecret,
      "x-selective-client-ip": "not-an-ip",
    },
    socket: { remoteAddress: "172.20.0.3" },
  }, proxySecret), "unknown");
});

test("bundled ingress overwrites and authenticates the client IP header", async () => {
  const caddyfile = await readFile(fileURLToPath(new URL("../Caddyfile", import.meta.url)), "utf8");
  const compose = await readFile(fileURLToPath(new URL("../compose.yaml", import.meta.url)), "utf8");

  assert.match(caddyfile, /header_up X-Selective-Client-IP \{remote_host\}/);
  assert.match(caddyfile, /header_up X-Selective-Proxy-Secret \{\$PROXY_SHARED_SECRET\}/);
  assert.match(compose, /PROXY_SHARED_SECRET: \$\{PROXY_SHARED_SECRET\}/);
  assert.doesNotMatch(compose, /8080:8080/);
});
