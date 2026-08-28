import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const scriptPath = fileURLToPath(new URL("../scripts/audit-host-readonly.sh", import.meta.url));
const guidePath = fileURLToPath(new URL("../STAGING-READINESS.md", import.meta.url));

test("host audit shell is valid and limited to read-only inventory", async () => {
  const syntax = spawnSync("bash", ["-n", scriptPath], { encoding: "utf8" });
  assert.equal(syntax.status, 0, syntax.stderr);

  const script = await readFile(scriptPath, "utf8");
  for (const expected of ["ss -H -lntup", "docker ps --format", "docker network ls", "systemctl list-units", "getent ahostsv4"]) {
    assert.ok(script.includes(expected), `missing inventory command: ${expected}`);
  }

  const executableSource = script
    .replace(/cat <<'USAGE'[\s\S]*?\nUSAGE\n/, "")
    .split("\n")
    .filter((line) => !line.trimStart().startsWith("#"))
    .join("\n");
  const destructive = /\b(?:sudo|printenv|iptables|ufw\s+(?:allow|delete|reset)|docker\s+(?:stop|rm)|systemctl\s+(?:stop|restart|enable|disable)|rm\s+-|mv\s+)\b/;
  assert.doesNotMatch(executableSource, destructive);
  assert.doesNotMatch(executableSource, /(?:cat|source|\.)\s+[^\n]*\.env\b/);
});

test("staging guide keeps audit output private and deployment gated", async () => {
  const guide = await readFile(guidePath, "utf8");
  assert.match(guide, /private continuity repository/);
  assert.match(guide, /does not\s+authorize deployment/);
  assert.match(guide, /Do not start the bundled Caddy service/);
});
