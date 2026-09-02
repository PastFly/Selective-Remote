import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { validateSmallHostModel } from "../scripts/validate-small-host-model.mjs";

const cloudURL = new URL("../", import.meta.url);
const checkerPath = fileURLToPath(new URL("scripts/validate-small-host-model.mjs", cloudURL));
const probePath = fileURLToPath(new URL("scripts/probe-staging-kdf.mjs", cloudURL));
const profile = await readFile(new URL("compose.small-host.yaml", cloudURL), "utf8");
const guide = await readFile(new URL("STAGING-SMALL-HOST.md", cloudURL), "utf8");

function fixture() {
  const model = { services: {} };
  for (const [name, memory, swap, cpus] of [
    ["postgres", 160, 192, 0.25], ["cloud", 320, 384, 0.4], ["caddy", 96, 128, 0.1],
  ]) {
    model.services[name] = {
      mem_limit: memory * 1024 * 1024, memswap_limit: swap * 1024 * 1024,
      cpus, pids_limit: 128, restart: "on-failure:3",
      logging: { driver: "json-file", options: { "max-size": "10m", "max-file": "3" } },
    };
  }
  model.services.cloud.environment = {
    ALLOW_REGISTRATION: "false", UV_THREADPOOL_SIZE: "1", NODE_OPTIONS: "--max-old-space-size=96",
    SESSION_TOKEN_PEPPER: "test-secret-must-never-be-printed",
  };
  model.services.postgres.command = [
    "postgres", "-c", "shared_buffers=32MB", "-c", "work_mem=1MB",
    "-c", "maintenance_work_mem=16MB", "-c", "autovacuum_work_mem=16MB",
    "-c", "autovacuum_max_workers=1", "-c", "max_connections=20",
    "-c", "max_parallel_workers=0", "-c", "max_parallel_workers_per_gather=0",
    "-c", "max_wal_size=128MB", "-c", "min_wal_size=32MB",
  ];
  model.services.caddy.ports = [
    { published: "443", target: 443, protocol: "tcp" },
    { published: "443", target: 443, protocol: "udp" },
  ];
  model.services.caddy.volumes = [{
    type: "bind", source: "/private/test/Caddyfile.443-only", target: "/etc/caddy/Caddyfile", read_only: true,
  }];
  return model;
}

test("small-host overlay has explicit budgets without changing ingress or secrets", () => {
  const model = fixture();
  for (const [name, s] of Object.entries(model.services)) {
    const block = profile.match(new RegExp(`^  ${name}:\\n([\\s\\S]*?)(?=^  [a-z]+:|$(?![\\s\\S]))`, "m"))?.[1];
    assert.ok(block, name);
    assert.match(block, new RegExp(`mem_limit: ${s.mem_limit / 1024 / 1024}m`));
    assert.match(block, new RegExp(`memswap_limit: ${s.memswap_limit / 1024 / 1024}m`));
    assert.match(block, new RegExp(`cpus: ${s.cpus}\\s`));
    assert.match(block, /pids_limit: 128/);
    assert.match(block, /restart: "on-failure:3"/);
    assert.match(block, /driver: json-file/);
    assert.match(block, /max-size: "10m"/);
    assert.match(block, /max-file: "3"/);
  }
  for (const [key, value] of Object.entries(model.services.cloud.environment).slice(0, 3)) {
    assert.ok(profile.includes(`${key}: "${value}"`));
  }
  for (const entry of model.services.postgres.command.filter(x => x.includes("="))) assert.ok(profile.includes(`- ${entry}`));
  assert.doesNotMatch(profile, /ports:|volumes:|privileged:|cap_add:|image:|build:|PASSWORD|PEPPER|PROXY_SHARED_SECRET/);
  assert.doesNotMatch(profile, /fsync|full_page_writes|synchronous_commit|oom_kill_disable/);
});

test("model checker accepts normalized bytes and Compose byte-size strings", () => {
  assert.deepEqual(validateSmallHostModel(fixture()), { memoryMiB: 576, additionalSwapMiB: 128, cpus: 0.75 });
  const model = fixture();
  model.services.cloud.mem_limit = "320m";
  model.services.cloud.memswap_limit = String(384 * 1024 * 1024);
  validateSmallHostModel(model);
});

