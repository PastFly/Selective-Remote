import { pathToFileURL } from "node:url";

const MiB = 1024 * 1024;
const budgets = Object.freeze({
  postgres: [160, 192, 0.25],
  cloud: [320, 384, 0.4],
  caddy: [96, 128, 0.1],
});
const postgresCommand = [
  "postgres", "-c", "shared_buffers=32MB", "-c", "work_mem=1MB",
  "-c", "maintenance_work_mem=16MB", "-c", "autovacuum_work_mem=16MB",
  "-c", "autovacuum_max_workers=1", "-c", "max_connections=20",
  "-c", "max_parallel_workers=0", "-c", "max_parallel_workers_per_gather=0",
  "-c", "max_wal_size=128MB", "-c", "min_wal_size=32MB",
];

function bytes(value) {
  if (typeof value === "number") return value;
  if (typeof value !== "string") return NaN;
  const match = /^(\d+)([kmg])?b?$/i.exec(value);
  if (!match) return NaN;
  return Number(match[1]) * (1024 ** ({ k: 1, m: 2, g: 3 }[match[2]?.toLowerCase()] ?? 0));
}

function requireCheck(condition, code) {
  // Codes are fixed strings, never values from a possibly secret-bearing model.
  if (!condition) throw new Error(code);
}

export function validateSmallHostModel(model) {
  const services = model?.services;
  requireCheck(services && Object.keys(services).sort().join(",") === "caddy,cloud,postgres", "unexpected_services");
  for (const [name, [memory, combined, cpus]] of Object.entries(budgets)) {
    const service = services[name];
    requireCheck(bytes(service.mem_limit) === memory * MiB, `${name}_memory_limit`);
    requireCheck(bytes(service.memswap_limit) === combined * MiB, `${name}_swap_limit`);
    requireCheck(Number(service.cpus) === cpus, `${name}_cpu_limit`);
    requireCheck(Number(service.pids_limit) === 128, `${name}_pids_limit`);
    requireCheck(service.restart === "on-failure:3", `${name}_restart_policy`);
    requireCheck(service.logging?.driver === "json-file" &&
      service.logging.options?.["max-size"] === "10m" &&
      service.logging.options?.["max-file"] === "3", `${name}_log_rotation`);
    requireCheck(!service.privileged && !service.network_mode, `${name}_isolation`);
  }
  const env = services.cloud.environment;
  requireCheck(env?.ALLOW_REGISTRATION === "false", "registration_must_be_disabled");
  requireCheck(env?.UV_THREADPOOL_SIZE === "1", "one_libuv_worker_required");
  requireCheck(env?.NODE_OPTIONS === "--max-old-space-size=96", "node_heap_limit");
  requireCheck(JSON.stringify(services.postgres.command) === JSON.stringify(postgresCommand), "postgres_tuning");
  requireCheck(!services.cloud.ports?.length && !services.postgres.ports?.length, "backend_ports_published");
  const ports = services.caddy.ports;
  requireCheck(Array.isArray(ports) && ports.length === 2 && ports.every(p =>
    String(p.published) === "443" && String(p.target) === "443") &&
    ports.map(p => p.protocol).sort().join(",") === "tcp,udp", "caddy_ports");
  const mounts = services.caddy.volumes?.filter(v => v.target === "/etc/caddy/Caddyfile");
  requireCheck(mounts?.length === 1 && mounts[0].type === "bind" && mounts[0].read_only === true &&
    typeof mounts[0].source === "string" && mounts[0].source.endsWith("/Caddyfile.443-only"), "caddy_mount");
  return { memoryMiB: 576, additionalSwapMiB: 128, cpus: 0.75 };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    process.stdin.setEncoding("utf8");
    let input = "";
    for await (const chunk of process.stdin) {
      input += chunk;
      if (Buffer.byteLength(input) > 1024 * 1024) throw new Error("model_too_large");
    }
    const result = validateSmallHostModel(JSON.parse(input));
    console.log(`SMALL_HOST_MODEL_OK memory=${result.memoryMiB}MiB extra-swap=${result.additionalSwapMiB}MiB cpu=${result.cpus}`);
  } catch {
    // Do not echo JSON, environment, paths, parse errors or secrets from stdin.
    console.error("SMALL_HOST_MODEL_INVALID: check the ordered profiles and required settings locally; do not share rendered environment values.");
    process.exitCode = 1;
  }
}
