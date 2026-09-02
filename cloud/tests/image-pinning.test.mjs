import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const dockerfile = await readFile(new URL("../Dockerfile", import.meta.url), "utf8");
const compose = await readFile(new URL("../compose.yaml", import.meta.url), "utf8");
const readme = await readFile(new URL("../README.md", import.meta.url), "utf8");

const expectedNode =
  "node:22.18.0-alpine@sha256:1b2479dd35a99687d6638f5976fd235e26c5b37e8122f786fcd5fe231d63de5b";
const expectedPostgres =
  "postgres:16.6-alpine@sha256:1d04b9ba1d4996401f2552b51beda8187f175c0645c091e4781134fc9c9a3eef";
const expectedCaddy =
  "caddy:2.9.1-alpine@sha256:b4e3952384eb9524a887633ce65c752dd7c71314d2c2acf98cd5c715aaa534f0";

test("Dockerfile pins every build and runtime stage to the reviewed Node image", () => {
  const images = [...dockerfile.matchAll(/^FROM\s+(\S+)/gm)].map((match) => match[1]);
  assert.deepEqual(images, [expectedNode, expectedNode]);
});

test("Compose pins every external runtime image to its reviewed digest", () => {
  const images = [...compose.matchAll(/^\s+image:\s+(\S+)\s*$/gm)].map((match) => match[1]);
  assert.deepEqual(images, [expectedPostgres, expectedCaddy]);
});

test("operator documentation preserves the immutable upgrade contract", () => {
  assert.match(readme, /referenced as `tag@sha256`/);
  assert.match(readme, /Do not replace these references with mutable tags/);
});
