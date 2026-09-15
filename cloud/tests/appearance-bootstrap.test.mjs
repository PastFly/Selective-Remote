import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

const source = await readFile(new URL("../public/appearance-bootstrap.js", import.meta.url), "utf8");

function bootTheme(cookie) {
  const document = { cookie, documentElement: { dataset: {} } };
  vm.runInNewContext(source, { document });
  return document.documentElement.dataset.theme;
}

test("appearance bootstrap applies a saved light theme before the stylesheet loads", () => {
  assert.equal(bootTheme("session=opaque; sr_theme=light; another=value"), "light");
});

test("appearance bootstrap uses graphite for absent or invalid preferences", () => {
  assert.equal(bootTheme("session=opaque"), "graphite");
  assert.equal(bootTheme("sr_theme=unknown"), "graphite");
});
