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

test("optional 443-only ingress keeps TCP 80 with the existing host service", async () => {
  const caddyfile = await readFile(fileURLToPath(new URL("../Caddyfile.443-only", import.meta.url)), "utf8");
  const override = await readFile(fileURLToPath(new URL("../compose.443-only.yaml", import.meta.url)), "utf8");
  const guide = await readFile(fileURLToPath(new URL("../STAGING-443-ONLY.md", import.meta.url)), "utf8");

  assert.match(caddyfile, /\{\$CLOUD_PUBLIC_HOST\}/);
  assert.match(caddyfile, /auto_https disable_redirects/);
  assert.match(caddyfile, /issuer acme https:\/\/acme-v02\.api\.letsencrypt\.org\/directory/);
  assert.match(caddyfile, /disable_http_challenge/);
  assert.match(caddyfile, /header_up X-Selective-Client-IP \{remote_host\}/);
  assert.match(caddyfile, /header_up X-Selective-Proxy-Secret \{\$PROXY_SHARED_SECRET\}/);

  assert.match(override, /ports: !override/);
  assert.doesNotMatch(override, /80:80/);
  assert.match(override, /"443:443"/);
  assert.match(override, /"443:443\/udp"/);
  assert.match(override, /CLOUD_PUBLIC_HOST: \$\{CLOUD_PUBLIC_HOST:\?/);
  assert.match(override, /Caddyfile\.443-only:\/etc\/caddy\/Caddyfile:ro/);

  assert.match(guide, /Docker Compose 2\.24\.4 or newer/);
  assert.match(guide, /registration disabled/i);
  assert.doesNotMatch(guide, /cloud\.pastfly\.ru|\b\d{1,3}(?:\.\d{1,3}){3}\b/);
});
