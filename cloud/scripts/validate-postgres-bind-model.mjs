import process from "node:process";

const expectedSource = process.env.POSTGRES_DATA_HOST_PATH;
if (!expectedSource) {
  throw new Error("POSTGRES_DATA_HOST_PATH is required for model validation");
}

let input = "";
for await (const chunk of process.stdin) input += chunk;
const model = JSON.parse(input);
const services = model.services ?? {};
const postgres = services.postgres;
if (!postgres) throw new Error("Rendered model has no postgres service");

const pgDataMounts = (postgres.volumes ?? []).filter(
  (mount) => mount.target === "/var/lib/postgresql/data",
);
if (pgDataMounts.length !== 1) {
  throw new Error("Rendered model must have exactly one PostgreSQL data mount");
}
const mount = pgDataMounts[0];
if (mount.type !== "bind" || mount.source !== expectedSource) {
  throw new Error("Rendered PostgreSQL data mount is not the reviewed bind source");
}
const bindOptions = mount.bind;
const bindKeys =
  bindOptions !== null &&
  typeof bindOptions === "object" &&
  !Array.isArray(bindOptions)
    ? Object.keys(bindOptions)
    : null;
if (
  bindKeys === null ||
  bindKeys.some((key) => key !== "create_host_path") ||
  (Object.hasOwn(bindOptions, "create_host_path") &&
    bindOptions.create_host_path !== false)
) {
  throw new Error("Rendered PostgreSQL mount has unsafe bind options");
}

for (const name of ["postgres", "cloud", "caddy"]) {
  if (services[name]?.restart !== "on-failure:3") {
    throw new Error(`${name} must use the guarded on-failure restart policy`);
  }
}
for (const name of ["postgres", "cloud"]) {
  if ((services[name]?.ports ?? []).length !== 0) {
    throw new Error(`${name} must not publish ports`);
  }
}
if (String(services.cloud?.environment?.ALLOW_REGISTRATION) !== "false") {
  throw new Error("Closed staging must keep registration disabled");
}

process.stdout.write("POSTGRES_BIND_MODEL_OK: storage and startup policy verified\n");
