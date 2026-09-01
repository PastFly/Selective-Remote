import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import process from "node:process";

const expectedDigest =
  "4b7a54d666140ed4e9a3785437315cda9026bda2753c3d13086398f37e91704a";
const composeFiles = process.argv.slice(2);
if (composeFiles.length === 0) {
  throw new Error("At least one Compose file is required for source validation");
}

const digests = await Promise.all(
  composeFiles.map(async (path) => {
    const content = await readFile(path);
    return createHash("sha256").update(content).digest("hex");
  }),
);
const matches = digests
  .map((digest, index) => (digest === expectedDigest ? index : -1))
  .filter((index) => index >= 0);

if (matches.length !== 1) {
  throw new Error(
    "Compose inputs must contain exactly one exact reviewed PostgreSQL bind profile",
  );
}
if (matches[0] !== composeFiles.length - 1) {
  throw new Error("The reviewed PostgreSQL bind profile must be the final Compose file");
}

process.stdout.write(
  "POSTGRES_BIND_SOURCE_OK: exact reviewed storage profile is final\n",
);