const invalidCases = [
  ["extra service", m => { m.services.extra = {}; }],
  ["unlimited memory", m => { delete m.services.cloud.mem_limit; }],
  ["unlimited swap", m => { m.services.cloud.memswap_limit = -1; }],
  ["no CPU cap", m => { delete m.services.caddy.cpus; }],
  ["unlimited PIDs", m => { m.services.postgres.pids_limit = -1; }],
  ["restart loop", m => { m.services.cloud.restart = "always"; }],
  ["unbounded logs", m => { delete m.services.postgres.logging; }],
  ["privileged service", m => { m.services.cloud.privileged = true; }],
  ["host networking", m => { m.services.cloud.network_mode = "host"; }],
  ["registration enabled", m => { m.services.cloud.environment.ALLOW_REGISTRATION = "true"; }],
  ["parallel scrypt", m => { m.services.cloud.environment.UV_THREADPOOL_SIZE = "4"; }],
  ["unbounded heap", m => { delete m.services.cloud.environment.NODE_OPTIONS; }],
  ["unsafe postgres tuning", m => { m.services.postgres.command.push("-c", "fsync=off"); }],
  ["published database", m => { m.services.postgres.ports = [{ published: "5432", target: 5432 }]; }],
  ["published API", m => { m.services.cloud.ports = [{ published: "8080", target: 8080 }]; }],
  ["TCP 80 exposed", m => { m.services.caddy.ports.push({ published: "80", target: 80, protocol: "tcp" }); }],
  ["wrong Caddyfile", m => { m.services.caddy.volumes[0].source = "/private/test/Caddyfile"; }],
  ["writable Caddyfile", m => { m.services.caddy.volumes[0].read_only = false; }],
];
for (const [name, change] of invalidCases) {
  test(`model checker rejects ${name}`, () => {
    const model = fixture();
    change(model);
    assert.throws(() => validateSmallHostModel(model));
  });
}

test("checker CLI prints sanitized status only, including malformed or oversized input", () => {
  const secret = fixture().services.cloud.environment.SESSION_TOKEN_PEPPER;
  const invalid = fixture();
  invalid.services.cloud.environment.ALLOW_REGISTRATION = "true";
  for (const [input, status] of [
    [JSON.stringify(fixture()), 0], [JSON.stringify(invalid), 1],
    [`{"secret":"${secret}",`, 1], ["x".repeat(1024 * 1024 + 1), 1],
  ]) {
    const result = spawnSync(process.execPath, [checkerPath], { input, encoding: "utf8", timeout: 10_000 });
    assert.equal(result.status, status, result.stderr);
    assert.doesNotMatch(result.stdout + result.stderr, new RegExp(secret));
    assert.doesNotMatch(result.stdout + result.stderr, /\/private\/test|SyntaxError|stack|SESSION_TOKEN_PEPPER/);
    assert.match(result.stdout + result.stderr, status === 0 ? /SMALL_HOST_MODEL_OK/ : /SMALL_HOST_MODEL_INVALID/);
  }
});

test("single-worker KDF probe preserves hashing strength within the baseline budget", { timeout: 60_000 }, t => {
  const result = spawnSync(process.execPath, [probePath], {
    encoding: "utf8", timeout: 55_000,
    env: { ...process.env, UV_THREADPOOL_SIZE: "1", NODE_OPTIONS: "--max-old-space-size=96" },
  });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /^STAGING_KDF_PROBE_OK max-rss-kib=\d+\s*$/);
  t.diagnostic(result.stdout.trim());
});

test("guide preserves operational and secret-handling boundaries", () => {
  assert.match(guide, /config --format json\s*\\\n\s*\| docker run --rm -i --pull=never --network none --read-only/);
  assert.match(guide, /node@sha256:1b2479dd35a99687d6638f5976fd235e26c5b37e8122f786fcd5fe231d63de5b/);
  assert.match(guide, /host Node\.js is not required/);
  assert.doesNotMatch(guide, /\| node scripts\/validate-small-host-model\.mjs/);
  const orderedProfiles =
    /compose\.yaml[\s\S]*compose\.443-only\.yaml[\s\S]*compose\.small-host\.yaml[\s\S]*compose\.postgres-bind\.yaml/;
  assert.match(guide, orderedProfiles);
  assert.match(guide, /PostgreSQL bind profile must appear once and last/);
  assert.match(guide, /Earlier three-file examples are not valid/);
  assert.match(guide, /same four ordered profiles/);
  assert.match(guide, /start-staging-guarded\.sh/);
  assert.match(guide, /runtime limits do not limit Docker builds/);
  assert.match(guide, /not a\s+disk quota/);
  assert.match(guide, /does not bound\s+the HTTP request queue/);
  assert.match(guide, /No real data until a disposable restore drill/);
  assert.match(guide, /default project identity/);
  assert.match(guide, /never through terminal output, chat, command arguments or git/);
  assert.doesNotMatch(guide, /\b(?:\d{1,3}\.){3}\d{1,3}\b|ssh -p/);
});
